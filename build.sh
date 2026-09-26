#!/bin/bash
#
# Cross-compile the meter vendor Launcher for AM62P (aarch64)
# 用法：source SDK env 後執行 ./build.sh
#
set -e

SDK=/opt/ti/processor-sdk-linux-am62pxx
SYSROOT=$SDK/linux-devkit/sysroots/aarch64-oe-linux

if [ -z "$OECORE_TARGET_SYSROOT" ]; then
    echo "→ Sourcing SDK environment-setup..."
    source $SDK/linux-devkit/environment-setup
fi

cd "$(dirname "$0")"
rm -rf build
mkdir build && cd build

QT_HOST_PATH=${QT_HOST_PATH:-/opt/Qt/6.11.0/gcc_64}
QT_HOST_CMAKE_DIR=${QT_HOST_CMAKE_DIR:-$QT_HOST_PATH/lib/cmake}

cmake .. \
    -DCMAKE_PREFIX_PATH="$SYSROOT/usr;$(pwd)/../cmake/host-stubs" \
    -DQt6_DIR=$SYSROOT/usr/lib/cmake/Qt6 \
    -DQT_HOST_PATH=$QT_HOST_PATH \
    -DQT_HOST_PATH_CMAKE_DIR=$QT_HOST_CMAKE_DIR \
    -DQT_NO_PACKAGE_VERSION_CHECK=TRUE \
    -DQt6QuickTools_DIR=$(pwd)/../cmake/host-stubs/Qt6QuickTools \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_NO_SYSTEM_FROM_IMPORTED=ON \
    -DCMAKE_C_FLAGS="--sysroot=$SYSROOT" \
    -DCMAKE_CXX_FLAGS="--sysroot=$SYSROOT" \
    -DCMAKE_EXE_LINKER_FLAGS="--sysroot=$SYSROOT" \
    -DCMAKE_C_COMPILER=$SDK/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-gcc \
    -DCMAKE_CXX_COMPILER=$SDK/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-g++ \
    -DCMAKE_SYSROOT=$SYSROOT \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64

make -j$(nproc)

echo
echo "✓ Build complete: $(pwd)/edgepilot-launcher"
file edgepilot-launcher
