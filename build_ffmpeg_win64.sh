#!/usr/bin/env bash
# =============================================================================
# FFmpeg estático para Windows x64 (cross-compile no Debian/Ubuntu via MinGW-w64)
# Inclui: LCEVCdec, mpeghdec (MPEG-H 3D Audio), x265 (8/10/12 bits)
# (H.266/VVC: decoder nativo do FFmpeg, sem biblioteca externa)
#
# Uso:   bash build_ffmpeg_win64.sh
# Log:   ~/build_win64/build.log
# Saída: ~/build_win64/ffmpeg_out/bin/ffmpeg.exe
# =============================================================================
set -Eeuo pipefail

BASE="$HOME/build_win64"
SRC="$BASE/src"
WIN_PREFIX="$BASE/win64_prefix"
OUT="$BASE/ffmpeg_out"
TC="$BASE/toolchain-mingw64.cmake"
HOST=x86_64-w64-mingw32
JOBS="$(nproc)"

mkdir -p "$SRC" "$WIN_PREFIX" "$OUT"
exec > >(tee -a "$BASE/build.log") 2>&1
trap 'echo; echo "### ERRO na linha $LINENO: comando \"$BASH_COMMAND\" falhou. Veja o log acima / $BASE/build.log"' ERR

step() { echo; echo "=================== $* ==================="; }

# Flags comuns a todos os projetos CMake.
# CMAKE_POLICY_VERSION_MINIMUM evita falha com CMake 4.x em projetos antigos (ex.: x265).
CMAKE_COMMON=(
  -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="$TC"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$WIN_PREFIX"
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

# -----------------------------------------------------------------------------
step "1/8 Dependências do sistema"
# -----------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
$SUDO apt update
$SUDO apt install -y \
  build-essential git cmake ninja-build meson nasm yasm pkg-config curl ca-certificates \
  autoconf automake libtool gperf bison flex ragel \
  mingw-w64 g++-mingw-w64-x86-64 gcc-mingw-w64-x86-64

# -----------------------------------------------------------------------------
step "2/8 MinGW com threads POSIX"
# -----------------------------------------------------------------------------
$SUDO update-alternatives --set ${HOST}-gcc /usr/bin/${HOST}-gcc-posix
$SUDO update-alternatives --set ${HOST}-g++ /usr/bin/${HOST}-g++-posix

for c in gcc g++; do
  if ! ${HOST}-${c} -v 2>&1 | grep -q "Thread model: posix"; then
    echo "ERRO: ${HOST}-${c} não está com thread model posix."
    echo "Rode: sudo update-alternatives --config ${HOST}-${c}  e escolha a opção -posix."
    exit 1
  fi
done
echo "OK: toolchain com threads POSIX."

# -----------------------------------------------------------------------------
step "3/8 Toolchain file do CMake"
# -----------------------------------------------------------------------------
cat > "$TC" << 'TOOLCHAIN_EOF'
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH /usr/x86_64-w64-mingw32 $ENV{WIN_PREFIX})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
TOOLCHAIN_EOF
export WIN_PREFIX   # lido pelo toolchain via $ENV{WIN_PREFIX}

cd "$SRC"

# Clona se ainda não existir (reexecutar o script não rebaixa tudo)
clone() { # clone <url> <dir> [--full]
  if [ ! -d "$2/.git" ]; then
    rm -rf "$2"
    if [ "${3:-}" = "--full" ]; then git clone "$1" "$2"; else git clone --depth 1 "$1" "$2"; fi
  fi
}

# Se todas as libs principais já estiverem instaladas no WIN_PREFIX (vindas do cache), pula para o FFmpeg
if [ ! -f "$WIN_PREFIX/lib/libx265.a" ] || [ ! -f "$WIN_PREFIX/lib/libmpeghdec.a" ] || [ ! -f "$WIN_PREFIX/lib/liblcevc_dec.a" ]; then

