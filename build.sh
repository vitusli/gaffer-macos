#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# build.sh -- Build Gaffer with Cycles for macOS Apple Silicon
#
# Downloads Gaffer source, applies macOS-specific patches for Cycles,
# viewport rendering and dependency relocation, downloads pre-built
# dependencies, and compiles everything with SCons.
#
# Usage:
#   bash build.sh            # builds Gaffer 1.7.6.0 (latest tested)
#   TAG=latest bash build.sh # resolves the newest GafferHQ release
#   TAG=1.6.19.1 bash build.sh
#
# Requirements: Xcode CLI tools, Homebrew, ~10 GB disk, ~30 min.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# Latest Gaffer release this script has been built and smoke-tested against.
DEFAULT_TAG="1.7.6.0"

TAG="${TAG:-$DEFAULT_TAG}"
if [ "$TAG" = "latest" ]; then
  echo "Resolving latest GafferHQ release..."
  TAG="$(
    curl -fsSL "https://api.github.com/repos/GafferHQ/gaffer/releases/latest" |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
  )"
  echo "  -> $TAG"
  if [ "$TAG" != "$DEFAULT_TAG" ]; then
    echo "  NOTE: $TAG is newer than the tested $DEFAULT_TAG. Patches are"
    echo "        verified at apply time, so this will fail loudly rather"
    echo "        than silently produce a broken build."
  fi
fi

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="$ROOT_DIR/release-$TAG"
BUILD_DIR="$ROOT_DIR/build-$TAG"
GAFFER="$BUILD_DIR/bin/gaffer"

# ── helpers ──────────────────────────────────────────────────────────

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Missing required command: $1" >&2
    exit 1
  }
}

ensure_brew_pkg() {
  local pkg="$1"
  if brew list --versions "$pkg" >/dev/null 2>&1; then
    return
  fi
  echo "Installing $pkg via Homebrew..."
  brew install "$pkg"
}

step() {
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════════"
}

# ── 1. Download Gaffer source ────────────────────────────────────────

ensure_source() {
  step "Source (Gaffer $TAG)"
  if [ -f "$RELEASE_DIR/SConstruct" ]; then
    echo "Already present at $RELEASE_DIR"
    return
  fi
  echo "Downloading..."
  local tarball="$ROOT_DIR/gaffer-$TAG.tar.gz"
  curl -fSL "https://github.com/GafferHQ/gaffer/archive/refs/tags/$TAG.tar.gz" -o "$tarball"
  mkdir -p "$RELEASE_DIR"
  tar xf "$tarball" -C "$RELEASE_DIR" --strip-components=1
  rm -f "$tarball"
  echo "Extracted to $RELEASE_DIR"
}

# ── 2. Download pre-built dependencies ──────────────────────────────

download_dependencies() {
  step "Dependencies"
  if [ -d "$BUILD_DIR/lib" ]; then
    echo "Already present at $BUILD_DIR"
    return
  fi
  python3 "$RELEASE_DIR/.github/workflows/main/installDependencies.py" \
    --dependenciesDir "$BUILD_DIR"
}

# ── 3. Fix Mach-O install paths ─────────────────────────────────────

relocate_dependencies() {
  step "Relocating dependency paths"
  if [ -f "$BUILD_DIR/.relocated" ]; then
    echo "Already relocated (marker file present)"
    return
  fi
  python3 - "$BUILD_DIR" <<'PY'
import os, subprocess, sys

root = sys.argv[1]
patched = 0

def relocated_path(path):
    if path.startswith("@"):
        return path
    if not path.startswith("/"):
        # Bare/relative references (e.g. "libz.1.dylib", "lib/libIECore.dylib")
        # break dlopen once files move away from the original build tree.
        # Cortex 10.7.1.3's platform25 dependency bundle ships several of
        # these (libz in particular) with no "@rpath/" prefix at all.
        return "@rpath/" + os.path.basename(path)
    if path.startswith(root + "/"):
        return path

    stripped = path.rstrip("/")
    for directory in ("/lib", "/Frameworks", "/python"):
        if stripped.endswith(directory):
            prefix = stripped[: -len(directory)]
            if "/build/" in prefix or "gafferDependencies" in prefix or "cortex-" in prefix:
                return root + directory + ("/" if path.endswith("/") else "")

    for marker in ("/lib/", "/Frameworks/", "/python/"):
        if marker in path:
            prefix, suffix = path.split(marker, 1)
            if "/build/" in prefix or "gafferDependencies" in prefix or "cortex-" in prefix:
                return root + marker + suffix

    return path

def is_macho_candidate(path):
    name = os.path.basename(path)
    if name.startswith("."):
        return False

    ext = os.path.splitext(name)[1]
    if ext in { ".dylib", ".so", ".bundle" }:
        return True

    normalized = path.replace(os.sep, "/")
    if "/bin/" in normalized and not ext:
        return True

    if ".framework/Versions/" in normalized and not ext:
        return True

    return False

for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if not is_macho_candidate(path):
            continue
        try:
            info = subprocess.check_output(
                ["file", "-b", path], text=True, stderr=subprocess.DEVNULL
            )
        except subprocess.CalledProcessError:
            continue
        if "Mach-O" not in info:
            continue
        changed = False
        try:
            ids = subprocess.check_output(
                ["otool", "-D", path], text=True, stderr=subprocess.DEVNULL
            ).splitlines()[1:]
        except subprocess.CalledProcessError:
            ids = []
        for ident in ids:
            new_ident = relocated_path(ident)
            if new_ident != ident:
                subprocess.check_call(
                    ["install_name_tool", "-id", new_ident, path]
                )
                changed = True
        try:
            libs = subprocess.check_output(
                ["otool", "-L", path], text=True, stderr=subprocess.DEVNULL
            ).splitlines()[1:]
        except subprocess.CalledProcessError:
            libs = []
        for line in libs:
            dep = line.strip().split(" (compatibility version", 1)[0]
            new_dep = relocated_path(dep)
            if new_dep != dep:
                subprocess.check_call(
                    ["install_name_tool", "-change", dep, new_dep, path]
                )
                changed = True
        # Fix LC_RPATH entries
        try:
            rpath_out = subprocess.check_output(
                ["otool", "-l", path], text=True, stderr=subprocess.DEVNULL
            )
        except subprocess.CalledProcessError:
            rpath_out = ""
        for line in rpath_out.splitlines():
            line = line.strip()
            if line.startswith("path "):
                old_rpath = line.split("path ", 1)[1].split(" (offset", 1)[0].strip()
                new_rpath = relocated_path(old_rpath)
                if new_rpath == old_rpath:
                    continue
                try:
                    subprocess.check_call(
                        ["install_name_tool", "-rpath", old_rpath, new_rpath, path]
                    )
                    changed = True
                except subprocess.CalledProcessError:
                    pass

        if changed:
            patched += 1

print(f"Relocated {patched} Mach-O binaries")
PY
  touch "$BUILD_DIR/.relocated"
}

# ── 4. Apply source patches ─────────────────────────────────────────
#
# All patches are applied as Python string replacements on the
# freshly-downloaded source.  They are idempotent (safe to re-run).
#
# What we fix:
#   a) SConstruct     -- suppress new clang warnings-as-errors
#   b) TweakPlug.cpp  -- fmt::format type fix
#   c) bin/gaffer     -- macOS Python.framework launcher
#   d) Renderer.cpp   -- fallback fixes while keeping explicit OSL usable
#   e) ShaderNetworkAlgo.cpp -- DiffuseBsdf fallback for empty shaders
#   f) cyclesViewerSettings.gfr -- SVM default + Python expressions
#   g) shaderView.py  -- keep OSL shader previews in OSL mode
#   h) OutputBuffer.cpp -- GL_TEXTURE_1D, GLSL 1.20, null checks
#   i) macosDeviceSelection.py -- default to all devices, optional CPU fallback
#   j) PaintTool.cpp  -- GLSL 1.20 paint visualiser
#   j2) DepthRender.cpp -- depth-only framebuffer completeness
#   k) VisualiserTool.cpp -- GLSL 1.20 visualisers, CPU vertex label visibility

apply_source_patches() {
  step "Patching source"
  python3 - "$RELEASE_DIR" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])

# Every patch below is a string replacement against a specific upstream
# revision, so a Gaffer release that moves the code out from under us would
# otherwise leave a silently unpatched (crashing) build. Each patch therefore
# asserts its own end state: either our replacement landed, or upstream
# already does the equivalent thing. Anything else aborts the build.
problems = []

def expect( label, condition, detail ) :

	if condition :
		print( f"  [{label}] ok" )
	else :
		print( f"  [{label}] FAILED -- {detail}" )
		problems.append( label )

# ── a) SConstruct: suppress warnings-as-errors on newer clang ──
#
# clang 21 (Xcode 27) adds two warnings that Gaffer's -Werror turns fatal:
#   -Wno-unknown-warning-option                    -- future-proofs against
#                                                      clang version skew
#   -Wno-error=implicit-const-int-float-conversion -- new in clang 21, hits
#                                                      PrimitiveVariableType.cpp
#                                                      (half<->int at numeric_limits
#                                                      boundaries; new file in 1.7.x)
sconstruct = root / "SConstruct"
text = sconstruct.read_text()
extra_flags = '"-Wno-unknown-warning-option", "-Wno-error=implicit-const-int-float-conversion"'
if '-Wno-error=cast-function-type-mismatch' in text and '-Wno-unknown-warning-option' not in text:
    text = text.replace(
        '"-Wno-error=cast-function-type-mismatch" ]',
        '"-Wno-error=cast-function-type-mismatch", ' + extra_flags + ' ]',
        1,
    )
elif '-Wno-error=cast-function-type-mismatch' not in text:
    text = re.sub(
        r'(env\.Append\( CXXFLAGS = \[ "-DBOOST_NO_CXX98_FUNCTION_BASE", "-D_HAS_AUTO_PTR_ETC=0" \] \)\n)',
        r'\1\t\tenv.Append( CXXFLAGS = [ "-Wno-error=deprecated-declarations", "-Wno-error=cast-function-type-mismatch", ' + extra_flags + r' ] )\n',
        text, count=1,
    )
elif '-Wno-error=implicit-const-int-float-conversion' not in text:
    # Already patched by an older run of this script (before this flag existed).
    text = text.replace(
        '"-Wno-error=cast-function-type-mismatch", "-Wno-unknown-warning-option" ]',
        '"-Wno-error=cast-function-type-mismatch", ' + extra_flags + ' ]',
        1,
    )
sconstruct.write_text(text)
expect(
	"a SConstruct clang flags",
	'-Wno-error=implicit-const-int-float-conversion' in text,
	"could not add clang warning suppressions; SConstruct's CXXFLAGS block moved"
)

# ── a2) SConstruct: add @loader_path rpath for macOS shared libs ──
text = sconstruct.read_text()
if '@loader_path/../lib' not in text:
    text = text.replace(
        'env["GAFFER_PLATFORM"] = "macos"\n\n\telse :',
        'env["GAFFER_PLATFORM"] = "macos"\n'
        '\t\tenv.Append( SHLINKFLAGS = [ "-Wl,-rpath,@loader_path/../lib", "-Wl,-rpath,@loader_path/../../lib" ] )\n\n'
        '\telse :',
    )
    sconstruct.write_text(text)
