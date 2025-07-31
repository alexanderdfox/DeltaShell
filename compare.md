# DeltaShell Serial SSH vs Typical SSH Shell

| Feature                      | DeltaShell Serial SSH           | Typical SSH Shell          |
|-----------------------------|--------------------------------|---------------------------|
| Multi-phase abstraction     | ✔ Yes                          | ✘ No                      |
| Logic gating per phase      | ✔ Yes                          | ✘ No                      |
| Persistent SSH connections  | ✔ Yes                          | ✘ No (unless manual setup)|
| Transformer nodes & buffers | ✔ Yes                          | ✘ No                      |
| Local + remote hybrid       | ✔ Yes                          | ✘ No                      |
| SCP between phases          | ✔ Yes                          | ✘ No (manual only)        |
| Colored per-phase output    | ✔ Yes                          | ✘ No                      |

---

**Summary:**

DeltaShell is more than a simple shell; it is a distributed command and control environment designed for multi-host orchestration with built-in logic, coordination, and persistent connections, making it especially suited for complex workflows and enhanced visibility compared to typical SSH shells.
