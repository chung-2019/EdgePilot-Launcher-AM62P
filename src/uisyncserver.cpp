#include "uisyncserver.h"

#include "blescanner.h"

#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QTcpServer>
#include <QTcpSocket>
#include <QVariantMap>
#include <QDebug>

UiSyncServer::UiSyncServer(QObject *rootWindow, BleScanner *bleScanner,
                           QObject *parent)
    : QObject(parent),
      m_rootWindow(rootWindow),
      m_bleScanner(bleScanner),
      m_server(new QTcpServer(this))
{
    connect(m_server, &QTcpServer::newConnection,
            this, &UiSyncServer::acceptConnections);

    connect(m_bleScanner, &BleScanner::pairingPasskey, this,
            [this](const QString &address, const QString &passkey) {
                m_pairingAddress = address;
                m_pairingPasskey = passkey;
            });
    connect(m_bleScanner, &BleScanner::pairingSucceeded, this,
            [this](const QString &) {
                m_pairingAddress.clear();
                m_pairingPasskey.clear();
            });
    connect(m_bleScanner, &BleScanner::pairingFailed, this,
            [this](const QString &, const QString &) {
                m_pairingAddress.clear();
                m_pairingPasskey.clear();
            });
}

bool UiSyncServer::listen(quint16 port)
{
    if (m_server->listen(QHostAddress::LocalHost, port)) {
        qInfo() << "UI sync bridge listening on 127.0.0.1:" << port;
        return true;
    }

    qWarning() << "UI sync bridge failed to listen:" << m_server->errorString();
    return false;
}

void UiSyncServer::acceptConnections()
{
    while (m_server->hasPendingConnections()) {
        QTcpSocket *socket = m_server->nextPendingConnection();
        socket->setParent(this);
        connect(socket, &QTcpSocket::readyRead, this,
                [this, socket]() { processSocket(socket); });
        connect(socket, &QTcpSocket::disconnected,
                socket, &QObject::deleteLater);
        if (socket->canReadLine())
            processSocket(socket);
    }
}

void UiSyncServer::processSocket(QTcpSocket *socket)
{
    if (!socket->canReadLine())
        return;

    const QByteArray line = socket->readLine().trimmed();
    QJsonParseError parseError;
    const QJsonDocument requestDocument = QJsonDocument::fromJson(line, &parseError);

    QJsonObject response;
    if (parseError.error != QJsonParseError::NoError || !requestDocument.isObject()) {
        response.insert("ok", false);
        response.insert("error", QStringLiteral("invalid JSON request"));
    } else {
        response = handleRequest(requestDocument.object());
    }

    socket->write(QJsonDocument(response).toJson(QJsonDocument::Compact));
    socket->write("\n");
    socket->disconnectFromHost();
}

QJsonObject UiSyncServer::bleState() const
{
    QJsonArray devices;
    const QVariantList sourceDevices = m_bleScanner->devices();
    for (const QVariant &entry : sourceDevices)
        devices.append(QJsonObject::fromVariantMap(entry.toMap()));

    QJsonObject state;
    state.insert("devices", devices);
    state.insert("scanning", m_bleScanner->scanning());
    state.insert("scanIntent", m_bleScanner->scanIntent());
    state.insert("status", m_bleScanner->status());
    state.insert("connectionState", m_bleScanner->connectionState());
    state.insert("connectedAddress", m_bleScanner->connectedAddress());
    state.insert("connectedName", m_bleScanner->connectedName());
    state.insert("autoReconnect", m_bleScanner->autoReconnect());
    state.insert("lastTemperature", m_bleScanner->lastTemperature());
    state.insert("lastTemperatureUnit", m_bleScanner->lastTemperatureUnit());
    state.insert("pairingAddress", m_pairingAddress);
    state.insert("pairingPasskey", m_pairingPasskey);
    state.insert("log", QJsonArray());
    return state;
}

QJsonObject UiSyncServer::stateResponse() const
{
    QJsonObject response;
    response.insert("ok", true);
    response.insert("available", true);
    response.insert("activeIndex", m_rootWindow
                    ? m_rootWindow->property("activeIndex").toInt() : -1);
    response.insert("ble", bleState());
    return response;
}

QJsonObject UiSyncServer::handleRequest(const QJsonObject &request)
{
    const QString action = request.value("action").toString();
    if (action != QLatin1String("state")
            && action != QLatin1String("bleState")) {
        QJsonObject error;
        error.insert("ok", false);
        error.insert("error", QStringLiteral("read-only bridge"));
        return error;
    }

    return stateResponse();
}
