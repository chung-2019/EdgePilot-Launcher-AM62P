#!/bin/bash
#
# Deploy EdgePilot Launcher to an AM62P EVM.
# Flow: copy files -> install units -> disable ti-apps-launcher -> enable
#       edgepilot-launcher
#
set -e

# Board address. Override per run: EVM_IP=<address> ./deploy.sh
EVM_IP=${EVM_IP:?set EVM_IP to the board address, e.g. EVM_IP=192.168.0.11 ./deploy.sh}
SSH="ssh -o BatchMode=yes root@$EVM_IP"
SCP="scp -o BatchMode=yes"

cd "$(dirname "$0")"

if [ ! -f build/edgepilot-launcher ]; then
    echo "[X] build/edgepilot-launcher not found -- run ./build.sh first"
    exit 1
fi

echo "-> Stopping the running service (so scp does not hit 'text file busy')..."
$SSH 'systemctl stop edgepilot-launcher.service 2>/dev/null || true'

echo "-> Copying the binary to the EVM ($EVM_IP)..."
$SCP build/edgepilot-launcher root@$EVM_IP:/usr/bin/edgepilot-launcher

echo "-> Installing the systemd units..."
$SCP edgepilot-launcher.service root@$EVM_IP:/etc/systemd/system/
$SCP edgepilot-j4-gpios.service root@$EVM_IP:/etc/systemd/system/


# Optional peripheral identification. The file holds real device names, so it
# is supplied per deployment and is not part of this repository. Without it the
# launcher still starts and simply matches no device-specific special case --
# in particular the always-on firmware's first (cached) reading is no longer
# discarded. Worth saying out loud rather than skipping in silence.
#
# Schema (see src/deviceprofiles.h for what each field changes):
#   { "memoryMeterNamePrefix": "", "alwaysOnTokens": [],
#     "vendor1524Tokens": [], "longHoldTokens": [] }
if [ -f config/device-profiles.json ]; then
    echo "-> Installing the device profile (/etc/edgepilot/device-profiles.json)..."
    $SSH 'mkdir -p /etc/edgepilot'
    $SCP config/device-profiles.json root@$EVM_IP:/etc/edgepilot/device-profiles.json
else
    echo "[!] No config/device-profiles.json -- skipping the device profile."
    echo "    If the EVM has no /etc/edgepilot/device-profiles.json either, every"
    echo "    device-specific special case stays disabled. That is a supported"
    echo "    configuration, not an error; see src/deviceprofiles.h."
fi

echo "-> Installing the CC3351 BLE watchdog (after a Wi-Fi FW recovery ble_enable drops to 0 and hci0 disappears; this re-attaches it)..."
$SSH 'mkdir -p /usr/local/sbin'
$SCP evm-assets/cc33xx-ble-watchdog/cc33xx-ble-watchdog.sh      root@$EVM_IP:/usr/local/sbin/cc33xx-ble-watchdog.sh
$SCP evm-assets/cc33xx-ble-watchdog/cc33xx-ble-watchdog.service root@$EVM_IP:/etc/systemd/system/
$SCP evm-assets/cc33xx-ble-watchdog/cc33xx-ble-watchdog.timer   root@$EVM_IP:/etc/systemd/system/

echo "-> Switching launcher (disable ti-apps-launcher -> enable edgepilot-launcher + j4-gpios)..."
$SSH '
    chmod +x /usr/bin/edgepilot-launcher
    chmod 0755 /usr/local/sbin/cc33xx-ble-watchdog.sh
    systemctl daemon-reload
    systemctl disable --now ti-apps-launcher.service 2>/dev/null || true
    systemctl disable --now seva-launcher.service 2>/dev/null || true
    systemctl enable --now edgepilot-j4-gpios.service
    systemctl enable --now edgepilot-launcher.service
    systemctl enable --now cc33xx-ble-watchdog.timer
    sleep 2
    systemctl status edgepilot-j4-gpios.service --no-pager | head -8
    echo
    systemctl status edgepilot-launcher.service --no-pager | head -10
'

echo
# TMP119 can be reached two equally valid ways. This only reports which one is
# in effect; neither is treated as an error:
#   [A] kernel-managed: uEnv.txt loads edgepilot-tmp119.dtbo, pca954x claims
#       0x71 (i2cdetect shows UU) and TMP119 moves onto a child bus.
#   [B] legacy: no overlay, and the launcher's C++ drives the mux itself with
#       ioctl(0x71) plus a channel-mask write; 0x71 appears as an ordinary
#       device on i2c-2.
# The launcher detects both by itself (systemmonitor.cpp, resolveTmp119Bus()),
# so no code change is needed either way. The overlay itself is not shipped in
# this repository; [B] is what a board without it uses, and it works.
echo "-> Checking which TMP119 path is active (kernel-managed PCA9543 vs legacy manual mux)..."
$SSH '
    U=/run/media/boot-mmcblk1p1/uEnv.txt
    if grep -q "^name_overlays=.*edgepilot-tmp119.dtbo" "$U" 2>/dev/null; then
        echo "    [i] uEnv.txt lists ti/edgepilot-tmp119.dtbo -> [A] kernel takes over the mux after a reboot"
    else
        echo "    [i] uEnv.txt does not list an I2C mux overlay -> [B] legacy, the launcher drives the mux"
    fi
    if [ -e /sys/bus/i2c/devices/2-0071/channel-0 ]; then
        CH=$(basename "$(readlink -f /sys/bus/i2c/devices/2-0071/channel-0)")
        echo "    [i] Running: kernel has claimed the PCA9543, J4 channel 0 = /dev/$CH"
    else
        echo "    [i] Running: legacy path, the launcher drives the mux (0x71 is an ordinary device on i2c-2)"
    fi
    # What actually deserves a warning is no temperature at all, not which
    # path is in use.
    MSG=$(journalctl -u edgepilot-launcher -b --no-pager 2>/dev/null |
          grep -o "TMP119: using .*" | tail -1)
    if [ -n "$MSG" ]; then
        echo "    [i] Launcher reports: $MSG"
    fi
'

echo
echo "[OK] Deployed. The EVM display should now show EdgePilot Launcher."
echo
echo "To roll back:"
echo "  ssh root@$EVM_IP '"'systemctl disable --now edgepilot-launcher && systemctl enable --now ti-apps-launcher'"'"
