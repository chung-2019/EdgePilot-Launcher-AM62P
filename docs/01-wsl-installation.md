# 1. WSL as a build host

Skip this if you build on native Linux — everything else in this repository
works the same way there.

## Why WSL rather than a virtual machine

The AM62P SDK is a Linux toolchain, but the board is usually on a desk next to a
Windows laptop. WSL2 gives you the Linux side without a second machine, and
unlike a VM it shares the network stack — so the board is reachable at the same
address from Windows and from Linux, with no bridging to configure.

The split this repository assumes:

| Runs on Windows | Runs inside WSL |
|---|---|
| the GUI (`gui/main.py`) | the compiler, `ssh`, `scp`, the SDK installer |
| your editor | the build scripts, the examples |

The GUI needs tkinter, which ships with the python.org Windows build and *not*
with the WSL Python. Everything the GUI actually executes it runs through
`wsl.exe`, so the split is invisible in use.

## Install

In an administrator PowerShell:

```powershell
wsl --install -d Ubuntu
wsl --set-default-version 2
```

Reboot when asked, then set a username and password when the Ubuntu window
appears. Confirm:

```powershell
wsl -l -v
```

`VERSION` must be 2. WSL1 cannot run the SDK installer reliably and has a
different network model.

## Prepare the distribution

```bash
sudo apt update && sudo apt upgrade -y
git clone <this repository>
cd am62p-linux-workflow
./scripts/install_host.sh
```

`install_host.sh` installs the compiler, ssh tooling, device-tree tools and
Python, then reports what is present. It is idempotent: run it again any time as
a check.

## Where to keep your files

Keep the SDK and your source **inside** the WSL filesystem (`/home/you/...`,
`/opt/...`), not under `/mnt/c/`.

Crossing the Windows/Linux boundary goes through the 9p protocol, and it is slow
enough to change how you work: a build that takes two minutes on `/home` can
take fifteen on `/mnt/c`. The SDK installer is worse — it writes tens of
thousands of small files, which is the worst case for 9p. That is why
`install_host.sh` and the GUI both offer to copy the installer into the Linux
filesystem before running it.

You can still edit from Windows: `\\wsl$\Ubuntu\home\you\...` in Explorer, or
VS Code with the WSL extension, which runs its server on the Linux side.

## Networking

WSL2 gets its own virtual network, but outbound connections and `localhost`
forwarding work without configuration:

```bash
ping 192.168.0.42        # a board on the LAN: works
ssh root@192.168.0.42    # works
```

The direction that does *not* work by default is inbound — reaching a service
inside WSL from another machine. Nothing in this workflow needs that, except the
VNC tunnel in the GUI's Remote UI panel, which works because it forwards to
`localhost` on the Windows side.

If the board is unreachable from WSL but reachable from Windows, check Windows
Firewall first; that is the usual cause.

## Disk space

Budget roughly:

| | |
|---|---|
| Ubuntu itself | ~2 GB |
| TI SDK | ~10 GB installed, plus ~4.5 GB for the installer |
| host Qt (if needed) | ~2 GB |

The WSL virtual disk grows on demand and does not shrink when files are deleted.
To reclaim space after removing a large SDK:

```powershell
wsl --shutdown
Optimize-VHD -Path $env:LOCALAPPDATA\Packages\<distro>\LocalState\ext4.vhdx -Mode Full
```

## Things that surprise people

**`systemctl` may not work.** Older WSL runs no init system. Nothing here needs
systemd on the build host — all the systemd work happens on the board — but a
command copied from a server guide will fail. Modern WSL enables it with
`systemd=true` under `[boot]` in `/etc/wsl.conf`.

**Windows paths appear as `/mnt/c/...`.** The GUI converts what you type; the
scripts expect Linux paths.

**File permissions on `/mnt/c` are approximate.** A file there may not carry the
execute bit, which is why the SDK installer step runs `chmod +x` first.

**`wsl --shutdown` is the fix for a surprising number of problems** — a hung
mount, a stale network, an installer that will not release a file.

## Next

`02-ti-sdk-installation.md`
