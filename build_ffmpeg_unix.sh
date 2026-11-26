#!/usr/bin/env bash
# =============================================================================
# FFmpeg estático (libs embutidas) para Linux x64, macOS Intel e macOS ARM.
# Build NATIVO (sem cross-compile): rode em cada plataforma/arquitetura.
# Inclui: LCEVCdec, mpeghdec (MPEG-H 3D Audio), x265 (8/10/12 bits) e as mesmas
# libs do script win64 (+ OpenSSL estático, já que não há schannel fora do Windows).
# (H.266/VVC: decoder nativo do FFmpeg, sem biblioteca externa)
#
# Uso:   bash build_ffmpeg_unix.sh <linux64|macos-intel|macos-arm64>
# Log:   ~/build_<alvo>/build.log
# Saída: ~/build_<alvo>/ffmpeg_out/bin/ffmpeg
#
# Compatível com bash 3.2 (macOS): sem mapfile, sem arrays vazios expandidos.
# =============================================================================
set -Eeuo pipefail

TARGET="${1:-${TARGET:-}}"
case "$TARGET" in
  linux64)     OS=linux; ARCH=x86_64; CXXLIB=stdc++ ;;
  macos-intel) OS=macos; ARCH=x86_64; CXXLIB=c++ ;;
  macos-arm64) OS=macos; ARCH=arm64;  CXXLIB=c++ ;;
  *) echo "Uso: bash $0 <linux64|macos-intel|macos-arm64>" >&2; exit 1 ;;
esac

# Build é nativo: confere se a máquina bate com o alvo pedido.
HOST_OS="$(uname -s)"; HOST_ARCH="$(uname -m)"
case "$TARGET" in
  linux64)     [ "$HOST_OS" = Linux ]  && [ "$HOST_ARCH" = x86_64 ] || { echo "ERRO: linux64 exige Linux x86_64 (atual: $HOST_OS $HOST_ARCH)"; exit 1; } ;;
  macos-intel) [ "$HOST_OS" = Darwin ] && [ "$HOST_ARCH" = x86_64 ] || { echo "ERRO: macos-intel exige macOS x86_64 (atual: $HOST_OS $HOST_ARCH)"; exit 1; } ;;
  macos-arm64) [ "$HOST_OS" = Darwin ] && [ "$HOST_ARCH" = arm64 ]  || { echo "ERRO: macos-arm64 exige macOS arm64 (atual: $HOST_OS $HOST_ARCH)"; exit 1; } ;;
esac

BASE="$HOME/build_$TARGET"
SRC="$BASE/src"
PREFIX="$BASE/prefix"
OUT="$BASE/ffmpeg_out"
STAMPS="$PREFIX/.stamps"
MIN_MACOS="11.0"

if [ "$OS" = macos ]; then JOBS="$(sysctl -n hw.ncpu)"; else JOBS="$(nproc)"; fi
if [ "$ARCH" = x86_64 ]; then X86=1; else X86=0; fi

mkdir -p "$SRC" "$PREFIX/lib/pkgconfig" "$PREFIX/bin" "$OUT" "$STAMPS"
exec > >(tee -a "$BASE/build.log") 2>&1
trap 'echo; echo "### ERRO na linha $LINENO: comando \"$BASH_COMMAND\" falhou. Veja o log acima / $BASE/build.log"' ERR

step() { echo; echo "=================== $* ==================="; }

# -----------------------------------------------------------------------------
step "1/4 Dependências do sistema ($TARGET)"
# -----------------------------------------------------------------------------
if [ "$OS" = linux ]; then
  if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
  $SUDO apt-get update
  $SUDO apt-get install -y \
    build-essential git cmake ninja-build nasm yasm pkg-config curl ca-certificates \
    autoconf automake libtool gperf bison flex ragel autopoint gettext \
    python3-pip perl zip xz-utils
  # meson do apt costuma ser antigo demais para libass/harfbuzz atuais
  python3 -m pip install --user meson 2>/dev/null \
    || python3 -m pip install --user --break-system-packages meson
  export PATH="$HOME/.local/bin:$PATH"
