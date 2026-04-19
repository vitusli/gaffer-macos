# gaffer-macos


Build [Gaffer](https://gafferhq.org) with Cycles rendering on macOS Apple Silicon (M-series).

This repo contains a self-contained build script that downloads Gaffer 1.6.14.2 source,
applies patches to fix macOS-specific issues, downloads pre-built dependencies, and
compiles everything with SCons.

## Quick start

```
git clone https://github.com/vitusli/gaffer-macos.git
cd gaffer-macos
make build   # ~30 min first time
make run
```

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
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
- Viewport rendering only
- No OSL
- OpenGL 2.1

## What the patches fix

### Cycles OSL/LLVM crash (SIGTRAP)

OSL 1.14.5 bundles LLVM 15.0.7 which crashes on ARM64 macOS in the legacy pass
manager (`EXC_BREAKPOINT` in `llvm::PMDataManager::addLowerLevelRequiredPass`).
Gaffer is patched to default to Cycles' built-in SVM shading system on macOS
instead of OSL.

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
  changed to Python expressions (OSL is unavailable on macOS).
- **Dependency path relocation** -- pre-built dependencies ship with hardcoded
  `/Users/admin/build/...` paths; `install_name_tool` rewrites them.
- **Clang warning suppression** -- `-Wno-error=cast-function-type-mismatch` added
  for newer Apple Clang versions.

## Project structure

```
gaffer-macos/
  build.sh        # Main build script with all patches
  Makefile         # Convenience targets
  .gitignore       # Ignores release-*/, build-*/, gaffer-launcher
```

After building:

```
  release-1.6.14.2/   # Patched Gaffer source (kept for incremental rebuilds)
  build-1.6.14.2/     # Build output + dependencies (the Gaffer installation)
  gaffer-launcher     # Shell wrapper to launch Gaffer
```

## License

The build script and patches in this repository are provided under the
[BSD 3-Clause License](https://opensource.org/licenses/BSD-3-Clause),
matching Gaffer's own license. Gaffer itself is copyright its respective authors.
