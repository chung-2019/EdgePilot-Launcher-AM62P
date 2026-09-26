import QtQuick
import QtQuick.Effects

Item {
    id: root

    property url iconSource: ""
    property string label: ""
    property color accentColor: "#2196f3"

    implicitWidth: content.implicitWidth
    implicitHeight: 34

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 7

        Item {
            width: 28
            height: 28

            Image {
                id: iconSourceItem
                anchors.fill: parent
                source: root.iconSource
                sourceSize: Qt.size(56, 56)
                fillMode: Image.PreserveAspectFit
                smooth: true
                visible: false
            }

            MultiEffect {
                anchors.fill: iconSourceItem
                source: iconSourceItem
                colorization: 1.0
                colorizationColor: root.accentColor
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: "#ffffff"
            font.pixelSize: 17
            font.bold: true
            font.letterSpacing: 0.5
        }
    }
}
