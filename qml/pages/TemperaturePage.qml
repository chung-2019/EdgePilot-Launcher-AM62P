import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects

// Sidebar Temperature page — dual 3D-rendered temperature graphs
// (TMP119 ambient + SoC junction) shown directly. Navigation away is via
// the sidebar — no in-page close button.
Rectangle {
    id: root

    readonly property int xMax: systemMonitor.historyCapacity   // 60 s

    // Deep-space gradient bg (same vibe as the old TemperatureGraphDialog)
    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0.0; color: "#020716" }
        GradientStop { position: 1.0; color: "#050E22" }
    }

    // ─────────────────────── One graph panel ───────────────────────
    component TempPanel: Item {
        id: panelRoot

        property string panelTitle: ""
        property var    samples: []
        property real   yMinValue: 0
        property real   yMaxValue: 100
        property int    yStep: 10
        property color  accent: "#4FC3F7"
        property color  accentBright: "#B3E5FC"
        property int    valueDecimals: 1
        // 非空字串時：當最新讀值無效（NaN）會在圖面中央顯示此「未連接」提示
        property string disconnectedText: ""

        readonly property real currentValue:
            samples.length > 0 ? samples[samples.length - 1] : 0
        // 最新一筆是否為有效讀值（NaN/缺值＝感測器讀取失敗，如 TMP119 拔線）
        readonly property bool currentValid:
            samples.length > 0 && !isNaN(samples[samples.length - 1])
        // 將 samples 依 NaN 切成多個「連續有效段」，每段 [{i, v}, …]；曲線逐段繪製→缺口斷線
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

        Item {
            id: pHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 72
            anchors.rightMargin: 30
            height: 48

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                text: panelRoot.panelTitle
                color: "#E0F4FF"
                font.pixelSize: 20
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
                    font.pixelSize: 42
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
                    text: "°C"
                    color: panelRoot.accent
                    font.pixelSize: 22
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        Item {
            id: pChart
            anchors.top: pHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 72
            anchors.rightMargin: 30
            anchors.topMargin: 4
            anchors.bottomMargin: 28

            function xPx(i) { return i / Math.max(1, root.xMax - 1) * width }
            function yPx(v) {
                const t = (v - panelRoot.yMinValue)
                        / (panelRoot.yMaxValue - panelRoot.yMinValue)
                return height - Math.max(0, Math.min(1, t)) * height
            }

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
                        font.pixelSize: 12
                    }
                }
            }

            Repeater {
                model: 7
                Item {
                    width: 0
                    height: pChart.height
                    x: index * (pChart.width / 6)
                    Rectangle {
                        anchors.horizontalCenter: parent.left
                        y: 0
                        width: 1
                        height: pChart.height
                        color: "#1A2F52"
                    }
                    Text {
                        anchors.horizontalCenter: parent.left
                        anchors.top: parent.bottom
                        anchors.topMargin: 6
                        text: (index * 10).toString()
                        color: "#7892B5"
                        font.pixelSize: 11
                    }
                }
            }

            // 填色（漸層）— 逐「連續有效段」繪製；NaN 缺口不填色
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
                            GradientStop { position: 0.0; color: Qt.rgba(
                                panelRoot.accent.r, panelRoot.accent.g,
                                panelRoot.accent.b, 0.45) }
                            GradientStop { position: 1.0; color: Qt.rgba(
                                panelRoot.accent.r, panelRoot.accent.g,
                                panelRoot.accent.b, 0.02) }
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

            // 霓虹線（含外發光）— 逐「連續有效段」繪製；NaN 處斷線（曲線停止）
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

            // 感測器未連接提示：有設定提示文字、已有取樣、且最新值無效（NaN）時顯示
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
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "(No sensor reading / disconnected)"
                    color: "#7892B5"
                    font.pixelSize: 13
                }
            }
        }
    }

    // ───── Bezel + HUD bracket frame ─────
    Rectangle {
        id: bezel
        anchors.fill: parent
        anchors.margins: 24
        color: "transparent"
        border.color: "#0E2342"
        border.width: 2
        radius: 4

        readonly property int armLen: 36
        readonly property int armW:   3
        readonly property int armOff: 2

        property real pulse: 1.0
        SequentialAnimation on pulse {
            loops: Animation.Infinite
            NumberAnimation { from: 1.0; to: 0.55; duration: 1600
                              easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.55; to: 1.0; duration: 1600
                              easing.type: Easing.InOutSine }
        }

        component HudBracket: Item {
            id: hud
            property string corner: "tl"
            property color  glowColor: "#55DFFF"
            property real   pulse: 1.0
            property int    armLen: 32
            property int    armW: 3

            readonly property bool isTop:  corner === "tl" || corner === "tr"
            readonly property bool isLeft: corner === "tl" || corner === "bl"

            width: armLen
            height: armLen

            Item {
                anchors.fill: parent
                Rectangle {
                    x: 0
                    y: hud.isTop ? 0 : hud.armLen - hud.armW
                    width: hud.armLen; height: hud.armW
                    color: hud.glowColor
                }
                Rectangle {
                    x: hud.isLeft ? 0 : hud.armLen - hud.armW
                    y: 0
                    width: hud.armW; height: hud.armLen
                    color: hud.glowColor
                }
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: 1.0
                    blurMax: 36
                    brightness: 0.5
                    autoPaddingEnabled: true
                }
                opacity: 0.55 * hud.pulse
            }

            Item {
                anchors.fill: parent
                Rectangle {
                    x: 0
                    y: hud.isTop ? 0 : hud.armLen - hud.armW
                    width: hud.armLen; height: hud.armW
                    color: hud.glowColor
                }
                Rectangle {
                    x: hud.isLeft ? 0 : hud.armLen - hud.armW
                    y: 0
                    width: hud.armW; height: hud.armLen
                    color: hud.glowColor
                }
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: 0.5
                    blurMax: 14
                    brightness: 0.4
                    autoPaddingEnabled: true
                }
                opacity: 0.9
            }

            Rectangle {
                x: 0
                y: hud.isTop ? 0 : hud.armLen - hud.armW
                width: hud.armLen; height: hud.armW
                color: Qt.lighter(hud.glowColor, 1.6)
            }
            Rectangle {
                x: hud.isLeft ? 0 : hud.armLen - hud.armW
                y: 0
                width: hud.armW; height: hud.armLen
                color: Qt.lighter(hud.glowColor, 1.6)
            }
        }

        readonly property color hudGlow: "#4FC3F7"

        HudBracket {
            corner: "tl"; glowColor: bezel.hudGlow
            armLen: bezel.armLen; armW: bezel.armW; pulse: bezel.pulse
            anchors.top: parent.top; anchors.left: parent.left
            anchors.topMargin: bezel.armOff; anchors.leftMargin: bezel.armOff
        }
        HudBracket {
            corner: "tr"; glowColor: bezel.hudGlow
            armLen: bezel.armLen; armW: bezel.armW; pulse: bezel.pulse
            anchors.top: parent.top; anchors.right: parent.right
            anchors.topMargin: bezel.armOff; anchors.rightMargin: bezel.armOff
        }
        HudBracket {
            corner: "bl"; glowColor: bezel.hudGlow
            armLen: bezel.armLen; armW: bezel.armW; pulse: bezel.pulse
            anchors.bottom: parent.bottom; anchors.left: parent.left
            anchors.bottomMargin: bezel.armOff; anchors.leftMargin: bezel.armOff
        }
        HudBracket {
            corner: "br"; glowColor: bezel.hudGlow
            armLen: bezel.armLen; armW: bezel.armW; pulse: bezel.pulse
            anchors.bottom: parent.bottom; anchors.right: parent.right
            anchors.bottomMargin: bezel.armOff; anchors.rightMargin: bezel.armOff
        }

        Text {
            id: globalTitle
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: 22
            text: "Temperature Monitoring"
            color: "#E0F4FF"
            font.pixelSize: 24
            font.bold: true
            font.letterSpacing: 2
        }

        ColumnLayout {
            anchors.top: globalTitle.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.topMargin: 18
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.bottomMargin: 22
            spacing: 24

            TempPanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                panelTitle: "TMP119 Ambient (°C)"
                disconnectedText: "TMP119 not connected"
                samples: systemMonitor.ambientHistory
                yMinValue: 20
                yMaxValue: 45
                yStep: 5
                accent: "#4FC3F7"
                accentBright: "#B3E5FC"
                valueDecimals: 1
            }

            TempPanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                panelTitle: "SoC Junction (°C)"
                samples: systemMonitor.socTempHistory
                yMinValue: 30
                yMaxValue: 90
                yStep: 10
                accent: "#FF8A65"
                accentBright: "#FFCCBC"
                valueDecimals: 0
            }
        }
    }

}