expect(
	"a2 SConstruct rpath",
	'@loader_path/../lib' in sconstruct.read_text(),
	"could not add @loader_path rpaths; the macOS GAFFER_PLATFORM branch moved"
)

# ── b) TweakPlug.cpp: fmt::format enum fix ──
tweak = root / "src/Gaffer/TweakPlug.cpp"
text = tweak.read_text()
text = re.sub(
    r'throw\s+IECore::Exception\(\s*fmt::format\(\s*"Not a valid tweak mode: \{\}\.",\s*mode\s*\)\s*\);',
    'throw IECore::Exception( fmt::format( "Not a valid tweak mode: {}.", TweakPlug::modeToString( mode ) ) );',
    text,
    count=1,
)
tweak.write_text(text)
expect(
	"b TweakPlug.cpp",
	'TweakPlug::modeToString( mode )' in text or 'Not a valid tweak mode' not in text,
	"fmt::format( mode ) is still unformattable; the throw statement moved"
)

# ── c) bin/gaffer: macOS Python.framework launcher ──
#
# 1.7.x upstream already exports PYTHONHOME from the bundled framework and
# execs `$rootDir/bin/python` (the wrapper we write in write_python_wrappers),
# so the 1.6.x launcher rewrite below only runs on older sources.
launcher = root / "bin/gaffer"
text = launcher.read_text()
pythonHome = 'PYTHONHOME="$rootDir/lib/Python.framework/Versions/Current"'
if pythonHome not in text:
    text = re.sub(
        r'# Unset PYTHONHOME to make sure our internal Python build is used in\n# preference to anything in the external environment\.\nunset PYTHONHOME\n',
        'gafferPythonHome="$rootDir/lib/Python.framework/Versions/Current"\n'
        'gafferPython="$rootDir/bin/python"\n\n'
        '# Force our bundled Python framework so macOS can locate its standard library\n'
        '# and extension modules reliably.\n'
        'export PYTHONHOME="$gafferPythonHome"\n',
        text, count=1,
    )
    text = text.replace(
        'exec $GAFFER_DEBUGGER `which python` "$rootDir/bin/_gaffer.py" "$@"',
        'exec $GAFFER_DEBUGGER "$gafferPython" "$rootDir/bin/_gaffer.py" "$@"',
    )
    text = text.replace(
        'exec python "$rootDir/bin/_gaffer.py" "$@"',
        'exec "$gafferPython" "$rootDir/bin/_gaffer.py" "$@"',
    )
# Keep DYLD_LIBRARY_PATH unset on macOS. It pollutes flat namespace lookups and
# can make ImageIO pick up Gaffer's bundled libpng on Sequoia/Tahoe.
text = text.replace(
    '\tprependToPath "$rootDir/lib" DYLD_FRAMEWORK_PATH\n\tprependToPath "$rootDir/lib" DYLD_LIBRARY_PATH\nfi',
    '\tprependToPath "$rootDir/lib" DYLD_FRAMEWORK_PATH\nfi',
)
launcher.write_text(text)
expect(
	"c bin/gaffer PYTHONHOME",
	pythonHome in text,
	"launcher does not point PYTHONHOME at the bundled Python.framework"
)
expect(
	"c bin/gaffer DYLD_LIBRARY_PATH",
	"DYLD_LIBRARY_PATH" not in text,
	"launcher still sets DYLD_LIBRARY_PATH, which breaks ImageIO on Sequoia/Tahoe"
)

# ── i) macosDeviceSelection.py: keep Metal enabled, optional CPU fallback ──
startup = root / "startup/GafferCycles/macosDeviceSelection.py"
startup.write_text(
    'import os\n'
    'import sys\n\n'
    'if sys.platform == "darwin" and os.environ.get( "GAFFER_CYCLES_FORCE_CPU", "0" ) in { "1", "true", "TRUE", "yes", "YES" } :\n\n'
    '\timport IECore\n'
    '\timport GafferCycles\n\n'
    '\tcpuDevice = GafferCycles.devices.get( "CPU" )\n'
    '\tif cpuDevice is not None :\n'
    '\t\tGafferCycles.devices = IECore.CompoundData( { "CPU" : cpuDevice } )\n'
)

legacyStartup = root / "startup/GafferCycles/macosCPUFallback.py"
if legacyStartup.exists() :
    legacyStartup.unlink()

expect(
	"i macosDeviceSelection.py",
	"GAFFER_CYCLES_FORCE_CPU" in startup.read_text(),
	"could not write the Cycles device selection startup file"
)

# ── d) Renderer.cpp: fallback fixes while keeping explicit OSL usable ──

# d.1) Null-out "defaultsurface" shader name
#
# The default IECoreScene::Shader constructor uses the name "defaultsurface",
# which is not a valid Cycles shader. Treat it as "no shader assigned" so the
# facing-ratio fallback is used instead, avoiding an empty ShaderGraph that
# crashes Cycles' SVM compiler.
#
# This lived in Renderer.cpp up to 1.7.2.0 and moved to Attributes.cpp in
# 1.7.3.0, at a different indentation level, so find it by content.
defaultSurfaceMarker = 'getName() == "defaultsurface"'
defaultSurfaceOk = False
for candidate in (
    root / "src/GafferCycles/IECoreCyclesPreview/Attributes.cpp",
    root / "src/GafferCycles/IECoreCyclesPreview/Renderer.cpp",
):
    if not candidate.exists():
        continue
    ctext = candidate.read_text()
    if defaultSurfaceMarker in ctext:
        defaultSurfaceOk = True  # already applied by a previous run
        break
    match = re.search(
        r'^([\t ]*)(surfaceShaderAttribute = surfaceShaderAttribute \? surfaceShaderAttribute : '
        r'attribute<IECoreScene::ShaderNetwork>\( g_surfaceShaderAttributeName, attributes \);\n)'
        r'([\t ]*if\( !surfaceShaderAttribute && !volumeShaderAttribute \)\n)',
        ctext, re.MULTILINE
    )
    if not match:
        continue
    indent = match.group(1)
    guard = "".join(
        indent + line + "\n" for line in (
            'if(',
            '\tsurfaceShaderAttribute &&',
            '\tsurfaceShaderAttribute->getOutput().shader.string().size() &&',
            '\tsurfaceShaderAttribute->getShader( surfaceShaderAttribute->getOutput().shader )'
                '->getName() == "defaultsurface"',
            ')',
            '{',
            '\tsurfaceShaderAttribute = nullptr;',
            '}',
        )
    )
    candidate.write_text(
        ctext.replace(match.group(0), indent + match.group(2) + guard + match.group(3), 1)
    )
    defaultSurfaceOk = defaultSurfaceMarker in candidate.read_text()
    break

expect(
    "d1 defaultsurface fallback",
    defaultSurfaceOk,
    "could not find the surface shader attribute lookup in Attributes.cpp or "
    "Renderer.cpp; without this guard Cycles crashes on unshaded geometry"
)

renderer = root / "src/GafferCycles/IECoreCyclesPreview/Renderer.cpp"
rtxt = renderer.read_text()

# d.2) Leave renderer defaults as OSL. Viewer settings opt into SVM on macOS,
# but explicit OSL renders must remain possible.
rtxt = rtxt.replace(
    'ccl::SessionParams defaultSessionParams( IECoreScenePreview::Renderer::RenderType renderType )\n'
    '{\n'
    '\tccl::SessionParams params;\n'
    '\tparams.device = firstCPUDevice();\n'
    '#ifdef __APPLE__\n'
    "\t// OSL's LLVM 15 legacy pass manager crashes on ARM64 macOS.\n"
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_SVM;\n'
    '#else\n'
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_OSL;\n'
    '#endif\n',
    'ccl::SessionParams defaultSessionParams( IECoreScenePreview::Renderer::RenderType renderType )\n'
    '{\n'
    '\tccl::SessionParams params;\n'
    '\tparams.device = firstCPUDevice();\n'
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_OSL;\n',
    1
)

rtxt = rtxt.replace(
    'ccl::SceneParams defaultSceneParams( IECoreScenePreview::Renderer::RenderType renderType )\n'
    '{\n'
    '\tccl::SceneParams params;\n'
    '#ifdef __APPLE__\n'
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_SVM;\n'
    '#else\n'
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_OSL;\n'
    '#endif\n',
    'ccl::SceneParams defaultSceneParams( IECoreScenePreview::Renderer::RenderType renderType )\n'
    '{\n'
    '\tccl::SceneParams params;\n'
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_OSL;\n',
    1
)

# d.3) Add g_defaultShadingSystem constant
rtxt = rtxt.replace(
    'IECore::InternedString g_shadingsystemSVM( "SVM" );\n\n'
    '#ifdef __APPLE__\n'
    'const char *g_defaultShadingSystem = "SVM";\n'
    '#else\n'
    'const char *g_defaultShadingSystem = "OSL";\n'
    '#endif\n\n'
    'ccl::ShadingSystem nameToShadingSystemEnum(',
    'IECore::InternedString g_shadingsystemSVM( "SVM" );\n\n'
    'const char *g_defaultShadingSystem = "OSL";\n\n'
    'ccl::ShadingSystem nameToShadingSystemEnum(',
    1
)
rtxt = rtxt.replace(
    'IECore::InternedString g_shadingsystemSVM( "SVM" );\n\n'
    'ccl::ShadingSystem nameToShadingSystemEnum(',
    'IECore::InternedString g_shadingsystemSVM( "SVM" );\n\n'
    'const char *g_defaultShadingSystem = "OSL";\n\n'
    'ccl::ShadingSystem nameToShadingSystemEnum(',
    1
)

# d.4) Use g_defaultShadingSystem in option lookups
rtxt = rtxt.replace(
    'params.shadingsystem = nameToShadingSystemEnum( optionValue<string>( g_shadingsystemOptionName, "OSL", modified ) );',
    'params.shadingsystem = nameToShadingSystemEnum( optionValue<string>( g_shadingsystemOptionName, g_defaultShadingSystem, modified ) );',
)

renderer.write_text(rtxt)
expect(
    "d Renderer.cpp OSL default",
    'const char *g_defaultShadingSystem = "OSL";' in rtxt
        and '#ifdef __APPLE__\nconst char *g_defaultShadingSystem' not in rtxt,
    "could not force the renderer's default shading system to OSL"
)
expect(
    "d Renderer.cpp option default",
    'optionValue<string>( g_shadingsystemOptionName, g_defaultShadingSystem, modified )' in rtxt,
    "the cycles:shadingsystem option still hard-codes its default"
)
expect(
    "d Renderer.cpp session params",
    'params.shadingsystem = ccl::SHADINGSYSTEM_SVM;\n#else' not in rtxt,
    "default session/scene params still force SVM on __APPLE__"
)

