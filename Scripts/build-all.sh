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
OPENAL_REF=1.24.3          # la 1.25 usa rangos de C++ que el libc++ del NDK r28 no tiene
FREETYPE_REF=VER-2-15-0
MOBILEGLUES_REF=97558a69157b033b890958b1e49258c5b51a80c6   # main del 2026-09-22, sin tags recientes
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
# Que se vea por qué falla libffi: el original manda todo a /dev/null.
sed -i 's| >/dev/null 2>&1$||' "$ROOT/.linux/build-lwjgl-natives-android.sh"

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

# MobileGlues (LGPL-2.1): OpenGL de computador sobre OpenGL ES. Lo necesitan los móviles cuyo
# Vulkan no llega a lo que pide Minecraft (los Mali, por ejemplo). Se le aplica
# Scripts/mobileglues-uniform.patch: sin él corta los sombreadores con nombres que contienen
# "uniform" (el terreno de la 26.3). Perfetto no se baja: solo sirve para perfilar.
echo "▸ mobileglues ($MOBILEGLUES_REF)"
git init -q "$WORK/mg" && git -C "$WORK/mg" fetch -q --depth 1 https://github.com/MobileGL-Dev/MobileGlues.git "$MOBILEGLUES_REF"
git -C "$WORK/mg" checkout -q FETCH_HEAD
git -C "$WORK/mg" submodule update -q --init --depth 1 MobileGlues-cpp/3rdparty/xxhash   MobileGlues-cpp/3rdparty/glslang MobileGlues-cpp/3rdparty/SPIRV-Cross MobileGlues-cpp/include/ska
git -C "$WORK/mg" apply "$ROOT/Scripts/mobileglues-uniform.patch"
cmake -S "$WORK/mg/MobileGlues-cpp" -B "$WORK/mg/b" "${TOOLCHAIN[@]}" > "$WORK/mg.log" 2>&1   || { tail -25 "$WORK/mg.log"; exit 1; }
cmake --build "$WORK/mg/b" --target mobileglues -j"$(nproc)" > "$WORK/mg.log" 2>&1   || { grep -E "error" "$WORK/mg.log" | head -15; exit 1; }
cp "$WORK/mg/b/libmobileglues.so" "$OUT/"

# Nativos de Simple Voice Chat (henkelmax, cada uno con su CMake que baja Opus, RNNoise,
# SpeexDSP o LAME). Los del mod son de Linux con glibc y en Android no cargan; gapple-ingame le
# hace cargar estos. Las versiones son las que pide la 2.6.x del mod.
for lib in opus4j:2.1.3 rnnoise4j:2.1.3 speex4j:1.0.3 lame4j:2.1.5; do
  name="${lib%%:*}" ref="${lib#*:}"
  echo "▸ $name ($ref)"
  git clone -q --depth 1 --branch "$ref" "https://github.com/henkelmax/$name.git" "$WORK/$name"
  cmake -S "$WORK/$name/native" -B "$WORK/$name/b" "${TOOLCHAIN[@]}" > "$WORK/$name.log" 2>&1 \
    || { tail -25 "$WORK/$name.log"; exit 1; }
  cmake --build "$WORK/$name/b" -j"$(nproc)" > "$WORK/$name.log" 2>&1 \
    || { grep -E "error" "$WORK/$name.log" | head -15; exit 1; }
  cp "$WORK/$name/b/lib$name.so" "$OUT/"
done

# JNA (la trae Minecraft) publica su nativo para Android; el de Linux pide glibc.
JNA_REF=5.17.0
curl -sfL "https://github.com/java-native-access/jna/raw/$JNA_REF/lib/native/android-aarch64.jar" -o "$WORK/jna.jar"
unzip -q -o -j "$WORK/jna.jar" libjnidispatch.so -d "$OUT"

# ANGLE lo compila Scripts/build-angle.sh en otro trabajo del CI; aquí solo se suma.
cp "$ROOT/angle/"lib*_angle.so "$OUT/"

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
check libmobileglues.so eglGetProcAddress
check libGLESv2_angle.so glDrawArrays
check libEGL_angle.so eglGetDisplay
check libopus4j.so Java_de_maxhenkel_opus4j_OpusEncoder_createEncoder0
check librnnoise4j.so Java_de_maxhenkel_rnnoise4j_Denoiser_createDenoiser0
check libspeex4j.so Java_de_maxhenkel_speex4j_AutomaticGainControl_createAgc0
check liblame4j.so Java_de_maxhenkel_lame4j_Mp3Encoder_createEncoder0
check libjnidispatch.so Java_com_sun_jna_Native_initIDs
for f in "$OUT"/*.so; do "$BIN/llvm-strip" --strip-unneeded "$f"; done

mkdir -p "$ROOT/dist"
(cd "$OUT" && zip -q "$ROOT/dist/natives-android-arm64-v8a.zip" ./*.so)
(cd "$ROOT/dist" && sha256sum natives-android-arm64-v8a.zip > natives-android-arm64-v8a.zip.sha256)
ls -l "$OUT" "$ROOT/dist"
