#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# build.sh -- Build Gaffer with Cycles for macOS Apple Silicon
#
# Downloads Gaffer source, applies patches to fix Cycles rendering
# (OSL/LLVM crash, GL viewport crash), downloads pre-built
# dependencies, and compiles everything with scons.
#
# Usage:
#   bash build.sh            # builds Gaffer 1.6.14.2
#   TAG=1.6.14.2 bash build.sh
#
# Requirements: Xcode CLI tools, Homebrew, ~10 GB disk, ~30 min.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

TAG="${TAG:-1.6.14.2}"
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
old = "/Users/admin/build/gafferDependencies-10.0.0-macos"
patched = 0

for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        path = os.path.join(dirpath, name)
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
            if old in ident:
                subprocess.check_call(
                    ["install_name_tool", "-id", ident.replace(old, root), path]
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
            if old in dep:
                subprocess.check_call(
                    ["install_name_tool", "-change", dep, dep.replace(old, root), path]
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
            if line.startswith("path ") and old in line:
                old_rpath = line.split("path ", 1)[1].split(" (offset", 1)[0].strip()
                new_rpath = old_rpath.replace(old, root)
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
#   d) Renderer.cpp   -- default Cycles to SVM (OSL/LLVM 15 crashes)
#   e) ShaderNetworkAlgo.cpp -- DiffuseBsdf fallback for empty shaders
#   f) cyclesViewerSettings.gfr -- SVM default + Python expressions
#   g) shaderView.py  -- SVM on macOS
#   h) OutputBuffer.cpp -- GL_TEXTURE_1D, GLSL 1.20, null checks
#   i) macosCPUFallback.py -- CPU-only device list

apply_source_patches() {
  step "Patching source"
  python3 - "$RELEASE_DIR" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])

# ── a) SConstruct: suppress warnings-as-errors on newer clang ──
sconstruct = root / "SConstruct"
text = sconstruct.read_text()
if '-Wno-error=cast-function-type-mismatch' not in text:
    text = re.sub(
        r'(env\.Append\( CXXFLAGS = \[ "-DBOOST_NO_CXX98_FUNCTION_BASE", "-D_HAS_AUTO_PTR_ETC=0" \] \)\n)',
        r'\1\t\tenv.Append( CXXFLAGS = [ "-Wno-error=deprecated-declarations", "-Wno-error=cast-function-type-mismatch" ] )\n',
        text, count=1,
    )
sconstruct.write_text(text)
print("  [a] SConstruct")

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
print("  [a2] SConstruct rpath")

# ── b) TweakPlug.cpp: fmt::format enum fix ──
tweak = root / "src/Gaffer/TweakPlug.cpp"
text = tweak.read_text()
old = '                throw IECore::Exception( fmt::format( "Not a valid tweak mode: {}.", mode ) );'
new = '                throw IECore::Exception( fmt::format( "Not a valid tweak mode: {}.", TweakPlug::modeToString( mode ) ) );'
if old in text:
    text = text.replace(old, new)
tweak.write_text(text)
print("  [b] TweakPlug.cpp")

# ── c) bin/gaffer: macOS Python.framework launcher ──
launcher = root / "bin/gaffer"
text = launcher.read_text()
if 'gafferPythonHome="$rootDir/lib/Python.framework/Versions/Current"' not in text:
    text = re.sub(
        r'# Unset PYTHONHOME to make sure our internal Python build is used in\n# preference to anything in the external environment\.\nunset PYTHONHOME\n',
        'gafferPythonHome="$rootDir/lib/Python.framework/Versions/Current"\n'
        'gafferPython="$gafferPythonHome/bin/python3.11"\n\n'
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
# Ensure DYLD_LIBRARY_PATH is set for macOS (LD_LIBRARY_PATH doesn't work)
if 'DYLD_LIBRARY_PATH' not in text:
    text = text.replace(
        'prependToPath "$rootDir/lib" DYLD_FRAMEWORK_PATH\nfi',
        'prependToPath "$rootDir/lib" DYLD_FRAMEWORK_PATH\n\tprependToPath "$rootDir/lib" DYLD_LIBRARY_PATH\nfi',
    )
launcher.write_text(text)
print("  [c] bin/gaffer")

# ── i) macosCPUFallback.py: CPU-only Cycles device list ──
startup = root / "startup/GafferCycles/macosCPUFallback.py"
startup.write_text(
    'import sys\n\n'
    'if sys.platform == "darwin" :\n\n'
    '\timport IECore\n'
    '\timport GafferCycles\n\n'
    '\tcpuDevice = GafferCycles.devices.get( "CPU" )\n'
    '\tif cpuDevice is not None :\n'
    '\t\tGafferCycles.devices = IECore.CompoundData( { "CPU" : cpuDevice } )\n'
)
print("  [i] macosCPUFallback.py")

# ── d) Renderer.cpp: default Cycles to SVM on macOS ──
# OSL's bundled LLVM 15 legacy pass manager crashes on ARM64 macOS
# (EXC_BREAKPOINT in addLowerLevelRequiredPass).

renderer = root / "src/GafferCycles/IECoreCyclesPreview/Renderer.cpp"
rtxt = renderer.read_text()

# d.1) Null-out "defaultsurface" shader name
old_surf = (
    '\t\t\tsurfaceShaderAttribute = surfaceShaderAttribute ? surfaceShaderAttribute : attribute<IECoreScene::ShaderNetwork>( g_surfaceShaderAttributeName, attributes );\n'
    '\t\t\tif( !surfaceShaderAttribute && !volumeShaderAttribute )\n'
)
new_surf = (
    '\t\t\tsurfaceShaderAttribute = surfaceShaderAttribute ? surfaceShaderAttribute : attribute<IECoreScene::ShaderNetwork>( g_surfaceShaderAttributeName, attributes );\n'
    '\t\t\t// The default IECoreScene::Shader constructor uses the name\n'
    '\t\t\t// "defaultsurface", which is not a valid Cycles shader. Treat\n'
    '\t\t\t// it as "no shader assigned" so the facing-ratio fallback is\n'
    '\t\t\t// used instead, avoiding an empty ShaderGraph that crashes\n'
    "\t\t\t// Cycles' SVM compiler.\n"
    '\t\t\tif(\n'
    '\t\t\t\tsurfaceShaderAttribute &&\n'
    '\t\t\t\tsurfaceShaderAttribute->getOutput().shader.string().size() &&\n'
    '\t\t\t\tsurfaceShaderAttribute->getShader( surfaceShaderAttribute->getOutput().shader )->getName() == "defaultsurface"\n'
    '\t\t\t)\n'
    '\t\t\t{\n'
    '\t\t\t\tsurfaceShaderAttribute = nullptr;\n'
    '\t\t\t}\n'
    '\t\t\tif( !surfaceShaderAttribute && !volumeShaderAttribute )\n'
)
if old_surf in rtxt:
    rtxt = rtxt.replace(old_surf, new_surf, 1)

# d.2) Default session params to SVM on macOS
rtxt = rtxt.replace(
    'ccl::SessionParams defaultSessionParams( IECoreScenePreview::Renderer::RenderType renderType )\n'
    '{\n'
    '\tccl::SessionParams params;\n'
    '\tparams.device = firstCPUDevice();\n'
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_OSL;\n',
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
    1
)

# d.3) Default scene params to SVM on macOS
rtxt = rtxt.replace(
    'ccl::SceneParams defaultSceneParams( IECoreScenePreview::Renderer::RenderType renderType )\n'
    '{\n'
    '\tccl::SceneParams params;\n'
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_OSL;\n',
    'ccl::SceneParams defaultSceneParams( IECoreScenePreview::Renderer::RenderType renderType )\n'
    '{\n'
    '\tccl::SceneParams params;\n'
    '#ifdef __APPLE__\n'
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_SVM;\n'
    '#else\n'
    '\tparams.shadingsystem = ccl::SHADINGSYSTEM_OSL;\n'
    '#endif\n',
    1
)

# d.4) Add g_defaultShadingSystem constant
rtxt = rtxt.replace(
    'IECore::InternedString g_shadingsystemSVM( "SVM" );\n\n'
    'ccl::ShadingSystem nameToShadingSystemEnum(',
    'IECore::InternedString g_shadingsystemSVM( "SVM" );\n\n'
    '#ifdef __APPLE__\n'
    'const char *g_defaultShadingSystem = "SVM";\n'
    '#else\n'
    'const char *g_defaultShadingSystem = "OSL";\n'
    '#endif\n\n'
    'ccl::ShadingSystem nameToShadingSystemEnum(',
    1
)

# d.5) Use g_defaultShadingSystem in option lookups
rtxt = rtxt.replace(
    'params.shadingsystem = nameToShadingSystemEnum( optionValue<string>( g_shadingsystemOptionName, "OSL", modified ) );',
    'params.shadingsystem = nameToShadingSystemEnum( optionValue<string>( g_shadingsystemOptionName, g_defaultShadingSystem, modified ) );',
)

renderer.write_text(rtxt)
print("  [d] Renderer.cpp")

# ── e) ShaderNetworkAlgo.cpp: DiffuseBsdf fallback ──
snalgo = root / "src/GafferCycles/IECoreCyclesPreview/ShaderNetworkAlgo.cpp"
stxt = snalgo.read_text()
old_sna = (
    '\t\tccl::ShaderNode *node = convertWalk( toConvert->getOutput(), toConvert.get(), namePrefix, shaderManager, graph.get(), converted );\n'
    '\n'
    '\t\tif( node )\n'
)
new_sna = (
    '\t\tccl::ShaderNode *node = convertWalk( toConvert->getOutput(), toConvert.get(), namePrefix, shaderManager, graph.get(), converted );\n'
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
snalgo.write_text(stxt)
print("  [e] ShaderNetworkAlgo.cpp")

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
vset.write_text(vtxt)
print("  [f] cyclesViewerSettings.gfr")

# ── g) shaderView.py: SVM on macOS ──
sview = root / "startup/gui/shaderView.py"
svtxt = sview.read_text()
svtxt = svtxt.replace(
    '\t\t\t# Less issues when mixing around OSL shaders\n'
    '\t\t\tresult["shadingSystem"]["enabled"].setValue( True )\n'
    '\t\t\tresult["shadingSystem"]["value"].setValue( "OSL" )\n',
    '\t\t\timport sys\n'
    '\t\t\t_shadingSys = "SVM" if sys.platform == "darwin" else "OSL"\n'
    '\t\t\tresult["shadingSystem"]["enabled"].setValue( True )\n'
    '\t\t\tresult["shadingSystem"]["value"].setValue( _shadingSys )\n',
    1
)
sview.write_text(svtxt)
print("  [g] shaderView.py")

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
print("  [h] OutputBuffer.cpp")

print("All patches applied.")
PY
}

# ── 5. Write helper scripts ─────────────────────────────────────────

write_python_wrappers() {
  rm -f "$BUILD_DIR/bin/python" "$BUILD_DIR/bin/python3"
  cat > "$BUILD_DIR/bin/python" <<'WRAPPER'
#!/bin/bash
set -e
rootDir="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONHOME="$rootDir/lib/Python.framework/Versions/Current"
exec "$rootDir/lib/Python.framework/Versions/Current/bin/python3.11" "$@"
WRAPPER
  cp "$BUILD_DIR/bin/python" "$BUILD_DIR/bin/python3"
  chmod +x "$BUILD_DIR/bin/python" "$BUILD_DIR/bin/python3"
}

# ── 6. Build ────────────────────────────────────────────────────────

build_gaffer() {
  step "Building Gaffer"
  ( cd "$RELEASE_DIR" && \
    scons -j "$(sysctl -n hw.ncpu)" build \
      BUILD_DIR="$BUILD_DIR" )
}

# ── 6b. Fix install names of freshly-built Gaffer libs ──────────────

fixup_gaffer_install_names() {
  step "Fixing install names of built libraries"
  local bd="$BUILD_DIR"

  # Fix dylibs in lib/ — change id from "lib/libXxx.dylib" to "@rpath/libXxx.dylib"
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
  for f in "$bd"/lib/*.dylib "$bd"/python/*/*.so; do
    [ -f "$f" ] || continue
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

# ── 8. Smoke test ───────────────────────────────────────────────────

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
  build_gaffer
  fixup_gaffer_install_names
  patch_menu_shortcut_labels
  smoke_test

  echo ""
  echo "Build complete. Launch Gaffer with:"
  echo "  ./build-$TAG/bin/gaffer"
}

main "$@"
