import QtQuick
import QtQuick.Layouts
import QtQuick.Effects

Rectangle {
    id: root

    property string deviceType: ""
    property string zhName: ""
    property string enName: ""
    property string iconSource: ""
    property color  accentColor: "#2563eb"
    signal launch()

    color: "#1a1a1a"
    radius: 8
    border.width: 1
    border.color: "#333333"

    // Auto-pick contrast text color for the filled button based on luminance.
    readonly property color buttonTextColor: {
        var c = root.accentColor
        var y = c.r * 0.299 + c.g * 0.587 + c.b * 0.114
        return y > 0.55 ? "#0a0a0a" : "#ffffff"
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 22
        spacing: 18

        // Icon + name block (centered)
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Column {
                anchors.centerIn: parent
                spacing: 14

                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 84
                    height: 84

                    Image {
                        id: iconImg
                        anchors.fill: parent
                        source: root.iconSource
                        sourceSize: Qt.size(168, 168)
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
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.zhName
                    color: "#ffffff"
                    font.pixelSize: 22
                    font.bold: true
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.enName
                    color: "#9ca3af"
                    font.pixelSize: 13
                }
            }
        }

        // Full-width flat launch button
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            radius: 6
            color: btnHover.hovered ? Qt.darker(root.accentColor, 1.25) : root.accentColor

            HoverHandler { id: btnHover; cursorShape: Qt.PointingHandCursor }

            Text {
                anchors.centerIn: parent
                text: "Launch Monitor"
                color: root.buttonTextColor
                font.pixelSize: 14
                font.bold: true
                font.letterSpacing: 1
            }

            TapHandler { onTapped: root.launch() }
        }
    }
}
