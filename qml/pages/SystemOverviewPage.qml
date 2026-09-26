import QtQuick
import QtQuick.Layouts
import QtQuick.Effects

Rectangle {
    id: root
    color: "#0a0a0a"

    readonly property bool networkUp:
        systemMonitor.ethIp && systemMonitor.ethIp.length > 0
                            && systemMonitor.ethIp !== "Disconnected"
                            && systemMonitor.ethIp !== "-"

    // Reusable label/value row used by both info cards (dark theme)
    component InfoRow: RowLayout {
        id: row
        property string rowLabel: ""
        property string rowValue: ""
        Layout.fillWidth: true

        Text {
            text: row.rowLabel
            color: "#9ca3af"
            font.pixelSize: 19
        }
        Item { Layout.fillWidth: true }
        Text {
            text: row.rowValue
            color: "#ffffff"
            font.pixelSize: 19
            font.bold: true
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 48
        spacing: 40

        // ─────────── Platform Information ───────────
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#1a1a1a"
            radius: 8
            border.color: "#333333"
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 36
                spacing: 28

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 18

                    Rectangle {
                        Layout.preferredWidth: 56
                        Layout.preferredHeight: 56
                        radius: 14
                        color: "#262626"

                        Item {
                            anchors.centerIn: parent
                            width: 32
                            height: 32

                            Image {
                                id: cpuIcon
                                anchors.fill: parent
                                source: "qrc:/assets/icons/cpu.svg"
                                sourceSize: Qt.size(64, 64)
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                visible: false
                            }
                            MultiEffect {
                                anchors.fill: cpuIcon
                                source: cpuIcon
                                colorization: 1.0
                                colorizationColor: "#9ca3af"
                            }
                        }
                    }

                    Text {
                        text: "Platform Information"
                        color: "#ffffff"
                        font.pixelSize: 28
                        font.bold: true
                    }

                    Item { Layout.fillWidth: true }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 16

                    InfoRow { rowLabel: "Platform"; rowValue: systemMonitor.platformName }
                    InfoRow { rowLabel: "SoC";      rowValue: systemMonitor.socName }
                    // Hardware spec rows (sourced from AM62Px datasheet; static)
                    InfoRow { rowLabel: "CPU";      rowValue: "Quad Cortex-A53 @ 1.4 GHz" }
                    InfoRow { rowLabel: "GPU";      rowValue: "IMG BXS-4-64 · 50 GFLOPS" }
                    InfoRow { rowLabel: "Memory";   rowValue: "8 GB LPDDR4-3733 · 32-bit (inline ECC)" }
                    InfoRow { rowLabel: "L1 Cache"; rowValue: "32 KB I + 32 KB D per core" }
                    InfoRow { rowLabel: "L2 Cache"; rowValue: "512 KB shared (SECDED ECC)" }
                    InfoRow { rowLabel: "OS";       rowValue: systemMonitor.osName }
                    InfoRow { rowLabel: "Kernel";   rowValue: systemMonitor.kernelVersion }
                    InfoRow { rowLabel: "Build";    rowValue: systemMonitor.buildDate }
                    InfoRow { rowLabel: "App Updated"; rowValue: systemMonitor.appBuildDate }
                    // microSD card (root fs lives on mmcblk1 SD slot)
                    InfoRow { rowLabel: "SD Total"; rowValue: systemMonitor.sdTotal }
                    InfoRow { rowLabel: "SD Used";  rowValue: systemMonitor.sdUsed }
                    InfoRow { rowLabel: "SD Free";  rowValue: systemMonitor.sdFree }
                }

                Item { Layout.fillHeight: true }
            }
        }

        // ─────────── Network Status ───────────
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#1a1a1a"
            radius: 8
            border.color: "#333333"
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 36
                spacing: 28

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 18

                    Rectangle {
                        Layout.preferredWidth: 56
                        Layout.preferredHeight: 56
                        radius: 14
                        color: "#1e293b"

                        Item {
                            anchors.centerIn: parent
                            width: 32
                            height: 32

                            Image {
                                id: actIcon
                                anchors.fill: parent
                                source: "qrc:/assets/icons/activity.svg"
                                sourceSize: Qt.size(64, 64)
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                visible: false
                            }
                            MultiEffect {
                                anchors.fill: actIcon
                                source: actIcon
                                colorization: 1.0
                                colorizationColor: "#60a5fa"
                            }
                        }
                    }

                    Text {
                        text: "Network Status"
                        color: "#ffffff"
                        font.pixelSize: 28
                        font.bold: true
                    }

                    Item { Layout.fillWidth: true }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 22

                    InfoRow { rowLabel: "Ethernet (eth0)"; rowValue: systemMonitor.ethIp }
                    InfoRow { rowLabel: "WLAN (wlan0)";    rowValue: systemMonitor.wlanIp }
                    InfoRow { rowLabel: "Bluetooth";       rowValue: systemMonitor.bluetoothStatus }

                    // Status row — pill badge (dark theme: muted dark bg + bright text)
                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: "Status"
                            color: "#9ca3af"
                            font.pixelSize: 19
                        }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            Layout.preferredHeight: 32
                            implicitWidth: statusText.implicitWidth + 28
                            radius: 16
                            color: root.networkUp ? "#064e3b" : "#7f1d1d"
                            border.width: 1
                            border.color: root.networkUp ? "#10b981" : "#ef4444"
                            Text {
                                id: statusText
                                anchors.centerIn: parent
                                text: root.networkUp ? "Connected" : "Offline"
                                color: root.networkUp ? "#34d399" : "#fca5a5"
                                font.pixelSize: 16
                                font.bold: true
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }
    }
}
