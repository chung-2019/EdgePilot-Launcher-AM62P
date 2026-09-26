import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    color: "#0a0a0a"

    // Emitted when a card is tapped — Main.qml wires this to navigateTo(idx).
    signal toolRequested(int pageIndex)

    component BleToolCard: Rectangle {
        id: card
        property string title: ""
        property string subtitle: ""
        property int    targetIndex: -1
        signal clicked()

        Layout.fillWidth: true
        Layout.fillHeight: true
        radius: 14
        color: hover.hovered ? "#262626" : "#1a1a1a"
        border.color: hover.hovered ? "#0891b2" : "#333333"
        border.width: 1

        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: card.clicked() }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 32
            spacing: 18

            // Icon tile (matches existing BLE page header style)
            Rectangle {
                Layout.alignment: Qt.AlignLeft
                Layout.preferredWidth: 72
                Layout.preferredHeight: 72
                radius: 16
                color: "#262626"
                Image {
                    anchors.centerIn: parent
                    width: 40; height: 40
                    source: "qrc:/assets/icons/bluetooth.svg"
                    sourceSize: Qt.size(80, 80)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                }
            }

            Text {
                text: card.title
                color: "#ffffff"
                font.pixelSize: 36
                font.bold: true
            }
            Text {
                text: card.subtitle
                color: "#9ca3af"
                font.pixelSize: 20
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            Item { Layout.fillHeight: true }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 48
        spacing: 32

        // ── Header ─────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 18

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
                    text: "BLE Tools"
                    color: "#ffffff"
                    font.pixelSize: 56
                    font.bold: true
                }
                Text {
                    text: "Select a BLE utility · CC3351 · hci0"
                    color: "#9ca3af"
                    font.pixelSize: 28
                }
            }
            Item { Layout.fillWidth: true }
        }

        // ── Tool grid (add more cards here as new BLE utilities land) ──
        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 3
            rowSpacing: 24
            columnSpacing: 24

            BleToolCard {
                title: "BLE Scan"
                subtitle: "6-digit numeric comparison · Apollo510b"
                targetIndex: 7
                onClicked: root.toolRequested(targetIndex)
            }
        }
    }
}