# ── e) ShaderNetworkAlgo.cpp: DiffuseBsdf fallback ──
# convertWalk()'s 4th argument was renamed/retyped from `shaderManager`
# (1.6.x) to `scene` (1.7.x+) upstream -- match either.
snalgo = root / "src/GafferCycles/IECoreCyclesPreview/ShaderNetworkAlgo.cpp"
stxt = snalgo.read_text()
for arg_name in ( "shaderManager", "scene" ):
    old_sna = (
        f'\t\tccl::ShaderNode *node = convertWalk( toConvert->getOutput(), toConvert.get(), namePrefix, {arg_name}, graph.get(), converted );\n'
        '\n'
        '\t\tif( node )\n'
    )
    new_sna = (
        f'\t\tccl::ShaderNode *node = convertWalk( toConvert->getOutput(), toConvert.get(), namePrefix, {arg_name}, graph.get(), converted );\n'
        '\n'
        '\t\tif( !node && name == "surface" )\n'
        '\t\t{\n'
        '\t\t\tnode = graph->create_node<ccl::DiffuseBsdfNode>();\n'
        '\t\t}\n'
        '\n'
        '\t\tif( node )\n'
    )
    if old_sna in stxt:
        stxt = stxt.replace(old_sna, new_sna, 1)
        break
snalgo.write_text(stxt)
expect(
    "e ShaderNetworkAlgo.cpp",
    "ccl::DiffuseBsdfNode" in stxt,
    "could not add the DiffuseBsdf fallback; convertWalk()'s signature changed again"
)

# ── f) cyclesViewerSettings.gfr: SVM default + Python expressions ──
vset = root / "startup/gui/cyclesViewerSettings.gfr"
vtxt = vset.read_text()
vtxt = vtxt.replace(
    """__children["ViewerSettings"].addChild( Gaffer.StringPlug( "shadingSystem", defaultValue = 'OSL',""",
    """__children["ViewerSettings"].addChild( Gaffer.StringPlug( "shadingSystem", defaultValue = 'SVM',""",
    1
)
vtxt = vtxt.replace(
    """__children["ViewerSettings"]["Expression3"]["__engine"].setValue( 'OSL' )\n__children["ViewerSettings"]["Expression3"]["__expression"].setValue( 'parent.__out.p0 = !parent.__in.p0;' )\n__children["ViewerSettings"]["Expression5"]["__engine"].setValue( 'OSL' )\n__children["ViewerSettings"]["Expression5"]["__expression"].setValue( 'parent.__out.p0 = parent.__in.p0;' )""",
    """__children["ViewerSettings"]["Expression3"]["__engine"].setValue( 'python' )\n__children["ViewerSettings"]["Expression3"]["__expression"].setValue( 'parent["__out"]["p0"] = not parent["__in"]["p0"]' )\n__children["ViewerSettings"]["Expression5"]["__engine"].setValue( 'python' )\n__children["ViewerSettings"]["Expression5"]["__expression"].setValue( 'parent["__out"]["p0"] = parent["__in"]["p0"]' )""",
    1
)
vtxt = vtxt.replace(
    """Gaffer.Metadata.registerValue( __children["ViewerSettings"]["shadingSystem"], 'plugValueWidget:type', 'GafferUI.PresetsPlugValueWidget' )""",
    """Gaffer.Metadata.registerValue( __children["ViewerSettings"]["shadingSystem"], 'plugValueWidget:type', 'GafferCyclesUI.CyclesOptionsUI.ViewerShadingSystemPlugValueWidget' )""",
    1
)
vset.write_text(vtxt)
expect(
    "f cyclesViewerSettings.gfr",
    "shadingSystem\", defaultValue = 'SVM'" in vtxt
        and "ViewerShadingSystemPlugValueWidget" in vtxt
        and "'OSL'" not in vtxt.split( "Expression5" )[0],
    "the viewer's shading system defaults/expressions could not be switched to SVM/python"
)

# ── f2) CyclesOptionsUI.py: restart viewer when shading system changes ──
cycles_ui = root / "python/GafferCyclesUI/CyclesOptionsUI.py"
ctxt = cycles_ui.read_text()
if "class ViewerShadingSystemPlugValueWidget" not in ctxt:
    insert = r'''
class ViewerShadingSystemPlugValueWidget( GafferUI.PresetsPlugValueWidget ) :

	def __init__( self, plugs, **kw ) :

		GafferUI.PresetsPlugValueWidget.__init__( self, plugs, **kw )

		self.getPlug().node().plugSetSignal().connect( Gaffer.WeakMethod( self.__plugSet ) )

	def __plugSet( self, plug ) :

		if plug != self.getPlug() :
			return

		# Cycles can't switch shading systems after the session has started.
		# Force the SceneView to create a fresh Cycles renderer.
		if plug.node()["renderer"]["name"].getValue() == "Cycles" :
			plug.node()["renderer"]["name"].setValue( "OpenGL" )
			plug.node()["renderer"]["name"].setValue( "Cycles" )

'''
    ctxt = ctxt.replace(
        "\n# Used by `startup/gui/cyclesViewerSettings.gfr`.\nclass ViewerDevicePlugValueWidget",
        "\n# Used by `startup/gui/cyclesViewerSettings.gfr`.\n" + insert + "class ViewerDevicePlugValueWidget",
        1,
    )
cycles_ui.write_text(ctxt)
expect(
    "f2 CyclesOptionsUI.py",
    "class ViewerShadingSystemPlugValueWidget" in ctxt,
    "could not install the widget that restarts the viewer on a shading system change"
)

# ── g) shaderView.py: keep OSL shader previews in OSL mode ──
sview = root / "startup/gui/shaderView.py"
svtxt = sview.read_text()
svtxt = svtxt.replace(
    '\t\t\timport sys\n'
    '\t\t\t_shadingSys = "SVM" if sys.platform == "darwin" else "OSL"\n'
    '\t\t\tresult["shadingSystem"]["enabled"].setValue( True )\n'
    '\t\t\tresult["shadingSystem"]["value"].setValue( _shadingSys )\n',
    '\t\t\t# Less issues when mixing around OSL shaders\n'
    '\t\t\tresult["shadingSystem"]["enabled"].setValue( True )\n'
    '\t\t\tresult["shadingSystem"]["value"].setValue( "OSL" )\n',
    1
)
sview.write_text(svtxt)
expect(
    "g shaderView.py",
    "_shadingSys" not in svtxt and 'result["shadingSystem"]["value"].setValue( "OSL" )' in svtxt,
    "shader previews still force SVM on macOS"
)

# ── h) OutputBuffer.cpp: macOS GL viewport fix ──
# macOS GL 2.1 context doesn't have GL_TEXTURE_BUFFER / glTexBuffer.
# Use GL_TEXTURE_1D + GLSL 1.20 + GL_EXT_gpu_shader4 instead.

ob = root / "src/GafferSceneUI/OutputBuffer.cpp"
otxt = ob.read_text()

# h.1) BufferTexture: skip GL buffer on macOS
otxt = otxt.replace(
    '\t\tBufferTexture()\n'
    '\t\t{\n'
    '\t\t\tglGenTextures( 1, &m_texture );\n'
    '\t\t\tglGenBuffers( 1, &m_buffer );\n'
    '\t\t}\n'
    '\n'
    '\t\t~BufferTexture()\n'
    '\t\t{\n'
    '\t\t\tglDeleteBuffers( 1, &m_buffer );\n'
    '\t\t\tglDeleteTextures( 1, &m_texture );\n'
    '\t\t}\n',
    '\t\tBufferTexture()\n'
    '\t\t{\n'
    '\t\t\tglGenTextures( 1, &m_texture );\n'
    '#ifndef __APPLE__\n'
    '\t\t\tglGenBuffers( 1, &m_buffer );\n'
    '#endif\n'
    '\t\t}\n'
    '\n'
    '\t\t~BufferTexture()\n'
    '\t\t{\n'
    '#ifndef __APPLE__\n'
    '\t\t\tglDeleteBuffers( 1, &m_buffer );\n'
    '#endif\n'
    '\t\t\tglDeleteTextures( 1, &m_texture );\n'
    '\t\t}\n',
    1
)

# h.2) BufferTexture::updateBuffer: GL_TEXTURE_1D on macOS
otxt = otxt.replace(
    '\t\tvoid updateBuffer( const vector<uint32_t> &data )\n'
    '\t\t{\n'
    '\t\t\tglBindBuffer( GL_TEXTURE_BUFFER, m_buffer );\n'
    '\t\t\tglBufferData( GL_TEXTURE_BUFFER, sizeof( uint32_t ) * data.size(), data.data(), GL_STREAM_DRAW );\n'
    '\n'
    '\t\t\tglBindTexture( GL_TEXTURE_BUFFER, m_texture );\n'
    '\t\t\tglTexBuffer( GL_TEXTURE_BUFFER, GL_R32UI, m_buffer );\n'
    '\t\t}\n',
    '\t\tvoid updateBuffer( const vector<uint32_t> &data )\n'
    '\t\t{\n'
    '#ifdef __APPLE__\n'
    '\t\t\t// macOS GL 2.1 context doesn\'t support GL_TEXTURE_BUFFER / glTexBuffer.\n'
    '\t\t\t// Use a GL_TEXTURE_1D with R32UI format instead.\n'
    '\t\t\tglBindTexture( GL_TEXTURE_1D, m_texture );\n'
    '\t\t\tglTexParameteri( GL_TEXTURE_1D, GL_TEXTURE_MIN_FILTER, GL_NEAREST );\n'
    '\t\t\tglTexParameteri( GL_TEXTURE_1D, GL_TEXTURE_MAG_FILTER, GL_NEAREST );\n'
    '\t\t\tglTexImage1D( GL_TEXTURE_1D, 0, GL_R32UI, data.size(), 0, GL_RED_INTEGER, GL_UNSIGNED_INT, data.data() );\n'
    '\t\t\tm_size = static_cast<int>( data.size() );\n'
    '#else\n'
    '\t\t\tglBindBuffer( GL_TEXTURE_BUFFER, m_buffer );\n'
    '\t\t\tglBufferData( GL_TEXTURE_BUFFER, sizeof( uint32_t ) * data.size(), data.data(), GL_STREAM_DRAW );\n'
    '\n'
    '\t\t\tglBindTexture( GL_TEXTURE_BUFFER, m_texture );\n'
    '\t\t\tglTexBuffer( GL_TEXTURE_BUFFER, GL_R32UI, m_buffer );\n'
    '#endif\n'
    '\t\t}\n',
    1
)

# h.3) BufferTexture: size() accessor + m_size member on macOS
otxt = otxt.replace(
    '\tprivate :\n'
    '\n'
    '\t\tGLuint m_texture;\n'
    '\t\tGLuint m_buffer;\n',
    '#ifdef __APPLE__\n'
    '\t\tint size() const\n'
    '\t\t{\n'
    '\t\t\treturn m_size;\n'
    '\t\t}\n'
    '#endif\n'
    '\n'
    '\tprivate :\n'
    '\n'
    '\t\tGLuint m_texture;\n'
    '#ifdef __APPLE__\n'
    '\t\tint m_size = 0;\n'
    '#else\n'
    '\t\tGLuint m_buffer;\n'
    '#endif\n',
    1
)

# h.4) GLSL shaders: macOS GLSL 1.20 + GL_EXT_gpu_shader4
# Only apply if not already patched (idempotency guard)
if '#ifdef __APPLE__\n\nconst char *g_vertexSource' not in otxt:
  otxt = otxt.replace(
    'const char *g_vertexSource = R"(\n'
    '\n'
    '#version 330 compatibility\n'
    '\n'
    'in vec2 P; // Receives unit quad\n'
    'out vec2 texCoords;\n',
    '#ifdef __APPLE__\n'
    '\n'
    'const char *g_vertexSource = R"(\n'
    '\n'
    '#version 120\n'
    '\n'
    'attribute vec2 P; // Receives unit quad\n'
    'varying vec2 texCoords;\n',
    1
  )

