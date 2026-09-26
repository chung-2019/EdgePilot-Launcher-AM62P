import QtQuick
import QtQuick.Effects

// EdgePilot lock screen — pulled down from the top bar, pushed back up to
// return to whatever page was open.
//
// The artwork is LOGO/桌面圖示.png with the clock and date PAINTED OUT. They
// were baked into the supplied image at a fixed 09:41, and a lock screen whose
// clock never moves is worse than no clock at all — so the background carries
// the mark, the status glyphs and the globe, and the two live readings are
// drawn back on top at the same place, size and colour they occupied.
//
// How the region was cleaned: the glyphs sit on a smooth near-black gradient
// with a soft glow around them, so the erased box (x 115..740, y 220..552 of
// the 1672x941 original) was refilled with a vertical blend between the clean
// row above it and the clean row below, each blurred horizontally first so the
// per-pixel noise did not stretch into vertical streaks.
//
// Nothing here needs a C++ context property, so it renders standalone —
// tools/mission-harness/RenderLockScreen.qml is what the metrics below were
// tuned against.
Item {
    id: root

    // Live readings. Driven from Main.qml off the top bar's existing 1 Hz
    // clock tick; the defaults are what the supplied artwork showed.
    property string timeText: "09:41"
    property string dateText: "Sunday, August 16, 2026"

    // Fraction of the screen the lock covers: 0 fully away, 1 fully down.
    // Everything that fades does it off this one value, so a half-finished
    // pull looks consistent.
    property real reveal: 1

    // ── Metrics ──────────────────────────────────────────────────────────
    //
    // Fractions of the screen rather than pixels, so the layout survives a
    // different panel. The numbers are where the baked text INK sat in the
    // artwork, measured by thresholding it, once the image had been padded to
    // 16:10 and scaled to 1280x800.
    readonly property real textLeftFrac:      108.7 / 1280
    readonly property real clockTopFrac:      281.7 / 800
    readonly property real clockInkHeightFrac: 123.3 / 800
    readonly property real dateTopFrac:       446.3 / 800
    readonly property real dateInkHeightFrac:  41.4 / 800

    readonly property string fontFamily: "Liberation Sans"

    // ── Ink, not line boxes ──────────────────────────────────────────────
    //
    // Everything above is about the INK — where the glyphs actually mark the
    // screen. A Text item is not positioned or sized by its ink: its x is
    // where the pen starts (the first glyph begins a left side bearing later),
    // its y is the top of a line box that carries the font's full ascent, and
    // its pixelSize is a design size that no glyph is actually that tall.
    //
    // Guessing those three offsets is what the first two attempts did, and
    // both were wrong the moment the font changed — the date moved 5 px and
    // lost 3 px of height purely from naming Liberation Sans. So ask the font
    // instead. A FontMetrics pinned at a reference size gives the ink of this
    // exact string, which scales linearly, so the pixel size that produces the
    // wanted ink height falls out without iterating.
    readonly property int referencePixelSize: 100

    FontMetrics {
        id: clockRef
        font.family: root.fontFamily
        font.pixelSize: root.referencePixelSize
        font.letterSpacing: -2
    }

    FontMetrics {
        id: dateRef
        font.family: root.fontFamily
        font.pixelSize: root.referencePixelSize
    }

    // Metrics come from these, never from the live strings. Measuring "21:47"
    // and then "21:48" gives slightly different bearings — "1" carries more
    // left side bearing than "2" — and the clock would twitch sideways once a
    // minute. A fixed sample keeps the position still while the digits change.
    readonly property string clockSample: "00:00"
    readonly property string dateSample: "Wednesday, September 30, 2026"

    // Everything the two Texts need, derived from one reference size.
    //
    // Font metrics scale linearly, which was checked rather than assumed: at
    // pixelSize 100 the digits measure ascent 90.5, ink 70.0 tall starting
    // 5.0 in; at 177 they measure 160.2, 124.0 and 8.0 — the same numbers
    // times 1.77. So one measurement at a reference size yields the pixel size
    // that hits a wanted ink height, plus the offsets to place that ink.
    //
    // Reading the metrics off the live Text instead does NOT work: the ink
    // query is a function call, so the binding cannot re-run when the font
    // settles, and the first (default-size) answer sticks. That put the clock
    // 120 px too high, straight through the logo.
    function layoutFor(metrics, sample, wantedInk) {
        const ink = metrics.tightBoundingRect(sample)
        const scale = ink.height > 0 ? wantedInk / ink.height : 1

        return {
            "pixelSize": Math.round(referencePixelSize * scale),
            "bearing":   ink.x * scale,          // pen origin -> first ink
            "inkTop":    ink.y * scale,          // baseline -> ink top (negative)
            "ascent":    metrics.ascent * scale  // line box top -> baseline
        }
    }

    readonly property var clockLayout:
        layoutFor(clockRef, clockSample, height * clockInkHeightFrac)
    readonly property var dateLayout:
        layoutFor(dateRef, dateSample, height * dateInkHeightFrac)

    Image {
        anchors.fill: parent

        source: "qrc:/assets/lockscreen_bg.png"
        sourceSize: Qt.size(1280, 800)
        fillMode: Image.PreserveAspectCrop
        smooth: true
        asynchronous: true
    }

    // ── Clock ────────────────────────────────────────────────────────────
    //
    // Declared before the Text it takes as its source, so the blurred copy
    // lands behind the sharp one — the artwork has a soft halo around the
    // digits and without it the live clock reads as pasted on.
    MultiEffect {
        source: clock
        x: clock.x
        y: clock.y
        width: clock.width
        height: clock.height

        blurEnabled: true
        blur: 1.0
        blurMax: 40
        opacity: 0.45
    }

    Text {
        id: clock

        // x is the pen origin, so back off the bearing to put the INK on the
        // mark. y is the top of the line box, so back off the ascent to reach
        // the baseline and then the (negative) ink top to reach the digits.
        x: root.width * root.textLeftFrac - root.clockLayout.bearing
        y: root.height * root.clockTopFrac
           - root.clockLayout.ascent - root.clockLayout.inkTop

        text: root.timeText
        color: "#e9ecf1"
        font.family: root.fontFamily
        font.pixelSize: root.clockLayout.pixelSize
        font.letterSpacing: -2
    }

    // ── Date ─────────────────────────────────────────────────────────────
    Text {
        id: date

        x: root.width * root.textLeftFrac - root.dateLayout.bearing
        y: root.height * root.dateTopFrac
           - root.dateLayout.ascent - root.dateLayout.inkTop

        text: root.dateText
        color: "#02eaff"
        font.family: root.fontFamily
        font.pixelSize: root.dateLayout.pixelSize
    }

    // ── Unlock hint ──────────────────────────────────────────────────────
    //
    // Fades out as the lock comes down, so it is not competing with the pull
    // that is still in progress, and settles once it is the only thing left to
    // tell the operator how to get back.
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.height * 0.045
        spacing: 10

        opacity: root.reveal

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 58
            height: 5
            radius: 2.5
            color: "#8ea3bd"
            opacity: 0.75
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Swipe up to return"
            color: "#8ea3bd"
            font.pixelSize: 15
            font.letterSpacing: 0.6
        }
    }
}
