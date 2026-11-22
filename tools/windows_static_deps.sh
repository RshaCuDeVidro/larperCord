#!/usr/bin/env bash
# Experimental: o .exe único para Windows, sem SDL3.dll, libcurl-x64.dll nem
# libcrypto-3-x64.dll ao lado. Põe em .deps/windows-static o que o build normal leva
# em DLLs (versões e hashes fixos; hash errado para tudo):
#   tools/windows_deps.sh && tools/windows_static_deps.sh
#   zig build -Dtarget=x86_64-windows-gnu -Dsingle-exe=true
# A SDL3 estática vem do pacote do MSYS2. O resto que fala com a rede é compilado aqui
# pelo próprio zig, como no binário portátil de Linux (tools/linux_deps.sh), para a
# conexão sair igual à do Chrome (src/platform/tls_chrome.c): o OpenSSL com o
# certificado comprimido em brotli (o do MSYS2 não tem), o nghttp2 para o HTTP/2 e o
# curl com o SETTINGS do Chrome (tools/curl-chrome-h2.patch). O curl oficial traz outro
# OpenSSL dentro, fora do alcance do app, e o do MSYS2 arrastaria libssh2 e companhia.
# Opus, zlib, libwebp e FreeType continuam vindo de tools/windows_deps.sh.
# O pacote da SDL3 não tem uma seção por função, então o ligador leva cada objeto
# inteiro: compilá-la aqui é o que falta para o .exe encolher de verdade.
set -euo pipefail
cd "$(dirname "$0")/.."
win=$PWD/.deps/windows
[ -f "$win/lib/libz.a" ] || { echo "rode tools/windows_deps.sh antes" >&2; exit 1; }
out=$PWD/.deps/windows-static
dl=$out/dl
mkdir -p "$dl"
rm -rf "$out/include" "$out/lib"
mkdir -p "$out/include" "$out/lib"
msys=https://repo.msys2.org/mingw/ucrt64
get() { # url sha256
    local f="$dl/$(basename "$1")"
    [ -f "$f" ] || curl -fsSL --retry 3 -o "$f" "$1"
    echo "$2  $f" | sha256sum -c --quiet -
    echo "$f"
}
pkg() { # pacote sha256 bibliotecas...: só os headers e as bibliotecas estáticas pedidas.
    local f t lib
    f=$(get "$msys/$1" "$2")
    shift 2
    t=$(mktemp -d)
    tar --zstd -xf "$f" -C "$t" ucrt64/include ucrt64/lib
    cp -r "$t"/ucrt64/include/. "$out/include/"
    for lib in "$@"; do cp "$t/ucrt64/lib/$lib" "$out/lib/"; done
    rm -rf "$t"
}
pkg mingw-w64-ucrt-x86_64-sdl3-3.4.20-1-any.pkg.tar.zst 4a44381560c433ff42da3a6aff788fba2bba84a44b7f63ea396dec9c1cf79f78 libSDL3.a
pkg mingw-w64-ucrt-x86_64-libiconv-1.19.1-1-any.pkg.tar.zst 8a45dc317a285a036bddd79e01505d67b79e44ff49fc3f6e7177a5ea98d098cf libiconv.a

# O zig como compilador cruzado do CMake.
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
for tool in cc ar ranlib; do
    case $tool in
        cc) cmd='zig cc -target x86_64-windows-gnu' ;;
        *) cmd="zig $tool" ;;
    esac
    printf '#!/bin/sh\nexec %s "$@"\n' "$cmd" > "$t/z$tool"
    chmod +x "$t/z$tool"
done
secoes="-ffunction-sections -fdata-sections"
cmake_win=(-G Ninja -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64
    -DCMAKE_C_COMPILER="$t/zcc" -DCMAKE_AR="$t/zar" -DCMAKE_RANLIB="$t/zranlib"
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib
    -DBUILD_SHARED_LIBS=OFF)