if '#else // !__APPLE__' not in otxt:
  otxt = otxt.replace(
    'const char *g_fragmentSource = R"(\n'
    '\n'
    '#version 330 compatibility\n'
    '\n'
    '// Assumes texture contains sorted values.\n'
    'bool contains( usamplerBuffer array, uint value )\n'
    '{\n'
    '\tint high = textureSize( array ) - 1;\n'
    '\tint low = 0;\n'
    '\twhile( low != high )\n'
    '\t{\n'
    '\t\tint mid = (low + high + 1) / 2;\n'
    '\t\tif( texelFetch( array, mid ).r > value )\n'
    '\t\t{\n'
    '\t\t\thigh = mid - 1;\n'
    '\t\t}\n'
    '\t\telse\n'
    '\t\t{\n'
    '\t\t\tlow = mid;\n'
    '\t\t}\n'
    '\t}\n'
    '\treturn texelFetch( array, low ).r == value;\n'
    '}\n'
    '\n'
    'uniform sampler2D rgbaTexture;\n'
    'uniform sampler2D depthTexture;\n'
    'uniform usampler2D idTexture;\n'
    'uniform usamplerBuffer selectionTexture;\n'
    'uniform bool renderSelection;\n'
    '\n'
    'in vec2 texCoords;\n'
    'layout( location=0 ) out vec4 outColor;\n'
    '\n'
    'void main()\n'
    '{\n'
    '\toutColor = texture( rgbaTexture, texCoords );\n'
    '\tif( outColor.a == 0.0 )\n'
    '\t{\n'
    '\t\tdiscard;\n'
    '\t}\n'
    '\n'
    '\t// Input depth is absolute in camera space (completely\n'
    '\t// unrelated to clipping planes). Convert to the screen\n'
    '\t// space that `GL_fragDepth` needs.\n'
    '\tfloat depth = texture( depthTexture, texCoords ).r;\n'
    '\tvec4 Pcamera = vec4( 0.0, 0.0, -depth, 1.0 );\n'
    '\tvec4 Pclip = gl_ProjectionMatrix * Pcamera;\n'
    '\tfloat ndcDepth = Pclip.z / Pclip.w;\n'
    '\tgl_FragDepth = (ndcDepth + 1.0) / 2.0;\n'
    '\n'
    '\tif( renderSelection )\n'
    '\t{\n'
    '\t\tuint id = texture( idTexture, texCoords ).r;\n'
    '\t\toutColor = vec4( 0.466, 0.612, 0.741, 1.0 ) * outColor.a * 0.75 * float( contains( selectionTexture, id ) );\n'
    '\t}\n'
    '}\n'
    '\n'
    ')";',
    'const char *g_fragmentSource = R"(\n'
    '\n'
    '#version 120\n'
    '#extension GL_EXT_gpu_shader4 : enable\n'
    '\n'
    'bool contains( usampler1D array, int arraySize, unsigned int value )\n'
    '{\n'
    '\tint high = arraySize - 1;\n'
    '\tint low = 0;\n'
    '\twhile( low != high )\n'
    '\t{\n'
    '\t\tint mid = (low + high + 1) / 2;\n'
    '\t\tif( texelFetch1D( array, mid, 0 ).r > value )\n'
    '\t\t{\n'
    '\t\t\thigh = mid - 1;\n'
    '\t\t}\n'
    '\t\telse\n'
    '\t\t{\n'
    '\t\t\tlow = mid;\n'
    '\t\t}\n'
    '\t}\n'
    '\treturn texelFetch1D( array, low, 0 ).r == value;\n'
    '}\n'
    '\n'
    'uniform sampler2D rgbaTexture;\n'
    'uniform sampler2D depthTexture;\n'
    'uniform usampler2D idTexture;\n'
    'uniform usampler1D selectionTexture;\n'
    'uniform int selectionSize;\n'
    'uniform bool renderSelection;\n'
    '\n'
    'varying vec2 texCoords;\n'
    '\n'
    'void main()\n'
    '{\n'
    '\tvec4 outColorVal = texture2D( rgbaTexture, texCoords );\n'
    '\tif( outColorVal.a == 0.0 )\n'
    '\t{\n'
    '\t\tdiscard;\n'
    '\t}\n'
    '\n'
    '\tfloat depth = texture2D( depthTexture, texCoords ).r;\n'
    '\tvec4 Pcamera = vec4( 0.0, 0.0, -depth, 1.0 );\n'
    '\tvec4 Pclip = gl_ProjectionMatrix * Pcamera;\n'
    '\tfloat ndcDepth = Pclip.z / Pclip.w;\n'
    '\tgl_FragDepth = (ndcDepth + 1.0) / 2.0;\n'
    '\n'
    '\tif( renderSelection )\n'
    '\t{\n'
    '\t\tunsigned int id = texture2D( idTexture, texCoords ).r;\n'
    '\t\toutColorVal = vec4( 0.466, 0.612, 0.741, 1.0 ) * outColorVal.a * 0.75 * float( contains( selectionTexture, selectionSize, id ) );\n'
    '\t}\n'
    '\tgl_FragColor = outColorVal;\n'
    '}\n'
    '\n'
    ')";'
    '\n\n'
    '#else // !__APPLE__\n'
    '\n'
    'const char *g_vertexSource = R"(\n'
    '\n'
    '#version 330 compatibility\n'
    '\n'
    'in vec2 P; // Receives unit quad\n'
    'out vec2 texCoords;\n'
    '\n'
    'void main()\n'
    '{\n'
    '\tvec2 p = P * 2.0 - 1.0;\n'
    '\tgl_Position = vec4( p.x, p.y, 0, 1 );\n'
    '\ttexCoords = P * vec2( 1, -1 ) + vec2( 0, 1 );\n'
    '}\n'
    '\n'
    ')";'
    '\n\n'
    'const char *g_fragmentSource = R"(\n'
    '\n'
    '#version 330 compatibility\n'
    '\n'
    'bool contains( usamplerBuffer array, uint value )\n'
    '{\n'
    '\tint high = textureSize( array ) - 1;\n'
    '\tint low = 0;\n'
    '\twhile( low != high )\n'
    '\t{\n'
    '\t\tint mid = (low + high + 1) / 2;\n'
    '\t\tif( texelFetch( array, mid ).r > value )\n'
    '\t\t{\n'
    '\t\t\thigh = mid - 1;\n'
    '\t\t}\n'
    '\t\telse\n'
    '\t\t{\n'
    '\t\t\tlow = mid;\n'
    '\t\t}\n'
    '\t}\n'
    '\treturn texelFetch( array, low ).r == value;\n'
    '}\n'
    '\n'
    'uniform sampler2D rgbaTexture;\n'
    'uniform sampler2D depthTexture;\n'
    'uniform usampler2D idTexture;\n'
    'uniform usamplerBuffer selectionTexture;\n'
    'uniform bool renderSelection;\n'
    '\n'
    'in vec2 texCoords;\n'
    'layout( location=0 ) out vec4 outColor;\n'
    '\n'
    'void main()\n'
    '{\n'
    '\toutColor = texture( rgbaTexture, texCoords );\n'
    '\tif( outColor.a == 0.0 )\n'
    '\t{\n'
    '\t\tdiscard;\n'
    '\t}\n'
    '\n'
    '\tfloat depth = texture( depthTexture, texCoords ).r;\n'
    '\tvec4 Pcamera = vec4( 0.0, 0.0, -depth, 1.0 );\n'
    '\tvec4 Pclip = gl_ProjectionMatrix * Pcamera;\n'
    '\tfloat ndcDepth = Pclip.z / Pclip.w;\n'
    '\tgl_FragDepth = (ndcDepth + 1.0) / 2.0;\n'
    '\n'
    '\tif( renderSelection )\n'
    '\t{\n'
    '\t\tuint id = texture( idTexture, texCoords ).r;\n'
    '\t\toutColor = vec4( 0.466, 0.612, 0.741, 1.0 ) * outColor.a * 0.75 * float( contains( selectionTexture, id ) );\n'
    '\t}\n'
    '}\n'
    '\n'
    ')";'
    '\n\n'
    '#endif // __APPLE__\n',
    1
)

# h.5) Add MessageHandler include
otxt = otxt.replace(
    '#include "boost/lexical_cast.hpp"\n',
    '#include "IECore/MessageHandler.h"\n\n'
    '#include "boost/lexical_cast.hpp"\n',
    1
)

# h.6) renderInternal(): error handling, null checks, texture unit fix
otxt = otxt.replace(
    '\tif( !m_shader )\n'
    '\t{\n'
    '\t\tm_shader = ShaderLoader::defaultShaderLoader()->create( g_vertexSource, "", g_fragmentSource );\n'
    '\t\tm_shaderSetup = new IECoreGL::Shader::Setup( m_shader );\n'
    '\t\tm_shaderSetup->addUniformParameter( "rgbaTexture", m_rgbaTexture );\n'
    '\t\tm_shaderSetup->addUniformParameter( "depthTexture", m_depthTexture );\n'
    '\t\tm_shaderSetup->addUniformParameter( "idTexture", m_idTexture );\n'
    '\t\tm_shaderSetup->addVertexAttribute(\n'
    '\t\t\t"P", new V2fVectorData( { V2f( 0, 0 ), V2f( 0, 1 ), V2f( 1, 1 ), V2f( 1, 0 ) } )\n'
    '\t\t);\n'
    '\t}\n'
    '\n'
    '\tIECoreGL::Shader::Setup::ScopedBinding shaderBinding( *m_shaderSetup );\n'
    '\n'
    '\tconst IECoreGL::Shader::Parameter *selectionParameter = m_shader->uniformParameter( "selectionTexture" );\n'
    '\tGLuint selectionTextureUnit = selectionParameter->textureUnit;\n'
    '\tif( !selectionTextureUnit )\n'
    '\t{\n'
    '\t\t// Workaround until IECoreGL assigns units to GL_SAMPLER_BUFFER.\n'
    '\t\tselectionTextureUnit = 3;\n'
    '\t}\n'
    '\n'
    '\tglActiveTexture( GL_TEXTURE0 + selectionTextureUnit );\n'
    '\tglBindTexture( GL_TEXTURE_BUFFER, m_selectionTexture->texture() );\n'
    '\tglUniform1i( selectionParameter->location, selectionTextureUnit );\n'
    '\tglUniform1i( m_shader->uniformParameter( "renderSelection" )->location, renderSelection );\n',
    '\tif( !m_shader )\n'
    '\t{\n'
    '\t\ttry\n'
    '\t\t{\n'
    '\t\t\tm_shader = ShaderLoader::defaultShaderLoader()->create( g_vertexSource, "", g_fragmentSource );\n'
    '\t\t}\n'
    '\t\tcatch( const std::exception &e )\n'
    '\t\t{\n'
    '\t\t\tIECore::msg( IECore::Msg::Error, "OutputBuffer", string( "Shader compilation failed: " ) + e.what() );\n'
    '\t\t\treturn;\n'
    '\t\t}\n'
    '\t\tm_shaderSetup = new IECoreGL::Shader::Setup( m_shader );\n'
    '\t\tm_shaderSetup->addUniformParameter( "rgbaTexture", m_rgbaTexture );\n'
    '\t\tm_shaderSetup->addUniformParameter( "depthTexture", m_depthTexture );\n'
    '\t\tm_shaderSetup->addUniformParameter( "idTexture", m_idTexture );\n'
    '\t\tm_shaderSetup->addVertexAttribute(\n'
    '\t\t\t"P", new V2fVectorData( { V2f( 0, 0 ), V2f( 0, 1 ), V2f( 1, 1 ), V2f( 1, 0 ) } )\n'
    '\t\t);\n'
    '\t}\n'
    '\n'
    '\tIECoreGL::Shader::Setup::ScopedBinding shaderBinding( *m_shaderSetup );\n'
    '\n'
    '\tconst IECoreGL::Shader::Parameter *selectionParameter = m_shader->uniformParameter( "selectionTexture" );\n'
    '\tif( !selectionParameter )\n'
    '\t{\n'
    '\t\tIECore::msg( IECore::Msg::Error, "OutputBuffer", "selectionTexture uniform not found" );\n'
    '\t\treturn;\n'
    '\t}\n'
    '\n'
    '\tGLuint selectionTextureUnit = selectionParameter->textureUnit;\n'
    '#ifndef __APPLE__\n'
    '\tif( selectionParameter->type == GL_UNSIGNED_INT_SAMPLER_BUFFER || selectionParameter->type == GL_SAMPLER_BUFFER )\n'
    '\t{\n'
    '\t\tselectionTextureUnit = 4;\n'
    '\t}\n'
    '#endif\n'
    '\n'
    '\tglActiveTexture( GL_TEXTURE0 + selectionTextureUnit );\n'
    '#ifdef __APPLE__\n'
    '\tglBindTexture( GL_TEXTURE_1D, m_selectionTexture->texture() );\n'
    '#else\n'
    '\tglBindTexture( GL_TEXTURE_BUFFER, m_selectionTexture->texture() );\n'
    '#endif\n'
    '\tglUniform1i( selectionParameter->location, selectionTextureUnit );\n'
    '\n'
    '\tconst IECoreGL::Shader::Parameter *renderSelectionParam = m_shader->uniformParameter( "renderSelection" );\n'
    '\tif( renderSelectionParam )\n'
    '\t{\n'
    '\t\tglUniform1i( renderSelectionParam->location, renderSelection );\n'
    '\t}\n'
    '#ifdef __APPLE__\n'
    '\tconst IECoreGL::Shader::Parameter *selectionSizeParam = m_shader->uniformParameter( "selectionSize" );\n'
    '\tif( selectionSizeParam )\n'
    '\t{\n'
    '\t\tglUniform1i( selectionSizeParam->location, m_selectionTexture->size() );\n'
    '\t}\n'
    '#endif\n',
    1
)

