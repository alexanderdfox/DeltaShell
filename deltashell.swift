import Foundation

// MARK: - Node

class Node {
	var buffer: String = ""
	let name: String
	init(_ name: String) { self.name = name }
}

// MARK: - Transformer protocol and base

protocol Transformer {
	var name: String { get }
	var input: Node { get }
	var output: Node { get }
	
	func pass(color: String)
}

extension Transformer {
	func pass(color: String) {
		// Default just copy buffer
		output.buffer = input.buffer
		print("\u{001B}[\(color)m[\(name)] Passed: \(input.buffer)\u{001B}[0m")
	}
}

// MARK: - Example Transformers

class EnvSetupTransformer: Transformer {
	let name: String
	let input: Node
	let output: Node
	init(name: String, input: Node, output: Node) {
		self.name = name
		self.input = input
		self.output = output
	}
	func pass(color: String) {
		let envSetup = "export PATH=/custom/bin:$PATH; "
		output.buffer = envSetup + input.buffer
		print("\u{001B}[\(color)m[\(name)] Env prepended: \(output.buffer)\u{001B}[0m")
	}
}

class LoggingTransformer: Transformer {
	let name: String
	let input: Node
	let output: Node
	init(name: String, input: Node, output: Node) {
		self.name = name
		self.input = input
		self.output = output
	}
	func pass(color: String) {
		print("[LOG][\(name)] Command passed: \(input.buffer)")
		output.buffer = input.buffer
	}
}

class FilterTransformer: Transformer {
	let name: String
	let input: Node
	let output: Node
	init(name: String, input: Node, output: Node) {
		self.name = name
		self.input = input
		self.output = output
	}
	func pass(color: String) {
		if input.buffer.contains("rm -rf") {
			output.buffer = "echo 'Command blocked for safety!'"
			print("\u{001B}[\(color)m[\(name)] Dangerous command blocked\u{001B}[0m")
		} else {
			output.buffer = input.buffer
		}
	}
}

class JsonToYamlTransformer: Transformer {
	let name: String
	let input: Node
	let output: Node
	init(name: String, input: Node, output: Node) {
		self.name = name
		self.input = input
		self.output = output
	}
	func pass(color: String) {
		// Stub: just note conversion
		output.buffer = "---\nconverted: yaml\noriginal:\n\(input.buffer)"
		print("\u{001B}[\(color)m[\(name)] Converted JSON to YAML (stub)\u{001B}[0m")
	}
}

// MARK: - Persistent SSH Session

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

				if self.outputBuffer.contains(self.doneMarker) {
					let parts = self.outputBuffer.components(separatedBy: self.doneMarker)
					let commandOutput = parts[0]

					if let current = self.commandQueue.first {
						current.1(commandOutput.trimmingCharacters(in: .whitespacesAndNewlines))
					}

					if !self.commandQueue.isEmpty {
						self.commandQueue.removeFirst()
					}

					self.outputBuffer = parts.dropFirst().joined(separator: self.doneMarker)
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

// MARK: - DeltaShell

class DeltaShell {
	var nodes: [String: Node] = [:]
	var transformersPerNode: [String: [Transformer]] = [:] // Multiple transformers per node
	var sshTargets: [String: String] = [:]
	var phaseColors: [String: String] = [:]
	var logicGates: [String: String] = [:]
	var gateEnablers: Set<String> = []

	var sshSessions: [String: PersistentSSHSession] = [:]

	init() {
		loadConfig()
		setupNodesAndTransformers()
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
				nodes[key + "_OUT"] = Node(key + "_OUT")
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

	func setupNodesAndTransformers() {
		// Clear old transformers
		transformersPerNode.removeAll()

		// Register example transformer plugins per phase node
		for phase in sshTargets.keys {
			// Base nodes
			guard let inputNode = nodes[phase], let outputNode = nodes[phase + "_OUT"] else { continue }

			// Example: multiple transformers chained: EnvSetup -> Filter -> Logging (Removed EncryptTransformer)
			let transformers: [Transformer] = [
				EnvSetupTransformer(name: "EnvSetup_\(phase)", input: inputNode, output: outputNode),
				FilterTransformer(name: "Filter_\(phase)", input: outputNode, output: outputNode),
				LoggingTransformer(name: "Logger_\(phase)", input: outputNode, output: outputNode)
			]

			transformersPerNode[phase] = transformers
		}
	}

	func setupSessions() {
		for (phase, host) in sshTargets {
			if host == "localhost" || host == "127.0.0.1" {
				sshSessions[phase] = nil // Local execution
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
		process.executableURL = URL(fileURLWithPath: "/bin/zsh")
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

	func runTransformers(for phase: String, color: String) {
		guard let transformers = transformersPerNode[phase], let _ = nodes[phase] else { return }
		for transformer in transformers {
			transformer.pass(color: color)
		}
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

		runTransformers(for: phase, color: color)

		if let target = sshTargets[phase] {
			if target == "localhost" || target == "127.0.0.1" {
				print("\u{001B}[\(color)m[Phase \(phase)] Executing locally...\u{001B}[0m")
				let output = executeLocal(nodes[phase + "_OUT"]?.buffer ?? cmd)
				print("\u{001B}[\(color)m[Output]\n\(output)\u{001B}[0m")
			} else if let session = sshSessions[phase] {
				print("\u{001B}[\(color)m[Phase \(phase)] Executing remotely on \(target)...\u{001B}[0m")
				session.sendCommand(nodes[phase + "_OUT"]?.buffer ?? cmd) { output in
					print("\u{001B}[\(color)m[Output]\n\(output)\u{001B}[0m")
				}
			} else {
				print("\u{001B}[\(color)m[Phase \(phase)] No SSH session available\u{001B}[0m")
			}
		}
	}

	func run() {
		print("🔌 DeltaShell v4 — Transformers & Plugins, SCP, Local/Remote, Colors")
		print("Format: PHASE: command | scp phase:/path phase:/path | Type 'exit' to quit\n")

		while true {
			print(">>> ", terminator: "")
			guard let line = readLine(), line != "exit" else { break }
			handle(line)
			usleep(200_000)
		}

		sshSessions.values.forEach { $0.close() }
	}
}

// MARK: - Run

let shell = DeltaShell()
shell.run()
