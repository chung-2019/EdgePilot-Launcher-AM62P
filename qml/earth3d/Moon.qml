import QtQuick
import QtQuick3D

// Moon body only — the orbit motion lives in the parent node chain
// (orbit plane -> orbit angle -> this), so self-rotation stays independent
// of where the moon currently is along its orbit.
Node {
    id: root

    property real rotationAngle: 0

    // 0.42 / 1.6 = 0.2625, which is very close to the real Moon/Earth
    // radius ratio (0.273).
    readonly property real bodyScale: 0.42

    Texture {
        id: moonTexture
        source: "qrc:/assets/moon/moon_1k.jpg"
        generateMipmaps: true
        mipFilter: Texture.Linear
        minFilter: Texture.Linear
        magFilter: Texture.Linear
    }

    Node {
        id: moonSpin
        eulerRotation.y: root.rotationAngle

        Model {
            source: "#Sphere"
            scale: Qt.vector3d(root.bodyScale, root.bodyScale, root.bodyScale)

            materials: PrincipledMaterial {
                baseColorMap: moonTexture

                // Same trick as Earth: a little self-illumination so the moon
                // never drops to a black silhouette against the star field.
                emissiveMap: moonTexture
                emissiveFactor: Qt.vector3d(0.12, 0.12, 0.12)

                roughness: 0.92
                metalness: 0.0
                specularAmount: 0.06
            }
        }
    }
}
