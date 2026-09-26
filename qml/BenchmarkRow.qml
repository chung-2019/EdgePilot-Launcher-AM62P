import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property string benchName: ""
    property string label: benchName
    property string resultText: "click"
    property bool running: false

    signal runRequested()

    implicitHeight: 60

    Connections {
        target: benchmarkRunner
        function onResultChanged(name, result) {
            if (name === root.benchName) root.resultText = result
        }
        function onStatusChanged(name) {
            if (name === root.benchName) root.running = benchmarkRunner.isRunning(name)
        }
    }
    Component.onCompleted: {
        resultText = benchmarkRunner.result(benchName)
        running   = benchmarkRunner.isRunning(benchName)
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Name cell
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            color: "white"
            border.color: "#E0E0E0"

            Text {
                anchors.centerIn: parent
                text: root.label
                color: "#D32F2F"
                font.pixelSize: 17
                font.bold: true
            }
        }

        // Result + run-button cell
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            color: "white"
            border.color: "#E0E0E0"

            Text {
                anchors.right: playBtn.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: root.running ? "running…" : (root.resultText === "click" ? "" : root.resultText)
                color: root.running ? "#999" : "#444"
                font.pixelSize: 15
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
            }

            Button {
                id: playBtn
                anchors.centerIn: parent
                implicitWidth: 48
                implicitHeight: 48
                background: Rectangle {
                    color: root.running ? "#999" : "#1976D2"
                    radius: 24
                }
                contentItem: Text {
                    text: root.running ? "…" : "▶"
                    color: "white"
                    font.pixelSize: 24
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                enabled: !root.running
                onClicked: root.runRequested()
            }
        }
    }
}
