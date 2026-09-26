#pragma once

#include <QObject>
#include <QProcess>
#include <QHash>

class BenchmarkRunner : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString activeBench   READ activeBench   NOTIFY activeBenchChanged)
    Q_PROPERTY(QString activeOutput  READ activeOutput  NOTIFY activeOutputChanged)
    Q_PROPERTY(QString activeResult  READ activeResult  NOTIFY activeResultChanged)
    Q_PROPERTY(bool    activeRunning READ activeRunning NOTIFY activeRunningChanged)
public:
    explicit BenchmarkRunner(QObject *parent = nullptr);

    Q_INVOKABLE void run(const QString &name);
    Q_INVOKABLE QString status(const QString &name) const;
    Q_INVOKABLE QString result(const QString &name) const;
    Q_INVOKABLE bool isRunning(const QString &name) const;

    QString activeBench()   const { return m_activeBench; }
    QString activeOutput()  const { return m_outputs.value(m_activeBench); }
    QString activeResult()  const { return m_results.value(m_activeBench, QStringLiteral("click")); }
    bool    activeRunning() const { return isRunning(m_activeBench); }

signals:
    void statusChanged(const QString &name);
    void resultChanged(const QString &name, const QString &result);
    void activeBenchChanged();
    void activeOutputChanged();
    void activeResultChanged();
    void activeRunningChanged();

private slots:
    void onProcessFinished(int exitCode, QProcess::ExitStatus status);
    void onProcessReadyRead();

private:
    QString scriptPath(const QString &name) const;
    QString parseResult(const QString &name, const QString &output) const;

    QString m_activeBench;
    QHash<QString, QProcess*> m_processes;
    QHash<QString, QString>   m_results;
    QHash<QString, QString>   m_status;
    QHash<QString, QString>   m_outputs;
};
