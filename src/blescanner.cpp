#include "blescanner.h"

#include "deviceprofiles.h"

#include <QRegularExpression>
#include <QVariantMap>
#include <QDebug>
#include <QTimer>
#include <QDateTime>
#include <QLoggingCategory>
#include <cmath>
#include <cstring>
#include <cerrno>
#include <sys/socket.h>
#include <unistd.h>

Q_LOGGING_CATEGORY(lcBle, "ble")

namespace {
// Bluetooth SIG Health Thermometer Temperature Measurement (indicate-only).
// This is the char that Python `bleak` reliably subscribes to on the TIR1 and
// always-on thermometers — both power-cycle and always-on firmware push
// real measurements on this UUID.
constexpr const char *kStandardTempChar = "00002a1c-0000-1000-8000-00805f9b34fb";
constexpr const char *kVendorTempChar   = "00001524-1212-efde-1523-785feabcd123";
// NB: vendor char 00001524-… is intentionally NOT subscribed for the existing
// always-on flow. The vendor-1524 meter is the exception: 1524 carries its state
// machine — 0x54 = measuring started, 0xec = abnormal temperature, 0xff =
// measurement complete (prelude flag) — and the actual temperature lands on
// 00002a1c right after the 0xff/0xec frame.
constexpr const char *kCharUuids[]   = { kStandardTempChar };
constexpr int         kCharUuidCount = sizeof(kCharUuids) / sizeof(kCharUuids[0]);

// Fix A — in-connection re-read on the meter's zero-mantissa placeholder.
// When a power-cycle meter is caught mid-computation it
// serves a cached `04 00 00 00` placeholder on the first read; the fresh value
// lands a few seconds later. Rather than dropping the link and paying a full
// advertise→connect→resolve reconnect (~3-4 s of churn), re-read the live 2A1C
// handle on the SAME connection a few times. The retry counter bounds the
// total wait; if exhausted we fall back to the original drop→reconnect path.
constexpr int kMaxPlaceholderReadRetries = 8;     // ~6.4 s of in-connection polling
constexpr int kPlaceholderReadIntervalMs = 800;

// Pending-connect protection window (btmon-proven, long-hold HTS 2026-06-18).
// A long-hold HTS meter naps its radio for a few seconds right after a disconnect and
// only answers a connect once it re-enters its connectable window. The launcher
// has three independent reconnect initiators (adv-driven onReconnectTimer,
// periodic onPeriodicConnectTimer, the initial connectInternal); when they fire
// within ~1-2 s of each other, every new `connect`/`scan` cancels the still-
// pending LE create-connection of the previous one — btmon shows a storm of
// `le-connection-abort-by-local`, and the reading stalls ~20 s until one attempt
// happens to land. So once ANY initiator issues `connect`, no other initiator
// may issue connect / toggle scan until this window elapses — long enough for
// the napping meter to wake and answer, short enough that the 7 s standard-mode
// subscribe watchdog (onSubscribeTimeout) stays the sole authorised canceller of
// a genuinely stuck attempt.
constexpr qint64 kConnectProtectMs = 6000;

QString bluezDevicePath(const QString &address)
{
    QString path = address;
    path.replace(':', '_');
    return QStringLiteral("/org/bluez/hci0/dev_%1").arg(path);
}
}

BleScanner::BleScanner(QObject *parent) : QObject(parent)
{
    m_subscribeTimer = new QTimer(this);
    m_subscribeTimer->setSingleShot(true);
    connect(m_subscribeTimer, &QTimer::timeout, this, &BleScanner::onSubscribeTimeout);

    m_reconnectTimer = new QTimer(this);
    m_reconnectTimer->setSingleShot(true);
    connect(m_reconnectTimer, &QTimer::timeout, this, &BleScanner::onReconnectTimer);

    m_streamingTimer = new QTimer(this);
    m_streamingTimer->setSingleShot(true);
    connect(m_streamingTimer, &QTimer::timeout, this, &BleScanner::onStreamingTimeout);

    // Fires every 8 s while latched to a target. Compensates for meters whose
    // advertising interval stretches to 10+ s after a measurement burst — by
    // that point bluez has stopped emitting [CHG] for the peer, so the
    // advertisement-driven reconnect path never fires and we'd sit idle
    // forever. Active connect from the central side works even when the peer
    // is between adv bursts as long as it's still in a connectable window.
    m_periodicConnectTimer = new QTimer(this);
    // Adv-driven reconnect is the primary path, the same shape a dedicated
    // patient-monitor host uses: controller-level scan filter → catch target
    // MAC adv → immediate Create Connection. This periodic blind-connect only fires as a deep-
    // sleep safety net when no advertisement has been seen for 10 s — at
    // which point the device's adv interval has stretched past anything we
    // can predict. A short (2.5 s) interval here turns into 7–10 s LL
    // Initiator stalls because each blind `connect` parks bluez in LL
    // Initiating mode while the device isn't yet adverting.
    m_periodicConnectTimer->setInterval(10000);
    connect(m_periodicConnectTimer, &QTimer::timeout, this, &BleScanner::onPeriodicConnectTimer);

    // Scan-health watchdog: ticks every 3 s. In standard mode it detects a
    // stalled CC3351 scan (scanning + idle but zero advertisements) and
    // power-cycles the adapter to recover adv-driven reconnect.
    m_scanHealthTimer = new QTimer(this);
    m_scanHealthTimer->setInterval(3000);
    connect(m_scanHealthTimer, &QTimer::timeout, this, &BleScanner::onScanHealthCheck);
    m_scanHealthTimer->start();
}

bool BleScanner::connectProtected() const
{
    return m_lastConnectAttemptMs != 0 &&
           (QDateTime::currentMSecsSinceEpoch() - m_lastConnectAttemptMs) < kConnectProtectMs;
}

void BleScanner::onPeriodicConnectTimer()
{
    if (!m_autoReconnect || m_targetAddress.isEmpty()) return;
    if (!m_proc || m_proc->state() != QProcess::Running) return;
    if (m_connState != "idle") return;
    // Pairing in flight — see onReconnectTimer(): a blind connect mid-`pair`
    // breaks the SMP handshake and makes the confirm dialog appear to do nothing.
    if (!m_pairingAddress.isEmpty()) return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now < m_cooldownUntilMs) return;
    if (m_reconnectTimer->isActive()) return;
    // A connect issued moments ago (e.g. one that just failed fast with
    // abort-by-local and flipped us back to idle) is still inside its protection
    // window — don't fire another one on top of it. The repeating periodic timer
    // re-checks on its next tick.
    if (connectProtected()) return;
    qCInfo(lcBle) << "periodic active-connect fallback for" << m_targetAddress;
    setConnState("connecting");
    setStatus(QString("Active reconnecting %1…").arg(m_targetAddress));
    if (m_inGattMenu) { writeLine("back"); m_inGattMenu = false; }
    // CC3351 is single-radio: with scan still on, the LE Connect Request
    // serialises behind the scan window and stalls 7–9 s waiting for it to
    // settle. Stop the scan before issuing connect, matching onReconnectTimer().
    if (m_scanning) {
        writeLine("scan off");
        m_scanning = false;
        emit scanningChanged();
    }
    if (m_standardMode) loadConnParams(m_targetAddress);
    else if (m_numericMode) loadConnParams(m_targetAddress, numericSupervisionUnits());  // numeric: fast 15-30ms interval; 4s supervision for the self-power-cycling the meter vendor meters, 15s for the always-on Apollo510b
    writeLine(QString("connect %1").arg(m_targetAddress).toUtf8());
    m_subscribeTimer->start(fastSubscribe() ? 7000 : 15000);
}

void BleScanner::onScanHealthCheck()
{
    // Only meaningful in standard mode while latched to a target, supposed to be
    // scanning, and not currently linked. A healthy scan surfaces nearby
    // advertisements constantly; several ticks of total silence means the CC3351
    // scan has wedged (Discovery on, zero [CHG]/[NEW] Device) and adv-driven
    // reconnect is dead — power-cycle the adapter to recover it.
    if (!m_standardMode || !m_autoReconnect || m_targetAddress.isEmpty()) {
        m_scanStaleCount = 0;
        return;
    }
    if (!m_scanning || m_connState != "idle") {
        // Connecting/streaming, or scan intentionally off during a blind connect:
        // no advertisements are expected, so this is not a stall.
        m_scanStaleCount = 0;
        return;
    }
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (m_lastAdvMs == 0) { m_lastAdvMs = now; m_scanStaleCount = 0; return; }
    if (now - m_lastAdvMs < 3000) {          // saw an advertisement recently → healthy
        m_scanStaleCount = 0;
        return;
    }
    if (++m_scanStaleCount >= 3) {           // ~9 s scanning+idle with zero advertisements
        m_scanStaleCount = 0;
        recoverStalledScan();
    }
}

void BleScanner::recoverStalledScan()
{
    if (!m_proc || m_proc->state() != QProcess::Running) return;
    qCInfo(lcBle) << "scan stalled (no advertisements while scanning) — power-cycling hci0";
    setStatus("Scan stalled — resetting adapter…");
    // power off resets the controller's LE state, clearing a wedged scan; the
    // staged power on + scan on below brings it back and the reconnect loop
    // (periodic + adv-driven) resumes. Only fires when idle, so no live link is
    // torn down.
    if (m_inGattMenu) { writeLine("back"); m_inGattMenu = false; }
    writeLine("power off");
    m_scanning = false;
    emit scanningChanged();
    setConnState("idle");
    QTimer::singleShot(1500, this, [this]() {
        if (!m_proc || m_proc->state() != QProcess::Running) return;
        writeLine("power on");
        QTimer::singleShot(1500, this, [this]() {
            if (!m_proc || m_proc->state() != QProcess::Running) return;
            writeLine("scan on");
            m_scanning = true;
            m_lastAdvMs = QDateTime::currentMSecsSinceEpoch();
            emit scanningChanged();
        });
    });
}

void BleScanner::onStreamingTimeout()
{
    if (m_connState != "streaming" && m_connState != "connected") return;
    qCInfo(lcBle) << "no indicate within window — dropping ghost link";
    setStatus("No indicate — dropping link");
    if (m_inGattMenu) {
        writeLine("notify off");
        writeLine("back");
        m_inGattMenu = false;
    }
    if (!m_connectedAddress.isEmpty()) {
        writeLine(QString("disconnect %1").arg(m_connectedAddress).toUtf8());
    }
    // m_cooldownUntilMs is bumped when bluez emits Connected: no shortly after.
}

BleScanner::~BleScanner()
{
    if (m_proc) {
        m_proc->kill();
        m_proc->waitForFinished(500);
    }
}

QVariantList BleScanner::devices() const
{
    QVariantList out;
    out.reserve(m_order.size());
    for (const auto &addr : m_order) {
        QVariantMap m;
        m["address"] = addr;
        m["name"]    = m_byAddr.value(addr);
        out.push_back(m);
    }
    return out;
}

void BleScanner::setStatus(const QString &s)
{
    if (m_status == s) return;
    m_status = s;
    emit statusChanged();
}

void BleScanner::setConnState(const QString &s)
{
    if (m_connState == s) return;
    qCInfo(lcBle) << "connState ->" << s;
    m_connState = s;
    emit connectionStateChanged();
}

void BleScanner::setConnectedAddress(const QString &a)
{
    if (m_connectedAddress == a) return;
    m_connectedAddress = a;
    emit connectedAddressChanged();
}

void BleScanner::setConnectedName(const QString &n)
{
    if (m_connectedName == n) return;
    m_connectedName = n;
    emit connectedNameChanged();
}

void BleScanner::setAutoReconnect(bool on)
{
    if (m_autoReconnect == on) return;
    m_autoReconnect = on;
    emit autoReconnectChanged();
}