else
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
  brew install cmake ninja meson nasm yasm autoconf automake libtool gperf zip || true
  command -v pkg-config >/dev/null 2>&1 || brew install pkgconf
  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
fi
for t in cmake ninja meson nasm pkg-config git perl; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERRO: '$t' não encontrado no PATH"; exit 1; }
done

# -----------------------------------------------------------------------------
step "2/4 Ambiente isolado (pkg-config, flags, cmake, meson)"
# -----------------------------------------------------------------------------
# pkg-config enxerga APENAS o que compilamos em $PREFIX (evita vazar libs do
# sistema/Homebrew para dentro do binário).
export PKG_CONFIG_DIR=
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# -fPIC: no Linux, PIE por padrão exige que as .a estáticas sejam PIC.
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"

# Flags comuns a todos os projetos CMake.
# CMAKE_POLICY_VERSION_MINIMUM evita falha com CMake 4.x em projetos antigos (ex.: x265).
CMAKE_COMMON=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DBUILD_SHARED_LIBS=OFF
)
if [ "$OS" = macos ]; then
  CMAKE_COMMON+=(
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS"
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    # impede o CMake de achar libs do Homebrew (dylibs vazariam para o binário)
    "-DCMAKE_IGNORE_PATH=/usr/local/lib;/usr/local/include;/opt/homebrew/lib;/opt/homebrew/include"
  )
fi

MESON_COMMON=(
  --prefix="$PREFIX"
  --libdir=lib
  --default-library=static
  --buildtype=release
)

cd "$SRC"

# ----------------------------- helpers ---------------------------------------
clone() { # clone <url> <dir> [--full | --branch <ref>]
  local url="$1" dir="$2" mode="${3:-}" ref="${4:-}"
  if [ ! -d "$dir/.git" ]; then
    rm -rf "$dir"
    case "$mode" in
      --full)   git clone "$url" "$dir" ;;
      --branch) git clone --depth 1 --branch "$ref" "$url" "$dir" ;;
      *)        git clone --depth 1 "$url" "$dir" ;;
    esac
  fi
}

cmake_build() { # cmake_build <srcdir> <builddir> [args...]
  local s="$1" b="$2"; shift 2
  rm -rf "$b"
  cmake -S "$s" -B "$b" "${CMAKE_COMMON[@]}" "$@"
  cmake --build "$b" -j"$JOBS"
  cmake --install "$b"
}

meson_build() { # meson_build <srcdir> <builddir> [args...]
  local s="$1" b="$2"; shift 2
  rm -rf "$b"
  meson setup "$b" "$s" "${MESON_COMMON[@]}" "$@"
  ninja -C "$b" -j"$JOBS"
  ninja -C "$b" install
}

# Une várias .a em uma só (GNU ar -M no Linux, libtool -static no macOS).
merge_static() { # merge_static <saida.a> <entrada.a>...
  local out="$1"; shift
  local tmp="$out.merge.tmp"
  rm -f "$tmp"
  if [ "$OS" = macos ]; then
    libtool -static -o "$tmp" "$@"
  else
    { echo "CREATE $tmp"; for a in "$@"; do echo "ADDLIB $a"; done; echo "SAVE"; echo "END"; } | ar -M
  fi
  mv -f "$tmp" "$out"
  ranlib "$out"
}

# Marca/pula bibliotecas já compiladas (o $PREFIX inteiro é cacheado pelo workflow).
once() { # once <nome> <função>
  local name="$1" fn="$2"
  if [ -f "$STAMPS/$name" ]; then
    echo "[cache] $name já compilado, pulando."
    return 0
  fi
  step "$name"
  "$fn"
  touch "$STAMPS/$name"
}

# ================= BASE & COMPRESSÃO =================
build_zlib() {
  clone https://github.com/madler/zlib.git zlib
  ( cd zlib && { make distclean >/dev/null 2>&1 || true; } \
    && ./configure --prefix="$PREFIX" --static && make -j"$JOBS" && make install )
}

