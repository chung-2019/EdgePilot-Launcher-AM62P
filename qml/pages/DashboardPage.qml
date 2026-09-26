import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    color: "#0a0a0a"

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 22
        spacing: 14

        // ── System Health ──
        Text {
            text: "System Health"
            color: "#ffffff"
            font.pixelSize: 18
            font.bold: true
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 140
            spacing: 14

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#1a1a1a"
                radius: 8
                border.width: 1
                border.color: "#333333"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: 4
                    anchors.bottomMargin: 4
                    spacing: 1

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "CPU Load"
                        color: "#9ca3af"
                        font.pixelSize: 55
                    }
                    FlatGauge {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        progressColor: "#2563eb"
                        value: systemMonitor.cpuLoad
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#1a1a1a"
                radius: 8
                border.width: 1
                border.color: "#333333"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: 4
                    anchors.bottomMargin: 4
                    spacing: 1

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "GPU Load"
                        color: "#9ca3af"
                        font.pixelSize: 55
                    }
                    FlatGauge {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        progressColor: "#f97316"
                        value: systemMonitor.gpuLoad
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#1a1a1a"
                radius: 8
                border.width: 1
                border.color: "#333333"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: 4
                    anchors.bottomMargin: 4
                    spacing: 1

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Memory Usage"
                        color: "#9ca3af"
                        font.pixelSize: 55
                    }
                    FlatGauge {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        progressColor: "#22d3a3"
                        value: systemMonitor.ddrLoad
                    }
                }
            }
        }

        Item { Layout.preferredHeight: 6 }

        Item { Layout.fillHeight: true }
    }
}
