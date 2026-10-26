# AGENTS.md

This repo builds [Gaffer](https://gafferhq.org) for Apple Silicon Macs (GafferHQ
doesn't ship macOS builds). Everything lives in `build.sh`; `Makefile` wraps it.

## Installing Gaffer for a user

Prefer the prebuilt release, it takes a minute instead of ~30:

```bash
mkdir -p ~/gaffer
curl -L https://github.com/vitusli/gaffer-macos/releases/download/v<version>/gaffer-<version>-macos-arm64.tar.gz | tar xz -C ~/gaffer
~/gaffer/build-<version>/bin/gaffer
```

curl doesn't set the quarantine attribute, so no `xattr` needed. Files
downloaded through a browser do need
`xattr -dr com.apple.quarantine ~/gaffer/build-<version>` (unsigned build).

Building from source instead: `make build && make run` (needs Xcode CLT,
Homebrew, ~10 GB). Tell the user about the Metal/SVM note in the README.

## Keeping up with Gaffer releases

Goal: the latest Gaffer release is always available here for macOS, tested.

1. Compare the newest GafferHQ release
   (`gh release view -R GafferHQ/gaffer --json tagName`) with ours
   (`gh release list -R vitusli/gaffer-macos`). Nothing new: stop.
2. `make build TAG=<version>`. If a patch fails, the build names it. Look at
   what upstream changed in that file and fix the patch in `build.sh`. If
   upstream fixed the problem itself, make the patch a no-op on new sources
   rather than deleting support for older ones.
3. Validate (see below). Don't release if anything fails that you can't
   explain.
4. Bump the default version in `build.sh` (`DEFAULT_TAG`), `Makefile` (`TAG`)
   and the version in the README install commands. Commit.
5. `make package TAG=<version>`, then test the tarball the way a user gets it:
   add a quarantine attribute (`xattr -w com.apple.quarantine "0083;0;Safari;" <file>`),
   extract into a fresh dir, follow the README install steps, run `make smoke`-style
   import check against the extracted build.
6. Publish:
   `gh release create v<version> <tarball> --title "Gaffer <version> for macOS ARM64" --notes "<notes>"`

### Validation

Run against `build-<version>/bin/gaffer`:

- `make smoke TAG=<version>` (imports)
- `bin/gaffer env python smoke_gpu_visibility.py` (Cycles CPU and Metal render
  the same pixel)
- Gaffer's own tests: `bin/gaffer test <Module>` for at least `GafferTest`,
  `GafferSceneTest`, `GafferImageTest`, `GafferOSLTest`, `GafferCyclesTest`,
  `GafferUSDTest`, `GafferVDBTest`, `GafferDispatchTest`. These are slow
  (GafferCyclesTest alone ~4 min), run them in the background. Failures in
  tests for renderers we don't ship (Arnold, 3Delight, Tractor, ...) are fine;
  anything else needs a reason.
- Launch the GUI (`bin/gaffer`), make sure it stays up, and that a Cycles
  viewer render works on CPU and on Metal.

### Release notes

Extremely short. One or two lines. Never repeat GafferHQ's changelog or the
README (install steps, GPU notes, known issues live in the README). Only
mention something if a Gaffer user on macOS needs to know it for *this*
version, e.g. a new limitation or a fixed one. Template:

```
Gaffer <version> for Apple Silicon, built on macOS <N>. See the [README](https://github.com/vitusli/gaffer-macos#readme) for install steps and known issues.
```

## What the patches do

- Clang warning flags so newer Xcode compiles Gaffer
- Install name / rpath fixes for the prebuilt dependencies and built libs
- Cycles viewer overlay (`OutputBuffer.cpp`) ported to the OpenGL 2.1 context
  macOS gives Gaffer
- Fallback shader so unshaded objects don't crash Cycles
- Viewer defaults to SVM instead of OSL, so switching the viewer to Metal works
  (Metal can't do OSL and Cycles silently falls back to CPU)
- Menu shortcut labels (Qt 6 hides them on macOS)
- `NSCursor set` swizzle against a cursor crash on macOS 15+. Side effect: the
  cursor never changes shape. Possibly obsolete since upstream stopped setting
  `DYLD_LIBRARY_PATH`; a synthetic test on macOS 27 didn't crash without it.
  Remove it once confirmed in real GUI use.

Some patches (bin/gaffer launcher, Renderer.cpp shading-system default,
shaderView.py) only matter for 1.6.x sources and are no-ops on 1.7.x.

Verified facts, so you don't re-investigate: OSL works on macOS since Gaffer
1.6.17.0 (expressions, OSLObject, OSLImage, Cycles OSL on CPU). Upstream's
viewer defaults are device `CPU`, shading system `OSL`.
