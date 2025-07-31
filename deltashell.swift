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

class DeltaShell {
	var nodes: [String: Node] = [:]
	var transformers: [String: Transformer] = [:]
	var sshTargets: [String: String] = [:]
	var phaseColors: [String: String] = [:]
	var logicGates: [String: String] = [:]
	var gateEnablers: Set<String> = []

	init() {
		loadConfig()
		setupTransformers()
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

	func sshExecute(_ cmd: String, on host: String) -> String {
		let process = Process()
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = ["ssh", host, cmd]

		do {
			try process.run()
		} catch {
			return "SSH error: \(error)"
		}

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		return String(data: data, encoding: .utf8) ?? "Failed to decode output"
	}

	func handle(_ input: String) {
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

		// Check for logic gate
		if let gate = logicGates[phase], !gateEnablers.contains(gate) {
			print("\u{001B}[\(color)m[Phase \(phase)] Blocked: Gate \(gate) not enabled\u{001B}[0m")
			return
		}

		// Gate-enabling logic
		if cmd == "enable \(phase)" {
			gateEnablers.insert(phase)
			print("\u{001B}[\(color)m[Logic] Enabled phase \(phase)\u{001B}[0m")
			return
		}

		// Pass through transformer
		if let transformer = transformers[phase] {
			transformer.pass(color: color)
		}

		// Execute via SSH
		if let target = sshTargets[phase] {
			print("\u{001B}[\(color)m[Phase \(phase)] Executing remotely on \(target)...\u{001B}[0m")
			let output = sshExecute(cmd, on: target)
			print("\u{001B}[\(color)m[Output]\n\(output)\u{001B}[0m")
		} else {
			print("\u{001B}[\(color)m[Phase \(phase)] No SSH target assigned\u{001B}[0m")
		}
	}

	func run() {
		print("🔌 DeltaShell v2.0 — Infinite Phases, SSH, Colors")
		print("Format: PHASE: command | Type 'exit' to quit\n")

		while true {
			print(">>> ", terminator: "")
			guard let line = readLine(), line != "exit" else { break }
			handle(line)
		}
	}
}

let shell = DeltaShell()
shell.run()
