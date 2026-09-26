# 5. Network and SSH

Every tool in this repository reaches the board over ssh with key
authentication. Getting that solid first makes everything after it boring.

## Deploy a key

```bash
scripts/setup_evm.sh --host 192.168.0.42 --deploy-key
```

or by hand:

```bash
ssh-keygen -t ed25519                     # if you have no key yet
ssh-copy-id root@192.168.0.42             # asks for the board password once
ssh root@192.168.0.42 'uname -a'          # must not prompt
```

## Why every panel uses BatchMode

```
-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8
```

`BatchMode=yes` disables the password prompt. That is deliberate: a GUI cannot
answer a prompt, so without it a missing key gives a hung window instead of an
error. With it you get exit code 255 in under eight seconds and a message that
says what to do.

`accept-new` accepts a first-time host key but still refuses a *changed* one, so
reflashing a board does not silently defeat host verification. When the key does
change:

```bash
ssh-keygen -R 192.168.0.42
```

## The board is probably running dropbear, not OpenSSH

This costs people an afternoon, reliably.

Minimal images ship **dropbear**. It has no `sshd_config`, no `sshd -T`, and no
`/etc/ssh/` at all. Looking for them and finding nothing reads like a broken
installation.

Its password policy lives in the command-line flags of the running process:

| Flag | Effect |
|---|---|
| `-s` | no password logins at all |
| `-g` | no password login for root |
| `-w` | no root login |
| `-B` | allow blank passwords |

```bash
ps aux | grep '[d]ropbear'
cat /etc/default/dropbear 2>/dev/null
```

If none of `-s`, `-g`, `-w` are there, root password login is enabled — and a
failed login means the password is simply wrong.

Also: dropbear is usually socket-activated, so

```bash
systemctl is-active sshd     # inactive
```

is the normal state between connections, not an outage. Check
`dropbear.socket` instead.

The GUI's **Password SSH** panel and `remote/system.py::ssh_server_info()` print
all of this in one go.

## Authorised keys live somewhere specific

```bash
ls -l /root/.ssh/authorized_keys
```

dropbear insists on the permissions being right: `700` on `~/.ssh` and `600` on
`authorized_keys`, owned by the account. Wrong permissions cause a silent
rejection — the log says nothing useful.

## Password login when there is no key yet

```bash
sudo apt install sshpass                            # on the build host
SSHPASS='thepassword' sshpass -e ssh \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password \
    root@192.168.0.42 'uname -a'
```

`sshpass -e` takes the password from the environment, so it never appears in the
command line or in `ps`. Turning public keys off matters too: otherwise a stale
agent key can succeed and hide the password problem you are trying to diagnose.

The GUI's Password SSH panel does exactly this, and never writes the password to
its log.

## Wi-Fi

The AM62P starter kit takes its Wi-Fi from an M.2 module. On the TI modules the
part is a **CC3351** or a relative — a combo device with Wi-Fi and Bluetooth LE
in one package, which matters more than it sounds; see the last section here.

### The stack

```
M.2 module (CC3351)
    Wi-Fi  --> SDIO --> cc33xx_sdio --> cc33xx --> mac80211 --> wlan0
    BLE    --> UART --> HCI transport driver --> BlueZ --> hci0
```

Two independent kernel paths, one piece of silicon and one firmware image. Each
step is a place to look when `wlan0` does not exist:

```bash
ls /sys/bus/sdio/devices/          # did the module enumerate on SDIO at all?
lsmod | grep cc33                  # are the driver modules loaded?
ip link show wlan0                 # did mac80211 register an interface?
dmesg | grep -iE 'cc33|sdio|mmc[0-9]|wlan'
```

No SDIO device is a hardware or device-tree problem (is the MMC controller for
the M.2 slot enabled?). An SDIO device with no `wlan0` is a driver or firmware
problem.

### Firmware, and the error that does not matter

```bash
ls /lib/firmware/ti-connectivity/
dmesg | grep -i firmware
```

The driver loads a firmware image and, separately, tries to load a **NVS or
calibration blob**. Some SDK releases do not ship the second one:

```
cc33xx: Direct firmware load for ti-connectivity/cc33xx-nvs.bin failed with error -2
```

That looks fatal and is not. Without it the driver falls back to defaults —
including a default MAC address — and basic connectivity works. Do not spend an
afternoon on it while the real fault is elsewhere. It *is* worth fixing before
shipping, because a default MAC and uncalibrated RF are not what you want in a
product.

