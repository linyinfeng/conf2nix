# [n]conf2nix

Two simple **experimental** _best effort_ tools to convert kconfig `.config` file to nixpkgs _structured config_.

From structured config to `.config` we have [generate-config.pl](https://github.com/NixOS/nixpkgs/blob/master/pkgs/os-specific/linux/kernel/generate-config.pl). These two tools are created to **help** developers to convert `.config` to structured config.

1. `conf2nix` - a tool reads both Kconfig and `.config`, then output all symbols that both defined in `.config` and having a prompt as nixpkgs structured config.
2. `nconf2nix` - **naive** version of `conf2nix`, which only reads `.config` and output all symbols as nixpkgs structured config.

In most cases the output of `nconf2nix` can not be directly used in `structuredExtraConfig`. That is because there is a gap between `.config` file and nixpkgs structured config. In nixpkgs, structured config is used in [generate-config.pl](https://github.com/NixOS/nixpkgs/blob/master/pkgs/os-specific/linux/kernel/generate-config.pl) to interactively answer questions in `make config` (precisely `make oldaskconfig`). While the `.config` file is not directly related to prompt and answer, whether a symbol will be written to `.config` is controlled by a complex `SYMBOL_WRITE` flag.

`conf2nix` does not have the issue of `nconf2nix`, since it ignores symbols that do not have a prompt, but,

1. it requires user to carefully review these unused symbols and modify `.config` (or set `warnUnused = false`);
2. it requires full Kconfig source code and libraries in `scripts/kconfig`, so that it must be built with the kernel source code.

## Usage of conf2nix

To use `conf2nix`, call the main function `lib.conf2nix`.
**Please read [conf2nix/default.nix](./conf2nix/default.nix) for more options.**

```nix
conf2nix {
    configFile = ./path/to/.config;
    src = kernel.src;
    preset = "standalone"|"partial";
}
```

There is also a convenient CLI wrapper `packages.${system}.conf2nix-wrapper` for interactive usage.

```console
$ nix run "github:linyinfeng/conf2nix#conf2nix-wrapper"
usage: conf2nix <kernel-src> <kconfig-config> <extra args to nix>...
$ nix run "github:linyinfeng/conf2nix#conf2nix-wrapper" -- /path/to/linux/source-code config --arg preset standalone|partial > config.nix
...
$ head -n 19 config.nix
{ lib }:
let
  inherit (lib.kernel) yes no module freeform;
in {
  # Linux/x86 6.8.2 Kernel Configuration

  ## General setup
  "LOCALVERSION_AUTO" = yes; # Automatically append version information to the version string
  "KERNEL_ZSTD" = yes; # ZSTD
  "DEFAULT_HOSTNAME" = freeform "(none)"; # Default hostname
  "SYSVIPC" = yes; # System V IPC
  "POSIX_MQUEUE" = yes; # POSIX Message Queues
  "WATCH_QUEUE" = yes; # General notification queue
  "CROSS_MEMORY_ATTACH" = yes; # Enable process_vm_readv/writev syscalls
  "AUDIT" = yes; # Auditing support

  ### General setup -> IRQ subsystem
  "SPARSE_IRQ" = yes; # Support sparse irq numbering
  ### General setup: end of IRQ subsystem
```

# Usage of nconf2nix

Simply run `packages.${system}.nconf2nix`.

```console
$ nix run "github:linyinfeng/conf2nix#nconf2nix" -- --config .config --output config.nix
$ head config.nix
{ lib }:
let
  inherit (lib.kernel) yes no module freeform;
in {
  "64BIT" = yes;
  "8139TOO" = yes;
  "8139TOO_PIO" = yes;
  "9P_FS" = yes;
  "ACPI" = yes;
  "ACPI_AC" = yes;
```

# License

- `conf2nix` is a derived work of the Linux kernel and is licensed under the [GPL-2.0-only](./conf2nix/LICENSE) license.
- `nconf2nix` and other parts of this repository is licensed under the [MIT](./LICENSE) license.