ob.write_text(otxt)
expect(
    "h OutputBuffer.cpp",
    "GL_TEXTURE_1D" in otxt and "#else // !__APPLE__" in otxt
        and "selectionSizeParam" in otxt,
    "could not apply the GL 2.1 viewport fixes; the viewer would render black"
)

# ── j) PaintTool.cpp: GLSL 1.20 paint visualiser ──
# The PaintTool (new in 1.7.5.0) draws painted values with a GLSL 330
# shader (uniform block, layout(location), interface blocks). The GL 2.1
# context only compiles GLSL 1.20, so the shader fails and painting shows
# nothing. Use a 1.20 shader with a plain mat4 uniform, and bind the
# attribute locations by relinking instead of layout(location).

pt = root / "src/GafferSceneUI/PaintTool.cpp"
ptxt = pt.read_text()

if "g_colorShaderVertSource120" not in ptxt:
    ptxt = ptxt.replace(
        '// Opengl vertex shader code\n',
        '#ifdef __APPLE__\n'
        '\n'
        '// macOS only gives us a GL 2.1 context, which compiles GLSL 1.20.\n'
        '\n'
        'const std::string g_colorShaderVertSource120(\n'
        '\t"#version 120\\n"\n'
        '\t"uniform mat4 o2c;\\n"\n'
        '\t"attribute vec3 ps;\\n"\n'
        '\t"attribute float vsx;\\n"\n'
        '\t"attribute float vsy;\\n"\n'
        '\t"attribute float vsz;\\n"\n'
        '\t"varying vec3 value;\\n"\n'
        '\t"void main()\\n"\n'
        '\t"{\\n"\n'
        '\t"   value = vec3( vsx, vsy, vsz );\\n"\n'
        '\t"   gl_Position = o2c * vec4( ps, 1.0 );\\n"\n'
        '\t"}\\n"\n'
        ');\n'
        '\n'
        'const std::string g_colorShaderFragSource120(\n'
        '\t"#version 120\\n"\n'
        '\t"varying vec3 value;\\n"\n'
        '\t"void main()\\n"\n'
        '\t"{\\n"\n'
        '\t"   gl_FragColor = vec4( value, 1.0 );\\n"\n'
        '\t"}\\n"\n'
        ');\n'
        '\n'
        '#endif\n'
        '\n'
        '// Opengl vertex shader code\n',
        1
    )

    ptxt = ptxt.replace(
        '\t\t\t\t\tconst GLuint program = shader->program();\n'
        '\t\t\t\t\tconst GLuint blockIndex = glGetUniformBlockIndex( program, "UniformBlock" );\n'
        '\t\t\t\t\tif( blockIndex != GL_INVALID_INDEX )\n'
        '\t\t\t\t\t{\n'
        '\t\t\t\t\t\tglUniformBlockBinding( program, blockIndex, g_uniformBlockBindingIndex );\n'
        '\t\t\t\t\t}\n',
        '\t\t\t\t\tconst GLuint program = shader->program();\n'
        '#ifdef __APPLE__\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_PS, "ps" );\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_VSX, "vsx" );\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_VSY, "vsy" );\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_VSZ, "vsz" );\n'
        '\t\t\t\t\tglLinkProgram( program );\n'
        '#else\n'
        '\t\t\t\t\tconst GLuint blockIndex = glGetUniformBlockIndex( program, "UniformBlock" );\n'
        '\t\t\t\t\tif( blockIndex != GL_INVALID_INDEX )\n'
        '\t\t\t\t\t{\n'
        '\t\t\t\t\t\tglUniformBlockBinding( program, blockIndex, g_uniformBlockBindingIndex );\n'
        '\t\t\t\t\t}\n'
        '#endif\n',
        1
    )

    ptxt = ptxt.replace(
        '\t\t\tbuildShader( m_colorShader, g_colorShaderVertSource, g_colorShaderFragSource );\n',
        '#ifdef __APPLE__\n'
        '\t\t\tbuildShader( m_colorShader, g_colorShaderVertSource120, g_colorShaderFragSource120 );\n'
        '#else\n'
        '\t\t\tbuildShader( m_colorShader, g_colorShaderVertSource, g_colorShaderFragSource );\n'
        '#endif\n',
        1
    )

    ptxt = ptxt.replace(
        '\t\t\tGLint uniformBinding;\n'
        '\t\t\tglGetIntegerv( GL_UNIFORM_BUFFER_BINDING, &uniformBinding );\n',
        '#ifndef __APPLE__\n'
        '\t\t\tGLint uniformBinding;\n'
        '\t\t\tglGetIntegerv( GL_UNIFORM_BUFFER_BINDING, &uniformBinding );\n',
        1
    )
    ptxt = ptxt.replace(
        '\t\t\tglBindBufferBase( GL_UNIFORM_BUFFER, g_uniformBlockBindingIndex, m_colorUniformBuffer->buffer() );\n',
        '\t\t\tglBindBufferBase( GL_UNIFORM_BUFFER, g_uniformBlockBindingIndex, m_colorUniformBuffer->buffer() );\n'
        '#endif\n',
        1
    )

    ptxt = ptxt.replace(
        '\t\t\tglUseProgram( m_colorShader->program() );\n',
        '\t\t\tglUseProgram( m_colorShader->program() );\n'
        '#ifdef __APPLE__\n'
        '\t\t\tconst GLint o2cLocation = glGetUniformLocation( m_colorShader->program(), "o2c" );\n'
        '#endif\n',
        1
    )

    ptxt = ptxt.replace(
        '\t\t\tglVertexAttribDivisor( ATTRIB_GLSL_LOCATION_PS, 0 );\n',
        '#ifndef __APPLE__\n'
        '\t\t\tglVertexAttribDivisor( ATTRIB_GLSL_LOCATION_PS, 0 );\n'
        '#endif\n',
        1
    )

    ptxt = ptxt.replace(
        '\t\t\t\t\tglBufferData( GL_UNIFORM_BUFFER, sizeof( UniformBlockColorShader ), &uniforms, GL_DYNAMIC_DRAW );\n',
        '#ifdef __APPLE__\n'
        '\t\t\t\t\tglUniformMatrix4fv( o2cLocation, 1, GL_FALSE, uniforms.o2c.getValue() );\n'
        '#else\n'
        '\t\t\t\t\tglBufferData( GL_UNIFORM_BUFFER, sizeof( UniformBlockColorShader ), &uniforms, GL_DYNAMIC_DRAW );\n'
        '#endif\n',
        1
    )

    ptxt = ptxt.replace(
        '\t\t\tglBindBuffer( GL_UNIFORM_BUFFER, uniformBinding );\n',
        '#ifndef __APPLE__\n'
        '\t\t\tglBindBuffer( GL_UNIFORM_BUFFER, uniformBinding );\n'
        '#endif\n',
        1
    )

if "#ifndef __APPLE__\nconst GLuint g_uniformBlockBindingIndex" not in ptxt:
    # Unused on macOS now, and -Werror rejects unused constants.
    ptxt = ptxt.replace(
        'const GLuint g_uniformBlockBindingIndex = 0;\n',
        '#ifndef __APPLE__\n'
        'const GLuint g_uniformBlockBindingIndex = 0;\n'
        '#endif\n',
        1
    )

pt.write_text(ptxt)

expect(
    "j PaintTool.cpp",
    "#version 330" not in ptxt  # upstream moved to GLSL 1.20 itself
        or ptxt.count("#ifdef __APPLE__") + ptxt.count("#ifndef __APPLE__") >= 9
        and "glUniformMatrix4fv( o2cLocation" in ptxt
        and "g_colorShaderVertSource120, g_colorShaderFragSource120" in ptxt,
    "could not port the paint visualiser to GLSL 1.20; painting would show nothing"
)

# ── j2) DepthRender.cpp: complete depth-only framebuffer ──
# The PaintTool renders the brush footprint into a depth-only framebuffer.
# In the GL 2.1 context that is GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER unless
# the draw and read buffers are GL_NONE, so strokes never applied.

dr = root / "src/GafferSceneUI/DepthRender.cpp"
drtxt = dr.read_text()
if "glDrawBuffer( GL_NONE )" not in drtxt:
    drtxt = drtxt.replace(
        '\tglFramebufferRenderbuffer( GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, m_depthBuffer );\n',
        '\tglFramebufferRenderbuffer( GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, m_depthBuffer );\n'
        '\n'
        '#ifdef __APPLE__\n'
        '\t// The macOS GL 2.1 context rejects a depth-only framebuffer unless\n'
        '\t// its colour draw and read buffers are disabled.\n'
        '\tglDrawBuffer( GL_NONE );\n'
        '\tGLint readFramebuffer = 0;\n'
        '\tglGetIntegerv( GL_READ_FRAMEBUFFER_BINDING, &readFramebuffer );\n'
        '\tglBindFramebuffer( GL_READ_FRAMEBUFFER, m_framebuffer );\n'
        '\tglReadBuffer( GL_NONE );\n'
        '\tglBindFramebuffer( GL_READ_FRAMEBUFFER, readFramebuffer );\n'
        '#endif\n',
        1
    )
    dr.write_text(drtxt)
