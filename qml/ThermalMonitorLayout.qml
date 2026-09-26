import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ════════════════════════════════════════════════════════════════════════════
//  THERMAL MONITOR — BLE 溫度連線畫面
//
//  版面依 更新內容/AM62P_Apollo510B_BLE_Temperature_Monitor.html 的範例移植：
//  左側大曲線面板（讀值 + 趨勢 + 狀態環），右側統計與 BLE 連線卡，底部時間
//  範圍分段與暫停鍵。裝置名稱放在最上方，與舊版面相同。
//
//  只有 deviceType === "thermometer" 走這個版面；SpO2 的 multiWaveLayout 與
//  血糖／血壓的 trendLayout 都沒有動。
//
//  與 HTML 範例的差異，都是為了不在畫面上放假資料：
//    * 範例的 RSSI（−48 dBm）拿掉了 —— BleScanner 不提供 RSSI，bluetoothctl
//      的 [CHG] RSSI 沒有被解析成 property，寫死一個數字只會誤導。
//    * 範例的「QUALITY 96%」狀態環改成緩衝區填充度：環的進度是目前視窗已收
//      到的樣本數 ÷ 視窗秒數，中央顯示真實的連線狀態。兩者都是實際可查的值。
//    * 範例的三段時間是 即時／近 1 分鐘／近 5 分鐘，但前兩者在 1 Hz 下幾乎
//      等長。這裡改成 30 秒／1 分鐘／5 分鐘，三段才真的有區別。
// ════════════════════════════════════════════════════════════════════════════
Rectangle {
    id: monitor

    // VitalSignsMonitorDialog（Popup）本體。讀值、單位、Y 軸設定都從它來。
    property var dialog: null
    signal closeRequested()

    // ── 調色盤（對應 HTML 的 :root 變數）
    readonly property color cBg:     "#050b13"
    readonly property color cPanel:  "#091523"
    readonly property color cLine:   "#1c354b"
    readonly property color cCyan:   "#45e9ff"
    readonly property color cBlue:   "#357cff"
    readonly property color cText:   "#eefaff"
    readonly property color cMuted:  "#7f9bb2"
    readonly property color cGreen:  "#54f3b1"

    // ── 樣本緩衝
    // 1 Hz × 5 分鐘 = 300 筆，足夠餵滿最長的視窗；再多就從頭丟棄。
    readonly property int maxSamples: 300
    property var samples: []
    property string range: "live"    // live | 1m | 5m

    readonly property int windowSeconds: range === "5m" ? 300
                                       : range === "1m" ? 60
                                       : 30

    // 目前視窗要畫的那一段
    readonly property var view: {
        var n = Math.min(samples.length, windowSeconds)
        return n > 0 ? samples.slice(samples.length - n) : []
    }

    readonly property var cfg: dialog ? dialog.cfg : null
    readonly property real yMin: cfg ? cfg.yMin : 15.0
    readonly property real yMax: cfg ? cfg.yMax : 35.0
    readonly property string unitText: (dialog && dialog.tempUnit === "F") ? "°F" : "°C"

    readonly property real avgValue: {
        if (view.length === 0) return NaN
        var s = 0
        for (var i = 0; i < view.length; i++) s += view[i]
        return s / view.length
    }
    readonly property real maxValue: view.length > 0 ? Math.max.apply(null, view) : NaN
    readonly property real minValue: view.length > 0 ? Math.min.apply(null, view) : NaN
    readonly property real deltaValue:
        view.length >= 2 ? view[view.length - 1] - view[view.length - 2] : NaN

    readonly property string deviceName:
        bleScanner.connectedName.length > 0
        ? bleScanner.connectedName
        : (bleScanner.connectedAddress.length > 0 ? bleScanner.connectedAddress
                                                  : "(Not connected)")
    readonly property bool linkLive: bleScanner.connectionState === "streaming" ||
                                     bleScanner.connectionState === "connected"

    color: cBg

    // ── 外部（VitalSignsMonitorDialog）呼叫的兩個入口 ────────────────────────
    function reset() {
        samples = []
        traceLayer.requestPaint()
    }

    function addTemperaturePoint(value) {
        var s = samples.slice()
        s.push(value)
        while (s.length > maxSamples) s.shift()
        samples = s
        traceLayer.requestPaint()
    }

    // 新樣本只重畫曲線層；格線／刻度／時間軸只有在 Y 軸設定或視窗長度
    // 變動時才需要重來一次。
    onViewChanged: traceLayer.requestPaint()
    onCfgChanged: { gridLayer.requestPaint(); traceLayer.requestPaint() }
    onWindowSecondsChanged: { gridLayer.requestPaint(); traceLayer.requestPaint() }

    function fmt(v) { return isNaN(v) ? "--.--" : (Math.floor(v * 100) / 100).toFixed(2) }
    function barFrac(v) {
        if (isNaN(v) || yMax <= yMin) return 0
        return Math.max(0, Math.min(1, (v - yMin) / (yMax - yMin)))
    }

    // 背景的科技感網格 —— 對應 HTML 的 .shell:before
    Canvas {
        anchors.fill: parent
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            if (!available || width <= 0 || height <= 0) return
            var ctx = getContext("2d")
            if (!ctx) return
            ctx.clearRect(0, 0, width, height)
            ctx.lineWidth = 1
            var step = 42
            // 上淡下無：HTML 用 mask-image 做，這裡直接按高度收斂透明度。
            for (var y = step; y < height; y += step) {
                ctx.strokeStyle = Qt.rgba(0.27, 0.91, 1.0,
                                          0.07 * 0.18 * Math.max(0, 1 - y / (height * 0.72)))
                ctx.beginPath(); ctx.moveTo(0, y + 0.5); ctx.lineTo(width, y + 0.5); ctx.stroke()
            }
            for (var x = step; x < width; x += step) {
                ctx.strokeStyle = Qt.rgba(0.27, 0.91, 1.0, 0.05 * 0.18)
                ctx.beginPath(); ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, height * 0.72); ctx.stroke()
            }
        }
    }

    // LIVE 指示燈的呼吸效果
    Item {
        id: liveBlink
        property real currentOpacity: 1.0
        Behavior on currentOpacity { NumberAnimation { duration: 220 } }
        Timer {
            interval: 900
            running: monitor.visible
            repeat: true
            onTriggered: liveBlink.currentOpacity =
                liveBlink.currentOpacity > 0.6 ? 0.35 : 1.0
        }
    }

    property string clockText: Qt.formatTime(new Date(), "HH:mm:ss")
    Timer {
        interval: 1000
        running: monitor.visible
        repeat: true
        onTriggered: monitor.clockText = Qt.formatTime(new Date(), "HH:mm:ss")
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 22
        spacing: 16

        // ═══ HEADER ═════════════════════════════════════════════════════════
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 68
            spacing: 14

            Rectangle {
                Layout.preferredWidth: 52
                Layout.preferredHeight: 52
                radius: 15
                color: "#0d2c40"
                border.color: "#2e7795"
                border.width: 1
                Canvas {
                    anchors.centerIn: parent
                    width: 30; height: 30
                    onPaint: {
                        var ctx = getContext("2d")
                        if (!ctx) return
                        ctx.clearRect(0, 0, width, height)
                        ctx.strokeStyle = monitor.cCyan
                        ctx.lineWidth = 2.4
                        ctx.lineJoin = "round"
                        ctx.lineCap = "round"
                        ctx.beginPath()
                        ctx.moveTo(2, 18); ctx.lineTo(8, 18); ctx.lineTo(11, 9)
                        ctx.lineTo(16, 25); ctx.lineTo(20, 14); ctx.lineTo(23, 18)
                        ctx.lineTo(28, 18)
                        ctx.stroke()
                    }
                }
            }

            ColumnLayout {
                spacing: 2
                // 裝置名稱 —— 與舊版面一樣放在最上方。
                Text {
                    text: monitor.deviceName
                    color: monitor.linkLive ? monitor.cText : "#89a6ba"
                    font.pixelSize: 30
                    font.bold: true
                    font.letterSpacing: 0.5
                    elide: Text.ElideRight
                    Layout.maximumWidth: 520
                }
                Text {
                    text: "AM62P · REAL-TIME SENSOR ARRAY"
                    color: monitor.cMuted
                    font.pixelSize: 13
                    font.letterSpacing: 1.6
                }
            }

            Item { Layout.fillWidth: true }

            Rectangle {
                Layout.preferredWidth: 11
                Layout.preferredHeight: 11
                radius: 6
                color: monitor.cGreen
                opacity: liveBlink.currentOpacity
            }
            Text {
                text: monitor.linkLive ? "即時資料串流" : "等待 BLE 連線"
                color: "#b9d0df"
                font.pixelSize: 16
            }
            Rectangle {
                Layout.preferredWidth: 1
                Layout.preferredHeight: 26
                color: "#244057"
            }
            Text {
                text: monitor.clockText
                color: monitor.cText
                font.pixelSize: 20
                font.family: "monospace"
            }

            Rectangle {
                Layout.preferredWidth: 46
                Layout.preferredHeight: 46
                radius: 12
                color: closeHover.hovered ? "#123449" : "#0c2233"
                border.color: "#28516a"
                border.width: 1
                HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: monitor.closeRequested() }
                Text {
                    anchors.centerIn: parent
                    text: "←"
                    color: "#bfefff"
                    font.pixelSize: 26
                    font.bold: true
                }
            }
        }

        // ═══ MAIN ═══════════════════════════════════════════════════════════
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 16

            // ── 曲線面板 ────────────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                // Rectangle 沒有 implicitWidth，在 layout 眼中「想要的寬度」是 0。
                // 給一個下限，寬度不足時寧可讓右欄縮，也不要把曲線壓不見。
                Layout.minimumWidth: 380
                radius: 22
                color: monitor.cPanel
                border.color: monitor.cLine
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 12

                    // 讀值靠右，放在原本狀態環的位置。
                    //
                    // 狀態環一起移除了：環中央寫的是連線狀態（「串流中」），而
                    // header 右上角已經有綠點 +「即時資料串流」在講同一件事；
                    // 環外圈的 BUFFER % 是緩衝填充度，對操作沒有影響。同一個
                    // 資訊在一個畫面上出現兩次，不如把位置讓給真正要看的數字。
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 18

                        Item { Layout.fillWidth: true }

                        ColumnLayout {
                            Layout.alignment: Qt.AlignRight | Qt.AlignTop
                            spacing: 4

                            Text {
                                Layout.alignment: Qt.AlignRight
                                text: "TEMPERATURE"
                                color: "#7fa7bd"
                                font.pixelSize: 13
                                font.letterSpacing: 2
                            }
                            RowLayout {
                                Layout.alignment: Qt.AlignRight
                                spacing: 10
                                Text {
                                    text: dialog ? dialog.primaryDisplay : "--.--"
                                    color: monitor.cText
                                    font.pixelSize: 76
                                    font.weight: Font.Light
                                    font.letterSpacing: -2
                                }
                                Text {
                                    Layout.alignment: Qt.AlignBottom
                                    Layout.bottomMargin: 14
                                    text: monitor.unitText
                                    color: monitor.cCyan
                                    font.pixelSize: 28
                                    font.bold: true
                                }
                            }
                            Text {
                                Layout.alignment: Qt.AlignRight
                                horizontalAlignment: Text.AlignRight
                                text: {
                                    var d = monitor.deltaValue
                                    var trend = isNaN(d)
                                        ? "--"
                                        : (d >= 0 ? "↗ +" : "↘ ") + d.toFixed(2) + " " + monitor.unitText
                                    return "趨勢 " + trend + "　·　更新週期 1 s"
                                }
                                color: "#9bb5c6"
                                font.pixelSize: 15
                            }
                        }
                    }

                    // 曲線區。拆成兩層 Canvas 是為了更新延遲：靜態的格線／刻度／
                    // 基準線／時間軸只在尺寸、Y 軸設定或視窗長度變動時重畫，每秒
                    // 進來的新樣本只重畫上面那層曲線。
                    //
                    // 為什麼要在意：Canvas 的預設 renderTarget 是 Image，也就是
                    // CPU raster。原本一層畫到底、而且描邊與端點都帶 shadowBlur，
                    // 光是 blur 就要對整張 canvas 做多次卷積，在 A53 上每次重繪
                    // 數百 ms —— 實機回報「溫度更新慢 2~3 秒」就是這個
                    // （2026-09-13）。輝光改用多道由粗到細的半透明描邊疊出來，
                    // 視覺接近而成本只跟點數有關。
                    Item {
                        id: chartArea
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: 200

                        readonly property int padL: 58
                        readonly property int padR: 14
                        readonly property int padT: 16
                        readonly property int padB: 30
                        readonly property real cw: Math.max(0, width - padL - padR)
                        readonly property real ch: Math.max(0, height - padT - padB)
                        readonly property real span: monitor.yMax - monitor.yMin
                        readonly property bool drawable: cw > 0 && ch > 0 && span > 0

                        function yOf(v) {
                            var r = Math.max(0, Math.min(1, (v - monitor.yMin) / span))
                            return padT + (1 - r) * ch
                        }
                        // 橫向座標按「視窗秒數」換算而不是按點數平均，所以資料還
                        // 沒填滿視窗時曲線是從右邊往左長，不會被拉伸鋪滿。
                        function xOf(idx, n) {
                            var win = monitor.windowSeconds
                            var r = 1 - (n - 1 - idx) / Math.max(1, win - 1)
                            return padL + Math.max(0, Math.min(1, r)) * cw
                        }

                        // ── 靜態層 ─────────────────────────────────────────
                        Canvas {
                            id: gridLayer
                            anchors.fill: parent
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onAvailableChanged: if (available) requestPaint()

                            onPaint: {
                                if (!available || !chartArea.drawable) return
                                var ctx = getContext("2d")
                                if (!ctx) return
                                ctx.clearRect(0, 0, width, height)

                                var padL = chartArea.padL, padR = chartArea.padR
                                var padB = chartArea.padB, cw = chartArea.cw

                                // Y 軸刻度與虛線格線。刻度沿用 cfg.ticks，也就是
                                // 15/20/25/30/35（華氏 59…95），連顏色都照它走 ——
                                // 25.0 那格是綠的。
                                var ticks = monitor.cfg && monitor.cfg.ticks ? monitor.cfg.ticks : []
                                ctx.font = "13px monospace"
                                ctx.textAlign = "right"
                                ctx.textBaseline = "middle"
                                for (var i = 0; i < ticks.length; i++) {
                                    var t = ticks[i]
                                    var y = Math.round(chartArea.yOf(t.value)) + 0.5
                                    ctx.strokeStyle = "rgba(75,134,166,.18)"
                                    ctx.lineWidth = 1
                                    ctx.setLineDash([3, 6])
                                    ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(width - padR, y); ctx.stroke()
                                    ctx.setLineDash([])
                                    ctx.fillStyle = t.color
                                    ctx.fillText(t.label, padL - 12, y)
                                }

                                // 基準線（25.0°C / 77.0°F）畫實線，壓在格線之上
                                var wls = monitor.cfg && monitor.cfg.warningLines
                                          ? monitor.cfg.warningLines : []
                                for (var k = 0; k < wls.length; k++) {
                                    var wy = Math.round(chartArea.yOf(wls[k].value)) + 0.5
                                    ctx.strokeStyle = wls[k].color
                                    ctx.globalAlpha = 0.55
                                    ctx.lineWidth = 1
                                    ctx.beginPath(); ctx.moveTo(padL, wy); ctx.lineTo(width - padR, wy); ctx.stroke()
                                    ctx.globalAlpha = 1
                                }

                                // 時間軸（右端為現在）
                                ctx.textAlign = "center"
                                ctx.textBaseline = "top"
                                ctx.fillStyle = "#58788f"
                                ctx.font = "12px monospace"
                                var win = monitor.windowSeconds
                                for (var g = 0; g <= 4; g++) {
                                    var gx = padL + cw * g / 4
                                    var secsAgo = Math.round(win * (1 - g / 4))
                                    ctx.fillText(secsAgo === 0 ? "now" : "-" + secsAgo + "s",
                                                 gx, height - padB + 8)
                                }
                            }
                        }

                        // ── 動態層（每秒只重畫這層）────────────────────────
                        Canvas {
                            id: traceLayer
                            anchors.fill: parent
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onAvailableChanged: if (available) requestPaint()

                            onPaint: {
                                if (!available || !chartArea.drawable) return
                                var ctx = getContext("2d")
                                if (!ctx) return
                                ctx.clearRect(0, 0, width, height)

                                var padL = chartArea.padL, padT = chartArea.padT
                                var cw = chartArea.cw, ch = chartArea.ch
                                var pts = monitor.view

                                if (pts.length === 0) {
                                    ctx.textAlign = "center"
                                    ctx.textBaseline = "middle"
                                    ctx.fillStyle = "#4d6b80"
                                    ctx.font = "16px sans-serif"
                                    ctx.fillText(monitor.linkLive
                                                 ? "等待第一筆溫度 indication…"
                                                 : "尚未連線",
                                                 padL + cw / 2, padT + ch / 2)
                                    return
                                }

                                var n = pts.length
                                function X(i) { return chartArea.xOf(i, n) }
                                function Y(i) { return chartArea.yOf(pts[i]) }

                                // 漸層填充
                                var grad = ctx.createLinearGradient(0, padT, 0, padT + ch)
                                grad.addColorStop(0, "rgba(43,224,255,.26)")
                                grad.addColorStop(1, "rgba(23,109,255,0)")
                                ctx.beginPath()
                                ctx.moveTo(X(0), padT + ch)
                                for (var a = 0; a < n; a++) ctx.lineTo(X(a), Y(a))
                                ctx.lineTo(X(n - 1), padT + ch)
                                ctx.closePath()
                                ctx.fillStyle = grad
                                ctx.fill()

                                // 曲線：四道由粗到細的描邊疊出輝光，取代 shadowBlur。
                                // 描邊成本只跟點數有關（最多 300 點），blur 是跟
                                // 畫布面積有關 —— 差距就是這次那 2~3 秒。
                                function tracePath() {
                                    ctx.beginPath()
                                    for (var b = 0; b < n; b++) {
                                        if (b === 0) ctx.moveTo(X(b), Y(b))
                                        else ctx.lineTo(X(b), Y(b))
                                    }
                                }
                                ctx.lineJoin = "round"
                                ctx.lineCap = "round"
                                tracePath(); ctx.strokeStyle = "rgba(66,233,255,0.16)"; ctx.lineWidth = 9;   ctx.stroke()
                                tracePath(); ctx.strokeStyle = "rgba(66,233,255,0.40)"; ctx.lineWidth = 5;   ctx.stroke()
                                tracePath(); ctx.strokeStyle = "#42e9ff";               ctx.lineWidth = 2.5; ctx.stroke()
                                tracePath(); ctx.strokeStyle = "#adf8ff";               ctx.lineWidth = 1;   ctx.stroke()

                                // 末端光點：同樣用三個同心圓取代 shadowBlur
                                var lx = X(n - 1), ly = Y(n - 1)
                                ctx.beginPath(); ctx.arc(lx, ly, 9, 0, 2 * Math.PI)
                                ctx.fillStyle = "rgba(69,233,255,0.18)"; ctx.fill()
                                ctx.beginPath(); ctx.arc(lx, ly, 6, 0, 2 * Math.PI)
                                ctx.fillStyle = "rgba(69,233,255,0.42)"; ctx.fill()
                                ctx.beginPath(); ctx.arc(lx, ly, 4, 0, 2 * Math.PI)
                                ctx.fillStyle = "#d8fdff"; ctx.fill()
                            }
                        }

                        // Vendor-1524 HUD — 該類體溫計 1524 狀態機的 60 秒倒數與異常旗標。
                        // 原本長在 trendLayout，溫度改走本版面後一併搬過來 —— 不搬的話
                        // 這類機一接上就再也看不到倒數。只有該類體溫計會顯示。
                        Item {
                            id: vendor1524Hud
                            z: 10
                            anchors.top: parent.top
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.topMargin: 6
                            width: 300
                            height: 62
                            // 由 device-profiles.json 決定，見 BleScanner::isVendor1524Device()
                            visible: bleScanner.vendor1524Device

                            property int remaining: 0
                            property bool abnormal: false

                            Timer {
                                id: vendor1524Countdown
                                interval: 1000
                                repeat: true
                                onTriggered: {
                                    if (vendor1524Hud.remaining > 0) vendor1524Hud.remaining -= 1
                                    if (vendor1524Hud.remaining <= 0) stop()
                                }
                            }
                            Timer {
                                id: vendor1524AbnormalReset
                                interval: 6000
                                onTriggered: vendor1524Hud.abnormal = false
                            }

                            Connections {
                                target: bleScanner
                                function onVendor1524MeasurementStarted() {
                                    vendor1524Hud.remaining = 60
                                    vendor1524Hud.abnormal = false
                                    vendor1524Countdown.restart()
                                }
                                function onVendor1524MeasurementAbnormal() {
                                    vendor1524Hud.abnormal = true
                                    vendor1524Countdown.stop()
                                    vendor1524Hud.remaining = 0
                                    vendor1524AbnormalReset.restart()
                                }
                                function onVendor1524MeasurementComplete() {
                                    vendor1524Countdown.stop()
                                    vendor1524Hud.remaining = 0
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: 12
                                color: "#0a1f2e"
                                opacity: 0.94
                                border.width: 1
                                border.color: vendor1524Hud.abnormal ? "#ef4444" : monitor.cCyan
                            }
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 16
                                anchors.rightMargin: 16
                                spacing: 12
                                Text {
                                    text: vendor1524Hud.abnormal ? "Abnormal temperature"
                                        : (vendor1524Hud.remaining > 0 ? "Measuring" : "Sensor standby")
                                    color: vendor1524Hud.abnormal ? "#fca5a5" : "#67e8f9"
                                    font.pixelSize: 16
                                    font.bold: true
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: vendor1524Hud.remaining > 0 ? vendor1524Hud.remaining + " s"
                                        : (vendor1524Hud.abnormal ? "ERR" : "--")
                                    color: vendor1524Hud.abnormal ? "#fca5a5" : monitor.cCyan
                                    font.pixelSize: 26
                                    font.bold: true
                                    font.family: "monospace"
                                }
                            }
                        }
                    }
                }
            }

            // ── 右側：統計 + BLE 連線卡 ─────────────────────────────────────
            ColumnLayout {
                // fillWidth 一定要明確關掉。Layout.fillWidth 的預設值是 false
                // *對一般 item 而言*，但 layout 本身（ColumnLayout/RowLayout/
                // GridLayout）預設是 true —— 不關的話這一欄會跟左邊的曲線面板
                // 一起分剩餘寬度，把面板擠成 0 寬（實機 2026-09-13：整個左半邊
                // 消失，統計欄撐滿全螢幕）。preferredWidth 只是「偏好」，擋不住
                // 這件事。
                Layout.fillWidth: false
                Layout.preferredWidth: 320
                Layout.minimumWidth: 280
                Layout.maximumWidth: 360
                Layout.fillHeight: true
                spacing: 14

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 22
                    color: monitor.cPanel
                    border.color: monitor.cLine
                    border.width: 1

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 22
                        spacing: 16

                        Repeater {
                            model: [
                                { zh: "平均溫度", en: "AVG", v: monitor.avgValue },
                                { zh: "最高溫度", en: "MAX", v: monitor.maxValue },
                                { zh: "最低溫度", en: "MIN", v: monitor.minValue }
                            ]
                            ColumnLayout {
                                id: metricItem
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 7
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        text: metricItem.modelData.zh
                                        color: "#829eb2"
                                        font.pixelSize: 14
                                    }
                                    Item { Layout.fillWidth: true }
                                    Text {
                                        text: metricItem.modelData.en
                                        color: "#829eb2"
                                        font.pixelSize: 14
                                        font.letterSpacing: 1
                                    }
                                }
                                RowLayout {
                                    spacing: 5
                                    Text {
                                        text: monitor.fmt(metricItem.modelData.v)
                                        color: monitor.cText
                                        font.pixelSize: 34
                                        font.family: "monospace"
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignBottom
                                        Layout.bottomMargin: 5
                                        text: monitor.unitText
                                        color: "#7896aa"
                                        font.pixelSize: 14
                                    }
                                }
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 5
                                    radius: 3
                                    color: "#132b3d"
                                    Rectangle {
                                        height: parent.height
                                        width: parent.width * monitor.barFrac(metricItem.modelData.v)
                                        radius: 3
                                        gradient: Gradient {
                                            orientation: Gradient.Horizontal
                                            GradientStop { position: 0.0; color: monitor.cBlue }
                                            GradientStop { position: 1.0; color: monitor.cCyan }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                }
            }
        }

        // ═══ FOOTER ═════════════════════════════════════════════════════════
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 62
            spacing: 16

            Rectangle {
                Layout.preferredHeight: 62
                Layout.preferredWidth: segRow.implicitWidth + 12
                radius: 15
                color: "#071522"
                border.color: "#1b3448"
                border.width: 1

                Row {
                    id: segRow
                    anchors.centerIn: parent
                    spacing: 6
                    Repeater {
                        model: [
                            { key: "live", label: "即時 30 s" },
                            { key: "1m",   label: "近 1 分鐘" },
                            { key: "5m",   label: "近 5 分鐘" }
                        ]
                        Rectangle {
                            id: segItem
                            required property var modelData
                            readonly property bool active: monitor.range === segItem.modelData.key
                            width: segLabel.implicitWidth + 42
                            height: 50
                            radius: 11
                            color: active ? "#12344a" : "transparent"
                            border.color: active ? "#2b6077" : "transparent"
                            border.width: 1
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: monitor.range = segItem.modelData.key }
                            Text {
                                id: segLabel
                                anchors.centerIn: parent
                                text: segItem.modelData.label
                                color: segItem.active ? "#ecfbff" : "#7f9fb3"
                                font.pixelSize: 17
                                font.bold: segItem.active
                            }
                        }
                    }
                }
            }
        }
    }
}
