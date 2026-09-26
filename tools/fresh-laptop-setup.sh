#!/bin/bash
#
# Fresh Ubuntu/WSL setup for cross-building edgepilot-launcher.
#
# Usage:
#   ./fresh-laptop-setup.sh <SDK_installer.bin>
#
# Does:
#   1. apt 前置 (python3-venv, python3-pip, build-essential ...)
#   2. 跑 TI Processor SDK installer (unattended)
#   3. 裝 Qt 6.11.0 host toolchain via aqtinstall
#   4. 驗證 cross-compiler + moc 可呼叫
#
# Idempotent — 重跑會跳過已完成步驟。
#
set -euo pipefail

# ── 解析參數 ─────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    cat <<EOF
Usage: $0 <SDK_installer.bin>

Example:
    $0 ~/Downloads/ti-processor-sdk-linux-am62pxx-evm-12.00.00.07-Linux-x86-Install.bin

Tips:
    - 從 https://www.ti.com/tool/PROCESSOR-SDK-AM62P 下載 SDK installer
    - WSL2 上跑沒問題；裸機 Ubuntu 也支援
EOF
    exit 1
fi

SDK_INSTALLER=$(realpath "$1")
if [ ! -f "$SDK_INSTALLER" ]; then
    echo "✗ SDK installer not found: $SDK_INSTALLER" >&2
    exit 1
fi

# ── sudo wrapper（已是 root 就不用 sudo）─────────────────────
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
    # 驗證 sudo 可用
    $SUDO -v || { echo "✗ 需要 sudo 權限"; exit 1; }
fi

SDK_PARENT=/opt/ti
QT_PARENT=/opt/Qt
QT_VERSION=6.11.0
QT_HOST_PATH=$QT_PARENT/$QT_VERSION/gcc_64
AQT_VENV=/opt/qt-aqt-venv

step() { echo; echo "── $1 ──"; }
ok()   { echo "  ✓ $1"; }
skip() { echo "  ↷ skip: $1"; }

# ── 1. apt 前置 ─────────────────────────────────────────────
step "1/4 apt 前置"
$SUDO apt-get update -qq
$SUDO apt-get install -y \
    python3-venv \
    python3-pip \
    build-essential \
    cmake \
    git \
    curl \
    file \
    pkg-config \
    libgl1 \
    libxcb-cursor0
ok "apt packages 已備齊"

# ── 2. TI Processor SDK ────────────────────────────────────
step "2/4 TI Processor SDK 安裝"

# 嘗試找出 SDK 已安裝的目錄
existing_sdk=""
if [ -d "$SDK_PARENT" ]; then
    existing_sdk=$(find "$SDK_PARENT" -maxdepth 1 -name "processor-sdk-linux-am62pxx*" -type d 2>/dev/null | head -1)
fi

if [ -n "$existing_sdk" ] && [ -f "$existing_sdk/linux-devkit/environment-setup" ]; then
    skip "SDK 已安裝於 $existing_sdk"
    SDK_DIR="$existing_sdk"
else
    chmod +x "$SDK_INSTALLER"
    # TI bitrock installer：--mode unattended + --prefix
    echo "  跑 SDK installer (unattended，可能需要幾分鐘)..."
    $SUDO "$SDK_INSTALLER" --mode unattended --prefix "$SDK_PARENT" 2>&1 | tail -20

    SDK_DIR=$(find "$SDK_PARENT" -maxdepth 1 -name "processor-sdk-linux-am62pxx*" -type d 2>/dev/null | head -1)
    if [ -z "$SDK_DIR" ] || [ ! -f "$SDK_DIR/linux-devkit/environment-setup" ]; then
        echo "  ✗ SDK install 完成後找不到 environment-setup" >&2
        echo "  請手動確認 $SDK_PARENT 內容，或改用 GUI installer 跑一次" >&2
        exit 1
    fi
    ok "SDK 安裝至 $SDK_DIR"
fi

# 驗證 cross-compiler
CROSS_GCC="$SDK_DIR/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-gcc"
if [ ! -x "$CROSS_GCC" ]; then
    echo "  ✗ 找不到 cross-compiler: $CROSS_GCC" >&2
    exit 1
fi
ok "cross-compiler: $($CROSS_GCC --version | head -1)"

# ── 3. Qt 6.11 host toolchain ──────────────────────────────
step "3/4 Qt $QT_VERSION host toolchain"

if [ -x "$QT_HOST_PATH/libexec/moc" ]; then
    skip "Qt $QT_VERSION 已安裝於 $QT_HOST_PATH"
else
    if [ ! -d "$AQT_VENV" ]; then
        $SUDO python3 -m venv "$AQT_VENV"
    fi
    $SUDO "$AQT_VENV/bin/pip" install --quiet --upgrade pip aqtinstall
    ok "aqtinstall 已準備"

    echo "  下載 Qt $QT_VERSION (約 1 GB，2-5 分鐘)..."
    $SUDO "$AQT_VENV/bin/aqt" install-qt linux desktop "$QT_VERSION" linux_gcc_64 -O "$QT_PARENT" 2>&1 | tail -3
    ok "Qt $QT_VERSION 安裝至 $QT_HOST_PATH"
fi

# 驗證 moc / rcc
moc_ver=$("$QT_HOST_PATH/libexec/moc" --version 2>&1 || echo "FAIL")
rcc_ver=$("$QT_HOST_PATH/libexec/rcc" --version 2>&1 || echo "FAIL")
ok "moc: $moc_ver"
ok "rcc: $rcc_ver"

# ── 4. 整合驗證 ────────────────────────────────────────────
step "4/4 build 環境總驗證"

# source SDK env 並列出關鍵變數
(
    set +u  # SDK env 可能有 unbound vars
    source "$SDK_DIR/linux-devkit/environment-setup"
    echo "  OECORE_TARGET_SYSROOT = ${OECORE_TARGET_SYSROOT:-(unset)}"
    echo "  CC                    = ${CC:-(unset)}"
    echo "  CXX                   = ${CXX:-(unset)}"
)
ok "SDK environment-setup 可 source"

cat <<EOF

══════════════════════════════════════════════════════════════
✓ 全部完成。下一步：

  cd $SDK_DIR/example-applications/EdgePilot_Github_Demo
  source $SDK_DIR/linux-devkit/environment-setup
  ./build.sh

  # 第一次到新 EVM（<board> 換成板子的位址）：
  cd evm-assets && EVM_IP=<board> ./push-evm-assets.sh

  # 部署：
  EVM_IP=<board> ./deploy.sh

詳細說明：docs/README.md（安裝、硬體、部署索引）
══════════════════════════════════════════════════════════════
EOF
