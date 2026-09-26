.pragma library

//
// Trajectory maths for the Taiwan–Moon round-trip mission.
//
// Ported from am62p-earth-moon/interactive_3d_taiwan_moon_round_trip_loop.html
// (three.js). The architecture doc puts this in C++ (MissionTrajectoryModel +
// QQuick3DGeometry), but the AM62P devkit sysroot ships no Quick3D headers, so
// nothing here may link against Quick3D — see EarthMoonPage.qml. Plain JS in a
// .pragma library it is: parsed once, shared by every instance.
//
// Vectors are plain [x, y, z] arrays, not Qt.vector3d. A vector3d is an
// immutable value type, so every intermediate step would allocate one; the
// mission evaluates a few hundred of these per frame. Conversion to
// Qt.vector3d happens once, at the property boundary.
//

// ── Vector helpers ──────────────────────────────────────────────────────

function vec(x, y, z) {
    return [x, y, z]
}

function add(a, b) {
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

function sub(a, b) {
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

function mul(a, s) {
    return [a[0] * s, a[1] * s, a[2] * s]
}

// a + b * s — the three.js addScaledVector, which the source uses everywhere.
function addScaled(a, b, s) {
    return [a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s]
}

function dot(a, b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

function cross(a, b) {
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]
}

function length(a) {
    return Math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
}

function normalize(a) {
    const l = length(a)
    return l > 1e-9 ? [a[0] / l, a[1] / l, a[2] / l] : [1, 0, 0]
}

function lerpVec(a, b, t) {
    return [a[0] + (b[0] - a[0]) * t,
            a[1] + (b[1] - a[1]) * t,
            a[2] + (b[2] - a[2]) * t]
}

// ── Scalar helpers ──────────────────────────────────────────────────────

function clamp(x, lo, hi) {
    return x < lo ? lo : (x > hi ? hi : x)
}

function lerp(a, b, t) {
    return a + (b - a) * t
}

// three.js MathUtils.smoothstep(x, edge0, edge1) — argument order flipped to
// the GLSL one (edges first) because that reads better at the call sites.
function smoothstep(edge0, edge1, x) {
    if (x <= edge0)
        return 0
    if (x >= edge1)
        return 1
    const t = (x - edge0) / (edge1 - edge0)
    return t * t * (3 - 2 * t)
}

// Ease used for launch ascent and lunar ascent in the source.
function easeInOut(t) {
    return t * t * (3 - 2 * t)
}

function degToRad(deg) {
    return deg * Math.PI / 180
}

// ── Rotations ───────────────────────────────────────────────────────────

function rotateX(p, deg) {
    const a = degToRad(deg)
    const c = Math.cos(a), s = Math.sin(a)
    return [p[0], p[1] * c - p[2] * s, p[1] * s + p[2] * c]
}

function rotateY(p, deg) {
    const a = degToRad(deg)
    const c = Math.cos(a), s = Math.sin(a)
    return [p[0] * c + p[2] * s, p[1], -p[0] * s + p[2] * c]
}

function rotateZ(p, deg) {
    const a = degToRad(deg)
    const c = Math.cos(a), s = Math.sin(a)
    return [p[0] * c - p[1] * s, p[0] * s + p[1] * c, p[2]]
}

// Shortest-arc rotation taking `from` onto `to`, as [w, x, y, z].
//
// The QQuaternion::rotationTo() the architecture doc calls for. Every mission
// object is modelled nose-along-local-+X, so the pose is always
// rotationTo([1,0,0], tangent).
function rotationTo(from, to) {
    const f = normalize(from)
    const t = normalize(to)
    const d = dot(f, t)

    if (d > 0.999999)
        return [1, 0, 0, 0]

    if (d < -0.999999) {
        // Antiparallel: any perpendicular axis gives a valid 180° turn.
        let axis = cross(f, [0, 1, 0])
        if (length(axis) < 1e-6)
            axis = cross(f, [1, 0, 0])
        axis = normalize(axis)
        return [0, axis[0], axis[1], axis[2]]
    }

    const c = cross(f, t)
    const s = Math.sqrt((1 + d) * 2)
    return [s * 0.5, c[0] / s, c[1] / s, c[2] / s]
}

function negate(a) {
    return [-a[0], -a[1], -a[2]]
}

// Spherical interpolation between two unit directions.
//
// Used to route the ascent around the planet instead of across it: a straight
// interpolation between two directions cuts the chord, and a chord between two
// points on a sphere passes inside it.
function slerpDir(a, b, t) {
    const from = normalize(a)
    const to = normalize(b)
    const d = clamp(dot(from, to), -1, 1)

    // Nearly parallel: the chord and the arc agree, and sin(theta) is about to
    // underflow.
    if (d > 0.9999)
        return normalize(lerpVec(from, to, t))

    // Antiparallel: every great circle through them is equally valid, so pick
    // one deterministically rather than dividing by zero.
    if (d < -0.9999) {
        let axis = cross(from, [0, 1, 0])
        if (length(axis) < 1e-6)
            axis = cross(from, [1, 0, 0])
        axis = normalize(axis)

        const half = Math.PI * t
        return normalize(addScaled(mul(from, Math.cos(half)),
                                   cross(axis, from), Math.sin(half)))
    }

    const theta = Math.acos(d)
    const s = Math.sin(theta)
    const wa = Math.sin((1 - t) * theta) / s
    const wb = Math.sin(t * theta) / s

    return normalize([from[0] * wa + to[0] * wb,
                      from[1] * wa + to[1] * wb,
                      from[2] * wa + to[2] * wb])
}

// Orientation from an orthonormal basis, given as the images of local +X, +Y
// and +Z. Returns [w, x, y, z].
function quatFromBasis(x, y, z) {
    const m00 = x[0], m10 = x[1], m20 = x[2]
    const m01 = y[0], m11 = y[1], m21 = y[2]
    const m02 = z[0], m12 = z[1], m22 = z[2]

    const trace = m00 + m11 + m22

    // Four cases, each dividing by the largest available term — the usual
    // guard against catastrophic cancellation near a 180° rotation.
    if (trace > 0) {
        const s = Math.sqrt(trace + 1) * 2
        return [s / 4, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s]
    }

    if (m00 > m11 && m00 > m22) {
        const s = Math.sqrt(1 + m00 - m11 - m22) * 2
        return [(m21 - m12) / s, s / 4, (m01 + m10) / s, (m02 + m20) / s]
    }

    if (m11 > m22) {
        const s = Math.sqrt(1 + m11 - m00 - m22) * 2
        return [(m02 - m20) / s, (m01 + m10) / s, s / 4, (m12 + m21) / s]
    }

    const s = Math.sqrt(1 + m22 - m00 - m11) * 2
    return [(m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, s / 4]
}

// Full orientation for a vehicle whose nose is local +X, flying along
// `forward`, kept upright against `upHint`.
//
// This replaces rotationTo() for vehicle attitude, and the reason is roll.
// rotationTo() only constrains where the nose points; roll is whatever falls
// out of the shortest arc. That is degenerate when the tangent is antiparallel
// to +X — the rotation axis is genuinely undefined there — so a vehicle in
// orbit snapped through a 180° roll every time its heading swept past -X. With
// a basis, roll is pinned by upHint and the whole sweep is continuous.
function poseAlong(forward, upHint) {
    const x = normalize(forward)

    let ref = upHint ? normalize(upHint) : [0, 1, 0]

    // Fall back if the hint is (nearly) the flight direction, which would leave
    // the cross product undefined.
    if (Math.abs(dot(x, ref)) > 0.999)
        ref = Math.abs(x[1]) > 0.9 ? [0, 0, 1] : [0, 1, 0]

    const z = normalize(cross(x, ref))
    const y = cross(z, x)

    return quatFromBasis(x, y, z)
}

// Hamilton product. quatMultiply(a, b) applies b in a's local frame.
function quatMultiply(a, b) {
    return [a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
            a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
            a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
            a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]]
}

function quatFromAxisAngle(axis, degrees) {
    const half = degToRad(degrees) * 0.5
    const s = Math.sin(half)
    const n = normalize(axis)

    return [Math.cos(half), n[0] * s, n[1] * s, n[2] * s]
}

// ── Geodetic ────────────────────────────────────────────────────────────

// Same convention as the three.js source, so the Taiwan latitude/longitude
// pair carries over unchanged. `longitudeOffset` compensates for the seam of
// whichever equirectangular map is on the sphere — Qt Quick 3D's built-in
// "#Sphere" does not necessarily place u=0 where three.js does.
function latLonToVector3(latitude, longitude, radius, longitudeOffset) {
    const phi = degToRad(90 - latitude)
    const theta = degToRad(longitude + 180 + (longitudeOffset || 0))

    return [-radius * Math.sin(phi) * Math.cos(theta),
             radius * Math.cos(phi),
             radius * Math.sin(phi) * Math.sin(theta)]
}

// ── Parametric curves ───────────────────────────────────────────────────

function ellipsePoint(centerX, centerZ, radiusX, radiusZ, angle, y) {
    return [centerX + Math.cos(angle) * radiusX,
            y,
            centerZ + Math.sin(angle) * radiusZ]
}

function ellipseTangent(radiusX, radiusZ, angle) {
    return normalize([-Math.sin(angle) * radiusX,
                      0,
                       Math.cos(angle) * radiusZ])
}

function cubicBezierPoint(p0, p1, p2, p3, t) {
    const u = 1 - t
    const b0 = u * u * u
    const b1 = 3 * u * u * t
    const b2 = 3 * u * t * t
    const b3 = t * t * t

    return [p0[0] * b0 + p1[0] * b1 + p2[0] * b2 + p3[0] * b3,
            p0[1] * b0 + p1[1] * b1 + p2[1] * b2 + p3[1] * b3,
            p0[2] * b0 + p1[2] * b1 + p2[2] * b2 + p3[2] * b3]
}

function cubicBezierTangent(p0, p1, p2, p3, t) {
    const u = 1 - t
    const w0 = 3 * u * u
    const w1 = 6 * u * t
    const w2 = 3 * t * t

    const d = [(p1[0] - p0[0]) * w0 + (p2[0] - p1[0]) * w1 + (p3[0] - p2[0]) * w2,
               (p1[1] - p0[1]) * w0 + (p2[1] - p1[1]) * w1 + (p3[1] - p2[1]) * w2,
               (p1[2] - p0[2]) * w0 + (p2[2] - p1[2]) * w1 + (p3[2] - p2[2]) * w2]

    return normalize(d)
}

// Catmull-Rom, matching three.js CatmullRomCurve3 with curveType "catmullrom"
// (the uniform variant with a tension knob) so the tension values quoted in
// the HTML source keep their meaning.
function catmullRomPoint(points, tension, t) {
    const l = points.length
    const p = (l - 1) * t

    let intPoint = Math.floor(p)
    let weight = p - intPoint

    if (weight === 0 && intPoint === l - 1) {
        intPoint = l - 2
        weight = 1
    }
    intPoint = clamp(intPoint, 0, l - 2)

    // Endpoints get a mirrored ghost control point, exactly as three.js does.
    const p0 = intPoint > 0 ? points[intPoint - 1]
                            : add(sub(points[0], points[1]), points[0])
    const p1 = points[intPoint]
    const p2 = points[intPoint + 1]
    const p3 = intPoint + 2 < l ? points[intPoint + 2]
                                : add(sub(points[l - 1], points[l - 2]),
                                      points[l - 1])

    const out = [0, 0, 0]

    for (let axis = 0; axis < 3; ++axis) {
        const v0 = p1[axis]
        const v1 = p2[axis]
        const t0 = tension * (p2[axis] - p0[axis])
        const t1 = tension * (p3[axis] - p1[axis])

        const c0 = v0
        const c1 = t0
        const c2 = -3 * v0 + 3 * v1 - 2 * t0 - t1
        const c3 = 2 * v0 - 2 * v1 + t0 + t1

        const w = weight
        out[axis] = c0 + c1 * w + c2 * w * w + c3 * w * w * w
    }

    return out
}

// ── Arc-length reparameterised curve ────────────────────────────────────

// The source drives every free curve with getPointAt()/getTangentAt(), i.e.
// arc length, not the raw curve parameter. Without that the vehicle visibly
// speeds up through the flat parts of a Bézier. Build the lookup table once
// per curve, at scene construction.
//
// `pointFn(t)` takes t in [0, 1] and returns [x, y, z].
function makeCurve(pointFn, samples) {
    const n = Math.max(8, samples || 96)
    const pts = new Array(n + 1)
    const lengths = new Array(n + 1)

    pts[0] = pointFn(0)
    lengths[0] = 0

    for (let i = 1; i <= n; ++i) {
        pts[i] = pointFn(i / n)
        lengths[i] = lengths[i - 1] + length(sub(pts[i], pts[i - 1]))
    }

    const total = lengths[n]

    // Arc length u -> curve parameter t.
    function paramAt(u) {
        const target = clamp(u, 0, 1) * total

        if (total <= 1e-9)
            return 0

        // Bisect the monotonic length table.
        let lo = 0, hi = n
        while (lo < hi - 1) {
            const mid = (lo + hi) >> 1
            if (lengths[mid] <= target)
                lo = mid
            else
                hi = mid
        }

        const span = lengths[hi] - lengths[lo]
        const frac = span > 1e-9 ? (target - lengths[lo]) / span : 0
        return (lo + frac) / n
    }

    function pointAt(u) {
        return pointFn(paramAt(u))
    }

    // Central difference in CURVE-PARAMETER space with a tiny step, not in
    // arc-length space with a 1/n step.
    //
    // The arc-length version is off by the chord-versus-tangent error over a
    // whole table interval, which at a curve endpoint — where phases hand over
    // and continuity actually matters — came to 10-20°. Converting u to t first
    // and then differencing at 1e-4 makes the endpoints accurate to well under
    // a degree, and still needs no analytic derivative, so Catmull-Rom and
    // Bézier share one path.
    function tangentAt(u) {
        const t = paramAt(u)
        const dt = 1e-4
        const a = Math.max(0, t - dt)
        const b = Math.min(1, t + dt)

        if (b - a < 1e-12)
            return [1, 0, 0]

        return normalize(sub(pointFn(b), pointFn(a)))
    }

    return {
        pointAt: pointAt,
        tangentAt: tangentAt,
        totalLength: total,

        // Evenly spaced points for the drawn trajectory line.
        sample: function (count) {
            const out = []
            const steps = Math.max(2, count)
            for (let i = 0; i < steps; ++i)
                out.push(pointAt(i / (steps - 1)))
            return out
        }
    }
}

function bezierCurve(p0, p1, p2, p3, samples) {
    return makeCurve(function (t) {
        return cubicBezierPoint(p0, p1, p2, p3, t)
    }, samples)
}

// Parameter-uniform samples, no arc-length table. For the drawn line of a
// curve that is rebuilt every frame (the launch corridor and the re-entry
// corridor both track the rotating Earth) the even spacing of a full
// makeCurve() is not worth its cost — a drawn line only needs to look smooth.
function bezierSamples(p0, p1, p2, p3, count) {
    const steps = Math.max(2, count)
    const out = []

    for (let i = 0; i < steps; ++i)
        out.push(cubicBezierPoint(p0, p1, p2, p3, i / (steps - 1)))

    return out
}

function catmullRomCurve(points, tension, samples) {
    return makeCurve(function (t) {
        return catmullRomPoint(points, tension, t)
    }, samples)
}

// Points along a (possibly partial) ellipse, for the drawn orbit lines.
function ellipseSamples(centerX, centerZ, radiusX, radiusZ, y,
                        count, startAngle, endAngle) {
    const a0 = startAngle === undefined ? 0 : startAngle
    const a1 = endAngle === undefined ? Math.PI * 2 : endAngle
    const steps = Math.max(3, count)
    const out = []

    for (let i = 0; i < steps; ++i) {
        const angle = a0 + (a1 - a0) * (i / steps)
        out.push(ellipsePoint(centerX, centerZ, radiusX, radiusZ, angle, y))
    }

    return out
}

// ── QML boundary ────────────────────────────────────────────────────────

function toVector3d(a) {
    return Qt.vector3d(a[0], a[1], a[2])
}

function toQuaternion(q) {
    return Qt.quaternion(q[0], q[1], q[2], q[3])
}

function toVector3dList(list) {
    const out = []
    for (let i = 0; i < list.length; ++i)
        out.push(Qt.vector3d(list[i][0], list[i][1], list[i][2]))
    return out
}
