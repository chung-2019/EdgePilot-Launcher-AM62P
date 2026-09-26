import QtQuick
import QtQuick.Effects

Rectangle {
    id: root

    property string iconSource: ""
    property string label: ""
    signal clicked()

    implicitHeight: 32
    implicitWidth: contentRow.implicitWidth + 24

    radius: 6
    border.width: 1
    border.color: "#e5e7eb"
    color: hover.hovered ? "#f3f4f6" : "#ffffff"

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }

    Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: 6

        Item {
            width: 14
            height: 14
            anchors.verticalCenter: parent.verticalCenter

            Image {
                id: iconSrc
                anchors.fill: parent
                source: root.iconSource
                sourceSize: Qt.size(28, 28)
                fillMode: Image.PreserveAspectFit
                smooth: true
                visible: false
            }

            MultiEffect {
                anchors.fill: iconSrc
                source: iconSrc
                colorization: 1.0
                colorizationColor: "#374151"
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            font.pixelSize: 13
            font.bold: true
            color: "#374151"
        }
    }

    TapHandler {
        onTapped: root.clicked()
    }
}