# brotli: o certificado comprimido que o Chrome pede (o OpenSSL descomprime) e as
# respostas em br do curl. Só o decodificador: o codificador vira o de
# tools/brotlienc_stub.c, que só falha.
f=$(get https://github.com/google/brotli/archive/refs/tags/v1.2.1.tar.gz 98d35d11a78dc453aebb7d10c3748f3f73ff78c8267c0dc697b8631f67bf7e8f)
tar -xf "$f" -C "$t"
cmake -S "$t"/brotli-* -B "$t/brotli" "${cmake_win[@]}" \
    -DCMAKE_C_FLAGS_RELEASE="-Os -DNDEBUG" -DCMAKE_C_FLAGS="$secoes" \
    -DBROTLI_BUILD_TOOLS=OFF -DBROTLI_BUNDLED_MODE=OFF
cmake --build "$t/brotli"
cmake --install "$t/brotli"
"$t/zcc" -Os $secoes -I"$out/include" -c tools/brotlienc_stub.c -o "$t/brotlienc_stub.o"
rm -f "$out/lib/libbrotlienc.a"
"$t/zar" rcs "$out/lib/libbrotlienc.a" "$t/brotlienc_stub.o"

# zstd: as respostas em zstd do curl (o Chrome aceita "gzip, deflate, br, zstd"). Só a
# descompressão.
f=$(get https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3)
tar -xf "$f" -C "$t"
zstd_opts="ZSTD_LIB_COMPRESSION=0 ZSTD_LIB_DICTBUILDER=0 ZSTD_LIB_DEPRECATED=0 ZSTD_LEGACY_SUPPORT=0"
make -C "$t"/zstd-*/lib -j"$(nproc)" libzstd.a-release $zstd_opts CC="$t/zcc" AR="$t/zar" \
    CFLAGS="-Os $secoes -DHUF_FORCE_DECOMPRESS_X1 -DZSTD_FORCE_DECOMPRESS_SEQUENCES_SHORT -DZSTD_NO_INLINE"
cp "$t"/zstd-*/lib/libzstd.a "$out/lib/"
cp "$t"/zstd-*/lib/zstd.h "$t"/zstd-*/lib/zstd_errors.h "$out/include/"

# nghttp2: o HTTP/2 do curl. O Chrome sempre fala h2 com o Discord; um "Chrome" que
# só fala HTTP/1.1 chama atenção.
f=$(get https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.xz e05cb1388eaca3830aded4ccf20044b6e1ac1a61411dcca11b0437c4285c8bc2)
tar -xf "$f" -C "$t"
cmake -S "$t"/nghttp2-* -B "$t/nghttp2" "${cmake_win[@]}" \
    -DCMAKE_C_FLAGS_RELEASE="-Os -DNDEBUG" -DCMAKE_C_FLAGS="$secoes" \
    -DENABLE_LIB_ONLY=ON -DBUILD_STATIC_LIBS=ON -DENABLE_DOC=OFF -DBUILD_TESTING=OFF
cmake --build "$t/nghttp2"
cmake --install "$t/nghttp2"

# OpenSSL: o TLS do curl e a criptografia do DAVE, com as mesmas partes do binário de
# Linux (o porquê de cada uma está em tools/linux_deps.sh) e o certificado comprimido
# em brotli. O openssl.cnf ficaria na pasta padrão do OpenSSL no Windows, que só o
# administrador cria, e nem é lido: o curl não pede (CURL_DISABLE_OPENSSL_AUTO_LOAD_CONFIG)
# e o app desliga antes de qualquer TLS (sys.zig), porque o arquivo pode carregar DLLs no
# processo, onde está o token.
f=$(get https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a)
tar -xf "$f" -C "$t"
(
    cd "$t"/openssl-*
    perl -0pi -e 's/^open OUT/\$avx512vaes = 0;\nopen OUT/m' crypto/modes/asm/aes-gcm-avx512.pl crypto/aes/asm/aesni-xts-avx512.pl
    CC="$t/zcc" AR="$t/zar" RANLIB="$t/zranlib" RC=false ./Configure mingw64 \
        --prefix="$out" --libdir=lib --openssldir="C:/Program Files/Common Files/SSL" \
        no-shared no-module no-engine no-legacy no-apps no-tests no-docs no-filenames \
        no-ssl3 no-tls1 no-tls1_1 no-tls1-method no-tls1_1-method no-dtls no-quic no-srtp no-sctp no-dgram \
        no-nextprotoneg no-srp no-integrity-only-ciphers no-tls-deprecated-ec no-ssl-trace no-sslkeylog \
        no-aria no-bf no-camellia no-cast no-des no-idea no-mdc2 no-md4 no-rc2 no-rc4 no-rc5 no-rmd160 \
        no-seed no-sm2 no-sm3 no-sm4 no-whirlpool no-gost no-siv no-ocb no-siphash no-blake2 no-argon2 \
        no-dsa no-ec2m no-slh-dsa \
        no-cms no-ts no-cmp no-rfc3779 no-zlib no-zstd no-async no-ui-console \
        enable-brotli --with-brotli-include="$out/include" --with-brotli-lib="$out/lib" \
        no-thread-pool no-default-thread-pool \
        -O2 $secoes
    make -j"$(nproc)" build_libs
    make install_dev
)

# curl: só HTTP(S), WebSocket e o proxy, com HTTP/2, br e zstd, como no binário
# portátil de Linux, e sem ler o openssl.cnf (acima).
f=$(get https://curl.se/download/curl-8.23.0.tar.xz 8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5)
tar -xf "$f" -C "$t"
patch -d "$t"/curl-* -p1 < tools/curl-chrome-h2.patch
# O libcrypto estático cita o brotli e o Winsock: os testes de ligação do CMake precisam deles.
cmake -S "$t"/curl-* -B "$t/curl" "${cmake_win[@]}" \
    -DCMAKE_C_FLAGS_RELEASE="-Os -DNDEBUG" -DCMAKE_C_FLAGS="$secoes -DNGHTTP2_STATICLIB" \
    -DCMAKE_C_STANDARD_LIBRARIES="$out/lib/libbrotlienc.a $out/lib/libbrotlidec.a $out/lib/libbrotlicommon.a -lws2_32 -lcrypt32 -lbcrypt -luser32 -ladvapi32" \
    -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF \
    -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF -DCURL_USE_PKGCONFIG=OFF \
    -DCURL_USE_OPENSSL=ON -DOPENSSL_ROOT_DIR="$out" -DOPENSSL_USE_STATIC_LIBS=ON -DCURL_DISABLE_OPENSSL_AUTO_LOAD_CONFIG=ON \
    -DZLIB_INCLUDE_DIR="$win/include" -DZLIB_LIBRARY="$win/lib/libz.a" \
    -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF \
    -DUSE_NGHTTP2=ON -DNGHTTP2_INCLUDE_DIR="$out/include" -DNGHTTP2_LIBRARY="$out/lib/libnghttp2.a" \
    -DCURL_BROTLI=ON -DBROTLI_INCLUDE_DIR="$out/include" -DBROTLICOMMON_LIBRARY="$out/lib/libbrotlicommon.a" -DBROTLIDEC_LIBRARY="$out/lib/libbrotlidec.a" \
    -DCURL_ZSTD=ON -DZSTD_INCLUDE_DIR="$out/include" -DZSTD_LIBRARY="$out/lib/libzstd.a" \
    -DUSE_LIBIDN2=OFF -DUSE_WIN32_IDN=OFF -DCURL_WINDOWS_SSPI=OFF -DENABLE_UNIX_SOCKETS=OFF \
    -DCURL_DISABLE_DICT=ON -DCURL_DISABLE_FILE=ON -DCURL_DISABLE_FTP=ON -DCURL_DISABLE_GOPHER=ON -DCURL_DISABLE_IMAP=ON \
    -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DCURL_DISABLE_MQTT=ON -DCURL_DISABLE_POP3=ON -DCURL_DISABLE_RTSP=ON \
    -DCURL_DISABLE_SMTP=ON -DCURL_DISABLE_TELNET=ON -DCURL_DISABLE_TFTP=ON -DCURL_DISABLE_IPFS=ON \
    -DCURL_ENABLE_NTLM=OFF -DCURL_DISABLE_AWS=ON -DCURL_DISABLE_COOKIES=ON \
    -DCURL_DISABLE_HSTS=ON -DCURL_DISABLE_ALTSVC=ON -DCURL_DISABLE_DOH=ON -DCURL_DISABLE_NETRC=ON \
    -DCURL_DISABLE_FORM_API=ON -DCURL_DISABLE_GETOPTIONS=ON -DCURL_DISABLE_HEADERS_API=ON -DCURL_DISABLE_BINDLOCAL=ON \
    -DCURL_DISABLE_PROGRESS_METER=ON -DCURL_DISABLE_SHA512_256=ON -DCURL_DISABLE_KERBEROS_AUTH=ON \
    -DCURL_DISABLE_NEGOTIATE_AUTH=ON -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none
cmake --build "$t/curl"
cmake --install "$t/curl"
rm -rf "$out/bin" "$out/share" "$out/lib/cmake" "$out/lib/pkgconfig"
echo "pronto: $out"
