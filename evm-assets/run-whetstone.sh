#!/bin/sh
#
# the meter vendor RD11_Chung 客製版 Whetstone (with scrollable full output)
# 還原: cp /opt/ti-apps-launcher/run-whetstone.sh.orig /opt/ti-apps-launcher/run-whetstone.sh

LOG=/tmp/whetstone_full.log

# 依 CPU 自動決定迴圈數
a=$(cat /proc/cpuinfo | grep "CPU part" | awk "{print \$4}" | head -1)
if [ "$a" = "0xc08" ]; then
    iterations=50000
else
    iterations=1000000
fi

# 跑 whetstone，同時 tee 到 log
/opt/vendor/whetstone $iterations 2>&1 | tee "$LOG"

# 互動式翻頁僅在有 tty (terminal) 時啟用；
# edgepilot-launcher Qt dialog 沒有 tty，會直接 EOF 跳過。
if [ -t 0 ] && [ -t 1 ]; then
    echo ""
    echo "==============================================="
    echo "  Press any key to scroll through full output"
    echo "  (q to quit pager)"
    echo "==============================================="
    read -n 1 _

    less -R "$LOG"

    echo ""
    read -n 1 -p "To exit, press any key from keyboard connected to Starter Kit or close the terminal..."
fi
