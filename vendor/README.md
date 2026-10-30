# GNU development packages

| Directory  | Target              | Status                                               |
| ---------- | ------------------- | ---------------------------------------------------- |
| `aarch64/` | Ubuntu 20.04 ARM64  | Included; selected by default for ARM64 Linux builds |
| `x86_64/`  | Ubuntu 20.04 x86_64 | Reserved; contains only `.gitkeep`                   |

The x86_64 directory has no development files and is not a build dependency.
x86_64 builds still use the host GNU files or an explicit `-Dsysroot`.