void BleScanner::clearLastTemperature()
{
    if (m_lastTemperature <= 0 && m_lastTemperatureUnit == QStringLiteral("C")) return;
    m_lastTemperature = 0;
    m_lastTemperatureUnit = QStringLiteral("C");
    emit lastTemperatureChanged();
}

// The three name slots are concatenated on purpose: during a reconnect the
// connected/target/cached names take turns being the only populated one, and a
// match on any of them is the same device.
QString BleScanner::identityNames() const
{
    return m_connectedName + QStringLiteral(" ") +
           m_byAddr.value(m_connectedAddress) + QStringLiteral(" ") +
           m_byAddr.value(m_targetAddress);
}

bool BleScanner::isVendor1524Device() const
{
    return DeviceProfiles::matches(identityNames(),
                                   DeviceProfiles::instance().vendor1524Tokens());
}

bool BleScanner::isAlwaysOnFirmware() const
{
    return DeviceProfiles::matches(identityNames(),
                                   DeviceProfiles::instance().alwaysOnTokens());
}

bool BleScanner::isApollo510Device() const
{
    // Unlike the meter families above this one is NOT profile-driven: the name
    // is this project's own firmware (nemagfx_watchface sets TMPS_DEVICE_NAME),
    // so it ships with the code rather than with the deployment.
    static const QStringList kApolloTokens { QStringLiteral("EdgePilot-510B") };
    return DeviceProfiles::matches(identityNames(), kApolloTokens);
}

QStringList BleScanner::tempCharSelectors() const
{
    // Scan3 (numeric-comparison) / standard / long-hold HTS keep selecting 0x2A1C by
    // bare UUID — untouched (red line). fastSubscribe() is m_standardMode ||
    // m_numericMode, so this branch is the ONLY thing those modes ever use.
    if (fastSubscribe()) {
        return { QString::fromLatin1(kStandardTempChar) };
    }
    // BLE SCAN: select the CONNECTED device's ACTUAL 0x2A1C object path, captured
    // from GATT discovery (handleLine → m_tempCharPath). This is handle-
    // independent (discovered at runtime, never hard-coded) AND device-scoped.
    //
    // Two bugs this closes (both 2026-07-03, on the always-on meter):
    //  1. Hard-coded handles (old service0022/char0023) hit a vendor char
    //     (0x1524, returns 0x00) because THIS unit exposes 0x2A1C at
    //     service0028/char0029 — no temperature ever arrived. (iPhone read it
    //     fine on the same pairing-free direct connect → handle bug, not
    //     encryption.)
    //  2. A bare-UUID select-attribute is device-ambiguous: after the meter's
    //     MAC was changed, bluetoothctl resolved the UUID to the stale cached
    //     old-MAC device (same device alias, different address) and read a
    //     disconnected link → "Failed to read" ×8. The full object path names
    //     dev_<connected> explicitly, so it can't mis-resolve.
    const QString device = !m_connectedAddress.isEmpty() ? m_connectedAddress
                                                         : m_targetAddress;
    const QString devPrefix = bluezDevicePath(device);
    if (!m_tempCharPath.isEmpty() && m_tempCharPath.startsWith(devPrefix)) {
        return { m_tempCharPath };
    }
    // Discovery hasn't surfaced the 0x2A1C handle for this device yet — fall
    // back to the bare UUID (correct whenever no stale same-alias device shadows
    // it; a fresh connect re-runs discovery and repopulates m_tempCharPath).
    return { QString::fromLatin1(kStandardTempChar) };
}

void BleScanner::upsertDevice(const QString &addr, const QString &name)
{
    const bool existed = m_byAddr.contains(addr);
    const QString prev = existed ? m_byAddr.value(addr) : QString();

    QString resolved = name.trimmed();
    if (existed && !prev.isEmpty()) {
        const bool prevIsPlaceholder = QRegularExpression("^[0-9A-F-]{17}$").match(prev).hasMatch();
        const bool newIsPlaceholder  = QRegularExpression("^[0-9A-F-]{17}$").match(resolved).hasMatch();
        if (!prevIsPlaceholder && newIsPlaceholder) return;
    }

    m_byAddr[addr] = resolved;
    if (!existed) m_order.push_back(addr);
    emit devicesChanged();
}

void BleScanner::clearDevices()
{
    if (m_order.isEmpty() && m_byAddr.isEmpty()) return;
    m_order.clear();
    m_byAddr.clear();
    emit devicesChanged();
}

void BleScanner::writeLine(const QByteArray &cmd)
{
    if (m_proc && m_proc->state() == QProcess::Running) {
        qCInfo(lcBle).nospace() << "→ " << cmd;
        // Stamp the protection window from the single command choke-point so
        // EVERY `connect <addr>` (initial tap, adv-driven, periodic) is covered.
        // Trailing space excludes `disconnect <addr>`. See kConnectProtectMs.
        if (cmd.startsWith("connect "))
            m_lastConnectAttemptMs = QDateTime::currentMSecsSinceEpoch();
        m_proc->write(cmd);
        if (!cmd.endsWith('\n')) m_proc->write("\n");
    }
}

void BleScanner::ensureProcess()
{
    if (m_proc && m_proc->state() == QProcess::Running) return;

    if (m_proc) { m_proc->deleteLater(); m_proc = nullptr; }

    m_proc = new QProcess(this);
    m_proc->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_proc, &QProcess::readyReadStandardOutput, this, &BleScanner::onStdout);
    connect(m_proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &BleScanner::onProcessFinished);

    QStringList env = QProcess::systemEnvironment();
    env << "TERM=dumb";
    m_proc->setEnvironment(env);

    qCInfo(lcBle) << "Starting bluetoothctl";
    m_proc->start("bluetoothctl", QStringList{});
    if (!m_proc->waitForStarted(2000)) {
        setStatus("Failed to start bluetoothctl");
        m_proc->deleteLater();
        m_proc = nullptr;
        return;
    }
    writeLine("power on");
    // Numeric-comparison pairing requires a KeyboardDisplay agent so bluez
    // forwards the 6-digit passkey to us via "Confirm passkey N (yes/no)".
    // Without an agent of this capability the device just fails with
    // AuthenticationRejected. Setting it once at startup is safe — it does
    // not interfere with the trust-only thermometer flow on UUID 1524/2A1C.
    writeLine("agent KeyboardDisplay");
    writeLine("default-agent");
}

void BleScanner::startScan()
{
    // Record user intent before any early-return: even if the controller
    // is already scanning (e.g. auto-reconnect has it on), the UI button
    // must flip to "Stop Scan" so the user can dismiss it explicitly.
    if (!m_scanIntent) {
        m_scanIntent = true;
        emit scanIntentChanged();
    }

    if (m_scanning) return;

    if (m_inGattMenu) {
        writeLine("back");
        m_inGattMenu = false;
    }

    clearDevices();
    ensureProcess();
    if (!m_proc) return;

    // Seed the list with already-known (paired/trusted/previously-seen) devices.
    // bluez only emits `[NEW] Device …` for previously-unknown peers, so a
    // device we have already trusted (e.g. the thermometer the user connected
    // to in a prior session) will silently never appear in a fresh scan.
    writeLine("devices");
    writeLine("scan on");

    m_scanning = true;
    emit scanningChanged();
    setStatus("Scanning…");
}

void BleScanner::stopScan()
{
    // Always drop the user intent so the button flips back to "Start Scan"
    // even when the controller is currently scanning under auto-reconnect's
    // wing (m_scanning could be true via internal toggling).
    if (m_scanIntent) {
        m_scanIntent = false;
        emit scanIntentChanged();
    }
    if (!m_scanning || !m_proc) return;
    writeLine("scan off");
    m_scanning = false;
    emit scanningChanged();
    setStatus(QString("Stopped (%1 device%2)").arg(m_order.size()).arg(m_order.size() == 1 ? "" : "s"));
}

void BleScanner::connectDevice(const QString &address)
{
    // Default (BLE Scan / Scan2 / Scan3) path — subscribe by hard-coded handle.
    //
    // EXCEPTION — long-hold HTS: this firmware is a standard HTS meter that
    // STAYS CONNECTED and streams a Temperature Measurement (0x2A1C) indication
    // every ~5 s. Verified against nRF Toolbox / iOS CoreBluetooth: one
    // connection held 47 s and delivered 8 readings, and the link dropped only
    // when the user disconnected. The legacy hard-coded-handle path here arms a
    // 6 s ghost-drop after every "Notify started" and reconnects once per
    // reading, which fights a stream-while-connected device and makes it slow
    // and lossy on the CC3351 single radio. Route long-hold HTS through standard mode
    // instead: select 0x2A1C by UUID (handle-layout independent), subscribe
    // notify-only (no read; 2A1C is indicate-only), and HOLD the link (60 s
    // re-arm) rather than ghost-dropping — i.e. mirror what nRF does. Only this
    // device is affected; every other meter keeps the hard-coded power-cycle path.
    const QString name = m_byAddr.value(address);
    m_standardMode = DeviceProfiles::matches(name, DeviceProfiles::instance().longHoldTokens());
    m_numericMode  = false;   // tap-to-connect (Scan / Scan2) is trust-only, not numeric-comparison
    connectInternal(address);
}

void BleScanner::connectStandardDevice(const QString &address)
{
    // 標準品BLE path — subscribe 0x2A1C by UUID (handle-layout independent).
    m_standardMode = true;
    m_numericMode  = false;
    connectInternal(address);
}

void BleScanner::connectInternal(const QString &address)
{
    if (address.isEmpty()) return;

    ensureProcess();
    if (!m_proc) return;

    if (m_scanning) {
        writeLine("scan off");
        m_scanning = false;
        emit scanningChanged();
    }
    if (m_inGattMenu) {
        writeLine("back");
        m_inGattMenu = false;
    }

    // Latch this address as the persistent reconnect target.
    m_targetAddress  = address;
    setAutoReconnect(true);
    // Periodic active connect is a deep-sleep SAFETY NET, not the primary path:
    // the meter advertises every ~250 ms and stays connectable, so the adv-driven
    // reconnect (onReconnectTimer) normally pulls the link back the instant the
    // meter beacons. The periodic blind `connect` only matters when the scan goes
    // silent right after a disconnect on the CC3351 single radio (Discovery
    // "started" yet zero [CHG] events) and no advertisement surfaces to drive it.
    //
    // It MUST run slow (8 s). A tight 2.5 s cadence (the old value) fired a fresh
    // blind connect on top of one that was still pending — every new connect/scan
    // cancelled the previous in-flight LE create-connection
    // (le-connection-abort-by-local), so post-disconnect reconnect stalled ~20 s
    // until one attempt happened to land (btmon-proven, long-hold HTS
    // 2026-06-18). The protection window (kConnectProtectMs) now also stops
    // initiators from cancelling each other; the slow cadence keeps this path a
    // genuine fallback instead of a competing hammer.
    m_periodicConnectTimer->setInterval(m_standardMode ? 8000 : 10000);
    m_periodicConnectTimer->start();   // active-connect (deep-sleep safety net)
    setConnectedAddress(address);
    setConnectedName(m_byAddr.value(address));
    setConnectedAddress(address);
    setConnectedName(m_byAddr.value(address));
    setConnState("connecting");
    setStatus(QString("Connecting %1…").arg(address));

    m_charAttempt = 0;
    m_subscribedOnce = false;
    m_dropNextTemperatureSample = isAlwaysOnFirmware();
    m_vendor1524TemperaturePending = false;
    clearLastTemperature();
    // Trust only — this thermometer firmware does not support pairing
    // (org.bluez.Error.AuthenticationFailed). Attempting `pair` also conflicts
    // with our explicit `connect` (org.bluez.Error.InProgress) and tears down
    // the link before we can subscribe. trust is enough for bluez to accept
    // future peripheral-initiated connections.
    writeLine(QString("trust %1").arg(address).toUtf8());
    if (m_standardMode) loadConnParams(address);
    writeLine(QString("connect %1").arg(address).toUtf8());

    m_subscribeTimer->start(fastSubscribe() ? 7000 : 15000);
}

