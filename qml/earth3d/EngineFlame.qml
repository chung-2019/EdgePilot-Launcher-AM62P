import QtQuick
import QtQuick3D

// Engine plume: a wide warm cone with a hot pale core inside it.
//
// The reference uses additive blending. Qt Quick 3D can only do that through a
// CustomMaterial, which means shipping shader source and a second shading path
// for one small effect — against a near-black sky an unlit blended material
// reads the same, so this uses PrincipledMaterial with lighting off.
//
// Geometry is in the reference's own units; the parent applies the scene scale.
// Built-in primitives are 100 units across ("#Cone" = base diameter 100,
// height 100), hence the /100 factors.
//
// Cones point along +Y by default and every mission object flies nose-along-+X,
// so eulerRotation.z = -90 turns the tip forward: the plume's wide end trails
// behind the nozzle.
Node {
    id: root

    property bool burning: false

    // 0..1. Drives length, width and opacity together, so a ramping engine
    // grows out of nothing instead of popping on at full size.
    property real throttle: 1

    property real outerDiameter: 0.46
    property real outerLength: 1.05
    property real outerOffset: -2.42

    property real coreDiameter: 0.20
    property real coreLength: 0.72
    property real coreOffset: -2.30

    property color outerColor: "#ffa542"
    property color coreColor: "#e8f7ff"

    visible: burning && throttle > 0.01

    // Combustion flicker. A declarative animation rather than a per-frame JS
    // callback: it runs on the animation driver and costs nothing per frame.
    property real pulse: 1

    SequentialAnimation on pulse {
        running: root.visible
        loops: Animation.Infinite

        NumberAnimation {
            from: 0.84
            to: 1.16
            duration: 190
            easing.type: Easing.InOutSine
        }
        NumberAnimation {
            from: 1.16
            to: 0.84
            duration: 240
            easing.type: Easing.InOutSine
        }
    }

    readonly property real gain: Math.max(root.throttle, 0.06) * root.pulse

    Model {
        id: outerPlume

        source: "#Cone"
        x: root.outerOffset
        eulerRotation.z: -90

        scale: Qt.vector3d(root.outerDiameter / 100 * root.gain,
                           root.outerLength / 100 * root.gain,
                           root.outerDiameter / 100 * root.gain)

        opacity: 0.88 * Math.min(root.throttle * 1.6, 1.0)

        materials: PrincipledMaterial {
            baseColor: root.outerColor
            lighting: PrincipledMaterial.NoLighting
            alphaMode: PrincipledMaterial.Blend
            cullMode: Material.NoCulling
        }
    }

    Model {
        id: corePlume

        source: "#Cone"
        x: root.coreOffset
        eulerRotation.z: -90

        // The core keeps a little more of its length at low throttle, which is
        // what makes a ramping engine look like it is building pressure.
        scale: Qt.vector3d(root.coreDiameter / 100 * root.gain,
                           root.coreLength / 100
                               * Math.max(root.throttle * 0.8 + 0.2, 0.2)
                               * root.pulse,
                           root.coreDiameter / 100 * root.gain)

        opacity: 0.92 * Math.min(root.throttle * 1.8, 1.0)

        materials: PrincipledMaterial {
            baseColor: root.coreColor
            lighting: PrincipledMaterial.NoLighting
            alphaMode: PrincipledMaterial.Blend
            cullMode: Material.NoCulling
        }
    }
}
