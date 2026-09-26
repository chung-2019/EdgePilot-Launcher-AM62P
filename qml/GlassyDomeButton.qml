import QtQuick
import QtQuick.Effects

// 3D glossy dome play button.
// Visual layers (back → front):
//   1. Coloured outer dome with vertical gradient
//   2. Diagonal glossy white overlay
//   3. Top-left specular highlight
//   4. White inner disc with coloured play glyph
// Plus a coloured drop shadow (MultiEffect) tinted from the dome colour.
Item {
    id: root

    property color  domeColor: "#1976D2"
    property string glyph: "▶"
    property real   glyphSize: 0
    signal clicked()

    implicitWidth: 142
    implicitHeight: 142

    readonly property real diameter: Math.min(132, Math.min(width, height) - 8)
    readonly property real innerRatio: 0.62

    readonly property color shadowTint:
        Qt.rgba(domeColor.r * 0.85, domeColor.g * 0.85, domeColor.b * 0.85, 0.45)

    Item {
        id: composite
        width: root.diameter
        height: root.diameter
        anchors.centerIn: parent
        scale: pressArea.pressed ? 0.94 : 1.0
        Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

        // 1. Coloured outer dome
        Rectangle {
            id: dome
            anchors.fill: parent
            radius: width / 2
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: Qt.lighter(root.domeColor, 1.45) }
                GradientStop { position: 1.0; color: Qt.darker(root.domeColor, 1.10) }
            }
            border.color: Qt.darker(root.domeColor, 1.35)
            border.width: 1
        }

        // 2. Diagonal glossy overlay
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            opacity: 0.42
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0;  color: "#58FFFFFF" }
                GradientStop { position: 0.42; color: "#08FFFFFF" }
                GradientStop { position: 1.0;  color: "#10000000" }
            }
        }

        // 3. Top-left specular highlight
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.topMargin: parent.height * 0.12
            anchors.leftMargin: parent.width * 0.17
            width: parent.width * 0.30
            height: parent.height * 0.24
            radius: height / 2
            opacity: 0.34
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: "#F8FFFFFF" }
                GradientStop { position: 1.0; color: "#00FFFFFF" }
            }
        }

        // 4. White inner disc + coloured play glyph
        Rectangle {
            id: innerDisc
            anchors.centerIn: parent
            width: parent.width * root.innerRatio
            height: parent.height * root.innerRatio
            radius: width / 2
            color: "white"
            border.color: "#EBEEF3"
            border.width: 1
            antialiasing: true

            Text {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: 2  // optical nudge for ▶
                text: root.glyph
                font.pixelSize: root.glyphSize > 0
                                ? root.glyphSize
                                : Math.round(innerDisc.width * 0.50)
                font.bold: true
                color: Qt.darker(root.domeColor, 1.05)
            }
        }

        // Coloured drop shadow — tinted from the dome colour for a premium look
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: root.shadowTint
            shadowBlur: 0.85
            shadowVerticalOffset: 12
            shadowHorizontalOffset: 0
            autoPaddingEnabled: true
        }
    }

    MouseArea {
        id: pressArea
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
