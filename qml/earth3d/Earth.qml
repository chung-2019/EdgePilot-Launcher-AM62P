import QtQuick
import QtQuick3D

// Earth = tilt node -> spin node -> surface sphere + cloud shell.
//
// Splitting tilt from spin keeps the 23.4° axial tilt fixed in world space
// while only the inner node accumulates the rotation angle, so the poles do
// not wobble as the angle wraps past 360°.
//
// There is deliberately NO atmosphere shell / blue rim glow here — the spec
// removed it, and on a tile-based GPU an extra full-screen transparent shell
// is the most expensive thing we could add for the least benefit.
Node {
    id: root

    property real rotationAngle: 0
    property bool cloudsVisible: true

    // Launch site. Parented to the spin node below, so it rides the surface —
    // the mission reads the same lat/lon to place the pad, and the two offsets
    // must agree or the rocket lifts off from open sea.
    property bool launchMarkerVisible: true
    property real launchMarkerLongitudeOffset: 0

    // Built-in "#Sphere" has radius 50, so scale 1.6 -> radius 80 world units.
    readonly property real surfaceScale: 1.6
    // 1.5 units of air between ground and clouds — enough to avoid z-fighting
    // at every zoom level we allow, small enough to read as one planet.
    readonly property real cloudScale: 1.625

    // Shared so baseColorMap and emissiveMap sample ONE GPU texture instead of
    // uploading the 2K day map twice.
    Texture {
        id: dayTexture
        source: "qrc:/assets/earth/earth_day_2k.jpg"
        generateMipmaps: true
        mipFilter: Texture.Linear
        minFilter: Texture.Linear
        magFilter: Texture.Linear
    }

    Texture {
        id: normalTexture
        source: "qrc:/assets/earth/earth_normal_2k.jpg"
        generateMipmaps: true
        mipFilter: Texture.Linear
        minFilter: Texture.Linear
    }

    Texture {
        id: roughnessTexture
        source: "qrc:/assets/earth/earth_roughness_2k.jpg"
        generateMipmaps: true
        mipFilter: Texture.Linear
        minFilter: Texture.Linear
    }

    Texture {
        id: cloudTexture
        source: "qrc:/assets/earth/earth_clouds_1k.png"
        generateMipmaps: true
        mipFilter: Texture.Linear
        minFilter: Texture.Linear
    }

    Node {
        id: earthTilt
        eulerRotation.z: -23.4

        Node {
            id: earthSpin
            eulerRotation.y: root.rotationAngle

            Model {
                id: earthModel

                source: "#Sphere"
                scale: Qt.vector3d(root.surfaceScale,
                                   root.surfaceScale,
                                   root.surfaceScale)

                materials: PrincipledMaterial {
                    baseColorMap: dayTexture

                    normalMap: normalTexture
                    normalStrength: 0.35

                    // The map is dark over ocean and bright over land, which is
                    // exactly the right polarity: glossy sea, matte continents.
                    // roughness stays at 1.0 so it acts as a pure multiplier.
                    roughnessMap: roughnessTexture
                    roughness: 1.0

                    metalness: 0.0
                    specularAmount: 0.22

                    // Low-strength self-illumination from the day map. This is
                    // what keeps the night side readable now that there is no
                    // sun light source — see the "always lit" section of the
                    // architecture doc.
                    emissiveMap: dayTexture
                    emissiveFactor: Qt.vector3d(0.25, 0.25, 0.25)
                }
            }

            Model {
                id: cloudModel

                visible: root.cloudsVisible
                source: "#Sphere"
                scale: Qt.vector3d(root.cloudScale,
                                   root.cloudScale,
                                   root.cloudScale)

                // Clouds drift slowly relative to the surface instead of being
                // welded to it — a small offset is enough to sell the effect.
                eulerRotation.y: root.rotationAngle * 0.08

                // 0.78 rather than 1.0: the regraded cloud mask still has a
                // wide soft-edge tail, and at full strength that tail turns
                // the oceans milky instead of reading as weather.
                opacity: 0.78

                materials: PrincipledMaterial {
                    // The PNG is RGBA, so its own alpha drives the blend —
                    // no separate opacityMap (that would apply alpha twice).
                    baseColorMap: cloudTexture
                    alphaMode: PrincipledMaterial.Blend

                    emissiveMap: cloudTexture
                    emissiveFactor: Qt.vector3d(0.12, 0.12, 0.12)

                    roughness: 1.0
                    metalness: 0.0
                }
            }

            // Inside the spin node, so the pad turns with the planet and the
            // mission's launch/re-entry points stay on top of it.
            TaiwanMarker {
                visible: root.launchMarkerVisible
                longitudeOffset: root.launchMarkerLongitudeOffset
                surfaceRadius: 50 * root.surfaceScale * 1.015
            }
        }
    }
}
