#pragma once

#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVector>

class SystemMonitor : public QObject {
    Q_OBJECT
    Q_PROPERTY(int cpuLoad READ cpuLoad NOTIFY metricsChanged)
    Q_PROPERTY(int gpuLoad READ gpuLoad NOTIFY metricsChanged)
    Q_PROPERTY(int ddrLoad READ ddrLoad NOTIFY metricsChanged)
    Q_PROPERTY(int socTemperature READ socTemperature NOTIFY metricsChanged)
    Q_PROPERTY(double ambientTemperature READ ambientTemperature NOTIFY metricsChanged)
    Q_PROPERTY(bool ambientTemperatureValid READ ambientTemperatureValid NOTIFY metricsChanged)
    Q_PROPERTY(QString platformName READ platformName CONSTANT)
    Q_PROPERTY(QString socName READ socName CONSTANT)
    Q_PROPERTY(QString osName READ osName CONSTANT)
    Q_PROPERTY(QString kernelVersion READ kernelVersion CONSTANT)
    Q_PROPERTY(QString buildDate READ buildDate CONSTANT)
    Q_PROPERTY(QString appBuildDate READ appBuildDate CONSTANT)
    Q_PROPERTY(QString ethIp READ ethIp NOTIFY metricsChanged)
    Q_PROPERTY(QString wlanIp READ wlanIp NOTIFY metricsChanged)
    Q_PROPERTY(QString bluetoothStatus READ bluetoothStatus NOTIFY metricsChanged)
    Q_PROPERTY(QString sdTotal READ sdTotal NOTIFY metricsChanged)
    Q_PROPERTY(QString sdUsed  READ sdUsed  NOTIFY metricsChanged)
    Q_PROPERTY(QString sdFree  READ sdFree  NOTIFY metricsChanged)
    Q_PROPERTY(QVariantList ambientHistory READ ambientHistory NOTIFY metricsChanged)
    Q_PROPERTY(QVariantList socTempHistory READ socTempHistory NOTIFY metricsChanged)
    Q_PROPERTY(int historyCapacity READ historyCapacity CONSTANT)

public:
    explicit SystemMonitor(QObject *parent = nullptr);

    Q_INVOKABLE void reboot();

    int cpuLoad() const { return m_cpuLoad; }
    int gpuLoad() const { return m_gpuLoad; }
    int ddrLoad() const { return m_ddrLoad; }
    int socTemperature() const { return m_socTemp; }
    double ambientTemperature() const { return m_ambientTemp; }
    bool ambientTemperatureValid() const { return m_ambientValid; }
    QString platformName() const { return m_platform; }
    QString socName() const { return m_soc; }
    QString osName() const { return m_os; }
    QString kernelVersion() const { return m_kernel; }
    QString buildDate() const { return m_buildDate; }
    QString appBuildDate() const { return m_appBuildDate; }
    QString ethIp() const { return m_ethIp; }
    QString wlanIp() const { return m_wlanIp; }
    QString bluetoothStatus() const { return m_btStatus; }
    QString sdTotal() const { return m_sdTotal; }
    QString sdUsed()  const { return m_sdUsed; }
    QString sdFree()  const { return m_sdFree; }

    // 60-sample ring buffer (1 Hz × 60 s) for the temperature graph dialog.
    // Element 0 is oldest, last is most recent. Empty during the first second
    // after launch, then grows up to historyCapacity.
    QVariantList ambientHistory() const;
    QVariantList socTempHistory() const;
    int historyCapacity() const { return kHistoryCapacity; }

signals:
    void metricsChanged();

private slots:
    void poll();

private:
    void readStaticInfo();
    int readMaxThermal();
    int readCpuLoad();
    int readGpuLoad();
    QString readIpAddress(const QString &iface);
    QString readBluetoothStatus();
    QString runCmd(const QStringList &args);

    // External TMP119 ambient sensor on J4, behind the PCA9543 I²C mux @0x71.
    // Returns true on success and writes °C to *out.
    bool readTmp119Ambient(double *out);

    // Works out which bus TMP119 answers on. With edgepilot-tmp119.dtbo applied the
    // kernel owns the mux and gives channel 0 its own bus; without it we fall back
    // to bus 2 and select the channel by hand. Sets *manualMux accordingly.
    int  resolveTmp119Bus(bool *manualMux);
    void closeI2c();

    QTimer m_timer;

    int m_cpuLoad = 0;
    int m_gpuLoad = 0;
    int m_ddrLoad = 0;
    int m_socTemp = 0;
    double m_ambientTemp = 0.0;
    bool m_ambientValid = false;
    int m_i2cFd = -1;                  // cached /dev/i2c-N file descriptor
    int m_i2cBus = -1;                 // bus the fd belongs to (-1 = not resolved yet)
    bool m_manualMux = true;           // true = we drive the PCA9543 ourselves
    int m_loggedBus = -2;              // last (bus, mode) announced to the log
    bool m_loggedManualMux = false;
    quint64 m_lastTotal = 0, m_lastIdle = 0;

    QString m_platform, m_soc, m_os, m_kernel, m_buildDate, m_appBuildDate;
    QString m_ethIp, m_wlanIp, m_btStatus;
    QString m_sdTotal, m_sdUsed, m_sdFree;

    static constexpr int kHistoryCapacity = 60;
    QVector<double> m_ambientHistory;       // °C samples, last is newest
    QVector<int>    m_socTempHistory;       // °C samples
};
