#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QVariantList>
#include <QHash>
#include <QSet>
#include <QByteArray>

class BleScanner : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList devices         READ devices            NOTIFY devicesChanged)
    Q_PROPERTY(bool        scanning         READ scanning           NOTIFY scanningChanged)
    // User intent (Start Scan / Stop Scan button reflects THIS, not the
    // internal scan state — auto-reconnect toggles `scanning` on/off
    // every cycle while the user just wants the button to stay put).
    Q_PROPERTY(bool        scanIntent       READ scanIntent         NOTIFY scanIntentChanged)
    Q_PROPERTY(QString     status           READ status             NOTIFY statusChanged)
    // Connection state — one of: "idle", "connecting", "connected", "streaming", "error".
    Q_PROPERTY(QString     connectionState  READ connectionState    NOTIFY connectionStateChanged)
    Q_PROPERTY(QString     connectedAddress READ connectedAddress   NOTIFY connectedAddressChanged)
    Q_PROPERTY(QString     connectedName    READ connectedName      NOTIFY connectedNameChanged)
    // Latched true while a reconnect target is held (between power-cycle
    // measurement cycles the link drops and connectedAddress is empty, but we
    // keep retrying). Pages use this to keep the 斷線 button visible mid-loop.
    Q_PROPERTY(bool        autoReconnect    READ autoReconnect      NOTIFY autoReconnectChanged)
    Q_PROPERTY(qreal       lastTemperature  READ lastTemperature    NOTIFY lastTemperatureChanged)
    Q_PROPERTY(QString     lastTemperatureUnit READ lastTemperatureUnit NOTIFY lastTemperatureChanged)
    // Auto-connect by Manufacturer Data company ID. 0 = disabled. When set,
    // any advertisement carrying a matching ManufacturerData Key triggers an
    // immediate connect without user input. No page sets this today; it is
    // kept for hosts that pair by company ID rather than by selection.
    Q_PROPERTY(int autoConnectCompanyId READ autoConnectCompanyId NOTIFY autoConnectCompanyIdChanged)
    // True while the connected peer is one of the vendor-1524 state-machine
    // meters. QML drives the countdown HUD off this instead of sniffing the
    // device name itself — which names count is a deployment question answered
    // by device-profiles.json, not something a layout should know.
    // Re-evaluates on connectedNameChanged: the name is what the match reads.
    Q_PROPERTY(bool vendor1524Device READ isVendor1524Device NOTIFY connectedNameChanged)

public:
    explicit BleScanner(QObject *parent = nullptr);
    ~BleScanner() override;

    QVariantList devices() const;
    bool        scanning() const         { return m_scanning; }
    bool        scanIntent() const       { return m_scanIntent; }
    QString     status() const           { return m_status; }
    QString     connectionState() const  { return m_connState; }
    QString     connectedAddress() const { return m_connectedAddress; }
    QString     connectedName() const    { return m_connectedName; }
    bool        autoReconnect() const    { return m_autoReconnect; }
    qreal       lastTemperature() const  { return m_lastTemperature; }
    QString     lastTemperatureUnit() const { return m_lastTemperatureUnit; }
    // Vendor-1524 state machine (0x54 measuring / 0xec abnormal / 0xff done).
    // Which advertised names this covers comes from device-profiles.json; with
    // no profile loaded it is always false and 1524 is never subscribed.
    bool isVendor1524Device() const;

public slots:
    void startScan();
    void stopScan();
    void clearDevices();
    void connectDevice(const QString &address);
    // Standard-thermometer connect entry (BLE Tools → 標準品BLE). Same
    // power-cycle disconnect/scan/reconnect lifecycle as connectDevice(), but
    // latches "standard mode": the temperature subscribe selects 0x2A1C *by
    // UUID* instead of a hard-coded bluez handle path, so it works across
    // different Bluetooth-4.0 thermometers whose GATT handle layout (and
    // advertised device name) differ — one such meter puts 2A1C at
    // service001c/char001d, not the always-on meter's service0022/char0023.
    void connectStandardDevice(const QString &address);
    void disconnectDevice();
    // Numeric Comparison pairing (BLE 4.2+ Secure Connections). The peripheral
    // shows a 6-digit passkey; bluez forwards it via the bluetoothctl agent.
    // QML handles the confirmation dialog and calls confirm/cancel.
    void pairDevice(const QString &address);
    void confirmPairing();
    void cancelPairing();
    void unpairDevice(const QString &address);
    // One-shot helper: list every paired device and remove it. Used by the
    // "清除所有配對" UI button so the operator doesn't have to copy the MAC.
    void clearAllPairings();
    // Auto-connect by company ID: while the scan is on, any advertisement
    // whose ManufacturerData company ID matches `cid` triggers an immediate
    // connect + subscribe + temperature stream without user interaction.
    // Set 0 (or call clear) to disable.
    void setAutoConnectCompanyId(int cid);
    void clearAutoConnectCompanyId() { setAutoConnectCompanyId(0); }
    int  autoConnectCompanyId() const { return m_autoConnectCompanyId; }

