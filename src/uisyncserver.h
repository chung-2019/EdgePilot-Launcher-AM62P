#pragma once

#include <QObject>
#include <QJsonObject>

class BleScanner;
class QTcpServer;
class QTcpSocket;

// Local-only, read-only state bridge for an external viewer.  Binds to
// 127.0.0.1 (see listen()), so it is not reachable from the network.  The
// launcher remains the single owner of bluetoothctl: a client reads this
// launcher's exact BLE/page state and cannot send navigation or BLE commands
// back.
class UiSyncServer : public QObject
{
    Q_OBJECT

public:
    explicit UiSyncServer(QObject *rootWindow, BleScanner *bleScanner,
                          QObject *parent = nullptr);
    bool listen(quint16 port = 8766);

private:
    void acceptConnections();
    void processSocket(QTcpSocket *socket);
    QJsonObject handleRequest(const QJsonObject &request);
    QJsonObject stateResponse() const;
    QJsonObject bleState() const;

    QObject *m_rootWindow { nullptr };
    BleScanner *m_bleScanner { nullptr };
    QTcpServer *m_server { nullptr };
    QString m_pairingAddress;
    QString m_pairingPasskey;
};
