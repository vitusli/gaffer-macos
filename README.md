# gaffer-macos


Build [Gaffer](https://gafferhq.org) with Cycles rendering on macOS Apple Silicon.

This repo contains a self-contained build script that downloads Gaffer 1.6.19.1 source,
applies patches to fix macOS-specific issues, downloads pre-built dependencies, and
compiles everything with SCons.

## Pre-built binary

A ready-to-use build for Apple Silicon is available on the
[Releases page](https://github.com/vitusli/gaffer-macos/releases/latest).

## Build from source

```
git clone https://github.com/vitusli/gaffer-macos.git
cd gaffer-macos
make build   # ~30 min first time
make run
```

## Requirements

- macOS on Apple Silicon
- Xcode command-line tools (`xcode-select --install`)
- [Homebrew](https://brew.sh)
- ~10 GB disk space

The build script will install `scons` and `inkscape` via Homebrew if not present.

## Make targets

| Target | Description |
|--------|-------------|
| `make build` | Download, patch, and build Gaffer |
| `make run` | Launch Gaffer |
| `make smoke` | Quick import test |
| `make clean` | Remove source + build directories |

## Known limitations

- CPU rendering only
- The Cycles viewer defaults to SVM on macOS; OSL can be selected manually in newer Gaffer builds
- **OSL freezes on ARM64 macOS** -- OSL uses LLVM 15 whose legacy pass manager hangs/crashes on Apple Silicon during JIT compilation (`OSLShaderManager::device_update_specific`). This is why the viewer defaults to SVM. Forcing OSL would require rebuilding against LLVM 16+.
- OpenGL 2.1

## What the patches fix

### Cycles viewer SVM default

Older Gaffer builds could crash in OSL/LLVM on ARM64 macOS. Gaffer is patched to
default the interactive viewer to Cycles' built-in SVM shading system on macOS.
Gaffer 1.6.17.0 and newer include macOS OSL fixes, so the renderer itself keeps
OSL available for manual selection.

### OpenGL viewport crash (SIGSEGV)

macOS provides only an OpenGL 2.1 compatibility context. Gaffer's viewport code
uses `GL_TEXTURE_BUFFER` and `glTexBuffer` (GL 3.1+) which resolve to NULL function
pointers. The patches replace these with `GL_TEXTURE_1D` / `glTexImage1D` and
downgrade GLSL shaders from `#version 330 compatibility` to `#version 120` with
`GL_EXT_gpu_shader4`.

### Other fixes

- **Python.framework launcher** -- macOS bundles Python as a framework; the
  `bin/gaffer` launcher is patched to set `PYTHONHOME` correctly.
- **`fmt::format` enum error** -- `TweakPlug.cpp` passes an enum to `fmt::format`
  which newer clang rejects; patched to use the string conversion.
- **DiffuseBsdf fallback** -- empty Cycles shader graphs crash the SVM compiler;
  a DiffuseBsdf node is inserted as fallback.
- **Expression engine** -- two OSL expressions in `cyclesViewerSettings.gfr` are
  changed to Python expressions.
- **Dependency path relocation** -- pre-built dependencies ship with hardcoded
  `/Users/admin/build/...` paths; `install_name_tool` rewrites them.
- **Build-time RPATH repair** -- Python extension modules and Gaffer dylibs are
  repaired during a one-time SCons retry if the export phase cannot load them.
- **macOS 15+/Tahoe cursor crash workaround** -- an AppKit cursor swizzle is
  loaded from bundled Python startup to avoid ImageIO using Gaffer's bundled
  libpng through flat namespace lookup.
- **Cycles viewer restart on shading-system changes** -- switching between SVM
  and OSL recreates the Cycles viewer renderer so the new mode takes effect.
- **Clang warning suppression** -- `-Wno-error=cast-function-type-mismatch` and
  `-Wno-unknown-warning-option` added for newer Apple Clang versions.

## Project structure

```
gaffer-macos/
  build.sh        # Main build script with all patches
  Makefile         # Convenience targets
  .gitignore       # Ignores release-*/, build-*/
```

After building:

```
  release-1.6.19.1/   # Patched Gaffer source (kept for incremental rebuilds)
  build-1.6.19.1/     # Build output + dependencies (the Gaffer installation)
```

## Gatekeeper note (downloaded builds)

If a downloaded/extracted build triggers many macOS "Not Opened" dialogs for
`.dylib` files, remove quarantine attributes from both files and symlinks:

```bash
BUILD_DIR="./build-<TAG>"
chmod -R u+w "$BUILD_DIR"
xattr -dr com.apple.quarantine "$BUILD_DIR"
xattr -drs com.apple.quarantine "$BUILD_DIR"
```

Example:

```bash
BUILD_DIR="/Users/<you>/Downloads/build-1.6.19.1"
chmod -R u+w "$BUILD_DIR"
xattr -dr com.apple.quarantine "$BUILD_DIR"
xattr -drs com.apple.quarantine "$BUILD_DIR"
```

## Community

Work like this depends on help from Gaffer's friendly community on Discord. Their
shared testing, build notes, and troubleshooting make these macOS builds possible.
Join the community here: https://discord.gg/sEm8dDw

## License

The build script and patches in this repository are provided under the
[BSD 3-Clause License](https://opensource.org/licenses/BSD-3-Clause),
matching Gaffer's own license. Gaffer itself is copyright its respective authors.
