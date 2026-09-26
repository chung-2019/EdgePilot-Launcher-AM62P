import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property string deviceNameZh: ""
    property string deviceNameEn: ""
    property bool   connected: true

    color: "#1a1a1a"
    radius: 8
    border.width: 1
    border.color: "#333333"
    implicitHeight: 170

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 28
        anchors.rightMargin: 28
        spacing: 20

        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            spacing: 8

            Text {
                text: root.deviceNameZh
                color: "#ffffff"
                font.pixelSize: 32
                font.bold: true
            }
            Text {
                text: root.deviceNameEn
                color: "#9ca3af"
                font.pixelSize: 22
            }
        }

        Item { Layout.fillWidth: true }

        Row {
            Layout.alignment: Qt.AlignVCenter
            spacing: 10

            Rectangle {
                width: 14
                height: 14
                radius: 7
                color: root.connected ? "#00ff00" : "#666666"
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.connected ? "Connected" : "Offline"
                color: root.connected ? "#00ff00" : "#9ca3af"
                font.pixelSize: 22
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
