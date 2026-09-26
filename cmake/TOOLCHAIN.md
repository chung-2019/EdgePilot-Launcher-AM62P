# CMake Toolchain — EdgePilot Launcher on AM62P (aarch64)

`am62p-aarch64-toolchain.cmake` 是這個專案的標準 cross-compile toolchain，用於 TI Processor SDK Linux for AM62Px + Qt 6 sysroot。

## 一鍵編譯

```bash
cd /path/to/EdgePilot_Github_Demo
source /opt/ti/processor-sdk-linux-am62pxx/linux-devkit/environment-setup
mkdir -p build && cd build
cmake -DCMAKE_TOOLCHAIN_FILE=../cmake/am62p-aarch64-toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)
```

> **必須先 `source environment-setup`**，否則 link 階段會缺 `Scrt1.o`、pkg-config 找不到 `.pc` 檔。toolchain file 不會替你 source env（CMake 不能跑 shell script）。

## 預期環境

| 元件 | 預設路徑 | override 方式 |
|---|---|---|
| TI SDK | `/opt/ti/processor-sdk-linux-am62pxx` | `-DTI_SDK_PATH=...` 或 `TI_SDK_PATH=...` env |
| Qt host tools | 自動找 `/opt/Qt/6.*/gcc_64`（最新） | `-DQT_HOST_PATH=...` 或 `QT_HOST_PATH=...` env |
| Target sysroot | `$TI_SDK_PATH/linux-devkit/sysroots/aarch64-oe-linux` | （由 TI_SDK_PATH 推導，不獨立 override）|
| Cross compiler | `$TI_SDK_PATH/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-{gcc,g++}` | 同上 |

## Toolchain file 做的事

1. **`CMAKE_SYSTEM_NAME=Linux` + `CMAKE_SYSTEM_PROCESSOR=aarch64`** — 觸發 CMake cross-compile 模式
2. **指定 cross compiler 路徑** — gcc / g++ / ar / ranlib / strip / ld / objcopy / objdump 全套
3. **sysroot** — `CMAKE_SYSROOT` + `CMAKE_FIND_ROOT_PATH` + `_INIT` flags 三重設定（補強 IDE 不自動帶的情況）
4. **`Qt6_DIR`** 指到 sysroot 內的 `usr/lib/cmake/Qt6`
5. **`QT_HOST_PATH`** 自動掃 `/opt/Qt/6.*/gcc_64` 取最新版（natural sort）
6. **`Qt6QuickTools_DIR`** 指向 `cmake/host-stubs/Qt6QuickTools` — 解決 host Qt 6.11 缺 `Qt6QuickTools` target，但 target Qt 6.12+ 需要它的問題
7. **`QT_NO_PACKAGE_VERSION_CHECK=TRUE`** — 容忍 host 6.11 vs target 6.12+ 版本不同
8. **pkg-config 環境變數** — `PKG_CONFIG_SYSROOT_DIR` / `PKG_CONFIG_LIBDIR` 設好，讓 sysroot 內的 `.pc` 檔被找到

## 為什麼需要 host-stubs

target sysroot 內 Qt 6.12+ 的 `Qt6QmlConfig.cmake` 會 `find_package(Qt6QuickTools)`，但 host 端 Qt 6.11 沒這個 module → 編譯失敗。  
`cmake/host-stubs/Qt6QuickTools/Qt6QuickToolsConfig.cmake` 提供一個空的 stub 滿足 find_package 需求，避免改動 sysroot 也不影響實際 cross build（Qt host tools 的 moc/rcc/qmlcachegen 仍由 `QT_HOST_PATH` 提供）。

## IDE 整合

### Qt Creator
Kit → Manage Kits → 新增 Kit：
- C/C++ compiler 指向 `aarch64-oe-linux-gcc` / `aarch64-oe-linux-g++`
- CMake 設定加入 `-DCMAKE_TOOLCHAIN_FILE=%{sourceDir}/cmake/am62p-aarch64-toolchain.cmake`

### VSCode (CMake Tools)
`.vscode/settings.json`：
```json
{
  "cmake.configureSettings": {
    "CMAKE_TOOLCHAIN_FILE": "${workspaceFolder}/cmake/am62p-aarch64-toolchain.cmake",
    "CMAKE_BUILD_TYPE": "Release"
  },
  "cmake.environment": {
    "OECORE_NATIVE_SYSROOT": "/opt/ti/processor-sdk-linux-am62pxx/linux-devkit/sysroots/x86_64-arago-linux",
    "OECORE_TARGET_SYSROOT": "/opt/ti/processor-sdk-linux-am62pxx/linux-devkit/sysroots/aarch64-oe-linux"
  }
}
```

## 排錯

| 症狀 | 原因 | 解 |
|---|---|---|
| `cannot find -lQt6Quick`（link 階段） | 沒 source environment-setup | `source /opt/ti/.../environment-setup` 再 cmake |
| `Scrt1.o: No such file` | 同上 | 同上 |
| `Qt6QuickTools` not found | host Qt 缺 stub 或路徑不對 | 確認 `cmake/host-stubs/Qt6QuickTools/` 存在 |
| moc 失敗、`Cannot find moc` | `QT_HOST_PATH` 沒設或路徑不對 | 安裝 Qt 6.11+ 到 `/opt/Qt/` 或 `-DQT_HOST_PATH=` |
| `TypeAndForceComplete` 錯誤 | host Qt < 6.11 與 target 不匹配 | 升級 host Qt 到 6.11+（Ubuntu apt 的 6.4 不行）|
| 編譯 OK 但 .so 找不到 | sysroot 沒帶到 link | toolchain file 已設 `--sysroot=` flag，檢查 IDE 有沒有蓋掉 |

## 跟舊 build.sh 的關係

舊 `build.sh` 把所有 `-D` 直接展開在命令列。新 toolchain file 之後 build.sh 可以簡化為：

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")"
[ -z "$OECORE_TARGET_SYSROOT" ] && source /opt/ti/processor-sdk-linux-am62pxx/linux-devkit/environment-setup
rm -rf build && mkdir build && cd build
cmake -DCMAKE_TOOLCHAIN_FILE=../cmake/am62p-aarch64-toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)
file edgepilot-launcher
```

舊 build.sh 暫時保留作為 reference / fallback，不影響本 toolchain file。
