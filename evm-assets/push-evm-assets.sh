#!/bin/bash
#
# 一次部署 EVM 端 runtime assets：cursor theme + CJK 字型 + fontconfig + tty-aware whetstone script
# 第一次到新 EVM 跑一次就好。日常 build/deploy 走 ../build.sh + ../deploy.sh。
#
# 用法：
#   EVM_IP=<board address> ./push-evm-assets.sh
#
set -e

EVM_IP=${EVM_IP:?set EVM_IP to the board address, e.g. EVM_IP=192.168.0.11 ./push-evm-assets.sh}
SSH="ssh -o BatchMode=yes root@$EVM_IP"
SCP="scp -o BatchMode=yes"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "→ 目標 EVM: $EVM_IP"
echo

# ── 1. Adwaita cursor theme ───────────────────────────────
echo "→ [1/4] Adwaita cursor theme"
if [ ! -d /usr/share/icons/Adwaita/cursors ]; then
    echo "  ✗ host 端沒有 /usr/share/icons/Adwaita/cursors，先在 host 裝："
    echo "    sudo apt install -y adwaita-icon-theme"
    exit 1
fi

cd /usr/share/icons
tar czf /tmp/adwaita-cursors.tar.gz \
    Adwaita/cursors Adwaita/cursor.theme Adwaita/index.theme default 2>/dev/null
$SCP /tmp/adwaita-cursors.tar.gz root@$EVM_IP:/tmp/
$SSH 'tar xzf /tmp/adwaita-cursors.tar.gz -C /usr/share/icons/ && rm /tmp/adwaita-cursors.tar.gz'
echo "  ✓ Adwaita cursors 部署完成"
echo

# ── 2. Noto Sans TC font ──────────────────────────────────
echo "→ [2/4] Noto Sans TC (從 jsDelivr 下載到 EVM)"
$SSH '
    mkdir -p /usr/share/fonts/truetype/custom
    if [ ! -s /usr/share/fonts/truetype/custom/NotoSansTC.ttf ]; then
        curl -sLfo /usr/share/fonts/truetype/custom/NotoSansTC.ttf \
            "https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanstc/NotoSansTC%5Bwght%5D.ttf"
        echo "  ✓ NotoSansTC 下載完成 ($(du -h /usr/share/fonts/truetype/custom/NotoSansTC.ttf | cut -f1))"
    else
        echo "  ✓ NotoSansTC 已存在，跳過"
    fi
'
echo

# ── 3. fontconfig fallback ────────────────────────────────
echo "→ [3/4] fontconfig fallback"
$SCP "$HERE/99-noto-cjk-fallback.conf" root@$EVM_IP:/etc/fonts/conf.d/
$SSH 'fc-cache -f >/dev/null 2>&1 && echo "  ✓ fc-cache 完成，zh-tw fallback 啟用："
fc-match -s "sans-serif:lang=zh-tw" 2>/dev/null | head -2'
echo

# ── 4. tty-aware whetstone script ─────────────────────────
echo "→ [4/4] tty-aware run-whetstone.sh"
$SSH '[ -f /opt/ti-apps-launcher/run-whetstone.sh ] && \
    cp /opt/ti-apps-launcher/run-whetstone.sh /opt/ti-apps-launcher/run-whetstone.sh.orig-pre-tty 2>/dev/null || true'
$SCP "$HERE/run-whetstone.sh" root@$EVM_IP:/opt/ti-apps-launcher/run-whetstone.sh
$SSH 'chmod +x /opt/ti-apps-launcher/run-whetstone.sh && echo "  ✓ run-whetstone.sh 已替換 (備份在 .orig-pre-tty)"'
echo

echo "✓ 全部完成。接著可以跑 ../build.sh && ../deploy.sh 部署 launcher。"
