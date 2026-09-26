import QtQuick
import QtQuick3D

// A free-form trajectory drawn as a run of small markers.
//
// Qt Quick 3D has no line primitive and this build cannot supply custom C++
// geometry — the AM62P devkit sysroot ships no Quick3D headers, so the
// TrajectoryGeometry/QQuick3DGeometry approach in the architecture doc is not
// available here. A textured plane works for a closed ring (see OrbitRing.qml)
// but not for an open space curve, so free curves become dotted paths.
//
// Cost is one draw call per marker, which is why callers pass modest sample
// counts (16-26 per curve) and why the whole set can be switched off. Cubes,
// not spheres: 12 triangles instead of ~1600, and at this size on screen the
// silhouette is a couple of pixels either way.
Node {
    id: root

    // List of vector3d, in this node's coordinate space.
    property var points: []

    property color pathColor: "#d1d8df"
    property real pathOpacity: 0.72

    // World units. Markers stay a fixed size, so a path close to the camera
    // reads as a heavier line — which is the depth cue we want.
    property real markerSize: 2.4

    PrincipledMaterial {
        id: pathMaterial

        baseColor: root.pathColor
        lighting: PrincipledMaterial.NoLighting
        alphaMode: PrincipledMaterial.Blend
        cullMode: Material.NoCulling
    }

    Repeater3D {
        model: root.points

        Model {
            required property vector3d modelData

            source: "#Cube"
            position: modelData
            scale: Qt.vector3d(root.markerSize / 100,
                               root.markerSize / 100,
                               root.markerSize / 100)
            opacity: root.pathOpacity
            materials: pathMaterial
        }
    }
}
