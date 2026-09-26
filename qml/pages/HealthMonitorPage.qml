import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    color: "#0a0a0a"

    signal launchRequested(string deviceType)

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 22
        spacing: 16

        Text {
            text: "Health Monitor"
            color: "#ffffff"
            font.pixelSize: 18
            font.bold: true
        }

        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 2
            rowSpacing: 16
            columnSpacing: 16

            DeviceLaunchCard {
                Layout.fillWidth: true
                Layout.fillHeight: true
                deviceType: "thermometer"
                zhName: "Thermometer"
                enName: "Thermometer"
                iconSource: "qrc:/assets/icons/thermometer.svg"
                accentColor: "#ffff00"
                onLaunch: root.launchRequested(deviceType)
            }
            DeviceLaunchCard {
                Layout.fillWidth: true
                Layout.fillHeight: true
                deviceType: "spo2"
                zhName: "SpO2 & Heart Rate"
                enName: "SpO2 & Heart Rate"
                iconSource: "qrc:/assets/icons/heart.svg"
                accentColor: "#ef4444"
                onLaunch: root.launchRequested(deviceType)
            }
        }
    }
}
