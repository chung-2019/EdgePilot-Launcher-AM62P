import QtQuick
import QtQuick.Layouts

// EdgePilot project overview.
Rectangle {
    id: root
    color: "#0a0a0a"

    RowLayout {
        anchors.fill: parent
        anchors.margins: 48
        spacing: 40

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

                        Image {
                            anchors.centerIn: parent
                            width: 32; height: 32
                            source: "qrc:/assets/icons/info.svg"
                            sourceSize: Qt.size(64, 64)
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }
                    }

                    Text {
                        text: "About"
                        color: "#ffffff"
                        font.pixelSize: 28
                        font.bold: true
                    }

                    Item { Layout.fillWidth: true }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    text: "EdgePilot is an open-source Qt-based launcher and system console\n"
                        + "designed for embedded Linux development on the TI AM62P platform.\n\n"
                        + "It provides a unified interface for system monitoring, hardware\n"
                        + "diagnostics, device connectivity and application demonstrations.\n\n"
                        + "EdgePilot is intended for development, evaluation and educational\n"
                        + "use. It helps developers explore common embedded Linux functions\n"
                        + "through a visual and easy-to-use interface."
                    color: "#d8e3f0"
                    font.family: "Liberation Sans"
                    font.pixelSize: 24
                    lineHeight: 1.5
                    wrapMode: Text.WordWrap
                }

                Item { Layout.fillHeight: true }
            }
        }
    }
}
