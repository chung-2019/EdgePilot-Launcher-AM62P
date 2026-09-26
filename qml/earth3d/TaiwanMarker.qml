import QtQuick
import QtQuick3D

import "MissionMath.js" as M

// Launch-site marker, parented to the Earth's spin node so it rides the
// surface.
//
// The reference uses a torus plus a circle plus a point light. There is no
// torus primitive here, and OrbitRing's ring texture is no help at this size —
// its line width is a fixed fraction of the ring radius, so at 6 world units
// the line would be a fraction of a unit wide and mip out to nothing. A flat
// lit disc plus a bright centre reads better and costs two draw calls.
//
// No point light: adding one would change the light count for every material in
// the scene and force a shader rebuild, for a glow that an unlit emissive
// sphere already sells.
Node {
    id: root

    property real latitude: 23.7
    property real longitude: 121.0

    // Slightly above the surface so it never z-fights with the globe.
    property real surfaceRadius: 81.2

    // See MissionController.earthTextureLongitudeOffset — same correction, same
    // default, and the two must agree or the rocket lifts off somewhere other
    // than the marker.
    property real longitudeOffset: -90

    property real markerDiameter: 13
    property color markerColor: "#ff8a52"

    readonly property var localPosition:
        M.latLonToVector3(latitude, longitude, surfaceRadius, longitudeOffset)

    position: M.toVector3d(localPosition)

    // Lay the disc flat against the surface: its own +Y becomes the local
    // outward normal.
    rotation: M.toQuaternion(M.rotationTo([0, 1, 0],
                                          M.normalize(localPosition)))

    Model {
        id: pad

        source: "#Cylinder"
        scale: Qt.vector3d(root.markerDiameter / 100,
                           0.6 / 100,
                           root.markerDiameter / 100)
        opacity: 0.55

        materials: PrincipledMaterial {
            baseColor: root.markerColor
            lighting: PrincipledMaterial.NoLighting
            alphaMode: PrincipledMaterial.Blend
            cullMode: Material.NoCulling
        }
    }

    Model {
        id: beacon

        source: "#Sphere"
        y: 1.6
        scale: Qt.vector3d(4.4 / 100, 4.4 / 100, 4.4 / 100)

        materials: PrincipledMaterial {
            baseColor: "#ffd0a8"
            lighting: PrincipledMaterial.NoLighting
        }
    }
}