build_bzip2() {
  clone https://sourceware.org/git/bzip2.git bzip2
  make -C bzip2 clean || true
  make -C bzip2 CFLAGS="$CFLAGS -D_FILE_OFFSET_BITS=64" libbz2.a -j"$JOBS"
  cp -f bzip2/bzlib.h "$PREFIX/include/"
  cp -f bzip2/libbz2.a "$PREFIX/lib/"
}

build_xz() {
  clone https://github.com/tukaani-project/xz.git xz
  cmake_build xz xz/build -DXZ_TOOLS=OFF -DXZ_NLS=OFF
}

build_openssl() {
  # TLS para https/hls/dash (no Windows isso vem do schannel). Branch LTS estável.
  clone https://github.com/openssl/openssl.git openssl --branch openssl-3.5
  local conf
  if [ "$OS" = linux ]; then conf=linux-x86_64
  elif [ "$ARCH" = arm64 ]; then conf=darwin64-arm64-cc
  else conf=darwin64-x86_64-cc; fi
  ( cd openssl
    { make distclean >/dev/null 2>&1 || true; }
    ./Configure "$conf" no-shared no-tests no-docs --prefix="$PREFIX" --libdir=lib
    make -j"$JOBS"
    make install_sw )
}

build_libxml2() {
  # Essencial para demuxer DASH/MPD, SmoothStreaming e legendas TTML/IMF
  clone https://gitlab.gnome.org/GNOME/libxml2.git libxml2
  cmake_build libxml2 libxml2/build \
    -DLIBXML2_WITH_ICONV=ON -DLIBXML2_WITH_LZMA=ON -DLIBXML2_WITH_ZLIB=ON \
    -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_TESTS=OFF
}

# ================= IMAGENS & CORES =================
build_libpng() {
  clone https://github.com/pnggroup/libpng.git libpng
  cmake_build libpng libpng/build -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
}

build_libjpeg_turbo() {
  clone https://github.com/libjpeg-turbo/libjpeg-turbo.git libjpeg-turbo
  cmake_build libjpeg-turbo libjpeg-turbo/build -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF
}

build_libwebp() {
  clone https://chromium.googlesource.com/webm/libwebp libwebp
  cmake_build libwebp libwebp/build \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
}

build_openjpeg() {
  clone https://github.com/uclouvain/openjpeg.git openjpeg
  cmake_build openjpeg openjpeg/build -DBUILD_STATIC_LIBS=ON -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF
}

build_zimg() {
  clone https://github.com/sekrit-twc/zimg.git zimg --full
  git -C zimg submodule update --init --recursive
  ( cd zimg && ./autogen.sh \
    && ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-pic \
    && make -j"$JOBS" && make install )
}

# ================= LEGENDAS & TEXTO =================
build_freetype() {
  clone https://gitlab.freedesktop.org/freetype/freetype.git freetype
  cmake_build freetype freetype/build -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON
}

build_fribidi() {
  clone https://github.com/fribidi/fribidi.git fribidi
  meson_build fribidi fribidi/build -Ddocs=false -Dbin=false -Dtests=false
}

build_harfbuzz() {
  clone https://github.com/harfbuzz/harfbuzz.git harfbuzz
  meson_build harfbuzz harfbuzz/build \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
    -Dicu=disabled -Dtests=disabled -Dutilities=disabled -Ddocs=disabled
}

build_libass() {
  # Linux: sem fontconfig (estático e sem dependências); use fontsdir/fontes embutidas.
  # macOS: CoreText como provedor de fontes do sistema.
  clone https://github.com/libass/libass.git libass
  local provider
  if [ "$OS" = macos ]; then provider="-Dcoretext=enabled"; else provider="-Dcoretext=disabled"; fi
  meson_build libass libass/build \
    -Dfontconfig=disabled -Ddirectwrite=disabled "$provider" \
    -Dtest=disabled -Dcompare=disabled -Dprofile=disabled
}