void BleScanner::pairDevice(const QString &address)
{
    if (address.isEmpty()) return;
    ensureProcess();
    if (!m_proc) return;

    // Guard against double-tap: if a pair flow is already in progress for the
    // same device, ignore the duplicate. Sending a second "pair" while the
    // agent is asking "Confirm passkey N (yes/no):" pipes the literal command
    // into the prompt — bluez sees invalid input and aborts with
    // org.bluez.Error.AuthenticationFailed.
    if (!m_pairingAddress.isEmpty()) {
        qCInfo(lcBle) << "pair ignored — flow already in progress for"
                      << m_pairingAddress;
        return;
    }

    if (m_scanning) {
        writeLine("scan off");
        m_scanning = false;
        emit scanningChanged();
    }
    if (m_inGattMenu) {
        writeLine("back");
        m_inGattMenu = false;
    }

    // User explicitly retrying this address — lift the prior cancel block
    // so the next agent prompt actually surfaces to the UI.
    m_cancelledPairings.remove(address.toUpper());

    // Enable the fast-subscribe strategy (early CCCD arm on Connected:yes +
    // UUID select) so each reconnect skips the 4-5 s ServicesResolved wait.
    // NOT m_standardMode — that would bring long-hold HTS's 15 s supervision / 60 s
    // hold, which slows disconnect detection on a meter that power-cycles
    // itself. Both callers land here: BLE Scan 3 / BLE Pair with the third-party
    // power-cycle meters, and BLE Scan with the always-on Apollo510b watch;
    // isApollo510Device() is what separates the two where they differ.
    m_numericMode = true;
    m_pairingAddress = address;
    m_pairingPasskey.clear();
    m_subscribeAfterPairing = false;   // fresh pairing — no deferred subscribe owed
    // Set the connected/target slots NOW so the ServicesResolved-triggered
    // subscribeNextTempChar() can resolve isPowerCycleDevice() correctly
    // (it reads from m_connectedAddress / m_targetAddress / m_byAddr). If we
    // wait for "Paired: yes" the subscribe path runs first with empty fields
    // and treats a power-cycle meter like an always-on device, dropping the very
    // first 2A1C indicate of every (re)connect as "cached initial temp".
    m_targetAddress = address;
    setAutoReconnect(true);
    m_periodicConnectTimer->start();
    setConnectedAddress(address);
    setConnectedName(m_byAddr.value(address));
    setStatus(QString("Pairing %1…").arg(address));
    // `pair` triggers numeric-comparison handshake. bluez will call the
    // agent's RequestConfirmation, which bluetoothctl prints as
    // "Confirm passkey 123456 (yes/no):".
    writeLine(QString("pair %1").arg(address).toUtf8());
}

void BleScanner::confirmPairing()
{
    if (!m_proc || m_pairingAddress.isEmpty()) return;
    writeLine("yes");
    setStatus(QString("Pairing %1 — confirmed").arg(m_pairingAddress));
}

void BleScanner::cancelPairing()
{
    if (!m_proc) return;
    if (m_pairingAddress.isEmpty()) return;

    const QString addr = m_pairingAddress;

    // 1) Reject the agent's "Confirm passkey N (yes/no):" prompt.
    writeLine("no");
    // 2) Tell bluez to fully abort the pairing transaction. Without this,
    //    the peer's next pair request (it WILL retry on numeric-comparison
    //    rejection) generates a fresh 6-digit passkey, bluez agent re-prompts,
    //    our handler emits pairingPasskey again, and the dialog reopens.
    writeLine(QString("cancel-pairing %1").arg(addr).toUtf8());
    // 3) Block subsequent agent prompts for this address. If the device
    //    re-advertises and bluez retries pair anyway, the rePairPasskey
    //    handler auto-rejects without re-opening the dialog.
    m_cancelledPairings.insert(addr.toUpper());
    // 4) Clear in-flight pairing state.
    m_pairingAddress.clear();
    m_pairingPasskey.clear();
    m_subscribeAfterPairing = false;
    // 5) Drop auto-reconnect for this address — otherwise the periodic
    //    timer would keep waking the link and the peer would re-pair.
    if (m_targetAddress.compare(addr, Qt::CaseInsensitive) == 0) {
        m_targetAddress.clear();
        setAutoReconnect(false);
        if (m_periodicConnectTimer) m_periodicConnectTimer->stop();
    }
    // 6) Drop the LL link so the peer stops being a "connected" peer.
    if (!m_connectedAddress.isEmpty() &&
        m_connectedAddress.compare(addr, Qt::CaseInsensitive) == 0) {
        writeLine(QString("disconnect %1").arg(addr).toUtf8());
    }

    setStatus(QString("Pairing cancelled (%1)").arg(addr));
    emit pairingFailed(addr, QStringLiteral("Cancelled by user"));
}

void BleScanner::unpairDevice(const QString &address)
{
    if (address.isEmpty() || !m_proc) return;
    writeLine(QString("remove %1").arg(address).toUtf8());
    setStatus(QString("Removed pairing for %1").arg(address));
}

void BleScanner::setAutoConnectCompanyId(int cid)
{
    if (m_autoConnectCompanyId == cid) return;
    m_autoConnectCompanyId = cid;
    qCInfo(lcBle) << "auto-connect company ID set to" << QString::asprintf("0x%04x", cid);
    emit autoConnectCompanyIdChanged();
}

void BleScanner::clearAllPairings()
{
    ensureProcess();
    if (!m_proc) return;
    // `devices Paired` and `remove` only exist in the MAIN menu — issuing
    // them inside the `gatt` submenu silently fails with
    // "Invalid command in menu gatt: devices". The previous tap may have
    // left us inside the gatt menu (subscribe path), so back out first.
    if (m_inGattMenu) {
        writeLine("back");
        m_inGattMenu = false;
    }
    // Drop any in-flight pair state so the UI returns to a clean slate.
    if (!m_pairingAddress.isEmpty()) {
        writeLine("no");   // dismiss any pending Confirm prompt
        m_pairingAddress.clear();
        m_pairingPasskey.clear();
    }
    // Walk the known device list and `remove` each. Harmless if a MAC wasn't
    // actually paired — bluez just no-ops. Use a small delay so the `back`
    // command above has time to land in the main menu before remove fires.
    QStringList knownPaired;
    for (const auto &addr : m_order) knownPaired.append(addr);
    QTimer::singleShot(150, this, [this, knownPaired]() {
        writeLine("devices Paired");
        for (const QString &addr : knownPaired) {
            writeLine(QString("remove %1").arg(addr).toUtf8());
        }
    });
    setStatus("Cleared all pairings");
}

void BleScanner::disconnectDevice()
{
    // User-initiated stop: cancel the auto-reconnect loop entirely.
    setAutoReconnect(false);
    m_targetAddress.clear();
    m_reconnectTimer->stop();
    m_subscribeTimer->stop();
    m_periodicConnectTimer->stop();

    if (!m_proc) {
        setConnState("idle");
        return;
    }
    if (m_inGattMenu) {
        writeLine("notify off");
        writeLine("back");
        m_inGattMenu = false;
    }
    if (!m_connectedAddress.isEmpty()) {
        writeLine(QString("disconnect %1").arg(m_connectedAddress).toUtf8());
    }
    setConnState("idle");
    setStatus("Disconnected (auto-reconnect off)");
    setConnectedAddress("");
    setConnectedName("");
    m_pendingValueLine = false;
    m_charAttempt = 0;
    m_subscribedOnce = false;
    m_dropNextTemperatureSample = false;
    m_vendor1524TemperaturePending = false;
    clearLastTemperature();
}

void BleScanner::onReconnectTimer()
{
    if (!m_autoReconnect || m_targetAddress.isEmpty()) return;
    if (!m_proc || m_proc->state() != QProcess::Running) return;
    // Never issue a reconnect `connect` while a pairing handshake is in flight:
    // an adv-driven connect injected mid-`pair` collides with bluez's SMP, storms
    // the passkey agent (the prompt repeats dozens of times) and the pair dies
    // with AuthenticationFailed — so the user's "confirm" then does nothing.
    if (!m_pairingAddress.isEmpty()) return;
    if (m_connState == "connecting" ||
        m_connState == "connected"  ||
        m_connState == "streaming") return;

    // A connect issued moments ago is still inside its protection window — firing
    // another `connect`/`scan off` now would cancel the in-flight LE create-
    // connection (le-connection-abort-by-local). Defer this attempt to just after
    // the window so the napping meter gets the uninterrupted seconds it needs to
    // wake and answer the pending connect.
    if (connectProtected()) {
        const qint64 remaining =
            kConnectProtectMs - (QDateTime::currentMSecsSinceEpoch() - m_lastConnectAttemptMs);
        m_reconnectTimer->start(static_cast<int>(remaining > 0 ? remaining : 0) + 50);
        return;
    }

    qCInfo(lcBle) << "auto-reconnect attempt for" << m_targetAddress;
    setConnState("connecting");
    setStatus(QString("Reconnecting %1…").arg(m_targetAddress));
    m_charAttempt    = 0;
    m_subscribedOnce = false;
    m_dropNextTemperatureSample = isAlwaysOnFirmware();
    m_vendor1524TemperaturePending = false;
    clearLastTemperature();
    // bluetoothctl stays in `gatt` submenu across peer disconnects.
    writeLine("back");
    m_inGattMenu = false;
    // Stop scan during the connect attempt — CC3351 single-radio scheduling
    // works better when scan is off during link establishment.
    if (m_scanning) {
        writeLine("scan off");
        m_scanning = false;
        emit scanningChanged();
    }
    if (m_standardMode) loadConnParams(m_targetAddress);
    else if (m_numericMode) loadConnParams(m_targetAddress, numericSupervisionUnits());  // numeric: fast 15-30ms interval; 4s supervision for the self-power-cycling the meter vendor meters, 15s for the always-on Apollo510b
    writeLine(QString("connect %1").arg(m_targetAddress).toUtf8());
    m_subscribeTimer->start(fastSubscribe() ? 7000 : 15000);
}

