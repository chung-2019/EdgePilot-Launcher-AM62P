# SPDX-License-Identifier: MIT
#
# Cross-compile toolchain for EdgePilot Launcher on AM62P (aarch64).
#
# 使用方式（從 build 目錄）：
#   cmake -DCMAKE_TOOLCHAIN_FILE=../cmake/am62p-aarch64-toolchain.cmake \
#         -DCMAKE_BUILD_TYPE=Release ..
#   make -j$(nproc)
#
# 可用環境變數 override（建議在 source SDK environment-setup 之前設）：
#   TI_SDK_PATH   TI Processor SDK Linux 根目錄
#                   default: /opt/ti/processor-sdk-linux-am62pxx
#   QT_HOST_PATH  Qt 6.11+ host tools 安裝路徑（提供 moc/rcc/qmlcachegen）
#                   default: 自動掃 /opt/Qt/6.*/gcc_64 取最新
#
# 注意：本檔不會 source SDK environment-setup（CMake 不能跑 shell script）。
# 編譯前仍建議 `source $TI_SDK_PATH/linux-devkit/environment-setup`，否則
# pkg-config 找不到 .pc 檔、link 階段可能缺 Scrt1.o。

# ── 1. Target system ──────────────────────────────────────────────
set(CMAKE_SYSTEM_NAME      Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# ── 2. TI SDK 路徑 ────────────────────────────────────────────────
if(NOT DEFINED TI_SDK_PATH)
    if(DEFINED ENV{TI_SDK_PATH})
        set(TI_SDK_PATH $ENV{TI_SDK_PATH})
    else()
        set(TI_SDK_PATH "/opt/ti/processor-sdk-linux-am62pxx")
    endif()
endif()

set(_SDK_HOST_SYSROOT   "${TI_SDK_PATH}/linux-devkit/sysroots/x86_64-arago-linux")
set(_SDK_TARGET_SYSROOT "${TI_SDK_PATH}/linux-devkit/sysroots/aarch64-oe-linux")

if(NOT EXISTS "${_SDK_TARGET_SYSROOT}")
    message(FATAL_ERROR
        "TI SDK target sysroot not found:\n  ${_SDK_TARGET_SYSROOT}\n"
        "Set -DTI_SDK_PATH=... or install TI Processor SDK Linux for AM62Px.")
endif()

# ── 3. Cross toolchain binaries ───────────────────────────────────
set(_TOOLBIN "${_SDK_HOST_SYSROOT}/usr/bin/aarch64-oe-linux")
set(CMAKE_C_COMPILER   "${_TOOLBIN}/aarch64-oe-linux-gcc"   CACHE FILEPATH "")
set(CMAKE_CXX_COMPILER "${_TOOLBIN}/aarch64-oe-linux-g++"   CACHE FILEPATH "")
set(CMAKE_AR           "${_TOOLBIN}/aarch64-oe-linux-ar"     CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB       "${_TOOLBIN}/aarch64-oe-linux-ranlib" CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP        "${_TOOLBIN}/aarch64-oe-linux-strip"  CACHE FILEPATH "" FORCE)
set(CMAKE_LINKER       "${_TOOLBIN}/aarch64-oe-linux-ld"     CACHE FILEPATH "" FORCE)
set(CMAKE_OBJCOPY      "${_TOOLBIN}/aarch64-oe-linux-objcopy" CACHE FILEPATH "" FORCE)
set(CMAKE_OBJDUMP      "${_TOOLBIN}/aarch64-oe-linux-objdump" CACHE FILEPATH "" FORCE)

# ── 4. Sysroot & find behaviour ───────────────────────────────────
set(CMAKE_SYSROOT        "${_SDK_TARGET_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH "${_SDK_TARGET_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Sysroot 也要套到 compile/link 命令（補強，部分 IDE 不會自動帶）
set(CMAKE_C_FLAGS_INIT          "--sysroot=${_SDK_TARGET_SYSROOT}")
set(CMAKE_CXX_FLAGS_INIT        "--sysroot=${_SDK_TARGET_SYSROOT}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "--sysroot=${_SDK_TARGET_SYSROOT}")

# ── 5. Qt 6 (target side，從 sysroot 找) ──────────────────────────
set(Qt6_DIR "${_SDK_TARGET_SYSROOT}/usr/lib/cmake/Qt6" CACHE PATH "" FORCE)

# ── 6. Qt host tools (moc / rcc / qmlcachegen) ────────────────────
if(NOT DEFINED QT_HOST_PATH)
    if(DEFINED ENV{QT_HOST_PATH})
        set(QT_HOST_PATH $ENV{QT_HOST_PATH})
    else()
        # 自動掃 /opt/Qt/6.*/gcc_64，挑版本最新（natural sort，descending）
        file(GLOB _qt_candidates LIST_DIRECTORIES true "/opt/Qt/6.*/gcc_64")
        if(_qt_candidates)
            list(SORT _qt_candidates COMPARE NATURAL ORDER DESCENDING)
            list(GET _qt_candidates 0 QT_HOST_PATH)
        endif()
    endif()
endif()

if(QT_HOST_PATH AND EXISTS "${QT_HOST_PATH}/lib/cmake/Qt6")
    set(QT_HOST_PATH           "${QT_HOST_PATH}"           CACHE PATH "" FORCE)
    set(QT_HOST_PATH_CMAKE_DIR "${QT_HOST_PATH}/lib/cmake" CACHE PATH "" FORCE)
    message(STATUS "Qt host tools: ${QT_HOST_PATH}")
else()
    message(WARNING
        "QT_HOST_PATH 未設定或路徑無效。Cross build 會在 moc/rcc 階段失敗。\n"
        "請安裝 Qt 6.11+ host tools 到 /opt/Qt/，或設 -DQT_HOST_PATH=<dir>。")
endif()

# host Qt 6.11 vs sysroot Qt 6.12+ 容差：跳過版本檢查 + 壓 warning
set(QT_NO_PACKAGE_VERSION_CHECK             TRUE CACHE BOOL "" FORCE)
set(QT_NO_PACKAGE_VERSION_INCOMPATIBLE_WARNING TRUE CACHE BOOL "" FORCE)

# host Qt 6.11 缺 Qt6QuickTools，用 host-stubs 補上（路徑相對本檔目錄）
get_filename_component(_TOOLCHAIN_DIR "${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)
if(EXISTS "${_TOOLCHAIN_DIR}/host-stubs/Qt6QuickTools/Qt6QuickToolsConfig.cmake")
    set(Qt6QuickTools_DIR "${_TOOLCHAIN_DIR}/host-stubs/Qt6QuickTools" CACHE PATH "" FORCE)
    list(APPEND CMAKE_PREFIX_PATH "${_TOOLCHAIN_DIR}/host-stubs")
endif()

# ── 7. CMake 一般化設定 ───────────────────────────────────────────
list(APPEND CMAKE_PREFIX_PATH "${_SDK_TARGET_SYSROOT}/usr")
set(CMAKE_NO_SYSTEM_FROM_IMPORTED ON CACHE BOOL "" FORCE)

# Yocto SDK 風格：讓 pkg-config 在 sysroot 內找 .pc
set(ENV{PKG_CONFIG_PATH} "${_SDK_TARGET_SYSROOT}/usr/lib/pkgconfig:${_SDK_TARGET_SYSROOT}/usr/share/pkgconfig")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${_SDK_TARGET_SYSROOT}")
set(ENV{PKG_CONFIG_LIBDIR}      "${_SDK_TARGET_SYSROOT}/usr/lib/pkgconfig:${_SDK_TARGET_SYSROOT}/usr/share/pkgconfig")
