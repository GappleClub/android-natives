#!/bin/bash
#
# Compila Java 25 (el JRE que va dentro del APK como assets/jre.zip) para Android arm64, con todas
# sus bibliotecas alineadas a páginas de 16 KB, y lo deja en dist/jre25-android-arm64.zip.
#
# Por qué: el JRE ya hecho de Amethyst que usábamos tiene sus 33 bibliotecas a 4 KB. En los móviles
# con páginas de 16 KB (Android 15+) la app corre en «modo compatibilidad» y Android anuncia que ese
# modo se podrá apagar. https://developer.android.com/guide/practices/page-sizes
#
# La receta es la pública de AngelAuraMC (angelauramc-openjdk-build, rama fcl/BUILD_JRE_25, la más
# nueva para JDK 25), fijada a un commit y sin copiar nada aquí: se clona y se ejecuta. Lo único
# que se cambia es añadir las opciones de 16 KB al enlazador. Al final se comprueba cada .so: si
# alguno queda a menos de 16 KB, falla.
#
# Uso: Scripts/build-jre.sh   (en el runner Linux de GitHub Actions: usa sudo y apt)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECIPE=https://github.com/AngelAuraMC/angelauramc-openjdk-build
RECIPE_REF=7a0266e745d9b4acf400afa189b58e672900f710   # fcl/BUILD_JRE_25 del 2026-08-08
WORK="$ROOT/.jre"
PAGE_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

rm -rf "$WORK"
git clone -q "$RECIPE" "$WORK"
git -C "$WORK" checkout -q "$RECIPE_REF"
cd "$WORK"

# set_devkit_path.sh define LDFLAGS para todo lo que se compila (las bibliotecas de apoyo y
# OpenJDK con --with-extra-ldflags). Las opciones de 16 KB van al final de esa línea.
sed -i "s|^export LDFLAGS=\"\(.*\)\"\$|export LDFLAGS=\"\1 $PAGE_FLAGS\"|" set_devkit_path.sh
grep -q 'max-page-size=16384' set_devkit_path.sh || { echo "no se pudo poner 16 KB en set_devkit_path.sh"; exit 1; }

bash ci_build_arch_aarch64.sh

TAR="$(ls "$WORK"/jre25-*.tar.xz | head -n 1)"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/jre25-android-arm64.zip"

python3 - "$TAR" "$OUT" <<'PY'
"""Comprueba la alineación de cada ELF y pasa el .tar.xz a .zip (Java no trae lector de .xz)."""
import io, lzma, struct, sys, tarfile, zipfile

src, out = sys.argv[1], sys.argv[2]
PAGE = 16384
bad, elves = [], 0
with tarfile.open(fileobj=lzma.open(src)) as tar, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for m in tar.getmembers():
        # Los únicos enlaces son textos de licencia en legal/: el juego no los necesita.
        if not m.isfile():
            continue
        data = tar.extractfile(m).read()
        name = m.name.lstrip("./")
        if data[:4] == b"\x7fELF" and data[4] == 2:   # ELF de 64 bits
            elves += 1
            phoff, = struct.unpack_from("<Q", data, 0x20)
            phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
            for i in range(phnum):
                p_type, = struct.unpack_from("<I", data, phoff + i * phentsize)
                p_align, = struct.unpack_from("<Q", data, phoff + i * phentsize + 0x30)
                if p_type == 1 and p_align < PAGE:   # PT_LOAD
                    bad.append(f"{name} (alineado a {p_align})")
                    break
        z.writestr(name, data)
print(f"{elves} ELF revisados")
if bad:
    sys.exit("No quedaron a 16 KB:\n  " + "\n  ".join(bad))
PY

( cd "$ROOT/dist" && sha256sum jre25-android-arm64.zip > jre25-android-arm64.zip.sha256 )
echo "listo: $OUT"