void BleScanner::loadConnParams(const QString &address, quint16 supervisionUnits)
{
    // Why this exists (long-hold HTS, btmon-proven on the CC3351/TI kernel):
    //
    //  * The kernel opens LE links with its built-in default supervision
    //    timeout of 420 ms. The long-hold HTS radio naps longer than that while
    //    pre-warming, so a fresh link dies (HCI 0x08) before the meter's own
    //    L2CAP parameter request (15-30 ms / latency 0 / timeout 4 s, sent by
    //    its firmware right after connect) can be applied.
    //  * This kernel exposes NO default-parameter knobs: debugfs is empty and
    //    MGMT Read/Set Default System Configuration returns nothing, so the
    //    main.conf [LE] section silently does nothing here.
    //  * Mid-link LE Connection Updates are RUSSIAN ROULETTE on this device:
    //    its radio naps, it misses the update instant, and the spec forces a
    //    disconnect — btmon showed 12× "Instant Passed (0x28)" deaths,
    //    matching both our old hcitool-lecup shots and the meter's own
    //    request. The fewer updates on the link, the better.
    //
    // The one lever the kernel does honour is the PER-DEVICE connection
    // parameter list (MGMT Load Connection Parameters, opcode 0x0025): create
    // connections to a listed device start with the listed parameters from
    // t=0. bluez loads this list from storage only at adapter init, and the
    // entry can drop out mid-session (observed: 22 of 36 connects fell back
    // to 420 ms) — so re-assert it ourselves right before every connect
    // attempt, through the raw MGMT control socket.
    //
    // The values are EXACTLY what the long-hold HTS firmware itself requests
    // (min 12×1.25=15 ms, max 24×1.25=30 ms, latency 0, timeout 400×10ms=4 s).
    // Matching matters: Zephyr's bt_conn_le_param_update() skips sending its
    // request when the live parameters already satisfy it, so the link runs
    // with ZERO connection updates — no 0x28 window at all. nRF/iOS held
    // through warm-up + measurement on these same values.
    if (address.isEmpty()) return;
    const QStringList parts = address.split(QLatin1Char(':'));
    if (parts.size() != 6) return;

    quint8 pkt[6 + 2 + 7 + 8];   // MGMT hdr + count + addr_info + conn params
    quint8 *p = pkt;
    auto put16 = [&p](quint16 v) { *p++ = v & 0xff; *p++ = v >> 8; };
    put16(0x0035);               // MGMT_OP_LOAD_CONN_PARAM (btmon-verified opcode)
    put16(0x0000);               // controller index 0 (hci0)
    put16(17);                   // payload length
    put16(1);                    // param_count
    bool ok = true;
    for (int i = 5; i >= 0; --i) // bdaddr_t is little-endian (reversed)
        *p++ = static_cast<quint8>(parts[i].toUInt(&ok, 16));
    if (!ok) return;
    // MGMT address type: 1 = LE public, 2 = LE random. Top two bits 11 =
    // static random address (covers the F3:… and C0:… prefixes we see).
    const quint8 first = static_cast<quint8>(parts[0].toUInt(&ok, 16));
    *p++ = ((first & 0xC0) == 0xC0) ? 2 : 1;
    put16(12);                   // min interval (×1.25 ms = 15 ms)
    put16(24);                   // max interval (×1.25 ms = 30 ms)
    put16(0);                    // latency
    put16(supervisionUnits);     // supervision timeout (×10 ms): 1500=15s long-hold HTS, 400=4s numeric — must
                                 // cover the meter's 10 s warm-up radio stall;
                                 // matches the fixed firmware's own request so
                                 // Zephyr skips its update (zero updates, zero
                                 // 0x28). NB the device's GAP auto-update at
                                 // ~5 s uses CONFIG_BT_PERIPHERAL_PREF_* — the
                                 // firmware must set those to 12/24/0/1500 too
                                 // (defaults are 24/40/0/42 = 420 ms, which
                                 // poisons the link and bluez's stored params).

    struct SockaddrHci {
        sa_family_t    family;
        unsigned short dev;
        unsigned short channel;
    } sa {};
    sa.family  = 31;             // AF_BLUETOOTH
    sa.dev     = 0xffff;         // HCI_DEV_NONE (required for the control channel)
    sa.channel = 3;              // HCI_CHANNEL_CONTROL (mgmt)
    const int fd = ::socket(31 /*AF_BLUETOOTH*/, SOCK_RAW | SOCK_CLOEXEC,
                            1 /*BTPROTO_HCI*/);
    if (fd < 0) {
        qCWarning(lcBle) << "loadConnParams: socket failed:" << strerror(errno);
        return;
    }
    if (::bind(fd, reinterpret_cast<struct sockaddr *>(&sa), sizeof(sa)) != 0) {
        qCWarning(lcBle) << "loadConnParams: bind failed:" << strerror(errno);
    } else if (::send(fd, pkt, sizeof(pkt), 0) != static_cast<ssize_t>(sizeof(pkt))) {
        qCWarning(lcBle) << "loadConnParams: send failed:" << strerror(errno);
    } else {
        qCInfo(lcBle) << "loaded conn params (15-30ms/0/" << (supervisionUnits / 100) << "s) for" << address;
    }
    ::close(fd);
}

void BleScanner::subscribeNextTempChar()
{
    // Subscribe to the SIG standard Health Thermometer char (00002a1c).
    // First issue a `read` — this matches the successful Python `bleak`
    // sequence: always-on firmware returns the last cached measurement
    // immediately on read, then start_notify catches subsequent updates.
    if (!m_inGattMenu) {
        writeLine("menu gatt");
        m_inGattMenu = true;
    }
    // bluetoothctl `read` returns the device's cached 2A1C measurement first.
    // For the monitor screen that stale value must not become the first visible
    // reading; drop the first parsed sample and let the following notify drive UI.
    const bool vendor1524 = isVendor1524Device();
    m_dropNextTemperatureSample = isAlwaysOnFirmware();
    m_placeholderReadRetries = 0;   // fresh in-connection re-read budget per subscribe
    if (vendor1524) {
        m_vendor1524TemperaturePending = false;
    }
    const QString device = !m_connectedAddress.isEmpty() ? m_connectedAddress : m_targetAddress;
    if (!device.isEmpty()) {
        const QString devPath = bluezDevicePath(device);
        if (vendor1524) {
            // bluetoothctl chokes on four back-to-back commands (proven by
            // log: 1524 select succeeded but its `notify on` never produced
            // a Notifying: yes — only 2A1C ended up subscribed). Stage it:
            //   t=0   : subscribe 2A1C (the must-have temperature char)
            //   t+500 : subscribe 1524 (the state-machine: 0x54/0xff/0xec)
            // nRF Connect confirms 1524 really does push 0x54/0xec from the
            // device, so the gap is purely in our subscribe sequencing.
            writeLine(QString("select-attribute %1/service000e/char000f").arg(devPath).toUtf8());
            writeLine("notify on");
            const QByteArray sel1524 =
                QString("select-attribute %1").arg(QString::fromLatin1(kVendorTempChar)).toUtf8();
            QTimer::singleShot(500, this, [this, sel1524]() {
                if (m_connState != "streaming" && m_connState != "connected") return;
                if (!m_inGattMenu) {
                    writeLine("menu gatt");
                    m_inGattMenu = true;
                }
                writeLine(sel1524);
                writeLine("notify on");
            });
            setStatus("Subscribed to 2A1C; 1524 follows in 500ms…");
            return;
        }

        // Standard mode → select 0x2A1C by UUID (handle-layout independent so
        // it covers any Bluetooth-4.0 Health Thermometer); otherwise
        // the two legacy hard-coded handle paths. See tempCharSelectors().
        const QStringList candidatePaths = tempCharSelectors();
        // The `read` is REQUIRED for the legacy hard-coded-handle path —
        // empirically the legacy-layout meters only push a 2A1C Indication on the
        // *first* fresh connection after a measurement; on every later reconnect
        // they serve the value via Read Response only. BUT standard HTS meters
        // expose 2A1C as indicate-only → `read` returns
        // org.bluez.Error.NotPermitted, which is not just useless: the extra ATT
        // round-trip delays our `notify on` (CCCD enable), letting the device's
        // single indicate slip in before the CCCD is armed → dropped. So in
        // standard mode subscribe with notify on ONLY, no read.
        // Keep the `read` for numeric-comparison meters (m_numericMode): this
        // firmware pushes its single 2A1C indication very early (before/around
        // connect) and bluez caches it as the characteristic Value — the `read`
        // is what actually retrieves the temperature here. Only long-hold HTS-class
        // always-on standard HTS (m_standardMode) is indicate-only where `read`
        // returns NotPermitted and merely delays the CCCD arm, so ONLY standard
        // mode skips it. (This is the opposite of the long-hold HTS "去 read" rule.)
        // Apollo510b joins standard mode in skipping the read, for a stronger
        // reason: its 0x2A1C is ATT_PROP_INDICATE with NO read property, and the
        // Cordio firmware produces nothing at all until the CCCD is armed (first
        // sample after subscribe, then 1 Hz). There is no cached value to fetch,
        // so a read can only fail with NotPermitted and push back the `notify on`
        // that is what actually starts the data. See isApollo510Device().
        const bool doRead = !m_standardMode && !isApollo510Device();
        for (const QString &path : candidatePaths) {
            writeLine(QString("select-attribute %1").arg(path).toUtf8());
            if (doRead) writeLine("read");
            writeLine("notify on");
        }
        setStatus(doRead ? "Subscribed + reading…" : "Subscribed (indicate)…");
        return;
    }

    for (int i = 0; i < kCharUuidCount; ++i) {
        writeLine(QString("select-attribute %1").arg(kCharUuids[i]).toUtf8());
        writeLine("read");
        writeLine("notify on");
    }
    if (vendor1524) {
        writeLine(QString("select-attribute %1").arg(QString::fromLatin1(kVendorTempChar)).toUtf8());
        writeLine("notify on");
    }
    setStatus("Subscribed + reading…");
}

void BleScanner::onSubscribeTimeout()
{
    if (m_subscribedOnce) return;
    // Standard mode connect-watchdog: if we are STILL only "connecting" (no
    // Connected: yes yet) when this fires, the blind connect is stuck — the
    // device is asleep / not in a connectable window. bluez would otherwise sit
    // on it for ~40 s with the CC3351 single radio parked in LE-Initiating (NOT
    // scanning), so the device's next measurement advertisement is missed and
    // that reading is lost. Abandon the stuck connect and resume scanning so the
    // adv-driven path can catch the measurement burst the instant it appears.
    if (fastSubscribe() && m_connState == "connecting") {
        qCInfo(lcBle) << "standard: connect watchdog — cancelling stuck connect, back to scan";
        if (m_inGattMenu) { writeLine("back"); m_inGattMenu = false; }
        // `scan on` alone does NOT reliably abort a pending LE create
        // connection on this stack (observed: InProgress persisted across the
        // watchdog and `hcitool con` still showed the half-open handle).
        // bluez's Device1.Disconnect DOES cancel a pending connect — issue it
        // first, then resume scanning.
        if (!m_targetAddress.isEmpty())
            writeLine(QString("disconnect %1").arg(m_targetAddress).toUtf8());
        writeLine("scan on");
        m_scanning = true;
        emit scanningChanged();
        setConnState("idle");
        return;
    }
    if (m_connState == "connecting" || m_connState == "connected") {
        qCInfo(lcBle) << "subscribe timer: forcing subscribe attempt";
        m_subscribedOnce = true;
        subscribeNextTempChar();
    }
}

void BleScanner::onProcessFinished(int code, QProcess::ExitStatus)
{
    qCInfo(lcBle) << "bluetoothctl exited code=" << code;
    m_scanning = false;
    emit scanningChanged();
    setStatus(QString("bluetoothctl exited (%1 device%2)").arg(m_order.size()).arg(m_order.size() == 1 ? "" : "s"));
    setConnState("idle");
    setConnectedAddress("");
    setConnectedName("");
    m_inGattMenu = false;
    m_pendingValueLine = false;
    m_charAttempt = 0;
    m_subscribedOnce = false;
    m_vendor1524TemperaturePending = false;
    m_subscribeTimer->stop();
    if (m_proc) {
        m_proc->deleteLater();
        m_proc = nullptr;
    }
    m_buf.clear();
}

void BleScanner::onStdout()
{
    if (!m_proc) return;
    QByteArray chunk = m_proc->readAllStandardOutput();
    // bluetoothctl is an interactive shell and redraws prompts with CR. Treat
    // CR as a real line break so Value/hex rows do not arrive as journald blobs.
    chunk.replace('\r', '\n');
    m_buf.append(chunk);

    static const QRegularExpression ansi("\\x1b\\[[0-9;?]*[A-Za-z]");
    // Bluetoothctl prompt forms: "[bluetooth]#", "[XX-XX-XX-XX-XX-XX]#",
    // "[XX-XX-XX-XX-XX-XX:/service000a/char000b]#", "[<name>]>". The closing
    // bracket is ALWAYS immediately followed by '#' or '>'. Event tags like
    // "[NEW]" / "[CHG]" / "[DEL]" are followed by a space (they are content,
    // not a prompt), so they must NOT be stripped.
    static const QRegularExpression prompt("^\\[[^\\]]*\\][#>]\\s*");

    int nl;
    while ((nl = m_buf.indexOf('\n')) >= 0) {
        QString line = QString::fromUtf8(m_buf.left(nl));
        m_buf.remove(0, nl + 1);
        line.remove(ansi);
        // The prompt may appear multiple times on the same line because
        // bluetoothctl re-prints it after every async event. Strip leading
        // prompts repeatedly until no more remain.
        while (prompt.match(line).hasMatch()) {
            line.remove(prompt);
        }
        line.remove(QRegularExpression("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]"));
        line = line.trimmed();
        if (line.isEmpty()) continue;
        qCInfo(lcBle).noquote() << "←" << line;
        handleLine(line);
    }

    // bluetoothctl's interactive agent prompts ("Confirm passkey N (yes/no):"
    // and similar) are written WITHOUT a trailing newline — they sit there
    // waiting for input. Without special handling we'd buffer the prompt
    // until the next bluez event arrived (typically 20+ s on this stack),
    // making the EVM dialog lag the meter's passkey display by a long time.
    // Detect the prompt mid-buffer and process it immediately.
    static const QByteArray kPromptTail("(yes/no):");
    int promptIdx = m_buf.indexOf(kPromptTail);
    if (promptIdx >= 0) {
        int end = promptIdx + kPromptTail.size();
        QString line = QString::fromUtf8(m_buf.left(end));
        m_buf.remove(0, end);
        line.remove(ansi);
        while (prompt.match(line).hasMatch()) {
            line.remove(prompt);
        }
        line.remove(QRegularExpression("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]"));
        line = line.trimmed();
        if (!line.isEmpty()) {
            qCInfo(lcBle).noquote() << "← (prompt)" << line;
            handleLine(line);
        }
    }
}

