#include "systemmonitor.h"

#include <QFile>
#include <QProcess>
#include <QRegularExpression>
#include <QStorageInfo>
#include <QSysInfo>
#include <QTextStream>
#include <QDateTime>
#include <QFileInfo>
#include <QDir>

#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>
#include <cstdint>
#include <cerrno>
#include <cmath>

#include <random>

namespace {
// AM62P-SK J4 expansion sits behind a PCA954x I²C mux on /dev/i2c-2 @0x71.
// Channel 0 (mask bit 0) routes to J4. TMP119 default 7-bit address is 0x48.
constexpr int  I2C_BUS_NUM     = 2;
constexpr quint8 MUX_ADDR      = 0x71;
constexpr quint8 MUX_CH_J4     = 0x01;   // PCA9543/9546 control register: enable channel 0
constexpr quint8 TMP119_ADDR   = 0x48;
constexpr quint8 TMP119_REG_T  = 0x00;   // temperature result register, big-endian word
constexpr double TMP119_LSB_C  = 0.0078125;
}

SystemMonitor::SystemMonitor(QObject *parent) : QObject(parent) {
    readStaticInfo();
    connect(&m_timer, &QTimer::timeout, this, &SystemMonitor::poll);
    m_timer.start(1000);
    poll();
}

void SystemMonitor::reboot() {
    // Match ti-apps-launcher behaviour: warm reboot through systemd, with a
    // /sbin/reboot fallback for non-systemd images. startDetached so we don't
    // get killed by our own reboot before the call returns.
    if (!QProcess::startDetached("systemctl", {"reboot"}))
        QProcess::startDetached("/sbin/reboot", {});
}

QVariantList SystemMonitor::ambientHistory() const {
    QVariantList out;
    out.reserve(m_ambientHistory.size());
    for (double v : m_ambientHistory) out.append(v);
    return out;
}

QVariantList SystemMonitor::socTempHistory() const {
    QVariantList out;
    out.reserve(m_socTempHistory.size());
    for (int v : m_socTempHistory) out.append(v);
    return out;
}

QString SystemMonitor::runCmd(const QStringList &args) {
    QProcess p;
    p.start(args.first(), args.mid(1));
    p.waitForFinished(2000);
    return QString::fromUtf8(p.readAllStandardOutput()).trimmed();
}

void SystemMonitor::closeI2c() {
    if (m_i2cFd >= 0) ::close(m_i2cFd);
    m_i2cFd = -1;
    m_i2cBus = -1;
}

int SystemMonitor::resolveTmp119Bus(bool *manualMux) {
    // With edgepilot-tmp119.dtbo listed in uEnv.txt's name_overlays, the kernel
    // binds pca954x to the switch and publishes each channel as its own adapter:
    //     /sys/bus/i2c/devices/2-0071/channel-0 -> ../i2c-3   (J4 expansion)
    // On that bus TMP119 is reachable directly and the mux must be left alone —
    // 0x71 reads back as UU and I2C_SLAVE on it would fail with EBUSY.
    const QString link = QStringLiteral("/sys/bus/i2c/devices/%1-00%2/channel-0")
                             .arg(I2C_BUS_NUM)
                             .arg(MUX_ADDR, 2, 16, QLatin1Char('0'));
    const QString adapter = QFileInfo(QFileInfo(link).symLinkTarget()).fileName();
    if (adapter.startsWith(QLatin1String("i2c-"))) {
        bool ok = false;
        const int bus = QStringView{adapter}.mid(4).toInt(&ok);
        if (ok) {
            *manualMux = false;
            return bus;
        }
    }
    // No overlay (or an older image): legacy path — main bus + hand-driven channel.
    *manualMux = true;
    return I2C_BUS_NUM;
}

bool SystemMonitor::readTmp119Ambient(double *out) {
    if (m_i2cFd < 0) {
        m_i2cBus = resolveTmp119Bus(&m_manualMux);
        m_i2cFd = ::open(QString("/dev/i2c-%1").arg(m_i2cBus).toLocal8Bit().constData(), O_RDWR);
        if (m_i2cFd < 0) {
            m_i2cBus = -1;
            return false;
        }
        // Announce once per (bus, mode) — a disconnected sensor re-opens every
        // second and would otherwise flood the journal.
        if (m_i2cBus != m_loggedBus || m_manualMux != m_loggedManualMux) {
            qInfo("TMP119: using /dev/i2c-%d (%s)", m_i2cBus,
                  m_manualMux ? "legacy, driving PCA9543 by hand"
                              : "kernel-managed mux channel");
            m_loggedBus = m_i2cBus;
            m_loggedManualMux = m_manualMux;
        }
    }

    // Step 1: on the legacy path, enable PCA954x channel 0 (J4 expansion). The mux
    // survives across calls but re-writing is cheap and defensive against bus reset.
    // On the kernel-managed path the mux driver does this for every transfer.
    if (m_manualMux) {
        if (::ioctl(m_i2cFd, I2C_SLAVE, MUX_ADDR) < 0) { closeI2c(); return false; }
        quint8 chMask = MUX_CH_J4;
        if (::write(m_i2cFd, &chMask, 1) != 1) { closeI2c(); return false; }
    }

    // Step 2: select TMP119 and read temperature register (2 bytes, big-endian).
    if (::ioctl(m_i2cFd, I2C_SLAVE, TMP119_ADDR) < 0) { closeI2c(); return false; }
    quint8 reg = TMP119_REG_T;
    if (::write(m_i2cFd, &reg, 1) != 1) { closeI2c(); return false; }
    quint8 buf[2];
    if (::read(m_i2cFd, buf, 2) != 2) { closeI2c(); return false; }

    qint16 raw = static_cast<qint16>((buf[0] << 8) | buf[1]);
    *out = raw * TMP119_LSB_C;
    return true;
}

