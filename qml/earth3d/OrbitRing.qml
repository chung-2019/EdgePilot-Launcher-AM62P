import QtQuick
import QtQuick3D

// Moon orbit line.
//
// Qt Quick 3D has no line primitive, and this build cannot use custom C++
// geometry (the AM62P devkit sysroot ships no Quick3D headers — only the EVM
// rootfs has the runtime). So the ring is a single textured "#Rectangle"
// laid flat: 2 triangles, 1 draw call, and the anti-aliasing comes from the
// texture instead of from MSAA.
//
// The far half of the ring is hidden by the Earth for free: transparent
// materials are drawn after opaque ones but still depth-TEST against them.
//
// Texture is produced by tools/gen_orbit_ring.py; the ring sits at 0.80 of
// the plane half-extent there, which is where ringUvRadius comes from.
//
// The mission added elliptical orbits (Earth parking, lunar capture, lunar
// return) and they all reuse this one texture: independent x/z scales turn the
// circle into an ellipse, and baseColor tints it, since PrincipledMaterial
// multiplies baseColor into baseColorMap. Eight orbit rings, one texture,
// one draw call each.
Model {
    id: root

    // Circular by default; set radiusZ for an ellipse.
    property real radius: 230
    property real radiusZ: radius

    // Offset along +X, for orbits centred on the Moon rather than the Earth.
    property real centerX: 0

    property color ringColor: "#ffffff"
    property real ringOpacity: 0.85

    readonly property real ringUvRadius: 0.80

    source: "#Rectangle"

    x: root.centerX

    // "#Rectangle" is a 100x100 plane in XY facing +Z; lay it into the XZ
    // plane so it matches the orbit. After the -90 turn, local y maps to
    // world -z, so scale.y is the z radius.
    eulerRotation.x: -90
    scale: Qt.vector3d(radius / ringUvRadius / 50,
                       radiusZ / ringUvRadius / 50,
                       1)

    opacity: root.ringOpacity

    materials: PrincipledMaterial {
        baseColor: root.ringColor

        baseColorMap: Texture {
            source: "qrc:/assets/space/moon_orbit_ring.png"
            generateMipmaps: true
            mipFilter: Texture.Linear
            minFilter: Texture.Linear
            magFilter: Texture.Linear
        }

        alphaMode: PrincipledMaterial.Blend
        lighting: PrincipledMaterial.NoLighting

        // Without this the ring vanishes as soon as the camera drops below the
        // orbit plane, because a plane only has one facing side.
        cullMode: Material.NoCulling
    }
}