build_aribb24() {
  # Closed Captions / Legendas de TV Digital ISDB-Tb
  clone https://github.com/nkoriyama/aribb24.git aribb24
  ( cd aribb24 && ./bootstrap \
    && ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-pic \
    && make -j"$JOBS" && make install )
}

# ================= ÁUDIO =================
build_fdk_aac() {
  clone https://github.com/mstorsjo/fdk-aac.git fdk-aac
  cmake_build fdk-aac fdk-aac/build -DBUILD_PROGRAMS=OFF
}

build_opus() {
  clone https://github.com/xiph/opus.git opus
  cmake_build opus opus/build -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
}

build_ogg() {
  clone https://github.com/xiph/ogg.git ogg
  cmake_build ogg ogg/build -DBUILD_TESTING=OFF
}

build_vorbis() {
  clone https://github.com/xiph/vorbis.git vorbis
  cmake_build vorbis vorbis/build -DBUILD_TESTING=OFF
}

build_lame() {
  clone https://github.com/rbrito/lame.git lame
  local asm=""
  [ "$X86" = 1 ] && asm="--enable-nasm"
  ( cd lame
    { make distclean >/dev/null 2>&1 || true; }
    ./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-frontend \
      --disable-gtktest --with-pic $asm
    make -j"$JOBS"
    make install )
}

build_soxr() {
  clone https://git.code.sf.net/p/soxr/code soxr
  cmake_build soxr soxr/build -DBUILD_TESTS=OFF -DWITH_OPENMP=OFF -DBUILD_EXAMPLES=OFF
  cat > "$PREFIX/lib/pkgconfig/soxr.pc" << EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: soxr
Description: High quality, one-dimensional sample-rate conversion library
Version: 0.1.3
Libs: -L\${libdir} -lsoxr -lm
Cflags: -I\${includedir}
EOF
}

# ================= VÍDEO =================
build_nv_codec_headers() { # só Linux (NVENC/CUVID via dlopen em runtime)
  clone https://github.com/FFmpeg/nv-codec-headers.git nv-codec-headers
  make -C nv-codec-headers PREFIX="$PREFIX" install
}

build_x264() {
  clone https://code.videolan.org/videolan/x264.git x264
  ( cd x264
    { make distclean >/dev/null 2>&1 || true; }
    ./configure --prefix="$PREFIX" --enable-static --enable-pic --disable-cli
    make -j"$JOBS"
    make install )
}

build_libvpx() {
  clone https://chromium.googlesource.com/webm/libvpx.git libvpx
  ( cd libvpx
    { make distclean >/dev/null 2>&1 || true; }
    ./configure --prefix="$PREFIX" --enable-static --disable-shared --enable-pic \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests \
      --enable-vp9-highbitdepth --enable-runtime-cpu-detect
    make -j"$JOBS"
    make install )
}

build_dav1d() {
  clone https://code.videolan.org/videolan/dav1d.git dav1d
  meson_build dav1d dav1d/build -Denable_tools=false -Denable_tests=false
}

build_svtav1() {
  clone https://gitlab.com/AOMediaCodec/SVT-AV1.git svt-av1
  cmake_build svt-av1 svt-av1/build -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF
}

build_aom() {
  clone https://aomedia.googlesource.com/aom aom
  local nasm="-DENABLE_NASM=OFF"
  [ "$X86" = 1 ] && nasm="-DENABLE_NASM=ON"
  cmake_build aom aom/build_unix "$nasm" \
    -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF \
    -DENABLE_TOOLS=OFF -DENABLE_TESTDATA=OFF
}