signals:
    void devicesChanged();
    void scanningChanged();
    void scanIntentChanged();
    void statusChanged();
    void connectionStateChanged();
    void connectedAddressChanged();
    void connectedNameChanged();
    void autoReconnectChanged();
    void connected();
    void connectionFailed(const QString &reason);
    void lastTemperatureChanged();
    void temperatureReceived(qreal value, const QString &unit);
    // Vendor state machine on UUID 1524 — UI uses these to drive the
    // on-curve 60 s countdown HUD and the abnormal-reading banner.
    void vendor1524MeasurementStarted();   // 0x54 — start countdown
    void vendor1524MeasurementAbnormal();  // 0xec — flag abnormal reading
    void vendor1524MeasurementComplete();  // 0xff — measurement end

    // Pairing flow (numeric comparison)
    void pairingPasskey(const QString &address, const QString &passkey);
    void pairingSucceeded(const QString &address);
    void pairingFailed(const QString &address, const QString &reason);
    void autoConnectCompanyIdChanged();
    // Emitted whenever an advertisement matching autoConnectCompanyId is seen
    // — UI uses this to flash the "auto-connecting…" indicator even before
    // bluez has completed the link.
    void autoConnectMatch(const QString &address);

private slots:
    void onStdout();
    void onProcessFinished(int code, QProcess::ExitStatus st);
    void onSubscribeTimeout();
    void onReconnectTimer();
    void onStreamingTimeout();
    void onPeriodicConnectTimer();
    // Standard-mode scan-health watchdog. CC3351 scan can silently stall under
    // the high connect/disconnect churn (Discovery "on" but zero advertisements
    // surface), which kills adv-driven reconnect and slows every reading. This
    // detects the stall and power-cycles the adapter to recover it.
    void onScanHealthCheck();

