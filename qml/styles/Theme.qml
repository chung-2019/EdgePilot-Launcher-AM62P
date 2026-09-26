pragma Singleton
import QtQuick

QtObject {
    readonly property color bgBase:        "#0a0a0a"
    readonly property color bgCard:        "#111111"

    readonly property color navIdleBg:     "transparent"
    readonly property color navHoverBg:    "#1a1a1a"
    readonly property color navCheckedBg:  "#2563eb"
    readonly property color navIdleFg:     "#9ca3af"
    readonly property color navCheckedFg:  "#ffffff"

    readonly property int navItemHeight:   44
    readonly property int navItemRadius:   8
    readonly property int navIconSize:     22
    readonly property int navItemHPad:     14
    readonly property int navItemSpacing:  12

    readonly property int sidebarWidth:    220
    readonly property int sidebarVSpacing: 8
}
