import Foundation

class Node {
    var buffer: String = ""
    let name: String
    init(_ name: String) { self.name = name }
}

class Transformer {
    let name: String
    let input: Node
    let output: Node
    init(name: String, input: Node, output: Node) {
        self.name = name
        self.input = input
        self.output = output
    }

    func pass(color: String) {
        output.buffer = input.buffer
        print("\u{001B}[\(color)m[\(name)] Passed: \(input.buffer)\u{001B}[0m")
    }
}

class PersistentSSHSession {
    let host: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?

    private var commandQueue: [(String, (String) -> Void)] = []
    private var isBusy = false
    private var outputBuffer = ""

    private let doneMarker = "__DONE__"

    init(host: String) {
        self.host = host
        startSession()
    }

    private func startSession() {
        process = Process()
        stdinPipe = Pipe()
        stdoutPipe = Pipe()

        guard let process = process, let stdinPipe = stdinPipe, let stdoutPipe = stdoutPipe else { return }

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ssh", "-tt", host]

        do {
            try process.run()
        } catch {
            print("❌ Failed to start SSH session to \(host): \(error)")
            return
        }

        // Start async reading
        readOutput()
    }

    private func readOutput() {
        guard let stdoutPipe = stdoutPipe else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.count > 0, let output = String(data: data, encoding: .utf8) {
                self.outputBuffer += output
                // print("[\(self.host) partial output]: \(output)")

                // Check if doneMarker is in output buffer
                if self.outputBuffer.contains(self.doneMarker) {
                    // Extract output before marker
                    let parts = self.outputBuffer.components(separatedBy: self.doneMarker)
                    let commandOutput = parts[0]

                    // Call callback with trimmed output
                    if let current = self.commandQueue.first {
                        current.1(commandOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                    }

                    // Remove current command from queue
                    if !self.commandQueue.isEmpty {
                        self.commandQueue.removeFirst()
                    }

                    // Remove everything up to marker (including marker)
                    self.outputBuffer = parts.dropFirst().joined(separator: self.doneMarker)

                    // Mark not busy, send next command if any
                    self.isBusy = false
                    self.trySendNext()
                }
            }
        }
    }

    func sendCommand(_ command: String, completion: @escaping (String) -> Void) {
        commandQueue.append((command, completion))
        trySendNext()
    }

    private func trySendNext() {
        guard !isBusy, let stdinPipe = stdinPipe else { return }
        guard let (cmd, _) = commandQueue.first else { return }
        isBusy = true

        // Append echo doneMarker to detect command end
        let fullCommand = "\(cmd); echo \(doneMarker)\n"
        if let data = fullCommand.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
    }

    func close() {
        stdinPipe?.fileHandleForWriting.closeFile()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
    }
}

class DeltaShell {
    var nodes: [String: Node] = [:]
    var transformers: [String: Transformer] = [:]
    var sshTargets: [String: String] = [:]
    var phaseColors: [String: String] = [:]
    var logicGates: [String: String] = [:]
    var gateEnablers: Set<String> = []

    var sshSessions: [String: PersistentSSHSession] = [:]

    init() {
        loadConfig()
        setupTransformers()
        setupSessions()
    }

    func loadConfig() {
        let path = FileManager.default.currentDirectoryPath + "/.deltarc.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("❌ Missing config file: .deltarc.json")
            exit(1)
        }