expect(
    "j2 DepthRender.cpp",
    "glDrawBuffer( GL_NONE )" in drtxt,
    "could not fix the depth-only framebuffer; paint strokes would not apply"
)

# ── k) VisualiserTool.cpp: GLSL 1.20 visualisers, CPU vertex label visibility ──
# The VisualiserTool draws with GLSL 330 shaders (uniform blocks,
# layout(location), interface blocks) and its vertex labels use a GLSL 430
# pass that writes visibility bits with atomicOr into a shader storage
# buffer. In the GL 2.1 context none of it compiles, so the tool draws
# nothing. Port the 330 shaders to 1.20 (EXT_gpu_shader4 provides
# gl_VertexID and flat varyings; instancing comes from ARB_instanced_arrays
# and ARB_draw_instanced), with plain uniforms and attribute locations bound
# by relinking. GL 2.1 has no storage buffers or atomics, so the vertex
# label visibility test reads back the scene depth and tests each vertex on
# the CPU instead.

vt = root / "src/GafferSceneUI/VisualiserTool.cpp"
vtxt = vt.read_text()

VT_APPLE_CODE = r'''#ifdef __APPLE__

// macOS only gives us a GL 2.1 context, which compiles GLSL 1.20 and has no
// uniform blocks. Matrices are uploaded untransposed, so they multiply from
// the left here.

// The core GL 3.3 instancing entry points are null in a 2.1 context, but the
// ARB extensions they came from are there.
#undef glVertexAttribDivisor
#define glVertexAttribDivisor glVertexAttribDivisorARB
#undef glDrawArraysInstanced
#define glDrawArraysInstanced glDrawArraysInstancedARB

const std::string g_colorShaderVertSource120(
	"#version 120\n"
	"uniform mat4 o2c;\n"
	"uniform vec3 valueMin;\n"
	"uniform vec3 valueRange;\n"
	"attribute vec3 ps;\n"
	"attribute float vsx;\n"
	"attribute float vsy;\n"
	"attribute float vsz;\n"
	"varying vec3 value;\n"
	"void main()\n"
	"{\n"
	"   value = clamp( ( vec3( vsx, vsy, vsz ) - valueMin ) * valueRange, 0.0, 1.0 );\n"
	"   gl_Position = o2c * vec4( ps, 1.0 );\n"
	"}\n"
);

const std::string g_colorShaderFragSource120(
	"#version 120\n"
	"uniform float opacity;\n"
	"varying vec3 value;\n"
	"void main()\n"
	"{\n"
	"   gl_FragColor = vec4( value, opacity );\n"
	"}\n"
);

#define VECTOR_SHADER_GLSL_120_HEADER \
	"#version 120\n" \
	"#extension GL_EXT_gpu_shader4 : require\n" \
	"uniform mat4 o2v;\n" \
	"uniform mat4 n2v;\n" \
	"uniform mat4 v2c;\n" \
	"uniform mat4 o2c;\n" \
	"uniform float scale;\n" \
	"attribute vec3 ps;\n" \
	"attribute vec3 vs;\n"

const std::string g_vectorShaderVertSourcePoint120(
	VECTOR_SHADER_GLSL_120_HEADER
	"void main()\n"
	"{\n"
	"   vec3 position = ps;\n"
	"   if( gl_VertexID == 1 )\n"
	"   {\n"
	"       position = vs;\n"
	"   }\n"
	"   gl_Position = o2c * vec4( position, 1.0 );\n"
	"}\n"
);

const std::string g_vectorShaderVertSourceVector120(
	VECTOR_SHADER_GLSL_120_HEADER
	"void main()\n"
	"{\n"
	"   vec3 position = ps;\n"
	"   if( gl_VertexID == 1 )\n"
	"   {\n"
	"       position += vs * scale;\n"
	"   }\n"
	"   gl_Position = o2c * vec4( position, 1.0 );\n"
	"}\n"
);

const std::string g_vectorShaderVertSourceBivector120(
	VECTOR_SHADER_GLSL_120_HEADER
	"void main()\n"
	"{\n"
	"   vec4 position = o2v * vec4( ps, 1.0 );\n"
	"   if( gl_VertexID == 1 )\n"
	"   {\n"
	"       position.xyz += normalize( mat3( n2v ) * vs ) * ( scale * length( vs ) );\n"
	"   }\n"
	"   gl_Position = v2c * position;\n"
	"}\n"
);

const std::string g_vectorShaderFragSource120(
	"#version 120\n"
	"uniform vec3 color;\n"
	"uniform float opacity;\n"
	"void main()\n"
	"{\n"
	"   gl_FragColor = vec4( color, opacity );\n"
	"}\n"
);

const std::string g_orientationShaderVertSource120(
	"#version 120\n"
	"#extension GL_EXT_gpu_shader4 : require\n"
	"uniform mat4 o2c;\n"
	"uniform float scale;\n"
	"attribute vec3 ps;\n"
	"attribute vec4 qs;\n"
	"flat varying vec3 color;\n"
	"void main()\n"
	"{\n"
	"   vec3 colors[ 3 ];\n"
	"   // Match colors to `StandardStyle::colorForAxes()`\n"
	"   colors[0] = vec3( 0.73, 0.17, 0.17 );\n"
	"   colors[1] = vec3( 0.2, 0.57, 0.2 );\n"
	"   colors[2] = vec3( 0.2, 0.36, 0.74 );\n"
	"   vec3 position = ps;\n"
	"   int axis = gl_VertexID / 2;\n"
	"   if( ( gl_VertexID % 2 ) > 0 )\n"
	"   {\n"
	"       float r = qs.x;\n"
	"       vec3  v = qs.yzw;\n"
	"       mat3  m = mat3(\n"
	"           1.0 - 2.0 * dot( v.yz, v.yz ),\n"
	"                 2.0 * dot( v.xz, vec2( v.y,  r ) ),\n"
	"                 2.0 * dot( v.zy, vec2( v.x, -r ) ),\n"
	"                 2.0 * dot( v.xz, vec2( v.y, -r ) ),\n"
	"           1.0 - 2.0 * dot( v.zx, v.zx ),\n"
	"                 2.0 * dot( v.yx, vec2( v.z,  r ) ),\n"
	"                 2.0 * dot( v.zy, vec2( v.x,  r ) ),\n"
	"                 2.0 * dot( v.yx, vec2( v.z, -r ) ),\n"
	"           1.0 - 2.0 * dot( v.yx, v.yx ) );\n"
	"       position += normalize( m[ axis ] ) * scale;\n"
	"   }\n"
	"   gl_Position = o2c * vec4( position, 1.0 );\n"
	"   color = colors[ axis ];\n"
	"}\n"
);

const std::string g_orientationShaderFragSource120(
	"#version 120\n"
	"#extension GL_EXT_gpu_shader4 : require\n"
	"uniform float opacity;\n"
	"flat varying vec3 color;\n"
	"void main()\n"
	"{\n"
	"   gl_FragColor = vec4( color, opacity );\n"
	"}\n"
);

GLint uniformLocation( const char *name )
{
	GLint program = 0;
	glGetIntegerv( GL_CURRENT_PROGRAM, &program );
	return glGetUniformLocation( program, name );
}

void setUniforms( const UniformBlockColorShader &uniforms )
{
	glUniformMatrix4fv( uniformLocation( "o2c" ), 1, GL_FALSE, uniforms.o2c.getValue() );
	glUniform3fv( uniformLocation( "valueMin" ), 1, uniforms.valueMin.getValue() );
	glUniform3fv( uniformLocation( "valueRange" ), 1, uniforms.valueRange.getValue() );
	glUniform1f( uniformLocation( "opacity" ), uniforms.opacity );
}

void setUniforms( const UniformBlockVectorShader &uniforms )
{
	glUniformMatrix4fv( uniformLocation( "o2v" ), 1, GL_FALSE, uniforms.o2v.getValue() );
	glUniformMatrix4fv( uniformLocation( "n2v" ), 1, GL_FALSE, uniforms.n2v.getValue() );
	glUniformMatrix4fv( uniformLocation( "v2c" ), 1, GL_FALSE, uniforms.v2c.getValue() );
	glUniformMatrix4fv( uniformLocation( "o2c" ), 1, GL_FALSE, uniforms.o2c.getValue() );
	glUniform3fv( uniformLocation( "color" ), 1, uniforms.color.getValue() );
	glUniform1f( uniformLocation( "opacity" ), uniforms.opacity );
	glUniform1f( uniformLocation( "scale" ), uniforms.scale );
}

void setUniforms( const UniformBlockOrientationShader &uniforms )
{
	glUniformMatrix4fv( uniformLocation( "o2c" ), 1, GL_FALSE, uniforms.o2c.getValue() );
	glUniform1f( uniformLocation( "scale" ), uniforms.scale );
	glUniform1f( uniformLocation( "opacity" ), uniforms.opacity );
}

// GL 2.1 has no shader storage buffers or atomics, so instead of the GPU
// visibility pass for vertex labels we read back the scene depth and depth
// test each vertex on the CPU. Like the GPU pass, which draws 3 pixel
// points, a vertex is visible if any pixel of its 3x3 neighbourhood passes.

struct SceneDepth
{
	int width = 0;
	int height = 0;
	std::vector<float> depth;
};

void readSceneDepth( SceneDepth &sceneDepth )
{
	GLint viewport[4];
	glGetIntegerv( GL_VIEWPORT, viewport );
	sceneDepth.width = viewport[2];
	sceneDepth.height = viewport[3];
	sceneDepth.depth.assign( (size_t)sceneDepth.width * sceneDepth.height, 1.f );
	if( sceneDepth.depth.empty() )
	{
		return;
	}

	GLint readFramebuffer, drawFramebuffer, renderbuffer;
	glGetIntegerv( GL_READ_FRAMEBUFFER_BINDING, &readFramebuffer );
	glGetIntegerv( GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebuffer );
	glGetIntegerv( GL_RENDERBUFFER_BINDING, &renderbuffer );
	const GLboolean scissorEnabled = glIsEnabled( GL_SCISSOR_TEST );
	glDisable( GL_SCISSOR_TEST );

	// The viewport renders multisampled, which can't be read directly, so
	// resolve its depth into a single sampled buffer of the same format.

	GLuint depthBuffer = 0;
	glGenRenderbuffers( 1, &depthBuffer );
	glBindRenderbuffer( GL_RENDERBUFFER, depthBuffer );
	glRenderbufferStorage( GL_RENDERBUFFER, GL_DEPTH_COMPONENT32F, sceneDepth.width, sceneDepth.height );

	GLuint framebuffer = 0;
	glGenFramebuffers( 1, &framebuffer );
	glBindFramebuffer( GL_FRAMEBUFFER, framebuffer );
	glFramebufferRenderbuffer( GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthBuffer );
	glDrawBuffer( GL_NONE );
	glReadBuffer( GL_NONE );

	glBindFramebuffer( GL_READ_FRAMEBUFFER, drawFramebuffer );
	glBlitFramebuffer(
		viewport[0], viewport[1], viewport[0] + sceneDepth.width, viewport[1] + sceneDepth.height,
		0, 0, sceneDepth.width, sceneDepth.height,
		GL_DEPTH_BUFFER_BIT, GL_NEAREST
	);
	glBindFramebuffer( GL_READ_FRAMEBUFFER, framebuffer );
	glReadPixels( 0, 0, sceneDepth.width, sceneDepth.height, GL_DEPTH_COMPONENT, GL_FLOAT, sceneDepth.depth.data() );

	glBindFramebuffer( GL_READ_FRAMEBUFFER, readFramebuffer );
	glBindFramebuffer( GL_DRAW_FRAMEBUFFER, drawFramebuffer );
	glBindRenderbuffer( GL_RENDERBUFFER, renderbuffer );
	glDeleteFramebuffers( 1, &framebuffer );
	glDeleteRenderbuffers( 1, &depthBuffer );
	if( scissorEnabled )
	{
		glEnable( GL_SCISSOR_TEST );
	}
}

std::vector<std::uint32_t> vertexVisibility( const SceneDepth &sceneDepth, const std::vector<V3f> &points, const M44f &o2c )
{
	std::vector<std::uint32_t> visibility( points.size() / 32 + 1, 0u );
	for( size_t i = 0; i < points.size(); ++i )
	{
		const V4f p = V4f( points[i].x, points[i].y, points[i].z, 1.f ) * o2c;
		if( p.w <= 0.f )
		{
			continue;
		}

		// Same depth bias as the GPU pass.
		const float z = ( p.z - std::numeric_limits<float>::epsilon() * 10.f ) / p.w * 0.5f + 0.5f;
		if( z < 0.f )
		{
			continue;
		}
		const int x = (int)std::floor( ( p.x / p.w * 0.5f + 0.5f ) * sceneDepth.width );
		const int y = (int)std::floor( ( p.y / p.w * 0.5f + 0.5f ) * sceneDepth.height );

		bool visible = false;
		for( int py = std::max( y - 1, 0 ); py <= std::min( y + 1, sceneDepth.height - 1 ) && !visible; ++py )
		{
			for( int px = std::max( x - 1, 0 ); px <= std::min( x + 1, sceneDepth.width - 1 ) && !visible; ++px )
			{
				visible = z <= sceneDepth.depth[(size_t)py * sceneDepth.width + px];
			}
		}

		if( visible )
		{
			visibility[i / 32] |= 1u << ( i % 32 );
		}
	}
	return visibility;
}

#endif

'''

