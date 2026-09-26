#include "deviceprofiles.h"

#include <QCoreApplication>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QLoggingCategory>
#include <QProcessEnvironment>

Q_LOGGING_CATEGORY(lcProfiles, "edgepilot.deviceprofiles")

namespace {

QStringList toStringList(const QJsonValue &v)
{
    QStringList out;
    if (!v.isArray()) return out;
    const QJsonArray arr = v.toArray();
    for (const QJsonValue &item : arr) {
        const QString s = item.toString().trimmed();
        if (!s.isEmpty()) out.append(s);
    }
    return out;
}

QString normalize(const QString &s)
{
    QString n = s.toUpper();
    n.remove('-');
    n.remove(' ');
    return n;
}

} // namespace

const DeviceProfiles &DeviceProfiles::instance()
{
    static const DeviceProfiles profiles;
    return profiles;
}

DeviceProfiles::DeviceProfiles()
{
    QStringList candidates;

    const QString fromEnv =
        QProcessEnvironment::systemEnvironment().value(QStringLiteral("EDGEPILOT_DEVICE_PROFILES"));
    if (!fromEnv.isEmpty()) candidates << fromEnv;

    // applicationDirPath() needs a QCoreApplication; this singleton is only ever
    // touched from scanner code that runs well after main() built one, but guard
    // anyway so a unit test constructing it bare doesn't trip an assert.
    if (QCoreApplication::instance())
        candidates << QCoreApplication::applicationDirPath() + QStringLiteral("/device-profiles.json");

    candidates << QStringLiteral("/etc/edgepilot/device-profiles.json");

    for (const QString &path : candidates) {
        if (!QFileInfo::exists(path)) continue;
        loadFrom(path);
        return;
    }

    qCInfo(lcProfiles) << "no device-profiles.json found (looked in" << candidates
                       << ") — every device-specific special case is disabled";
}

void DeviceProfiles::loadFrom(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        qCWarning(lcProfiles) << "cannot open" << path << ":" << f.errorString()
                              << "— continuing with an empty profile set";
        return;
    }

    QJsonParseError err {};
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        // A malformed file is worse than a missing one — it usually means someone
        // edited it in a hurry. Say so loudly and keep the empty (safe) set rather
        // than half-applying whatever parsed.
        qCWarning(lcProfiles) << "malformed" << path << ":" << err.errorString()
                              << "— continuing with an empty profile set";
        return;
    }

    const QJsonObject o = doc.object();
    m_memoryMeterPrefix = o.value(QStringLiteral("memoryMeterNamePrefix")).toString().trimmed();
    m_alwaysOn          = toStringList(o.value(QStringLiteral("alwaysOnTokens")));
    m_vendor1524        = toStringList(o.value(QStringLiteral("vendor1524Tokens")));
    m_longHold           = toStringList(o.value(QStringLiteral("longHoldTokens")));

    qCInfo(lcProfiles) << "loaded" << path
                       << "— memoryMeterPrefix:" << (m_memoryMeterPrefix.isEmpty() ? "(none)" : "set")
                       << "alwaysOn:" << m_alwaysOn.size()
                       << "vendor1524:" << m_vendor1524.size()
                       << "longHold:" << m_longHold.size();
}

bool DeviceProfiles::matches(const QString &name, const QStringList &tokens)
{
    if (tokens.isEmpty() || name.isEmpty()) return false;
    const QString n = normalize(name);
    for (const QString &token : tokens) {
        const QString t = normalize(token);
        if (!t.isEmpty() && n.contains(t)) return true;
    }
    return false;
}