# -----------------------------------------------------------------------------
step "4/8 Bibliotecas: LCEVCdec, mpeghdec"
# -----------------------------------------------------------------------------
# 4.1 LCEVCdec (V-Nova)
clone https://github.com/v-novaltd/LCEVCdec.git LCEVCdec
rm -rf LCEVCdec/build
# Correção MinGW: o mingw-w64 < 12 (Ubuntu 24.04 traz o 11.0.1) NÃO declara
# SetThreadDescription em nenhum header, embora a kernel32 exporte o símbolo.
# Injetamos a declaração via -include (compila e linka normalmente).
cat > "$BASE/mingw_compat.h" << 'COMPAT_EOF'
#pragma once
#include <windows.h>
#if defined(__MINGW32__) && defined(__MINGW64_VERSION_MAJOR) && __MINGW64_VERSION_MAJOR < 12
#ifdef __cplusplus
extern "C" {
#endif
WINBASEAPI HRESULT WINAPI SetThreadDescription(HANDLE hThread, PCWSTR lpThreadDescription);
#ifdef __cplusplus
}
#endif
#endif
COMPAT_EOF
cmake -S LCEVCdec -B LCEVCdec/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF \
  -DVN_SDK_EXECUTABLES=OFF \
  -DVN_SDK_UNIT_TESTS=OFF \
  -DVN_SDK_SAMPLE_SOURCE=OFF \
  -DCMAKE_CXX_FLAGS="-include $BASE/mingw_compat.h" \
  -DCMAKE_C_FLAGS="-include $BASE/mingw_compat.h"
cmake --build LCEVCdec/build -j"$JOBS"
cmake --install LCEVCdec/build

# 4.2 (removido) VVdeC: o FFmpeg oficial NÃO tem --enable-libvvdec (era só um patch
# não incorporado). H.266/VVC é decodificado pelo decoder nativo "vvc", ativo por padrão.

# 4.3 mpeghdec (Fraunhofer MPEG-H 3D Audio)
# Correção MinGW: a dependência "ilo" usa _SH_DENYNO / _S_IREAD / _S_IWRITE sem
# incluir <share.h> e <sys/stat.h>; forçamos a inclusão via flags.
# BINARIES=OFF: o ffmpeg só precisa da lib (mude para ON se quiser o .exe).
clone https://github.com/Fraunhofer-IIS/mpeghdec.git mpeghdec
rm -rf mpeghdec/build
cmake -S mpeghdec -B mpeghdec/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF \
  -Dmpeghdec_BUILD_BINARIES=ON \
  -Dmpeghdec_BUILD_DOC=OFF \
  -DCMAKE_CXX_FLAGS="-include share.h -include sys/stat.h" \
  -DCMAKE_EXE_LINKER_FLAGS="-static -static-libgcc -static-libstdc++"
cmake --build mpeghdec/build -j"$JOBS"
cmake --install mpeghdec/build
# Garante que os executáveis fiquem salvos no prefixo em cache:
mkdir -p "$WIN_PREFIX/bin"
find mpeghdec/build -maxdepth 3 -iname 'mpegh*.exe' -exec cp -f {} "$WIN_PREFIX/bin/" \;