# ================= DTV / TV 3.0 =================
build_lcevc() {
  clone https://github.com/v-novaltd/LCEVCdec.git LCEVCdec
  cmake_build LCEVCdec LCEVCdec/build \
    -DVN_SDK_EXECUTABLES=OFF -DVN_SDK_UNIT_TESTS=OFF -DVN_SDK_SAMPLE_SOURCE=OFF

  # Se gerou várias libs estáticas separadas, une tudo em liblcevc_dec.a
  local libs=() f
  while IFS= read -r f; do libs+=("$f"); done < <(find "$SRC/LCEVCdec/build" -name 'liblcevc*.a' | sort)
  if [ "${#libs[@]}" -gt 1 ]; then
    merge_static "$PREFIX/lib/liblcevc_dec.a" "${libs[@]}"
  fi

  if ! find "$PREFIX" -name 'lcevc_dec.pc' | grep -q .; then
    local extra=""
    [ "$OS" = linux ] && extra=" -ldl"
    cat > "$PREFIX/lib/pkgconfig/lcevc_dec.pc" << EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: lcevc_dec
Description: V-Nova LCEVC Decoder SDK
Version: 4.0.0
Libs: -L\${libdir} -llcevc_dec -l$CXXLIB -lm -lpthread$extra
Cflags: -I\${includedir} -DVN_LCEVC_DEC_STATIC
EOF
  fi
}

build_mpeghdec() {
  # Fraunhofer MPEG-H 3D Audio. BINARIES=ON gera mpeghDecoder / mpeghUIManager.
  clone https://github.com/Fraunhofer-IIS/mpeghdec.git mpeghdec
  local exeflags=""
  [ "$OS" = linux ] && exeflags="-static-libgcc -static-libstdc++"
  cmake_build mpeghdec mpeghdec/build \
    -Dmpeghdec_BUILD_BINARIES=ON -Dmpeghdec_BUILD_DOC=OFF \
    -DCMAKE_EXE_LINKER_FLAGS="$exeflags"

  # Guarda os executáveis no prefixo (que é cacheado) para o empacotamento
  find mpeghdec/build -maxdepth 3 -type f -perm -u+x -iname 'mpegh*' \
    ! -name '*.a' ! -name '*.o' ! -name '*.h' ! -name '*.cmake' ! -name '*.txt' \
    -exec cp -f {} "$PREFIX/bin/" \;

  # O mpeghdec gera várias libs internas e não cria .pc: funde numa libmpeghdec.a única
  local libs=() f
  while IFS= read -r f; do libs+=("$f"); done < <(find "$SRC/mpeghdec/build" -name 'lib*.a' | sort)
  if [ "${#libs[@]}" -gt 0 ]; then
    merge_static "$PREFIX/lib/libmpeghdec.a" "${libs[@]}"
  fi
  cat > "$PREFIX/lib/pkgconfig/mpeghdec.pc" << EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: mpeghdec
Description: Fraunhofer MPEG-H 3D Audio Decoder
Version: 3.0.0
Libs: -L\${libdir} -lmpeghdec -l$CXXLIB -lm -lpthread
Cflags: -I\${includedir}
EOF
}

build_x265() {
  # clone COMPLETO: o CMake do x265 lê a versão das tags do git
  clone https://bitbucket.org/multicoreware/x265_git.git x265_git --full
  git -C x265_git fetch --tags
  local X="$SRC/x265_git"
  rm -rf "$X/build"
  mkdir -p "$X/build/8bit" "$X/build/10bit" "$X/build/12bit"
  local COMMON=("${CMAKE_COMMON[@]}" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF)

  cmake -S "$X/source" -B "$X/build/12bit" "${COMMON[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DMAIN12=ON
  cmake --build "$X/build/12bit" -j"$JOBS"

  cmake -S "$X/source" -B "$X/build/10bit" "${COMMON[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
  cmake --build "$X/build/10bit" -j"$JOBS"

  ln -sf ../10bit/libx265.a "$X/build/8bit/libx265_main10.a"
  ln -sf ../12bit/libx265.a "$X/build/8bit/libx265_main12.a"
  cmake -S "$X/source" -B "$X/build/8bit" "${COMMON[@]}" \
    -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L. \
    -DLINKED_10BIT=ON -DLINKED_12BIT=ON
  cmake --build "$X/build/8bit" -j"$JOBS"

  ( cd "$X/build/8bit"
    mv libx265.a libx265_main.a
    merge_static "$PWD/libx265.a" "$PWD/libx265_main.a" "$PWD/libx265_main10.a" "$PWD/libx265_main12.a" )
  cmake --install "$X/build/8bit"
}