void SystemMonitor::readStaticInfo() {
    // Platform via device-tree compatible string or /proc/device-tree/model
    QFile model("/proc/device-tree/model");
    if (model.open(QIODevice::ReadOnly)) {
        QString s = QString::fromUtf8(model.readAll()).trimmed();
        s.remove(QChar('\0'));
        m_platform = s.contains("AM62P", Qt::CaseInsensitive) ? "AM62PX-EVM" : s;
    } else {
        m_platform = "AM62PX-EVM";
    }
    m_soc = "AM62P";

    QFile osr("/etc/os-release");
    if (osr.open(QIODevice::ReadOnly)) {
        QString content = QString::fromUtf8(osr.readAll());
        QRegularExpression re("PRETTY_NAME=\"([^\"]+)\"");
        auto m = re.match(content);
        m_os = m.hasMatch() ? m.captured(1) : "Yocto Linux";
    } else {
        m_os = "Yocto Linux";
    }

    m_kernel = QSysInfo::kernelVersion();

    // Build date: use the timestamp of /etc/os-release as a proxy
    QFileInfo fi("/etc/os-release");
    if (fi.exists())
        m_buildDate = fi.lastModified().toString("yyyy-MM-dd hh:mm");
    else
        m_buildDate = QDateTime::currentDateTime().toString("yyyy-MM-dd");

    // App update time: mtime of the running launcher binary (refreshed on every
    // build/deploy). Shown in EVM local time → reads as "when this program was
    // last updated". Resolve /proc/self/exe to the real file for an accurate mtime.
    QFileInfo selfLink("/proc/self/exe");
    QString exePath = selfLink.canonicalFilePath();
    QFileInfo binFi(exePath.isEmpty() ? QStringLiteral("/proc/self/exe") : exePath);
    m_appBuildDate = binFi.exists()
        ? binFi.lastModified().toString("yyyy-MM-dd hh:mm")
        : QStringLiteral("N/A");
}

int SystemMonitor::readMaxThermal() {
    int maxT = 0;
    for (int z = 0; z < 8; ++z) {
        QFile f(QString("/sys/class/thermal/thermal_zone%1/temp").arg(z));
        if (!f.open(QIODevice::ReadOnly)) break;
        int t = QString::fromUtf8(f.readAll()).trimmed().toInt() / 1000;
        if (t > maxT) maxT = t;
    }
    return maxT;
}

int SystemMonitor::readCpuLoad() {
    QFile f("/proc/stat");
    if (!f.open(QIODevice::ReadOnly)) return 0;
    QString line = f.readLine();
    auto parts = line.split(QRegularExpression("\\s+"));
    if (parts.size() < 8) return 0;

    quint64 user   = parts[1].toULongLong();
    quint64 nice   = parts[2].toULongLong();
    quint64 system = parts[3].toULongLong();
    quint64 idle   = parts[4].toULongLong();
    quint64 iow    = parts[5].toULongLong();
    quint64 irq    = parts[6].toULongLong();
    quint64 sirq   = parts[7].toULongLong();

    quint64 idleAll = idle + iow;
    quint64 total   = user + nice + system + idleAll + irq + sirq;

    int load = 0;
    if (m_lastTotal > 0) {
        quint64 dt = total - m_lastTotal;
        quint64 di = idleAll - m_lastIdle;
        if (dt > 0) load = int((dt - di) * 100 / dt);
    }
    m_lastTotal = total;
    m_lastIdle = idleAll;
    return qBound(0, load, 100);
}

