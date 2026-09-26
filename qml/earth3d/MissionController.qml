import QtQuick

import "MissionMath.js" as M

// Taiwan–Moon round-trip mission state machine.
//
// Behaviour is ported from the three.js reference,
// am62p-earth-moon/interactive_3d_taiwan_moon_round_trip_loop.html, and follows
// the phase model in AM62P_Qt_QML_3D_Lunar_Mission_Architecture.md. The doc puts
// this in C++; it cannot be, because the cross-compile sysroot ships no Quick3D
// headers (see EarthMoonPage.qml) and a C++ controller would still have to hand
// Quick3D types across the boundary. So: QML, and deliberately NO QtQuick3D
// import here — this file is pure maths and plain value types, which keeps it
// loadable even where the 3D module is missing.
//
// The invariant the whole thing is built around, from §8 of the doc: every phase
// boundary must agree on position, tangent AND attitude. Nothing here is allowed
// to teleport, which is why the burn phases hold station at a fixed point and
// blend the tangent instead of cutting straight to the next curve.
Item {
    id: root

    // ── Input ───────────────────────────────────────────────────────────
    //
    // Driven from EarthMoonPage: the page owns the clock so pause / speed /
    // reset survive a scene reload.

    // Normalised mission time, 0..1.
    property real missionTime: 0

    // Scene angles, needed because the launch and re-entry points ride the
    // rotating Earth while the whole mission frame rides the Moon's orbit.
    property real earthRotationAngle: 0
    property real moonOrbitAngle: 0

    // ── Scene scale ─────────────────────────────────────────────────────
    //
    // The reference scene is EARTH_RADIUS = 2, MOON_ORBIT_RADIUS = 8. This one
    // is earthRadius = 80 (built-in "#Sphere" r=50 x 1.6) and
    // moonOrbitRadius = 230, and 80/2 != 230/8 — the Earth here is
    // proportionally larger. One global factor therefore cannot serve both:
    // scaled by the orbit, the parking ellipse's minor radius (2.46) would land
    // at 70 world units and sink into an 80-unit Earth.
    //
    // So there are two: earthScale for anything that has to sit just above the
    // Earth's surface, moonScale for the Earth–Moon distance and everything
    // near the Moon. Phase continuity is unaffected — boundary values are
    // always produced by the same expression on both sides.
    readonly property real earthRadius: 80
    readonly property real moonOrbitRadius: 230
    readonly property real moonRadius: 21

    readonly property real earthScale: earthRadius / 2.0      // 40
    readonly property real moonScale: moonOrbitRadius / 8.0   // 28.75

    // Landing curves in the reference graze the lunar surface (0.72 vs a 0.74
    // radius). Lift them clear so the probe stands on the regolith instead of
    // half inside it.
    readonly property real lunarSurfaceLift: 5.5

    readonly property real taiwanLatitude: 23.7
    readonly property real taiwanLongitude: 121.0

    // Correction between three.js's equirectangular convention, which the
    // lat/lon formula came from, and Qt Quick 3D's built-in "#Sphere".
    //
    // three.js maps longitude 0 to +X; Qt maps it to +Z. That is a 90° swap, and
    // without it the pad lands in the Atlantic off West Africa — verified by
    // rendering the globe on the EVM and looking: -90 puts the marker on Taiwan,
    // -75 puts it in the Philippine Sea.
    //
    // Still a property, because a different equirectangular map with a different
    // seam would need a different value.
    property real earthTextureLongitudeOffset: -90

    // ── Phase boundaries (normalised) ───────────────────────────────────
    //
    // Same table as the reference so the pacing carries over exactly.
    readonly property real launchAscentEnd: 0.08
    readonly property real fairingSeparationEnd: 0.13
    readonly property real earthParkEnd: 0.27
    readonly property real tliBurnEnd: 0.32
    readonly property real transferEnd: 0.49
    readonly property real probeDeployEnd: 0.57
    readonly property real lunarCaptureEnd: 0.65
    readonly property real descentEnd: 0.69
    readonly property real lunarSurfaceEnd: 0.73
    readonly property real lunarAscentEnd: 0.78
    readonly property real lunarReturnOrbitEnd: 0.83
    readonly property real teiBurnEnd: 0.87
    readonly property real earthReturnEnd: 0.955
    readonly property real earthReentryEnd: 0.988

    // ── Output: launch vehicle ──────────────────────────────────────────

    property string phaseName: "Launch over Taiwan"

    property bool launchVehicleVisible: true
    property vector3d launchVehiclePosition: Qt.vector3d(0, 0, 0)
    property quaternion launchVehicleRotation: Qt.quaternion(1, 0, 0, 0)
    property vector3d launchVehicleTumble: Qt.vector3d(0, 0, 0)

    property bool coreStageVisible: true
    property vector3d coreStageOffset: Qt.vector3d(0, 0, 0)
    property vector3d coreStageEuler: Qt.vector3d(0, 0, 0)

    property bool fairingVisible: true
    property vector3d fairingLeftOffset: Qt.vector3d(0, 0, 0)
    property vector3d fairingLeftEuler: Qt.vector3d(0, 0, 0)
    property vector3d fairingRightOffset: Qt.vector3d(0, 0, 0)
    property vector3d fairingRightEuler: Qt.vector3d(0, 0, 0)

    property real bayDoorAngle: 0

    property bool launchBurning: true
    property real launchThrottle: 1

    // ── Output: lunar probe ─────────────────────────────────────────────

    property bool probeVisible: false
    property vector3d probePosition: Qt.vector3d(0, 0, 0)
    property quaternion probeRotation: Qt.quaternion(1, 0, 0, 0)
    property vector3d probeTumble: Qt.vector3d(0, 0, 0)

    // 0 = stowed, 1 = solar wings and dish fully deployed.
    property real probeDeploy: 0
    property bool probeBurning: false
    property real reentryGlow: 0

    // ── Output: markers, camera, dynamic path ───────────────────────────

    property real tliMarkerOpacity: 0.62
    property real tliMarkerScale: 1
    property real teiMarkerOpacity: 0.62
    property real teiMarkerScale: 1

    // Whichever object the camera should track, in mission-frame and in world
    // coordinates. The camera rig lives on the scene root, so it needs world.
    property vector3d activeVehiclePosition: Qt.vector3d(0, 0, 0)
    property vector3d activeVehicleWorldPosition: Qt.vector3d(0, 0, 0)

    // Earth-entry corridor. Its far end tracks the rotating Taiwan surface
    // point, so unlike every other path this one is rebuilt as it is used.
    property var reentryPathPoints: []

    // ── Static geometry ─────────────────────────────────────────────────
    //
    // Built once. Everything below is in the mission frame, i.e. under the
    // Moon's orbit pivot, so the whole route stays aligned with the Moon.

    readonly property var geom: buildGeometry()

    function buildGeometry() {
        const es = earthScale
        const ms = moonScale
        const moonCenter = [moonOrbitRadius, 0, 0]

        // ── Earth parking ellipse
        const parkCenterX = 0.28 * es
        const parkRadiusX = 3.34 * es
        const parkRadiusZ = 2.46 * es
        const parkY = 0.10 * es

        // Injection point on the parking orbit.
        //
        // -pi/2 is the far end of the ellipse in -z, where the orbital velocity
        // points along +x — straight at the Moon, which in this frame always
        // sits at +x. That is where a real TLI burn happens, and it is what lets
        // the transfer arc leave along the orbit tangent without a 90° turn.
        //
        // The reference uses -0.12, whose tangent is almost pure +z: its
        // transfer curve has to swing 78° immediately after the burn, and the
        // curvature that takes is visible as the vehicle snapping round.
        const tliAngle = -Math.PI / 2

        const tliPosition = M.ellipsePoint(parkCenterX, 0,
                                          parkRadiusX, parkRadiusZ,
                                          tliAngle, parkY)
        const tliOrbitTangent = M.ellipseTangent(parkRadiusX, parkRadiusZ,
                                                 tliAngle)

        // The insertion point is NOT here — it depends on where the pad is when
        // the ascent ends, so it lives outside this fixed geometry. See the
        // `insertion` property.

        // ── Lunar capture
        //
        // Solved BEFORE the transfer, because the transfer's job is to arrive on
        // the capture approach line. The reference does it the other way round
        // and the far end of its route is not flyable: the deployment point ends
        // up on the far side of the Moon from Earth while the probe arrives from
        // the near side, so the path has to overshoot and double back. The
        // tangent reverses mid-curve, and once the phase boundaries are made
        // continuous that reversal is what is left over.
        const captureRadiusX = 1.55 * ms
        const captureRadiusZ = 1.16 * ms
        const captureY = 0.12 * ms

        // Entry angle picked so the orbit's tangent at entry lines up with the
        // direction the probe actually arrives from.
        //
        // Solving -tan(a) * (radiusX / radiusZ) for the Earth-to-Moon approach
        // heading gives ~-1.03 rad, and at that angle the approach and the orbit
        // tangent differ by under 10° — so the capture-entry curve only has to
        // turn a little, over a short run, instead of absorbing a 78° swing.
        //
        // Any angle satisfies position continuity; only this one also keeps the
        // curvature low enough that the attitude does not visibly snap.
        const captureStartAngle = -1.03

        // The reference spirals down to 0.48 of the entry radius, which at this
        // Moon size puts the last turn ~19 units from the centre — inside a
        // 21-unit Moon. 0.80 keeps the whole spiral clear of the surface and
        // still reads as a descent.
        const captureEndScale = 0.80

        // Where the spiral hands over to the powered descent. Just upstream of
        // the landing site's own orbital angle (~3.11 rad), so the descent curve
        // runs forward onto the pad.
        //
        // The reference instead sweeps a fixed 4.15pi and hands over wherever
        // that lands — with these radii, on the opposite side of the Moon from
        // the pad, so its descent has to double back and the tangent reverses.
        const descentStartAngle = 2.5

        // Two full turns, finishing exactly on descentStartAngle.
        const captureSpiralSweep =
            descentStartAngle + Math.PI * 4 - captureStartAngle

        const captureEndAngle = captureStartAngle + captureSpiralSweep

        // How far upstream of orbit entry the probe is released. The deployment
        // phase slides the probe forward by exactly this much, so it arrives at
        // captureOrbitStart as that phase ends.
        const deploymentRun = 0.70 * ms

        const captureOrbitStart = M.ellipsePoint(moonOrbitRadius, 0,
                                                 captureRadiusX, captureRadiusZ,
                                                 captureStartAngle, captureY)
        const captureTangentStart = M.ellipseTangent(captureRadiusX,
                                                     captureRadiusZ,
                                                     captureStartAngle)

        const captureEndRadiusX = captureRadiusX * captureEndScale
        const captureEndRadiusZ = captureRadiusZ * captureEndScale

        const captureEndPosition = M.ellipsePoint(moonOrbitRadius, 0,
                                                  captureEndRadiusX,
                                                  captureEndRadiusZ,
                                                  captureEndAngle, captureY)
        const captureEndTangent = M.ellipseTangent(captureEndRadiusX,
                                                   captureEndRadiusZ,
                                                   captureEndAngle)

        const captureDeploymentEnd = M.addScaled(captureOrbitStart,
                                                 captureTangentStart,
                                                 -deploymentRun)

        // ── Earth -> Moon transfer
        //
        // Anchored on the parking orbit at the Earth end (earthScale) and on the
        // capture approach line at the Moon end (moonScale), so transfer,
        // capture entry and orbit insertion all travel the same way.
        const transferEndPoint = M.addScaled(captureDeploymentEnd,
                                             captureTangentStart, -0.60 * ms)

        const transferControl1 =
            M.add(M.addScaled(tliPosition, tliOrbitTangent, 1.28 * es),
                  [0, 0.44 * es, 0])

        // Back along the approach line, lifted to give the crossing its arc.
        // The lift tilts the arrival heading ~29° off the approach line, which
        // the capture-entry curve absorbs by turning rather than reversing.
        const transferControl2 =
            M.add(M.addScaled(transferEndPoint, captureTangentStart, -1.80 * ms),
                  [0, 1.00 * ms, 0])

        const transfer = M.bezierCurve(tliPosition, transferControl1,
                                       transferControl2, transferEndPoint, 160)

        // Attitude the vehicle must reach before the TLI burn, and the heading
        // it hands to the capture-entry curve at the far end.
        const tliTransferTangent = transfer.tangentAt(0)
        const transferEndTangent = transfer.tangentAt(1)

        // Catmull-Rom end tangents are (points[1] - points[0]) at the start and
        // (points[3] - points[2]) at the end — the tension cancels out. So the
        // two interior points go along the neighbouring phases' tangents, and
        // this curve joins the transfer arc to the capture ellipse smoothly
        // instead of at the reference's ~139° kink.
        const captureEntry = M.catmullRomCurve([
            transferEndPoint,
            M.addScaled(transferEndPoint, transferEndTangent, 0.25 * ms),
            M.addScaled(captureDeploymentEnd, captureTangentStart, -0.25 * ms),
            captureDeploymentEnd
        ], 0.42, 96)

        // ── Lunar descent / surface / ascent
        //
        // Every point is pushed radially clear of the surface by
        // lunarSurfaceLift, which keeps the whole descent above the regolith
        // rather than only fixing the touchdown point.
        function liftFromMoon(p) {
            const radial = M.normalize(M.sub(p, moonCenter))
            return M.addScaled(p, radial, lunarSurfaceLift)
        }

        // Touchdown point: the reference's, lifted clear of the surface.
        const landingPosition =
            liftFromMoon(M.add(moonCenter, [-0.72 * ms, 0.06 * ms, 0.02 * ms]))

        // Local vertical at the pad. This is the probe's attitude while it
        // stands on the surface, and it is also the direction it comes down and
        // goes back up along, which is what makes those three phases join.
        const landingUp = M.normalize(M.sub(landingPosition, moonCenter))

        // Descent leaves the capture spiral where the spiral actually ends,
        // heading the same way, and arrives coming straight down. The reference
        // starts this curve at a hardcoded point ~15 units off the end of its
        // own spiral.
        const descentPoints = [
            captureEndPosition,
            M.addScaled(captureEndPosition, captureEndTangent, 0.20 * ms),
            M.addScaled(landingPosition, landingUp, 0.15 * ms),
            landingPosition
        ]

        const descent = M.catmullRomCurve(descentPoints, 0.35, 72)

        // Return orbit, outside the capture set.
        //
        // The reference's 1.02 / 0.76 put it ~28 units from the Moon's centre,
        // only 2 above the pad — so "lift off and reach orbit" had almost no
        // altitude in it, and the ascent curve had to double back on itself to
        // reach an insertion point barely higher than its start. 1.6 / 1.2 gives
        // the climb ~18 units of gain, which is what makes it read as a launch.
        const returnRadiusX = 1.60 * ms
        const returnRadiusZ = 1.20 * ms
        const returnY = 0.13 * ms

        // Orbit insertion after lift-off, set half a radian downstream of the
        // pad's own angle so the ascent climbs and then turns onto the orbit in
        // one direction. The reference's 0.48 rad puts insertion on the far side
        // of the Moon from the pad — the ascent path would cross the Moon and
        // reverse its tangent doing it.
        const ascentStartAngle = 3.6
        const teiAngle = Math.PI

        const ascentOrbitPoint = M.ellipsePoint(moonOrbitRadius, 0,
                                               returnRadiusX, returnRadiusZ,
                                               ascentStartAngle, returnY)

        const ascentTangent = M.ellipseTangent(returnRadiusX, returnRadiusZ,
                                              ascentStartAngle)

        // Straight up off the pad, then over onto the return orbit's heading.
        const lunarAscent = M.catmullRomCurve([
            landingPosition,
            M.addScaled(landingPosition, landingUp, 0.30 * ms),
            M.addScaled(ascentOrbitPoint, ascentTangent, -0.45 * ms),
            ascentOrbitPoint
        ], 0.38, 96)

        // ── Moon -> Earth return
        const teiPosition = M.ellipsePoint(moonOrbitRadius, 0,
                                           returnRadiusX, returnRadiusZ,
                                           teiAngle, returnY)
        const teiOrbitTangent = M.ellipseTangent(returnRadiusX, returnRadiusZ,
                                                 teiAngle)

        const returnEndPoint = [2.55 * es, 0.46 * es, -0.30 * es]

        const returnControl1 =
            M.add(M.addScaled(teiPosition, teiOrbitTangent, 1.00 * ms),
                  [-0.30 * ms, 0.48 * ms, 0])

        const returnControl2 = [3.35 * ms, 2.30 * ms, -1.36 * ms]

        const earthReturn = M.bezierCurve(teiPosition, returnControl1,
                                          returnControl2, returnEndPoint, 160)

        const teiTransferTangent = earthReturn.tangentAt(0)
        const earthReturnEndTangent = earthReturn.tangentAt(1)

        return {
            earthScale: es,
            moonScale: ms,
            moonCenter: moonCenter,

            parkCenterX: parkCenterX,
            parkRadiusX: parkRadiusX,
            parkRadiusZ: parkRadiusZ,
            parkY: parkY,

            tliAngle: tliAngle,
            tliPosition: tliPosition,
            tliOrbitTangent: tliOrbitTangent,
            tliTransferTangent: tliTransferTangent,

            // Insertion happens 1.2*pi before the parking orbit proper starts,
            // and the orbit finishes exactly on the Moon-facing TLI angle after
            // four full turns — that exact landing is what lets the burn phase
            // hold station instead of jumping.
            parkEndAngle: tliAngle + Math.PI * 2 * 4,

            transfer: transfer,
            transferEndTangent: transferEndTangent,

            captureRadiusX: captureRadiusX,
            captureRadiusZ: captureRadiusZ,
            captureY: captureY,
            captureStartAngle: captureStartAngle,
            captureEndScale: captureEndScale,
            captureSpiralSweep: captureSpiralSweep,
            deploymentRun: deploymentRun,
            captureOrbitStart: captureOrbitStart,
            captureTangentStart: captureTangentStart,
            captureEndPosition: captureEndPosition,
            captureEndTangent: captureEndTangent,
            captureEntry: captureEntry,

            descent: descent,
            landingPosition: landingPosition,
            landingUp: landingUp,

            returnRadiusX: returnRadiusX,
            returnRadiusZ: returnRadiusZ,
            returnY: returnY,
            ascentStartAngle: ascentStartAngle,
            ascentTangent: ascentTangent,
            teiAngle: teiAngle,
            lunarAscent: lunarAscent,

            teiPosition: teiPosition,
            teiOrbitTangent: teiOrbitTangent,
            teiTransferTangent: teiTransferTangent,
            earthReturn: earthReturn,
            earthReturnEndTangent: earthReturnEndTangent,
            returnEndPoint: returnEndPoint
        }
    }

    // ── Taiwan launch frame ─────────────────────────────────────────────
    //
    // The three.js version does this with localToWorld / worldToLocal on live
    // scene matrices. There is no equivalent that is cheap to call from QML
    // every frame, so the two node chains are applied by hand:
    //
    //   Earth:   tilt(z = -23.4) -> spin(y = earthRotationAngle)
    //   Mission: orbit plane(x = 5.1) -> orbit pivot(y = moonOrbitAngle)
    //
    // Keep these in step with EarthMoonScene.qml and Earth.qml.
    readonly property real earthAxialTilt: -23.4
    readonly property real moonOrbitInclination: 5.1

    function earthLocalToMissionAt(local, earthAngle, moonAngle) {
        const world = M.rotateZ(M.rotateY(local, earthAngle), earthAxialTilt)
        return M.rotateY(M.rotateX(world, -moonOrbitInclination), -moonAngle)
    }

    function earthLocalToMission(local) {
        return earthLocalToMissionAt(local, earthRotationAngle, moonOrbitAngle)
    }

    function missionToWorld(p) {
        return M.rotateX(M.rotateY(p, moonOrbitAngle), moonOrbitInclination)
    }

    // Position, local up and local east at the launch site, in mission frame,
    // for a given Earth spin and Moon orbit angle.
    function taiwanFrameAt(earthAngle, moonAngle) {
        const r = earthRadius * 1.015

        const surface = earthLocalToMissionAt(
            M.latLonToVector3(taiwanLatitude, taiwanLongitude, r,
                              earthTextureLongitudeOffset),
            earthAngle, moonAngle)

        // A point slightly further east gives the local heading without any
        // extra trigonometry.
        const east = earthLocalToMissionAt(
            M.latLonToVector3(taiwanLatitude, taiwanLongitude + 0.8, r,
                              earthTextureLongitudeOffset),
            earthAngle, moonAngle)

        // The Earth's centre is the mission-frame origin only up to the orbit
        // plane tilt, which does not move it — so the normal is just the
        // normalised surface point.
        return {
            position: surface,
            normal: M.normalize(surface),
            east: M.normalize(M.sub(east, surface))
        }
    }

    function taiwanFrame() {
        return taiwanFrameAt(earthRotationAngle, moonOrbitAngle)
    }

    // ── Orbit insertion point ───────────────────────────────────────────
    //
    // The insertion point CANNOT be a fixed angle on the parking orbit.
    //
    // The pad turns with the Earth at 18°/s and the ascent lasts 8.2 s, so
    // against a fixed insertion point the angle between them sweeps ~147° per
    // ascent — and every lap starts at a different Earth orientation, since the
    // mission is 102 s and the Earth's day is 20 s. At some point in that sweep
    // the two are nearly antipodal, and a great-circle route between antipodal
    // points has no defined direction: the arc plane flips from one side of the
    // planet to the other on rounding alone. On screen the rocket shoots over
    // the pole and drops back.
    //
    // Anchoring insertion a fixed angle DOWNSTREAM of the pad removes the
    // degeneracy outright — the ascent always turns through the same arc. It is
    // also what really happens: the insertion point of a launch depends on when
    // you launch.
    // How far downrange of the pad the orbit is entered.
    //
    // 40°, not the 75° first tried. The whole mission frame rides the Moon's
    // orbit pivot, which turns at 36°/s here, so anything in Earth orbit sweeps
    // out of view in a few seconds. A long ascent arc spends that budget before
    // the interesting part — the vehicle was already round the back by the time
    // the fairing came off.
    readonly property real launchArc: Math.PI * 0.22      // ~40° of downrange

    // Rates, kept in step with the page's clock. Not currently read, but the
    // insertion geometry is defined in terms of them.
    property real missionDuration: 102
    property real earthDegPerSecond: 18.0
    property real moonOrbitDegPerSecond: 9.0

    // Scene angles as they were at the START of the current lap, captured once
    // by the page's clock when the mission time wraps.
    //
    // Deriving these instead — `earthRotationAngle + (launchAscentEnd -
    // missionTime) * rate` — is algebraically identical but does not work,
    // because the two inputs are assigned SEPARATELY by the clock. Between
    // `earthRotationAngle = ...` and `missionElapsed = ...` the pair is
    // inconsistent, the derived insertion point moves, and the parking orbit
    // ends up somewhere different from where the ascent left off (measured:
    // a 167-unit jump at the fairing/parking boundary). One value, captured
    // once, has no such window.
    property real earthAngleAtLapStart: 0
    property real moonAngleAtLapStart: 0

    // The pad as it was at lift-off — the anchor for the whole ascent.
    //
    // Both ends of the ascent are pinned to this one instant, and that is the
    // point. Letting the path's start follow the live pad is wrong twice over:
    //
    //   * Physically. Once the rocket leaves the pad its trajectory belongs to
    //     the inertial frame; the pad keeps turning with the planet and the
    //     rocket does not care.
    //   * Numerically. The pad sweeps 147° during the ascent, so the angle
    //     between it and any fixed insertion point sweeps 147° too, and
    //     somewhere in that sweep it passes 180° — where a great-circle route
    //     has no defined side to go round and the arc flips across the planet.
    //
    // Anchored at lift-off, the pad-to-insertion angle is a constant `launchArc`
    // for the whole ascent, and there is nothing left to degenerate.
    readonly property var launchFrame:
        taiwanFrameAt(earthAngleAtLapStart, moonAngleAtLapStart)

    readonly property real insertionAngle: {
        const g = geom
        if (!g)
            return 0

        const dir = M.normalize(launchFrame.position)

        // Parking-orbit parameter angle beneath the pad. The ellipse is
        // (cx + cos a * rx, y, sin a * rz), so inverting it means dividing each
        // axis by its own radius before taking the arctangent.
        const bearing = Math.atan2(dir[2] / g.parkRadiusZ,
                                   (dir[0] - g.parkCenterX / g.parkRadiusX)
                                   / g.parkRadiusX)

        return bearing + launchArc
    }

    readonly property var insertion: {
        const g = geom
        if (!g)
            return null

        return {
            angle: insertionAngle,
            position: M.ellipsePoint(g.parkCenterX, 0,
                                     g.parkRadiusX, g.parkRadiusZ,
                                     insertionAngle, g.parkY),
            tangent: M.ellipseTangent(g.parkRadiusX, g.parkRadiusZ,
                                      insertionAngle)
        }
    }

    // Insertion happens 1.2*pi before the parking orbit proper starts, and the
    // orbit still finishes exactly on the Moon-facing TLI angle — that exact
    // landing is what lets the burn phase hold station instead of jumping.
    //
    // Now that insertion moves with the launch time, the number of parking
    // laps varies between roughly 1.9 and 3.2 depending on when the rocket left
    // the pad. The end of the orbit is unchanged, so everything downstream of
    // it — TLI, transfer, the whole lunar leg — is unaffected.
    readonly property real parkStartAngle: insertionAngle + Math.PI * 1.20

    // The pad as it will be at TOUCHDOWN, which is what entry aims at.
    //
    // Not the pad right now: the Earth turns ~60° during the entry phase, so
    // aiming at the live position lands the capsule short and, worse, reshapes
    // the path every frame. Aiming at the arrival position is both what a real
    // re-entry does and what makes the path a fixed curve.
    readonly property var touchdownFrame:
        taiwanFrameAt(earthAngleAtLapStart
                      + earthReentryEnd * missionDuration * earthDegPerSecond,
                      moonAngleAtLapStart
                      + earthReentryEnd * missionDuration
                        * moonOrbitDegPerSecond)

    // Earth-entry corridor.
    //
    // Same construction as the ascent, and for the same reason: the start of
    // this path is fixed in the mission frame while its end sits on the
    // rotating Earth, so a straight run between them is a chord — and a chord
    // subtending more than ~90° goes through the planet. Measured at 61 units
    // INSIDE the Earth before this was changed.
    function reentryControlPath() {
        const es = geom.earthScale
        const frame = touchdownFrame

        const start = geom.returnEndPoint

        // Leave the return arc along the heading it arrived on — the first pair
        // sets the start tangent. The reference uses a fixed offset here and the
        // probe swings ~94° the instant entry begins.
        const depart = M.addScaled(start, geom.earthReturnEndTangent, 0.62 * es)
        const departDir = M.normalize(depart)
        const departRadius = M.length(depart)

        const touchdown = M.addScaled(frame.position, frame.normal, 0.035 * es)

        // Directly above the touchdown point, so the end tangent is exactly
        // -normal and the retrograde attitude is exactly +normal — the upright
        // pose the final phase holds. The reference adds a sideways component
        // here, which leaves an ~11° step at that boundary.
        const entry = M.addScaled(touchdown, frame.normal, 1.28 * es)
        const entryDir = M.normalize(entry)
        const entryRadius = M.length(entry)

        const points = [start, depart]

        const arcSteps = 3
        for (let i = 1; i <= arcSteps; ++i) {
            const u = i / (arcSteps + 1)
            points.push(M.mul(M.slerpDir(departDir, entryDir, u),
                              M.lerp(departRadius, entryRadius, u)))
        }

        points.push(entry)
        points.push(touchdown)

        return points
    }

    // Launch corridor, anchored on the live Taiwan position.
    //
    // Control points for a Catmull-Rom, not a Bézier, and the middle ones ride
    // a great circle rather than a straight line. That is what stops the rocket
    // flying through the planet.
    //
    // The pad moves and the orbit insertion point does not: the Earth spins at
    // 18°/s and the ascent lasts 8.2 s, so over one ascent the angle between
    // them sweeps about 147°. Interpolating between two points on a sphere in a
    // straight line takes the chord, and any chord subtending more than ~90°
    // passes inside the sphere. The old four-point Bézier did exactly that for
    // most of the ascent.
    //
    // Here the intermediate points are slerped from the climb-out direction to
    // the insertion direction while the radius eases between them, so every
    // control point stays outside the surface and so does the curve through
    // them.
    readonly property real launchTension: 0.5

    function launchPathPoints() {
        const es = geom.earthScale

        // The pad at lift-off, not the pad now — see `launchFrame`.
        const frame = launchFrame

        const insertionPoint = insertion.position

        // Arriving along the parking orbit, not across it: this point and the
        // insertion point set the end tangent, which the next phase continues
        // from.
        const approach = M.addScaled(insertionPoint, insertion.tangent,
                                     -1.10 * es)
        const approachDir = M.normalize(approach)
        const approachRadius = M.length(approach)

        // Straight up off the pad — this pair sets the start tangent.
        const climb = M.addScaled(frame.position, frame.normal, 1.20 * es)
        const climbDir = M.normalize(climb)
        const climbRadius = M.length(climb)

        const points = [frame.position, climb]

        // The arc runs to the APPROACH point, not to the insertion point.
        // Aiming it at the insertion point instead leaves the last arc point
        // off the arc that reaches `approach`, and the curve has to kink to get
        // back on track — measured at 50° of attitude change in a single frame.
        const arcSteps = 4
        for (let i = 1; i <= arcSteps; ++i) {
            const u = i / (arcSteps + 1)
            points.push(M.mul(M.slerpDir(climbDir, approachDir, u),
                              M.lerp(climbRadius, approachRadius, u)))
        }

        points.push(approach)
        points.push(insertionPoint)

        return points
    }

    // ── Evaluation ──────────────────────────────────────────────────────

    onMissionTimeChanged: evaluate()
    onEarthRotationAngleChanged: evaluate()
    onEarthAngleAtLapStartChanged: evaluate()
    Component.onCompleted: evaluate()

    // Roll reference for every attitude. Both orbit planes are near the world
    // XZ plane, so world up is never close to a flight direction and the basis
    // it defines is well conditioned everywhere on the route.
    //
    // Vehicles are modelled nose-along-local-+X, as the mesh assets and the
    // architecture doc both assume.
    readonly property var upHint: [0, 1, 0]

    function poseFrom(tangent) {
        return M.toQuaternion(M.poseAlong(tangent, upHint))
    }

    // Nose-forward to engine-forward: the retrograde flip a vehicle performs
    // before it brakes. `flip` runs 0..1.
    //
    // Composed as a rotation about the vehicle's own +Y rather than interpolated
    // between the two end orientations, and neither alternative survives:
    //
    //   * Lerping the tangent VECTORS passes through the zero vector at the
    //     halfway point, because they are antiparallel.
    //   * Slerping the two ORIENTATIONS is degenerate for exactly the same
    //     reason. At 180° the short arc is not unique, so the sign of the
    //     quaternion dot product decides which half to travel — and that sign
    //     flips on rounding, snapping the attitude mid-flip.
    //
    // Composing is exact: poseAlong(-t) is identically poseAlong(t) turned 180°
    // about local +Y (the basis goes from (x, y, z) to (-x, y, -z)), so scaling
    // that angle by `flip` interpolates the flip itself with nothing to go
    // degenerate.
    function retrogradePose(tangent, flip) {
        return M.toQuaternion(
            M.quatMultiply(M.poseAlong(tangent, upHint),
                           M.quatFromAxisAngle([0, 1, 0], 180 * flip)))
    }

    function resetPerFrameState() {
        launchVehicleVisible = true
        coreStageVisible = true
        fairingVisible = true

        coreStageOffset = Qt.vector3d(0, 0, 0)
        coreStageEuler = Qt.vector3d(0, 0, 0)
        fairingLeftOffset = Qt.vector3d(0, 0, 0)
        fairingLeftEuler = Qt.vector3d(0, 0, 0)
        fairingRightOffset = Qt.vector3d(0, 0, 0)
        fairingRightEuler = Qt.vector3d(0, 0, 0)
        launchVehicleTumble = Qt.vector3d(0, 0, 0)

        bayDoorAngle = 0

        probeVisible = false
        probeTumble = Qt.vector3d(0, 0, 0)
        probeDeploy = 0
        probeBurning = false
        reentryGlow = 0

        launchBurning = false
        launchThrottle = 0

        tliMarkerOpacity = 0.62
        tliMarkerScale = 1
        teiMarkerOpacity = 0.62
        teiMarkerScale = 1
    }

    function evaluate() {
        const g = geom
        if (!g)
            return

        const es = g.earthScale
        const ms = g.moonScale
        const t = missionTime
        // The reference pulses flames off performance.now(); mission time in
        // milliseconds is the same unit and stops when the mission stops.
        const now = t * 102000

        resetPerFrameState()

        // Mission-frame pose of whichever object is currently active.
        let activePos = [0, 0, 0]

        if (t < launchAscentEnd) {
            // ── Launch from Taiwan
            const progress = t / launchAscentEnd
            const eased = M.easeInOut(progress)

            // Build the control points once and sample them three times, rather
            // than going through an arc-length curve: this path is rebuilt every
            // frame (the pad moves with the planet) and the ascent does not need
            // constant-speed parameterisation.
            const pts = launchPathPoints()
            const p = M.catmullRomPoint(pts, launchTension, eased)

            const du = 0.002
            const before = M.catmullRomPoint(pts, launchTension,
                                             Math.max(0, eased - du))
            const after = M.catmullRomPoint(pts, launchTension,
                                            Math.min(1, eased + du))
            const tangent = M.normalize(M.sub(after, before))

            launchVehiclePosition = M.toVector3d(p)
            launchVehicleRotation = poseFrom(tangent)
            activePos = p

            phaseName = "Launch over Taiwan"
            launchBurning = true
            launchThrottle = 1

        } else if (t < fairingSeparationEnd) {
            // ── Fairing separation, still on the insertion arc
            const progress = (t - launchAscentEnd)
                           / (fairingSeparationEnd - launchAscentEnd)

            const angle = insertionAngle + progress * Math.PI * 1.20

            const p = M.ellipsePoint(g.parkCenterX, 0,
                                     g.parkRadiusX, g.parkRadiusZ,
                                     angle, g.parkY)
            const tangent = M.ellipseTangent(g.parkRadiusX, g.parkRadiusZ,
                                             angle)

            launchVehiclePosition = M.toVector3d(p)
            launchVehicleRotation = poseFrom(tangent)
            activePos = p

            // Front-loaded: the shells are away inside the first ~2 s of this
            // phase, while the vehicle is still on the near side of the planet.
            // Spread across the whole phase (the reference's 0.12..0.92) the
            // separation happens behind the Earth and is simply never seen.
            const separation = M.smoothstep(0.02, 0.38, progress)

            fairingLeftOffset = Qt.vector3d(-separation * 0.40 * es,
                                             separation * 0.42 * es,
                                             separation * 0.62 * es)
            fairingLeftEuler = Qt.vector3d(separation * 31.5,
                                           separation * 11.5,
                                           separation * 41.3)

            fairingRightOffset = Qt.vector3d(-separation * 0.40 * es,
                                             -separation * 0.42 * es,
                                             -separation * 0.62 * es)
            fairingRightEuler = Qt.vector3d(-separation * 31.5,
                                            -separation * 11.5,
                                            -separation * 41.3)

            phaseName = "Rocket fairing separation"
            launchBurning = progress < 0.52
            launchThrottle = launchBurning ? 0.88 : 0

        } else if (t < earthParkEnd) {
            // ── First-stage separation, then the parking orbit
            const progress = (t - fairingSeparationEnd)
                           / (earthParkEnd - fairingSeparationEnd)

            const angle = M.lerp(parkStartAngle, g.parkEndAngle, progress)

            const p = M.ellipsePoint(g.parkCenterX, 0,
                                     g.parkRadiusX, g.parkRadiusZ,
                                     angle, g.parkY)
            const tangent = M.ellipseTangent(g.parkRadiusX, g.parkRadiusZ,
                                             angle)

            launchVehiclePosition = M.toVector3d(p)
            launchVehicleRotation = poseFrom(tangent)
            activePos = p

            // Shells drift off and are then dropped from the scene entirely.
            const drift = Math.min(progress * 2.2, 1.0)

            fairingLeftOffset =
                Qt.vector3d((-0.40 - drift * 1.25) * es,
                            ( 0.42 + drift * 0.85) * es,
                            ( 0.62 + drift * 1.10) * es)
            fairingLeftEuler =
                Qt.vector3d((0.55 + progress * 3.2) * 57.3,
                            (0.20 + progress * 1.8) * 57.3,
                            (0.72 + progress * 2.6) * 57.3)

            fairingRightOffset =
                Qt.vector3d((-0.40 - drift * 1.25) * es,
                            (-0.42 - drift * 0.85) * es,
                            (-0.62 - drift * 1.10) * es)
            fairingRightEuler =
                Qt.vector3d((-0.55 - progress * 3.0) * 57.3,
                            (-0.20 - progress * 1.6) * 57.3,
                            (-0.72 - progress * 2.4) * 57.3)

            fairingVisible = progress <= 0.58

            const stageSeparation = M.smoothstep(0.20, 0.62, progress)

            coreStageOffset = Qt.vector3d(-stageSeparation * 2.60 * es,
                                           stageSeparation * 0.42 * es,
                                           0)
            coreStageEuler = Qt.vector3d(stageSeparation * 41.3,
                                         0,
                                         stageSeparation * 88.8)

            coreStageVisible = progress <= 0.78

            phaseName = progress < 0.36 ? "First-stage booster separation"
                      : progress < 0.90 ? "Elliptical Earth parking orbit"
                                        : "Approaching lunar transfer point"

        } else if (t < tliBurnEnd) {
            // ── Hold at the departure point, align, then light the engine
            //
            // §11 of the doc: the parking orbit does not cut straight to the
            // transfer curve. It stops on the injection point and rotates the
            // attitude from the orbit tangent to the transfer tangent while
            // the throttle ramps up from zero.
            const progress = (t - earthParkEnd) / (tliBurnEnd - earthParkEnd)

            coreStageVisible = false
            fairingVisible = false

            const attitudeBlend = M.smoothstep(0.08, 0.50, progress)
            const tangent = M.normalize(M.lerpVec(g.tliOrbitTangent,
                                                  g.tliTransferTangent,
                                                  attitudeBlend))

            launchVehiclePosition = M.toVector3d(g.tliPosition)
            launchVehicleRotation = poseFrom(tangent)
            activePos = g.tliPosition

            const ignition = M.smoothstep(0.40, 0.72, progress)

            launchBurning = progress > 0.36
            launchThrottle = ignition

            tliMarkerOpacity = 0.52 + Math.sin(now * 0.012) * 0.24
            tliMarkerScale = 1 + ignition * 0.24

            phaseName = progress < 0.28 ? "At Earth-Moon transfer departure point; holding"
                      : progress < 0.56 ? "Aligning with Moon; preparing ignition"
                                        : "Engine rel ignition"

        } else if (t < transferEnd) {
            // ── Earth–Moon transfer coast
            const progress = (t - tliBurnEnd) / (transferEnd - tliBurnEnd)

            coreStageVisible = false
            fairingVisible = false

            const p = g.transfer.pointAt(progress)
            const tangent = g.transfer.tangentAt(progress)

            launchVehiclePosition = M.toVector3d(p)
            launchVehicleRotation = poseFrom(tangent)
            activePos = p

            phaseName = progress < 0.10 ? "Earth-Moon transfer burn complete; leaving Earth"
                                        : "Earth-Moon transfer orbit"

            const midCourse = progress > 0.54 && progress < 0.59

            launchBurning = progress < 0.12 || midCourse
            launchThrottle = progress < 0.12
                             ? 1 - M.smoothstep(0.025, 0.12, progress)
                             : (midCourse ? 0.72 : 0)

        } else if (t < probeDeployEnd) {
            // ── Payload bay opens, probe slides out and unfolds, carrier drops
            //    away
            const progress = (t - transferEnd) / (probeDeployEnd - transferEnd)

            coreStageVisible = false
            fairingVisible = false

            const pathPosition = g.captureEntry.pointAt(progress)
            const pathTangent = g.captureEntry.tangentAt(progress)

            const doorOpen = M.smoothstep(0.04, 0.32, progress)
            const probeSlide = M.smoothstep(0.18, 0.80, progress)
            const separation = M.smoothstep(0.48, 0.96, progress)
            const panelDeploy = M.smoothstep(0.35, 0.82, progress)
            const dishDeploy = M.smoothstep(0.50, 0.88, progress)

            bayDoorAngle = doorOpen * 68.8

            // Carrier falls behind the path point; the probe runs ahead of it,
            // reaching captureOrbitStart exactly as deployment ends.
            const carrierPosition =
                M.add(M.addScaled(pathPosition, pathTangent,
                                  -separation * 0.92 * ms),
                      [0, separation * 0.18 * ms, separation * 0.09 * ms])

            launchVehiclePosition = M.toVector3d(carrierPosition)
            launchVehicleRotation = poseFrom(pathTangent)
            launchVehicleTumble = Qt.vector3d(separation * 11.5, 0,
                                              separation * 17.2)

            // Slides forward to exactly deploymentRun, which is the distance
            // captureDeploymentEnd sits upstream of captureOrbitStart — so the
            // probe reaches orbit entry as this phase ends, with no jump.
            const probePos = M.addScaled(pathPosition, pathTangent,
                                         g.deploymentRun
                                         * (0.65 + probeSlide * 0.35))

            probeVisible = progress > 0.08
            probePosition = M.toVector3d(probePos)
            probeRotation = poseFrom(pathTangent)
            probeDeploy = Math.max(panelDeploy, dishDeploy * 0.92)

            phaseName = progress < 0.30 ? "Lunar capture: payload bay opening"
                      : progress < 0.68 ? "Lander probe deploying"
                                        : "Probe separating from upper stage"

            probeBurning = progress > 0.76 && progress < 0.94

            launchBurning = progress < 0.12
            launchThrottle = launchBurning ? 0.42 : 0

            activePos = progress < 0.56 ? carrierPosition : probePos

        } else if (t < lunarCaptureEnd) {
            // ── Lunar capture, spiralling down through the orbit set
            const progress = (t - probeDeployEnd)
                           / (lunarCaptureEnd - probeDeployEnd)

            const angle = g.captureStartAngle + progress * g.captureSpiralSweep
            const radiusScale = M.lerp(1.0, g.captureEndScale, progress)

            const radiusX = g.captureRadiusX * radiusScale
            const radiusZ = g.captureRadiusZ * radiusScale

            const p = M.ellipsePoint(moonOrbitRadius, 0, radiusX, radiusZ,
                                     angle, g.captureY)
            const tangent = M.ellipseTangent(radiusX, radiusZ, angle)

            probeVisible = true
            probeDeploy = 1
            probePosition = M.toVector3d(p)
            probeRotation = poseFrom(tangent)
            activePos = p

            // The spent upper stage keeps tumbling away for a while instead of
            // blinking out the instant the probe is released.
            launchVehicleVisible = progress < 0.42
            coreStageVisible = false
            fairingVisible = false
            bayDoorAngle = 68.8

            if (launchVehicleVisible) {
                // Picks the drift up exactly where deployment left it. At full
                // separation the carrier sat at captureDeploymentEnd (which is
                // deploymentRun upstream of orbit entry) minus another 0.92*ms
                // along the track, with a (0, 0.18, 0.09)*ms offset.
                const driftStart = -g.deploymentRun - 0.92 * ms

                const driftPosition =
                    M.add(M.addScaled(g.captureOrbitStart,
                                      g.captureTangentStart,
                                      driftStart - progress * 1.90 * ms),
                          [-progress * 0.20 * ms,
                           (0.18 + progress * 0.42) * ms,
                           (0.09 + progress * 0.30) * ms])

                launchVehiclePosition = M.toVector3d(driftPosition)
                launchVehicleRotation = poseFrom(g.captureTangentStart)

                // Picks up where the deployment phase left the tumble (11.5 /
                // 17.2 at full separation) rather than restarting from zero.
                launchVehicleTumble = Qt.vector3d(11.5 + progress * 137.5, 0,
                                                  17.2 + progress * 103.1)
            }

            phaseName = "Probe lunar orbit capture and descent"
            probeBurning = progress < 0.15
                           || (progress > 0.58 && progress < 0.72)

        } else if (t < descentEnd) {
            // ── Powered descent to the surface
            //
            // The probe flips retrograde early on so the engine faces the
            // direction of travel, which is both how a real descent is flown and
            // what leaves it standing upright at touchdown: the curve's end
            // tangent is -landingUp, so the flipped attitude is +landingUp.
            const progress = (t - lunarCaptureEnd) / (descentEnd - lunarCaptureEnd)

            const p = g.descent.pointAt(progress)
            const tangent = g.descent.tangentAt(progress)

            launchVehicleVisible = false
            probeVisible = true
            probeDeploy = 1
            probePosition = M.toVector3d(p)
            probeRotation = retrogradePose(tangent,
                                           M.smoothstep(0.05, 0.40, progress))
            activePos = p

            phaseName = "Lunar surface descent"
            probeBurning = true

        } else if (t < lunarSurfaceEnd) {
            // ── Surface stay
            const progress = (t - descentEnd) / (lunarSurfaceEnd - descentEnd)

            launchVehicleVisible = false
            probeVisible = true
            probeDeploy = 1
            probePosition = M.toVector3d(g.landingPosition)

            // Standing on its legs. The reference parks it nose-along-+X here,
            // which reads as lying on its side and jumps ~107° out of the
            // descent.
            probeRotation = poseFrom(g.landingUp)
            activePos = g.landingPosition

            phaseName = progress < 0.72 ? "Lunar landing and brief stay" : "Preparing ascent to Earth"
            probeBurning = progress > 0.84

        } else if (t < lunarAscentEnd) {
            // ── Ascent back to lunar orbit
            const progress = (t - lunarSurfaceEnd)
                           / (lunarAscentEnd - lunarSurfaceEnd)
            const eased = M.easeInOut(progress)

            const p = g.lunarAscent.pointAt(eased)
            const tangent = g.lunarAscent.tangentAt(eased)

            launchVehicleVisible = false
            probeVisible = true
            probeDeploy = 1
            probePosition = M.toVector3d(p)
            probeRotation = poseFrom(tangent)
            activePos = p

            phaseName = "Probe ascent from the lunar surface"
            probeBurning = true

        } else if (t < lunarReturnOrbitEnd) {
            // ── Phasing orbit before the return burn
            const progress = (t - lunarAscentEnd)
                           / (lunarReturnOrbitEnd - lunarAscentEnd)

            const endAngle = g.teiAngle + Math.PI * 2 * 2
            const angle = M.lerp(g.ascentStartAngle, endAngle, progress)

            const p = M.ellipsePoint(moonOrbitRadius, 0,
                                     g.returnRadiusX, g.returnRadiusZ,
                                     angle, g.returnY)
            const tangent = M.ellipseTangent(g.returnRadiusX, g.returnRadiusZ,
                                             angle)

            launchVehicleVisible = false
            probeVisible = true
            probeDeploy = 1
            probePosition = M.toVector3d(p)
            probeRotation = poseFrom(tangent)
            activePos = p

            phaseName = progress < 0.82 ? "Probe lunar rendezvous" : "Approaching lunar-Earth return point"

        } else if (t < teiBurnEnd) {
            // ── Hold, align to Earth, ignite. Mirror of the TLI phase.
            const progress = (t - lunarReturnOrbitEnd)
                           / (teiBurnEnd - lunarReturnOrbitEnd)

            const attitudeBlend = M.smoothstep(0.08, 0.48, progress)
            const tangent = M.normalize(M.lerpVec(g.teiOrbitTangent,
                                                  g.teiTransferTangent,
                                                  attitudeBlend))

            launchVehicleVisible = false
            probeVisible = true
            probeDeploy = 1
            probePosition = M.toVector3d(g.teiPosition)
            probeRotation = poseFrom(tangent)
            activePos = g.teiPosition

            const ignition = M.smoothstep(0.42, 0.76, progress)

            teiMarkerOpacity = 0.54 + Math.sin(now * 0.012) * 0.22
            teiMarkerScale = 1 + ignition * 0.24

            phaseName = progress < 0.28 ? "At lunar-Earth return point; holding"
                      : progress < 0.58 ? "Aligning toward Earth"
                                        : "Lunar-Earth return engine burn"

            probeBurning = progress > 0.38

        } else if (t < earthReturnEnd) {
            // ── Moon–Earth transfer coast
            const progress = (t - teiBurnEnd) / (earthReturnEnd - teiBurnEnd)

            const p = g.earthReturn.pointAt(progress)
            const tangent = g.earthReturn.tangentAt(progress)

            launchVehicleVisible = false
            probeVisible = true
            probeDeploy = 1
            probePosition = M.toVector3d(p)
            probeRotation = poseFrom(tangent)
            activePos = p

            phaseName = progress < 0.08 ? "Lunar-Earth return burn complete" : "Probe returning to Earth"
            probeBurning = progress < 0.10

        } else if (t < earthReentryEnd) {
            // ── Stow, then atmospheric entry over Taiwan
            const progress = (t - earthReturnEnd)
                           / (earthReentryEnd - earthReturnEnd)

            const eased = M.easeInOut(progress)

            const pts = reentryControlPath()
            const p = M.catmullRomPoint(pts, launchTension, eased)

            const du = 0.002
            const beforeP = M.catmullRomPoint(pts, launchTension,
                                              Math.max(0, eased - du))
            const afterP = M.catmullRomPoint(pts, launchTension,
                                             Math.min(1, eased + du))
            const tangent = M.normalize(M.sub(afterP, beforeP))

            launchVehicleVisible = false
            probeVisible = true
            probeDeploy = 1 - M.smoothstep(0.02, 0.42, progress)
            probePosition = M.toVector3d(p)

            // Same retrograde flip as the lunar descent, and for the same two
            // reasons: heat shield into the airflow, and an upright attitude at
            // touchdown. It happens while the panels stow.
            probeRotation = retrogradePose(tangent,
                                           M.smoothstep(0.05, 0.38, progress))
            activePos = p

            // Plasma sheath fades in on entry and back out before touchdown.
            const plasma = M.smoothstep(0.28, 0.60, progress)
                         * (1 - M.smoothstep(0.84, 1.0, progress))

            reentryGlow = plasma

            const drawn = []
            for (let i = 0; i < 20; ++i)
                drawn.push(M.catmullRomPoint(pts, launchTension, i / 19))
            reentryPathPoints = M.toVector3dList(drawn)

            phaseName = progress < 0.34 ? "Folding solar panels and antennas"
                      : progress < 0.82 ? "Entering Earth's atmosphere"
                                        : "Returning near Taiwan"

        } else {
            // ── Down, and reset for the next cycle
            const frame = taiwanFrame()
            const p = M.addScaled(frame.position, frame.normal, 0.035 * es)

            launchVehicleVisible = false
            probeVisible = true
            probeDeploy = 0
            probePosition = M.toVector3d(p)

            // Upright on the pad — which is also the attitude the next cycle's
            // rocket starts in, so the wrap reads as a changeover rather than a
            // flip.
            probeRotation = poseFrom(frame.normal)
            activePos = p

            phaseName = "Earth return complete · preparing next launch"
        }

        // The re-entry corridor is only meaningful on the way home; leaving it
        // empty elsewhere keeps 20 nodes out of the scene for the rest of the
        // mission.
        if (t < earthReturnEnd || t >= earthReentryEnd)
            reentryPathPoints = []

        activeVehiclePosition = M.toVector3d(activePos)
        activeVehicleWorldPosition = M.toVector3d(missionToWorld(activePos))
    }
}