def vt_guard(match, apple=None):
    body = match.group(0)
    if apple is None:
        return "#ifndef __APPLE__\n" + body + "#endif\n"
    return "#ifdef __APPLE__\n" + apple + "#else\n" + body + "#endif\n"

if "g_colorShaderVertSource120" not in vtxt:
    vtxt = vtxt.replace(
        '//-----------------------------------------------------------------------------\n'
        '// Helper Methods\n',
        VT_APPLE_CODE +
        '//-----------------------------------------------------------------------------\n'
        '// Helper Methods\n',
        1
    )

    # Constants only the uniform/storage block code uses; -Werror rejects
    # them unused.
    for const in (
        'const GLuint g_uniformBlockBindingIndex = 0;\n',
        'GLuint const g_storageBlockBindingIndex = 0;\n',
    ):
        vtxt = vtxt.replace(const, "#ifndef __APPLE__\n" + const + "#endif\n", 1)

    vtxt = vtxt.replace(
        '\t\t\t\t\tconst GLuint program = shader->program();\n'
        '\t\t\t\t\tconst GLuint blockIndex = glGetUniformBlockIndex( program, "UniformBlock" );\n'
        '\t\t\t\t\tif( blockIndex != GL_INVALID_INDEX )\n'
        '\t\t\t\t\t{\n'
        '\t\t\t\t\t\tglUniformBlockBinding( program, blockIndex, g_uniformBlockBindingIndex );\n'
        '\t\t\t\t\t}\n',
        '\t\t\t\t\tconst GLuint program = shader->program();\n'
        '#ifdef __APPLE__\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_PS, "ps" );\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_VSX, "vsx" );\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_VSY, "vsy" );\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_VSZ, "vsz" );\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_VS, "vs" );\n'
        '\t\t\t\t\tglBindAttribLocation( program, ATTRIB_GLSL_LOCATION_QS, "qs" );\n'
        '\t\t\t\t\tglLinkProgram( program );\n'
        '#else\n'
        '\t\t\t\t\tconst GLuint blockIndex = glGetUniformBlockIndex( program, "UniformBlock" );\n'
        '\t\t\t\t\tif( blockIndex != GL_INVALID_INDEX )\n'
        '\t\t\t\t\t{\n'
        '\t\t\t\t\t\tglUniformBlockBinding( program, blockIndex, g_uniformBlockBindingIndex );\n'
        '\t\t\t\t\t}\n'
        '#endif\n',
        1
    )

    for shader, sources in (
        ( "m_colorShader", ( "g_colorShaderVertSource", "g_colorShaderFragSource" ) ),
        ( "m_vectorShaderPoint", ( "g_vectorShaderVertSourcePoint", "g_vectorShaderFragSource" ) ),
        ( "m_vectorShaderVector", ( "g_vectorShaderVertSourceVector", "g_vectorShaderFragSource" ) ),
        ( "m_vectorShaderBivector", ( "g_vectorShaderVertSourceBivector", "g_vectorShaderFragSource" ) ),
        ( "m_orientationShader", ( "g_orientationShaderVertSource", "g_orientationShaderFragSource" ) ),
    ):
        call = "\t\t\tbuildShader( %s, %s, %s );\n" % ( shader, *sources )
        call120 = "\t\t\tbuildShader( %s, %s120, %s120 );\n" % ( shader, *sources )
        vtxt = vtxt.replace(call, "#ifdef __APPLE__\n" + call120 + "#else\n" + call + "#endif\n", 1)

    # Vertex labels: everything from building the 430 shader up to the
    # saved GL state only serves the GPU visibility pass.
    vtxt = re.sub(
        r'\t\t\tbuildShader\( m_vertexLabelShader, .*?'
        r'\t\t\tglGetIntegerv\( GL_ARRAY_BUFFER_BINDING, &arrayBinding \);\n',
        lambda m: vt_guard(m, '\t\t\tSceneDepth sceneDepth;\n'),
        vtxt, count=1, flags=re.S
    )
    vtxt = re.sub(
        r'\t\t\t\t// Retrieve cached opengl buffer data\n.*?'
        r'(?=\n\t\t\t\t// Draw vertex ids or int variable offset)',
        lambda m: (
            '#ifdef __APPLE__\n'
            '\t\t\t\tif( sceneDepth.depth.empty() )\n'
            '\t\t\t\t{\n'
            '\t\t\t\t\treadSceneDepth( sceneDepth );\n'
            '\t\t\t\t}\n'
            '\t\t\t\tconst std::vector<std::uint32_t> visibility = vertexVisibility( sceneDepth, pData->readable(), o2w * w2c );\n'
            '\t\t\t\tconst std::uint32_t *vBuffer = visibility.data();\n'
            '#else\n' + m.group(0) + '\n#endif'
        ),
        vtxt, count=1, flags=re.S
    )
    vtxt = re.sub(
        r'\t\t\t\t\t// unmap storage buffer\n\n.*?\n\t\t\t\t}\n\n'
        r'\t\t\t\tglBindBuffer\( GL_SHADER_STORAGE_BUFFER, storageBinding \);\n',
        lambda m: m.group(0)
            .replace('\t\t\t\t\t// unmap', '#ifndef __APPLE__\n\t\t\t\t\t// unmap', 1)
            .replace('\t\t\t\t}\n\n\t\t\t\tglBindBuffer', '#endif\n\t\t\t\t}\n\n#ifndef __APPLE__\n\t\t\t\tglBindBuffer', 1)
            + '#endif\n',
        vtxt, count=1, flags=re.S
    )

    # Color, vector and orientation visualisers: no uniform buffers, set
    # plain uniforms instead.
    vtxt = re.sub(
        r'^\t\t\tGLint uniformBinding;\n'
        r'\t\t\tglGetIntegerv\( GL_UNIFORM_BUFFER_BINDING, &uniformBinding \);\n\n'
        r'\t\t\tif\( !m_\w+UniformBuffer \)\n\t\t\t\{\n(?:\t\t\t\t.*\n)*?\t\t\t\}\n\n'
        r'\t\t\tglBindBufferBase\( GL_UNIFORM_BUFFER, g_uniformBlockBindingIndex, m_\w+UniformBuffer->buffer\(\) \);\n',
        vt_guard, vtxt, flags=re.M
    )
    vtxt = re.sub(
        r'^\t\t\tglBindBuffer\( GL_UNIFORM_BUFFER, uniformBinding \);\n',
        vt_guard, vtxt, flags=re.M
    )
    vtxt = re.sub(
        r'^(\t+)glBufferData\( GL_UNIFORM_BUFFER, sizeof\( UniformBlock\w+ \), &uniforms, GL_DYNAMIC_DRAW \);\n',
        lambda m: vt_guard(m, m.group(1) + 'setUniforms( uniforms );\n'),
        vtxt, flags=re.M
    )

if "#ifndef __APPLE__\n\t\t\tm_vertexLabelStorageCapacity( 0 )," not in vtxt:
    # Unused on macOS now, and -Werror rejects unused private fields.
    for member in (
        '\t\t\tm_vertexLabelStorageCapacity( 0 ),\n',
        '\t\tmutable std::size_t m_vertexLabelStorageCapacity;\n',
    ):
        vtxt = vtxt.replace(member, "#ifndef __APPLE__\n" + member + "#endif\n", 1)

vt.write_text(vtxt)

expect(
    "k VisualiserTool.cpp",
    "#version 330" not in vtxt  # upstream moved to GLSL 1.20 itself
        or "g_colorShaderVertSource120, g_colorShaderFragSource120" in vtxt
        and "g_vectorShaderVertSourceBivector120, g_vectorShaderFragSource120" in vtxt
        and "g_orientationShaderVertSource120, g_orientationShaderFragSource120" in vtxt
        and "glBindAttribLocation( program, ATTRIB_GLSL_LOCATION_QS" in vtxt
        and "#define glVertexAttribDivisor glVertexAttribDivisorARB" in vtxt
        and "\t\t\tSceneDepth sceneDepth;\n#else\n\t\t\tbuildShader( m_vertexLabelShader" in vtxt
        and "vertexVisibility( sceneDepth, pData->readable()" in vtxt
        and "#ifndef __APPLE__\n\t\t\t\t\t// unmap storage buffer" in vtxt
        and vtxt.count("#ifndef __APPLE__\n\t\t\tGLint uniformBinding;") == 3
        and vtxt.count("#ifndef __APPLE__\n\t\t\tglBindBuffer( GL_UNIFORM_BUFFER, uniformBinding );") == 3
        and vtxt.count("setUniforms( uniforms );") == 3
        and "#ifndef __APPLE__\n\t\tmutable std::size_t m_vertexLabelStorageCapacity;" in vtxt,
    "could not port the visualiser shaders to GLSL 1.20; the VisualiserTool would draw nothing"
)

