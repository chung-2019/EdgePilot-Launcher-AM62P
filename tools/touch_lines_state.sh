#!/bin/bash
#
# touch_lines_state.sh
#
# Dump the real-time logic level of the two key GPIO expander pins on
# AM62P-SK that carry the OLDI panel's touch signals. Use this when touch
# stopped working and you need to isolate "chip dead" vs "reset stuck low"
# vs "INT line not toggling" without breaking out a multimeter.
#
# Mapping (per AM62P_EVM.md Table 2-5 J27 connector + 2-30 IO expander):
#   J27 pin 32  OLDI_INT#   →  TCA6424 exp1 (i2c-1 0x22)  P0.0   (active LOW)
#   J27 pin 33  OLDI_RESETN →  TCA6424 exp2 (i2c-1 0x23)  P2.4   (active LOW)
#
# TCA6424 input register layout: 0x00=Port0, 0x01=Port1, 0x02=Port2
# (each port = 8 lines, bit 0 = first line).
#
# We read the expander INPUT REGISTER directly with `i2cget -f` so the
# Linux ili251x driver's claim on these GPIOs doesn't block us.

set -u

read_bit() {
    local bus=$1 addr=$2 reg=$3 bit=$4
    local v=$(i2cget -f -y "$bus" "$addr" "$reg" 2>/dev/null)
    [ -z "$v" ] && { echo "?"; return; }
    echo $(( (v >> bit) & 1 ))
}

read_int()   { read_bit 1 0x22 0x00 0; }   # exp1 P0.0 = OLDI_INT#
read_reset() { read_bit 1 0x23 0x02 4; }   # exp2 P2.4 = OLDI_RSTn

label_int() {
    case "$1" in
        0) echo "ASSERTED (LOW) — touch IC pulled INT — chip is sensing!" ;;
        1) echo "idle (HIGH)" ;;
        *) echo "read failed" ;;
    esac
}
label_reset() {
    case "$1" in
        0) echo "held in RESET (LOW) — chip is OFF, won't respond" ;;
        1) echo "released (HIGH) — chip should be powered up" ;;
        *) echo "read failed" ;;
    esac
}

snapshot() {
    local i=$(read_int)
    local r=$(read_reset)
    printf "  OLDI_INT#    (J27 pin 32, exp1 P0.0)  = %s  → %s\n" "$i" "$(label_int "$i")"
    printf "  OLDI_RESETN  (J27 pin 33, exp2 P2.4)  = %s  → %s\n" "$r" "$(label_reset "$r")"
}

cat <<'BANNER'
══ AM62P-SK touch line state ══════════════════════════════════════════════
  EVM end (J27)            TCA6424 expander          Polarity
  Pin 32  OLDI_INT#    →   i2c-1 0x22  P0.0          active LOW (touch=0)
  Pin 33  OLDI_RESETN  →   i2c-1 0x23  P2.4          active LOW (reset=0)
═══════════════════════════════════════════════════════════════════════════

[snapshot]
BANNER

snapshot

cat <<'CONT'

[continuous monitoring — 12 seconds]
Touch the LCD now. If hardware is OK, INT line should drop to 0 on each
touch and return to 1 on release. RESET line should stay at 1 the whole
time. Only changes are printed.
CONT

prev=""
samples=120                    # 12 s @ 100 ms
for i in $(seq 1 $samples); do
    cur="$(read_int)/$(read_reset)"
    if [ "$cur" != "$prev" ]; then
        ms=$(( i * 100 ))
        int_v="${cur%/*}"
        rst_v="${cur#*/}"
        printf "  t=%5d ms   INT=%s  RST=%s   %s\n" "$ms" "$int_v" "$rst_v" \
            "$(if [ "$int_v" = "0" ]; then echo '← TOUCH detected'; fi)"
        prev="$cur"
    fi
    sleep 0.1
done

echo
echo "[final snapshot]"
snapshot
echo
echo "Interpretation:"
echo "  • RST stays 1, INT only ever 1     → chip alive but never reports touch"
echo "                                       = chip-side problem (firmware/sensor)"
echo "  • RST stays 1, INT toggles 1→0→1   → hardware OK!"
echo "                                       = Linux driver/Wayland/Qt layer issue"
echo "  • RST stays 0 the whole time       → reset never released"
echo "                                       = panel driver bug or GPIO contention"
echo "  • Both show '?'                    → can't read expander (i2c-1 issue)"