build_sdl2() { # só macOS (ffplay). SDL2 estático; frameworks do sistema são linkados dinamicamente.
  rm -rf sdl2
  git clone --depth 1 --branch SDL2 https://github.com/libsdl-org/SDL.git sdl2
  cmake_build sdl2 sdl2/build -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DSDL_TESTS=OFF
}

# -----------------------------------------------------------------------------
step "3/4 Bibliotecas (puladas se vieram do cache)"
# -----------------------------------------------------------------------------
once zlib           build_zlib
once bzip2          build_bzip2
once xz             build_xz
once openssl        build_openssl
once libxml2        build_libxml2
once libpng         build_libpng
once libjpeg-turbo  build_libjpeg_turbo
once libwebp        build_libwebp
once openjpeg       build_openjpeg
once zimg           build_zimg
once freetype       build_freetype
once fribidi        build_fribidi
once harfbuzz       build_harfbuzz
once libass         build_libass
once aribb24        build_aribb24
once fdk-aac        build_fdk_aac
once opus           build_opus
once ogg            build_ogg
once vorbis         build_vorbis
once lame           build_lame
once soxr           build_soxr
[ "$OS" = linux ] && once nv-codec-headers build_nv_codec_headers
once x264           build_x264
once libvpx         build_libvpx
once dav1d          build_dav1d
once svt-av1        build_svtav1
once aom            build_aom
once LCEVCdec       build_lcevc
once mpeghdec       build_mpeghdec
once x265           build_x265
[ "$OS" = macos ] && once sdl2 build_sdl2

# Ajustes finais nos .pc (idempotente; roda também com o prefixo vindo do cache)
for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
  [ -f "$pc" ] || continue
  perl -pi -e 's/-lgcc_s//g' "$pc"
  if [ "$OS" = macos ]; then perl -pi -e 's/-lstdc\+\+/-lc++/g' "$pc"; fi
done
# libs C++ que às vezes não declaram a libstdc++/libc++ no .pc
for n in zimg x265 lcevc_dec mpeghdec; do
  pc="$PREFIX/lib/pkgconfig/$n.pc"
  [ -f "$pc" ] || continue
  if ! grep -qE -- '-l(std)?c\+\+' "$pc"; then
    perl -pi -e 's/^(Libs:.*)$/$1 -l'"$CXXLIB"'/' "$pc"
  fi
done

# -----------------------------------------------------------------------------
step "4/4 FFmpeg"
# -----------------------------------------------------------------------------
cd "$SRC"
FFMPEG_REF="${FFMPEG_BRANCH:-master}"

if [ ! -d "ffmpeg/.git" ]; then
  rm -rf ffmpeg
  git clone --depth 1 --branch "$FFMPEG_REF" https://github.com/FFmpeg/FFmpeg.git ffmpeg
else
  git -C ffmpeg fetch --depth 1 origin "$FFMPEG_REF"
  git -C ffmpeg checkout FETCH_HEAD
fi

cd ffmpeg
{ make distclean >/dev/null 2>&1 || true; }

GIT_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "git")
if [[ "$FFMPEG_REF" == "master" ]]; then
  BASE_VER=$(cat RELEASE 2>/dev/null || echo "git")
  echo "${BASE_VER}-${GIT_SHORT}" > RELEASE
  EXTRA_VER="$(date +%Y%m%d)-limaalef"
else
  echo "${FFMPEG_REF#n}" > RELEASE
  EXTRA_VER="limaalef"
fi

# O configure do FFmpeg não deve herdar as flags usadas nas libs
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

