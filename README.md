
# DeltaShell

**DeltaShell** is a command-line tool for managing and executing commands across multiple named **phases** with color-coded output, SSH remote execution, and simple logic gate control.

---

## Features

- Supports **infinite phases**, each with a unique name and color.
- Routes commands to corresponding phases in the format:  
  `PHASE: command`
- Passes command buffers through transformers for chaining.
- Executes commands remotely over SSH on phase-specific hosts.
- Implements simple **logic gate control** to enable or block phases dynamically.
- Color-coded output for easy identification of phases and command results.

---

## Configuration

DeltaShell requires a `.deltarc.json` configuration file placed in the current working directory. This JSON file defines phases, their colors, SSH targets, and optional logic gates.

### Example `.deltarc.json`

```json
{
  "phases": {
    "phase1": {
      "color": "31",         // ANSI Red
      "ssh": "user@host1"
    },
    "phase2": {
      "color": "34",         // ANSI Blue
      "ssh": "user@host2"
    }
  },
  "logic": {
    "gates": {
      "phase1": "gate1",
      "phase2": "gate2"
    }
  }
}
```

- **phases**: Dictionary where keys are phase names, each with:
  - `color`: ANSI color code (e.g. 31 = red, 34 = blue).
  - `ssh`: SSH host string (e.g. `user@hostname`).
- **logic.gates** (optional): Map of phases to gate names for enabling/blocking.

---

## Usage

Run the program, and enter commands in the format:

```
PHASE: command
```

- Example:

```
phase1: ls -la
```

This will:

- Send the command `ls -la` to the node `phase1`.
- Pass it through the transformer pipeline.
- Execute the command remotely via SSH on the configured host for `phase1`.
- Display colored output corresponding to `phase1`'s color.

### Logic Gate Control

If a phase is gated, commands are blocked unless the gate is enabled. Enable a gate by entering:

```
PHASE: enable PHASE
```

Example:

```
phase1: enable phase1
```

---

## Installation & Running

1. Place your `.deltarc.json` in the directory where you run DeltaShell.
2. Build and run the Swift program (e.g. `swift run` or compile and execute).
3. Enter commands following the format above.
4. Type `exit` to quit the shell.

---

## Dependencies

- Swift 5+
- SSH access to remote hosts configured in `.deltarc.json`
- Terminal that supports ANSI color codes

---

## License

MIT License

---

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

---

## Contact

For questions or support, please contact the maintainer.

---

Enjoy using DeltaShell! 🚀