A missing *main* firmware image is a different matter and stops the interface
existing at all. The `dmesg` line names the file either way, so read which one it
is complaining about.

### Regulatory domain

```bash
iw reg get
```

`country 00: DFS-UNSET` is the world-roaming default: conservative, and it hides
channels. If a 5 GHz AP is invisible to the board but obvious to a phone, check
this before suspecting the antenna.

```bash
iw reg set DE                      # or wherever the board actually is
```

To make it stick, set `REGDOMAIN` in `/etc/default/crda`, or the equivalent for
your image. The regulatory database (`regulatory.db`) also has to be present in
`/lib/firmware/`, or the setting is silently ignored.

### Association

```bash
iw dev wlan0 scan | grep -E 'SSID|signal|freq'
iw dev wlan0 link                  # associated? which AP? what signal?
```

`iw ... link` says `Not connected` while a supplicant is authenticating too, so
check it twice a few seconds apart before concluding anything.

Which supplicant depends on the image — `wpa_supplicant` directly, or connman or
NetworkManager on top of it:

```bash
systemctl status wpa_supplicant connman NetworkManager 2>/dev/null | grep -E 'Loaded|Active'
```

Configuring one of them from another's config file is a common way to get an
interface that never associates and logs nothing useful.

### Bind connectivity tests to the interface

A board with Ethernet up will answer an unbound `ping` over Ethernet and make a
dead Wi-Fi look perfectly healthy.

```bash
ping -I wlan0 -c 4 www.example.com
```

Use a hostname, not an address: one successful run then proves association,
routing, DNS and the path out, all at once. Read the failures:

| | |
|---|---|
| `Destination Host Unreachable` | the packets never left the board — association or route |
| `100% packet loss` | they left and nothing came back — AP, upstream or DNS |
| `Name or service not known` | associated and routed, but DNS is not configured |

```bash
ip -br addr show wlan0             # is there an address?
ip route                           # is there a route through wlan0?
cat /etc/resolv.conf               # is there a resolver?
```

### The combo-chip failure that arrives hours later

Wi-Fi and BLE share one chip and one firmware. When the Wi-Fi side hits an
unrecoverable error the driver performs a firmware recovery — and that takes the
**Bluetooth** side down with it. The adapter simply disappears, long after boot,
with nothing in the Bluetooth log to explain it.

```bash
dmesg | grep -iE 'fw.*stuck|firmware.*(recovery|reset|reload)|cc33'
hciconfig -a                       # nothing at all now
```

If you are chasing a Bluetooth adapter that vanished, look at the Wi-Fi log. And
if you are chasing intermittent Wi-Fi, note that a healthy-looking BLE stack does
not clear Wi-Fi of suspicion — check whether both went at the same moment.

Recovering usually does not need a reboot: re-run whatever enables BLE on your
image, re-bind the HCI transport, then restart `bluetooth.service`. The exact
unit and device names differ between images —
`troubleshooting/wifi-decision-tree.md` has the sequence and how to find yours.

### Power save

```bash
iw dev wlan0 get power_save
iw dev wlan0 set power_save off
```

Power save costs latency — tens to hundreds of milliseconds on the first packet
after an idle period. On a board that is mains powered and needs responsive
network I/O, turn it off. On a battery product, leave it on and design around the
latency. Either way, know which one you have before measuring anything.

### Tools here

```bash
scripts/hardware_health_check.sh --host <address> --only network
```

The GUI's **Network** panel has status, an interface-bound ping, an AP scan, and
a driver/firmware/regulatory view. The board profile supplies the interface name,
the ping target and the firmware directory:

```yaml
network:
  wifi_interface: wlan0
  ping_host: www.google.com
  firmware_dir: /lib/firmware/ti-connectivity
  dmesg_filter: "cc33xx|wlan0|nvs|regulatory"
```

## Speeding up repeated connections

Every panel opens its own ssh connection. On a slow link, multiplexing makes
that much cheaper — add to `~/.ssh/config`:

```
Host 192.168.0.*
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 60
```

## Copying files

```bash
scp -O file root@192.168.0.42:/usr/bin/
```

`-O` forces the legacy protocol. Since OpenSSH 9, `scp` uses SFTP by default,
and minimal target images often have no sftp server — the failure is
`subsystem request failed on channel 0`, which does not mention sftp at all.

## Related

* `scripts/setup_evm.sh`
* `docs/16-troubleshooting.md`

## Next

`06-device-tree.md`
