import QtQuick
import QtQuick3D

// Launch vehicle: core stage, upper stage, payload bay and two fairing shells,
// each on its own node so they can separate independently.
//
// Assembled from built-in primitives rather than the .mesh files in
// am62p-earth-moon/assets/models/. Two reasons, both decisive:
//
//   * launch_vehicle.mesh is one model with seven material slots. Material
//     slots cannot move relative to each other, and this vehicle has to shed a
//     fairing, drop a stage and open a payload bay.
//   * Qt .mesh is a versioned runtime format (those files are version 7) and
//     the EVM rootfs Qt is a different build. Primitives cannot version-skew.
//
// Geometry follows the three.js reference one-to-one, in its units; `unitScale`
// converts to world units. Built-in primitives are 100 across, so a target
// diameter d and height h become scale (d/100, h/100, d/100).
//
// Everything is modelled nose-along-local-+X. Primitives extrude along +Y, so
// bodies carry eulerRotation.z = 90 and forward-facing cones -90.
Node {
    id: root

    // 4.72 reference units nose-to-tail; at 11 that is ~52 world units against
    // an 80-unit Earth radius. Deliberately oversized — a to-scale rocket at
    // this zoom would be a single pixel.
    property real unitScale: 11

    property bool coreStageVisible: true
    property vector3d coreStageOffset: Qt.vector3d(0, 0, 0)
    property vector3d coreStageEuler: Qt.vector3d(0, 0, 0)

    property bool fairingVisible: true
    property vector3d fairingLeftOffset: Qt.vector3d(0, 0, 0)
    property vector3d fairingLeftEuler: Qt.vector3d(0, 0, 0)
    property vector3d fairingRightOffset: Qt.vector3d(0, 0, 0)
    property vector3d fairingRightEuler: Qt.vector3d(0, 0, 0)

    // Degrees. Doors hinge apart to release the probe.
    property real bayDoorAngle: 0

    property bool burning: false
    property real throttle: 0

    readonly property vector3d unit: Qt.vector3d(unitScale, unitScale, unitScale)

    // Separation offsets arrive in world units, so they belong on nodes OUTSIDE
    // the unitScale node — otherwise they would be multiplied by it as well.

    PrincipledMaterial {
        id: whiteMaterial
        baseColor: "#e8edf0"
        roughness: 0.40
        metalness: 0.42
    }

    PrincipledMaterial {
        id: darkMaterial
        baseColor: "#252d32"
        roughness: 0.54
        metalness: 0.62
    }

    PrincipledMaterial {
        id: orangeMaterial
        baseColor: "#d88435"
        roughness: 0.58
        metalness: 0.22
    }

    PrincipledMaterial {
        id: fairingMaterial
        baseColor: "#f3f5f6"
        roughness: 0.36
        metalness: 0.34
        cullMode: Material.NoCulling
    }

    // ── Core stage ──────────────────────────────────────────────────────

    Node {
        id: coreStage

        visible: root.coreStageVisible
        position: root.coreStageOffset
        eulerRotation: root.coreStageEuler

        Node {
            scale: root.unit

            // Main body.
            Model {
                source: "#Cylinder"
                x: -0.45
                eulerRotation.z: 90
                scale: Qt.vector3d(0.50 / 100, 1.65 / 100, 0.50 / 100)
                materials: whiteMaterial
            }

            // Aft tank band.
            Model {
                source: "#Cylinder"
                x: -1.47
                eulerRotation.z: 90
                scale: Qt.vector3d(0.49 / 100, 0.42 / 100, 0.49 / 100)
                materials: orangeMaterial
            }

            // Nozzle skirt. +90 puts the cone tip aft, where it belongs.
            Model {
                source: "#Cone"
                x: -1.85
                eulerRotation.z: 90
                scale: Qt.vector3d(0.48 / 100, 0.36 / 100, 0.48 / 100)
                materials: darkMaterial
            }

            // Four stabilising fins. modelData is the roll angle in degrees.
            Repeater3D {
                model: [0, 90, 180, 270]

                Model {
                    required property real modelData

                    readonly property real radians: modelData * Math.PI / 180

                    source: "#Cube"
                    position: Qt.vector3d(-1.25,
                                          Math.cos(radians) * 0.25,
                                          Math.sin(radians) * 0.25)
                    eulerRotation.x: modelData
                    scale: Qt.vector3d(0.34 / 100, 0.025 / 100, 0.22 / 100)
                    materials: darkMaterial
                }
            }

            // First-stage plume.
            EngineFlame {
                burning: root.burning && root.coreStageVisible
                throttle: root.throttle

                outerDiameter: 0.46
                outerLength: 1.05
                outerOffset: -2.42

                coreDiameter: 0.20
                coreLength: 0.72
                coreOffset: -2.30
            }
        }
    }

    // ── Upper stage, payload and bay ────────────────────────────────────

    Node {
        id: upperStack

        Node {
            scale: root.unit

            Model {
                source: "#Cylinder"
                x: 0.78
                eulerRotation.z: 90
                scale: Qt.vector3d(0.40 / 100, 0.76 / 100, 0.40 / 100)
                materials: whiteMaterial
            }

            // Interstage.
            Model {
                source: "#Cylinder"
                x: 0.27
                eulerRotation.z: 90
                scale: Qt.vector3d(0.36 / 100, 0.28 / 100, 0.36 / 100)
                materials: darkMaterial
            }

            // Payload body under the fairing.
            Model {
                source: "#Cylinder"
                x: 1.30
                eulerRotation.z: 90
                scale: Qt.vector3d(0.26 / 100, 0.38 / 100, 0.26 / 100)
                materials: orangeMaterial
            }

            // Payload bay doors. Each hinges about its own node, so the
            // rotation happens at the hinge line and not about the body axis.
            Node {
                position: Qt.vector3d(1.42, 0.23, 0)
                eulerRotation.z: root.bayDoorAngle

                Model {
                    source: "#Cube"
                    scale: Qt.vector3d(0.78 / 100, 0.045 / 100, 0.46 / 100)
                    materials: fairingMaterial
                }
            }

            Node {
                position: Qt.vector3d(1.42, -0.23, 0)
                eulerRotation.z: -root.bayDoorAngle

                Model {
                    source: "#Cube"
                    scale: Qt.vector3d(0.78 / 100, 0.045 / 100, 0.46 / 100)
                    materials: fairingMaterial
                }
            }

            // Upper-stage plume. The reference parents its only flame to the
            // core stage, so the TLI burn — the mission's most important
            // ignition — shows no exhaust at all once the stage is gone. This
            // second nozzle takes over exactly when the core stage leaves.
            EngineFlame {
                burning: root.burning && !root.coreStageVisible
                throttle: root.throttle

                outerDiameter: 0.30
                outerLength: 0.62
                outerOffset: -0.18

                coreDiameter: 0.13
                coreLength: 0.42
                coreOffset: -0.08
            }
        }
    }

    // ── Fairing shells ──────────────────────────────────────────────────
    //
    // The reference builds true half shells from Cylinder/Cone theta ranges.
    // Built-in primitives have no theta range, so each shell is a half-width
    // body offset to its own side: closed up they read as one fairing with a
    // seam down the middle, and they separate the same way. At this scale the
    // difference between a half-ellipse and a half-circle section is invisible.

    component FairingShell: Node {
        id: shell

        required property real side   // -1 or +1

        Node {
            scale: root.unit

            Model {
                source: "#Cylinder"
                position: Qt.vector3d(1.56, 0, shell.side * 0.06)
                eulerRotation.z: 90
                scale: Qt.vector3d(0.48 / 100, 0.56 / 100, 0.24 / 100)
                materials: fairingMaterial
            }

            Model {
                source: "#Cone"
                position: Qt.vector3d(2.07, 0, shell.side * 0.06)
                eulerRotation.z: -90
                scale: Qt.vector3d(0.48 / 100, 0.46 / 100, 0.24 / 100)
                materials: fairingMaterial
            }
        }
    }

    FairingShell {
        side: 1
        visible: root.fairingVisible
        position: root.fairingLeftOffset
        eulerRotation: root.fairingLeftEuler
    }

    FairingShell {
        side: -1
        visible: root.fairingVisible
        position: root.fairingRightOffset
        eulerRotation: root.fairingRightEuler
    }
}