FF_ARGS=(
  --prefix="$OUT"
  --extra-version="$EXTRA_VER"
  --pkg-config=pkg-config
  --pkg-config-flags="--static"
  --extra-cflags="-I$PREFIX/include"
  --enable-static --disable-shared
  --disable-doc --disable-debug
  # Nada é detectado "por acaso" no sistema/Homebrew: tudo é habilitado explicitamente
  --disable-autodetect
  --enable-gpl --enable-version3 --enable-nonfree
  --enable-openssl
  --enable-zlib --enable-bzlib --enable-lzma --enable-iconv
  --enable-libxml2
  --enable-liblcevc-dec
  --enable-libmpeghdec
  --enable-libx264
  --enable-libx265
  --enable-libvpx
  --enable-libdav1d
  --enable-libsvtav1
  --enable-libaom
  --enable-libwebp
  --enable-libopenjpeg
  --enable-libzimg
  --enable-libfreetype
  --enable-libfribidi
  --enable-libharfbuzz
  --enable-libass
  --enable-libaribb24
  --enable-libfdk-aac
  --enable-libmp3lame
  --enable-libopus
  --enable-libvorbis
  --enable-libsoxr
)

if [ "$OS" = linux ]; then
  FF_ARGS+=(
    --extra-ldflags="-L$PREFIX/lib -static-libgcc -static-libstdc++"
    --extra-libs="-lstdc++ -lpthread -lm -ldl"
    --enable-ffnvcodec --enable-nvenc
    --disable-ffplay
  )
else
  FF_ARGS+=(
    --extra-ldflags="-L$PREFIX/lib"
    --extra-libs="-lc++ -lpthread -lm"
    --enable-videotoolbox --enable-audiotoolbox --enable-avfoundation
    --enable-ffplay --enable-sdl2
  )
fi

./configure "${FF_ARGS[@]}"

make -j"$JOBS"
make install

if [ "$OS" = macos ]; then STRIP_FLAGS="-x"; else STRIP_FLAGS=""; fi
for b in ffmpeg ffprobe ffplay; do
  [ -f "$OUT/bin/$b" ] && strip $STRIP_FLAGS "$OUT/bin/$b" || true
done

# -----------------------------------------------------------------------------
step "Verificação"
# -----------------------------------------------------------------------------
BIN="$OUT/bin/ffmpeg"
file "$BIN"
"$BIN" -hide_banner -version | head -n 3

echo "--- Dependências dinâmicas (devem ser só do sistema) ---"
check_deps() {
  local b="$1" bad
  if [ "$OS" = linux ]; then
    ldd "$b" | tee /dev/stderr \
      | awk '{print $1}' \
      | grep -vE '^(linux-vdso|/lib64/ld-linux|ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libutil\.so)' \
      > "$BASE/deps_unexpected.txt" || true
  else
    otool -L "$b" | tee /dev/stderr | tail -n +2 | awk '{print $1}' \
      | grep -vE '^(/usr/lib/|/System/Library/)' > "$BASE/deps_unexpected.txt" || true
  fi
  bad="$(cat "$BASE/deps_unexpected.txt")"
  if [ -n "$bad" ]; then
    echo "ERRO: $b depende de bibliotecas fora do sistema:"; echo "$bad"; exit 1
  fi
}
check_deps "$BIN"
check_deps "$OUT/bin/ffprobe"

echo "--- Teste rápido de encode (x264, x265 10-bit, SVT-AV1) ---"
"$BIN" -hide_banner -loglevel error -f lavfi -i testsrc=d=1:s=320x240:r=25 -c:v libx264 -f null -
"$BIN" -hide_banner -loglevel error -f lavfi -i testsrc=d=1:s=320x240:r=25 -pix_fmt yuv420p10le -c:v libx265 -f null -
"$BIN" -hide_banner -loglevel error -f lavfi -i testsrc=d=1:s=320x240:r=25 -c:v libsvtav1 -f null -

step "CONCLUÍDO"
echo "Binário: $BIN"
