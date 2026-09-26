#include "benchmarkrunner.h"

#include <QDebug>
#include <QFileInfo>
#include <QRegularExpression>

BenchmarkRunner::BenchmarkRunner(QObject *parent) : QObject(parent) {}

QString BenchmarkRunner::scriptPath(const QString &name) const {
    return QString("/opt/ti-apps-launcher/run-%1.sh").arg(name);
}

void BenchmarkRunner::run(const QString &name) {
    if (m_processes.contains(name)) {
        QProcess *p = m_processes[name];
        if (p->state() != QProcess::NotRunning) {
            if (m_activeBench != name) {
                m_activeBench = name;
                emit activeBenchChanged();
                emit activeOutputChanged();
                emit activeResultChanged();
                emit activeRunningChanged();
            }
            return;
        }
    }

    QString script = scriptPath(name);
    if (!QFileInfo::exists(script)) {
        m_status[name] = QString("script missing: %1").arg(script);
        m_outputs[name] = QString("[error] script missing: %1\n").arg(script);
        m_results[name] = QStringLiteral("script missing");
        m_activeBench = name;
        emit activeBenchChanged();
        emit activeOutputChanged();
        emit activeResultChanged();
        emit activeRunningChanged();
        emit statusChanged(name);
        emit resultChanged(name, m_results[name]);
        return;
    }

    QProcess *p = new QProcess(this);
    p->setProcessChannelMode(QProcess::MergedChannels);
    p->setProperty("benchName", name);

    connect(p, &QProcess::finished,                this, &BenchmarkRunner::onProcessFinished);
    connect(p, &QProcess::readyReadStandardOutput, this, &BenchmarkRunner::onProcessReadyRead);

    m_processes[name] = p;
    m_status[name] = "running";
    m_results[name] = QStringLiteral("running…");
    m_outputs[name].clear();

    m_activeBench = name;
    emit activeBenchChanged();
    emit activeOutputChanged();
    emit activeResultChanged();
    emit activeRunningChanged();
    emit statusChanged(name);

    p->setStandardInputFile(QProcess::nullDevice());
    p->start("/bin/sh", {script});
}

void BenchmarkRunner::onProcessReadyRead() {
    auto p = qobject_cast<QProcess*>(sender());
    if (!p) return;
    QString name = p->property("benchName").toString();
    QString chunk = QString::fromUtf8(p->readAllStandardOutput());
    if (chunk.isEmpty()) return;

    m_outputs[name].append(chunk);
    if (m_activeBench == name)
        emit activeOutputChanged();
}

void BenchmarkRunner::onProcessFinished(int exitCode, QProcess::ExitStatus status) {
    auto p = qobject_cast<QProcess*>(sender());
    if (!p) return;
    QString name = p->property("benchName").toString();

    QString tail = QString::fromUtf8(p->readAllStandardOutput());
    if (!tail.isEmpty()) m_outputs[name].append(tail);

    const QString &output = m_outputs[name];
    m_results[name] = parseResult(name, output);
    m_status[name] = (status == QProcess::NormalExit && exitCode == 0) ? "done" : "error";

    p->deleteLater();
    m_processes.remove(name);

    emit statusChanged(name);
    emit resultChanged(name, m_results[name]);

    if (m_activeBench == name) {
        emit activeOutputChanged();
        emit activeResultChanged();
        emit activeRunningChanged();
    }
}

QString BenchmarkRunner::parseResult(const QString &name, const QString &output) const {
    QRegularExpression re;
    QRegularExpressionMatch m;

    if (name == "whetstone") {
        re.setPattern("([0-9]+\\.[0-9]+)\\s*MIPS");
        m = re.match(output);
        if (m.hasMatch()) return m.captured(1) + " MIPS";
    } else if (name == "dhrystone") {
        re.setPattern("([0-9]+(?:\\.[0-9]+)?)\\s*DMIPS");
        m = re.match(output);
        if (m.hasMatch()) return m.captured(1) + " DMIPS";
        re.setPattern("Dhrystones per Second:\\s*([0-9]+)");
        m = re.match(output);
        if (m.hasMatch()) return m.captured(1) + " D/s";
    } else if (name == "linpack") {
        re.setPattern("([0-9]+\\.[0-9]+)\\s*Mflops");
        m = re.match(output);
        if (m.hasMatch()) return m.captured(1) + " Mflops";
    } else if (name == "stream") {
        re.setPattern("Triad:\\s*([0-9]+\\.[0-9]+)");
        m = re.match(output);
        if (m.hasMatch()) return m.captured(1) + " MB/s";
    } else if (name == "nbench") {
        re.setPattern("MEMORY INDEX\\s*:\\s*([0-9]+\\.[0-9]+)");
        m = re.match(output);
        if (m.hasMatch()) return m.captured(1) + " (mem)";
    } else if (name == "glmark2-fps" || name == "glmark2-score") {
        re.setPattern("glmark2 Score:\\s*([0-9]+)");
        m = re.match(output);
        if (m.hasMatch()) return m.captured(1);
    }

    auto lines = output.split('\n');
    for (auto it = lines.rbegin(); it != lines.rend(); ++it) {
        QString trimmed = it->trimmed();
        if (!trimmed.isEmpty()) return trimmed.left(40);
    }
    return "done";
}

QString BenchmarkRunner::status(const QString &name) const {
    return m_status.value(name, "idle");
}

QString BenchmarkRunner::result(const QString &name) const {
    return m_results.value(name, "click");
}

bool BenchmarkRunner::isRunning(const QString &name) const {
    auto p = m_processes.value(name, nullptr);
    return p && p->state() != QProcess::NotRunning;
}
