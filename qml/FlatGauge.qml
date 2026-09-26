import QtQuick

Item {
    id: root

    property real   value: 0
    property real   minValue: 0
    property real   maxValue: 100
    property string unit: "%"
    property color  progressColor: "#2563eb"
    property real   ringThickness: 14
    property string displayText: Math.round(root.value) + root.unit
    property int    valuePixelSize: 44

    readonly property real ratio: {
        var span = root.maxValue - root.minValue
        if (span <= 0) return 0
        return Math.max(0, Math.min(1, (root.value - root.minValue) / span))
    }

    implicitWidth: 220
    implicitHeight: 220

    Canvas {
        id: arc
        anchors.fill: parent

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var r  = Math.min(width, height) / 2 - root.ringThickness / 2 - 2
            if (r <= 0) return
            var cx = width / 2
            var cy = height / 2

            // Track (full circle, flat dark gray)
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, 2 * Math.PI)
            ctx.strokeStyle = "#333333"
            ctx.lineWidth = root.ringThickness
            ctx.lineCap = "butt"
            ctx.stroke()

            // Progress arc (top → clockwise), solid color, no gradient
            if (root.ratio > 0) {
                var startAngle = -Math.PI / 2
                var endAngle   = startAngle + root.ratio * 2 * Math.PI
                ctx.beginPath()
                ctx.arc(cx, cy, r, startAngle, endAngle)
                ctx.strokeStyle = root.progressColor
                ctx.lineWidth = root.ringThickness
                ctx.stroke()
            }
        }

        onWidthChanged:  requestPaint()
        onHeightChanged: requestPaint()

        Connections {
            target: root
            function onRatioChanged()          { arc.requestPaint() }
            function onProgressColorChanged()  { arc.requestPaint() }
            function onRingThicknessChanged()  { arc.requestPaint() }
        }
    }

    Text {
        anchors.centerIn: parent
        text: root.displayText
        color: root.progressColor
        font.pixelSize: root.valuePixelSize
        font.bold: true
    }
}
