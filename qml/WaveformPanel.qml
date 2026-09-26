import QtQuick

Rectangle {
    id: root

    property string title: ""
    property string subtitle: ""
    property string rightLabel: ""
    property color  titleColor: "#9ca3af"
    property color  waveColor: "#00ff00"
    property real   lineWidth: 2.5
    property real   timeWindowSec: 10
    property var    sampleFunc: function(t) { return 0 }
    property bool   showTimeAxis: false
    property int    timeAxisTickInterval: 1
    property real   eraseWidth: 30

    implicitWidth: 400
    implicitHeight: 180
    color: "#0a0a0a"
    border.width: 1
    border.color: "#1f2937"
    radius: 6
    clip: true

    // ── Core sweep-erase state
    //   scanX  : current x where new sample lands (1-px micro-step granularity)
    //   lastX  : previous draw x (–1 means "no prior point, skip first stroke")
    //   lastY  : previous draw y (in canvas pixels)
    //   phase  : continuous seconds-of-signal time (sampleFunc input)
    property real scanX: 0
    property real lastX: -1
    property real lastY: -1
    property real phase: 0

    // Sub-pixel pixel debt accumulated by tick() — onPaint consumes integer pixels.
    // Lets us run a fixed-rate Timer while staying perfectly periodic per pixel.
    property real pendingAdvance: 0

    // ── Title bar
    Item {
        id: titleBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.topMargin: 8
        height: 16
        z: 10

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 14

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.title
                color: root.titleColor
                font.pixelSize: 12
                font.bold: true
                visible: text !== ""
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.subtitle
                color: "#6b7280"
                font.pixelSize: 11
                visible: text !== ""
            }
        }

        Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.rightLabel
            color: "#6b7280"
            font.pixelSize: 11
            visible: text !== ""
        }
    }

    Canvas {
        id: wave
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: titleBar.bottom
        anchors.topMargin: 4
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.showTimeAxis ? 20 : 4

        // ════════════════════════════════════════════════════════════
        //  Sweep-Erase Rendering Pipeline
        //  No global clearRect per frame. Each integer pixel of advance:
        //    1. wrap-around check
        //    2. clearRect(scanX, 0, eraseWidth, height)  ← TRANSPARENT
        //    3. stroke from (lastX, lastY) → (scanX, currentY)
        //    4. update state
        // ════════════════════════════════════════════════════════════
        onPaint: {
            if (!available || width <= 0 || height <= 0) return
            var ctx = getContext("2d")
            if (!ctx) return

            var stepsLeft = Math.floor(root.pendingAdvance)
            if (stepsLeft < 1) return
            root.pendingAdvance -= stepsLeft

            var dtPerPx = root.timeWindowSec / width
            var halfH   = height * 0.5
            var ampPx   = height * 0.40

            // Configure stroke style once for all sub-segments this frame
            ctx.strokeStyle = root.waveColor
            ctx.lineWidth   = root.lineWidth
            ctx.lineCap     = "round"
            ctx.lineJoin    = "round"

            for (var i = 0; i < stepsLeft; i++) {
                // Advance signal phase and compute the new Y sample
                root.phase += dtPerPx
                var sample   = root.sampleFunc(root.phase)
                var currentY = halfH - sample * ampPx

                // ── Step 1: wrap-around (don't draw a line across the canvas)
                if (root.scanX >= width) {
                    root.scanX = 0
                    root.lastX = 0
                    root.lastY = currentY   // continuity anchor for next stroke
                    root.scanX += 1
                    continue
                }

                // ── Step 2: local erase ahead of scanX (transparent, NOT black)
                ctx.clearRect(root.scanX, 0, root.eraseWidth, height)

                // ── Step 3: draw the new 1-px segment
                if (root.lastX >= 0) {
                    ctx.beginPath()
                    ctx.moveTo(root.lastX, root.lastY)
                    ctx.lineTo(root.scanX, currentY)
                    ctx.stroke()
                }

                // ── Step 4: advance state
                root.lastX = root.scanX
                root.lastY = currentY
                root.scanX += 1
            }
        }

        onWidthChanged:     root.reset()
        onHeightChanged:    root.reset()
        onAvailableChanged: if (available) root.reset()
    }

    // ── Time axis
    Row {
        visible: root.showTimeAxis
        anchors.left: wave.left
        anchors.right: wave.right
        anchors.top: wave.bottom
        anchors.topMargin: 2
        spacing: 0

        Repeater {
            model: root.showTimeAxis
                   ? Math.floor(root.timeWindowSec / root.timeAxisTickInterval) + 1
                   : 0
            Item {
                width: wave.width / Math.max(1, Math.floor(root.timeWindowSec / root.timeAxisTickInterval))
                height: 14
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: (index * root.timeAxisTickInterval) + "s"
                    color: "#6b7280"
                    font.pixelSize: 10
                }
            }
        }
    }

    // ── External API
    function reset() {
        scanX = 0
        lastX = -1
        lastY = -1
        phase = 0
        pendingAdvance = 0
        if (!wave.available || wave.width <= 0 || wave.height <= 0) return
        var ctx = wave.getContext("2d")
        // One-time full clear when (re)opening the panel — NOT a per-frame op
        if (ctx) ctx.clearRect(0, 0, wave.width, wave.height)
    }

    // Driven by the dialog's shared 30 Hz Timer.
    // Each call accumulates `dt * pixelsPerSecond` of pixel advance.
    // onPaint consumes the integer part as 1-px micro-steps.
    function tick(dt) {
        if (wave.width <= 0) return
        pendingAdvance += dt * (wave.width / Math.max(0.001, timeWindowSec))
        wave.requestPaint()
    }
}
