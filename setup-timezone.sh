#!/bin/bash
#
# 設定 AM62P EVM 時區為 Asia/Taipei，並確認 NTP 同步開啟
#
# 用途：tisdk image 預設沒有 /usr/share/zoneinfo/，且時區為 UTC，
#       導致 weston-desktop-shell 上方時鐘顯示落後 8 小時。
#       本腳本會推 tzdata、設 /etc/localtime、啟用 systemd-timesyncd。
#
# 用法：
#   EVM_IP=<board address> ./setup-timezone.sh
#   EVM_IP=<board address> TZ_NAME=Asia/Tokyo ./setup-timezone.sh
#
# 套用後需 reboot EVM 才能讓 weston-desktop-shell 重新讀取時區。
#
set -e

EVM_IP=${EVM_IP:?set EVM_IP to the board address, e.g. EVM_IP=192.168.0.11 ./setup-timezone.sh}
TZ_NAME=${TZ_NAME:-Asia/Taipei}
HOST_TZDATA=/usr/share/zoneinfo/$TZ_NAME

SSH="ssh -o BatchMode=yes root@$EVM_IP"
SCP="scp -o BatchMode=yes"

if [ ! -f "$HOST_TZDATA" ]; then
    echo "✗ host 上找不到 $HOST_TZDATA，無法部署"
    echo "  Ubuntu/Debian: sudo apt install tzdata"
    exit 1
fi

echo "→ 目標 EVM: $EVM_IP, 時區: $TZ_NAME"
echo
echo "→ 部署前狀態："
$SSH 'timedatectl 2>&1 | grep -E "Local time|Time zone|NTP service|synchronized"'
echo

echo "→ 推送 tzdata..."
TZ_DIR=$(dirname "$TZ_NAME")
$SSH "mkdir -p /usr/share/zoneinfo/$TZ_DIR"
$SCP "$HOST_TZDATA" "root@$EVM_IP:/usr/share/zoneinfo/$TZ_NAME"

echo "→ 設定 /etc/localtime、/etc/timezone..."
$SSH "ln -sf /usr/share/zoneinfo/$TZ_NAME /etc/localtime && echo $TZ_NAME > /etc/timezone"

echo "→ 套用 timezone (timedatectl)..."
$SSH "timedatectl set-timezone $TZ_NAME"

echo "→ 確認 NTP 啟用..."
$SSH 'systemctl enable --now systemd-timesyncd 2>&1 | grep -v "^$" || true
      timedatectl set-ntp true'

echo
echo "→ 部署後狀態："
$SSH 'timedatectl 2>&1 | grep -E "Local time|Time zone|NTP service|synchronized"'

echo
echo "✓ 時區設定完成。"
echo
echo "  注意：weston-desktop-shell 上方時鐘須 reboot 後才會顯示新時區。"
echo "  立即生效：ssh root@$EVM_IP reboot"