        do {
            let raw = try JSONSerialization.jsonObject(with: data, options: [])
            guard let root = raw as? [String: Any],
                  let phases = root["phases"] as? [String: Any] else {
                print("❌ Invalid JSON: Missing 'phases'")
                exit(1)
            }

            for (key, val) in phases {
                guard let dict = val as? [String: Any],
                      let color = dict["color"] as? String,
                      let ssh = dict["ssh"] as? String else {
                    print("⚠️ Skipping invalid phase: \(key)")
                    continue
                }
                nodes[key] = Node(key)
                phaseColors[key] = color
                sshTargets[key] = ssh
            }

            if let logic = root["logic"] as? [String: Any],
               let gates = logic["gates"] as? [String: String] {
                logicGates = gates
            }

        } catch {
            print("❌ Failed to parse JSON: \(error)")
            exit(1)
        }
    }

    func setupTransformers() {
        for (from, to) in sshTargets.keys.map({ ($0, $0 + "_OUT") }) {
            let input = nodes[from] ?? Node(from)
            let output = Node(to)
            nodes[to] = output
            let transformer = Transformer(name: "T\(from)", input: input, output: output)
            transformers[from] = transformer
        }
    }

    func setupSessions() {
        for (phase, host) in sshTargets {
            if host == "localhost" || host == "127.0.0.1" {
                // No persistent SSH session needed for localhost, use direct execution
                sshSessions[phase] = nil
            } else {
                sshSessions[phase] = PersistentSSHSession(host: host)
            }
        }
    }

    func executeLocal(_ cmd: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: "/bin/zsh") // or get from SHELL env var
        process.arguments = ["-c", cmd]

        do {
            try process.run()
        } catch {
            return "Local execution error: \(error)"
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "Failed to decode local output"
    }

    func scpBetweenPhases(_ src: String, _ dst: String) -> String {
        guard let srcSep = src.firstIndex(of: ":"),
              let dstSep = dst.firstIndex(of: ":") else {
            return "Invalid SCP syntax. Usage: scp phase:/path phase:/path"
        }

        let srcPhase = String(src[..<srcSep])
        let srcPath = String(src[srcSep...].dropFirst())
        let dstPhase = String(dst[..<dstSep])
        let dstPath = String(dst[dstSep...].dropFirst())

        guard let srcHost = sshTargets[srcPhase],
              let dstHost = sshTargets[dstPhase] else {
            return "Unknown source or destination phase"
        }

        let srcStr = (srcHost == "localhost" ? srcPath : "\(srcHost):\(srcPath)")
        let dstStr = (dstHost == "localhost" ? dstPath : "\(dstHost):\(dstPath)")

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["scp", srcStr, dstStr]

        do {
            try process.run()
        } catch {
            return "SCP error: \(error)"
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "Failed to decode SCP output"
    }

    func handle(_ input: String) {
        if input.starts(with: "scp ") {
            let parts = input.dropFirst(4).split(separator: " ", maxSplits: 1).map { String($0) }
            if parts.count == 2 {
                let output = scpBetweenPhases(parts[0], parts[1])
                print(output)
            } else {
                print("Invalid scp command. Usage: scp phaseA:/path phaseB:/path")
            }
            return
        }

        guard input.contains(":") else {
            print("Use format: PHASE: command")
            return
        }

        let parts = input.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return }

        let phase = parts[0]
        let cmd = parts[1]

        guard let node = nodes[phase] else {
            print("❌ Unknown phase: \(phase)")
            return
        }

        node.buffer = cmd
        let color = phaseColors[phase] ?? "37"

        if let gate = logicGates[phase], !gateEnablers.contains(gate) {
            print("\u{001B}[\(color)m[Phase \(phase)] Blocked: Gate \(gate) not enabled\u{001B}[0m")
            return
        }

        if cmd == "enable \(phase)" {
            gateEnablers.insert(phase)
            print("\u{001B}[\(color)m[Logic] Enabled phase \(phase)\u{001B}[0m")
            return
        }

        if let transformer = transformers[phase] {
            transformer.pass(color: color)
        }

        if let target = sshTargets[phase] {
            print("\u{001B}[\(color)m[Phase \(phase)] Executing on \(target)...\u{001B}[0m")

            if target == "localhost" || target == "127.0.0.1" {
                let output = executeLocal(cmd)
                print("\u{001B}[\(color)m[Output]\n\(output)\u{001B}[0m")
            } else if let session = sshSessions[phase] {
                session.sendCommand(cmd) { output in
                    print("\u{001B}[\(color)m[Output]\n\(output)\u{001B}[0m")
                }
            } else {
                print("\u{001B}[\(color)m[Phase \(phase)] No SSH session available\u{001B}[0m")
            }
        }
    }

    func run() {
        print("🔌 DeltaShell v3.0 — Persistent SSH, SCP, Local Exec, Colors")
        print("Format: PHASE: command | scp phaseA:/src phaseB:/dst | Type 'exit' to quit\n")

        while true {
            print(">>> ", terminator: "")
            guard let line = readLine(), line != "exit" else { break }
            handle(line)
        }

        // Close all sessions on exit
        for (_, session) in sshSessions {
            session.close()
        }
    }
}

let shell = DeltaShell()
shell.run()
