import QtQuick
import QtQuick.Layouts
import QtQuick.Effects

Rectangle {
    id: root

    property string name: ""
    property string unit: ""
    property string valueText: ""
    property color  accentColor: "#00ff00"
    property real   minVal: 0
    property real   maxVal: 100
    property real   currentVal: 0
    property bool   showRangeBar: true
    property string iconSource: ""
    property int    valuePixelSize: 48

    implicitWidth: 220
    implicitHeight: 120
    color: "#1a1a1a"
    border.width: 1
    border.color: "#333333"
    radius: 8

    readonly property real ratio: {
        if (maxVal <= minVal) return 0
        return Math.max(0, Math.min(1, (currentVal - minVal) / (maxVal - minVal)))
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        anchors.topMargin: 12
        anchors.bottomMargin: 12
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: root.name
                color: "#ffffff"
                font.pixelSize: 14
                font.bold: true
            }
            Item { Layout.fillWidth: true }
            Text {
                text: root.unit
                color: "#9ca3af"
                font.pixelSize: 12
                visible: text !== ""
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12

            Item {
                visible: root.iconSource !== ""
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                Layout.alignment: Qt.AlignVCenter

                Image {
                    id: iconImg
                    anchors.fill: parent
                    source: root.iconSource
                    sourceSize: Qt.size(44, 44)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    visible: false
                }
                MultiEffect {
                    anchors.fill: iconImg
                    source: iconImg
                    colorization: 1.0
                    colorizationColor: root.accentColor
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                horizontalAlignment: Text.AlignRight
                text: root.valueText
                color: root.accentColor
                font.pixelSize: root.valuePixelSize
                font.bold: true
            }
        }

        Item {
            visible: root.showRangeBar
            Layout.fillWidth: true
            Layout.preferredHeight: 24

            Text {
                id: minLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -4
                text: root.minVal.toString()
                color: "#9ca3af"
                font.pixelSize: 11
            }
            Text {
                id: maxLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -4
                text: root.maxVal.toString()
                color: "#9ca3af"
                font.pixelSize: 11
            }
            Rectangle {
                id: track
                anchors.left: minLabel.right
                anchors.right: maxLabel.left
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -4
                height: 3
                color: "#3a3a3a"
                radius: 2

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * root.ratio
                    color: root.accentColor
                    radius: 2
                }
            }
            Text {
                anchors.top: track.bottom
                anchors.topMargin: 1
                x: track.x + track.width * root.ratio - width / 2
                text: "▲"
                color: root.accentColor
                font.pixelSize: 9
            }
        }
    }
}