# Corrige linkagem estática do mpeghdec no MinGW (remove dllimport e une todas as sub-libs .o):
sed -i 's/__declspec(dllimport)//g' "$WIN_PREFIX"/include/mpeghdec/*.h
mapfile -t MPEGH_OBJS < <(find mpeghdec/build -name '*.o' -o -name '*.obj')
rm -f "$WIN_PREFIX/lib/libmpeghdec.a"
${HOST}-ar rcs "$WIN_PREFIX/lib/libmpeghdec.a" "${MPEGH_OBJS[@]}"
${HOST}-ranlib "$WIN_PREFIX/lib/libmpeghdec.a"

# O mpeghdec gera múltiplas libs internas (.a) na pasta build/lib e não cria .pc.
# Vamos fundi-las numa única libmpeghdec.a e gerar o mpeghdec.pc:
mkdir -p "$WIN_PREFIX/lib/pkgconfig"
(
  cd mpeghdec/build
  mapfile -t MPEGH_LIBS < <(find . -name 'lib*.a')
  {
    echo "CREATE $WIN_PREFIX/lib/libmpeghdec.a"
    for a in "${MPEGH_LIBS[@]}"; do
      echo "ADDLIB $a"
    done
    echo "SAVE"
    echo "END"
  } | ${HOST}-ar -M
  ${HOST}-ranlib "$WIN_PREFIX/lib/libmpeghdec.a"
)

cat > "$WIN_PREFIX/lib/pkgconfig/mpeghdec.pc" << EOF
prefix=$WIN_PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: mpeghdec
Description: Fraunhofer MPEG-H 3D Audio Decoder
Version: 3.0.0
Libs: -L\${libdir} -lmpeghdec -lstdc++ -lm -lpthread
Cflags: -I\${includedir}
EOF

# -----------------------------------------------------------------------------
step "5/8 x265 multilib (8 + 10 + 12 bits)"
# -----------------------------------------------------------------------------
# IMPORTANTE: clone COMPLETO (sem --depth 1). O CMake do x265 lê a versão das
# tags do git; em clone raso a lista fica vazia e o configure falha com
# "list GET given empty list".
clone https://bitbucket.org/multicoreware/x265_git.git x265_git --full
git -C x265_git fetch --tags

X="$SRC/x265_git"
rm -rf "$X/build"
mkdir -p "$X/build/8bit" "$X/build/10bit" "$X/build/12bit"

X265_COMMON=("${CMAKE_COMMON[@]}" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF)

# 12 bits
cmake -S "$X/source" -B "$X/build/12bit" "${X265_COMMON[@]}" \
  -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DMAIN12=ON
cmake --build "$X/build/12bit" -j"$JOBS"

# 10 bits
cmake -S "$X/source" -B "$X/build/10bit" "${X265_COMMON[@]}" \
  -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
cmake --build "$X/build/10bit" -j"$JOBS"

# 8 bits (principal) ligando as libs de 10 e 12 bits
ln -sf ../10bit/libx265.a "$X/build/8bit/libx265_main10.a"
ln -sf ../12bit/libx265.a "$X/build/8bit/libx265_main12.a"
cmake -S "$X/source" -B "$X/build/8bit" "${X265_COMMON[@]}" \
  -DEXTRA_LIB="x265_main10.a;x265_main12.a" \
  -DEXTRA_LINK_FLAGS=-L. \
  -DLINKED_10BIT=ON -DLINKED_12BIT=ON
cmake --build "$X/build/8bit" -j"$JOBS"

# Mescla as três libs numa só libx265.a
(
  cd "$X/build/8bit"
  mv libx265.a libx265_main.a
  ${HOST}-ar -M << 'AR_EOF'
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
AR_EOF
)
cmake --install "$X/build/8bit"

else
  echo "Bibliotecas já encontradas em $WIN_PREFIX (Cache ativo). Pulando direto para o FFmpeg..."
fi

# -----------------------------------------------------------------------------
step "5.1/8 Bibliotecas Extras (Compressão, Imagens, Áudio, Vídeo e Legendas)"
# -----------------------------------------------------------------------------
# Isola o pkg-config para enxergar apenas as bibliotecas Windows compiladas em WIN_PREFIX
export PKG_CONFIG_DIR=
export PKG_CONFIG_LIBDIR="$WIN_PREFIX/lib/pkgconfig:$WIN_PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$WIN_PREFIX/lib/pkgconfig:$WIN_PREFIX/share/pkgconfig"

# Arquivo de cross-compile para projetos que usam Meson (dav1d, harfbuzz, fribidi, libass)
cat > "$BASE/meson-cross.txt" << EOF
[binaries]
c = '${HOST}-gcc'
cpp = '${HOST}-g++'
ar = '${HOST}-ar'
strip = '${HOST}-strip'
pkgconfig = 'pkg-config'
windres = '${HOST}-windres'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

MESON_COMMON=(
  --cross-file="$BASE/meson-cross.txt"
  --prefix="$WIN_PREFIX"
  --libdir=lib
  --default-library=static
  --buildtype=release
)

# ================= BASE & COMPRESSÃO (zlib, bzip2, lzma, iconv, libxml2) =================

# 1. zlib (Ativa PNG, APNG, TIFF, etc. no FFmpeg)
clone https://github.com/madler/zlib.git zlib
rm -f "$WIN_PREFIX/lib/libz"* "$WIN_PREFIX/lib/pkgconfig/zlib.pc"
make -C zlib -f win32/Makefile.gcc clean || true
make -C zlib -f win32/Makefile.gcc PREFIX="${HOST}-" SHARED_MODE=0 -j"$JOBS"
make -C zlib -f win32/Makefile.gcc \
  INCLUDE_PATH="$WIN_PREFIX/include" \
  LIBRARY_PATH="$WIN_PREFIX/lib" \
  BINARY_PATH="$WIN_PREFIX/bin" \
  SHARED_MODE=0 install

cat > "$WIN_PREFIX/lib/pkgconfig/zlib.pc" << EOF
prefix=$WIN_PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library
Version: 1.3.1
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF

# 2. bzip2
clone https://sourceware.org/git/bzip2.git bzip2
make -C bzip2 clean || true
make -C bzip2 CC="${HOST}-gcc" AR="${HOST}-ar" RANLIB="${HOST}-ranlib" libbz2.a -j"$JOBS"
cp -f bzip2/bzlib.h "$WIN_PREFIX/include/"
cp -f bzip2/libbz2.a "$WIN_PREFIX/lib/"

# 3. xz / liblzma
clone https://github.com/tukaani-project/xz.git xz
rm -rf xz/build
cmake -S xz -B xz/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DXZ_TOOLS=OFF -DXZ_NLS=OFF
cmake --build xz/build -j"$JOBS"
cmake --install xz/build

# 4. win-iconv (Conversão de caracteres de legendas Latin1/UTF-8/ARIB)
clone https://github.com/win-iconv/win-iconv.git win-iconv
rm -rf win-iconv/build
cmake -S win-iconv -B win-iconv/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED=OFF -DBUILD_STATIC=ON -DBUILD_EXECUTABLE=OFF -DBUILD_TEST=OFF
cmake --build win-iconv/build -j"$JOBS"
cmake --install win-iconv/build

# 5. libxml2 (Essencial para demuxer DASH/MPD, SmoothStreaming e legendas TTML/IMF)
clone https://gitlab.gnome.org/GNOME/libxml2.git libxml2
rm -rf libxml2/build
cmake -S libxml2 -B libxml2/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLIBXML2_WITH_ICONV=ON \
  -DLIBXML2_WITH_LZMA=ON \
  -DLIBXML2_WITH_ZLIB=ON \
  -DLIBXML2_WITH_PYTHON=OFF \
  -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_TESTS=OFF
cmake --build libxml2/build -j"$JOBS"
cmake --install libxml2/build
# Garante flag estática no libxml-2.0.pc
sed -i 's/^Cflags:/Cflags: -DLIBXML_STATIC/' "$WIN_PREFIX/lib/pkgconfig/libxml-2.0.pc"

# ================= IMAGENS & CORES (PNG, JPEG, WebP, OpenJPEG, zimg) =================

# 6. libpng
clone https://github.com/pnggroup/libpng.git libpng
rm -rf libpng/build
cmake -S libpng -B libpng/build "${CMAKE_COMMON[@]}" \
  -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
cmake --build libpng/build -j"$JOBS"
cmake --install libpng/build

# 7. libjpeg-turbo
clone https://github.com/libjpeg-turbo/libjpeg-turbo.git libjpeg-turbo
rm -rf libjpeg-turbo/build
cmake -S libjpeg-turbo -B libjpeg-turbo/build "${CMAKE_COMMON[@]}" \
  -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF
cmake --build libjpeg-turbo/build -j"$JOBS"
cmake --install libjpeg-turbo/build

# 8. libwebp (WebP e animações WebP)
clone https://chromium.googlesource.com/webm/libwebp libwebp
rm -rf libwebp/build
cmake -S libwebp -B libwebp/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
cmake --build libwebp/build -j"$JOBS"
cmake --install libwebp/build

# 9. OpenJPEG (JPEG 2000 - muito usado em broadcast/cinema digital)
clone https://github.com/uclouvain/openjpeg.git openjpeg
rm -rf openjpeg/build
cmake -S openjpeg -B openjpeg/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF
cmake --build openjpeg/build -j"$JOBS"
cmake --install openjpeg/build

# 10. zimg (Filtro zscale: tonemapping HDR HLG/PQ -> SDR e conversão de cores 10-bit)
clone https://github.com/sekrit-twc/zimg.git zimg --full
git -C zimg submodule update --init --recursive
(
  cd zimg
  ./autogen.sh
  ./configure --host=${HOST} --prefix="$WIN_PREFIX" --enable-static --disable-shared
  make -j"$JOBS"
  make install
)

# ================= LEGENDAS & TEXTO (FreeType, FriBidi, HarfBuzz, libass) =================

# 11. FreeType2 (Renderização de fontes para drawtext e legendas)
clone https://gitlab.freedesktop.org/freetype/freetype.git freetype
rm -rf freetype/build
cmake -S freetype -B freetype/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON
cmake --build freetype/build -j"$JOBS"
cmake --install freetype/build

# 12. FriBidi (Formatação bidirecional de texto para legendas)
clone https://github.com/fribidi/fribidi.git fribidi
rm -rf fribidi/build
meson setup fribidi/build fribidi "${MESON_COMMON[@]}" \
  -Ddocs=false -Dbin=false -Dtests=false
ninja -C fribidi/build -j"$JOBS"
ninja -C fribidi/build install

# 13. HarfBuzz (Shaping de fontes modernas para libass e drawtext)
clone https://github.com/harfbuzz/harfbuzz.git harfbuzz
rm -rf harfbuzz/build
meson setup harfbuzz/build harfbuzz "${MESON_COMMON[@]}" \
  -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
  -Dicu=disabled -Dtests=disabled -D utilities=disabled -Ddocs=disabled
ninja -C harfbuzz/build -j"$JOBS"
ninja -C harfbuzz/build install

# 14. libass (Renderização de legendas ASS/SSA e SRT com estilos no filtro subtitles)
clone https://github.com/libass/libass.git libass
rm -rf libass/build
meson setup libass/build libass "${MESON_COMMON[@]}" \
  -Dfontconfig=disabled -Ddirectwrite=enabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled
ninja -C libass/build -j"$JOBS"
ninja -C libass/build install

# 15. libaribb24 (Decodificador de Closed Captions / Legendas de TV Digital ISDB-Tb)
clone https://github.com/nkoriyama/aribb24.git aribb24
(
  cd aribb24
  ./bootstrap
  ./configure --host=${HOST} --prefix="$WIN_PREFIX" --enable-static --disable-shared
  make -j"$JOBS"
  make install
)

# ================= ÁUDIO (FDK-AAC, Opus, Vorbis, MP3Lame, SoXR) =================

# 16. fdk-aac
clone https://github.com/mstorsjo/fdk-aac.git fdk-aac
rm -rf fdk-aac/build
cmake -S fdk-aac -B fdk-aac/build "${CMAKE_COMMON[@]}" -DBUILD_SHARED_LIBS=OFF -DBUILD_PROGRAMS=OFF
cmake --build fdk-aac/build -j"$JOBS"
cmake --install fdk-aac/build

# 17. libopus
clone https://github.com/xiph/opus.git opus
rm -rf opus/build
cmake -S opus -B opus/build "${CMAKE_COMMON[@]}" -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_PROGRAMS=OFF
cmake --build opus/build -j"$JOBS"
cmake --install opus/build

# 18. libogg & libvorbis
clone https://github.com/xiph/ogg.git ogg
rm -rf ogg/build
cmake -S ogg -B ogg/build "${CMAKE_COMMON[@]}" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
cmake --build ogg/build -j"$JOBS"
cmake --install ogg/build

clone https://github.com/xiph/vorbis.git vorbis
rm -rf vorbis/build
cmake -S vorbis -B vorbis/build "${CMAKE_COMMON[@]}" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
cmake --build vorbis/build -j"$JOBS"
cmake --install vorbis/build

# 19. libmp3lame
clone https://github.com/rbrito/lame.git lame
(
  cd lame
  make distclean >/dev/null 2>&1 || true
  ./configure --host=${HOST} --prefix="$WIN_PREFIX" \
    --enable-static --disable-shared --disable-frontend --enable-nasm
  make -j"$JOBS"
  make install
)

# 20. libsoxr (Resampler de áudio de altíssima qualidade para o filtro aresample=resampler=soxr)
clone https://git.code.sf.net/p/soxr/code soxr
rm -rf soxr/build
cmake -S soxr -B soxr/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DWITH_OPENMP=OFF -DBUILD_EXAMPLES=OFF
cmake --build soxr/build -j"$JOBS"
cmake --install soxr/build
# O soxr não gera .pc completo com -lm no MinGW, criamos um limpo:
cat > "$WIN_PREFIX/lib/pkgconfig/soxr.pc" << EOF
prefix=$WIN_PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: soxr
Description: High quality, one-dimensional sample-rate conversion library
Version: 0.1.3
Libs: -L\${libdir} -lsoxr -lm
Cflags: -I\${includedir}
EOF

# ================= VÍDEO (NVENC, x264, VP8/VP9, AV1: dav1d + SVT-AV1) =================

# 21. nv-codec-headers (NVENC / CUVID / CUDA)
clone https://github.com/FFmpeg/nv-codec-headers.git nv-codec-headers
make -C nv-codec-headers PREFIX="$WIN_PREFIX" install

# 22. x264 (8 e 10 bits unificados)
clone https://code.videolan.org/videolan/x264.git x264
(
  cd x264
  make distclean >/dev/null 2>&1 || true
  ./configure --host=${HOST} --cross-prefix=${HOST}- --prefix="$WIN_PREFIX" \
    --enable-static --disable-cli
  make -j"$JOBS"
  make install
)

# 23. libvpx (VP8 / VP9 encoder e decoder)
clone https://chromium.googlesource.com/webm/libvpx.git libvpx
(
  cd libvpx
  make distclean >/dev/null 2>&1 || true
  CROSS="${HOST}-" ./configure --target=x86_64-win64-gcc --prefix="$WIN_PREFIX" \
    --enable-static --disable-shared --disable-examples --disable-tools \
    --disable-docs --disable-unit-tests --enable-vp9-highbitdepth
  make -j"$JOBS"
  make install
)

# 24. dav1d (Decoder AV1 ultrarrápido)
clone https://code.videolan.org/videolan/dav1d.git dav1d
rm -rf dav1d/build
meson setup dav1d/build dav1d "${MESON_COMMON[@]}" \
  -Denable_tools=false -Denable_tests=false
ninja -C dav1d/build -j"$JOBS"
ninja -C dav1d/build install

# 25. SVT-AV1 (Encoder AV1 oficial de alta performance)
clone https://gitlab.com/AOMediaCodec/SVT-AV1.git svt-av1
rm -rf svt-av1/build
cmake -S svt-av1 -B svt-av1/build "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF
cmake --build svt-av1/build -j"$JOBS"
cmake --install svt-av1/build

# -----------------------------------------------------------------------------
step "6/8 Ajuste dos .pc (libstdc++) e verificação"
# -----------------------------------------------------------------------------
mkdir -p "$WIN_PREFIX/lib/pkgconfig"

# Se o LCEVCdec gerou múltiplas libs estáticas separadas (ex: lcevc_dec_api, core, etc.),
# unifica todas dentro de liblcevc_dec.a para que o -llcevc_dec do FFmpeg funcione de primeira:
if [ -d "$SRC/LCEVCdec/build" ]; then
  mapfile -t LCEVC_LIBS < <(find "$SRC/LCEVCdec/build" -name 'liblcevc*.a')
  if [ "${#LCEVC_LIBS[@]}" -gt 1 ]; then
    (
      echo "CREATE $WIN_PREFIX/lib/liblcevc_dec.a"
      for a in "${LCEVC_LIBS[@]}"; do
        echo "ADDLIB $a"
      done
      echo "SAVE"
      echo "END"
    ) | ${HOST}-ar -M
    ${HOST}-ranlib "$WIN_PREFIX/lib/liblcevc_dec.a"
  fi
fi

# Caso o LCEVCdec não tenha gerado o lcevc_dec.pc na pasta padrão, cria/ajusta:
if ! find "$WIN_PREFIX" -name 'lcevc_dec.pc' | grep -q .; then
cat > "$WIN_PREFIX/lib/pkgconfig/lcevc_dec.pc" << EOF
prefix=$WIN_PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: lcevc_dec
Description: V-Nova LCEVC Decoder SDK
Version: 4.0.0
Libs: -L\${libdir} -llcevc_dec -lstdc++ -lm -lpthread
Cflags: -I\${includedir} -DVN_LCEVC_DEC_STATIC
EOF
fi

for pc in "$WIN_PREFIX"/lib/pkgconfig/*.pc; do
  [ -f "$pc" ] || continue
  sed -i 's/-lgcc_s//g' "$pc"
  grep -q -- '-lstdc++' "$pc" || sed -i '/^Libs:/ s/$/ -lstdc++/' "$pc"
done

# =============================================================================
step "7/8 SDL2 para suportar compilação do FFplay"
# =============================================================================
cd "$SRC"

if [ ! -f "$WIN_PREFIX/lib/libSDL2.a" ]; then
  rm -rf sdl2
  git clone --depth 1 --branch SDL2 https://github.com/libsdl-org/SDL.git sdl2

  cmake -S sdl2 -B sdl2/build "${CMAKE_COMMON[@]}" \
    -DSDL_SHARED=OFF \
    -DSDL_STATIC=ON \
    -DSDL_TEST=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_RENDER_D3D=ON
  cmake --build sdl2/build -j"$JOBS"
  cmake --install sdl2/build

  # Garante que todas as libs do Windows exigidas pela SDL2 estática estejam no sdl2.pc
  if [ -f "$WIN_PREFIX/lib/pkgconfig/sdl2.pc" ]; then
    sed -i '/^Libs:/ s/$/ -lwinmm -limm32 -lole32 -loleaut32 -lversion -luuid -lsetupapi -lgdi32 -luser32 -lshell32/' "$WIN_PREFIX/lib/pkgconfig/sdl2.pc"
  fi
fi

# -----------------------------------------------------------------------------
step "8/8 FFmpeg"
# -----------------------------------------------------------------------------
FFMPEG_REF="${FFMPEG_BRANCH:-master}"

if [ ! -d "ffmpeg/.git" ]; then
  rm -rf ffmpeg
  git clone --depth 1 --branch "$FFMPEG_REF" https://github.com/FFmpeg/FFmpeg.git ffmpeg
else
  git -C ffmpeg fetch --depth 1 origin "$FFMPEG_REF"
  git -C ffmpeg checkout FETCH_HEAD
fi

cd ffmpeg
make distclean >/dev/null 2>&1 || true

# Determina o identificador da versão + assinatura "limaalef"
GIT_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "git")
if [[ "$FFMPEG_REF" == "master" ]]; then
  BASE_VER=$(cat RELEASE 2>/dev/null || echo "git")
  echo "${BASE_VER}-${GIT_SHORT}" > RELEASE
  EXTRA_VER="$(date +%Y%m%d)-limaalef"
else
  # Remove o prefixo 'n' (ex: n7.1 -> 7.1) para ficar limpo no banner
  CLEAN_VER="${FFMPEG_REF#n}"
  echo "${CLEAN_VER}" > RELEASE
  EXTRA_VER="limaalef"
fi

export PKG_CONFIG_DIR=
export PKG_CONFIG_LIBDIR="$WIN_PREFIX/lib/pkgconfig:$WIN_PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$WIN_PREFIX/lib/pkgconfig:$WIN_PREFIX/share/pkgconfig"

./configure \
  --arch=x86_64 \
  --target-os=mingw32 \
  --cross-prefix=${HOST}- \
  --prefix="$OUT" \
  --extra-version="$EXTRA_VER" \
  --pkg-config=pkg-config \
  --pkg-config-flags="--static" \
  --extra-cflags="-I$WIN_PREFIX/include -DLIBXML_STATIC" \
  --extra-ldflags="-L$WIN_PREFIX/lib -static -static-libgcc -static-libstdc++ -Wl,--allow-multiple-definition" \
  --extra-libs="-lstdc++ -lpthread -lm -lgdi32 -ldwrite -lusp10 -luser32 -lwinmm -limm32 -lole32 -loleaut32 -lversion -luuid -ladvapi32 -lshell32 -lsetupapi" \
  --enable-static --disable-shared \
  --enable-ffplay \
  --enable-sdl2 \
  --disable-doc --disable-debug \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-zlib --enable-bzlib --enable-lzma --enable-iconv \
  --enable-libxml2 \
  --enable-schannel \
  --enable-d3d11va --enable-dxva2 --enable-nvenc --enable-ffnvcodec \
  --enable-liblcevc-dec \
  --enable-libmpeghdec \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libvpx \
  --enable-libdav1d \
  --enable-libsvtav1 \
  --enable-libwebp \
  --enable-libopenjpeg \
  --enable-libzimg \
  --enable-libfreetype \
  --enable-libfribidi \
  --enable-libharfbuzz \
  --enable-libass \
  --enable-libaribb24 \
  --enable-libfdk-aac \
  --enable-libmp3lame \
  --enable-libopus \
  --enable-libvorbis \
  --enable-libsoxr

make -j"$JOBS"
make install

${HOST}-strip "$OUT/bin/ffmpeg.exe" "$OUT/bin/ffprobe.exe" "$OUT/bin/ffplay.exe" || true

step "CONCLUÍDO"
file "$OUT/bin/ffmpeg.exe"
echo "DLLs de que o ffmpeg.exe depende (devem ser só do sistema Windows):"
${HOST}-objdump -p "$OUT/bin/ffmpeg.exe" | grep "DLL Name" || true
echo
echo "Binário: $OUT/bin/ffmpeg.exe"