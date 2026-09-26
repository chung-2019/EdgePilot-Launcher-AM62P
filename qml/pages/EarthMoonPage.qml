import QtQuick
import QtQuick.Layouts

// Sidebar "Earth 3D" page — Qt Quick 3D globe with the Moon in orbit.
//
// This file deliberately does NOT import QtQuick3D. The 3D scene is pulled in
// through a Loader so that a Qt build without the Quick3D module degrades to
// a notice instead of taking the whole launcher down at startup. (The AM62P
// rootfs has Quick3D 6.12; the cross-compile sysroot does not ship its dev
// files, which is why the whole feature is QML-only and links nothing new.)
//
// The simulation clock lives here rather than in the scene: pause / speed /
// reset then keep their state across a scene reload, and they still work
// while the scene is still loading its textures.
Rectangle {
    id: root
    color: "#04070e"

    // ── Simulation state ────────────────────────────────────────────────
    property bool running: true
    property real timeScale: 1.0

    // Earth spin at mission time zero, chosen so the launch site faces the
    // default camera — otherwise the rocket lifts off from the far side of the
    // globe and the first thing the page shows is the Atlantic.
    //
    // Solved against the default rig (camYaw 20, camPitch -12) and the Earth's
    // node chain, tilt(z = -23.4) -> spin(y = angle): at 252.7 Taiwan sits
    // 4.8° off the camera axis. The residual is the axial tilt against the
    // camera's pitch and cannot be removed by spinning alone.
    //
    // Tied to the default camera angles — change those and this needs
    // re-solving.
    readonly property real earthStartAngle: 252.7

    property real earthRotationAngle: earthStartAngle
    property real moonOrbitAngle: 0
    property real moonRotationAngle: 0

    // Scene angles as they were when the current mission lap began.
    //
    // The mission derives its orbit insertion point from these — insertion has
    // to sit a fixed angle downrange of the launch pad, and the pad's position
    // depends on when the lap started. Captured once per lap rather than
    // derived from the live angles, because the clock assigns those separately
    // and anything reading the pair mid-update sees an inconsistent state.
    property real earthAngleAtLapStart: earthStartAngle
    property real moonAngleAtLapStart: 0

    // Clouds off by default: the cloud shell washes out the continents, and the
    // launch site is a lot easier to pick out without it. Toggle in the menu.
    property bool cloudsVisible: false

    property bool orbitLineVisible: true
    property bool starsVisible: true

    // ── Mission state ───────────────────────────────────────────────────
    //
    // Taiwan -> Earth orbit -> Moon -> landing -> return -> Taiwan, then round
    // again. 102 s per cycle, the same budget the three.js reference uses, so
    // the phase table in MissionController keeps its pacing.
    property bool missionVisible: true

    // Trajectory lines off by default: with all eight orbits and seven dotted
    // curves drawn at once the vehicles get lost in them. Toggle in the menu.
    property bool missionPathsVisible: false

    property bool followVehicle: false

    property real missionElapsed: 0
    readonly property real missionDuration: 102
    readonly property real missionTime: missionElapsed / missionDuration

    // Corrects for Qt Quick 3D's "#Sphere" putting longitude 0 at +Z where
    // three.js puts it at +X. -90 was confirmed by rendering the globe on the
    // EVM: it lands the pad on Taiwan. Degrees, positive eastward.
    property real launchSiteLongitudeOffset: -90

    readonly property string missionPhaseName:
        sceneLoader.item ? sceneLoader.item.missionPhaseName : ""

    // ── Settings menu ───────────────────────────────────────────────────
    //
    // The controls used to be a permanent 208 x 500 panel pinned to the right
    // edge, which ate a sixth of the width and most of the height of a view
    // whose whole point is the picture. They now live in a bar that pulls down
    // from the top edge and is dismissed by touching anywhere else.
    property bool menuOpen: false

    // ── Pull-to-reveal state ────────────────────────────────────────────
    //
    // NOT currently driven by anything. The top-bar pull-down that used to set
    // these now belongs to the lock screen, on every page — see the lock
    // screen block in Main.qml. The bar is opened from the grip at the top of
    // this page instead.
    //
    // Kept rather than deleted because menuReveal still reads them and because
    // restoring the follow-the-finger pull is a matter of pointing a handler
    // back at them. With menuDragging permanently false, menuReveal collapses
    // to "open or not" and the Behaviors below are always live, which is
    // exactly what a tap-driven menu wants.
    property bool menuDragging: false
    property real menuDragProgress: 0      // 0..1 while dragging

    // How far out the bar is, whatever the reason. One value for the bar's
    // position and for everything that fades behind it.
    readonly property real menuReveal:
        menuDragging ? menuDragProgress : (menuOpen ? 1 : 0)

    // Display speeds, not real time: ~20 s per Earth day, ~40 s per lunar
    // orbit, ~90 s per lunar rotation.
    readonly property real earthDegPerSecond: 18.0

    // 9°/s, down from 36.
    //
    // Two things were wrong with 36. It put ten lunar orbits inside one 102 s
    // mission — the probe crossed to a Moon that had lapped the Earth several
    // times on the way. And because the whole mission frame hangs off the
    // Moon's orbit pivot (that is what keeps the transfer arc pointed at the
    // Moon), everything in Earth orbit was being swept round at 36°/s too: the
    // launcher disappeared behind the planet within a few seconds of lift-off
    // and the fairing came off out of sight.
    //
    // At 9°/s the mission spans ~2.5 lunar orbits and Earth-orbit events stay
    // in view long enough to read. The reference uses 1.95°/s.
    readonly property real moonOrbitDegPerSecond: 9.0

    readonly property real moonSpinDegPerSecond: 4.0

    readonly property bool sceneReady: sceneLoader.status === Loader.Ready
    readonly property bool sceneFailed: sceneLoader.status === Loader.Error

    // StackLayout keeps every page instantiated, so the 3D scene must not be
    // built until this page is actually opened once — otherwise ~2 MB of
    // textures get decoded and uploaded during launcher startup for a page
    // the operator may never visit.
    property bool everShown: false

    onVisibleChanged: {
        if (visible)
            everShown = true
        else
            menuOpen = false      // never come back to a page with a menu open
    }

    // onVisibleChanged only fires on a change, so a page that is already
    // visible when it is created would never set everShown and the scene would
    // never load. That does not happen inside the launcher's StackLayout today,
    // because Earth 3D is not the startup page — but it is one config change
    // away from being true.
    Component.onCompleted: if (visible) everShown = true

    function wrapAngle(angle) {
        const a = angle % 360
        return a < 0 ? a + 360 : a
    }

    function resetSimulation() {
        earthRotationAngle = earthStartAngle
        moonOrbitAngle = 0
        moonRotationAngle = 0
        missionElapsed = 0

        earthAngleAtLapStart = earthStartAngle
        moonAngleAtLapStart = 0
    }

    // FrameAnimation is driven by the render loop, so the step matches the
    // frame that is about to be drawn — a 16 ms QTimer would drift against
    // vsync and show up as judder on the orbit.
    FrameAnimation {
        id: clock

        running: root.visible && root.running && root.sceneReady

        onTriggered: {
            // Cap the step so a stall (page switch, texture upload) cannot
            // teleport the moon half way round its orbit.
            const dt = Math.min(frameTime, 0.05) * root.timeScale

            root.earthRotationAngle =
                root.wrapAngle(root.earthRotationAngle
                               + root.earthDegPerSecond * dt)
            root.moonOrbitAngle =
                root.wrapAngle(root.moonOrbitAngle
                               + root.moonOrbitDegPerSecond * dt)
            root.moonRotationAngle =
                root.wrapAngle(root.moonRotationAngle
                               + root.moonSpinDegPerSecond * dt)

            // Mission clock wraps to start the next cycle. MissionController's
            // final phase has already stowed the probe and put it back on the
            // pad, so the wrap needs no explicit reset step.
            let elapsed = root.missionElapsed + dt
            if (elapsed >= root.missionDuration) {
                elapsed -= root.missionDuration

                // New lap: record where the bodies are now. The mission reads
                // these to place the orbit insertion point downrange of the
                // pad, and each lap starts with the Earth 36° further round —
                // the mission is 102 s and the Earth's day is 20 s, so ten laps
                // pass before the geometry repeats.
                root.earthAngleAtLapStart = root.earthRotationAngle
                root.moonAngleAtLapStart = root.moonOrbitAngle
            }
            root.missionElapsed = elapsed
        }
    }

    // ── 3D scene ────────────────────────────────────────────────────────
    Loader {
        id: sceneLoader

        anchors.fill: parent
        active: root.everShown
        asynchronous: true
        visible: root.sceneReady
        source: "qrc:/qml/earth3d/EarthMoonScene.qml"

        onLoaded: {
            item.earthRotationAngle = Qt.binding(() => root.earthRotationAngle)
            item.moonOrbitAngle     = Qt.binding(() => root.moonOrbitAngle)
            item.moonRotationAngle  = Qt.binding(() => root.moonRotationAngle)
            item.cloudsVisible      = Qt.binding(() => root.cloudsVisible)
            item.orbitLineVisible   = Qt.binding(() => root.orbitLineVisible)
            item.starsVisible       = Qt.binding(() => root.starsVisible)

            item.missionTime        = Qt.binding(() => root.missionTime)

            // The mission predicts where the pad will be at the end of the
            // ascent, so it needs this clock's rates.
            item.missionDuration    = Qt.binding(() => root.missionDuration)
            item.earthDegPerSecond  = Qt.binding(() => root.earthDegPerSecond)
            item.moonOrbitDegPerSecond =
                Qt.binding(() => root.moonOrbitDegPerSecond)
            item.earthAngleAtLapStart =
                Qt.binding(() => root.earthAngleAtLapStart)
            item.moonAngleAtLapStart =
                Qt.binding(() => root.moonAngleAtLapStart)

            item.missionVisible     = Qt.binding(() => root.missionVisible)
            item.missionPathsVisible = Qt.binding(() => root.missionPathsVisible)
            item.followVehicle      = Qt.binding(() => root.followVehicle)
            item.launchSiteLongitudeOffset =
                Qt.binding(() => root.launchSiteLongitudeOffset)
        }
    }

    // Loading placeholder
    Text {
        anchors.centerIn: parent
        visible: sceneLoader.active && sceneLoader.status === Loader.Loading
        text: "Loading 3D scene…"
        color: "#64748b"
        font.pixelSize: 16
    }

    // Fallback for a Qt build without the Quick3D module (e.g. the Windows
    // simulator). The launcher keeps working; only this page is empty.
    Rectangle {
        anchors.centerIn: parent
        visible: root.sceneFailed
        width: fallbackColumn.implicitWidth + 56
        height: fallbackColumn.implicitHeight + 44
        radius: 12
        color: "#111827"
        border.color: "#334155"
        border.width: 1

        ColumnLayout {
            id: fallbackColumn
            anchors.centerIn: parent
            spacing: 10

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Qt Quick 3D is not available in this build"
                color: "#f8fafc"
                font.pixelSize: 18
                font.bold: true
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "The 3D Earth scene needs the QtQuick3D QML module at runtime.\n"
                      + "It is present on the AM62P EVM rootfs (Qt 6.12)."
                color: "#94a3b8"
                font.pixelSize: 14
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    // ── Header overlay ──────────────────────────────────────────────────
    //
    // Fades back while the menu is down, so the two never fight for the same
    // corner.
    ColumnLayout {
        id: header

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 28
        spacing: 4

        opacity: 1.0 - root.menuReveal * 0.88
        Behavior on opacity {
            enabled: !root.menuDragging
            NumberAnimation { duration: 180 }
        }

        Text {
            text: "Earth 3D"
            color: "#ffffff"
            font.pixelSize: 30
            font.bold: true
            style: Text.Outline
            styleColor: "#8004070e"
        }
        Text {
            text: "Qt Quick 3D · Taiwan–Moon round-trip mission on the AM62P GPU"
            color: "#94a3b8"
            font.pixelSize: 15
        }

        // ── Mission phase readout ───────────────────────────────────────
        Rectangle {
            Layout.topMargin: 10

            visible: root.sceneReady && root.missionVisible

            implicitWidth: phaseRow.implicitWidth + 26
            implicitHeight: 34
            radius: 17
            color: "#cc0b1320"
            border.color: "#2b3444"
            border.width: 1

            RowLayout {
                id: phaseRow

                anchors.centerIn: parent
                spacing: 9

                // Live indicator: steady while coasting, pulsing while the
                // mission is running.
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    width: 8
                    height: 8
                    radius: 4
                    color: "#f97316"

                    SequentialAnimation on opacity {
                        running: root.running && root.sceneReady
                        loops: Animation.Infinite

                        NumberAnimation { to: 0.25; duration: 620 }
                        NumberAnimation { to: 1.0; duration: 620 }
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: root.missionPhaseName
                    color: "#e2e8f0"
                    font.pixelSize: 15
                    font.bold: true
                }

                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    width: 1
                    height: 15
                    color: "#334155"
                }

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: Math.round(root.missionTime * 100) + "%"
                    color: "#94a3b8"
                    font.pixelSize: 14
                }
            }
        }
    }

    // ── Menu controls ───────────────────────────────────────────────────
    //
    // Sized from their own text rather than stretched by the layout, because
    // the bar lays them out in rows now, not in a narrow column.
    component PanelButton: Rectangle {
        id: button

        property string label: ""
        // null = plain action button, true/false = on/off toggle
        property var toggled: null

        signal activated()

        readonly property bool isOn: toggled === true

        implicitWidth: buttonLabel.implicitWidth + 30
        implicitHeight: 36
        radius: 8

        color: !enabled ? "#161b22"
                        : (tap.pressed ? "#1d4ed8"
                                       : (isOn ? "#1e3a8a" : "#161b22"))
        border.width: 1
        border.color: isOn ? "#3b82f6" : "#2b3444"

        Text {
            id: buttonLabel

            anchors.centerIn: parent
            text: button.label
            color: button.enabled ? (button.isOn ? "#dbeafe" : "#cbd5e1")
                                  : "#475569"
            font.pixelSize: 14
            font.bold: true
        }

        HoverHandler {
            cursorShape: button.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        }

        TapHandler {
            id: tap

            // ReleaseWithinBounds, not the default DragThreshold.
            //
            // DragThreshold only takes a PASSIVE grab on press, which does not
            // consume the event — so the press carried on down to the dismiss
            // layer behind the bar, that took the exclusive grab, and every
            // button press closed the menu instead of doing its job.
            // ReleaseWithinBounds takes the exclusive grab on press, so the
            // event stops here.
            gesturePolicy: TapHandler.ReleaseWithinBounds

            onTapped: button.activated()
        }
    }

    // Inline components get their own scope, so `current` is passed in from
    // the instantiation site rather than read off root.timeScale directly.
    component SpeedButton: Rectangle {
        id: speedButton

        property real value: 1.0
        property real current: 1.0

        signal picked()

        readonly property bool isOn: Math.abs(current - value) < 0.001

        implicitWidth: 48
        implicitHeight: 36
        radius: 8

        color: speedTap.pressed ? "#1d4ed8" : (isOn ? "#1e3a8a" : "#161b22")
        border.width: 1
        border.color: isOn ? "#3b82f6" : "#2b3444"

        Text {
            anchors.centerIn: parent
            text: speedButton.value + "×"
            color: speedButton.isOn ? "#dbeafe" : "#94a3b8"
            font.pixelSize: 13
            font.bold: true
        }

        HoverHandler { cursorShape: Qt.PointingHandCursor }

        TapHandler {
            id: speedTap

            // See PanelButton: the exclusive grab is what stops the press
            // reaching the dismiss layer.
            gesturePolicy: TapHandler.ReleaseWithinBounds

            onTapped: speedButton.picked()
        }
    }

    component GroupLabel: Text {
        color: "#64748b"
        font.pixelSize: 11
        font.bold: true
        font.letterSpacing: 1.4
    }

    component GroupDivider: Rectangle {
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        Layout.topMargin: 2
        Layout.bottomMargin: 2
        color: "#233046"
    }

    // ── Grip ────────────────────────────────────────────────────────────
    //
    // Tap only. The pull-down itself now lives on the top bar (Main.qml), so
    // that the gesture starts at the display's real top edge — a strip inside
    // the page starts 64 px lower and does not read as an edge swipe.
    //
    // Moving the drag out has a second benefit: the top of the page is no
    // longer stealing downward drags from the scene's one-finger orbit.
    Item {
        id: pullTab

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: 180
        height: 34
        z: 5

        enabled: root.sceneReady && !root.menuOpen

        // A tap on something that looks like a handle should not do nothing.
        TapHandler {
            onTapped: root.menuOpen = true
        }
    }

    // Grip indicator. The only thing the menu leaves on screen when closed.
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 9
        z: 6

        width: 58
        height: 5
        radius: 2.5
        color: "#4b5768"

        visible: root.sceneReady
        opacity: (1.0 - root.menuReveal) * 0.9
        Behavior on opacity {
            enabled: !root.menuDragging
            NumberAnimation { duration: 160 }
        }
    }

    // ── Dismiss layer ───────────────────────────────────────────────────
    //
    // Only alive while the menu is down. It accepts the press, so the tap that
    // closes the menu does not also spin the globe underneath.
    MouseArea {
        anchors.fill: parent
        z: 8

        enabled: root.menuOpen
        visible: enabled
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onPressed: root.menuOpen = false
    }

    Shortcut {
        sequence: "Escape"
        enabled: root.menuOpen && root.visible
        onActivated: root.menuOpen = false
    }

    // ── Settings bar ────────────────────────────────────────────────────
    Rectangle {
        id: settingsMenu

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        z: 10

        // Tracks menuReveal, so the same expression serves the finger during a
        // pull and the animation on release.
        y: -(height + 8) + (14 + height + 8) * root.menuReveal
        height: menuRow.implicitHeight + 34
        radius: 14

        color: "#f20d1522"
        border.color: "#2f3a4d"
        border.width: 1

        // Off while a finger is on it — the bar has to sit exactly where the
        // finger is, not ease towards it.
        Behavior on y {
            enabled: !root.menuDragging
            NumberAnimation { duration: 230; easing.type: Easing.OutCubic }
        }

        // Push it back up the way it came.
        //
        // Measured off the centroid for the same reason the top-bar pull in
        // Main.qml is: activeTranslation is 0 on the event that activates the
        // handler and is reset again on release, so a swipe delivered in a
        // couple of updates — normal on this page, where touch updates arrive
        // at the frame rate — can leave it 0 for the whole gesture and the
        // swipe-up does nothing.
        //
        // Only alive while the menu is down. When it is up, this bar is parked
        // at y = -(height + 8) — which is not off screen. The page starts 64 px
        // down and nothing clips it, so the closed bar still spans screen rows
        // -44..56 and covers 56 of the top bar's 64 px, right under the title
        // the user aims at. Measured: without this gate BOTH drag handlers
        // activate on a pull-down, and this one can take the grab off the top
        // bar's mid-gesture — that handler then saw 85 px of a 170 px pull.
        // See tools/mission-harness/tst_barbehindtopbar.qml.
        DragHandler {
            target: null
            xAxis.enabled: false
            yAxis.enabled: true

            enabled: root.menuOpen

            readonly property real pushed:
                centroid.scenePosition.y - centroid.scenePressPosition.y

            function closeIfPushedUp() {
                if (active && pushed < -28)
                    root.menuOpen = false
            }

            onActiveChanged: closeIfPushedUp()
            onCentroidChanged: closeIfPushedUp()
        }

        // Swallows presses that land on the bar but miss a button — the gaps
        // between buttons, the group labels, the padding. Without it those
        // reach the dismiss layer behind and close the menu, which feels like
        // a misfire when the user was aiming at a control.
        //
        // Declared before the controls so it sits under them, and left without
        // preventStealing so the drag-up-to-close handler above can still take
        // the grab off it.
        //
        // Gated for the same reason as that handler: while the menu is closed
        // this bar is sitting over the top bar, and an ungated absorber up
        // there swallows presses aimed at the header.
        MouseArea {
            anchors.fill: parent
            enabled: root.menuOpen
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        }

        RowLayout {
            id: menuRow

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            spacing: 18

            // ── Scene
            ColumnLayout {
                spacing: 6

                GroupLabel { text: "SCENE" }

                RowLayout {
                    spacing: 8

                    PanelButton {
                        label: root.running ? "Pause" : "Resume"
                        enabled: root.sceneReady
                        onActivated: root.running = !root.running
                    }

                    PanelButton {
                        label: "Clouds"
                        toggled: root.cloudsVisible
                        enabled: root.sceneReady
                        onActivated: root.cloudsVisible = !root.cloudsVisible
                    }

                    PanelButton {
                        label: "Orbit line"
                        toggled: root.orbitLineVisible
                        enabled: root.sceneReady
                        onActivated: root.orbitLineVisible = !root.orbitLineVisible
                    }

                    PanelButton {
                        label: "Star field"
                        toggled: root.starsVisible
                        enabled: root.sceneReady
                        onActivated: root.starsVisible = !root.starsVisible
                    }
                }
            }

            GroupDivider {}

            // ── Mission
            ColumnLayout {
                spacing: 6

                GroupLabel { text: "MISSION" }

                RowLayout {
                    spacing: 8

                    PanelButton {
                        label: "Mission"
                        toggled: root.missionVisible
                        enabled: root.sceneReady
                        onActivated: {
                            root.missionVisible = !root.missionVisible
                            if (!root.missionVisible)
                                root.followVehicle = false
                        }
                    }

                    PanelButton {
                        label: "Paths"
                        toggled: root.missionPathsVisible
                        enabled: root.sceneReady && root.missionVisible
                        onActivated:
                            root.missionPathsVisible = !root.missionPathsVisible
                    }

                    PanelButton {
                        label: "Follow"
                        toggled: root.followVehicle
                        enabled: root.sceneReady && root.missionVisible
                        onActivated: root.followVehicle = !root.followVehicle
                    }
                }
            }

            GroupDivider {}

            // ── Speed
            ColumnLayout {
                spacing: 6

                GroupLabel { text: "SPEED" }

                RowLayout {
                    spacing: 6

                    SpeedButton {
                        value: 0.5
                        current: root.timeScale
                        onPicked: root.timeScale = value
                    }
                    SpeedButton {
                        value: 1
                        current: root.timeScale
                        onPicked: root.timeScale = value
                    }
                    SpeedButton {
                        value: 2
                        current: root.timeScale
                        onPicked: root.timeScale = value
                    }
                    SpeedButton {
                        value: 4
                        current: root.timeScale
                        onPicked: root.timeScale = value
                    }
                }
            }

            // Takes up whatever is left, so Reset and Close sit on the far edge
            // and the groups stay bunched at the leading edge.
            Item { Layout.fillWidth: true }

            ColumnLayout {
                spacing: 6

                GroupLabel { text: "VIEW" }

                RowLayout {
                    spacing: 8

                    PanelButton {
                        label: "Reset view"
                        enabled: root.sceneReady
                        onActivated: {
                            // Drop tracking first: resetCamera() sets the
                            // default distance, and leaving follow on would
                            // immediately ramp it back to the close framing.
                            root.followVehicle = false

                            if (sceneLoader.item)
                                sceneLoader.item.resetCamera()
                            root.resetSimulation()
                        }
                    }

                    PanelButton {
                        label: "Close"
                        onActivated: root.menuOpen = false
                    }
                }
            }
        }
    }

    // ── Gesture hint ────────────────────────────────────────────────────
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20

        visible: root.sceneReady
        opacity: 1.0 - root.menuReveal
        Behavior on opacity {
            enabled: !root.menuDragging
            NumberAnimation { duration: 180 }
        }

        text: "Pull down from the top bar: settings  ·  Drag: orbit  ·  "
              + "Wheel or pinch: zoom  ·  Right-drag: pan  ·  Double-tap: reset"
        color: "#64748b"
        font.pixelSize: 13
    }
}
