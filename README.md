# gaffer-macos

Unofficial [Gaffer](https://gafferhq.org) builds for Apple Silicon Macs, with Cycles.
GafferHQ only ships Linux and Windows builds, so this repo has a script that
downloads the Gaffer source, patches it for macOS and builds it.

I'm just a hobby Gaffer user and haven't done anything serious with it. I
wanted Gaffer on my Mac, and I'd like Mac users to be able to get the latest
version. Everything here is vibecoded. It builds and renders, but I haven't
reviewed the patches in depth, so no guarantees.

If something breaks, open an [issue](https://github.com/vitusli/gaffer-macos/issues)
or message me on the [Gaffer Discord](https://discord.gg/sEm8dDw). I'm happy
to fix bugs.

## Download

Get the latest build from [Releases](https://github.com/vitusli/gaffer-macos/releases/latest), then:

```bash
mkdir -p ~/gaffer
tar xzf ~/Downloads/gaffer-1.7.5.0-macos-arm64.tar.gz -C ~/gaffer
xattr -dr com.apple.quarantine ~/gaffer/build-1.7.5.0
~/gaffer/build-1.7.5.0/bin/gaffer
```

The build isn't signed, so without the `xattr` line macOS blocks every `.dylib`
with a "Not Opened" dialog.

## GPU rendering (Metal)

Cycles can render on the GPU via Metal, but it's not the default:

- **Viewer:** switch the Cycles device dropdown from CPU to Metal.
- **Final renders:** in CyclesOptions set Device to Metal *and* Shading System
  to SVM. Metal doesn't support OSL, and Gaffer defaults to OSL, so otherwise
  Cycles silently falls back to CPU (only a warning in the log).

## Known issues

- OSL shaders only render on the CPU (Cycles limitation, same on other platforms).
- The mouse cursor doesn't change shape (e.g. resize arrows). This is a side
  effect of a workaround for a crash on macOS 15+.

## Build from source

Needs an Apple Silicon Mac, Xcode command line tools, [Homebrew](https://brew.sh)
and ~10 GB of disk. The script installs `scons` and `inkscape` via Homebrew.

```bash
git clone https://github.com/vitusli/gaffer-macos.git
cd gaffer-macos
make build   # ~30 min
make run
```

`make build TAG=latest` builds the newest GafferHQ release. Untested versions
may fail, but the script tells you which patch broke.

Using a coding agent (Claude Code, Codex, ...)? Point it at this repo and ask
it to install or build Gaffer for you; [AGENTS.md](AGENTS.md) tells it how.

Gaffer's [Discord](https://discord.gg/sEm8dDw) helped a lot with this.

Not affiliated with GafferHQ. BSD 3-Clause, like Gaffer.