void BleScanner::handleLine(const QString &line)
{
    // Scan-health: any [NEW]/[CHG]/[DEL] Device line means the scan is alive and
    // surfacing advertisements. Stamp it so onScanHealthCheck() can distinguish
    // a healthy scan from a stalled one.
    if (line.contains(QStringLiteral("] Device "))) {
        m_lastAdvMs = QDateTime::currentMSecsSinceEpoch();
    }

    // Capture the connected device's 0x2A1C object path during GATT discovery.
    // bluetoothctl prints a characteristic's object path on one line and its
    // UUID on the next; remember the last char path, and when the following
    // line is the 0x2A1C UUID, latch it. tempCharSelectors() then selects this
    // full path for BLE SCAN so the read can't mis-resolve to a stale same-alias
    // cached device (old MAC). Scan3 does not use m_tempCharPath — untouched.
    {
        static const QRegularExpression reCharObjPath(
            "^(/org/bluez/\\S*/dev_[0-9A-F_]+/service[0-9a-f]+/char[0-9a-f]+)$",
            QRegularExpression::CaseInsensitiveOption);
        const QRegularExpressionMatch mCharPath = reCharObjPath.match(line);
        if (mCharPath.hasMatch()) {
            m_lastCharObjPath = mCharPath.captured(1);
        } else if (!m_lastCharObjPath.isEmpty() &&
                   line.compare(QLatin1String(kStandardTempChar),
                                Qt::CaseInsensitive) == 0) {
            m_tempCharPath = m_lastCharObjPath;
        }
    }

    static const QRegularExpression reNew(
        "\\[NEW\\]\\s+Device\\s+([0-9A-F:]{17})\\s+(.+)");
    static const QRegularExpression reChgName(
        "\\[CHG\\]\\s+Device\\s+([0-9A-F:]{17})\\s+Name:\\s+(.+)");
    static const QRegularExpression reDel(
        "\\[DEL\\]\\s+Device\\s+([0-9A-F:]{17})");
    // Response rows of `devices`: "Device AA:BB:CC:DD:EE:FF NAME". Used to seed
    // the list with peers bluez already knows about — those never get a [NEW].
    static const QRegularExpression reDeviceRow(
        "^Device\\s+([0-9A-F:]{17})\\s+(.+)$");

    // Pairing flow lines (numeric-comparison agent prompts).
    //   "[agent] Confirm passkey 123456 (yes/no):"  → ask user
    //   "[CHG] Device XX Paired: yes"                → succeeded
    //   "Pairing successful"                         → succeeded (no MAC)
    //   "Failed to pair: <reason>"                   → failed
    static const QRegularExpression rePairPasskey(
        "Confirm\\s+passkey\\s+(\\d{1,6})",
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression rePairedYes(
        "\\[CHG\\]\\s+Device\\s+([0-9A-F:]{17})\\s+Paired:\\s+yes",
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression rePairFailed(
        "Failed\\s+to\\s+pair[^A-Za-z0-9]*(.*)",
        QRegularExpression::CaseInsensitiveOption);

    static const QRegularExpression reConnected(
        "\\[CHG\\]\\s+Device\\s+([0-9A-F:]{17})\\s+Connected:\\s+(yes|no)",
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression reServicesResolved(
        "\\[CHG\\]\\s+Device\\s+([0-9A-F:]{17})\\s+ServicesResolved:\\s+yes",
        QRegularExpression::CaseInsensitiveOption);
    // Any `[CHG] Device <mac> …` line is evidence the peer is advertising
    // (bluez emits these on RSSI / ManufacturerData / UUIDs / Name updates).
    static const QRegularExpression reAnyChg(
        "\\[CHG\\]\\s+Device\\s+([0-9A-F:]{17})\\b");

    static const QRegularExpression reAttrValueHeader(
        "Attribute\\s+\\S+\\s+Value:\\s*(.*)$",
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression reHexBytes(
        "\\b([0-9a-fA-F]{2}(?:\\s+[0-9a-fA-F]{2})*)\\b");
    static const QRegularExpression reFailedToConnect(
        "(Failed\\s+to\\s+connect|Connection\\s+refused|le-connection-abort)",
        QRegularExpression::CaseInsensitiveOption);

    auto parseHexDump = [&](const QString &text) -> bool {
        auto m = reHexBytes.match(text);
        if (!m.hasMatch()) return false;

        const QStringList tokens = m.captured(1).split(QRegularExpression("\\s+"),
                                                       Qt::SkipEmptyParts);
        QByteArray bytes;
        bytes.reserve(tokens.size());
        for (const auto &t : tokens) {
            bool ok = false;
            int v = t.toInt(&ok, 16);
            if (!ok) { bytes.clear(); break; }
            bytes.append(static_cast<char>(v & 0xff));
        }
        if (bytes.isEmpty()) return false;

        qCInfo(lcBle).noquote() << "  bytes:" << bytes.toHex(' ');
        parseTemperatureBytes(bytes);
        return true;
    };

    // 1) Hex byte dump (expected after a "Value:" header line)
    if (m_pendingValueLine) {
        m_pendingValueLine = false;
        if (parseHexDump(line)) return;
    }

    {
        auto m = reAttrValueHeader.match(line);
        if (m.hasMatch()) {
            const QString inlineBytes = m.captured(1).trimmed();
            if (!inlineBytes.isEmpty() && parseHexDump(inlineBytes)) return;
            m_pendingValueLine = true;
            return;
        }
    }

    // DO NOT fall back to a generic "contains Value:" sniff. bluez also
    // emits "ManufacturerData.Value:" and "ServiceData.<UUID>:" for any
    // nearby advertising peer — if we accepted any of those as a hex
    // dump source we'd parse another vendor's beacon payload (e.g. Apple
    // 0x004C iBeacon bytes `10 06 71 1e …`) as our thermometer's HTS
    // frame and commit a fake 15.52°C from a passing iPhone. Only trust
    // the strict `Attribute /org/bluez/.../charXXXX Value:` form, which
    // is already matched by reAttrValueHeader above.

    // 2) Discovery
    {
        auto m = reNew.match(line);
        if (m.hasMatch()) { upsertDevice(m.captured(1), m.captured(2).trimmed()); /* fall through to advertisement-check */ }
        else if ((m = reChgName.match(line)).hasMatch()) {
            upsertDevice(m.captured(1), m.captured(2).trimmed());
        }
        else if ((m = reDel.match(line)).hasMatch()) {
            const QString addr = m.captured(1);
            if (m_byAddr.remove(addr) > 0) {
                m_order.removeAll(addr);
                emit devicesChanged();
            }
            return;
        }
        else if ((m = reDeviceRow.match(line)).hasMatch()) {
            upsertDevice(m.captured(1), m.captured(2).trimmed());
        }
    }

    // 2b) Advertisement-driven reconnect: a [NEW]/[CHG]/Device row for the
    //     target MAC while we are idle in auto-reconnect mode kicks a connect.
    //     A cooldown window suppresses ghost advertisements that arrive
    //     immediately after disconnect (not a real new measurement).
    if (m_autoReconnect && !m_targetAddress.isEmpty() && m_connState == "idle") {
        auto matchTarget = [&](const QRegularExpression &re) {
            auto mm = re.match(line);
            return mm.hasMatch() && mm.captured(1).compare(m_targetAddress, Qt::CaseInsensitive) == 0;
        };
        if (matchTarget(reNew) || matchTarget(reAnyChg) || matchTarget(reDeviceRow)) {
            // Don't gate the adv itself (would let bluez dedup kill the
            // [CHG] feed); instead push the reconnect QTimer past the
            // bluez kernel-handle drain window so that issuing `connect`
            // doesn't hit `status 0x09 Already Connected`.
            if (!m_reconnectTimer->isActive()) {
                const qint64 now = QDateTime::currentMSecsSinceEpoch();
                int delay = 50;
                if (now < m_cooldownUntilMs) {
                    delay = static_cast<int>(m_cooldownUntilMs - now) + 50;
                    qCInfo(lcBle) << "target advertising — deferring reconnect"
                                  << delay << "ms (kernel handle drain)";
                } else {
                    qCInfo(lcBle) << "target advertising — scheduling reconnect";
                }
                m_reconnectTimer->start(delay);
            }
        }
    }

    // 2b2) BLE Scan2 — auto-connect on ManufacturerData company ID match.
    // bluez emits two lines per advertisement when manufacturer data is
    // present:
    //   [CHG] Device <MAC> ManufacturerData.Key: 0x043e (1086)
    //   [CHG] Device <MAC> ManufacturerData.Value:
    //           c0 26 db 00 00 c9
    // We only need the Key line to decide whether to auto-connect — the
    // Value is the device's serial / payload, irrelevant for our linkup.
    if (m_autoConnectCompanyId != 0) {
        static const QRegularExpression reMfgKey(
            "\\[CHG\\]\\s+Device\\s+([0-9A-F:]{17})\\s+ManufacturerData\\.Key:\\s+0x([0-9a-fA-F]{1,4})",
            QRegularExpression::CaseInsensitiveOption);
        auto mm = reMfgKey.match(line);
        if (mm.hasMatch()) {
            const QString addr = mm.captured(1).toUpper();
            const int cid = mm.captured(2).toInt(nullptr, 16);
            if (cid == m_autoConnectCompanyId) {
                emit autoConnectMatch(addr);
                const qint64 now = QDateTime::currentMSecsSinceEpoch();
                // Throttle: avoid hammering connect on every advertisement
                // burst; also respect the global cooldown after disconnect.
                const bool inCooldown = now < m_cooldownUntilMs;
                const bool tooSoon = (now - m_lastAutoConnectMs) < 2000;
                const bool busy =
                    m_connState == "connecting" ||
                    m_connState == "connected"  ||
                    m_connState == "streaming";
                // If the user just cancelled out of numeric-comparison
                // pairing for this address, the device will keep adverting
                // (it has no way to know the user said no) and this
                // company-ID auto-connect path would silently re-issue
                // `connect`, the LL link establishes, `connected()` fires,
                // Main.qml jumps to the temperature curve — and the user's
                // Cancel is undone. Skip until the user explicitly retries.
                const bool cancelled = m_cancelledPairings.contains(addr);
                if (!inCooldown && !tooSoon && !busy && !cancelled) {
                    qCInfo(lcBle) << "auto-connect: company ID match"
                                  << QString::asprintf("0x%04x", cid)
                                  << "for" << addr;
                    m_lastAutoConnectMs = now;
                    // connectDevice() latches m_targetAddress + autoReconnect,
                    // so subsequent disconnects (e.g. supervision timeout
                    // after each measurement burst) are picked up by the
                    // advertisement-driven reconnect loop above.
                    connectDevice(addr);
                } else if (cancelled) {
                    qCInfo(lcBle) << "auto-connect: skipping" << addr
                                  << "— user cancelled pairing earlier";
                }
            }
        }
    }

    // 2c) Pairing flow (numeric comparison)
    {
        auto m = rePairPasskey.match(line);
        if (m.hasMatch()) {
            // If there is no active pairDevice() session (user already hit
            // Cancel, or the peripheral re-initiated pair on its own), or
            // the address was explicitly cancelled, auto-decline this prompt
            // and DON'T emit pairingPasskey — otherwise the dialog reopens
            // with a freshly-randomised 6-digit code, forever.
            const QString addrU = m_pairingAddress.toUpper();
            if (m_pairingAddress.isEmpty() ||
                m_cancelledPairings.contains(addrU)) {
                qCInfo(lcBle) << "  passkey prompt for"
                              << (m_pairingAddress.isEmpty() ? QStringLiteral("<no active pair>") : m_pairingAddress)
                              << "— auto-declining"
                              << (m_cancelledPairings.contains(addrU) ? "(cancelled by user)" : "(no session)");
                writeLine("no");
                if (!addrU.isEmpty()) {
                    writeLine(QString("cancel-pairing %1").arg(m_pairingAddress).toUtf8());
                }
                return;
            }
            // bluetoothctl re-draws the same "Confirm passkey N (yes/no):"
            // prompt ~25-30× as async events (RSSI/[CHG]) arrive while the user
            // decides. Surface the dialog only ONCE per code — re-emitting fires
            // pairingConfirmDialog.open() repeatedly under the user's finger.
            const QString newPasskey = m.captured(1);
            if (newPasskey == m_pairingPasskey) return;
            m_pairingPasskey = newPasskey;
            // bluetoothctl prints "Confirm passkey 1234 (yes/no):" — the digit
            // run can be shorter than 6, so left-pad for display.
            QString padded = m_pairingPasskey;
            while (padded.length() < 6) padded.prepend('0');
            qCInfo(lcBle) << "  pairing passkey:" << padded;
            emit pairingPasskey(m_pairingAddress, padded);
            return;
        }
    }
    {
        auto m = rePairedYes.match(line);
        if (m.hasMatch()) {
            const QString addr = m.captured(1);
            qCInfo(lcBle) << "  pairing succeeded:" << addr;
            const QString pairing = m_pairingAddress;
            m_pairingAddress.clear();
            m_pairingPasskey.clear();
            // Lift the just-paired address into the connected slot so the UI
            // (VitalSignsMonitorDialog) stops saying "未連線" — the peer is
            // already linked & resolving services at this point. Resolve the
            // friendly name from our scan cache; fall back to the MAC.
            setConnectedAddress(addr);
            const QString cachedName = m_byAddr.value(addr);
            setConnectedName(cachedName.isEmpty() ? addr : cachedName);
            // Latch the auto-reconnect target the same way connectDevice()
            // does. Power-cycle firmware drops the link with
            // Reason.Timeout (LL supervision) ~12 s after each measurement
            // burst — without this latch the page stays disconnected forever.
            // With it the advertisement-driven reconnect loop pulls the link
            // back as soon as the meter beacons for the next measurement.
            m_targetAddress = addr;
            setAutoReconnect(true);
            m_periodicConnectTimer->start();
            // Auto-trust right after a successful pair so future
            // peripheral-initiated reconnects don't re-prompt the agent. Must
            // be queued for the main menu — we may still be in `gatt` from
            // the subscribe path that ServicesResolved kicked off, and bluez
            // replies "Invalid command in menu gatt: trust" otherwise.
            QTimer::singleShot(1500, this, [this, addr]() {
                if (m_inGattMenu) {
                    qCInfo(lcBle) << "  trust deferred — still in gatt menu";
                    return;
                }
                writeLine(QString("trust %1").arg(addr).toUtf8());
            });
            setStatus(QString("Paired (%1)").arg(cachedName.isEmpty() ? addr : cachedName));
            emit pairingSucceeded(pairing.isEmpty() ? addr : pairing);
            // If ServicesResolved already fired during the (slow-confirm)
            // handshake we skipped the subscribe to protect SMP; bluez won't
            // emit ServicesResolved again, so issue the deferred subscribe now
            // that stdin no longer feeds the agent. Fire AFTER the 1500 ms
            // deferred-trust above so trust runs in the main menu first
            // (subscribe enters `menu gatt`). The `read` in subscribeNextTempChar
            // still fetches the meter's cached 2A1C value, so a fast-confirm path
            // (ServicesResolved arrives after Paired, m_pairingAddress already
            // empty → normal subscribe below) is unaffected and never sets this.
            if (m_subscribeAfterPairing) {
                m_subscribeAfterPairing = false;
                QTimer::singleShot(1800, this, [this]() {
                    if (!m_pairingAddress.isEmpty()) return;
                    if (m_connState != "connected" && m_connState != "streaming") return;
                    qCInfo(lcBle) << "  issuing deferred post-pair subscribe";
                    m_subscribedOnce = true;
                    m_subscribeTimer->stop();
                    subscribeNextTempChar();
                    // Fresh pairing: the cached 2A1C value bluez serves is the
                    // measurement the user JUST took — an always-on meter latches
                    // one reading (e.g. 36.5 C) and re-sends it unchanged, so bluez
                    // emits no further [CHG] and there is no "next" sample to show.
                    // subscribeNextTempChar() armed m_dropNextTemperatureSample for
                    // always-on firmware; leaving it set discards that just-measured
                    // value permanently (confirmed on hardware 2026-07-02:
                    // 36.5 C dropped 3× then the link died, temperature never shown).
                    // Clear it for the FRESH-PAIRING path only — reconnect paths keep
                    // the drop so a stale previous-session value stays hidden. No-op
                    // for power-cycle / numeric-comparison meters (isAlwaysOnFirmware
                    // == false there, so the drop was never armed — Scan3 untouched).
                    if (isAlwaysOnFirmware())
                        m_dropNextTemperatureSample = false;
                });
            }
            // Don't return — let the regular Connected/ServicesResolved path
            // continue for whichever device handler needs it.
        }
    }
    {
        auto m = rePairFailed.match(line);
        if (m.hasMatch()) {
            const QString reason = m.captured(1).trimmed();
            const QString addr = m_pairingAddress;
            m_pairingAddress.clear();
            m_pairingPasskey.clear();
            m_subscribeAfterPairing = false;
            // AlreadyExists isn't a real failure — bluez refuses to re-pair an
            // already-paired peer. Treat it as success so the UI doesn't
            // confuse the user with a red banner after they've successfully
            // paired (they often tap again because they didn't notice the
            // first success).
            if (reason.contains("AlreadyExists", Qt::CaseInsensitive)) {
                qCInfo(lcBle) << "  pair returned AlreadyExists — treating as paired";
                setStatus(QString("Paired (%1)").arg(addr));
                emit pairingSucceeded(addr);
                return;
            }
            qCInfo(lcBle) << "  pairing failed:" << reason;
            setStatus(QString("Pairing failed: %1").arg(reason));
            emit pairingFailed(addr, reason);
            return;
        }
    }

    // 3) Connection lifecycle. Use startsWith — `contains("Connection
    // successful")` also matches `Disconnection successful` (substring trap),
    // which incorrectly flips the state back to "connected" right after we
    // intentionally drop a ghost link, breaking the next reconnect.
    const bool connectionAck =
           line.startsWith("Connection successful", Qt::CaseInsensitive)
        || line.startsWith("Successfully connected", Qt::CaseInsensitive)
        || line.startsWith("Pairing successful",     Qt::CaseInsensitive);
    if (connectionAck) {
        setConnState("connected");
        emit connected();
        setStatus(QString("Connected (%1)").arg(m_connectedName.isEmpty() ? m_connectedAddress : m_connectedName));
        return;
    }
    if (reFailedToConnect.match(line).hasMatch()) {
        // Pairing handshake in flight: a connection-failure / le-connection-abort
        // line here is SMP/LE churn on the single-radio CC3351, not a dead
        // target. Do NOT flip connState or toggle scan mid-bond — that smashes
        // the handshake (same root cause guarded in onReconnectTimer /
        // onPeriodicConnectTimer). Let rePairedYes / rePairFailed own the bond
        // outcome. (Not seen in the 2026-06-26 repro, where the failure was the
        // ServicesResolved subscribe injection above; this closes the same class
        // of latent injection path defensively.)
        if (!m_pairingAddress.isEmpty()) return;
        // "InProgress" is NOT a dead link — it means a connect is ALREADY
        // pending in the kernel (LE create connection parked in initiating
        // state until the peer advertises; it completes the instant the peer
        // wakes). Flipping to "idle" here un-gated the periodic blind-connect,
        // which then hammered a new attempt every 2.5 s: each returned
        // InProgress again, the pile-up wedged discovery ("scan 失效"), and a
        // queued attempt's abort could tear down the very link the pending
        // attempt had just established (observed: Connected:yes followed by
        // abort-by-local and reason-0 death within 157 ms). Reflect reality
        // instead: stay "connecting" so the periodic gate holds, and keep the
        // standard-mode watchdog armed to cancel the attempt if it stays stuck.
        if (line.contains(QStringLiteral("InProgress"), Qt::CaseInsensitive)) {
            setConnState("connecting");
            setStatus(QString("Connect pending %1…").arg(m_targetAddress));
            if (!m_subscribeTimer->isActive())
                m_subscribeTimer->start(fastSubscribe() ? 7000 : 15000);
            return;
        }
        setConnState(m_autoReconnect ? "idle" : "error");
        setStatus(m_autoReconnect ? "Waiting for next measurement…"
                                  : QString("Connect failed: %1").arg(line));
        emit connectionFailed(line);
        // Do not blind-retry. We will reconnect on the next advertisement of
        // m_targetAddress — see the [CHG] Device handler below.
        if (m_autoReconnect && !m_scanning) {
            if (m_inGattMenu) { writeLine("back"); m_inGattMenu = false; }
            writeLine("scan on");
            m_scanning = true;
            emit scanningChanged();
        }
        return;
    }
    {
        auto m = reConnected.match(line);
        if (m.hasMatch()) {
            const bool yes = m.captured(2).compare("yes", Qt::CaseInsensitive) == 0;
            if (yes && m_connState == "connecting") {
                setConnState("connected");
                emit connected();
                setStatus(QString("Connected (%1)").arg(m_connectedName.isEmpty() ? m_connectedAddress : m_connectedName));
            }
            // Also covers Scan3 numeric-comparison (m_numericMode) reconnects via
            // fastSubscribe(). Gate on no in-flight pairing so the initial bonding
            // handshake still subscribes via the ServicesResolved path (keeps the
            // deferred trust from being skipped by an early `menu gatt`).
            if (yes && fastSubscribe() && m_pairingAddress.isEmpty()) {
                // Subscribe the INSTANT we're connected, without waiting for
                // ServicesResolved (~1 s later). On a cached reconnect bluez
                // already holds this device's GATT objects, so select + notify on
                // succeed immediately — and because the meter emits its single
                // Temperature indication AFTER it sees the CCCD enable, arming
                // notify this early wins the race that otherwise loses the reading.
                //
                // This runs on EVERY Connected:yes (not gated on connState ==
                // "connecting"): when the user measures while we hold a link, the
                // meter power-cycles and an adv-driven reconnect fires — but two
                // reconnect attempts can race connState out of "connecting" before
                // this line, so gating on it dropped the early-subscribe and the
                // reading was missed (observed: the 36.3 °C measure-while-connected
                // case). Idempotent: a duplicate notify on is harmless, and the
                // ServicesResolved path below still re-subscribes as a backup.
                m_subscribeTimer->stop();
                subscribeNextTempChar();
            }
            if (!yes && m_connState != "idle") {
                m_subscribedOnce = false;
                m_charAttempt   = 0;
                m_streamingTimer->stop();
                // bluez kernel-handle drain window (~300 ms). bluez emits
                // LE.Disconnected before its internal Device1 object has
                // fully released the handle; issuing `connect` inside this
                // window returns `status 0x09, Already Connected` and
                // costs ~2 s of retry loops before the kernel catches up.
                //
                // NOTE: this cooldown does NOT gate advertisements — the
                // adv-driven path still records every [CHG] Device for the
                // target (so bluez's LE duplicate-filter doesn't dedup the
                // next real burst). What it gates is *issuing the connect
                // command*: the reconnect QTimer is scheduled to fire at
                // (cooldown + 50 ms) when an adv arrives mid-window.
                m_cooldownUntilMs = QDateTime::currentMSecsSinceEpoch() + 300;
                if (m_autoReconnect && !m_targetAddress.isEmpty()) {
                    // Disconnect → scan → (advertisement) → connect. The meter
                    // can't be reconnected the instant it drops the link (it has
                    // to re-enter its advertising window first); an immediate
                    // active connect just pins the radio on a stuck attempt
                    // (InProgress / abort loop, observed ~2 min stall). So go back
                    // to scanning and let the advertisement drive the reconnect.
                    setConnState("idle");
                    setStatus("Waiting for next advertisement…");
                    // Adv-driven reconnect is the primary path now. Toggle
                    // scan off→on so bluez resets its LE duplicate-filter
                    // table — without this reset the FIRST adv after the
                    // device wakes is silently dedup'd against a stale
                    // entry and we never see [CHG] Device for the target.
                    if (m_inGattMenu) { writeLine("back"); m_inGattMenu = false; }
                    if (m_scanning) {
                        writeLine("scan off");
                        m_scanning = false;
                        emit scanningChanged();
                    }
                    writeLine("scan on");
                    m_scanning = true;
                    emit scanningChanged();
                    // Periodic blind-connect is only a deep-sleep safety net
                    // now (10 s interval set in the constructor). Re-arm so
                    // its first fire is one full interval from now.
                    m_periodicConnectTimer->start();
                } else {
                    setConnState("idle");
                    setStatus("Peer disconnected");
                    emit connectionFailed("Peer disconnected");
                }
            }
            return;
        }
    }
    if (reServicesResolved.match(line).hasMatch()) {
        // Pairing handshake still in flight: bluez's agent is blocked on
        // "Confirm passkey (yes/no):" reading the SAME bluetoothctl stdin. The
        // subscribe below writes `menu gatt`/select/read/notify there, which
        // bluez consumes as the agent reply (non-"yes") and aborts SMP with
        // AuthenticationFailed — the "dialog shows, ~2 s later pairing fails"
        // bug (numeric comparison resolves GATT ~2.5 s into the link, before a
        // slow human confirm). Mirror the Connected:yes early-subscribe gate
        // above (m_pairingAddress.isEmpty()). bluez does NOT re-emit
        // ServicesResolved after a pre-bond resolve, so latch the owed subscribe
        // for rePairedYes to issue once the bond completes.
        if (!m_pairingAddress.isEmpty()) {
            m_subscribeAfterPairing = true;
            qCInfo(lcBle) << "  ServicesResolved during pairing — deferring subscribe until Paired";
            return;
        }
        // ServicesResolved: yes is the *only* reliable signal that bluez has
        // populated its attribute cache for this connection. We always
        // (re-)subscribe here, ignoring m_subscribedOnce — a previous attempt
        // might have failed with "No attribute selected" while the cache was
        // still filling.
        m_subscribedOnce = true;
        m_subscribeTimer->stop();
        subscribeNextTempChar();
        return;
    }

    // 4) select-attribute / notify feedback
    if (line.contains("Attribute path not found", Qt::CaseInsensitive) ||
        line.contains("Missing characteristic", Qt::CaseInsensitive) ||
        line.contains("Attribute is not available", Qt::CaseInsensitive) ||
        line.contains("No attribute selected", Qt::CaseInsensitive)) {
        // The cache wasn't ready when we tried — just wait for ServicesResolved
        // to retry. Don't bump m_charAttempt; we'll retry both UUIDs together.
        m_subscribedOnce = false;
        return;
    }
    // The always-on meter's fresh-connect read can transiently fail with
    // org.bluez.Error.Failed while GATT/encryption is still settling right after
    // pairing. This firmware latches a single value and, if it doesn't change,
    // emits no notification [CHG] — so a failed read means the value is never
    // delivered this connection (observed on hardware 2026-07-02 15:18:28:
    // read failed, no notify value for 18 s, link died, temperature never shown).
    // Re-read the live handle on the SAME connection a few times; the held value
    // becomes readable once the link settles. Bounded by the per-subscribe retry
    // budget (reused from the placeholder path). Gated on isAlwaysOnFirmware() so
    // power-cycle / numeric-comparison meters (Scan3) are untouched — they have
    // their own zero-mantissa placeholder re-read below.
    if (line.contains("Failed to read", Qt::CaseInsensitive)) {
        // Dead-link recovery (always-on only). If the whole re-read budget burned
        // with still no value, the failure isn't transient GATT settling — the
        // encrypted session never came up on this link (observed 2026-07-02
        // 16:42:59: kernel "unexpected SMP command 0x0b" during pairing →
        // Bonded/Paired reported yes, but every read failed ×9 AND the CCCD
        // never armed — no "Notify started" for the entire connection, so no
        // value can EVER arrive here). Drop the dead link; pairDevice() already
        // latched this address as the auto-reconnect target, and a reconnect
        // re-establishes encryption from the stored bond (proven 16:45:19 →
        // AlreadyExists reconnect, temps flowed within seconds). One-shot: bump
        // the counter past the budget so straggling failure lines can't re-fire.
        // Gated on isAlwaysOnFirmware() — power-cycle / numeric-comparison
        // meters (Scan3) never enter this branch; their pairing/reconnect code
        // is untouched.
        if (isAlwaysOnFirmware() && m_lastTemperature <= 0 &&
            (m_connState == "streaming" || m_connState == "connected") &&
            !m_connectedAddress.isEmpty() &&
            m_placeholderReadRetries == kMaxPlaceholderReadRetries) {
            ++m_placeholderReadRetries;   // mark recovery issued — one-shot
            qCInfo(lcBle) << "  always-on read failed after full re-read budget —"
                          << "dropping dead link for bonded reconnect";
            setStatus("Link encryption dead — reconnecting…");
            if (m_inGattMenu) {
                writeLine("notify off");
                writeLine("back");
                m_inGattMenu = false;
            }
            writeLine(QString("disconnect %1").arg(m_connectedAddress).toUtf8());
            return;
        }
        if (isAlwaysOnFirmware() && m_lastTemperature <= 0 &&
            (m_connState == "streaming" || m_connState == "connected") &&
            !m_connectedAddress.isEmpty() &&
            m_placeholderReadRetries < kMaxPlaceholderReadRetries) {
            ++m_placeholderReadRetries;
            qCInfo(lcBle) << "  always-on read failed — in-connection re-read"
                          << m_placeholderReadRetries << "of"
                          << kMaxPlaceholderReadRetries;
            const QString dev = m_connectedAddress;
            QTimer::singleShot(kPlaceholderReadIntervalMs, this, [this, dev]() {
                if (m_connState != "streaming" && m_connState != "connected") return;
                if (dev.isEmpty() || dev != m_connectedAddress) return;
                if (m_lastTemperature > 0) return;   // a value already landed
                if (!m_inGattMenu) { writeLine("menu gatt"); m_inGattMenu = true; }
                for (const QString &sel : tempCharSelectors()) {
                    writeLine(QString("select-attribute %1").arg(sel).toUtf8());
                    writeLine("read");
                }
            });
        }
        return;
    }
    if (line.contains("Notify started", Qt::CaseInsensitive)) {
        setConnState("streaming");
        setStatus("Streaming temperature…");
        // Ghost-link watchdog. Power-cycle meters push
        // their indicate sub-second to ~2 s, but keep advertising the last
        // reading afterwards, so we reconnect, re-read the cached value
        // and would hold this link a full 12 s each cycle — which makes a
        // freshly-measured value wait up to a whole churn cycle (observed
        // ~9 s worst case with 6 s watchdog) to arrive. Drop a quiet link
        // after 6 s for power-cycle so the next (fresh) indicate is caught
        // sooner. Keep 12 s for the always-on meter
        // (its first real indicate can take 4–5 s) and the vendor-1524 one (its 0x54
        // measurement-start frame may lag subscribe before the 60 s countdown
        // resets this timer). Still well under the bluez link-supervision
        // timeout (15+ s).
        // Standard mode favours STAYING CONNECTED: the meter is a
        // power-cycle device that drops the link itself a few seconds after each
        // connection when it has nothing to send, so the EVM doesn't need to
        // force a quick ghost-drop to catch the next reading — the device's own
        // disconnect already does that. Actively dropping after 6 s only adds
        // extra link-down/up churn (the visible Bluetooth-LED flicker) and opens
        // disconnect gaps that a measurement can fall into. So hold the link far
        // Standard mode: the meter holds the connection ~1 minute after
        // connecting before it powers off. Match that with a 60 s hold so any
        // measurement taken within that window is delivered on the LIVE link
        // with no reconnect at all (and the LED stays solid instead of flickering
        // per reading). The meter's own power-off (Connected:no near the 1-min
        // mark) ends the link and drives the reconnect; this 60 s timer is just
        // the dead-link safety net. (An earlier 180 s value overshot the meter's
        // 1-min lifetime; 6 s undershot it and forced a reconnect per reading.)
        // Numeric-comparison meters (m_numericMode) join standard mode on the
        // long hold: their cached 2A1C value only becomes readable after
        // ServicesResolved (3-5 s here), so a 6 s ghost-drop races that read and
        // intermittently kills the link before the temperature lands (observed:
        // "後來才出現" — the reading only shows a cycle or two later). Holding the
        // link keeps notify-on armed too, so a live indication for a fresh
        // measurement is caught instead of dropped. The meter still power-cycles
        // itself (~12 s, Reason.Timeout) which drives the next reconnect, so this
        // 60 s timer is only a dead-link safety net.
        const int ghostMs = fastSubscribe() ? 60000
                          : (isVendor1524Device() || isAlwaysOnFirmware()) ? 12000 : 6000;
        m_streamingTimer->start(ghostMs);
        return;
    }
}

void BleScanner::parseTemperatureBytes(const QByteArray &data)
{
    const uint8_t *b = reinterpret_cast<const uint8_t *>(data.constData());
    const int n = data.size();
    const bool vendor1524 = isVendor1524Device();

    // ── Sanity gate. We subscribe two candidate 2A1C handles to cover both
    // known GATT layouts; on one of them the *other* handle is
    // actually the vendor 1524 notify, whose payloads we are NOT supposed
    // to interpret as Health Thermometer Measurement (HTS). Reject anything
    // that doesn't look like a real HTS frame so we don't commit garbage
    // values like `parsed temp: -1.17963e-97 C` or `parsed temp: 0 C`,
    // either of which crashes the dialog into "--.-" (it treats
    // lastTemperature ≤ 0 as awaitingMeasurement).
    //
    // Skip the gate for n==1 single-byte vendor frames — the vendor-1524 state
    // machine bytes 0x54/0xff/0xec are legitimate and parsed below.
    if (n > 13 && n != 1) {
        qCInfo(lcBle) << "  reject: payload" << n << "bytes — HTS max is 13";
        return;
    }
    if (n >= 5) {
        // HTS Flags: these meters use bits 0..3 (unit / timestamp / type /
        // status). Bit 4 (Measurement Status Annunciation) is rare and our
        // devices never set it; bits 5..7 are reserved-must-be-zero. Any
        // byte 0x10..0xFF here is vendor 1524 notify data leaking through —
        // notably `10 06 ...` which the lenient fallback path below would
        // misinterpret as 16-bit fixed-point 15.52°C, causing the UI to
        // flash a fake reading then snap to 0.0°C on the next reconnect.
        if ((b[0] & 0xF0) != 0) {
            qCInfo(lcBle) << "  reject: invalid HTS flags"
                          << QString::asprintf("0x%02x", b[0]);
            return;
        }
        // Mantissa = 0 is the meter's "no measurement / cached placeholder"
        // marker, not a real reading — these meters emit it between bursts
        // and just after subscribe. Don't commit 0°C / 0°F, the UI uses
        // value > 0 to decide whether to draw a real number.
        if (b[1] == 0 && b[2] == 0 && b[3] == 0) {
            // Common failure pattern on the power-cycle meters: user presses the
            // meter button → meter starts advertising while still computing →
            // EVM connects + subscribes within a few hundred ms, but the meter
            // only has the cached placeholder ready and the real measurement is
            // still a few seconds away.
            //
            // Fix A — re-read on the SAME connection instead of dropping it.
            // The fresh value lands on this link within a few seconds (via Read
            // Response, or an Indication if this is the first connection of the
            // cycle). Polling the live handle a few times here is far cheaper
            // than dropping the link and paying a full advertise→connect→resolve
            // reconnect (~3-4 s of churn). Only for power-cycle meters; the
            // vendor-1524 and always-on ones keep the original behaviour. Skip once we
            // already hold a real reading this connection (m_lastTemperature>0).
            // Apollo510b is excluded for the same reason as the read above: the
            // char is indicate-only, so re-reading returns NotPermitted, and its
            // 1 Hz stream delivers the real value on its own within a second.
            const bool powerCycle = !vendor1524 && !isAlwaysOnFirmware() && !isApollo510Device();
            if (powerCycle && m_lastTemperature <= 0 &&
                m_placeholderReadRetries < kMaxPlaceholderReadRetries) {
                ++m_placeholderReadRetries;
                qCInfo(lcBle) << "  placeholder zero mantissa — in-connection re-read"
                              << m_placeholderReadRetries << "of"
                              << kMaxPlaceholderReadRetries;
                // Keep the link alive across the re-read round-trip; the retry
                // counter (not this timer) bounds the total wait, and a silent
                // link still drops after the interval + margin.
                m_streamingTimer->start(kPlaceholderReadIntervalMs + 1700);
                const QString dev = m_connectedAddress;
                QTimer::singleShot(kPlaceholderReadIntervalMs, this, [this, dev]() {
                    if (m_connState != "streaming" && m_connState != "connected") return;
                    if (dev.isEmpty() || dev != m_connectedAddress) return;
                    if (m_lastTemperature > 0) return;   // a real value already arrived
                    if (!m_inGattMenu) { writeLine("menu gatt"); m_inGattMenu = true; }
                    // Re-read the candidate handle(s) (the absent one is a
                    // harmless "Attribute is not available"). Standard mode skips
                    // the read entirely — 2A1C is indicate-only there (read =
                    // NotPermitted), so just keep the link alive and wait for the
                    // next indicate. Do NOT re-arm notify or touch
                    // m_dropNextTemperatureSample.
                    if (m_standardMode) return;
                    for (const QString &sel : tempCharSelectors()) {
                        writeLine(QString("select-attribute %1").arg(sel).toUtf8());
                        writeLine("read");
                    }
                });
                return;
            }
            // Re-read budget exhausted (or not a power-cycle meter): fall back to
            // the original short window. onStreamingTimeout() drops the link and
            // the advertisement-driven reconnect loop catches the *next*
            // advertisement (after the meter has finished computing).
            qCInfo(lcBle) << "  reject: placeholder zero mantissa — arming 3s timeout";
            m_streamingTimer->start(3000);
            return;
        }
    }

    auto reArm2A1C = [this]() {
        // bluez/CC3351 quirk: subscribing 1524 (notify) + 2A1C (indicate) at
        // the same time causes the *other* char's CCCD to silently stall on
        // each transaction. After 0xff/0xec we must re-arm BOTH:
        //   2A1C off→on   — recovers the buffered abnormal/final indicate
        //   1524 off→on   — so the NEXT 0x54 lands on a fresh CCCD
        // Without the second re-arm the next measurement bypasses 0x54 and
        // the on-curve HUD stays in its standby state.
        if (m_connectedAddress.isEmpty()) return;
        const QString devPath = bluezDevicePath(m_connectedAddress);
        const QByteArray sel2A1C =
            QString("select-attribute %1/service000e/char000f").arg(devPath).toUtf8();
        const QByteArray sel1524 =
            QString("select-attribute %1").arg(QString::fromLatin1(kVendorTempChar)).toUtf8();
        auto stillLive = [this]() {
            return m_connState == "streaming" || m_connState == "connected";
        };
        QTimer::singleShot(120, this, [this, sel2A1C, stillLive]() {
            if (!stillLive()) return;
            if (!m_inGattMenu) { writeLine("menu gatt"); m_inGattMenu = true; }
            writeLine(sel2A1C);
        });
        QTimer::singleShot(280, this, [this, stillLive]() {
            if (!stillLive()) return;
            writeLine("notify off");
        });
        QTimer::singleShot(480, this, [this, stillLive]() {
            if (!stillLive()) return;
            writeLine("notify on");
        });
        QTimer::singleShot(720, this, [this, sel1524, stillLive]() {
            if (!stillLive()) return;
            writeLine(sel1524);
        });
        QTimer::singleShot(880, this, [this, stillLive]() {
            if (!stillLive()) return;
            writeLine("notify off");
        });
        QTimer::singleShot(1080, this, [this, stillLive]() {
            if (!stillLive()) return;
            writeLine("notify on");
        });
    };

    if (vendor1524) {
        if (n == 1) {
            if (b[0] == 0x54) {
                m_vendor1524TemperaturePending = false;
                m_dropNextTemperatureSample = false;
                setStatus("Measuring…");
                m_streamingTimer->start(60000);
                qCInfo(lcBle) << "  vendor-1524 measurement started: 0x54";
                emit vendor1524MeasurementStarted();
                return;
            }
            if (b[0] == 0xff) {
                m_vendor1524TemperaturePending = true;
                m_dropNextTemperatureSample = false;
                setStatus("Ready for temperature…");
                m_streamingTimer->start(12000);
                qCInfo(lcBle) << "  vendor-1524 measurement complete notification received: 0xff; re-arming 2A1C";
                emit vendor1524MeasurementComplete();
                reArm2A1C();
                return;
            }
            if (b[0] == 0xec) {
                m_vendor1524TemperaturePending = true;
                m_dropNextTemperatureSample = false;
                setStatus("Measurement error; waiting temperature…");
                m_streamingTimer->start(60000);
                qCInfo(lcBle) << "  vendor-1524 measurement error notification received: 0xec; re-arming 2A1C";
                emit vendor1524MeasurementAbnormal();
                reArm2A1C();
                return;
            }
        }
    }

    auto commitTemp = [&](double v, const char *unit) {
        // No 0xff/0xec gating: real-world units never send the 1524
        // state machine — both cached and freshly-measured samples land on
        // 2A1C directly. Gating dropped everything and starved the streaming
        // timer into a disconnect. Even an abnormal-range reading should
        // commit (user requirement: 0xEC scenarios still display the value).
        if (vendor1524) {
            m_vendor1524TemperaturePending = false;
        }
        if (m_dropNextTemperatureSample) {
            m_dropNextTemperatureSample = false;
            // Fix D: drop only IMPLAUSIBLE junk, commit a plausible live reading.
            // Rationale (2026-07-02 17:48:16): on reconnect the drop flag gets
            // re-armed by the double subscribe (early Connected:yes + the
            // ServicesResolved one), and the meter's initial value arrives once
            // per subscribe — both copies of a real 34.3 C measurement were
            // swallowed and the reading only surfaced 10 s later (at 17:47:08
            // the identical sequence let 34.5 C through by timing luck alone).
            // Every value this drop ever caught on reconnect today was a live
            // ambient reading (31–35 C); the only true junk is the power-on
            // default (1.7 C, RTC 2025-01-02) and the zero-mantissa placeholder,
            // which the placeholder gate rejects separately. So: commit anything
            // in human/ambient range, swallow the rest. isAlwaysOnFirmware() is
            // re-checked as belt-and-suspenders — the flag is only ever armed for
            // the always-on case (blescanner.cpp:524/753/874), so numeric-comparison /
            // power-cycle meters (Scan3) never reach this branch at all.
            const bool plausible = isAlwaysOnFirmware() &&
                ((qstrcmp(unit, "C") == 0 && v >= 20.0 && v <= 45.0) ||
                 (qstrcmp(unit, "F") == 0 && v >= 68.0 && v <= 113.0));
            if (!plausible) {
                qCInfo(lcBle) << "  ignored cached initial temp:" << v << unit;
                return;
            }
            qCInfo(lcBle) << "  initial sample plausible — committing:" << v << unit;
        }
        m_lastTemperature     = v;
        m_lastTemperatureUnit = QString::fromLatin1(unit);
        if (m_connState != "streaming") setConnState("streaming");
        if (fastSubscribe()) {
            // long-hold HTS keeps the connection up ~1 min after connecting, so hold
            // the link (re-arm the 60 s safety net) rather than dropping it after
            // a reading: further measurements within that minute arrive on this
            // same live connection with no reconnect, and the LED stays solid.
            // The meter's own power-off near the 1-min mark (Connected:no) ends
            // the link and drives the next reconnect.
            m_streamingTimer->start(60000);
        } else {
            // Real measurement — cancel the ghost-link disconnect timer.
            m_streamingTimer->stop();
        }
        qCInfo(lcBle) << "  parsed temp:" << v << unit;
        emit lastTemperatureChanged();
        emit temperatureReceived(v, m_lastTemperatureUnit);
    };

    if (n >= 5) {
        const uint8_t flags = b[0];
        const char *unit = (flags & 0x01) ? "F" : "C";
        int32_t mantissa = b[1] | (b[2] << 8) | (b[3] << 16);
        if (mantissa & 0x00800000) mantissa -= 0x01000000;
        int8_t exp = static_cast<int8_t>(b[4]);
        const double v = mantissa * std::pow(10.0, exp);
        const bool inRange = (QString::fromLatin1(unit) == "C") ? (v >= -50.0 && v <= 100.0)
                                                                : (v >= -58.0 && v <= 212.0);
        if (inRange) { commitTemp(v, unit); return; }
    }

    if (n >= 2) {
        const uint16_t raw = b[0] | (b[1] << 8);
        if (raw != 0x07FF && raw != 0x0800 && raw != 0x0801 && raw != 0x0802) {
            int mantissa = raw & 0x0FFF;
            int exp      = (raw >> 12) & 0x0F;
            if (mantissa & 0x0800) mantissa -= 0x1000;
            if (exp & 0x08)        exp      -= 0x10;
            const double v = mantissa * std::pow(10.0, exp);
            if (v >= 25.0 && v <= 50.0) { commitTemp(v, "C"); return; }
        }
    }

    if (n >= 4) {
        float v;
        std::memcpy(&v, b, 4);
        if (v >= 25.0f && v <= 50.0f) { commitTemp(v, "C"); return; }
    }

    if (n >= 2) {
        const uint16_t v = b[0] | (b[1] << 8);
        if (v >= 1000 && v <= 4500) { commitTemp(v / 100.0, "C"); return; }
    }

    if (n >= 1) {
        const uint8_t v = b[0];
        if (v >= 25 && v <= 50) { commitTemp(static_cast<double>(v), "C"); return; }
    }

    if (vendor1524) {
        m_vendor1524TemperaturePending = false;
    }
    qCInfo(lcBle) << "  parse failed (no rule matched)";
}
