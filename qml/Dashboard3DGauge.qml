// Dashboard3DGauge.qml
//
// 3D-styled ring gauge for the Dashboard page. Uses only Qt 6 native modules
// (no Qt5Compat.GraphicalEffects, no QtQuick3D), so it runs on the AM62P
// PowerVR GPU through the standard QtQuick scene graph + MultiEffect shader.
//
// Visual stack (back → front):
//   1. Glass bowl    — radial-style vertical gradient + outer drop shadow
//                      gives the "recessed disc" feel.
//   2. Track ring    — 4 stacked Shapes (groove shadow, mid face, inner
//                      shadow edge, outer rim highlight) fake a tube
//                      cross-section under a top-left light source.
//   3. Glow halo     — duplicate of the active arc, blurred via MultiEffect
//                      (one shared layer so we only pay the shader cost once).
//   4. Active arc    — 4 passes (inner shadow, base color, bevel highlight,
//                      specular sliver) bevels the active ring.
//   5. Head cap glow — small disc at the progress endpoint, simulating the
//                      neon "tip" of a medical-instrument readout.
//   6. Center text   — gauge-tinted, glow-blurred via MultiEffect.

import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

Item {
    id: root

    // ── Public API ──────────────────────────────────────────────────────────
    property real   currentValue: 0
    property real   minValue:     0
    property real   maxValue:     100
    property color  gaugeColor:   "#22a4ff"
    property string title:        ""
    property string unit:         "%"
    property string displayText:  Math.round(root.currentValue) + root.unit
    property real   ringThickness: Math.max(12, Math.min(width, height) * 0.11)
    property bool   glowEnabled:  true

    // Smooth value transitions (data interface requirement)
    Behavior on currentValue {
        NumberAnimation { duration: 750; easing.type: Easing.OutQuart }
    }

    // 0..1 progress
    readonly property real ratio: {
        var span = root.maxValue - root.minValue
        if (span <= 0) return 0
        return Math.max(0, Math.min(1,
            (root.currentValue - root.minValue) / span))
    }

    // Derived shades for bevel passes
    readonly property color shadeDark:  Qt.darker (root.gaugeColor, 1.55)
    readonly property color shadeLight: Qt.lighter(root.gaugeColor, 1.45)

    implicitWidth:  220
    implicitHeight: 220

    // ── Title (optional) ────────────────────────────────────────────────────
    Text {
        id: titleText
        visible: root.title !== ""
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.title
        color: "#9ca3af"
        font.pixelSize: Math.max(14, Math.min(root.width, root.height) * 0.085)
        font.weight: Font.Medium
    }

    // ── Donut frame ─────────────────────────────────────────────────────────
    Item {
        id: ring
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top:    titleText.visible ? titleText.bottom : parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: titleText.visible ? 6 : 0
        width: Math.min(parent.width, height)

        readonly property real cx:     width / 2
        readonly property real cy:     height / 2
        readonly property real rOuter: Math.min(width, height) / 2 - 6
        readonly property real rMid:   rOuter - root.ringThickness / 2
        readonly property real rInner: rOuter - root.ringThickness

        // Pre-compute head-cap (x,y) on the unit-angle circle. JS Math runs
        // once per ratio change, then Behavior animation drives smooth motion.
        readonly property real headAngleRad:
            (-90 + root.ratio * 360) * Math.PI / 180
        readonly property real headX: cx + rMid * Math.cos(headAngleRad)
        readonly property real headY: cy + rMid * Math.sin(headAngleRad)

        // ── Static cache layer ──────────────────────────────────────────────
        // Glass bowl + 4 track-ring passes never animate. Wrap them in an
        // Item with layer.enabled so the scene graph renders them ONCE into
        // an FBO, then re-uses that texture every frame — no Shape path
        // tessellation, no binding re-evaluation during the active-arc
        // animation. Only invalidates on resize.
        Item {
            id: staticLayer
            anchors.fill: parent
            layer.enabled: true
            layer.smooth:  true

            // 1. ── Glass bowl (recessed inner panel) ───────────────────────
            Rectangle {
                id: glassBowl
                anchors.centerIn: parent
                width:  ring.rInner * 2 - 2
                height: ring.rInner * 2 - 2
                radius: width / 2
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: "#202733" }
                    GradientStop { position: 1.0; color: "#0c1018" }
                }
                border.color: "#06090f"
                border.width: 1
                layer.enabled: true
                layer.smooth:  true
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor:           "#aa000000"
                    shadowBlur:            0.65
                    shadowVerticalOffset:  4
                    shadowHorizontalOffset: 0
                    autoPaddingEnabled:    true
                }
            }
            // Subtle top crescent highlight on the bowl rim
            Rectangle {
                anchors.fill: glassBowl
                radius: width / 2
                color: "transparent"
                border.color: "#ffffff"
                border.width: 1
                opacity: 0.05
            }

            // 2. ── Track ring (4-pass tube cross-section) ──────────────────
            // 2a. Outer groove shadow — slightly wider, very dark
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: "#06080d"
                    strokeWidth: root.ringThickness + 2
                    PathAngleArc {
                        centerX: ring.cx; centerY: ring.cy
                        radiusX: ring.rMid; radiusY: ring.rMid
                        startAngle: -90; sweepAngle: 360
                    }
                }
            }
            // 2b. Mid face — neutral mid-tone
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: "#1d232f"
                    strokeWidth: root.ringThickness
                    PathAngleArc {
                        centerX: ring.cx; centerY: ring.cy
                        radiusX: ring.rMid; radiusY: ring.rMid
                        startAngle: -90; sweepAngle: 360
                    }
                }
            }
            // 2c. Inner-edge shadow (groove on the inside of the track)
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: "#05080d"
                    strokeWidth: 1.5
                    PathAngleArc {
                        centerX: ring.cx; centerY: ring.cy
                        radiusX: ring.rInner + 1; radiusY: ring.rInner + 1
                        startAngle: -90; sweepAngle: 360
                    }
                }
            }
            // 2d. Outer-edge rim highlight (top-left light hitting the crown)
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: "#3b4452"
                    strokeWidth: 1.0
                    PathAngleArc {
                        centerX: ring.cx; centerY: ring.cy
                        radiusX: ring.rOuter - 0.5; radiusY: ring.rOuter - 0.5
                        startAngle: -90; sweepAngle: 360
                    }
                }
            }
        }

        // 3. ── Glow halo (single MultiEffect layer wrapping all glow geometry) ─
        Item {
            id: glowLayer
            anchors.fill: parent
            visible: root.ratio > 0 && root.glowEnabled
            layer.enabled: root.glowEnabled
            layer.smooth:  true
            layer.effect: MultiEffect {
                blurEnabled:        true
                blur:               0.65
                blurMax:            14
                brightness:         0.22
                saturation:         0.30
                autoPaddingEnabled: true
            }

            // Halo arc — wider, slightly transparent, same path as base
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.gaugeColor
                    strokeWidth: root.ringThickness * 1.2
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: ring.cx; centerY: ring.cy
                        radiusX: ring.rMid; radiusY: ring.rMid
                        startAngle: -90
                        sweepAngle: root.ratio * 360
                    }
                }
                opacity: 0.85
            }

            // 5. Head-cap disc — neon "tip" of the progress arc
            Rectangle {
                width:  root.ringThickness * 1.45
                height: width
                radius: width / 2
                color:  root.shadeLight
                visible: root.ratio > 0.002 && root.ratio < 0.998
                x: ring.headX - width  / 2
                y: ring.headY - height / 2
            }
        }

        // 4. ── Active arc bevel (4 passes, back → front) ───────────────────
        // 4a. Inner shadow — darker stroke nudged toward the inner edge
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            visible: root.ratio > 0
            ShapePath {
                fillColor: "transparent"
                strokeColor: root.shadeDark
                strokeWidth: root.ringThickness * 0.85
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: ring.cx; centerY: ring.cy
                    radiusX: ring.rMid - root.ringThickness * 0.08
                    radiusY: ring.rMid - root.ringThickness * 0.08
                    startAngle: -90
                    sweepAngle: root.ratio * 360
                }
            }
        }
        // 4b. Base saturated color
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            visible: root.ratio > 0
            ShapePath {
                fillColor: "transparent"
                strokeColor: root.gaugeColor
                strokeWidth: root.ringThickness * 0.80
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: ring.cx; centerY: ring.cy
                    radiusX: ring.rMid; radiusY: ring.rMid
                    startAngle: -90
                    sweepAngle: root.ratio * 360
                }
            }
        }
        // 4c. Bevel highlight on the OUTER edge (lit by top-left light)
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            visible: root.ratio > 0
            ShapePath {
                fillColor: "transparent"
                strokeColor: root.shadeLight
                strokeWidth: root.ringThickness * 0.28
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: ring.cx; centerY: ring.cy
                    radiusX: ring.rMid + root.ringThickness * 0.26
                    radiusY: ring.rMid + root.ringThickness * 0.26
                    startAngle: -90
                    sweepAngle: root.ratio * 360
                }
            }
        }
        // 4d. (removed at half-size — specular sliver invisible, saves a pass)

        // 6. ── Center value text (no FBO; rely on gaugeColor for tint) ─────
        Text {
            anchors.centerIn: parent
            text: root.displayText
            color: root.gaugeColor
            font.pixelSize: Math.max(16, ring.rInner * 0.70)
            font.bold: true
        }
    }
}
