# android-natives

Bibliotecas nativas para jugar Minecraft 26.3+ en Android (arm64-v8a) desde el launcher
GappleClient: SDL3, LWJGL 3.4.3, shaderc, SPIRV-Cross, OpenAL Soft y FreeType.

Se compilan en GitHub Actions (`.github/workflows/natives.yml`) con `Scripts/build-all.sh`; cada
etiqueta `natives-v*` publica un release con `natives-android-arm64-v8a.zip` y su SHA-256.

## Origen y licencia

Licencia **AGPL-3.0** (ver `LICENSE`).

`Scripts/upstream/` son los scripts de compilación de
[FlameLauncher-SDL3](https://github.com/FlameLaunchers/FlameLauncher-SDL3) (© 2026 Donghyun Yang,
AGPL-3.0), copiados sin cambios del commit que indica `Scripts/upstream/COMMIT`. Su aviso original
está en `Scripts/upstream/NOTICE.FlameLauncher`. `build-all.sh` los adapta a Linux al vuelo.

Proyectos que se compilan (cada uno con su licencia): SDL (Zlib), LWJGL (BSD-3-Clause),
libffi (MIT), shaderc / SPIRV-Tools (Apache-2.0), glslang (BSD-3-Clause y otras),
SPIRV-Cross (Apache-2.0), OpenAL Soft (LGPL-2.0-or-later), FreeType (FTL / GPL-2.0).

Minecraft es marca de Mojang AB. Este proyecto no está afiliado a Mojang AB ni a Microsoft.
