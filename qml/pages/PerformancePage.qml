import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Sidebar Performance page — inline Whetstone benchmark dashboard:
// big result + relative-score bar + live log + Run button. State binds to
// the C++ benchmarkRunner so the page reflects an in-progress run.
Rectangle {
    id: root
    color: "#0a0a0a"

    // Last-known whetstone result, kept updated via onResultChanged
    property string lastResult: ""

    readonly property bool isActive: benchmarkRunner.activeBench === "whetstone"
    readonly property bool isRunning: isActive && benchmarkRunner.activeRunning
    readonly property string output:
        isActive ? benchmarkRunner.activeOutput : ""
    readonly property string resultText:
        (isActive && benchmarkRunner.activeResult)
            ? benchmarkRunner.activeResult
            : lastResult

    Connections {
        target: benchmarkRunner
        function onResultChanged(name, result) {
            if (name === "whetstone") root.lastResult = result
        }
    }

    Component.onCompleted: {
        lastResult = benchmarkRunner.result("whetstone") || ""
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 40
        spacing: 28

        // ────────── Header ──────────
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 72

            ColumnLayout {
                spacing: 6
                Text {
                    text: "Whetstone Benchmark"
                    color: "#ffffff"
                    font.pixelSize: 32
                    font.bold: true
                }
                Text {
                    text: "Floating-point CPU performance test"
                    color: "#9ca3af"
                    font.pixelSize: 16
                }
            }

            Item { Layout.fillWidth: true }

            // Running indicator pill
            Rectangle {
                visible: root.isRunning
                Layout.preferredHeight: 34
                implicitWidth: runText.implicitWidth + 36
                radius: 17
                color: "#1e3a8a"
                border.width: 1
                border.color: "#3b82f6"

                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8
                        radius: 4
                        color: "#60a5fa"
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite
                            running: root.isRunning
                            NumberAnimation { from: 0.3; to: 1.0; duration: 600 }
                            NumberAnimation { from: 1.0; to: 0.3; duration: 600 }
                        }
                    }
                    Text {
                        id: runText
                        anchors.verticalCenter: parent.verticalCenter
                        text: "RUNNING"
                        color: "#60a5fa"
                        font.pixelSize: 13
                        font.bold: true
                        font.letterSpacing: 1
                    }
                }
            }
        }

        // ────────── Body ──────────
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 28

            // ─── Result card (left) ───
            Rectangle {
                Layout.preferredWidth: 420
                Layout.fillHeight: true
                color: "#1a1a1a"
                radius: 8
                border.color: "#333333"
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 32
                    spacing: 18

                    Text {
                        text: "Result"
                        color: "#9ca3af"
                        font.pixelSize: 16
                        font.bold: true
                        font.letterSpacing: 1
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 110

                        Text {
                            anchors.centerIn: parent
                            text: root.isRunning
                                  ? "…"
                                  : (root.resultText
                                     && root.resultText !== "click"
                                     && root.resultText.length > 0
                                       ? root.resultText
                                       : "—")
                            color: root.isRunning ? "#9ca3af" : "#3b82f6"
                            font.pixelSize: 42
                            font.bold: true
                            elide: Text.ElideRight
                        }
                    }

                    // Relative score bar
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            text: "Relative score (vs 8000 MWIPS reference)"
                            color: "#9ca3af"
                            font.pixelSize: 13
                        }

                        Rectangle {
                            id: scoreTrack
                            Layout.fillWidth: true
                            Layout.preferredHeight: 14
                            radius: 7
                            color: "#262626"

                            readonly property real frac: {
                                if (root.isRunning) return 0
                                const m = /([0-9]+(?:\.[0-9]+)?)/.exec(root.resultText || "")
                                if (!m) return 0
                                const v = parseFloat(m[1])
                                if (isNaN(v) || v <= 0) return 0
                                return Math.max(0.02, Math.min(1.0, v / 8000))
                            }

                            Rectangle {
                                width: scoreTrack.width * scoreTrack.frac
                                height: parent.height
                                radius: parent.radius
                                color: "#3b82f6"
                                Behavior on width {
                                    NumberAnimation { duration: 400 }
                                }
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }

                    // Run button
                    Rectangle {
                        id: runBtn
                        Layout.fillWidth: true
                        Layout.preferredHeight: 58
                        radius: 8
                        color: root.isRunning
                               ? "#374151"
                               : runHover.hovered ? Qt.darker("#3b82f6", 1.2)
                                                  : "#3b82f6"

                        HoverHandler {
                            id: runHover
                            cursorShape: root.isRunning
                                         ? Qt.ForbiddenCursor
                                         : Qt.PointingHandCursor
                            enabled: !root.isRunning
                        }

                        Text {
                            anchors.centerIn: parent
                            text: root.isRunning ? "Running…" : "Run Benchmark"
                            color: "#ffffff"
                            font.pixelSize: 17
                            font.bold: true
                            font.letterSpacing: 1
                        }

                        TapHandler {
                            enabled: !root.isRunning
                            onTapped: benchmarkRunner.run("whetstone")
                        }
                    }
                }
            }

            // ─── Live log card (right) ───
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#1a1a1a"
                radius: 8
                border.color: "#333333"
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 12

                    Text {
                        text: "Live Output"
                        color: "#9ca3af"
                        font.pixelSize: 16
                        font.bold: true
                        font.letterSpacing: 1
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: "#0a0a0a"
                        radius: 6
                        border.color: "#262626"
                        border.width: 1

                        ScrollView {
                            anchors.fill: parent
                            anchors.margins: 6
                            clip: true

                            TextArea {
                                id: logArea
                                readOnly: true
                                wrapMode: TextArea.NoWrap
                                text: root.output && root.output.length > 0
                                      ? root.output
                                      : "(idle — press Run Benchmark to start)"
                                color: "#d7e3fa"
                                font.family: "monospace"
                                font.pixelSize: 13
                                background: null
                                selectByMouse: false
                                textFormat: TextArea.PlainText

                                onTextChanged: Qt.callLater(() => {
                                    cursorPosition = length
                                })
                            }
                        }
                    }
                }
            }
        }
    }
}
