import QtQuick
import QtQuick3D

// Lunar probe: service module, capsule, instrument bus, folding solar wings,
// folding dish, landing legs, engine plume and a re-entry plasma sheath.
//
// Primitives rather than lunar_probe.mesh, for the same reasons as
// LaunchVehicle.qml — the wings and dish have to articulate, and a material
// slot cannot. Geometry is the reference's, in its units; `unitScale` converts.
//
// Nose along local +X.
Node {
    id: root

    // ~1.34 reference units body length; at 13 that is ~17 world units against
    // a 21-unit Moon radius. Oversized on purpose, as with the launcher.
    property real unitScale: 13

    // 0 = wings folded along the body and dish stowed, 1 = fully deployed.
    property real deploy: 0

    property bool burning: false

    // 0..1 plasma envelope strength during atmospheric entry.
    property real reentryGlow: 0

    readonly property vector3d unit: Qt.vector3d(unitScale, unitScale, unitScale)

    // Hinge angles, in degrees. The reference lerps radians between ±pi/2 and 0
    // for the wings and -0.48pi to 0 for the dish.
    readonly property real wingAngle: 90 * (1 - deploy)
    readonly property real dishAngle: -86.4 * (1 - deploy)

    PrincipledMaterial {
        id: whiteMaterial
        baseColor: "#e8edf0"
        roughness: 0.36
        metalness: 0.52
    }

    PrincipledMaterial {
        id: silverMaterial
        baseColor: "#9ca8ad"
        roughness: 0.32
        metalness: 0.72
    }

    PrincipledMaterial {
        id: darkMaterial
        baseColor: "#202a30"
        roughness: 0.52
        metalness: 0.55
    }

    PrincipledMaterial {
        id: goldMaterial
        baseColor: "#caa64f"
        roughness: 0.68
        metalness: 0.20
    }

    PrincipledMaterial {
        id: blueMaterial
        baseColor: "#163f72"
        roughness: 0.56
        metalness: 0.20
    }

    Node {
        id: body

        scale: root.unit

        // Service module.
        Model {
            source: "#Cylinder"
            eulerRotation.z: 90
            scale: Qt.vector3d(0.38 / 100, 0.52 / 100, 0.38 / 100)
            materials: silverMaterial
        }

        // Command capsule, tip forward.
        Model {
            source: "#Cone"
            x: 0.46
            eulerRotation.z: -90
            scale: Qt.vector3d(0.40 / 100, 0.42 / 100, 0.40 / 100)
            materials: whiteMaterial
        }

        // Gold instrument bus.
        Model {
            source: "#Cube"
            x: -0.29
            scale: Qt.vector3d(0.28 / 100, 0.34 / 100, 0.34 / 100)
            materials: goldMaterial
        }

        // Engine bell, tip aft.
        Model {
            source: "#Cone"
            x: -0.55
            eulerRotation.z: 90
            scale: Qt.vector3d(0.32 / 100, 0.24 / 100, 0.32 / 100)
            materials: darkMaterial
        }

        // ── Folding solar wings ─────────────────────────────────────────
        //
        // Each wing is a yoke plus a panel on a hinge node. Stowed, the hinge
        // is at ±90° so the panel lies back along the body; deployed, it is 0°
        // and the panel stands out square.

        component SolarWing: Node {
            id: wing

            required property real side   // -1 or +1

            // Yoke.
            Model {
                source: "#Cube"
                position: Qt.vector3d(0, 0, wing.side * 0.23)
                scale: Qt.vector3d(0.055 / 100, 0.045 / 100, 0.46 / 100)
                materials: silverMaterial
            }

            // Panel.
            Model {
                source: "#Cube"
                position: Qt.vector3d(0, 0, wing.side * 0.72)
                scale: Qt.vector3d(0.44 / 100, 0.035 / 100, 0.68 / 100)
                materials: blueMaterial
            }
        }

        Node {
            position: Qt.vector3d(-0.12, 0, -0.20)
            eulerRotation.y: -root.wingAngle

            SolarWing { side: -1 }
        }

        Node {
            position: Qt.vector3d(-0.12, 0, 0.20)
            eulerRotation.y: root.wingAngle

            SolarWing { side: 1 }
        }

        // ── Folding dish antenna ────────────────────────────────────────

        Node {
            position: Qt.vector3d(-0.18, 0.18, 0)
            eulerRotation.z: root.dishAngle

            Model {
                source: "#Cone"
                position: Qt.vector3d(0, 0.12, 0)
                eulerRotation.z: -90
                scale: Qt.vector3d(0.46 / 100, 0.12 / 100, 0.46 / 100)
                materials: whiteMaterial
            }

            Model {
                source: "#Cylinder"
                position: Qt.vector3d(0.04, 0.04, 0)
                eulerRotation.z: 90
                scale: Qt.vector3d(0.05 / 100, 0.22 / 100, 0.05 / 100)
                materials: darkMaterial
            }
        }

        // ── Landing legs ────────────────────────────────────────────────
        //
        // modelData is the roll angle. Qt applies eulerRotation Z then X then
        // Y; with y = 0 that is the same composition the reference uses, so the
        // canted-outward pose carries over unchanged.
        Repeater3D {
            model: [45, 135, 225, 315]

            Model {
                required property real modelData

                readonly property real radians: modelData * Math.PI / 180

                source: "#Cylinder"
                position: Qt.vector3d(-0.22,
                                      Math.cos(radians) * 0.22,
                                      Math.sin(radians) * 0.22)
                eulerRotation: Qt.vector3d(modelData, 0, 64.3)
                scale: Qt.vector3d(0.036 / 100, 0.38 / 100, 0.036 / 100)
                materials: silverMaterial
            }
        }

        // ── Plume ───────────────────────────────────────────────────────

        EngineFlame {
            burning: root.burning
            throttle: 1

            outerDiameter: 0.24
            outerLength: 0.48
            outerOffset: -0.82

            coreDiameter: 0.10
            coreLength: 0.30
            coreOffset: -0.74
        }

        // ── Re-entry plasma sheath ──────────────────────────────────────
        //
        // Stretched along the flight direction and seen from the inside, which
        // is what gives the bow-shock look: FrontFaceCulling is Qt's equivalent
        // of the reference's THREE.BackSide.
        Model {
            id: plasma

            visible: root.reentryGlow > 0.01
            source: "#Sphere"

            scale: Qt.vector3d(0.86 / 100 * (1.75 + root.reentryGlow * 0.38),
                               0.86 / 100 * (0.90 + root.reentryGlow * 0.12),
                               0.86 / 100 * (0.90 + root.reentryGlow * 0.12))

            opacity: root.reentryGlow * 0.42

            materials: PrincipledMaterial {
                baseColor: "#ff7938"
                lighting: PrincipledMaterial.NoLighting
                alphaMode: PrincipledMaterial.Blend
                cullMode: Material.FrontFaceCulling
            }
        }
    }
}