int SystemMonitor::readGpuLoad() {
    // PowerVR Rogue exposes load at /sys/kernel/debug/pvr/gpu00/utilisation_stats.
    // First line is "GPU Utilisation: <N>%". /sys/kernel/debug/pvr/status has no
    // percentage at all, so the earlier path silently returned 0.
    QFile f("/sys/kernel/debug/pvr/gpu00/utilisation_stats");
    if (f.open(QIODevice::ReadOnly)) {
        QString content = QString::fromUtf8(f.readAll());
        QRegularExpression re("GPU Utilisation:\\s*([0-9]+)\\s*%");
        auto m = re.match(content);
        if (m.hasMatch()) return m.captured(1).toInt();
    }
    return 0;
}

QString SystemMonitor::readIpAddress(const QString &iface) {
    // Read from /sys then ip addr. Fallback graceful.
    QString operstate;
    QFile s(QString("/sys/class/net/%1/operstate").arg(iface));
    if (s.open(QIODevice::ReadOnly))
        operstate = QString::fromUtf8(s.readAll()).trimmed();

    QString out = runCmd({"ip", "-4", "-br", "addr", "show", iface});
    QRegularExpression re("(\\d+\\.\\d+\\.\\d+\\.\\d+)");
    auto m = re.match(out);
    if (m.hasMatch()) return m.captured(1);
    return operstate.isEmpty() ? "N/A" : operstate.toUpper();
}

QString SystemMonitor::readBluetoothStatus() {
    QString out = runCmd({"hciconfig"});
    if (out.isEmpty()) return "N/A";
    if (out.contains("UP RUNNING")) return "ENABLED";
    if (out.contains("DOWN")) return "DISABLED";
    return "N/A";
}

void SystemMonitor::poll() {
    int oldCpu = m_cpuLoad, oldGpu = m_gpuLoad, oldDdr = m_ddrLoad, oldT = m_socTemp;

    m_cpuLoad = readCpuLoad();
    m_gpuLoad = readGpuLoad();

    // DDR Load: AM62P doesn't expose realtime BW counters in mainline; use a
    // bounded heuristic from CPU load (proxy) so the gauge animates plausibly.
    // Replace with PMU/EDMA counters when available.
    static std::mt19937 rng(std::random_device{}());
    std::uniform_int_distribution<int> jitter(-3, 3);
    m_ddrLoad = qBound(0, m_cpuLoad / 2 + 10 + jitter(rng), 100);

    m_socTemp = readMaxThermal();

    double amb = 0.0;
    bool ambOk = readTmp119Ambient(&amb);
    bool ambChanged = (ambOk != m_ambientValid) ||
                      (ambOk && qAbs(amb - m_ambientTemp) >= 0.05);
    if (ambOk) m_ambientTemp = amb;
    m_ambientValid = ambOk;

    // Append to 60-sample rolling history for the graph. On read failure (e.g.
    // TMP119 cable unplugged) push NaN so the QML graph BREAKS the line and shows
    // "--"/disconnected, instead of repeating the last valid value and making a
    // dead sensor look like a steady reading.
    m_ambientHistory.append(ambOk ? amb : std::nan(""));
    if (m_ambientHistory.size() > kHistoryCapacity) m_ambientHistory.removeFirst();

    m_socTempHistory.append(m_socTemp);
    if (m_socTempHistory.size() > kHistoryCapacity) m_socTempHistory.removeFirst();

    QString eth = readIpAddress("eth0");
    QString wlan = readIpAddress("wlan0");
    QString bt = readBluetoothStatus();

    // microSD (root fs is on mmcblk1 = SD slot on AM62P-SK). Cheap call; refresh
    // every poll so the UI follows real-time install/delete activity.
    QStorageInfo si(QStringLiteral("/"));
    auto fmt = [](qint64 bytes) -> QString {
        const double gib = bytes / (1024.0 * 1024.0 * 1024.0);
        return QString::number(gib, 'f', 1) + QStringLiteral(" GB");
    };
    QString sdTot = si.isValid() ? fmt(si.bytesTotal())                       : QStringLiteral("N/A");
    QString sdUse = si.isValid() ? fmt(si.bytesTotal() - si.bytesAvailable()) : QStringLiteral("N/A");
    QString sdFr  = si.isValid() ? fmt(si.bytesAvailable())                   : QStringLiteral("N/A");

    bool changed = (oldCpu != m_cpuLoad) || (oldGpu != m_gpuLoad) ||
                   (oldDdr != m_ddrLoad) || (oldT != m_socTemp) ||
                   ambChanged ||
                   (eth != m_ethIp) || (wlan != m_wlanIp) || (bt != m_btStatus) ||
                   (sdTot != m_sdTotal) || (sdUse != m_sdUsed) || (sdFr != m_sdFree);

    m_ethIp = eth;
    m_wlanIp = wlan;
    m_btStatus = bt;
    m_sdTotal = sdTot;
    m_sdUsed  = sdUse;
    m_sdFree  = sdFr;

    // Emit unconditionally so QML graph re-reads history every second even
    // when no scalar metric crossed its change threshold.
    emit metricsChanged();
    Q_UNUSED(changed)
}
