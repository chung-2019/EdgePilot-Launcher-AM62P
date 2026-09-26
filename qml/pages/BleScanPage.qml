import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// BLE Scan — six-digit Numeric Comparison pairing.
//
// Target device: Apollo510b watchface (Cordio stack, advertises as
// "EdgePilot-510B"). Its SMP config is LE Secure Connections with the MITM
// flag and ioCap SMP_IO_DISP_YES_NO, so bluez negotiates Numeric Comparison
// instead of Just Works: both sides derive the SAME six-digit value, the watch
// draws it on its own screen, and the user confirms here that the two match.
//
// Why tapping a row now pairs instead of connecting: the old path was
// `trust` + `connect`, which is what the third-party thermometers need (their
// firmware cannot pair at all) but it leaves an unauthenticated link. The
// Apollo510b Health Thermometer attributes carry ATTS_PERMIT_READ_ENC /
// WRITE_ENC, so the CCCD write that starts the temperature stream only
// succeeds on an encrypted link — i.e. after a successful bond.
//
// The six-digit confirm dialog itself lives at ApplicationWindow level in
// Main.qml (one global Popup), so this page only starts the flow and mirrors
// the outcome.
Rectangle {
    id: root
    color: "#0a0a0a"

    signal backRequested()

    // Address tapped by the user, held from the moment `pair` is issued until
    // bluez reports success or failure. bleScanner.connectedAddress is set at
    // the same instant, but connectionState stays "idle" until the link is up,
    // so this is what drives the per-row "Pairing…" badge during the handshake
    // — including the seconds before the passkey dialog appears.
    property string pendingAddress: ""
    property string lastResult: ""
    property color  lastResultColor: "#9ca3af"

    Connections {
        target: bleScanner
        function onPairingSucceeded(address) {
            root.pendingAddress = ""
            root.lastResult = "Paired: " + address
            root.lastResultColor = "#10b981"
        }
        function onPairingFailed(address, reason) {
            root.pendingAddress = ""
            root.lastResult = "Pairing failed: " + reason
            root.lastResultColor = "#ef4444"
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 48
        spacing: 40

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#1a1a1a"
            radius: 8
            border.color: "#333333"
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 36
                spacing: 22

                // ── Header ─────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 18

                    // Back to BLE hub
                    Rectangle {
                        Layout.preferredWidth: 56
                        Layout.preferredHeight: 56
                        radius: 14
                        color: backHover.hovered ? "#3a3a3a" : "#262626"
                        HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.backRequested() }
                        Text {
                            anchors.centerIn: parent
                            text: "←"
                            color: "#ffffff"
                            font.pixelSize: 32
                            font.bold: true
                        }
                    }

                    Rectangle {
                        Layout.preferredWidth: 56
                        Layout.preferredHeight: 56
                        radius: 14
                        color: "#262626"

                        Image {
                            anchors.centerIn: parent
                            width: 32; height: 32
                            source: "qrc:/assets/icons/bluetooth.svg"
                            sourceSize: Qt.size(64, 64)
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }
                    }

                    ColumnLayout {
                        spacing: 4
                        Text {
                            text: "BLE Scanner"
                            color: "#ffffff"
                            font.pixelSize: 56
                            font.bold: true
                        }
                        Text {
                            text: "CC3351 · hci0 · 6-digit numeric comparison"
                            color: "#9ca3af"
                            font.pixelSize: 28
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        text: bleScanner.status
                        color: bleScanner.scanning ? "#22d3ee" : "#9ca3af"
                        font.pixelSize: 32
                        font.bold: true
                    }
                }

                // ── Controls ───────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14

                    Button {
                        // scanIntent: stable across auto-reconnect toggles.
                        text: bleScanner.scanIntent ? "Stop Scan" : "Start Scan"
                        Layout.preferredHeight: 72
                        Layout.preferredWidth: 250
                        font.pixelSize: 32
                        font.bold: true
                        onClicked: bleScanner.scanIntent ? bleScanner.stopScan()
                                                        : bleScanner.startScan()
                        background: Rectangle {
                            radius: 8
                            color: parent.pressed
                                   ? (bleScanner.scanIntent ? "#7f1d1d" : "#0e7490")
                                   : (bleScanner.scanIntent ? "#dc2626" : "#0891b2")
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
                        text: "Clear"
                        Layout.preferredHeight: 72
                        Layout.preferredWidth: 160
                        font.pixelSize: 32
                        enabled: !bleScanner.scanIntent
                        onClicked: {
                            root.lastResult = ""
                            bleScanner.clearDevices()
                        }
                        background: Rectangle {
                            radius: 8
                            color: parent.enabled
                                   ? (parent.pressed ? "#374151" : "#4b5563")
                                   : "#262626"
                        }
                        contentItem: Text {
                            text: parent.text
                            color: parent.enabled ? "#ffffff" : "#6b7280"
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        text: "Stop & Disconnect"
                        // Visible whenever an auto-reconnect target is latched
                        // (connecting / connected / streaming, or waiting between
                        // measurement cycles in "idle" with a target set).
                        visible: bleScanner.connectedAddress.length > 0
                        Layout.preferredHeight: 72
                        Layout.preferredWidth: 330
                        font.pixelSize: 32
                        font.bold: true
                        onClicked: {
                            root.pendingAddress = ""
                            bleScanner.disconnectDevice()
                        }
                        background: Rectangle {
                            radius: 8
                            color: parent.pressed ? "#991b1b" : "#dc2626"
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
                        // A bonded peer never shows the six digits again — bluez
                        // re-encrypts from the stored LTK and skips SMP phase 2
                        // entirely. Dropping the bond is the only way to exercise
                        // the comparison a second time, so the host side of that
                        // gets a button here (the watch has its own).
                        text: "Clear All Pairings"
                        Layout.preferredHeight: 72
                        Layout.preferredWidth: 280
                        font.pixelSize: 28
                        font.bold: true
                        onClicked: clearAllConfirm.open()
                        background: Rectangle {
                            radius: 8
                            color: parent.pressed ? "#7c2d12" : "#9a3412"
                        }
                        contentItem: Text {
                            text: parent.text
                            color: "#ffffff"
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        text: {
                            if (root.pendingAddress.length > 0)
                                return "○ Pairing: " + root.pendingAddress
                            if (bleScanner.connectedAddress.length === 0)
                                return root.lastResult.length > 0
                                       ? root.lastResult
                                       : bleScanner.devices.length + " device" +
                                         (bleScanner.devices.length === 1 ? "" : "s")
                            var name = bleScanner.connectedName.length > 0
                                       ? bleScanner.connectedName : bleScanner.connectedAddress
                            switch (bleScanner.connectionState) {
                            case "streaming":  return "● Streaming: " + name
                            case "connected":  return "● Connected: " + name
                            case "connecting": return "○ Connecting: " + name
                            default:           return "○ Waiting: " + name
                            }
                        }
                        color: {
                            if (root.pendingAddress.length > 0) return "#3b82f6"
                            if (bleScanner.connectedAddress.length === 0)
                                return root.lastResult.length > 0 ? root.lastResultColor
                                                                  : "#9ca3af"
                            switch (bleScanner.connectionState) {
                            case "streaming":  return "#10b981"
                            case "connected":  return "#10b981"
                            case "connecting": return "#f59e0b"
                            default:           return "#f59e0b"
                            }
                        }
                        font.pixelSize: 28
                        font.bold: bleScanner.connectedAddress.length > 0 ||
                                   root.lastResult.length > 0
                    }
                }

                // ── Header row for the list ────────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 64
                    color: "#262626"
                    radius: 6
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        Text {
                            text: "Device Name"
                            color: "#9ca3af"
                            font.pixelSize: 28
                            font.bold: true
                            Layout.fillWidth: true
                        }
                        Text {
                            text: "Address"
                            color: "#9ca3af"
                            font.pixelSize: 28
                            font.bold: true
                            Layout.preferredWidth: 320
                        }
                    }
                }

                // ── Device list — tap to pair ─────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: "#111111"
                    radius: 6
                    border.color: "#262626"
                    border.width: 1
                    clip: true

                    ListView {
                        id: list
                        anchors.fill: parent
                        anchors.margins: 6
                        model: bleScanner.devices
                        spacing: 4
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar { active: true }

                        delegate: Rectangle {
                            id: row
                            width: ListView.view.width
                            height: 88
                            radius: 6

                            readonly property bool isConnected:
                                bleScanner.connectedAddress === modelData.address &&
                                (bleScanner.connectionState === "connected" ||
                                 bleScanner.connectionState === "streaming")
                            readonly property bool isConnecting:
                                bleScanner.connectedAddress === modelData.address &&
                                bleScanner.connectionState === "connecting"
                            readonly property bool pairing:
                                root.pendingAddress.length > 0 &&
                                root.pendingAddress === modelData.address

                            color: rowHover.hovered ? "#1f2937"
                                 : (isConnected ? "#064e3b"
                                 : (pairing ? "#1e3a8a"
                                 : (index % 2 === 0 ? "#1a1a1a" : "#161616")))

                            HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                // Locked only while the pair handshake is in
                                // flight or the link is up. A row merely sitting
                                // in "connecting" stays re-tappable.
                                enabled: !row.isConnected && !row.pairing
                                onTapped: {
                                    root.lastResult = ""
                                    root.pendingAddress = modelData.address
                                    bleScanner.pairDevice(modelData.address)
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 14
                                spacing: 12

                                Text {
                                    text: modelData.name && modelData.name.length > 0
                                          ? modelData.name : "(unknown)"
                                    color: "#ffffff"
                                    font.pixelSize: 32
                                    font.bold: row.isConnected
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: modelData.address
                                    color: "#9ca3af"
                                    font.pixelSize: 28
                                    font.family: "monospace"
                                    Layout.preferredWidth: 310
                                }
                                Rectangle {
                                    Layout.preferredWidth: 230
                                    Layout.preferredHeight: 52
                                    radius: 26
                                    color: row.pairing ? "#3b82f6"
                                         : row.isConnected ? "#10b981"
                                         : row.isConnecting ? "#f59e0b"
                                         : "#374151"
                                    Text {
                                        anchors.centerIn: parent
                                        text: row.pairing ? "Pairing…"
                                            : row.isConnected
                                              ? (bleScanner.connectionState === "streaming"
                                                 ? "Streaming" : "Connected")
                                            : row.isConnecting ? "Connecting…"
                                            : "Tap to pair"
                                        color: "#ffffff"
                                        font.pixelSize: 24
                                        font.bold: true
                                    }
                                }
                            }
                        }

                        // Placeholder when empty
                        Text {
                            anchors.centerIn: parent
                            visible: list.count === 0
                            text: bleScanner.scanning
                                  ? "Searching for nearby BLE devices…"
                                  : "Press \"Start Scan\" to discover nearby BLE devices."
                            color: "#6b7280"
                            font.pixelSize: 32
                        }
                    }
                }
            }
        }
    }

    // ─── Clear-all confirmation popup ───────────────────────────
    Popup {
        id: clearAllConfirm
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        width: 560
        height: 280
        // Same reason as Main.qml's pairing dialog: anchor to the window-wide
        // overlay, not to the header-shifted content item, or the visible frame
        // and the touch hit-box land in different coordinate systems.
        parent: Overlay.overlay
        anchors.centerIn: Overlay.overlay

        background: Rectangle {
            color: "#111827"
            radius: 12
            border.color: "#9a3412"
            border.width: 2
        }
        Overlay.modal: Rectangle { color: "#CC000000" }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 16
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Clear All Pairing Records"
                color: "#ffffff"
                font.pixelSize: 30
                font.bold: true
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "This removes all Bluetooth pairings stored on the host. Removed devices must be paired again. Continue?"
                color: "#cbd5e1"
                font.pixelSize: 20
            }
            Item { Layout.fillHeight: true }
            RowLayout {
                Layout.fillWidth: true
                spacing: 16
                Button {
                    text: "Cancel"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 60
                    font.pixelSize: 26
                    onClicked: clearAllConfirm.close()
                    background: Rectangle { radius: 8; color: parent.pressed ? "#475569" : "#334155" }
                    contentItem: Text { text: parent.text; color: "#ffffff"; font: parent.font
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    text: "Clear"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 60
                    font.pixelSize: 26
                    font.bold: true
                    onClicked: {
                        bleScanner.clearAllPairings()
                        root.pendingAddress = ""
                        root.lastResult = "All pairing records cleared"
                        root.lastResultColor = "#f97316"
                        clearAllConfirm.close()
                    }
                    background: Rectangle { radius: 8; color: parent.pressed ? "#7c2d12" : "#9a3412" }
                    contentItem: Text { text: parent.text; color: "#ffffff"; font: parent.font
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter }
                }
            }
        }
    }

    // The six-digit confirmation dialog is the global Popup in Main.qml
    // (ApplicationWindow level).
}
