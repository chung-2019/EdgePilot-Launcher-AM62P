#!/bin/sh
# CC3351 BLE watchdog
# A cc33xx Wi-Fi "FW is stuck" recovery resets debugfs ble_enable to 0 and drops
# hci0; the boot-time oneshot cc33xx-ble-enable.service does not re-run, so BLE
# stays dead until reboot. This watchdog re-enables BLE (0->1 edge) + re-attaches
# hci0. Harmless when BT is healthy (exits immediately). Does NOT touch Wi-Fi.

[ -e /sys/class/bluetooth/hci0 ] && exit 0   # BT present -> nothing to do

logger -t cc33xx-ble-watchdog "hci0 missing -> re-enabling CC3351 BLE"

# 1) re-enable the BLE subsystem via debugfs (the gate the chip reset cleared).
#    Writing 1 produces the 0->1 edge the btti probe needs to register hci0.
for f in /sys/kernel/debug/ieee80211/phy*/cc33xx/ble_enable; do
    [ -e "$f" ] && echo 1 > "$f" 2>/dev/null
done

# 2) rebind the btti serdev so its probe re-runs and re-registers hci0.
#    Works whether btti is currently bound (unbind is a no-op error if not).
BT=$(ls /sys/bus/serial/devices/ 2>/dev/null | grep -m1 'serial[0-9]*-')
[ -z "$BT" ] && BT=serial0-0
echo "$BT" > /sys/bus/serial/drivers/btti/unbind 2>/dev/null
sleep 1
echo "$BT" > /sys/bus/serial/drivers/btti/bind 2>/dev/null

sleep 2
if [ -e /sys/class/bluetooth/hci0 ]; then
    systemctl restart bluetooth
    logger -t cc33xx-ble-watchdog "hci0 recovered ($BT)"
else
    logger -t cc33xx-ble-watchdog "hci0 still missing after re-enable ($BT)"
fi
