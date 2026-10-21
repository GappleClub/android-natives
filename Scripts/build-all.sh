#!/bin/bash
#
# Compila todos los nativos que Minecraft 26.3+ necesita en Android (arm64-v8a) y los deja en
# dist/natives-android-arm64-v8a.zip. Pensado para el runner Linux de GitHub Actions.
#
# SDL3, LWJGL y shaderc salen de los scripts de FlameLauncher-SDL3 (Scripts/upstream, sin tocar,
# AGPL-3.0). Esos scripts están hechos para macOS: aquí se adaptan a Linux al vuelo con sed, así
# actualizarlos es copiar los archivos nuevos encima.
#
# Uso: ANDROID_NDK_HOME=... Scripts/build-all.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${ANDROID_NDK_HOME:?falta ANDROID_NDK_HOME}"
NDK="$ANDROID_NDK_HOME"
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
API=26
OUT="$ROOT/out/arm64-v8a"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Versiones fijas: con main cada compilación sale distinta y un día falta una función sin avisar.
SDL_REF=release-3.4.16          # la misma que FlameLauncher probó con lwjgl-sdl 3.4.3
LWJGL_REF=3.4.3                 # la que pide Minecraft 26.3
SHADERC_REF=v2026.4
SPVC_REF=vulkan-sdk-1.4.363.0
OPENAL_REF=1.25.2
FREETYPE_REF=VER-2-15-0
export SDL_REF SHADERC_REF

rm -rf "$ROOT/Runtime" "$OUT"
mkdir -p "$OUT"

# ── Scripts de FlameLauncher, adaptados a Linux ─────────────────────────────────────
# Van en .linux/ (en la raíz) porque calculan su ROOT como la carpeta de arriba de la suya.
mkdir -p "$ROOT/.linux" "$ROOT/Runtime"
for f in build-sdl3.sh build-lwjgl-natives-android.sh build-shaderc.sh; do
  sed -e 's/sysctl -n hw.ncpu/nproc/g' -e 's/darwin-x86_64/linux-x86_64/g' \
    "$ROOT/Scripts/upstream/$f" > "$ROOT/.linux/$f"
  chmod +x "$ROOT/.linux/$f"
done

"$ROOT/.linux/build-sdl3.sh" android
"$ROOT/.linux/build-lwjgl-natives-android.sh" "$LWJGL_REF"
"$ROOT/.linux/build-shaderc.sh" android

cp "$ROOT/Runtime/SDL3/android/arm64-v8a/libSDL3.so" "$OUT/"
cp "$ROOT/Runtime/lwjgl341/android/arm64-v8a/"*.so "$OUT/"
cp "$ROOT/Runtime/shaderc/android/arm64-v8a/libshaderc.so" "$OUT/"

# ── Lo que FlameLauncher no compila para Android: spirv-cross, OpenAL y FreeType ────
# Los tres son CMake normal con el NDK. LWJGL los abre por nombre de archivo y con punteros a
# función, así que basta la biblioteca del proyecto original con el nombre que LWJGL busca.
TOOLCHAIN=(-G Ninja -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$API)

build_cmake() {   # build_cmake <repo> <tag> <nombre> <opciones cmake…>
  local repo="$1" ref="$2" name="$3"; shift 3
  echo "▸ $name ($ref)"
  git clone -q --depth 1 --branch "$ref" "https://github.com/$repo.git" "$WORK/$name"
  cmake -S "$WORK/$name" -B "$WORK/$name/b" "${TOOLCHAIN[@]}" "$@" > "$WORK/$name.log" 2>&1 \
    || { tail -25 "$WORK/$name.log"; return 1; }
  cmake --build "$WORK/$name/b" -j"$(nproc)" > "$WORK/$name.log" 2>&1 \
    || { grep -E "error" "$WORK/$name.log" | head -15; return 1; }
}

# Minecraft carga spvc al arrancar, siempre. LWJGL busca "libspirv-cross.so".
build_cmake KhronosGroup/SPIRV-Cross "$SPVC_REF" spvc \
  -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_STATIC=OFF -DSPIRV_CROSS_CLI=OFF \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF
cp "$WORK/spvc/b/libspirv-cross-c-shared.so" "$OUT/libspirv-cross.so"

build_cmake kcat/openal-soft "$OPENAL_REF" openal \
  -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_INSTALL=OFF -DALSOFT_EMBED_HRTF_DATA=ON
cp "$WORK/openal/b/libopenal.so" "$OUT/"

# Sin zlib/png/brotli/harfbuzz externos: Minecraft solo pinta fuentes TrueType.
build_cmake freetype/freetype "$FREETYPE_REF" freetype \
  -DBUILD_SHARED_LIBS=ON -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
  -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
cp "$WORK/freetype/b/libfreetype.so" "$OUT/"

# ── Comprobación final ─────────────────────────────────────────────────────────────
# Cada archivo tiene que ser arm64 y exportar la función que LWJGL pide primero. Se descubre
# aquí y no en el móvil.
check() {   # check <archivo> <símbolo>
  local f="$OUT/$1" syms
  case "$(file -L "$f")" in *aarch64*) ;; *) echo "✗ $1 no es arm64"; exit 1 ;; esac
  syms=$("$BIN/llvm-nm" -D --defined-only "$f")
  case "$syms" in *" T $2"*) ;; *) echo "✗ $1 no exporta $2"; exit 1 ;; esac
}
check libSDL3.so SDL_Vulkan_CreateSurface
check liblwjgl.so JNI_OnLoad
check libshaderc.so shaderc_compile_options_set_max_id_bound
check libspirv-cross.so spvc_context_create
check libopenal.so alcOpenDevice
check libfreetype.so FT_Init_FreeType
for f in "$OUT"/*.so; do "$BIN/llvm-strip" --strip-unneeded "$f"; done

mkdir -p "$ROOT/dist"
(cd "$OUT" && zip -q "$ROOT/dist/natives-android-arm64-v8a.zip" ./*.so)
(cd "$ROOT/dist" && sha256sum natives-android-arm64-v8a.zip > natives-android-arm64-v8a.zip.sha256)
ls -l "$OUT" "$ROOT/dist"
