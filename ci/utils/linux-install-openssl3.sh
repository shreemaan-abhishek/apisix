#!/usr/bin/env bash
set -euo pipefail
set -x

ENABLE_FIPS=${ENABLE_FIPS:-"false"}
OPENSSL_CONF_PATH=${OPENSSL_CONF_PATH:-$PWD/conf/openssl3/openssl.cnf}
OR_PREFIX=${OR_PREFIX:="/usr/local/openresty"}
OPENSSL_PREFIX=${OPENSSL_PREFIX:=$OR_PREFIX/openssl3}
OPENSSL_VERSION=${OPENSSL_VERSION:-"3.2.0"}
zlib_prefix=${OR_PREFIX}/zlib
pcre_prefix=${OR_PREFIX}/pcre

install_openssl_3(){
    local fips=""
    if [ "$ENABLE_FIPS" == "true" ]; then
        fips="enable-fips"
    fi
    # required for openssl 3.x config
    cpanm IPC/Cmd.pm
    wget --no-check-certificate https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz
    tar xvf openssl-${OPENSSL_VERSION}.tar.gz
    cd openssl-${OPENSSL_VERSION}/
    export LDFLAGS="-Wl,-rpath,$zlib_prefix/lib:$OPENSSL_PREFIX/lib"
    ./config $fips \
      shared \
      zlib \
      enable-camellia enable-seed enable-rfc3779 \
      enable-cms enable-md2 enable-rc5 \
      enable-weak-ssl-ciphers \
      --prefix=$OPENSSL_PREFIX \
      --libdir=lib               \
      --with-zlib-lib=$zlib_prefix/lib \
      --with-zlib-include=$zlib_prefix/include
    make -j $(nproc) LD_LIBRARY_PATH= CC="gcc"
    sudo make install
    if [ -f "$OPENSSL_CONF_PATH" ]; then
        sudo cp "$OPENSSL_CONF_PATH" "$OPENSSL_PREFIX"/ssl/openssl.cnf
    fi
    if [ "$ENABLE_FIPS" == "true" ]; then
        $OPENSSL_PREFIX/bin/openssl fipsinstall -out $OPENSSL_PREFIX/ssl/fipsmodule.cnf -module $OPENSSL_PREFIX/lib/ossl-modules/fips.so
        sudo sed -i 's@# .include fipsmodule.cnf@.include '"$OPENSSL_PREFIX"'/ssl/fipsmodule.cnf@g; s/# \(fips = fips_sect\)/\1\nbase = base_sect\n\n[base_sect]\nactivate=1\n/g' $OPENSSL_PREFIX/ssl/openssl.cnf
    fi
}

install_openssl_3
