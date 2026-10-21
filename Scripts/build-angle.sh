#!/bin/bash
#
# Compila ANGLE (BSD-3, Google) para Android arm64: OpenGL ES sobre Vulkan. MobileGlues lo usa en
# los Mali, cuyo OpenGL ES no compila los sombreadores de Minecraft 26.3. Deja libEGL_angle.so y
# libGLESv2_angle.so en angle/. Es la parte lenta: baja Chromium a medias y tarda ~1 h.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANGLE_REF=25e721127e1c6c4c6fa0182b5c234b2c88971175   # rama chromium/7999
WORK="${WORK:-$HOME/angle-work}"
mkdir -p "$WORK" "$ROOT/angle"

git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
export PATH="$WORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0

git init -q "$WORK/angle"
git -C "$WORK/angle" fetch -q --depth 1 https://chromium.googlesource.com/angle/angle "$ANGLE_REF"
git -C "$WORK/angle" checkout -q FETCH_HEAD
cd "$WORK/angle"
python3 scripts/bootstrap.py
sed -i "s/^target_os = .*/target_os = ['android']/" .gclient && grep -q "^target_os = ['android']" .gclient
gclient sync --no-history --shallow -j8

gn gen out/a --args='target_os="android" target_cpu="arm64" is_debug=false is_component_build=false
  angle_enable_vulkan=true angle_enable_gl=false angle_enable_null=false angle_enable_swiftshader=false
  angle_build_all=false angle_enable_wgpu=false symbol_level=0 angle_expose_non_conformant_extensions_and_versions=true'
autoninja -C out/a libEGL libGLESv2

cp out/a/libEGL_angle.so out/a/libGLESv2_angle.so "$ROOT/angle/"
ls -l "$ROOT/angle"
