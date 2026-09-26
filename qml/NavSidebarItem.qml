import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import "styles" as Styles

Item {
    id: root

    property string iconSource: ""
    property string label: ""
    property bool   checked: false

    // Icon only, centred — what the collapsed 56 px nav rail shows. The label
    // is not elided down to nothing but dropped outright: at rail width there
    // is room for the icon and nothing else, and an item that renders "Sy…"
    // reads as broken rather than deliberate.
    property bool compact: false

    signal clicked()

    implicitHeight: Styles.Theme.navItemHeight
    implicitWidth: compact ? Styles.Theme.navItemHeight
                           : Styles.Theme.sidebarWidth

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }

    Rectangle {
        anchors.fill: parent
        radius: Styles.Theme.navItemRadius
        color: root.checked     ? Styles.Theme.navCheckedBg
             : hover.hovered    ? Styles.Theme.navHoverBg
             :                    Styles.Theme.navIdleBg

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: root.compact ? 0 : Styles.Theme.navItemHPad
            anchors.rightMargin: root.compact ? 0 : Styles.Theme.navItemHPad
            spacing: root.compact ? 0 : Styles.Theme.navItemSpacing

            Item {
                Layout.preferredWidth: Styles.Theme.navIconSize
                Layout.preferredHeight: Styles.Theme.navIconSize

                // With the label hidden the layout has one visible child, so
                // AlignHCenter is what centres the icon in the rail.
                Layout.alignment: root.compact
                                  ? (Qt.AlignHCenter | Qt.AlignVCenter)
                                  : Qt.AlignVCenter

                Image {
                    id: iconSrc
                    anchors.fill: parent
                    source: root.iconSource
                    sourceSize: Qt.size(parent.width * 2, parent.height * 2)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    visible: false
                }

                MultiEffect {
                    anchors.fill: iconSrc
                    source: iconSrc
                    colorization: 1.0
                    colorizationColor: root.checked
                                       ? Styles.Theme.navCheckedFg
                                       : Styles.Theme.navIdleFg
                }
            }

            Text {
                visible: !root.compact
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: root.label
                font.pixelSize: 20
                font.bold: root.checked
                color: root.checked ? Styles.Theme.navCheckedFg
                                    : Styles.Theme.navIdleFg
                elide: Text.ElideRight
            }
        }
    }

    TapHandler {
        onTapped: root.clicked()
    }
}