private:
    void ensureProcess();
    void writeLine(const QByteArray &cmd);
    void setStatus(const QString &s);
    void setConnState(const QString &s);
    void setConnectedAddress(const QString &a);
    void setConnectedName(const QString &n);
    void setAutoReconnect(bool on);
    void clearLastTemperature();
    void upsertDevice(const QString &addr, const QString &name);
    void handleLine(const QString &line);
    void parseTemperatureBytes(const QByteArray &data);
    void subscribeNextTempChar();
    // Long-hold HTS fix: the kernel opens LE links with a 420 ms supervision timeout
    // and the meter's radio naps longer than that while pre-warming, killing
    // fresh links (HCI 0x08); mid-link parameter updates are equally fatal
    // (12× HCI 0x28 Instant Passed — the napping radio misses the update
    // instant). This kernel has no default-parameter knobs (empty debugfs, no
    // MGMT sysconfig), so before EVERY connect attempt re-assert the
    // per-device connection parameters (raw MGMT Load Connection Parameters)
    // with exactly the values the meter's firmware itself requests
    // (15-30 ms / latency 0 / 4 s timeout): links then start safe from t=0
    // and the firmware skips its own update — zero updates, zero 0x28.
    // Standard-mode connects only.
    // supervisionUnits ×10 ms. Default 1500 = 15 s for long-hold HTS meters (covers the radio
    // nap). Numeric-comparison power-cycle meters pass 400 (4 s) so the link's
    // fast 15-30 ms interval speeds GATT discovery WITHOUT slowing disconnect
    // detection on a meter that power-cycles itself.
    void loadConnParams(const QString &address, quint16 supervisionUnits = 1500);
    // Power-cycle the adapter (power off→on) to recover a stalled scan.
    void recoverStalledScan();
    // Shared connect body for connectDevice()/connectStandardDevice(); the only
    // difference between the two entry points is the m_standardMode latch they
    // set before calling this.
    void connectInternal(const QString &address);
    // True while a freshly-issued `connect` is still inside its protection
    // window (kConnectProtectMs from m_lastConnectAttemptMs). While true no other
    // reconnect initiator may issue connect / toggle scan, so competing timers
    // stop cancelling each other's pending LE create-connection (the
    // le-connection-abort-by-local storm).
    bool connectProtected() const;
    // The bluetoothctl `select-attribute` argument(s) used to subscribe the
    // Temperature Measurement char on the current target. In standard mode this
    // is the 0x2A1C UUID (handle-layout independent); otherwise it is the two
    // legacy hard-coded handle paths, one per known GATT layout.
    QStringList tempCharSelectors() const;
    // The connected / target / cached name slots joined into one string. During
    // a reconnect they take turns being the only populated one, so every
    // profile match runs against all three at once.
    QString identityNames() const;
    // Apollo510b watchface (advertises as "EdgePilot-510B", Cordio stack).
    // Numeric-comparison like the BLE Scan meters, but its Health Thermometer
    // Measurement (0x2A1C) is declared ATT_PROP_INDICATE *only* - the char has
    // no Read property at all (cordio ble-profiles svc_hts.c: htsValTmCh) and
    // the firmware emits its FIRST sample only once the CCCD is armed, then one
    // per second on a link it holds open. So the two things the third-party numeric
    // path does - `read` the cached value, and re-read on a zero-mantissa
    // placeholder - are not merely useless here: each returns
    // org.bluez.Error.NotPermitted and delays the CCCD arm that is the only
    // thing that ever produces data. See subscribeNextTempChar() and
    // parseTemperatureBytes().
    bool isApollo510Device() const;
    // Supervision timeout (x10 ms) handed to loadConnParams() for a
    // numeric-comparison target. Apollo510b holds the link, so it takes
    // the long-hold HTS profile's 15 s; third-party numeric meters power-cycle themselves and
    // need the short 4 s so their self-disconnect is detected fast.
    quint16 numericSupervisionUnits() const { return isApollo510Device() ? 1500 : 400; }
    // Always-on firmware: connect → bluez `read 2A1C` returns
    // the device's *last* measurement (cached) BEFORE notify catches the new
    // one. The first parsed sample must be dropped so the UI doesn't show a
    // stale value. Every other meter class (vendor-1524, and the power-cycle
    // families generally) runs power-cycle firmware — their first indicate IS
    // the new measurement and must NOT be dropped. Default: NOT always-on
    // (= don't drop). Which names count is alwaysOnTokens in
    // device-profiles.json; with no profile loaded nothing matches and
    // nothing is dropped.
    bool isAlwaysOnFirmware() const;
    // True for power-cycle meters that need the fast-subscribe strategy:
    // standard BLE / long-hold HTS (m_standardMode) OR Scan3 numeric-comparison
    // (m_numericMode). Both must arm the CCCD the instant the link is up
    // (not wait the 4-5 s ServicesResolved), select 0x2A1C by UUID, and skip
    // the indicate-only read — otherwise every reconnect pays a full GATT
    // re-discovery before the temperature can arrive.
    bool fastSubscribe() const { return m_standardMode || m_numericMode; }

    QProcess  *m_proc { nullptr };
    QByteArray m_buf;

    QHash<QString, QString> m_byAddr;
    QStringList             m_order;

    bool    m_scanning { false };
    bool    m_scanIntent { false };
    QString m_status { "Idle" };

    QString m_connState { "idle" };
    QString m_connectedAddress;
    QString m_connectedName;

    // BLE SCAN 2A1C selection: capture the connected device's actual 0x2A1C
    // characteristic object path from GATT discovery so we can select it by
    // full path (device-scoped AND handle-independent). A bare-UUID
    // select-attribute is device-ambiguous — bluetoothctl resolves it against a
    // stale same-alias cached device after a meter MAC change. m_lastCharObjPath
    // is the running "last characteristic object path seen"; m_tempCharPath is
    // the one whose following UUID line was 0x2A1C.
    QString m_lastCharObjPath;
    QString m_tempCharPath;

    // Standard-thermometer mode: latched by connectStandardDevice(), cleared by
    // connectDevice(). When set, subscribeNextTempChar() selects 0x2A1C by UUID
    // so the subscribe is independent of the device's GATT handle layout.
    bool    m_standardMode { false };

    // Numeric-comparison (LE Secure Connections / bonding) peers — set by
    // pairDevice(), cleared by connectDevice()/connectStandardDevice(). Two
    // different device classes share this latch:
    //   * Power-cycle thermometers, which push their single 2A1C indication
    //     the instant the link/encryption is up and then drop the link.
    //   * BLE Scan: the Apollo510b watch (EdgePilot-510B), which HOLDS the link
    //     and indicates once per second.
    // Both need the same fast-subscribe strategy as m_standardMode (early CCCD
    // arm, UUID select) so a reconnect doesn't pay the 4-5 s ServicesResolved
    // wait — but not the long-hold HTS profile's 60 s hold semantics wholesale. The two places
    // where the classes genuinely differ (the `read`, and the supervision
    // timeout) key off isApollo510Device() rather than this flag.
    bool    m_numericMode { false };

    // Stage tracking
    bool    m_pendingValueLine { false };   // next line is a hex byte dump
    int     m_charAttempt { 0 };            // which UUID we last tried (0=legacy layout, 1=standard 2a1c, …)
    bool    m_inGattMenu { false };

    qreal   m_lastTemperature { 0 };
    QString m_lastTemperatureUnit { "C" };
    bool    m_dropNextTemperatureSample { false };
    bool    m_vendor1524TemperaturePending { false };
    // Fix A: in-connection re-read budget when the meter serves its cached
    // zero-mantissa placeholder instead of a fresh measurement. Reset at the
    // start of every subscribe; counts up to kMaxPlaceholderReadRetries before
    // falling back to the drop→reconnect path.
    int     m_placeholderReadRetries { 0 };

    class QTimer *m_subscribeTimer { nullptr };
    bool          m_subscribedOnce { false };

    // Auto-reconnect loop. The third-party thermometer power-cycles its radio per
    // measurement: connect → push one indicate → disconnect. We persist the
    // target MAC and keep retrying `connect` so each new measurement is caught
    // without further user interaction.
    class QTimer *m_reconnectTimer { nullptr };
    QString       m_targetAddress;   // empty = no auto-reconnect target
    bool          m_autoReconnect { false };
    // Timestamp (ms since epoch) of the last `connect` issued by ANY reconnect
    // initiator. Guards the pending-connect protection window — see
    // kConnectProtectMs / connectProtected().
    qint64        m_lastConnectAttemptMs { 0 };

    // BLE Scan2 — auto-connect by ManufacturerData company ID
    int           m_autoConnectCompanyId { 0 };
    qint64        m_lastAutoConnectMs { 0 };  // throttle re-trigger

    // Latched while a `pair` command is in flight, between issuing the pair
    // command and seeing either "Pairing successful" or "Failed to pair".
    // Used to disambiguate the same "Confirm passkey N (yes/no):" prompt for
    // future re-pair attempts.
    QString m_pairingAddress;
    QString m_pairingPasskey;
    // Set when ServicesResolved: yes arrives WHILE a pairing handshake is still
    // in flight (numeric comparison: bluez resolves GATT on the LL link ~2.5 s
    // after connect, before the user has confirmed the passkey). We must NOT
    // subscribe then — writing `menu gatt`/select/notify into bluetoothctl while
    // its agent is blocked on "Confirm passkey (yes/no):" is consumed as the
    // agent reply and bluez aborts SMP with AuthenticationFailed (the "dialog
    // shows, ~2 s later pairing fails" bug, btmon/journal 2026-06-26 22:01). We
    // defer the subscribe; bluez won't re-emit ServicesResolved after a pre-bond
    // resolve, so this latch tells rePairedYes to issue the subscribe once the
    // bond completes.
    bool    m_subscribeAfterPairing { false };

    // Addresses the user explicitly cancelled out of (numeric comparison
    // dialog → Cancel). When the device subsequently re-advertises and
    // bluez auto-re-prompts with a freshly-randomised passkey, we silently
    // reject it instead of bouncing the dialog back at the user. Lifted
    // on the next explicit pairDevice() call for the same address.
    QSet<QString> m_cancelledPairings;

    // Ghost-advertisement filter: the thermometer keeps advertising for a
    // short window after disconnecting, which is not a real new measurement.
    // Suppress reconnect triggers during a cooldown after every disconnect.
    class QTimer *m_streamingTimer { nullptr };
    qint64        m_cooldownUntilMs { 0 };

    // Periodic active-connect fallback. When we are latched to a target but
    // sit in "idle" past the cooldown window — typically because the meter's
    // BLE radio has gone into deep sleep and advertises only every 5-10 s —
    // proactively issue `connect <addr>` instead of waiting for the next
    // [CHG] advertisement event. bluez sends an LE Connect Request and the
    // peer can ack from inside a (longer) connectable window even when it's
    // not currently broadcasting.
    class QTimer *m_periodicConnectTimer { nullptr };

    // Scan-health watchdog state (standard mode). m_lastAdvMs = last time ANY
    // advertisement surfaced; m_scanStaleCount = consecutive health-check ticks
    // seen "scanning + idle + no advertisement". When it crosses the threshold
    // the scan is judged stalled and recoverStalledScan() power-cycles hci0.
    class QTimer *m_scanHealthTimer { nullptr };
    qint64        m_lastAdvMs { 0 };
    int           m_scanStaleCount { 0 };
};
