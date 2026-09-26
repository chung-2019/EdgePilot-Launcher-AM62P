import QtQuick
import QtQuick3D

import "MissionMath.js" as M

// Every drawn mission trajectory, in the mission frame.
//
// Two kinds of line:
//
//   * Closed ellipses (Earth parking, lunar capture set, lunar return) reuse
//     OrbitRing's single ring texture with independent x/z scales — 1 draw call
//     each, anti-aliased by the texture rather than by MSAA.
//   * Open space curves become dotted TrajectoryPath runs, because a textured
//     plane cannot follow a curve and custom geometry is unavailable in this
//     build.
//
// Sample counts are deliberately low (9-22 per curve, ~90 markers total). The
// whole node can be switched off from the page, and the re-entry corridor only
// exists during the phases that use it.
Node {
    id: root

    required property var controller

    readonly property var g: controller ? controller.geom : null
    readonly property real ms: g ? g.moonScale : 1
    readonly property real moonCenterX: controller ? controller.moonOrbitRadius : 0

    // ── Dynamic corridors ───────────────────────────────────────────────
    //
    // These two are anchored on the launch site, so they track the Earth's
    // rotation: the binding re-evaluates whenever taiwanFrame()'s inputs
    // change. The reference freezes the launch corridor at its start-up
    // position instead, which drifts away from the actual launch after the
    // first cycle.
    readonly property var launchCorridorPoints: {
        if (!controller)
            return []

        // Same control points the vehicle flies, sampled for the drawn line —
        // built once here rather than per sample, since the pad moves and the
        // whole set is rebuilt every frame.
        const pts = controller.launchPathPoints()
        const tension = controller.launchTension
        const steps = 18
        const out = []

        for (let i = 0; i < steps; ++i)
            out.push(M.catmullRomPoint(pts, tension, i / (steps - 1)))

        return M.toVector3dList(out)
    }

    // ── Burn markers ────────────────────────────────────────────────────
    //
    // A flat pulsing disc, not the reference's torus: there is no torus
    // primitive, and the ring texture's line width scales with its radius, so
    // at ~5 world units it would mip away to nothing.
    component BurnMarker: Model {
        id: marker

        property real diameter: 11
        property color markerColor: "#ffb15d"
        property real markerOpacity: 0.62
        property real pulseScale: 1

        source: "#Cylinder"
        eulerRotation.x: 0

        scale: Qt.vector3d(diameter / 100 * pulseScale,
                           0.5 / 100,
                           diameter / 100 * pulseScale)

        opacity: markerOpacity

        materials: PrincipledMaterial {
            baseColor: marker.markerColor
            lighting: PrincipledMaterial.NoLighting
            alphaMode: PrincipledMaterial.Blend
            cullMode: Material.NoCulling
        }
    }

    // ── Earth departure ─────────────────────────────────────────────────

    OrbitRing {
        centerX: root.g ? root.g.parkCenterX : 0
        y: root.g ? root.g.parkY : 0
        radius: root.g ? root.g.parkRadiusX : 1
        radiusZ: root.g ? root.g.parkRadiusZ : 1
        ringColor: "#aeb9c7"
        ringOpacity: 0.5
    }

    TrajectoryPath {
        points: root.launchCorridorPoints
        pathColor: "#ffb174"
        pathOpacity: 0.62
        markerSize: 2.6
    }

    BurnMarker {
        position: root.g ? M.toVector3d(root.g.tliPosition) : Qt.vector3d(0, 0, 0)
        markerColor: "#ffb15d"
        markerOpacity: root.controller ? root.controller.tliMarkerOpacity : 0.6
        pulseScale: root.controller ? root.controller.tliMarkerScale : 1
    }

    // ── Earth -> Moon ───────────────────────────────────────────────────

    TrajectoryPath {
        points: root.g ? M.toVector3dList(root.g.transfer.sample(22)) : []
        pathColor: "#d1d8df"
        pathOpacity: 0.72
    }

    TrajectoryPath {
        points: root.g ? M.toVector3dList(root.g.captureEntry.sample(10)) : []
        pathColor: "#c7d0d8"
        pathOpacity: 0.5
        markerSize: 2.1
    }

    // ── Lunar orbits ────────────────────────────────────────────────────
    //
    // The capture spiral steps down through these three, then the return orbit
    // is the fourth.

    // Three rings spanning the spiral the probe actually flies — entry radius
    // down to entry x captureEndScale — rather than the reference's fixed set,
    // whose innermost ring the spiral never reaches.
    component CaptureRing: OrbitRing {
        required property real step   // 0 = entry radius, 1 = spiral end

        readonly property real shrink:
            root.g ? 1 - (1 - root.g.captureEndScale) * step : 1

        centerX: root.moonCenterX
        y: root.g ? root.g.captureY : 0
        radius: root.g ? root.g.captureRadiusX * shrink : 1
        radiusZ: root.g ? root.g.captureRadiusZ * shrink : 1
        ringColor: "#b9c1ca"
    }

    CaptureRing {
        step: 0
        ringOpacity: 0.42
    }

    CaptureRing {
        step: 0.5
        ringOpacity: 0.5
    }

    CaptureRing {
        step: 1
        ringOpacity: 0.58
    }

    OrbitRing {
        centerX: root.moonCenterX
        y: root.g ? root.g.returnY : 0
        radius: root.g ? root.g.returnRadiusX : 1
        radiusZ: root.g ? root.g.returnRadiusZ : 1
        ringColor: "#91c9f0"
        ringOpacity: 0.56
    }

    // ── Lunar surface operations ────────────────────────────────────────

    TrajectoryPath {
        points: root.g ? M.toVector3dList(root.g.descent.sample(9)) : []
        pathColor: "#e7edf2"
        pathOpacity: 0.66
        markerSize: 2.0
    }

    TrajectoryPath {
        points: root.g ? M.toVector3dList(root.g.lunarAscent.sample(10)) : []
        pathColor: "#9fd9ff"
        pathOpacity: 0.62
        markerSize: 2.0
    }

    // ── Moon -> Earth ───────────────────────────────────────────────────

    BurnMarker {
        position: root.g ? M.toVector3d(root.g.teiPosition) : Qt.vector3d(0, 0, 0)
        diameter: 10
        markerColor: "#75cfff"
        markerOpacity: root.controller ? root.controller.teiMarkerOpacity : 0.6
        pulseScale: root.controller ? root.controller.teiMarkerScale : 1
    }

    TrajectoryPath {
        points: root.g ? M.toVector3dList(root.g.earthReturn.sample(22)) : []
        pathColor: "#8fc7e9"
        pathOpacity: 0.7
    }

    // Earth-entry corridor. The controller only populates this during the
    // return and entry phases, so the markers do not exist the rest of the
    // time.
    TrajectoryPath {
        points: root.controller ? root.controller.reentryPathPoints : []
        pathColor: "#ffa56b"
        pathOpacity: 0.58
        markerSize: 2.3
    }
}
