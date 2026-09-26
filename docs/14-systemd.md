# 14. systemd on the board

## The four commands

```bash
systemctl status <unit>              # is it running, and what did it last say
systemctl list-units --failed        # what is broken right now
journalctl -u <unit> -b              # everything it said this boot
systemctl show -p Result <unit>      # *why* systemd gave up on it
```

The last one is the least known and the most useful. `Result=start-limit-hit`
means systemd stopped retrying, which is a completely different situation from a
unit that simply is not enabled — and `systemctl status` alone does not make the
difference obvious.

## A kiosk unit, and the three things that break it

```ini
[Unit]
Description=Example kiosk application
After=weston.service
Wants=weston.service
Conflicts=ti-apps-launcher.service

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=WAYLAND_DISPLAY=wayland-1
Environment=QT_QPA_PLATFORM=wayland

ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do \
    [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && exit 0; sleep 1; done; \
    echo "no Wayland socket after 60s"; exit 1'
ExecStart=/usr/bin/example-app

Restart=always
RestartSec=2
StartLimitBurst=5
StartLimitIntervalSec=30

[Install]
WantedBy=multi-user.target
```

### 1. `After=` is not "wait until ready"

`After=weston.service` only orders startup. systemd considers a unit started once
its process is running — which is well before a compositor has created its
Wayland socket. The application starts, finds no socket, and exits. On the next
boot the timing is slightly different and it works, which is the worst kind of
bug.

Wait for the socket itself. That is what the `ExecStartPre` loop does, and why it
is a loop and not a `sleep 5`.

### 2. `XDG_RUNTIME_DIR` must match the compositor's user

The client looks for the socket at `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`. If the
compositor runs as uid 1000 and your unit says `/run/user/0`, the socket is
simply not there. This is the classic "works when I run it over ssh, black screen
at boot" — over ssh you inherited a working environment.

```bash
ls -l /run/user/*/wayland-*         # where the socket actually is
systemctl show -p User weston       # who the compositor runs as
```

### 3. Bound the restarts

`Restart=always` on its own gives an invisible crash loop that burns CPU for
months. With the start limit, a persistently failing unit stops in a state you
can find:

```bash
systemctl show -p Result example-app.service
# Result=start-limit-hit
```

And when you fix the cause, clear the counter first — otherwise the start is
refused with a message that does not mention the limit:

```bash
systemctl reset-failed example-app.service
systemctl start example-app.service
```

## Three failure shapes

| What you see | Name it | Fix |
|---|---|---|
| stuck in `start-pre`, no Wayland socket | the compositor never came up | fix the display side; restarting the app does nothing |
| `inactive (dead)` and `disabled` | someone turned it off | `systemctl enable --now` |
| `failed`, `Result=start-limit-hit` | crash loop, systemd gave up | `reset-failed`, then read the journal for the real cause |

They look identical on the screen — black — and need opposite actions. Print
which one you have:

```bash
scripts/hardware_health_check.sh --host <address> --only services
```

## Logs

Send everything to the journal (`StandardOutput=journal`). An application that
writes its own log file will hide its crash reason exactly when you need it — on
a full or read-only filesystem.

```bash
journalctl -u example-app -b            # this boot
journalctl -u example-app -f            # follow
journalctl -u example-app --since -10m
journalctl -p err -b                    # errors from everything
```

The journal is usually volatile on an embedded image, so it is gone after a
reboot. To keep it across reboots:

```bash
mkdir -p /var/log/journal && systemctl restart systemd-journald
```

Weigh that against flash wear before enabling it on a product.

## Overrides beat editing

```bash
systemctl edit example-app.service
```

This writes `/etc/systemd/system/example-app.service.d/override.conf`, which
survives a package update replacing the unit. Editing the shipped unit in place
does not.

```ini
[Service]
Environment=QT_LOGGING_RULES=qt.qpa.*=true
```

To clear a list-valued directive before setting it, assign it empty first:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/example-app --debug
```

Omit that first empty line and you get two `ExecStart` entries, which is not what
you meant.

## What is slowing the boot

```bash
systemd-analyze
systemd-analyze blame | head -20
systemd-analyze critical-chain
```

`blame` is the flat list; `critical-chain` shows what was actually waiting on
what, which is the one that leads to a fix.

## Related

* `examples/systemd-service/` — the template and an installer with checks
* `troubleshooting/display-decision-tree.md`

## Next

`15-qt-deployment.md`
