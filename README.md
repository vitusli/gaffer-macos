# gaffer-macos


Build [Gaffer](https://gafferhq.org) with Cycles rendering on macOS Apple Silicon.

This repo contains a self-contained build script that downloads Gaffer source,
applies patches to fix macOS-specific issues, downloads pre-built dependencies, and
compiles everything with SCons. It defaults to the latest tested version,
**Gaffer 1.7.5.0**, and also builds 1.6.19.1 via `TAG=1.6.19.1`.

## Pre-built binary

A ready-to-use build for Apple Silicon is available on the
[Releases page](https://github.com/vitusli/gaffer-macos/releases/latest). You need to remove quarantine attributes on the downloaded build to avoid "Not Opened". Below are instructions for the pre-built binary.

## Known limitations

- Cycles OSL is unstable on Apple Silicon in this build path; viewer defaults to SVM
- No OSL shader compile support in Metal mode
- OpenGL 2.1

## Build from source

```
git clone https://github.com/vitusli/gaffer-macos.git
cd gaffer-macos
make build   # ~30 min first time, builds Gaffer 1.7.5.0
make run
```

To build a different release:

```
make build TAG=1.6.19.1   # the older 1.6.x line
make run   TAG=1.6.19.1

make build TAG=latest     # whatever GafferHQ released most recently
```

`TAG=latest` resolves the newest GafferHQ release at build time. Every patch
checks its own result, so an untested release fails the build with the name of
the patch that no longer applies instead of producing a Gaffer that crashes on
first render.

## Requirements

- macOS on Apple Silicon
- Xcode command-line tools (`xcode-select --install`)
- [Homebrew](https://brew.sh)
- ~10 GB disk space

The build script will install `scons` and `inkscape` via Homebrew if not present.

## Cycles device selection on macOS

The Metal device is available to Cycles out of the box -- `GafferCycles.devices`
lists it alongside the CPU, and batch renders can select it.

**The interactive Viewer still defaults to CPU.** That is Gaffer's own default
(`startup/gui/cyclesViewerSettings.gfr` ships `device` with a default of `CPU`),
not something this build changes. If you want the GPU in the Viewer, pick the
Metal entry in the Viewer's device dropdown -- otherwise you are path tracing on
the CPU without noticing.

Measured on an M4 Pro (16 GPU cores), identical scene and sample count:

| `cycles:device` | wall time | GPU utilisation | CPU time |
|---|---|---|---|
| `METAL:00` | 1.96 s | 78-85 % | 1.97 s |
| `CPU` | 6.29 s | ~3 % | 210 s |

Device strings are patterns, not device names: `CPU`, `METAL:00` (first Metal
device), `CPU METAL:00` (both) or `METAL:*` (all Metal devices) -- the values
behind the dropdown's entries. Passing the name from `GafferCycles.devices`
instead does *not* raise an error; Cycles logs

```
WARNING : CyclesRenderer : No devices matching "..." found, reverting to CPU.
```

and renders on the CPU. Worth grepping for if a GPU render seems slow.

To force CPU-only mode for debugging or compatibility:

```bash
GAFFER_CYCLES_FORCE_CPU=1 ./build-1.7.5.0/bin/gaffer
```

## Make targets

| Target | Description |
|--------|-------------|
| `make build` | Download, patch, and build Gaffer |
| `make run` | Launch Gaffer |
| `make smoke` | Quick import test |
| `make package` | Tar the build into `gaffer-<TAG>-macos-arm64.tar.gz` for a release |
| `make clean` | Remove source + build directories |

### Optional GPU visibility smoke test

This repository includes a deterministic Cycles test that verifies geometry and
material are visible on both CPU and METAL devices:

```bash
./build-1.7.5.0/bin/gaffer env python smoke_gpu_visibility.py
```

Expected result includes:

- `CPU session: CPU ...`
- `METAL session: METAL_...`
- `OK: Cycles METAL renders visible geometry/material`

## Project structure

```
gaffer-macos/
  build.sh        # Main build script with all patches
  Makefile         # Convenience targets
  .gitignore       # Ignores release-*/, build-*/
```

After building:

```
  release-1.xxx/   # Patched Gaffer source (kept for incremental rebuilds)
  build-1.xxx/     # Build output + dependencies (the Gaffer installation)
```

## Gatekeeper note (downloaded builds)

If a downloaded/extracted build triggers many macOS "Not Opened" dialogs for
`.dylib` files, remove quarantine attributes from both files and symlinks:


```bash
BUILD_DIR="$HOME/Downloads/build-1.7.5.0"
chmod -R u+w "$BUILD_DIR"
xattr -dr com.apple.quarantine "$BUILD_DIR"
xattr -drs com.apple.quarantine "$BUILD_DIR"
```

## Community

Work like this depends on help from Gaffer's friendly community on Discord. Their
shared testing, build notes, and troubleshooting make these macOS builds possible.
Join the community here: https://discord.gg/sEm8dDw

## Other fixes (details)

<details>
<summary>Show patch details</summary>


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

### 1.7.x-specific notes

Several 1.6.x macOS patches were upstreamed into Gaffer 1.7.x directly (the
Python.framework launcher, `DYLD_LIBRARY_PATH` removal, and OSL-everywhere
`Renderer.cpp` defaults), so the patch script quietly no-ops those steps on
1.7.x source. What's new for 1.7.x:

- **Bare `libz` install names** -- the `platform25` Cortex 10.7.1.3 dependency
  bundle ships several dylibs (`libfreetype`, `libOpenColorIO`, `libOpenImageIO`,
  `libopenvdb`, ...) with a bare `libz.1.dylib` reference (no `@rpath/` prefix),
  which fails `dlopen` once Gaffer's own Python runs mid-build. The dependency
  relocation pass now rewrites any bare (non-absolute, non-`@`) install name to
  `@rpath/<basename>`, not just absolute build-machine paths.
- **clang 21 warning** -- `-Wno-error=implicit-const-int-float-conversion` is
  added alongside the existing suppressions; it's new in Xcode 27's clang and
  fires in the new (1.7.x) `PrimitiveVariableType.cpp` on half/int conversions
  at `numeric_limits` boundaries.
- **`convertWalk` signature change** -- `ShaderNetworkAlgo.cpp`'s DiffuseBsdf
  fallback patch matches both the 1.6.x (`shaderManager`) and 1.7.x (`scene`)
  parameter name for the function it patches.

### 1.7.5.0-specific notes

- **Cortex 10.7.4.0** -- 1.7.5.0 pulls a newer dependency bundle than 1.7.2.0's
  10.7.1.3. The bare-install-name fix above still applies to it.
- **Shader assignment moved** -- the `"defaultsurface"` guard used to patch
  `Renderer.cpp`; from 1.7.3.0 that code lives in the new
  `IECoreCyclesPreview/Attributes.cpp` at a different indentation level. The
  patch now locates it by content in either file instead of by exact text.
- **Bundled interpreter discovered, not assumed** -- the `bin/python` wrapper is
  generated from whichever `python3.x` the dependency bundle actually ships
  (3.11 on platform25) rather than a hard-coded version.
- **Patches verify themselves** -- each patch asserts its own end state, so a
  patch that upstream has already applied is a silent no-op, while a patch whose
  target has moved aborts the build and names itself. This is what makes
  `TAG=latest` safe to offer.

</details>

## License

The build script and patches in this repository are provided under the
[BSD 3-Clause License](https://opensource.org/licenses/BSD-3-Clause),
matching Gaffer's own license. Gaffer itself is copyright its respective authors.
