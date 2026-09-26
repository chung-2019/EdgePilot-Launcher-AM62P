// Clock.qml
//
// Analog watch face built from 4 PNGs (Watch7Background / Hour / Minute / Second).
// Background is 454×454. Each hand image is vertical with the pointer tip at
// the TOP of the image and the pivot hole near the BOTTOM. The pivot pixel
// is approximately (W/2, H − W/2) for each hand — i.e. centered horizontally,
// one half-width up from the bottom edge (which is the radius of the round
// hub at the base of the hand).
//
// Pivot constants (original image pixels, computed once and scaled at render):
//   Hour    15×90  → pivot ( 7.5,  82.5)
//   Minute  15×150 → pivot ( 7.5, 142.5)
//   Second  13×179 → pivot ( 6.5, 172.5)
//
// The Clock auto-scales: caller sets any size, internal `s` is the ratio
// of the rendered square to the native 454. Width != height is tolerated —
// the watch face is centered as a square within the larger dimension.

import QtQuick

Item {
    id: clock

    implicitWidth:  160
    implicitHeight: 160

    // Live time state (refreshed by Timer + onCompleted)
    property int currentHour:   0
    property int currentMinute: 0
    property int currentSecond: 0

    function refresh() {
        var d = new Date()
        clock.currentHour   = d.getHours()
        clock.currentMinute = d.getMinutes()
        clock.currentSecond = d.getSeconds()
    }

    // Square watch-face metrics (handles non-square parent gracefully)
    readonly property real bgSize: Math.min(width, height)
    readonly property real bgX:    (width  - bgSize) / 2
    readonly property real bgY:    (height - bgSize) / 2
    readonly property real cx:     bgX + bgSize / 2
    readonly property real cy:     bgY + bgSize / 2
    readonly property real s:      bgSize / 454           // scale to native PNG

    // ── Watch face background ────────────────────────────────────────────
    Image {
        id: bg
        x: clock.bgX
        y: clock.bgY
        width:  clock.bgSize
        height: clock.bgSize
        source: "qrc:/Clock/Watch7Background.png"
        sourceSize: Qt.size(454, 454)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }

    // ── Hour hand (red, 15×90, pivot (7.5, 82.5)) ────────────────────────
    Image {
        id: hourHand
        source: "qrc:/Clock/Watch7Hour.png"
        sourceSize: Qt.size(15, 90)
        smooth: true
        mipmap: true
        width:  15 * clock.s
        height: 90 * clock.s
        x: clock.cx -  7.5 * clock.s
        y: clock.cy - 82.5 * clock.s
        transform: Rotation {
            origin.x:  7.5 * clock.s
            origin.y: 82.5 * clock.s
            angle: (clock.currentHour % 12) * 30 + clock.currentMinute * 0.5
        }
    }

    // ── Minute hand (white, 15×150, pivot (7.5, 142.5)) ──────────────────
    Image {
        id: minuteHand
        source: "qrc:/Clock/Watch7Minute.png"
        sourceSize: Qt.size(15, 150)
        smooth: true
        mipmap: true
        width:  15  * clock.s
        height: 150 * clock.s
        x: clock.cx -   7.5 * clock.s
        y: clock.cy - 142.5 * clock.s
        transform: Rotation {
            origin.x:   7.5 * clock.s
            origin.y: 142.5 * clock.s
            angle: clock.currentMinute * 6 + clock.currentSecond * 0.1
        }
    }

    // ── Second hand (grey thin, 13×179, pivot (6.5, 172.5)) ──────────────
    Image {
        id: secondHand
        source: "qrc:/Clock/Watch7Second.png"
        sourceSize: Qt.size(13, 179)
        smooth: true
        mipmap: true
        width:  13  * clock.s
        height: 179 * clock.s
        x: clock.cx -   6.5 * clock.s
        y: clock.cy - 172.5 * clock.s
        transform: Rotation {
            origin.x:   6.5 * clock.s
            origin.y: 172.5 * clock.s
            angle: clock.currentSecond * 6
        }
    }

    // 1Hz tick. Component.onCompleted does an immediate refresh so the very
    // first frame already shows the correct angle (no visible jump at start).
    Timer {
        interval: 1000
        running: true
        repeat:  true
        onTriggered: clock.refresh()
    }
    Component.onCompleted: clock.refresh()
}
