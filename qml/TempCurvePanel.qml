import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects

// Reusable neon temperature-curve panel (extracted from the TempPanel used on
// TemperaturePage / TemperatureGraphDialog, generalised for any data source).
//
//   samples       : array of numbers; NaN entries break the line into gaps
//   yMinValue/Max : vertical range   (USB page: 20 … 40)
//   yStep         : gridline / label spacing (USB page: 1 °C per unit)
//   valueDecimals : decimals on the big header readout (USB page: 2)
//   xMax          : how many samples span the full chart width
Item {
    id: panelRoot

    property string panelTitle: ""
    property string unitText: "°C"
    property var    samples: []
    property real   yMinValue: 20
    property real   yMaxValue: 40
    property real   yStep: 1
    property int    xMax: 120
    property color  accent: "#4FC3F7"
    property color  accentBright: "#B3E5FC"
    // Area-fill gradient (top → bottom). Defaults derive from `accent` so
    // existing users (USB / dialog) are unchanged; callers can override for a
    // custom fill (the memory thermometer uses a teal→blue weather-widget style).
    property color  fillTopColor: Qt.rgba(accent.r, accent.g, accent.b, 0.45)
    property color  fillBottomColor: Qt.rgba(accent.r, accent.g, accent.b, 0.02)
    property int    valueDecimals: 2
    // Y-axis (vertical) temperature-label font size. Default matches the
    // original 13 px so existing users (UsbPage, TemperatureGraphDialog) are
    // unchanged; callers can bump it (e.g. the memory-thermometer page uses 15).
    property int    axisLabelSize: 13
    // Y-axis (vertical, temperature) label size. Defaults to axisLabelSize so
    // callers can enlarge the Y numbers independently of the X-axis labels.
    property int    yAxisLabelSize: axisLabelSize
    // When true, label the vertical gridlines with record numbers (1..xMax)
    // under the X axis. Default off — existing users (USB / dialog) unchanged.
    property bool   showXAxisLabels: false
    // When set, shown centered if there are samples but the latest is invalid.
    property string disconnectedText: ""
    // When set, shown centered when there are no samples at all yet.
    property string idleText: ""

    readonly property real currentValue:
        samples.length > 0 ? samples[samples.length - 1] : 0
    readonly property bool currentValid:
        samples.length > 0 && !isNaN(samples[samples.length - 1])

    // Split samples on NaN into contiguous valid runs, each [{i, v}, …], so the
    // curve is drawn segment-by-segment and misses become gaps.
    readonly property var segments: {
        const segs = []
        let cur = []
        for (let i = 0; i < samples.length; ++i) {
            const v = samples[i]
            if (v === undefined || v === null || isNaN(v)) {
                if (cur.length > 0) { segs.push(cur); cur = [] }
            } else {
                cur.push({ i: i, v: v })
            }
        }
        if (cur.length > 0) segs.push(cur)
        return segs
    }

    // ── Header: title (left) + big current value (right) ──
    Item {
        id: pHeader
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 72
        anchors.rightMargin: 30
        height: 56

        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            text: panelRoot.panelTitle
            color: "#E0F4FF"
            font.pixelSize: 22
            font.bold: true
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Text {
                text: panelRoot.currentValid
                      ? panelRoot.currentValue.toFixed(panelRoot.valueDecimals)
                      : "--"
                color: panelRoot.accentBright
                font.pixelSize: 52
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blurMax: 24
                    blur: 0.5
                    brightness: 0.3
                }
            }
            Text {
                text: panelRoot.unitText
                color: panelRoot.accent
                font.pixelSize: 24
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // ── Chart ──
    Item {
        id: pChart
        anchors.top: pHeader.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 72
        anchors.rightMargin: 30
        anchors.topMargin: 4
        anchors.bottomMargin: 20

        function xPx(i) { return i / Math.max(1, panelRoot.xMax - 1) * width }
        function yPx(v) {
            const t = (v - panelRoot.yMinValue)
                    / (panelRoot.yMaxValue - panelRoot.yMinValue)
            return height - Math.max(0, Math.min(1, t)) * height
        }

        // Y-axis labels + horizontal gridlines (one per yStep)
        Repeater {
            model: Math.floor(
                (panelRoot.yMaxValue - panelRoot.yMinValue) / panelRoot.yStep) + 1
            Item {
                width: pChart.width
                height: 0
                y: pChart.yPx(panelRoot.yMinValue + index * panelRoot.yStep)
                Rectangle {
                    anchors.verticalCenter: parent.top
                    width: pChart.width
                    height: 1
                    color: "#1A2F52"
                }
                Text {
                    anchors.right: parent.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.top
                    text: (panelRoot.yMinValue + index * panelRoot.yStep).toString()
                    color: "#7892B5"
                    font.pixelSize: panelRoot.yAxisLabelSize
                }
            }
        }

        // Vertical gridlines (6 divisions, no numeric labels — poll interval varies)
        Repeater {
            model: 7
            Rectangle {
                x: index * (pChart.width / 6)
                y: 0
                width: 1
                height: pChart.height
                color: "#122544"
            }
        }

        // X-axis record-number labels (opt-in): 1 … xMax across the 7 gridlines.
        Repeater {
            model: panelRoot.showXAxisLabels ? 7 : 0
            Item {
                x: index * (pChart.width / 6)
                y: pChart.height + 2
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Math.round(1 + (Math.max(2, panelRoot.xMax) - 1)
                                     * index / 6).toString()
                    color: "#7892B5"
                    font.pixelSize: panelRoot.axisLabelSize
                }
            }
        }

        // Filled area under each segment (gradient fade)
        Repeater {
            model: panelRoot.segments
            Shape {
                anchors.fill: pChart
                visible: modelData.length >= 2
                ShapePath {
                    strokeColor: "transparent"
                    strokeWidth: 0
                    fillGradient: LinearGradient {
                        x1: 0; y1: 0
                        x2: 0; y2: pChart.height
                        GradientStop { position: 0.0; color: panelRoot.fillTopColor }
                        GradientStop { position: 1.0; color: panelRoot.fillBottomColor }
                    }
                    startX: pChart.xPx(modelData[0].i)
                    startY: pChart.height
                    PathLine {
                        x: pChart.xPx(modelData[0].i)
                        y: pChart.yPx(modelData[0].v)
                    }
                    PathPolyline {
                        path: {
                            const pts = []
                            for (let k = 0; k < modelData.length; ++k)
                                pts.push(Qt.point(
                                    pChart.xPx(modelData[k].i),
                                    pChart.yPx(modelData[k].v)))
                            return pts
                        }
                    }
                    PathLine {
                        x: pChart.xPx(modelData[modelData.length - 1].i)
                        y: pChart.height
                    }
                    PathLine { x: pChart.xPx(modelData[0].i); y: pChart.height }
                }
            }
        }

        // Neon polyline (Gaussian glow halo)
        Repeater {
            model: panelRoot.segments
            Shape {
                anchors.fill: pChart
                visible: modelData.length >= 2
                ShapePath {
                    strokeColor: panelRoot.accentBright
                    strokeWidth: 3
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    startX: pChart.xPx(modelData[0].i)
                    startY: pChart.yPx(modelData[0].v)
                    PathPolyline {
                        path: {
                            const pts = []
                            for (let k = 0; k < modelData.length; ++k)
                                pts.push(Qt.point(
                                    pChart.xPx(modelData[k].i),
                                    pChart.yPx(modelData[k].v)))
                            return pts
                        }
                    }
                }
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blurMax: 32
                    blur: 1.0
                    brightness: 0.3
                }
            }
        }

        // Latest-sample glowing dot
        Item {
            visible: panelRoot.currentValid
            x: panelRoot.currentValid
               ? pChart.xPx(panelRoot.samples.length - 1) : 0
            y: panelRoot.currentValid
               ? pChart.yPx(panelRoot.currentValue) : 0
            width: 0
            height: 0
            Rectangle {
                width: 14
                height: 14
                radius: 7
                anchors.centerIn: parent
                color: panelRoot.accentBright
                border.color: panelRoot.accent
                border.width: 2
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blurMax: 20
                    blur: 0.7
                    brightness: 0.5
                }
            }
        }

        // "No data yet" idle hint
        Text {
            anchors.centerIn: parent
            visible: panelRoot.idleText !== "" && panelRoot.samples.length === 0
            text: panelRoot.idleText
            color: "#48607F"
            font.pixelSize: 18
        }

        // Latest read invalid / disconnected hint
        Column {
            anchors.centerIn: parent
            spacing: 6
            visible: panelRoot.disconnectedText !== ""
                     && panelRoot.samples.length > 0
                     && !panelRoot.currentValid
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "⚠  " + panelRoot.disconnectedText
                color: "#FF6E6E"
                font.pixelSize: 18
                font.bold: true
            }
        }
    }
}