if problems:
    print("")
    print("ERROR: %d patch(es) did not apply to Gaffer %s." % (len(problems), root.name.replace("release-", "")))
    print("Upstream moved the code these patches target: " + ", ".join(problems) + ".")
    print("Build aborted rather than producing a broken Gaffer.")
    sys.exit(1)

print("All patches applied.")
PY
}

# ── 5. Write helper scripts ─────────────────────────────────────────

write_python_wrappers() {
  step "Python wrappers"

  # The bundled interpreter's version moves with the VFX platform the
  # dependency bundle was built for (3.11 on platform25), so discover it
  # rather than hard-coding it.
  local framework_bin="$BUILD_DIR/lib/Python.framework/Versions/Current/bin"
  local python_exe=""
  local candidate
  for candidate in "$framework_bin"/python3.[0-9] "$framework_bin"/python3.[0-9][0-9]; do
    if [ -x "$candidate" ]; then
      python_exe="$(basename "$candidate")"
    fi
  done
  if [ -z "$python_exe" ]; then
    echo "ERROR: No python3.x interpreter found in $framework_bin" >&2
    exit 1
  fi
  echo "  Bundled interpreter: $python_exe"

  mkdir -p "$BUILD_DIR/bin"
  rm -f "$BUILD_DIR/bin/python" "$BUILD_DIR/bin/python3"
  cat > "$BUILD_DIR/bin/python" <<WRAPPER
#!/bin/bash
set -e
rootDir="\$(cd "\$(dirname "\$0")/.." && pwd)"
export PYTHONHOME="\$rootDir/lib/Python.framework/Versions/Current"
exec "\$rootDir/lib/Python.framework/Versions/Current/bin/$python_exe" "\$@"
WRAPPER
  cp "$BUILD_DIR/bin/python" "$BUILD_DIR/bin/python3"
  chmod +x "$BUILD_DIR/bin/python" "$BUILD_DIR/bin/python3"
}

# ── 5b. Patch Cycles Metal runtime kernel compatibility ─────────────

patch_cycles_metal_compat() {
  step "Patching Cycles Metal compat.h"
  python3 - "$BUILD_DIR" <<'PY'
import pathlib, sys

build_dir = pathlib.Path(sys.argv[1])
targets = [
    build_dir / "cycles/source/kernel/device/metal/compat.h",
    build_dir / "cycles/include/kernel/device/metal/compat.h",
]

marker = "#ifdef __METAL_GLOBAL_BUILTINS__"
patch = (
    "#if defined( __METAL_GLOBAL_BUILTINS__ )\n"
    "#  undef __METAL_GLOBAL_BUILTINS__\n"
    "#endif\n\n"
    "#ifdef __METAL_GLOBAL_BUILTINS__"
)

patched = 0
for target in targets:
    if not target.exists():
        continue
    text = target.read_text()
    if patch in text:
        continue
    if marker not in text:
        print(f"  Marker not found in {target}")
        continue
    target.write_text(text.replace(marker, patch, 1))
    print(f"  Patched {target}")
    patched += 1

if patched == 0:
    print("  Already patched or no matching files found.")
PY
}

# ── 6. Build ────────────────────────────────────────────────────────

build_gaffer() {
  step "Building Gaffer"
  if run_scons_build; then
    return
  fi

  echo ""
  echo "Initial SCons build failed. Applying Mach-O rpath/install-name fixes and retrying once..."
  fixup_gaffer_install_names
  run_scons_build
}

run_scons_build() {
  ( cd "$RELEASE_DIR" && \
    scons -j "$(sysctl -n hw.ncpu)" build \
      BUILD_DIR="$BUILD_DIR" )
}

# ── 6b. Fix install names of freshly-built Gaffer libs ──────────────

fixup_gaffer_install_names() {
  step "Fixing rpaths/install names of built libraries"
  local bd="$BUILD_DIR"

  if [ -d "$bd/python" ]; then
    find "$bd/python" -name '*.so' -print0 | while IFS= read -r -d '' f; do
      install_name_tool -add_rpath "@loader_path/../../lib" "$f" 2>/dev/null || true
      install_name_tool -add_rpath "@loader_path/../../../lib" "$f" 2>/dev/null || true
    done
  fi

  if [ -d "$bd/lib" ]; then
    find "$bd/lib" -maxdepth 1 -name '*.dylib' -print0 | while IFS= read -r -d '' f; do
      install_name_tool -add_rpath "@loader_path/../lib" "$f" 2>/dev/null || true
    done
  fi

  # Fix dylibs in lib/ - change id from "lib/libXxx.dylib" to "@rpath/libXxx.dylib"
  for f in "$bd"/lib/*.dylib; do
    [ -f "$f" ] || continue
    local cur_id
    cur_id=$(otool -D "$f" | tail -1)
    local base
    base=$(basename "$cur_id")
    if [[ "$cur_id" != @rpath/* ]]; then
      install_name_tool -id "@rpath/$base" "$f" 2>/dev/null || true
    fi
  done

  # Fix all .so and .dylib that reference "lib/libXxx.dylib" (bare relative)
  {
    [ -d "$bd/lib" ] && find "$bd/lib" -maxdepth 1 -name '*.dylib' -print0
    [ -d "$bd/python" ] && find "$bd/python" -name '*.so' -print0
  } | while IFS= read -r -d '' f; do
    otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | while read -r dep; do
      if [[ "$dep" == lib/lib*.dylib ]]; then
        local base
        base=$(basename "$dep")
        install_name_tool -change "$dep" "@rpath/$base" "$f" 2>/dev/null || true
      fi
    done
  done

  echo "  Done."
}

# ── 7. Smoke test ───────────────────────────────────────────────────

# ── 6c. Patch Menu.py: show shortcut labels in Qt 6 menus ──────────

patch_menu_shortcut_labels() {
  step "Patching Menu.py for shortcut labels"
  python3 - "$BUILD_DIR" <<'PY'
import pathlib, sys

menu = pathlib.Path(sys.argv[1]) / "python/GafferUI/Menu.py"
text = menu.read_text()
marker = "qtAction.setShortcutContext( QtCore.Qt.WidgetShortcut )"
patch = (
    '\t\t\t# Qt 6 no longer displays shortcut labels for WidgetShortcut\n'
    '\t\t\t# actions in menus. Append the label manually.\n'
    '\t\t\tqtAction.setText( qtAction.text() + "\\t" + shortCut.split( "," )[0].strip() )'
)
if marker in text and patch not in text:
    text = text.replace(marker, marker + "\n" + patch)
    menu.write_text(text)
    print("  Patched.")
else:
    print("  Already patched or marker not found, skipping.")
PY
}

# ── 6d. Install macOS 15+/Tahoe cursor crash workaround ─────────────

install_cursor_crash_workaround() {
  step "Installing macOS cursor crash workaround"

  if [[ "$(uname)" != "Darwin" ]]; then
    echo "  Not macOS, skipping."
    return
  fi

  local product_version major_version
  product_version="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  major_version="${product_version%%.*}"
  if [[ "$major_version" =~ ^[0-9]+$ ]] && (( major_version < 15 )); then
    echo "  macOS $product_version does not need this workaround, skipping."
    return
  fi

  command -v clang >/dev/null 2>&1 || {
    echo "ERROR: Missing required command: clang" >&2
    exit 1
  }

  local source="$BUILD_DIR/fix_cursor_crash.m"
  local dylib="$BUILD_DIR/lib/fix_cursor_crash.dylib"
  cat > "$source" <<'OBJC'
#import <objc/runtime.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

static void noop(id self, SEL _cmd) { }

__attribute__((constructor))
static void swizzle(void)
{
    Method m1 = class_getInstanceMethod([NSCursor class], @selector(set));
    if (m1) method_setImplementation(m1, (IMP)noop);

    Method m2 = class_getInstanceMethod([NSCursor class], @selector(_reallySet));
    if (m2) method_setImplementation(m2, (IMP)noop);
}
OBJC

  clang -dynamiclib -framework AppKit -framework Foundation -o "$dylib" "$source"

  local site_packages
  site_packages="$(find "$BUILD_DIR/lib/Python.framework/Versions/Current/lib" -maxdepth 2 -type d -name site-packages -print -quit 2>/dev/null || true)"
  if [ -z "$site_packages" ]; then
    echo "ERROR: Could not find bundled Python site-packages directory" >&2
    exit 1
  fi

  cat > "$site_packages/_fix_cursor_crash.py" <<'PY'
import ctypes
import os
import pathlib
import sys

if sys.platform == "darwin":
    root = os.environ.get("GAFFER_ROOT")
    if not root:
        try:
            root = pathlib.Path(__file__).resolve().parents[7]
        except IndexError:
            root = None

    if root:
        lib = pathlib.Path(root) / "lib" / "fix_cursor_crash.dylib"
        if lib.exists():
            ctypes.CDLL(str(lib))
PY

  printf '%s\n' 'import _fix_cursor_crash' > "$site_packages/fix_cursor_crash.pth"
  echo "  Installed for macOS $product_version."
}

# ── 8. Remove Gatekeeper quarantine attributes ──────────────────────

remove_legacy_startup_files() {
  local legacy="$BUILD_DIR/startup/GafferCycles/macosCPUFallback.py"
  if [ -f "$legacy" ]; then
    rm -f "$legacy"
  fi
}

# ── 8. Remove Gatekeeper quarantine attributes ──────────────────────

remove_quarantine_attributes() {
  step "Removing Gatekeeper quarantine attributes"
  # Some bundled dependency files are read-only and some quarantine flags
  # can sit on symlinks themselves, so we handle both cases.
  chmod -R u+w "$BUILD_DIR" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$BUILD_DIR" 2>/dev/null || true
  xattr -drs com.apple.quarantine "$BUILD_DIR" 2>/dev/null || true
  echo "  Done."
}

# ── 9. Smoke test ───────────────────────────────────────────────────

smoke_test() {
  step "Smoke test"
  "$GAFFER" env python -c 'import Gaffer, GafferCycles; print("OK:", Gaffer.About.versionString())'
}

# ── main ─────────────────────────────────────────────────────────────

main() {
  echo "gaffer-macos build -- Gaffer $TAG for macOS Apple Silicon"
  echo ""

  need_cmd python3
  need_cmd brew
  need_cmd otool
  need_cmd install_name_tool
  need_cmd curl

  ensure_brew_pkg scons
  ensure_brew_pkg inkscape

  # Verify inkscape actually runs (Homebrew wrapper can point to a stale .app path)
  if ! inkscape --version >/dev/null 2>&1; then
    echo "Inkscape is installed but broken — reinstalling..."
    brew reinstall --cask inkscape
    if ! inkscape --version >/dev/null 2>&1; then
      echo "ERROR: inkscape still broken after reinstall" >&2
      exit 1
    fi
  fi

  need_cmd scons

  ensure_source
  apply_source_patches
  download_dependencies
  relocate_dependencies
  write_python_wrappers
  patch_cycles_metal_compat
  build_gaffer
  fixup_gaffer_install_names
  patch_menu_shortcut_labels
  remove_legacy_startup_files
  install_cursor_crash_workaround
  remove_quarantine_attributes
  smoke_test

  echo ""
  echo "Build complete. Launch Gaffer with:"
  echo "  ./build-$TAG/bin/gaffer"
}

main "$@"
