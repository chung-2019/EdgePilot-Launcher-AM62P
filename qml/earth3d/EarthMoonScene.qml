import QtQuick
import QtQuick3D

// 3D Earth / Moon scene.
//
// Loaded through a Loader from EarthMoonPage.qml. Everything that needs the
// QtQuick3D import lives in this file and its siblings, so a Qt build without
// the Quick3D module only fails to load THIS item — the launcher itself keeps
// running and the page shows a plain fallback notice instead.
//
// Angles are pushed in from the page rather than computed here: the page owns
// the clock so pause / speed / reset keep working even while this scene is
// being (re)created.
Item {
    id: root

    // ── Simulation input ────────────────────────────────────────────────
    property real earthRotationAngle: 0
    property real moonOrbitAngle: 0
    property real moonRotationAngle: 0

    property bool cloudsVisible: true
    property bool orbitLineVisible: true
    property bool starsVisible: true

    readonly property real moonOrbitRadius: 230

    // ── Mission input ───────────────────────────────────────────────────
    //
    // Normalised mission time, 0..1, also owned by the page clock.
    property real missionTime: 0

    property bool missionVisible: true
    property bool missionPathsVisible: true
    property bool followVehicle: false

    // Corrects the day map's longitude convention against the launch site —
    // see MissionController.earthTextureLongitudeOffset. This value is pushed
    // down into both the mission and the pad marker, so it has to carry the same
    // default or it would override theirs with 0.
    property real launchSiteLongitudeOffset: -90

    // Clock rates, passed through from the page. The mission needs them to work
    // out where the launch pad will be when the ascent ends — see
    // MissionController.insertionAngle — so they have to match the page's own
    // clock or the insertion point lands in the wrong place.
    property real missionDuration: 102
    property real earthDegPerSecond: 18.0
    property real moonOrbitDegPerSecond: 9.0

    // Scene angles at the start of the current mission lap, captured by the
    // page's clock. The insertion point is derived from these.
    property real earthAngleAtLapStart: 0
    property real moonAngleAtLapStart: 0

    // Read back by the page for the phase readout.
    readonly property string missionPhaseName: mission.phaseName

    // Mission state machine. An Item, not a Node, so it lives outside View3D.
    MissionController {
        id: mission

        missionTime: root.missionTime
        earthRotationAngle: root.earthRotationAngle
        moonOrbitAngle: root.moonOrbitAngle

        missionDuration: root.missionDuration
        earthDegPerSecond: root.earthDegPerSecond
        moonOrbitDegPerSecond: root.moonOrbitDegPerSecond

        earthAngleAtLapStart: root.earthAngleAtLapStart
        moonAngleAtLapStart: root.moonAngleAtLapStart

        earthTextureLongitudeOffset: root.launchSiteLongitudeOffset
    }

    // ── Camera rig state ────────────────────────────────────────────────
    //
    // The rig is nested yaw -> pitch -> pan -> camera, which means panning is
    // a plain XY offset in camera space and we never have to reason about
    // Euler ordering to work out the screen-space right/up vectors.
    // Default framing. At 480 the Earth fills ~40% of the viewport height and
    // the moon orbit still has margin on both sides.
    readonly property real defaultDistance: 480

    property real camYaw: 20
    property real camPitch: -12
    property real camDistance: defaultDistance
    property real camPanX: 0
    property real camPanY: 0

    readonly property real minDistance: 180
    readonly property real maxDistance: 2400
    readonly property real fieldOfView: 45

    // Closer framing while tracking, otherwise the vehicle is a few pixels.
    readonly property real followDistance: 220

    function resetCamera() {
        camYaw = 20
        camPitch = -12
        camDistance = defaultDistance
        camPanX = 0
        camPanY = 0
    }

    // Animate only on a follow toggle. A Behavior on camDistance would also
    // catch every pinch and wheel step and make the zoom gesture feel sticky.
    onFollowVehicleChanged: {
        camPanX = 0
        camPanY = 0
        distanceRamp.to = followVehicle ? followDistance : defaultDistance
        distanceRamp.restart()
    }

    NumberAnimation {
        id: distanceRamp

        target: root
        property: "camDistance"
        duration: 420
        easing.type: Easing.OutCubic
    }

    // TEMPORARY tuning aid: report the zoom level to journald once the gesture
    // settles, so a hand-picked framing can be read back with
    //   journalctl -u edgepilot-launcher -b | grep earth3d
    // Remove once defaultDistance is final.
    onCamDistanceChanged: zoomLogTimer.restart()

    Timer {
        id: zoomLogTimer
        interval: 500
        onTriggered: console.log("[earth3d] camDistance =",
                                 Math.round(root.camDistance))
    }

    function clamp(v, lo, hi) {
        return v < lo ? lo : (v > hi ? hi : v)
    }

    function zoomBy(factor) {
        camDistance = clamp(camDistance * factor, minDistance, maxDistance)
    }

    // World units per screen pixel at the orbit centre — keeps a drag-to-pan
    // gesture stuck under the finger at every zoom level.
    readonly property real worldPerPixel:
        height > 0
            ? (2 * camDistance * Math.tan(fieldOfView * Math.PI / 360)) / height
            : 1

    View3D {
        id: view3d

        anchors.fill: parent
        camera: camera
        renderMode: View3D.Offscreen

        environment: SceneEnvironment {
            backgroundMode: SceneEnvironment.Color
            clearColor: "#01030a"

            // Per the AM62P first-pass spec. The PowerVR GPU is tile-based, so
            // if the planet limb ever looks too jagged, MSAA here is cheap:
            //   antialiasingMode: SceneEnvironment.MSAA
            //   antialiasingQuality: SceneEnvironment.Medium
            antialiasingMode: SceneEnvironment.NoAA
            temporalAAEnabled: false
        }

        // Orbit centre: the Earth normally, the active mission vehicle while
        // tracking.
        //
        // §22 of the architecture doc — the camera is never parented to the
        // vehicle. A vehicle that tumbles (stage separation, spent upper stage)
        // would drag the view round with it, and the attitude blends during the
        // burn phases would read as camera judder. Instead the whole rig rides a
        // node that eases towards the vehicle, so the user's yaw/pitch/zoom keep
        // working unchanged while tracking.
        Node {
            id: cameraTarget

            position: root.followVehicle
                      ? mission.activeVehicleWorldPosition
                      : Qt.vector3d(0, 0, 0)

            Behavior on position {
                Vector3dAnimation {
                    duration: 260
                    easing.type: Easing.OutQuad
                }
            }

            Node {
                id: cameraYaw
                eulerRotation.y: root.camYaw

                Node {
                    id: cameraPitch
                    eulerRotation.x: root.camPitch

                    Node {
                        id: cameraPan
                        x: root.camPanX
                        y: root.camPanY

                        PerspectiveCamera {
                            id: camera

                            z: root.camDistance
                            // clipNear is deliberately far from 0: nothing can
                            // get closer than minDistance - earth radius, and a
                            // tight near plane is what buys usable depth
                            // precision over the very large clipFar the star
                            // shell needs.
                            clipNear: 10
                            clipFar: 12000
                            fieldOfView: root.fieldOfView
                        }
                    }
                }
            }
        }

        // Star field = one inverted sphere instead of thousands of point
        // objects. Radius 3000 keeps it outside maxDistance so the camera
        // always stays inside the shell.
        Model {
            id: starShell

            visible: root.starsVisible
            source: "#Sphere"
            scale: Qt.vector3d(60, 60, 60)

            materials: PrincipledMaterial {
                baseColorMap: Texture {
                    source: "qrc:/assets/space/stars_2k.jpg"
                    generateMipmaps: true
                    mipFilter: Texture.Linear
                    minFilter: Texture.Linear
                    magFilter: Texture.Linear
                }

                lighting: PrincipledMaterial.NoLighting
                // We look at this sphere from the inside.
                cullMode: Material.NoCulling
            }
        }

        /*
         * "Always lit" rig: front / rear / top fill lights instead of one sun.
         * No shadow casting anywhere — with no single key light there is no
         * terminator to sell, and shadow maps are the one thing that would
         * actually hurt on this GPU.
         */

        DirectionalLight {
            id: frontLight

            eulerRotation: Qt.vector3d(-25, -30, 0)
            brightness: 1.4
            color: "#ffffff"
            castsShadow: false
        }

        DirectionalLight {
            id: rearLight

            eulerRotation: Qt.vector3d(20, 150, 0)
            brightness: 0.95
            color: "#bfd8ff"
            castsShadow: false
        }

        DirectionalLight {
            id: topLight

            eulerRotation: Qt.vector3d(-90, 0, 0)
            brightness: 0.55
            color: "#ffffff"
            castsShadow: false
        }

        Node {
            id: earthMoonRoot

            // Earth sits on the scene root, not on an orbit node — it never
            // travels anywhere, it only spins.
            Earth {
                id: earth

                rotationAngle: root.earthRotationAngle
                cloudsVisible: root.cloudsVisible

                launchMarkerVisible: root.missionVisible
                launchMarkerLongitudeOffset: root.launchSiteLongitudeOffset
            }

            Node {
                id: moonOrbitPlane

                // Real lunar orbit inclination against the ecliptic. The ring
                // lives inside this node too, otherwise the drawn orbit and
                // the actual moon path would visibly disagree.
                eulerRotation.x: 5.1

                OrbitRing {
                    id: moonOrbitRing

                    radius: root.moonOrbitRadius
                    visible: root.orbitLineVisible
                }

                Node {
                    id: moonOrbitNode

                    eulerRotation.y: root.moonOrbitAngle

                    Moon {
                        id: moon

                        x: root.moonOrbitRadius
                        rotationAngle: root.moonRotationAngle
                    }

                    // ── Mission frame ───────────────────────────────────
                    //
                    // Everything mission-related hangs off the Moon's orbit
                    // pivot, not the scene root. That is what keeps the whole
                    // route — transfer arc, capture orbits, landing site,
                    // return arc — aligned with the Moon as it travels, so the
                    // trajectory never points at where the Moon used to be.
                    //
                    // The cost is that the launch and re-entry points, which
                    // belong to the rotating Earth, have to be transformed into
                    // this frame; MissionController.earthLocalToMission() does
                    // that by hand.

                    MissionPaths {
                        id: missionPaths

                        controller: mission
                        visible: root.missionVisible && root.missionPathsVisible
                    }

                    // Carrier. The outer node holds the trajectory pose; the
                    // inner one adds tumble, so a spinning spent stage does not
                    // corrupt the along-track attitude it was handed.
                    Node {
                        visible: root.missionVisible
                                 && mission.launchVehicleVisible
                        position: mission.launchVehiclePosition
                        rotation: mission.launchVehicleRotation

                        Node {
                            eulerRotation: mission.launchVehicleTumble

                            LaunchVehicle {
                                coreStageVisible: mission.coreStageVisible
                                coreStageOffset: mission.coreStageOffset
                                coreStageEuler: mission.coreStageEuler

                                fairingVisible: mission.fairingVisible
                                fairingLeftOffset: mission.fairingLeftOffset
                                fairingLeftEuler: mission.fairingLeftEuler
                                fairingRightOffset: mission.fairingRightOffset
                                fairingRightEuler: mission.fairingRightEuler

                                bayDoorAngle: mission.bayDoorAngle

                                burning: mission.launchBurning
                                throttle: mission.launchThrottle
                            }
                        }
                    }

                    // Lunar probe.
                    Node {
                        visible: root.missionVisible && mission.probeVisible
                        position: mission.probePosition
                        rotation: mission.probeRotation

                        Node {
                            eulerRotation: mission.probeTumble

                            LunarProbe {
                                deploy: mission.probeDeploy
                                burning: mission.probeBurning
                                reentryGlow: mission.reentryGlow
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Input ───────────────────────────────────────────────────────────
    //
    // Input handlers rather than Qt Quick 3D's OrbitCameraController: they
    // cover mouse AND touch with the same code, and they let us clamp pitch
    // and zoom so the user cannot get lost inside the planet.

    // Orbit — left button / single finger.
    DragHandler {
        id: orbitDrag

        target: null
        acceptedButtons: Qt.LeftButton
        maximumPointCount: 1

        property real lastX: 0
        property real lastY: 0

        onActiveChanged: {
            if (active) {
                lastX = 0
                lastY = 0
            }
        }

        onActiveTranslationChanged: {
            const dx = activeTranslation.x - lastX
            const dy = activeTranslation.y - lastY
            lastX = activeTranslation.x
            lastY = activeTranslation.y

            root.camYaw -= dx * 0.28
            root.camPitch = root.clamp(root.camPitch - dy * 0.28, -85, 85)
        }
    }

    // Pan — right / middle button.
    DragHandler {
        id: panDrag

        target: null
        acceptedButtons: Qt.RightButton | Qt.MiddleButton
        maximumPointCount: 1

        property real lastX: 0
        property real lastY: 0

        onActiveChanged: {
            if (active) {
                lastX = 0
                lastY = 0
            }
        }

        onActiveTranslationChanged: {
            const dx = activeTranslation.x - lastX
            const dy = activeTranslation.y - lastY
            lastX = activeTranslation.x
            lastY = activeTranslation.y

            root.camPanX -= dx * root.worldPerPixel
            root.camPanY += dy * root.worldPerPixel
        }
    }

    // Pinch — two fingers: zoom on the scale, pan on the centroid.
    PinchHandler {
        id: pinch

        target: null
        minimumPointCount: 2
        maximumPointCount: 2

        property real startDistance: 700
        property real lastX: 0
        property real lastY: 0

        onActiveChanged: {
            if (active) {
                startDistance = root.camDistance
                lastX = 0
                lastY = 0
            }
        }

        onActiveScaleChanged: {
            if (activeScale > 0) {
                root.camDistance = root.clamp(startDistance / activeScale,
                                              root.minDistance,
                                              root.maxDistance)
            }
        }

        onActiveTranslationChanged: {
            const dx = activeTranslation.x - lastX
            const dy = activeTranslation.y - lastY
            lastX = activeTranslation.x
            lastY = activeTranslation.y

            root.camPanX -= dx * root.worldPerPixel
            root.camPanY += dy * root.worldPerPixel
        }
    }

    // Wheel — one notch (120 units) is one zoom step.
    WheelHandler {
        id: wheel

        onWheel: function (event) {
            if (event.angleDelta.y !== 0)
                root.zoomBy(Math.pow(0.85, event.angleDelta.y / 120))
        }
    }

    // Double tap anywhere resets the view — the on-screen button does the
    // same thing, this is just the gesture people try first.
    TapHandler {
        acceptedButtons: Qt.LeftButton
        onDoubleTapped: root.resetCamera()
    }
}
