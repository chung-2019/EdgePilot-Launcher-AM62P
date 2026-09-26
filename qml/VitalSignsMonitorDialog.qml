import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects

Popup {
    id: root

    property string deviceType: "spo2"

    // ── Trend-mode dynamic state (thermometer / glucose / bp)
    property real primaryValueNum:   98
    property real secondaryValueNum: 72
    property bool alertActive: false
    property bool pendingDot: false
    property real trendPhase: 0
    property real trendDriftP: 0
    property real trendDriftS: 0
    property var temperatureSamples: []
    property int temperatureSampleTick: 0

    // ── SpO2 multi-waveform state
    property real hrValue:   72
    property real spo2Value: 98
    property real rrValue:   16
    property real prValue:   72
    property real piValue:   3.52

    // For thermometer, follow whatever unit the peripheral reports via 2A1C
    // Flags bit 0 (0=°C, 1=°F). bleScanner exposes this as lastTemperatureUnit.
    // Other devices ignore this value.
    readonly property string tempUnit: bleScanner.lastTemperatureUnit || "C"
    readonly property var cfg: configFor(deviceType, tempUnit)

    // True for thermometer mode whenever no real reading has come in yet.
    // Shown as "--.--" so the operator knows to take a measurement.
    readonly property bool awaitingMeasurement:
        deviceType === "thermometer" && bleScanner.lastTemperature <= 0

    readonly property string primaryDisplay: {
        if (deviceType === "thermometer") {
            if (awaitingMeasurement) return "--.--"
            // Two decimals. The HTS payload already carries hundredths —
            // Apollo510b builds the IEEE-11073 float with exponent -2, i.e.
            // °C x100 (app_hw_tmp119.c AppHwTmRead) — so the old one-decimal
            // readout was throwing away a digit the device actually sent.
            // Still truncate rather than round: a meter LCD that truncates
            // shows 31.88 for 31.889, and rounding here would disagree with it.
            return (Math.floor(primaryValueNum * 100) / 100).toFixed(2)
        }
        return Math.round(primaryValueNum).toString()
    }
    readonly property string secondaryDisplay: Math.round(secondaryValueNum).toString()

    readonly property color pillAccent: {
        if (!cfg) return "#ffffff"
        if (cfg.pillSingle) return cfg.pillSingle.color
        if (cfg.pillDual)   return cfg.pillDual.primary.color
        return "#ffffff"
    }

    function valueToY(val, chartH) {
        if (!cfg || chartH <= 0) return chartH / 2
        var ratio = (val - cfg.yMin) / (cfg.yMax - cfg.yMin)
        ratio = Math.max(0, Math.min(1, ratio))
        var padTop = 30, padBot = 30
        return padTop + (1 - ratio) * (chartH - padTop - padBot)
    }

    // ── ECG II shape — one cardiac cycle parameterised 0..1
    function ecgShape(cycle) {
        if (cycle > 1) cycle = cycle - Math.floor(cycle)
        if (cycle < 0)  cycle = 0
        if (cycle < 0.07) return 0.15 * Math.sin(cycle / 0.07 * Math.PI)            // P
        if (cycle < 0.12) return 0                                                  // PR
        if (cycle < 0.13) return -0.15 * ((cycle - 0.12) / 0.01)                    // Q
        if (cycle < 0.15) return -0.15 + 1.15 * ((cycle - 0.13) / 0.02)             // R↑
        if (cycle < 0.17) return 1.0 - 1.4 * ((cycle - 0.15) / 0.02)                // R↓/S
        if (cycle < 0.19) return -0.4 + 0.4 * ((cycle - 0.17) / 0.02)               // S→baseline
        if (cycle < 0.30) return 0                                                  // ST
        if (cycle < 0.50) return 0.30 * Math.sin((cycle - 0.30) / 0.20 * Math.PI)   // T
        return 0
    }

    // ── PPG (plethysmograph) — single pulse 0..1 cycle
    function ppgShape(cycle) {
        if (cycle > 1) cycle = cycle - Math.floor(cycle)
        if (cycle < 0)  cycle = 0
        var v
        if (cycle < 0.15)        v = Math.sin(cycle / 0.15 * Math.PI / 2)
        else if (cycle < 0.30)   v = 1.0 - 0.3 * ((cycle - 0.15) / 0.15)
        else if (cycle < 0.40)   v = 0.7 - 0.15 * Math.sin((cycle - 0.30) / 0.10 * Math.PI)
        else                     v = 0.55 * Math.exp(-(cycle - 0.40) * 3.5)
        return v * 1.4 - 0.5   // shift to -0.5..~0.9
    }

    function configFor(t, unit) {
        if (t === "thermometer") {
            // 2A1C Flags bit 0: "F" => Fahrenheit, anything else => Celsius.
            // General temperature measurement (TMP119 contact sensor on the
            // Apollo510b board), NOT body temperature: the axis is a room /
            // ambient range centred on 25.0°C, and there are no fever or
            // hypothermia gates. The two unit variants are the same axis
            // (15/20/25/30/35°C == 59/68/77/86/95°F, exact conversions).
            if (unit === "F") return {
                title: "Live Temperature Trend",
                subtitle: "Continuous scan monitoring - 1-second interval",
                pillIcon: "qrc:/assets/icons/thermometer.svg",
                pillSingle: { label: "Current Temperature", color: "#ffff00", unit: "°F" },
                yMin: 59.0, yMax: 95.0,
                ticks: [
                    { value: 95.0, label: "95.0", color: "#9ca3af" },
                    { value: 86.0, label: "86.0", color: "#9ca3af" },
                    { value: 77.0, label: "77.0", color: "#00ff00" },
                    { value: 68.0, label: "68.0", color: "#9ca3af" },
                    { value: 59.0, label: "59.0", color: "#9ca3af" }
                ],
                warningLines: [
                    { value: 77.0, color: "#00ff00", label: "Reference (25.0°C)" }
                ],
                traces: [ { color: "#ffff00", source: "primary" } ]
            }
            return {
                title: "Live Temperature Trend",
                subtitle: "Continuous scan monitoring - 1-second interval",
                pillIcon: "qrc:/assets/icons/thermometer.svg",
                pillSingle: { label: "Current Temperature", color: "#ffff00", unit: "°C" },
                yMin: 15.0, yMax: 35.0,
                ticks: [
                    { value: 35.0, label: "35.0", color: "#9ca3af" },
                    { value: 30.0, label: "30.0", color: "#9ca3af" },
                    { value: 25.0, label: "25.0", color: "#00ff00" },
                    { value: 20.0, label: "20.0", color: "#9ca3af" },
                    { value: 15.0, label: "15.0", color: "#9ca3af" }
                ],
                warningLines: [
                    { value: 25.0, color: "#00ff00", label: "Reference" }
                ],
                traces: [ { color: "#ffff00", source: "primary" } ]
            }
        }
        if (t === "glucose") return {
            title: "Live Blood Glucose Trend",
            subtitle: "Continuous scan monitoring - 1-second interval",
            pillIcon: "qrc:/assets/icons/heart-pulse.svg",
            pillSingle: { label: "Current Blood Glucose (GLU)", color: "#00ff00", unit: "mg/dL" },
            yMin: 40, yMax: 200,
            ticks: [
                { value: 200, label: "200", color: "#9ca3af" },
                { value: 170, label: "170", color: "#9ca3af" },
                { value: 140, label: "140", color: "#ff3333" },
                { value: 105, label: "105", color: "#00ff00" },
                { value: 70,  label: "70",  color: "#ff3333" },
                { value: 40,  label: "40",  color: "#9ca3af" }
            ],
            warningLines: [
                { value: 140, color: "#ff3333", label: "High glucose threshold (HIGH)" },
                { value: 105, color: "#00ff00", label: "Normal baseline (NORMAL)" },
                { value: 70,  color: "#ff3333", label: "Low glucose threshold (LOW)" }
            ],
            traces: [ { color: "#00ff00", source: "primary" } ]
        }
        if (t === "bp") return {
            title: "Live Blood Pressure Trend",
            subtitle: "Continuous scan monitoring - 1-second interval",
            pillIcon: "qrc:/assets/icons/heart-pulse.svg",
            pillDual: {
                primary:   { label: "Systolic SYS", color: "#00ffff" },
                secondary: { label: "Diastolic DIA", color: "#ff00ff" },
                unit: "mmHg"
            },
            yMin: 40, yMax: 160,
            ticks: [
                { value: 160, label: "160", color: "#9ca3af" },
                { value: 140, label: "140", color: "#ff3333" },
                { value: 120, label: "120", color: "#9ca3af" },
                { value: 100, label: "100", color: "#9ca3af" },
                { value: 80,  label: "80",  color: "#9ca3af" },
                { value: 60,  label: "60",  color: "#9ca3af" },
                { value: 40,  label: "40",  color: "#9ca3af" }
            ],
            warningLines: [
                { value: 140, color: "#ff3333", label: "High systolic threshold (SYS > 140)" },
                { value: 90,  color: "#ff3333", label: "High diastolic threshold (DIA > 90)" }
            ],
            traces: [
                { color: "#00ffff", source: "primary"   },
                { color: "#ff00ff", source: "secondary" }
            ]
        }
        // SpO2 has its own multi-waveform layout — cfg fields below are placeholders
        return {
            title: "Vital Signs Monitor",
            subtitle: "ECG · SpO2 · Respiration"
        }
    }

    // ── 1 Hz value refresh
    function updateValues() {
        var d = deviceType
        var abnormal = Math.random() < 0.15

        trendPhase  += 0.06
        trendDriftP += (Math.random() - 0.5) * 0.2
        trendDriftP  = Math.max(-2, Math.min(2, trendDriftP))
        if (abnormal) {
            trendDriftP += (Math.random() > 0.5 ? 1 : -1) * 0.8
            trendDriftP  = Math.max(-3, Math.min(3, trendDriftP))
        }

        if (d === "spo2") {
            hrValue   = 72 + 5   * Math.sin(trendPhase * 0.5) + trendDriftP * 2
            spo2Value = 97 + 1.5 * Math.sin(trendPhase * 0.3) + trendDriftP * 0.5
            spo2Value = Math.max(85, Math.min(100, spo2Value))
            rrValue   = 16 + 2   * Math.sin(trendPhase * 0.2) + trendDriftP * 0.8
            prValue   = hrValue
            piValue   = 3.5 + 0.3 * Math.sin(trendPhase * 0.4) + trendDriftP * 0.1
            primaryValueNum   = spo2Value
            secondaryValueNum = hrValue
            alertActive = spo2Value < 90 || hrValue < 60 || hrValue > 100
            return
        }

        if (d === "thermometer") {
            // Thermometer mode is BLE-only — no simulated trend. Hold the
            // last real reading (or 0 if none yet) and let the
            // `onTemperatureReceived` connection below push live values in.
            if (bleScanner.lastTemperature > 0) {
                primaryValueNum = bleScanner.lastTemperature
            }
            // General temperature measurement has no fever / hypothermia
            // gates, so nothing here raises the red blink. (Kept as an
            // explicit assignment: alertActive is shared with the other
            // device types and must be cleared when switching into
            // thermometer mode.)
            alertActive = false
        }
        else if (d === "glucose") {
            primaryValueNum = 105 + 25 * Math.sin(trendPhase) + trendDriftP * 6
            alertActive = primaryValueNum < 70 || primaryValueNum > 140
        }
        else if (d === "bp") {
            trendDriftS += (Math.random() - 0.5) * 0.2
            trendDriftS  = Math.max(-2, Math.min(2, trendDriftS))
            if (abnormal) {
                trendDriftS += (Math.random() > 0.5 ? 1 : -1) * 0.6
                trendDriftS  = Math.max(-3, Math.min(3, trendDriftS))
            }
            primaryValueNum   = 120 + 10 * Math.sin(trendPhase)       + trendDriftP * 3
            secondaryValueNum = 78  + 6  * Math.sin(trendPhase + 0.5) + trendDriftS * 2.5
            alertActive = primaryValueNum > 140 || secondaryValueNum > 90
        }

        // Don't advance the waveform while waiting for the first BLE
        // measurement — a flat baseline at the simulated value is misleading.
        pendingDot = !awaitingMeasurement
    }

    // Tapping the X buttons emits this — Main.qml decides whether to also
    // navigate back (e.g. to the BLE Scan page the user launched from).
    signal closeRequested()

    parent: Overlay.overlay
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    padding: 0

    x: 40
    y: 40
    width:  parent ? parent.width  - 80 : 1280
    height: parent ? parent.height - 80 :  640

    background: Rectangle {
        // 溫度模式走 ThermalMonitorLayout 的深藍科技風，白框會在圓角面板
        // 外圍露出一圈刺眼的邊；其他裝置類型維持原本的黑底白框。
        color: root.deviceType === "thermometer" ? "#050b13" : "#0a0a0a"
        border.width: 1
        border.color: root.deviceType === "thermometer" ? "#1c354b" : "#ffffff"
    }

    Overlay.modal: Rectangle { color: "#cc000000" }

    onAboutToShow: {
        trendPhase = 0
        trendDriftP = 0
        trendDriftS = 0
        updateValues()
        if (layoutLoader.item && layoutLoader.item.reset)
            layoutLoader.item.reset()
    }

    Timer {
        interval: 1000
        running: root.visible
        repeat: true
        onTriggered: root.updateValues()
    }

    // Push live BLE notifications onto the waveform immediately rather than
    // waiting for the next 1 Hz tick.
    Connections {
        target: bleScanner
        enabled: root.deviceType === "thermometer" && root.visible
        function onTemperatureReceived(value, unit) {
            // bleScanner reports the same unit the peripheral declared in 2A1C
            // Flags bit 0; the axis (cfg) re-evaluates on lastTemperatureUnit
            // changing, so we just push the raw value through.
            root.primaryValueNum = value
            // No fever / hypothermia gates — see updateValues().
            root.alertActive = false
            root.pendingDot = true
            if (layoutLoader.item && layoutLoader.item.addTemperaturePoint)
                layoutLoader.item.addTemperaturePoint(value)
        }
    }

    // LIVE-blink helper (shared between layouts)
    Item {
        id: liveBlink
        property real currentOpacity: 1.0
        Behavior on currentOpacity { NumberAnimation { duration: 80 } }
        Timer {
            interval: root.alertActive ? 150 : 600
            running: root.visible
            repeat: true
            onTriggered: liveBlink.currentOpacity =
                liveBlink.currentOpacity > 0.5 ? 0.25 : 1.0
        }
    }

    contentItem: Loader {
        id: layoutLoader
        sourceComponent: root.deviceType === "spo2"        ? multiWaveLayout
                       : root.deviceType === "thermometer" ? thermoLayout
                       : trendLayout
    }

    // 溫度版面（更新內容/AM62P_Apollo510B_BLE_Temperature_Monitor.html 的移植）。
    // 整塊實作在 ThermalMonitorLayout.qml；這裡只負責把 Popup 本體傳進去
    // （讀值、單位、Y 軸設定都從 root 來）並將關閉事件轉發出去。
    Component {
        id: thermoLayout
        ThermalMonitorLayout {
            dialog: root
            onCloseRequested: root.closeRequested()
        }
    }

    // ════════════════════════════════════════════════════════════════
    //  (溫度已於 2026-09-13 改走 ThermalMonitorLayout；下面還看得到的
    //   `root.deviceType === "thermometer" ? A : B` 現在一律取 B。保留是為了讓
    //   這次的 diff 只動路由，不撑到血糖與血壓的版面。)
    //  TREND LAYOUT — thermometer / glucose / bp
    // ════════════════════════════════════════════════════════════════
    Component {
        id: trendLayout

        ColumnLayout {
            id: trendRoot
            spacing: 0

            function reset() {
                gridLayer.requestPaint()
                wave.reset()
            }

            function addTemperaturePoint(value) {
                wave.addTemperaturePoint(value)
            }

            // ── Header
            Item {
                Layout.fillWidth: true
                // Thermometer mode shows a 3× value pill — grow the header
                // so the pill doesn't clip into the waveform area below.
                Layout.preferredHeight: root.deviceType === "thermometer" ? 180 : 92

                ColumnLayout {
                    anchors.left: parent.left
                    anchors.leftMargin: 26
                    y: root.deviceType === "thermometer" ? 18 : (parent.height - height) / 2
                    spacing: root.deviceType === "thermometer" ? 8 : 4

                    RowLayout {
                        spacing: root.deviceType === "thermometer" ? 18 : 14
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            text: root.cfg ? root.cfg.title : ""
                            color: "#ffffff"
                            font.pixelSize: root.deviceType === "thermometer" ? 36 : 22
                            font.bold: true
                        }
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredHeight: root.deviceType === "thermometer" ? 42 : 26
                            Layout.preferredWidth: liveRow.implicitWidth + (root.deviceType === "thermometer" ? 26 : 18)
                            color: "#0e2a14"
                            border.color: "#00ff00"
                            border.width: 1
                            radius: 4
                            Row {
                                id: liveRow
                                anchors.centerIn: parent
                                spacing: 6
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.deviceType === "thermometer" ? 14 : 8
                                    height: width
                                    color: "#00ff00"
                                    opacity: liveBlink.currentOpacity
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "LIVE"
                                    color: "#00ff00"
                                    font.pixelSize: root.deviceType === "thermometer" ? 20 : 12
                                    font.bold: true
                                    font.letterSpacing: 1
                                }
                            }
                        }
                    }
                    Text {
                        text: root.cfg ? root.cfg.subtitle : ""
                        color: "#6b7280"
                        font.pixelSize: root.deviceType === "thermometer" ? 20 : 13
                    }
                }

                Text {
                    visible: root.deviceType === "thermometer"
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: 20
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(parent.width - 620, 560)
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: bleScanner.connectedName.length > 0
                          ? bleScanner.connectedName
                          : (bleScanner.connectedAddress.length > 0
                                ? bleScanner.connectedAddress
                                : "(Not connected)")
                    color: bleScanner.connectionState === "streaming" ? "#10b981"
                         : bleScanner.connectedAddress.length > 0 ? "#f59e0b" : "#6b7280"
                    font.pixelSize: 54
                    font.bold: true
                }

                // Right: value pill + close
                RowLayout {
                    anchors.right: parent.right
                    anchors.rightMargin: 26
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12

                    Rectangle {
                        Layout.preferredHeight: root.deviceType === "thermometer" ? 160 : 70
                        Layout.preferredWidth: pillContent.implicitWidth + 28
                        color: "#000000"
                        border.color: "#333333"
                        border.width: 1
                        radius: 6

                        Row {
                            id: pillContent
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            spacing: 14

                            Column {
                                visible: root.cfg && root.cfg.pillSingle ? true : false
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4
                                Text {
                                    text: root.cfg && root.cfg.pillSingle ? root.cfg.pillSingle.label : ""
                                    color: "#9ca3af"
                                    font.pixelSize: root.deviceType === "thermometer" ? 24 : 12
                                    font.bold: root.deviceType === "thermometer"
                                }
                                Row {
                                    spacing: 8
                                    Text {
                                        text: root.primaryDisplay
                                        color: root.alertActive ? "#ff3333"
                                             : (root.cfg && root.cfg.pillSingle ? root.cfg.pillSingle.color : "#fff")
                                        // 3× larger for thermometer (32 → 96)
                                        font.pixelSize: root.deviceType === "thermometer" ? 96 : 32
                                        font.bold: true
                                    }
                                    Text {
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: root.deviceType === "thermometer" ? 14 : 5
                                        text: root.cfg && root.cfg.pillSingle ? root.cfg.pillSingle.unit : ""
                                        color: "#9ca3af"
                                        font.pixelSize: root.deviceType === "thermometer" ? 32 : 14
                                    }
                                }
                            }

                            Row {
                                visible: root.cfg && root.cfg.pillDual ? true : false
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 12
                                Column {
                                    spacing: 4
                                    Text {
                                        text: root.cfg && root.cfg.pillDual ? root.cfg.pillDual.primary.label : ""
                                        color: root.cfg && root.cfg.pillDual ? root.cfg.pillDual.primary.color : "#fff"
                                        font.pixelSize: 12
                                    }
                                    Text {
                                        text: root.primaryDisplay
                                        color: root.alertActive ? "#ff3333"
                                             : (root.cfg && root.cfg.pillDual ? root.cfg.pillDual.primary.color : "#fff")
                                        font.pixelSize: 32
                                        font.bold: true
                                    }
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "/"
                                    color: "#9ca3af"
                                    font.pixelSize: 30
                                }
                                Column {
                                    spacing: 4
                                    Text {
                                        text: root.cfg && root.cfg.pillDual ? root.cfg.pillDual.secondary.label : ""
                                        color: root.cfg && root.cfg.pillDual ? root.cfg.pillDual.secondary.color : "#fff"
                                        font.pixelSize: 12
                                    }
                                    Text {
                                        text: root.secondaryDisplay
                                        color: root.alertActive ? "#ff3333"
                                             : (root.cfg && root.cfg.pillDual ? root.cfg.pillDual.secondary.color : "#fff")
                                        font.pixelSize: 32
                                        font.bold: true
                                    }
                                }
                                Text {
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: 5
                                    text: root.cfg && root.cfg.pillDual ? root.cfg.pillDual.unit : ""
                                    color: "#9ca3af"
                                    font.pixelSize: 14
                                    visible: text !== ""
                                }
                            }

                            Item {
                                anchors.verticalCenter: parent.verticalCenter
                                width: root.deviceType === "thermometer" ? 72 : 36
                                height: width
                                Image {
                                    id: pillIconImg
                                    anchors.fill: parent
                                    source: root.cfg ? root.cfg.pillIcon : ""
                                    sourceSize: Qt.size(root.deviceType === "thermometer" ? 144 : 72,
                                                        root.deviceType === "thermometer" ? 144 : 72)
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true
                                    visible: false
                                }
                                MultiEffect {
                                    anchors.fill: pillIconImg
                                    source: pillIconImg
                                    colorization: 1.0
                                    colorizationColor: root.pillAccent
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.preferredWidth: 44
                        Layout.preferredHeight: 44
                        radius: 6
                        color: closeHoverT.hovered ? "#1a1a1a" : "transparent"
                        border.width: 1
                        border.color: "#333333"
                        HoverHandler { id: closeHoverT; cursorShape: Qt.PointingHandCursor }
                        Text { anchors.centerIn: parent; text: "X"; color: "#ffffff"; font.pixelSize: 18 }
                        TapHandler { onTapped: root.closeRequested() }
                    }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: "#333333"
                }
            }

            // ── Body: Y-axis labels + chart area
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Item {
                    id: yAxisCol
                    Layout.preferredWidth: root.deviceType === "thermometer" ? 110 : 70
                    Layout.fillHeight: true
                    Repeater {
                        model: root.cfg ? root.cfg.ticks : []
                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: root.deviceType === "thermometer" ? 16 : 10
                            y: root.valueToY(modelData.value, yAxisCol.height) - height / 2
                            text: modelData.label
                            color: modelData.color
                            font.pixelSize: root.deviceType === "thermometer" ? 24 : 12
                            font.bold: true
                        }
                    }
                }

                Item {
                    id: chartArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    // Vendor-1524 HUD: 60 s countdown (started by 0x54 on UUID 1524)
                    // plus an abnormal-reading flash (raised by 0xec). Floats
                    // above the trace, only shown for that meter class.
                    Item {
                        id: vendor1524Hud
                        z: 10
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.topMargin: 6
                        width: 280
                        height: 70
                        // 哪些裝置算 vendor-1524 由 device-profiles.json 決定，
                        // C++ 端算好後用 property 暴露出來，版面不需要知道機型。
                        visible: root.deviceType === "thermometer" && bleScanner.vendor1524Device

                        property int remaining: 0
                        property bool abnormal: false

                        Timer {
                            id: vendor1524CountdownTimer
                            interval: 1000
                            repeat: true
                            onTriggered: {
                                if (vendor1524Hud.remaining > 0) vendor1524Hud.remaining -= 1
                                if (vendor1524Hud.remaining <= 0) stop()
                            }
                        }
                        Timer {
                            id: vendor1524AbnormalTimer
                            interval: 6000
                            repeat: false
                            onTriggered: vendor1524Hud.abnormal = false
                        }

                        Connections {
                            target: bleScanner
                            function onVendor1524MeasurementStarted() {
                                vendor1524Hud.remaining = 60
                                vendor1524Hud.abnormal = false
                                vendor1524CountdownTimer.restart()
                            }
                            function onVendor1524MeasurementAbnormal() {
                                vendor1524Hud.abnormal = true
                                vendor1524CountdownTimer.stop()
                                vendor1524Hud.remaining = 0
                                vendor1524AbnormalTimer.restart()
                            }
                            function onVendor1524MeasurementComplete() {
                                vendor1524CountdownTimer.stop()
                                vendor1524Hud.remaining = 0
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: "#0a1f2e"
                            border.color: vendor1524Hud.abnormal ? "#ef4444" : "#22d3ee"
                            border.width: 2
                            opacity: 0.92
                        }
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 14
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                    text: vendor1524Hud.abnormal ? "Abnormal temperature"
                                    : (vendor1524Hud.remaining > 0 ? "Measuring" : "Sensor standby")
                                color: vendor1524Hud.abnormal ? "#fca5a5" : "#67e8f9"
                                font.pixelSize: 18
                                font.bold: true
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: vendor1524Hud.remaining > 0
                                      ? vendor1524Hud.remaining + " s"
                                      : (vendor1524Hud.abnormal ? "ERR" : "--")
                                color: vendor1524Hud.abnormal ? "#fca5a5" : "#22d3ee"
                                font.pixelSize: 32
                                font.bold: true
                                font.family: "monospace"
                            }
                        }
                    }

                    Canvas {
                        id: gridLayer
                        anchors.fill: parent
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        onAvailableChanged: if (available) requestPaint()
                        onPaint: {
                            if (!available || width <= 0 || height <= 0) return
                            var ctx = getContext("2d")
                            if (!ctx) return
                            ctx.fillStyle = "#0a0a0a"
                            ctx.fillRect(0, 0, width, height)
                            ctx.strokeStyle = "#1f2937"
                            ctx.lineWidth = 1
                            var s = 40
                            for (var x = s; x < width; x += s) {
                                ctx.beginPath(); ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, height); ctx.stroke()
                            }
                            for (var y = s; y < height; y += s) {
                                ctx.beginPath(); ctx.moveTo(0, y + 0.5); ctx.lineTo(width, y + 0.5); ctx.stroke()
                            }
                            if (root.cfg && root.cfg.warningLines) {
                                ctx.setLineDash([8, 6]); ctx.lineWidth = 1
                                for (var i = 0; i < root.cfg.warningLines.length; i++) {
                                    var wl = root.cfg.warningLines[i]
                                    var ly = Math.round(root.valueToY(wl.value, height)) + 0.5
                                    ctx.strokeStyle = wl.color
                                    ctx.beginPath(); ctx.moveTo(0, ly); ctx.lineTo(width, ly); ctx.stroke()
                                }
                                ctx.setLineDash([])
                            }
                        }
                    }

                    Canvas {
                        id: wave
                        anchors.fill: parent
                        property real scanX: 0
                        property real lastX: -1
                        property real lastY1: -1
                        property real lastY2: -1
                        property real blankWidth: 18
                        property real thermometerStepPx: 42

                        onPaint: {
                            if (width <= 0 || height <= 0 || !root.cfg) return
                            var ctx = getContext("2d")
                            if (!ctx) return
                            if (root.deviceType === "thermometer") {
                                paintThermometerTrace(ctx)
                                return
                            }
                            ctx.clearRect(scanX, 0, blankWidth, height)
                            var newY1 = root.valueToY(root.primaryValueNum, height) + (Math.random() - 0.5) * 1.2
                            var hasSec = root.cfg.traces && root.cfg.traces.length > 1
                            var newY2 = hasSec ? root.valueToY(root.secondaryValueNum, height) + (Math.random() - 0.5) * 1.2 : -1
                            if (lastX >= 0 && scanX > lastX) {
                                ctx.beginPath(); ctx.strokeStyle = root.cfg.traces[0].color
                                ctx.lineWidth = 2; ctx.lineCap = "butt"
                                ctx.moveTo(lastX, lastY1); ctx.lineTo(scanX, newY1); ctx.stroke()
                                if (hasSec && lastY2 >= 0) {
                                    ctx.beginPath(); ctx.strokeStyle = root.cfg.traces[1].color
                                    ctx.moveTo(lastX, lastY2); ctx.lineTo(scanX, newY2); ctx.stroke()
                                }
                            }
                            if (root.pendingDot && lastX >= 0) {
                                ctx.beginPath(); ctx.fillStyle = root.cfg.traces[0].color
                                ctx.arc(scanX, newY1, 3.5, 0, 2 * Math.PI); ctx.fill()
                                if (hasSec) {
                                    ctx.beginPath(); ctx.fillStyle = root.cfg.traces[1].color
                                    ctx.arc(scanX, newY2, 3.5, 0, 2 * Math.PI); ctx.fill()
                                }
                                root.pendingDot = false
                            }
                            lastX = scanX; lastY1 = newY1; lastY2 = newY2
                        }

                        onWidthChanged: reset()
                        onHeightChanged: reset()
                        onAvailableChanged: if (available) reset()

                        function reset() {
                            scanX = 0; lastX = -1; lastY1 = -1; lastY2 = -1
                            if (!available || width <= 0 || height <= 0) return
                            var ctx = getContext("2d")
                            if (!ctx) return
                            ctx.clearRect(0, 0, width, height)
                            if (root.deviceType === "thermometer") {
                                root.temperatureSamples = []
                                root.temperatureSampleTick++
                                requestPaint()
                                return
                            }
                            if (root.cfg) {
                                var y1 = root.valueToY(root.primaryValueNum, height)
                                ctx.strokeStyle = root.cfg.traces[0].color
                                ctx.lineWidth = 2
                                ctx.beginPath(); ctx.moveTo(0, y1); ctx.lineTo(width, y1); ctx.stroke()
                                if (root.cfg.traces.length > 1) {
                                    var y2 = root.valueToY(root.secondaryValueNum, height)
                                    ctx.strokeStyle = root.cfg.traces[1].color
                                    ctx.beginPath(); ctx.moveTo(0, y2); ctx.lineTo(width, y2); ctx.stroke()
                                }
                            }
                        }

                        function step() {
                            if (width <= 0 || height <= 0) return
                            if (root.deviceType === "thermometer") return
                            scanX += 0.5
                            if (scanX >= width) { scanX = 0; lastX = -1; lastY1 = -1; lastY2 = -1 }
                            requestPaint()
                        }

                        function addTemperaturePoint(value) {
                            if (root.deviceType !== "thermometer") return
                            var samples = root.temperatureSamples.slice()
                            samples.push(value)
                            var maxPoints = Math.max(2, Math.floor(width / thermometerStepPx) + 1)
                            while (samples.length > maxPoints)
                                samples.shift()
                            root.temperatureSamples = samples
                            root.temperatureSampleTick++
                            requestPaint()
                        }

                        function paintThermometerTrace(ctx) {
                            ctx.clearRect(0, 0, width, height)
                            var samples = root.temperatureSamples
                            if (!samples || samples.length === 0)
                                return

                            var step = thermometerStepPx
                            var startX = 22
                            var maxVisibleWidth = Math.max(1, width - startX - 22)
                            if ((samples.length - 1) * step > maxVisibleWidth)
                                step = maxVisibleWidth / Math.max(1, samples.length - 1)

                            ctx.strokeStyle = root.cfg.traces[0].color
                            ctx.fillStyle = root.cfg.traces[0].color
                            ctx.lineWidth = 4
                            ctx.lineJoin = "round"
                            ctx.lineCap = "round"

                            if (samples.length > 1) {
                                ctx.beginPath()
                                for (var i = 0; i < samples.length; i++) {
                                    var x = startX + i * step
                                    var y = root.valueToY(samples[i], height)
                                    if (i === 0) ctx.moveTo(x, y)
                                    else ctx.lineTo(x, y)
                                }
                                ctx.stroke()
                            }

                            for (var j = 0; j < samples.length; j++) {
                                var px = startX + j * step
                                var py = root.valueToY(samples[j], height)
                                ctx.beginPath()
                                ctx.arc(px, py, 4.5, 0, 2 * Math.PI)
                                ctx.fill()
                            }
                        }
                    }

                    Timer {
                        interval: 33
                        running: root.visible && root.deviceType !== "thermometer"
                        repeat: true
                        onTriggered: wave.step()
                    }

                    Repeater {
                        model: root.cfg ? root.cfg.warningLines : []
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 16
                            y: root.valueToY(modelData.value, chartArea.height) - height - 3
                            text: modelData.label
                            color: modelData.color
                            font.pixelSize: 11
                            font.family: "monospace"
                        }
                    }
                }
            }

            // Footer
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 28
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 86
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Scan start"; color: "#9ca3af"; font.pixelSize: 11
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.deviceType === "thermometer" ? "Time (per measurement / point)" : "Time (1 s / point)"
                    color: "#9ca3af"; font.pixelSize: 11
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 30
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Scan end"; color: "#9ca3af"; font.pixelSize: 11
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════
    //  MULTI-WAVEFORM LAYOUT — SpO2 (ECG + PPG + Respiration + cards)
    // ════════════════════════════════════════════════════════════════
    Component {
        id: multiWaveLayout

        Item {
            id: mwRoot

            function reset() {
                ecgPanel.reset()
                ppgPanel.reset()
                respPanel.reset()
            }

            // Close button (floating top-right)
            Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 14
                anchors.rightMargin: 14
                z: 100
                width: 44; height: 44
                radius: 6
                color: closeHoverM.hovered ? "#1a1a1a" : "transparent"
                border.width: 1
                border.color: "#333333"
                HoverHandler { id: closeHoverM; cursorShape: Qt.PointingHandCursor }
                Text { anchors.centerIn: parent; text: "X"; color: "#ffffff"; font.pixelSize: 18 }
                TapHandler { onTapped: root.close() }
            }

            // ── RIGHT COLUMN — fixed 240 px, anchored to right edge
            Item {
                id: rightCol
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.topMargin: 16
                anchors.bottomMargin: 16
                anchors.rightMargin: 70   // leave room for floating close button
                width: 240

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 10

                    VitalSignCard {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 122
                        Layout.maximumHeight: 130
                        name: "Heart Rate"
                        unit: "bpm"
                        valueText: Math.round(root.hrValue).toString()
                        accentColor: "#00ff00"
                        iconSource: "qrc:/assets/icons/heart.svg"
                        minVal: 60; maxVal: 100
                        currentVal: root.hrValue
                    }
                    VitalSignCard {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 122
                        Layout.maximumHeight: 130
                        name: "SpO2"
                        unit: "%"
                        valueText: Math.round(root.spo2Value).toString()
                        accentColor: "#00ccff"
                        iconSource: "qrc:/assets/icons/droplet.svg"
                        minVal: 90; maxVal: 100
                        currentVal: root.spo2Value
                    }
                    VitalSignCard {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 122
                        Layout.maximumHeight: 130
                        name: "Respiration"
                        unit: "rpm"
                        valueText: Math.round(root.rrValue).toString()
                        accentColor: "#ffcc00"
                        iconSource: "qrc:/assets/icons/lungs.svg"
                        minVal: 8; maxVal: 20
                        currentVal: root.rrValue
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 84
                        Layout.maximumHeight: 94
                        spacing: 10

                        VitalSignCard {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            name: "PR"
                            unit: "bpm"
                            valueText: Math.round(root.prValue).toString()
                            accentColor: "#00ccff"
                            showRangeBar: false
                            valuePixelSize: 32
                        }
                        VitalSignCard {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            name: "PI"
                            unit: ""
                            valueText: root.piValue.toFixed(2)
                            accentColor: "#00ccff"
                            showRangeBar: false
                            valuePixelSize: 32
                        }
                    }

                    // Absorb any vertical leftover so cards keep their preferred sizes
                    Item { Layout.fillHeight: true }
                }
            }

            // ── LEFT SIDE — fills remaining space between left edge and rightCol
            Item {
                anchors.left: parent.left
                anchors.right: rightCol.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: 16
                anchors.rightMargin: 14
                anchors.topMargin: 16
                anchors.bottomMargin: 16

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 10

                    WaveformPanel {
                        id: ecgPanel
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        title: "ECG II"
                        subtitle: "25 mm/s    10 mm/mV"
                        rightLabel: "HR Source: ECG ♥"
                        titleColor: "#00ff00"
                        waveColor: "#00ff00"
                        timeWindowSec: 10
                        sampleFunc: function(t) {
                            var period = 60.0 / Math.max(20, root.hrValue)
                            return root.ecgShape((t % period) / period)
                        }
                    }
                    WaveformPanel {
                        id: ppgPanel
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        waveColor: "#00ccff"
                        timeWindowSec: 10
                        showTimeAxis: true
                        timeAxisTickInterval: 1
                        sampleFunc: function(t) {
                            var period = 60.0 / Math.max(20, root.hrValue)
                            return root.ppgShape((t % period) / period)
                        }
                    }
                    WaveformPanel {
                        id: respPanel
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        waveColor: "#ffcc00"
                        timeWindowSec: 60
                        showTimeAxis: true
                        timeAxisTickInterval: 10
                        sampleFunc: function(t) {
                            var period = 60.0 / Math.max(4, root.rrValue)
                            return Math.sin((t / period) * 2 * Math.PI)
                        }
                    }
                }
            }

            // Shared 30fps tick driving the three waveform canvases
            Timer {
                interval: 33
                running: root.visible
                repeat: true
                onTriggered: {
                    ecgPanel.tick(0.033)
                    ppgPanel.tick(0.033)
                    respPanel.tick(0.033)
                }
            }
        }
    }
}
