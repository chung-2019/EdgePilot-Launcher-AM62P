import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Window
import "pages"

ApplicationWindow {
    id: window
    visible: true
    // visibility set from C++ (main.cpp) so the initial wayland map is
    // set_maximized rather than set_fullscreen — keep QML out of it.
    width: 1366
    height: 768
    title: "EdgePilot Launcher"
    color: "#F5F8FB"
    // Kiosk: no title bar / no minimize-close buttons. Without this the user
    // can hit weston's "_" minimize and lose the window — the process stays
    // alive, but weston-desktop-shell has no taskbar to restore it from.
    flags: Qt.Window | Qt.FramelessWindowHint

    // Core pages keep stable indices. Virtual Keyboard is appended at 15.
    property int activeIndex: 2
    // Tracks the page visited BEFORE the current one — used by pages with a
    // ✕ "back" button (e.g. TemperaturePage) to return where the user came from.
    property int previousActiveIndex: 1

    function navigateTo(idx) {
        // The panel deliberately does NOT close here. Picking a page is not a
        // reason to put the menu away: with the labels visible the operator can
        // read where they are and step through several pages in a row without
        // swiping the rail open again each time. Closing it is its own action —
        // swipe left, tap the mark, or tap the page.
        if (idx === activeIndex) return
        previousActiveIndex = activeIndex
        activeIndex = idx
    }

    // ── Nav rail ─────────────────────────────────────────────────────────
    //
    // The sidebar used to be a permanent 220 px column — 17% of a 1280 px
    // display, carrying ten labels that a returning operator no longer reads.
    // It is now a 56 px icon rail that widens to 220 on a left-to-right swipe
    // or a tap on the grip, and the labels come back with it.
    //
    // A rail rather than a fully hidden drawer, deliberately:
    //
    //   - The icons stay on screen, so the launcher still says what it can do
    //     at a glance. This box gets demonstrated to people who have never
    //     seen it; a blank left edge with a secret gesture does not.
    //   - The reveal gesture starts ON the rail, not over the page. Earth 3D
    //     orbits the camera with a full-page single-finger DragHandler, and a
    //     left-edge strip laid over the page would have eaten every drag that
    //     started there. This way that conflict does not exist at all.
    //   - It stays inside the layout instead of becoming a Popup, so it does
    //     not land in QQuickOverlay, where anything walking the scene to find
    //     items (touch mirroring, UI automation) has to hunt for it.
    //
    // 164 of the 220 px come back to the page, which is 75% of what hiding it
    // outright would have given.
    readonly property int navRailWidth: 56
    readonly property int navPanelWidth: 220

    property bool navExpanded: false

    // While a finger is on it the panel tracks the finger; on release it
    // either completes or snaps back. Same shape as the lock screen pull-down.
    property bool navDragging: false
    property real navDragWidth: navRailWidth

    // ── Lock screen ──────────────────────────────────────────────────────
    //
    // Pulled down from the top bar over whatever page is open, pushed back up
    // to return to it. It covers the header too, so it is parented to the
    // window overlay rather than the content item — a child of the content
    // item cannot draw over the header no matter what z it is given, because
    // the two are siblings and the header already sits at z 1.
    //
    // This gesture used to belong to the Earth 3D settings bar. It is now the
    // lock screen on every page, so the behaviour is the same wherever
    // the operator happens to be; Earth 3D opens its settings from the grip at
    // the top of the page, which was always there and is visible.
    property bool screenLocked: false
    property bool lockDragging: false
    property real lockDragProgress: 0        // 0..1 while dragging

    readonly property real lockReveal:
        lockDragging ? lockDragProgress : (screenLocked ? 1 : 0)

    // Formatted for the artwork this screen reproduces: 24-hour, no seconds,
    // and an English long date. Forced to en_US rather than the system locale
    // so the layout below cannot be handed a string it was not measured for.
    property string lockTime: ""
    property string lockDate: ""

    // Bumped on every benchmark state change so non-component bindings re-evaluate.
    property int refreshTick: 0
    Connections {
        target: benchmarkRunner
        function onResultChanged() { window.refreshTick++ }
        function onStatusChanged() { window.refreshTick++ }
    }

    // BLE → thermometer auto-launch.
    //
    // BLE Scan (idx 7) is the only BLE flow: six-digit Numeric Comparison
    // with the Apollo510b. It navigates on `connected()` without deferring.
    // The BT spec orders LL link establishment BEFORE the SMP passkey
    // exchange, but pairDevice() does not move the state to "connecting", so
    // that early `Connected: yes` emits nothing. `connected()` comes from
    // bluez's "Pairing successful", after the user has confirmed, so the
    // pair dialog never opens on top of the temperature curve.
    function openTemperatureMonitor() {
        window.navigateTo(2)
        vitalDialog.deviceType = "thermometer"
        vitalDialog.open()
    }
    Connections {
        target: bleScanner
        function onConnected() { window.openTemperatureMonitor() }
    }

    function runBench(name) {
        benchmarkDialog.open()
        benchmarkRunner.run(name)
    }

    BenchmarkDialog { id: benchmarkDialog }

    // Global numeric-comparison pairing dialog for BLE Scan (idx 7), which
    // pairs the Apollo510b watch (EdgePilot-510B). Keeping ONE Popup at the
    // ApplicationWindow level guarantees:
    //   * Always centered on the actual window (Popup parent = window)
    //   * Never shows two ghost copies (one per page)
    //   * Cancel / Confirm reliably wire through to bleScanner regardless
    //     of which page the user kicked the flow off from.
    property string pairingPendingAddress: ""
    property string pairingPendingPasskey: ""
    Connections {
        target: bleScanner
        function onPairingPasskey(address, passkey) {
            window.pairingPendingAddress = address
            window.pairingPendingPasskey = passkey
            pairingConfirmDialog.open()
        }
        function onPairingSucceeded(address) {
            window.pairingPendingAddress = ""
            window.pairingPendingPasskey = ""
            pairingConfirmDialog.close()
        }
        function onPairingFailed(address, reason) {
            window.pairingPendingAddress = ""
            window.pairingPendingPasskey = ""
            pairingConfirmDialog.close()
        }
    }
    Popup {
        id: pairingConfirmDialog
        // 觸控命中區修正：必須以「window overlay」為定位基準，不能用 `parent`。
        // 宣告在 ApplicationWindow 底下的 Popup，其定位 parent = window 的 contentItem，
        // 而 contentItem 被上方 64px header（topBar）往下推、且高度短少 64px。用
        // `anchors.centerIn: parent` 在這個「被推移、變短」的座標系置中，但 Popup 內容
        // 在繪製/輸入命中時是 reparent 到鋪滿整個 window 的 Overlay。兩套座標系不一致 →
        // 「看到的按鈕框」與「實際吃到 tap 的框」錯位，使用者只能按到兩框重疊的那一小塊
        // （≈文字中央），左右側落在 modal 遮罩上被吃掉（故先碰側邊再碰中央要多按幾次）。
        // 改用 Overlay.overlay（全 window、原點 0,0、不受 header 影響）即統一兩套座標系，
        // 與本檔 rebootDialog / VitalSignsMonitorDialog 既有的正確寫法一致。
        parent: Overlay.overlay
        modal: true
        focus: true
        closePolicy: Popup.NoAutoClose
        width: 620
        // 440（原 360）：欄內容（標題+訊息+96px passkey 框+64px 按鈕列+各 18px 間距）約
        // 需 336px，但 360 扣掉上下 margin 32 後內部僅 296px → 溢出，按鈕列被擠出 popup
        // 的命中矩形、部分落到遮罩上，加重觸控不靈敏。加高消除溢出。
        height: 440
        anchors.centerIn: Overlay.overlay

        background: Rectangle {
            color: "#111827"
            radius: 12
            border.color: "#3b82f6"
            border.width: 2
        }

        Overlay.modal: Rectangle { color: "#CC000000" }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 32
            spacing: 18

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Bluetooth Pairing Request"
                color: "#ffffff"
                font.pixelSize: 32
                font.bold: true
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "\"" + (bleScanner.connectedName.length > 0
                              ? bleScanner.connectedName
                              : window.pairingPendingAddress)
                       + "\" wants to pair with this device. Confirm that the code shown on that device matches the code below."
                color: "#cbd5e1"
                font.pixelSize: 22
            }
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 360
                Layout.preferredHeight: 96
                color: "#0a0a0a"
                radius: 10
                border.color: "#3b82f6"
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: window.pairingPendingPasskey
                    color: "#22d3ee"
                    font.pixelSize: 64
                    font.bold: true
                    font.family: "monospace"
                    font.letterSpacing: 8
                }
            }
            Item { Layout.fillHeight: true }
            RowLayout {
                Layout.fillWidth: true
                spacing: 20
                Button {
                    text: "Cancel"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 64
                    font.pixelSize: 28
                    font.bold: true
                    onClicked: bleScanner.cancelPairing()
                    background: Rectangle {
                        radius: 8
                        color: parent.pressed ? "#475569" : "#334155"
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "#ffffff"
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    text: "Pair"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 64
                    font.pixelSize: 28
                    font.bold: true
                    onClicked: bleScanner.confirmPairing()
                    background: Rectangle {
                        radius: 8
                        color: parent.pressed ? "#1d4ed8" : "#2563eb"
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "#ffffff"
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    VitalSignsMonitorDialog {
        id: vitalDialog
        // X button: close, then if the user came from BLE Scan (idx 7)
        // navigate back there. Otherwise just close (e.g. manual launch
        // from HealthMonitor stays on HealthMonitor).
        onCloseRequested: {
            close()
            if (window.previousActiveIndex === 7) {
                window.navigateTo(7)
            }
        }
    }

    // Reboot confirmation — 與 BLE 數字比對對話框同款外觀（深色卡片 + 藍框 + 大標題/大
    // 按鈕），並加大、加入立體感：卡片用垂直漸層 + 上緣 bevel 高光；按鈕用 app 既有立體
    // 慣用法（QtQuick.Effects MultiEffect drop shadow + 垂直漸層 + bevel，按下時陰影下沉、
    // 漸層加深，呈現實體按壓感，見 DonutGauge / Dashboard3DGauge / GlassyDomeButton）。
    // 定位同樣以 Overlay.overlay 為基準（避免 header 造成的視覺/觸控錯位）。
    Popup {
        id: rebootDialog
        parent: Overlay.overlay
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        width: 760
        height: 480
        anchors.centerIn: Overlay.overlay

        // 立體卡片：垂直漸層（上亮下暗）製造受光的隆起感 + 藍色描邊 + 上緣 bevel 高光。
        background: Rectangle {
            radius: 18
            border.color: "#3b82f6"
            border.width: 2
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: "#1b2536" }
                GradientStop { position: 1.0; color: "#0b1120" }
            }
            Rectangle {                 // 上緣一條淡高光線，做出受光的立體邊
                anchors { left: parent.left; right: parent.right; top: parent.top
                          leftMargin: 16; rightMargin: 16; topMargin: 3 }
                height: 2
                radius: 1
                color: "#40ffffff"
            }
        }

        Overlay.modal: Rectangle { color: "#CC000000" }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 36
            spacing: 20

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Restart System"
                color: "#ffffff"
                font.pixelSize: 38
                font.bold: true
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Reboot the system"
                color: "#93a4bd"
                font.pixelSize: 22
            }

            // 強調框（對應 BLE 對話框的 passkey 框）：內凹深色漸層 + 藍邊，內含重啟圖示與問句。
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 520
                Layout.preferredHeight: 124
                radius: 14
                border.color: "#3b82f6"
                border.width: 1
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: "#070b12" }
                    GradientStop { position: 1.0; color: "#0e1726" }
                }
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 18
                    spacing: 20
                    Image {
                        source: "qrc:/assets/icons/rotate-ccw.svg"   // 白色 stroke，深底可見
                        sourceSize: Qt.size(128, 128)
                        Layout.preferredWidth: 68
                        Layout.preferredHeight: 68
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Text {
                            Layout.fillWidth: true
                            text: "Are you sure you want to restart?"
                            color: "#e8eef7"
                            font.pixelSize: 25
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "The system will restart immediately"
                            color: "#93a4bd"
                            font.pixelSize: 18
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.fillWidth: true
                spacing: 24

                // 取消 — 中性立體按鈕
                Button {
                    id: rebootCancelBtn
                    text: "Cancel"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 76
                    font.pixelSize: 30
                    font.bold: true
                    onClicked: rebootDialog.close()
                    background: Rectangle {
                        radius: 14
                        border.color: "#56657b"
                        border.width: 1
                        gradient: Gradient {
                            orientation: Gradient.Vertical
                            GradientStop { position: 0.0; color: rebootCancelBtn.pressed ? "#222b39" : "#3c485b" }
                            GradientStop { position: 1.0; color: rebootCancelBtn.pressed ? "#2c3645" : "#28303d" }
                        }
                        Rectangle {                      // 上緣 bevel 高光（按下時隱藏）
                            anchors { left: parent.left; right: parent.right; top: parent.top
                                      leftMargin: 8; rightMargin: 8; topMargin: 3 }
                            height: parent.height * 0.42
                            radius: 11
                            visible: !rebootCancelBtn.pressed
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "#33ffffff" }
                                GradientStop { position: 1.0; color: "#00ffffff" }
                            }
                        }
                        layer.enabled: true              // GPU drop shadow，按下時下沉
                        layer.effect: MultiEffect {
                            shadowEnabled: true
                            shadowColor: "#80000000"
                            shadowBlur: 0.45
                            shadowVerticalOffset: rebootCancelBtn.pressed ? 1 : 6
                            shadowHorizontalOffset: 0
                        }
                    }
                    contentItem: Text {
                        text: rebootCancelBtn.text
                        color: "#ffffff"
                        font: rebootCancelBtn.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // 確定重啟 — 破壞性動作用紅色立體按鈕（3D 設計語言與 BLE 一致，色彩示警）
                Button {
                    id: rebootConfirmBtn
                    text: "Restart"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 76
                    font.pixelSize: 30
                    font.bold: true
                    onClicked: { rebootDialog.close(); systemMonitor.reboot() }
                    background: Rectangle {
                        radius: 14
                        border.color: "#fb7185"
                        border.width: 1
                        gradient: Gradient {
                            orientation: Gradient.Vertical
                            GradientStop { position: 0.0; color: rebootConfirmBtn.pressed ? "#9f1239" : "#ef4444" }
                            GradientStop { position: 1.0; color: rebootConfirmBtn.pressed ? "#7f1d1d" : "#b91c1c" }
                        }
                        Rectangle {                      // 上緣 bevel 高光（按下時隱藏）
                            anchors { left: parent.left; right: parent.right; top: parent.top
                                      leftMargin: 8; rightMargin: 8; topMargin: 3 }
                            height: parent.height * 0.42
                            radius: 11
                            visible: !rebootConfirmBtn.pressed
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "#4cffffff" }
                                GradientStop { position: 1.0; color: "#00ffffff" }
                            }
                        }
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            shadowEnabled: true
                            shadowColor: "#90450a0a"
                            shadowBlur: 0.5
                            shadowVerticalOffset: rebootConfirmBtn.pressed ? 1 : 6
                            shadowHorizontalOffset: 0
                        }
                    }
                    contentItem: Text {
                        text: rebootConfirmBtn.text
                        color: "#ffffff"
                        font: rebootConfirmBtn.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    // ─── TOP BAR ─────────────────────────────────────────────────
    header: Rectangle {
        id: topBar
        height: 64
        color: "#080d16"

        // ── Earth 3D settings: pull down from the very top edge ──────
        //
        // Control-Centre style. The gesture has to start on the top bar, which
        // is the top edge of the display in this kiosk, so it is defined here
        // rather than inside the page — a page-level strip starts 64 px lower
        // and does not feel like an edge swipe.
        //
        // Attached straight to the top bar instead of a covering Item: an Item
        // would swallow the reboot button's tap. A DragHandler only takes the
        // grab once the drag threshold is passed, so taps still get through,
        // and once it has the grab it keeps tracking the finger down into the
        // page below.
        DragHandler {
            id: lockPull

            target: null
            xAxis.enabled: false
            yAxis.enabled: true

            // Every page. Off once the lock is down — the way back up is the
            // handler on the lock screen itself.
            enabled: !window.screenLocked

            // Same reasoning as the unlock handler: an edge gesture that has
            // started should not be handed to anything the finger passes over
            // on its way down. Nothing was measured stealing this one — the
            // press lands on the top bar, which is outside every page's
            // bounds — but "nothing else is listening there" has been wrong
            // twice today, and refusing take-over costs nothing.
            grabPermissions: PointerHandler.CanTakeOverFromAnything

            // The lock follows the finger 1:1 down the whole screen, so a
            // quarter of the way is the commit point rather than a fixed
            // number of pixels.
            readonly property real commitFrac: 0.25

            // How far the finger has travelled since it went down, measured off
            // the centroid rather than activeTranslation.
            //
            // activeTranslation is worth 0 on the very event that activates the
            // handler, and is reset again the moment `active` goes false. It
            // only ever carries a real distance on an update delivered BETWEEN
            // those two — and touch updates arrive at the frame rate, on the
            // heaviest page in the launcher. Measured on the EVM: a 170 px
            // swipe delivered in five updates or fewer activates on its last
            // one, so no in-between update exists and the release branch reads
            // 0. That is the intermittent "pulling down does nothing" report —
            // the fewer frames Earth 3D leaves for input, the more often a
            // swipe lands in the failing shape.
            //
            // The centroid survives both transitions: 170 px of pull reads as
            // 170 whether the swipe arrived in ten updates or in one.
            // tools/mission-harness/tst_topbarpull.qml measures the two
            // readings side by side across delivery rates.
            readonly property real pulled:
                centroid.scenePosition.y - centroid.scenePressPosition.y

            function syncProgress() {
                window.lockDragProgress =
                    Math.max(0, Math.min(1, pulled / window.height))
            }

            onActiveChanged: {
                if (active) {
                    window.lockDragging = true
                    // The activating update can already be most of the way down
                    // when frames are scarce, so place the lock now rather than
                    // waiting for an update that may never come.
                    syncProgress()
                    return
                }

                // Release. Complete it if pulled far enough OR flicked quickly
                // — the same either/or Control Centre uses, so a short sharp
                // swipe works as well as a slow deliberate drag. Both readings
                // still stand here; it is only activeTranslation that is reset.
                window.screenLocked =
                    pulled > window.height * commitFrac
                    || (centroid.velocity.y > 300 && pulled > 40)

                window.lockDragging = false
                window.lockDragProgress = 0
            }

            // centroidChanged rather than activeTranslationChanged: it also
            // fires on the activating event, so the lock picks the finger up
            // one update earlier — the difference between a jump and a slide
            // when only three updates arrive for the whole gesture.
            onCentroidChanged: {
                if (active)
                    syncProgress()
            }
        }

        // Live digital clock state for the top-right date/time pill, and for
        // the lock screen — one 1 Hz tick serves both rather than two timers
        // ticking a few milliseconds apart.
        property string currentTime: ""
        property string currentDate: ""
        function refreshClock() {
            var d = new Date()
            topBar.currentTime = Qt.formatDateTime(d, "HH:mm:ss")
            topBar.currentDate = Qt.formatDateTime(d, "yyyy/MM/dd")

            window.lockTime = d.toLocaleTimeString(Qt.locale("en_US"), "HH:mm")
            window.lockDate = d.toLocaleDateString(Qt.locale("en_US"),
                                                   "dddd, MMMM d, yyyy")
        }
        Timer {
            interval: 1000
            running:  true
            repeat:   true
            onTriggered: topBar.refreshClock()
        }
        Component.onCompleted: topBar.refreshClock()

        // 1px bottom divider
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: "#27313d"
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 18
            spacing: 14

            // LEFT — compact EdgePilot subsystem status cluster
            Row {
                Layout.alignment: Qt.AlignVCenter
                spacing: 16

                TopBarStatusItem {
                    iconSource: "qrc:/assets/icons/cpu.svg"
                    label: "SYS"
                    accentColor: "#2196f3"
                }
                TopBarStatusItem {
                    iconSource: "qrc:/assets/icons/network.svg"
                    label: "NET"
                    accentColor: "#13d8dc"
                }
                TopBarStatusItem {
                    iconSource: "qrc:/assets/icons/device.svg"
                    label: "DEV"
                    accentColor: "#a855f7"
                }
            }

            // Spacer pushes the right cluster to the edge
            Item { Layout.fillWidth: true }

            // RIGHT — WiFi icon (opacity dims when wlan0 has no IPv4)
            Rectangle {
                id: wifiBadge
                Layout.alignment: Qt.AlignVCenter
                implicitWidth:  48
                implicitHeight: 48
                radius: 24
                color: "transparent"
                border.width: 1
                border.color: "#444444"
                // wlanIp returns IPv4 when connected; otherwise "DOWN"/"UNKNOWN"/"N/A".
                readonly property bool wifiUp:
                    /^\d+\.\d+\.\d+\.\d+$/.test(systemMonitor.wlanIp || "")

                Image {
                    anchors.centerIn: parent
                    width: 28
                    height: 28
                    source: "qrc:/assets/icons/wifi.svg"
                    sourceSize: Qt.size(56, 56)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    opacity: wifiBadge.wifiUp ? 1.0 : 0.3
                }
            }

            // RIGHT — Bluetooth icon (opacity dims when hci0 not ENABLED)
            Rectangle {
                id: btBadge
                Layout.alignment: Qt.AlignVCenter
                implicitWidth:  48
                implicitHeight: 48
                radius: 24
                color: "transparent"
                border.width: 1
                border.color: "#444444"
                // Light up only when a BLE device is actively connected/streaming,
                // not just because the adapter is powered on.
                readonly property bool btUp:
                    bleScanner.connectionState === "connected"
                    || bleScanner.connectionState === "streaming"

                Image {
                    anchors.centerIn: parent
                    width: 28
                    height: 28
                    source: "qrc:/assets/icons/bluetooth.svg"
                    sourceSize: Qt.size(56, 56)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    opacity: btBadge.btUp ? 1.0 : 0.3
                }
            }

            // RIGHT — Reset (icon-only symbol, enlarged, sits LEFT of clock)
            Rectangle {
                id: resetBtn
                Layout.alignment: Qt.AlignVCenter
                implicitWidth:  48
                implicitHeight: 48
                radius: 24
                color: resetHover.hovered ? "#2a2a2a" : "transparent"
                border.width: 1
                border.color: "#444444"

                HoverHandler {
                    id: resetHover
                    cursorShape: Qt.PointingHandCursor
                }

                Image {
                    id: resetIconSrc
                    anchors.centerIn: parent
                    width: 28
                    height: 28
                    source: "qrc:/assets/icons/rotate-ccw.svg"
                    sourceSize: Qt.size(56, 56)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    visible: false
                }
                MultiEffect {
                    anchors.fill: resetIconSrc
                    source: resetIconSrc
                    colorization: 1.0
                    colorizationColor: "#ffffff"
                }

                TapHandler {
                    onTapped: rebootDialog.open()
                }
            }

            // RIGHT — digital date/time (22px = topbar baseline 15px × 1.5)
            Column {
                Layout.alignment: Qt.AlignVCenter
                spacing: 0
                Text {
                    anchors.right: parent.right
                    text: topBar.currentTime
                    color: "#ffffff"
                    font.pixelSize: 22
                    font.bold: true
                }
                Text {
                    anchors.right: parent.right
                    text: topBar.currentDate
                    color: "#9ca3af"
                    font.pixelSize: 22
                }
            }
        }

        // Keep the product title centered in the entire display regardless of
        // the different widths of the left and right status clusters.
        Row {
            anchors.centerIn: parent
            spacing: 0

            Text {
                text: "Edge"
                color: "#ffffff"
                font.pixelSize: 24
                font.bold: true
                font.italic: true
            }
            Text {
                text: "Pilot"
                color: "#2196f3"
                font.pixelSize: 24
                font.bold: true
                font.italic: true
            }
            Item { width: 12; height: 1 }
            Text {
                text: "System Console"
                color: "#ffffff"
                font.pixelSize: 22
                font.bold: true
            }
        }
    }

    // ─── MAIN ROW: SIDEBAR + CONTENT ─────────────────────────────
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // NAV RAIL — 56 px of icons that widens to 220 on a swipe
        Item {
            id: navRail

            Layout.preferredWidth: window.navRailWidth
            Layout.fillHeight: true
            Layout.bottomMargin: 16

            // The expanded panel is wider than this cell and nothing clips it,
            // so it draws over the page rather than pushing it. The page keeps
            // its width and never reflows.
            z: 20

            // Dismiss layer, to the right of the panel.
            //
            // Gated AND hidden while the rail is collapsed. An absorber parked
            // over the content with no `enabled` is exactly the defect that
            // made the Earth 3D pull-down misfire — see
            // Earth3D_下拉手勢_送達次數不足_20260816.md, 改動三.
            MouseArea {
                x: navPanel.width
                width: window.width - navPanel.width
                height: window.height

                enabled: window.navExpanded
                visible: enabled
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

                onPressed: window.navExpanded = false
            }

            Rectangle {
                id: navPanel

                width: window.navDragging
                       ? window.navDragWidth
                       : (window.navExpanded ? window.navPanelWidth
                                             : window.navRailWidth)
                height: parent.height
                color: "#0a0a0a"

                // Driven by the ACTUAL width rather than by navExpanded, so
                // the labels appear when there is room for them instead of at
                // the instant the animation starts.
                readonly property bool compact: width < 150

                // Off while a finger is on it — the panel has to sit where the
                // finger is, not ease towards it.
                Behavior on width {
                    enabled: !window.navDragging
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }

                // ── Swipe right to open ──────────────────────────────────
                //
                // Attached straight to the panel instead of a covering Item:
                // an Item would swallow the taps on the icons. A DragHandler
                // only takes the grab once the drag threshold is passed, so
                // taps still get through, and once it has the grab it keeps
                // tracking the finger out across the page.
                DragHandler {
                    id: navPull

                    target: null
                    xAxis.enabled: true
                    yAxis.enabled: false

                    enabled: !window.navExpanded

                    // Measured off the centroid, not activeTranslation.
                    // activeTranslation is 0 on the event that activates the
                    // handler and is reset again on release, so a swipe
                    // delivered in few touch updates can leave it 0 for the
                    // whole gesture. Written up in
                    // Earth3D_下拉手勢_送達次數不足_20260816.md.
                    readonly property real pulled:
                        centroid.scenePosition.x - centroid.scenePressPosition.x

                    readonly property real travel:
                        window.navPanelWidth - window.navRailWidth

                    function syncWidth() {
                        window.navDragWidth =
                            Math.max(window.navRailWidth,
                                     Math.min(window.navPanelWidth,
                                              window.navRailWidth + pulled))
                    }

                    onActiveChanged: {
                        if (active) {
                            window.navDragging = true
                            syncWidth()
                            return
                        }

                        // Half way across, or a flick — the same either/or the
                        // Earth 3D pull-down uses.
                        window.navExpanded =
                            pulled > travel * 0.5
                            || (centroid.velocity.x > 300 && pulled > 15)

                        window.navDragging = false
                    }

                    onCentroidChanged: {
                        if (active)
                            syncWidth()
                    }
                }

                // ── Swipe left to put it back ────────────────────────────
                DragHandler {
                    target: null
                    xAxis.enabled: true
                    yAxis.enabled: false

                    enabled: window.navExpanded

                    readonly property real pushed:
                        centroid.scenePosition.x - centroid.scenePressPosition.x

                    function closeIfPushedLeft() {
                        if (active && pushed < -40)
                            window.navExpanded = false
                    }

                    onActiveChanged: closeIfPushedLeft()
                    onCentroidChanged: closeIfPushedLeft()
                }

                // Grip — the only hint the rail leaves that there is more.
                //
                // Deliberately just a picture. A TapHandler here needs a
                // margin to be hittable at 5 px wide, and that margin reaches
                // back over the right-hand side of the icon buttons at the
                // same height. Both would be TapHandlers holding only passive
                // grabs, so BOTH would fire: the tap would navigate and expand
                // at once, and which one won the race would decide what the
                // user ended up looking at. The tap affordance lives on the
                // brand block instead, where nothing else is listening.
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: 3
                    anchors.verticalCenter: parent.verticalCenter

                    width: 5
                    height: 58
                    radius: 2.5
                    color: "#4b5768"

                    visible: navPanel.compact
                    opacity: 0.9
                }

                // ── EdgePilot brand block with 1px bottom divider
                Item {
                    id: brandBlock
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 90

                    Column {
                        anchors.centerIn: parent
                        spacing: 2

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 7

                            Image {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 52
                                height: 34
                                source: "qrc:/assets/edgepilot_mark.png"
                                sourceSize: Qt.size(377, 232)
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                mipmap: true
                            }

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 0

                                // At rail width the mark carries the brand on its
                                // own; the wordmark would not fit beside it.
                                visible: !navPanel.compact

                                Text {
                                    text: "Edge"
                                    color: "#ffffff"
                                    font.family: "Liberation Sans"
                                    font.pixelSize: 29
                                    font.bold: true
                                    font.italic: true
                                    renderType: Text.NativeRendering
                                }
                                Text {
                                    text: "Pilot"
                                    color: "#1685f8"
                                    font.family: "Liberation Sans"
                                    font.pixelSize: 29
                                    font.bold: true
                                    font.italic: true
                                    renderType: Text.NativeRendering
                                }
                            }
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: !navPanel.compact
                            text: "EMBEDDED LINUX PLATFORM"
                            color: "#ffffff"
                            font.family: "Liberation Sans"
                            font.pixelSize: 10
                            font.bold: true
                            font.letterSpacing: 1.1
                            renderType: Text.NativeRendering
                        }
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: "#333333"
                    }

                    // Tap the mark to open or close the rail — the swipe is
                    // the primary gesture, but a mark that toggles the menu is
                    // a familiar fallback and, unlike the grip, this is 90 px
                    // of empty header with nothing else listening on it.
                    TapHandler {
                        onTapped: window.navExpanded = !window.navExpanded
                    }
                }

                ColumnLayout {
                    anchors.top: brandBlock.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.topMargin: 16
                    anchors.bottomMargin: 20
                    anchors.leftMargin: navPanel.compact ? 8 : 12
                    anchors.rightMargin: navPanel.compact ? 8 : 12
                    spacing: 8

                    // Analog watch face built from PNG layers in qrc:/Clock/.
                    // 160 px wide — nothing to show at rail width, and Layouts
                    // skip invisible items so the icons move up to fill the gap.
                    Clock {
                        visible: !navPanel.compact
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 160
                        Layout.preferredHeight: 160
                    }

                    NavSidebarItem {
                        Layout.fillWidth: true
                        compact: navPanel.compact
                        iconSource: "qrc:/assets/icons/grid.svg"
                        label: "System"
                        checked: window.activeIndex === 0
                        onClicked: window.navigateTo(0)
                    }
                    NavSidebarItem {
                        Layout.fillWidth: true
                        compact: navPanel.compact
                        iconSource: "qrc:/assets/icons/activity.svg"
                        label: "Dashboard"
                        checked: window.activeIndex === 1
                        onClicked: window.navigateTo(1)
                    }
                    NavSidebarItem {
                        Layout.fillWidth: true
                        compact: navPanel.compact
                        iconSource: "qrc:/assets/icons/heart.svg"
                        label: "Monitor"
                        checked: window.activeIndex === 2
                        onClicked: window.navigateTo(2)
                    }
                    NavSidebarItem {
                        Layout.fillWidth: true
                        compact: navPanel.compact
                        iconSource: "qrc:/assets/icons/thermometer.svg"
                        label: "Temperature"
                        checked: window.activeIndex === 3
                        onClicked: window.navigateTo(3)
                    }
                    NavSidebarItem {
                        Layout.fillWidth: true
                        compact: navPanel.compact
                        iconSource: "qrc:/assets/icons/globe.svg"
                        label: "Earth 3D"
                        checked: window.activeIndex === 5
                        onClicked: window.navigateTo(5)
                    }
                    // Single BLE entry — landing page lives at idx 6 (BleHubPage);
                    // its one tool, BLE Scan at idx 7, is reachable only from the
                    // hub. Sidebar stays highlighted on either BLE page.
                    NavSidebarItem {
                        Layout.fillWidth: true
                        compact: navPanel.compact
                        iconSource: "qrc:/assets/icons/bluetooth.svg"
                        label: "BLE"
                        checked: window.activeIndex === 6 || window.activeIndex === 7
                        onClicked: window.navigateTo(6)
                    }
                    NavSidebarItem {
                        Layout.fillWidth: true
                        compact: navPanel.compact
                        iconSource: "qrc:/assets/icons/keyboard.svg"
                        label: "Keyboard"
                        checked: window.activeIndex === 15
                        onClicked: window.navigateTo(15)
                    }
                    NavSidebarItem {
                        Layout.fillWidth: true
                        compact: navPanel.compact
                        iconSource: "qrc:/assets/icons/info.svg"
                        label: "About"
                        checked: window.activeIndex === 13
                        onClicked: window.navigateTo(13)
                    }

                    Item { Layout.fillHeight: true }

                    // Sidebar EdgePilot platform image / footer
                    Column {
                        visible: !navPanel.compact
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 6
                        Image {
                            anchors.horizontalCenter: parent.horizontalCenter
                            source: "qrc:/assets/edgepilot_am62p_platform.png"
                            fillMode: Image.PreserveAspectFit
                            width: 196
                            height: 135
                            sourceSize: Qt.size(320, 220)
                            smooth: true
                            mipmap: true
                        }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 0

                            Text {
                                text: "Edge"
                                color: "#ffffff"
                                font.pixelSize: 18
                                font.bold: true
                                font.italic: true
                            }
                            Text {
                                text: "Pilot"
                                color: "#2196f3"
                                font.pixelSize: 18
                                font.bold: true
                                font.italic: true
                            }
                            Item { width: 6; height: 1 }
                            Text {
                                text: "Platform"
                                color: "#ffffff"
                                font.pixelSize: 18
                                font.bold: true
                            }
                        }
                        Text {
                            text: "AM62P Embedded Linux"
                            color: "#13d8dc"
                            font.pixelSize: 15
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        Text {
                            text: "Open Development Environment"
                            color: "#b8c5d9"
                            font.pixelSize: 13
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }
            }
        }

        // CONTENT — page stack driven by activeIndex
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: window.activeIndex

            SystemOverviewPage {}
            DashboardPage      {}
            HealthMonitorPage {
                onLaunchRequested: function(deviceType) {
                    vitalDialog.deviceType = deviceType
                    vitalDialog.open()
                }
            }
            TemperaturePage    {}
            PerformancePage    {}
            EarthMoonPage      { id: earthMoonPage }
            BleHubPage {
                onToolRequested: function(pageIndex) { window.navigateTo(pageIndex) }
            }
            BleScanPage  { onBackRequested: window.navigateTo(6) }
            // 8–11 held the other BLE tools (BLE Pair, BLE Scan2, BLE Scan 3,
            // Standard BLE) and 12 the USB page. Only the Apollo510b flow on
            // BLE Scan is kept; the empty Items hold the slots so every later
            // page keeps its index.
            Item               {}
            Item               {}
            Item               {}
            Item               {}
            Item               {}
            AboutPage          {}
            // 14 held the Continuous Detection tool — reserved the same way.
            Item               {}
            // Appended to preserve every existing page index.
            VirtualKeyboardPage {}
        }
    }

    // ─── LOCK SCREEN ─────────────────────────────────────────────────
    //
    // Parented to the window overlay so it covers the header as well; a child
    // of the content item cannot, whatever z it is given, because the header
    // is its sibling and already sits above it.
    LockScreen {
        id: lockScreen

        parent: Overlay.overlay
        width: parent.width
        height: parent.height
        z: 100

        // Tracks the reveal, so the same expression serves the finger during a
        // pull and the animation on release.
        y: -height * (1 - window.lockReveal)

        // Bound to the position rather than to lockReveal: on release the
        // reveal snaps to its final value immediately while y is still
        // animating, and keying off the reveal would blank the screen before
        // the slide had played.
        visible: y > -height

        timeText: window.lockTime
        dateText: window.lockDate
        reveal: window.lockReveal

        Behavior on y {
            enabled: !window.lockDragging
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
        }

        // Swallows everything aimed at the launcher underneath. Enabled only
        // once the lock is actually down: while it is being pulled, the top
        // bar's handler owns the gesture and this must not compete for it.
        MouseArea {
            anchors.fill: parent

            enabled: window.screenLocked
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        }

        // Push it back up to return to the page underneath.
        DragHandler {
            target: null
            xAxis.enabled: false
            yAxis.enabled: true

            enabled: window.screenLocked

            // Refuse to hand the gesture on once it is ours.
            //
            // The page behind the lock is still there and still enabled, and a
            // touch press is offered to the pointer handlers of every item
            // under it — a handler taking a passive grab does not consume the
            // event, so the MouseArea above cannot shield them. On Earth 3D
            // that means the camera's full-page orbit DragHandler joins in on
            // the unlock swipe, and Qt's default permissions let a same-type
            // handler that grabbed first keep it.
            //
            // Measured: a 300 px swipe up reached the unlock handler as 150 px,
            // which is short of the 200 px threshold, so the screen stayed
            // locked and the operator had to try again — exactly the report,
            // and only on Earth 3D because it is the only page with a handler
            // rather than a Flickable underneath.
            //
            // CanTakeOverFromAnything without any Approves* bit: this handler
            // may take the gesture from anything, and nothing may take it back.
            // See tools/mission-harness/tst_lockvsorbit.qml.
            grabPermissions: PointerHandler.CanTakeOverFromAnything

            readonly property real pushed:
                centroid.scenePosition.y - centroid.scenePressPosition.y

            function syncProgress() {
                window.lockDragProgress =
                    Math.max(0, Math.min(1, 1 + pushed / window.height))
            }

            onActiveChanged: {
                if (active) {
                    window.lockDragging = true
                    syncProgress()
                    return
                }

                // Mirror of the pull-down: a quarter of the screen, or a flick.
                const dismissed =
                    pushed < -window.height * 0.25
                    || (centroid.velocity.y < -300 && pushed < -40)

                window.screenLocked = !dismissed
                window.lockDragging = false
                window.lockDragProgress = 0
            }

            onCentroidChanged: {
                if (active)
                    syncProgress()
            }
        }
    }
}
