#include <QApplication>
#include <QCursor>
#include <QLoggingCategory>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>

#include "systemmonitor.h"
#include "benchmarkrunner.h"
#include "blescanner.h"
#include "uisyncserver.h"

int main(int argc, char *argv[])
{
    // Force a cursor to be present from the very start. On a stationary
    // pointer at boot, Qt-Wayland does not always push wl_pointer.set_cursor
    // unless something has been hovered first. setOverrideCursor is pushed
    // eagerly on activation regardless of hover state, which guarantees the
    // Adwaita arrow shows up before the user touches the mouse.
    QApplication app(argc, argv);
    app.setApplicationName("edgepilot-launcher");
    app.setOrganizationName("EdgePilot");

    // Force-enable BLE diagnostic logging so bluetoothctl traffic shows up in
    // journalctl — we still need to see the raw line stream to tune the parser.
    QLoggingCategory::setFilterRules("ble.info=true\nble.debug=true\nble.warning=true");

    QApplication::setOverrideCursor(QCursor(Qt::ArrowCursor));

    QQuickStyle::setStyle("Basic");

    QQmlApplicationEngine engine;

    SystemMonitor monitor;
    BenchmarkRunner runner;
    BleScanner bleScanner;

    engine.rootContext()->setContextProperty("systemMonitor", &monitor);
    engine.rootContext()->setContextProperty("benchmarkRunner", &runner);
    engine.rootContext()->setContextProperty("bleScanner", &bleScanner);

    engine.load(QUrl("qrc:/qml/Main.qml"));
    if (engine.rootObjects().isEmpty())
        return -1;

    // Local-only, read-only state bridge for the Windows EVM simulator.  BLE is
    // deliberately owned by this launcher so both displays render one exact
    // device list instead of running two competing bluetoothctl sessions.
    // Windows mouse actions are intentionally not accepted here.
    UiSyncServer uiSync(engine.rootObjects().first(), &bleScanner);
    uiSync.listen();

    if (auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().first())) {
        // FullScreen so weston-desktop-shell's top panel (with its own clock)
        // is hidden — the app's topBar then owns the full top of the screen.
        win->setVisibility(QWindow::FullScreen);

        // Window-level cursor as a fallback after override is restored.
        win->setCursor(QCursor(Qt::ArrowCursor));

        // Once the window is actually active (mapped + focused), restore the
        // normal cursor stack so MouseArea cursorShape (PointingHandCursor on
        // sidebar etc.) takes over.
        auto restoreOnce = std::make_shared<bool>(false);
        QObject::connect(win, &QQuickWindow::activeChanged, &app,
                         [restoreOnce]() {
                             if (*restoreOnce) return;
                             if (QApplication::overrideCursor()) {
                                 QApplication::restoreOverrideCursor();
                                 *restoreOnce = true;
                             }
                         });
        // Safety net in case activeChanged never fires (e.g. compositor never
        // sends keyboard focus to a kiosk surface): release override after 3 s.
        QTimer::singleShot(3000, &app, [restoreOnce]() {
            if (*restoreOnce) return;
            if (QApplication::overrideCursor()) {
                QApplication::restoreOverrideCursor();
                *restoreOnce = true;
            }
        });
    }

    return app.exec();
}
