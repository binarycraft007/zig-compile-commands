# zig-compile-commands

A decoupled compilation database (`compile_commands.json`) generator for **Zig 0.17+** and `clangd`.

## The New Decoupled Way

In Zig 0.17+, custom build steps with in-process execution callbacks were removed in favor of splitting the build system into a **Configurer** and a **Maker** process. The Configurer serializes the entire build graph into a binary configuration file (`.zig-cache/c/<hash>`).

`zig-compile-commands` operates externally by reading and parsing this serialized compilation graph using the Zig standard library (`std.Build.Configuration`). It extracts all C and C++ translation units, target architectures, include directories, preprocessor definitions, and compiler flags without requiring any custom step hacks or modifications to your `build.zig`.

## Features

- **Strictly Zig 0.17+ compliant**: Built with `std.Io` and `std.process.Init`.
- **Automatic Graph Resolution**: Runs `zig build --print-configuration-path` automatically to locate the active configuration graph (supports passing build options like `-Dtarget=...`).
- **Complete Module Traversal**: Resolves DAG dependencies, modules, include paths (`-I`, `-isystem`, `-idirafter`, `-F`, `-iframework`), config header steps, and `-D` macros.
- **Support for `CSourceFile` and `CSourceFiles`**: Handles all C/C++ translation units.
- **Multiple Compiler Drivers**: Output either `zig cc`/`zig c++` or `clang`/`clang++` for `clangd`.
- **Zero-touch Integration**: No need to add custom steps or packages into your project's `build.zig`.

## Installation & Build

```bash
cd /path/to/zig-compile-commands
zig build -Doptimize=ReleaseFast
```

This installs the binary to `zig-out/bin/zig-compile-commands`.

## Usage

In any Zig project with C/C++ source files:

```bash
# Basic usage (generates compile_commands.json in the current project root)
/path/to/zig-compile-commands

# Specify output location
zig-compile-commands -o /path/to/compile_commands.json

# Use clang/clang++ driver instead of zig cc/c++
zig-compile-commands --driver clang

# Forward custom build options to zig build
zig-compile-commands -- -Dtarget=aarch64-linux-gnu --release=fast

# Provide explicit configuration graph path
zig-compile-commands --config .zig-cache/c/9542c6189a74894600b9a99e562d66ff
```
