import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes

// Modal popup that shows the live output of the active benchmark plus a
// result + bar visualisation, similar to the original ti-apps-launcher.
Popup {
    id: root
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape

    width: Math.min(parent ? parent.width  - 60 : 1200, 1200)
    height: Math.min(parent ? parent.height - 60 : 720, 720)
    padding: 0

    // Re-center on every open. Drag mutates x/y; without this the popup would
    // remember the dragged position next time it opens.
    onAboutToShow: {
        const o = Overlay.overlay
        if (o) {
            x = Math.max(0, (o.width  - width)  / 2)
            y = Math.max(0, (o.height - height) / 2)
        }
    }

    background: Rectangle {
        color: "white"
        radius: 12
        border.color: "#0D2A66"
        border.width: 2
    }

    Overlay.modal: Rectangle { color: "#88000000" }

    // Per-benchmark visual scale (numerator) → bar fill (0..1)
    function scaleFor(name, num) {
        if (isNaN(num) || num <= 0) return 0
        const ref = {
            "whetstone":     8000,    // MIPS
            "dhrystone":   12000,    // DMIPS
            "linpack":       800,    // Mflops
            "stream":       6000,    // MB/s
            "nbench":          8.0,  // index
            "glmark2-fps":   400,
            "glmark2-score": 400
        }
        const r = ref[name] || num
        return Math.max(0.02, Math.min(1.0, num / r))
    }

    function unitColor(name) {
        const c = {
            "whetstone":     "#1976D2",
            "dhrystone":     "#43A047",
            "linpack":       "#FB8C00",
            "stream":        "#7B1FA2",
            "nbench":        "#0097A7",
            "glmark2-fps":   "#D32F2F",
            "glmark2-score": "#D32F2F"
        }
        return c[name] || "#1976D2"
    }

    function parseNumber(text) {
        const m = /([0-9]+(?:\.[0-9]+)?)/.exec(text || "")
        return m ? parseFloat(m[1]) : NaN
    }

    readonly property string bench: benchmarkRunner.activeBench
    readonly property string output: benchmarkRunner.activeOutput
    readonly property string resultText: benchmarkRunner.activeResult
    readonly property bool   running: benchmarkRunner.activeRunning

    contentItem: ColumnLayout {
        spacing: 0

        // ── Header ───────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            color: root.unitColor(root.bench)
            radius: 10

            // mask the bottom corners so it joins the body cleanly
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 12
                color: parent.color
            }

            // Drag the popup by its header. Wraps the RowLayout so that
            // presses on the title text / spinner / empty space all reach this
            // MouseArea (mouse events do not fall through QML siblings). The
            // close Button has its own internal MouseArea and will consume its
            // own clicks, so it is not draggable.
            // Uses screen-space deltas via mapToGlobal because the popup (and
            // this MouseArea) move with x/y during the drag, which would
            // otherwise cancel out item-local mouse coordinate deltas.
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeAllCursor
                property point pressGlobal: Qt.point(0, 0)
                property real popupStartX: 0
                property real popupStartY: 0
                onPressed: (mouse) => {
                    pressGlobal = mapToGlobal(mouse.x, mouse.y)
                    popupStartX = root.x
                    popupStartY = root.y
                }
                onPositionChanged: (mouse) => {
                    if (!pressed) return
                    const cur = mapToGlobal(mouse.x, mouse.y)
                    const o = Overlay.overlay
                    let nx = popupStartX + (cur.x - pressGlobal.x)
                    let ny = popupStartY + (cur.y - pressGlobal.y)
                    if (o) {
                        // keep at least 60 px of header on screen so the
                        // user can always drag it back / close it
                        nx = Math.max(60 - root.width, Math.min(o.width - 60, nx))
                        ny = Math.max(0,                 Math.min(o.height - 60, ny))
                    }
                    root.x = nx
                    root.y = ny
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 20
                    anchors.rightMargin: 12
                    spacing: 14

                Text {
                    text: root.bench ? root.bench + " benchmark" : ""
                    color: "white"
                    font.pixelSize: 22
                    font.bold: true
                }

                Rectangle {
                    Layout.preferredWidth: spinText.implicitWidth + 22
                    Layout.preferredHeight: 28
                    radius: 14
                    color: "#22FFFFFF"
                    visible: root.running
                    Text {
                        id: spinText
                        anchors.centerIn: parent
                        text: "● running"
                        color: "white"
                        font.pixelSize: 14
                    }
                    SequentialAnimation on opacity {
                        running: root.running
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.4; to: 1.0; duration: 700 }
                        NumberAnimation { from: 1.0; to: 0.4; duration: 700 }
                    }
                }

                Item { Layout.fillWidth: true }

                Button {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    background: Rectangle { color: "transparent" }
                    contentItem: Text {
                        text: "✕"; color: "white"
                        font.pixelSize: 22
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: root.close()
                }
                }   // RowLayout
            }       // MouseArea
        }           // header Rectangle

        // ── Body ─────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // Live log
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: 16
                color: "#0F1B2D"
                radius: 8

                ScrollView {
                    id: logScroll
                    anchors.fill: parent
                    anchors.margins: 6
                    clip: true

                    TextArea {
                        id: logArea
                        readOnly: true
                        wrapMode: TextArea.NoWrap
                        text: root.output
                        color: "#D7E3FA"
                        font.family: "monospace"
                        font.pixelSize: 13
                        background: null
                        selectByMouse: true
                        textFormat: TextArea.PlainText

                        onTextChanged: Qt.callLater(() => {
                            cursorPosition = length
                        })
                    }
                }
            }

            // Result panel
            Rectangle {
                Layout.preferredWidth: 360
                Layout.fillHeight: true
                Layout.margins: 16
                Layout.leftMargin: 0
                color: "white"
                radius: 8
                border.color: "#E0E0E0"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 18
                    spacing: 14

                    Text {
                        text: "Result"
                        font.pixelSize: 16
                        font.bold: true
                        color: "#061C4A"
                    }

                    // big number
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 96
                        Text {
                            anchors.centerIn: parent
                            text: root.running
                                  ? "…"
                                  : (root.resultText && root.resultText !== "click"
                                     ? root.resultText : "—")
                            font.pixelSize: 36
                            font.bold: true
                            color: root.unitColor(root.bench)
                            elide: Text.ElideRight
                        }
                    }

                    // score bar
                    Column {
                        Layout.fillWidth: true
                        spacing: 6
                        Text {
                            text: "Relative score"
                            font.pixelSize: 12
                            color: "#666"
                        }
                        Rectangle {
                            id: barTrack
                            width: parent.width
                            height: 14
                            radius: 7
                            color: "#EEF2F8"

                            readonly property real frac: root.scaleFor(
                                root.bench, root.parseNumber(root.resultText))

                            Rectangle {
                                width: parent.width * parent.frac
                                height: parent.height
                                radius: parent.radius
                                color: root.unitColor(root.bench)
                                Behavior on width { NumberAnimation { duration: 400 } }
                            }
                        }
                        Text {
                            text: root.running
                                  ? "running…"
                                  : (root.resultText && root.resultText !== "click"
                                     ? "100% of reference scale"
                                     : "")
                            font.pixelSize: 11
                            color: "#999"
                        }
                    }

                    Item { Layout.fillHeight: true }

                    // action buttons
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Button {
                            Layout.fillWidth: true
                            text: "Run again"
                            enabled: !root.running && root.bench.length > 0
                            onClicked: benchmarkRunner.run(root.bench)
                            background: Rectangle {
                                color: parent.enabled ? root.unitColor(root.bench) : "#BDBDBD"
                                radius: 6
                            }
                            contentItem: Text {
                                text: parent.text; color: "white"
                                font.pixelSize: 14; font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }

                        Button {
                            Layout.fillWidth: true
                            text: "Close"
                            onClicked: root.close()
                            background: Rectangle { color: "#E3E8F0"; radius: 6 }
                            contentItem: Text {
                                text: parent.text; color: "#061C4A"
                                font.pixelSize: 14; font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }
            }
        }
    }
}
