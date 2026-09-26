# -*- coding: utf-8 -*-
# The module docstring is a raw string: it contains Windows UNC paths
# (\\wsl$\<distro>\...) and shell line-continuation backslashes. In a normal
# string those are invalid escape sequences (SyntaxWarning on Python 3.12+,
# SyntaxError in a future release).
r"""
EdgePilot_Workbench.pyw - install the TI SDK, cross-compile, deploy, and probe
the AM62P EVM, from one window.

English-interface build with five tabs. It is a focused subset of the internal
17-tab tool; the tab numbers below are this tool's own.

  (1) Install SDK
      Silent install of the TI Processor SDK inside WSL via InstallBuilder's
      unattended mode:
          <installer>.bin --mode unattended --unattendedmodeui none \
                          --prefix /opt/ti/processor-sdk-linux-am62pxx \
                          --installer-language en
      Also installs the Qt host toolchain (aqtinstall -> /opt/Qt), which the
      launcher's cross build needs and the TI SDK does not ship, plus
      build-essential for the host-side tooling a build invokes.

  (2) CC3351 Wi-Fi
      Checks whether wlan0 actually reaches the outside world. Pings a
      *hostname* (not an IP) forced out of wlan0, so one test covers
      association, routing, DNS and external reachability at once. The EVM
      usually has eth0 up as well, so without `-I wlan0` the traffic leaves
      over the wire and the Wi-Fi path is never exercised.

  (3) Cross-compile + Deploy
      Runs the project's build script and deploy script inside WSL. The
      project path is not hard-coded -- any project works, given three
      conventions:
        a. the build script lives in the project directory and sources the
           SDK environment before cross-compiling for aarch64;
        b. the deploy script lives in the project directory and takes the
           board address from the EVM_IP environment variable;
        c. both run with the project directory as the working directory.
      "Scan projects" walks WSL for directories containing the build script,
      so adding a project never means editing this tool.

  (4) Password SSH
      For a board that only accepts a password (every other tab assumes
      key-based login with BatchMode=yes). The password is passed to sshpass
      through the SSHPASS environment variable, so it never appears in the
      command string, in `ps`, or in the log. Requires sshpass in WSL.

  (5) BLE Scan Step
      Opens a persistent interactive bluetoothctl session over SSH and sends
      one command at a time, following the same sequence as the launcher's
      BLE Scan page. Target: the Apollo510b watchface firmware (Cordio stack,
      advertised name EdgePilot-510B), six-digit numeric-comparison pairing.

      The subscribe sequence deliberately issues no `read`. Cordio declares
      0x2A1C as ATT_PROP_INDICATE only (svc_hts.c, htsValTmCh has no Read
      property), so `read` returns org.bluez.Error.NotPermitted, and the extra
      ATT round-trip delays the CCCD write -- which is the only thing that
      makes the firmware emit anything. It sends the first sample once the
      CCCD is armed, then one per second. This mirrors blescanner.cpp:
          doRead = !m_standardMode && !isApollo510Device();

Execution model:
  * The GUI runs under Windows python.exe (WSL's python3 has no tkinter).
  * Work happens in WSL through `wsl.exe -e bash -lc "<cmd>"`; board access
    goes over SSH using WSL's keys.
  * Every task is Popen -> reader thread -> queue -> root.after, so the UI
    stays responsive and output streams in line by line.
  * Installs run as root (`-u root`); /opt is not writable otherwise, and
    this keeps sudo from blocking on a password prompt at stdin.

No third-party packages: standard library and tkinter only.
"""

import os
import re
import sys
import time
import queue
import struct
import threading
import subprocess

import tkinter as tk
from tkinter import ttk, filedialog, scrolledtext
from tkinter import font as tkfont      # tab bar wrapping needs text metrics


# ----------------------------------------------------------------------------
# Dark theme palette
# ----------------------------------------------------------------------------
BG = "#0f1419"
PANEL = "#1a2129"
INK = "#e6edf3"
MUTED = "#9aa7b4"
GREEN = "#3fb950"
AMBER = "#d29922"
RED = "#f85149"
ACCENT = "#4cc2ff"
CODE = "#0b0f14"


# ----------------------------------------------------------------------------
# Fixed paths
# ----------------------------------------------------------------------------
# TI SDK root, version-less. build.sh hard-codes this path, so the installer
# tab defaults to the same place.
SDK_ROOT = "/opt/ti/processor-sdk-linux-am62pxx"
ENV_SETUP = SDK_ROOT + "/linux-devkit/environment-setup"
EXAMPLES_ROOT = SDK_ROOT + "/example-applications"
LAUNCHER_DIR = EXAMPLES_ROOT + "/EdgePilot_Github_Demo"

# Cross-compile + deploy tab. These are defaults only -- the fields on the tab
# decide the real values, and "Scan projects" fills the dropdown from what is
# actually on disk.
DEFAULT_PROJECT_DIR = LAUNCHER_DIR
DEFAULT_BUILD_SH = "build.sh"
DEFAULT_DEPLOY_SH = "deploy.sh"
# One-click shortcut back to the default project. "Scan projects" is what
# finds everything else, so this list stays short on purpose.
PROJECT_QUICK_DIRS = (
    ("EdgePilot_Github_Demo", LAUNCHER_DIR),
)

# Installer tab defaults
DEFAULT_BIN_WIN = (r"C:\Others\TI_AM62x\SDK"
                   r"\ti-processor-sdk-linux-am62pxx-evm-12.00.00.07.04"
                   r"-Linux-x86-Install.bin")
DEFAULT_PREFIX = SDK_ROOT
DEFAULT_DISTRO = "Ubuntu"
DEFAULT_LANG = "en"
LANG_CHOICES = ["en", "zh_TW", "zh_CN", "ja", "ko"]

# Qt host toolchain (needed by the launcher's cross build)
QT_VER = "6.11.0"
QT_MOC = "/opt/Qt/%s/gcc_64/libexec/moc" % QT_VER

# EVM address. This moves around (DHCP, different board); ping first rather
# than trusting an old value. Every tab reads this one constant.
DEFAULT_EVM_IP = "192.xxx.xx.xx"

# ssh options: BatchMode fails fast instead of blocking on a password prompt
# when no key is present; accept-new skips the first-connection question.
SSH_OPTS = ("-o BatchMode=yes -o StrictHostKeyChecking=accept-new "
            "-o ConnectTimeout=8")


# ----------------------------------------------------------------------------
# ANSI stripping
# ----------------------------------------------------------------------------
_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def strip_ansi(s):
    """Drop ANSI control codes so they do not pollute the log widget."""
    return _ANSI.sub("", s)


# ----------------------------------------------------------------------------
# Path handling
# ----------------------------------------------------------------------------
def _trim_trailing_slash(p):
    """Trim trailing slashes, but keep root "/" itself."""
    if len(p) > 1:
        p = p.rstrip("/")
        if not p:
            p = "/"
    return p


def win_to_wsl_path(raw):
    r"""Turn user input into (wsl_path, distro).

    Accepts:
      * drive letters:  C:\X\Y                ->  /mnt/c/X/Y
      * UNC:            \\wsl$\<distro>\X     ->  /X   (distro=<distro>)
      * native POSIX:   /opt/ti/...           ->  unchanged

    distro is non-empty only for the UNC form.
    """
    if raw is None:
        return "", ""
    s = raw.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        s = s[1:-1].strip()
    if not s:
        return "", ""

    unified = s.replace("\\", "/")
    m = re.match(r"^/{2,}(wsl\$|wsl\.localhost)/+([^/]+)(/.*)?$", unified,
                 re.IGNORECASE)
    if m:
        distro = m.group(2)
        remainder = m.group(3) or ""
        return "/" + remainder.lstrip("/"), distro
    m = re.match(r"^([A-Za-z]):/(.*)$", unified)
    if m:
        return "/mnt/" + m.group(1).lower() + "/" + m.group(2), ""
    if unified.startswith("/"):
        return unified, ""
    return unified, ""


# ----------------------------------------------------------------------------
# WSL command assembly
# ----------------------------------------------------------------------------
def wsl_argv(distro, bash_cmd, user=None):
    """Build: wsl.exe [-d <distro>] [-u <user>] -e bash -lc "<cmd>"."""
    argv = ["wsl.exe"]
    if distro:
        argv += ["-d", distro]
    if user:
        argv += ["-u", user]
    argv += ["-e", "bash", "-lc", bash_cmd]
    return argv


def shq(path):
    """Single-quote a string for the shell. Everything user-supplied that
    reaches a shell goes through this."""
    return "'" + path.replace("'", "'\\''") + "'"


def _no_window_flags():
    return (subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)


def list_wsl_distros():
    """List installed distros via `wsl.exe -l -q`, whose output is UTF-16LE."""
    try:
        cp = subprocess.run(["wsl.exe", "-l", "-q"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            creationflags=_no_window_flags(), timeout=15)
    except Exception:
        return []
    raw = cp.stdout or b""
    # Decide the encoding by looking for NULs in the first 64 bytes, so a
    # (rare) UTF-8 stream is not misread as UTF-16.
    if b"\x00" in raw[:64]:
        text = raw.decode("utf-16-le", errors="replace")
    else:
        text = raw.decode("utf-8", errors="replace")
    names = []
    for line in text.replace("\x00", "").splitlines():
        n = line.strip().strip("\ufeff").lstrip("* ").strip()
        if n:
            names.append(n)
    return names


def detect_wsl_user(distro):
    """The default (non-root) WSL user, i.e. who a build actually runs as.
    Returns "" on failure or when that user is already root, meaning no chown
    is needed after the install."""
    try:
        cp = subprocess.run(wsl_argv(distro, "id -un"),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace",
                            creationflags=_no_window_flags(), timeout=15)
    except Exception:
        return ""
    lines = [x.strip() for x in (cp.stdout or "").splitlines() if x.strip()]
    name = lines[-1] if lines else ""     # last line: skip profile noise
    if not name or name == "root":
        return ""
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.\-]*", name):
        return ""
    return name


# ============================================================================
# Installer command builders  (tab 1)
# ============================================================================
def build_sdk_install_cmd(bin_wsl, prefix, lang, copy_first, chown_user=""):
    """bash script for the silent TI SDK install (set -e, aborts on the first
    failure). Only validated strings are interpolated, and every one of them
    goes through shq().

    chown_user is the default WSL user a build runs as. The install runs as
    root, so the SDK ends up root-owned; a non-root build then hits EACCES
    writing into example-applications (build/, build-native/, Release/). Hand
    that subtree over afterwards. Best-effort: a failure here does not fail
    the install. Skipped when empty or root.
    """
    b = shq(bin_wsl)
    p = shq(prefix)
    lang_q = shq(lang)
    parent = os.path.dirname(prefix.rstrip("/")) or "/"
    parent_q = shq(parent)

    lines = ["set -e"]
    if copy_first:
        lines += [
            "echo '== Copying the installer into WSL ext4 "
            "(faster than 9p, needs ~4.5GB more) ... =='",
            "TMPDIR_BIN=\"$(mktemp -d)\"",
            # Clean up on any exit path, so a failure does not strand ~4.5GB.
            "trap 'rm -rf \"$TMPDIR_BIN\"' EXIT",
            "cp %s \"$TMPDIR_BIN/installer.bin\"" % b,
            "chmod +x \"$TMPDIR_BIN/installer.bin\"",
        ]
        run_bin = "\"$TMPDIR_BIN/installer.bin\""
    else:
        # /mnt/c mounted without metadata can drop the execute bit.
        lines.append("chmod +x %s 2>/dev/null || true" % b)
        run_bin = b

    lines += [
        "echo '== Target directory: '%s' =='" % p,
        "mkdir -p %s" % parent_q,
        "echo '== Starting the silent install (--mode unattended). "
        "Takes 10-40 minutes. It prints no progress -- that is normal; "
        "watch the timer below to confirm it is still running. ... =='",
        "%s --mode unattended --unattendedmodeui none --prefix %s "
        "--installer-language %s" % (run_bin, p, lang_q),
        "echo '== Installer finished (rc=0), verifying... =='",
        "if [ -f %s/linux-devkit/environment-setup ]; then "
        "echo '[OK] environment-setup found, SDK installed'; "
        "else echo '[X] environment-setup missing, install may be incomplete'; "
        "exit 1; fi" % p,
    ]
    if chown_user and chown_user != "root":
        u = shq(chown_user)
        lines.append("echo '== Handing example-applications to build user '%s"
                     "' (so non-root builds can write) ... =='" % u)
        lines.append("chown -R %s:%s %s/example-applications 2>/dev/null "
                     "|| true" % (u, u, p))
    # The temp copy is removed by the EXIT trap above, failures included.
    return "\n".join(lines)


def build_qt_install_cmd():
    """bash script installing the Qt host toolchain through aqtinstall."""
    return "\n".join([
        "set -e",
        "echo '== Installing Qt %s host toolchain (aqtinstall -> /opt/Qt). "
        "Takes 2-5 minutes... =='" % QT_VER,
        "export DEBIAN_FRONTEND=noninteractive",
        "apt-get update",
        "apt-get install -y python3-venv python3-pip",
        "test -d /opt/qt-aqt-venv || python3 -m venv /opt/qt-aqt-venv",
        "/opt/qt-aqt-venv/bin/pip install --upgrade pip aqtinstall",
        "/opt/qt-aqt-venv/bin/aqt install-qt linux desktop %s linux_gcc_64 "
        "-O /opt/Qt" % QT_VER,
        "echo '== Verifying moc =='",
        "%s --version" % shq(QT_MOC),
        "echo '[OK] Qt %s host installed (launcher cross build can run)'"
        % QT_VER,
    ])


def build_hosttools_install_cmd():
    """bash script installing build-essential, as root.

    The aarch64 cross compiler and cmake already ship inside the TI SDK, so
    this is not what compiles the target binary. It is here for the host-side
    tooling a build still reaches for -- make, and the `file` used by the
    project check to report an artifact's architecture.
    """
    return "\n".join([
        "set -e",
        "echo '== Installing host build tools (build-essential + file). "
        "Takes 1-3 minutes... =='",
        "export DEBIAN_FRONTEND=noninteractive",
        "apt-get update",
        "apt-get install -y build-essential file",
        "echo '== Verifying =='",
        "gcc --version | head -1",
        "make --version | head -1",
        "echo '[OK] Host build tools installed'",
    ])


def build_verify_cmd(prefix):
    """bash script checking the TI SDK, the Qt host toolchain and host gcc."""
    p = shq(prefix)
    gcc = ("%s/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/"
           "aarch64-oe-linux/aarch64-oe-linux-gcc" % prefix)
    return "\n".join([
        "echo '== TI SDK =='",
        "if [ -d %s ]; then echo '[OK] SDK directory present'; "
        "else echo '[X] SDK directory not found'; fi" % p,
        "if [ -f %s/linux-devkit/environment-setup ]; then "
        "echo '[OK] environment-setup present'; "
        "else echo '[X] environment-setup missing'; fi" % p,
        "GCC=%s" % shq(gcc),
        "if [ -x \"$GCC\" ]; then printf '[OK] cross compiler: '; "
        "\"$GCC\" --version | head -1; "
        "else echo '[X] aarch64 cross compiler not found'; fi",
        "echo '== Qt %s host (for the launcher cross build) =='" % QT_VER,
        "if [ -x %s ]; then printf '[OK] '; %s --version; "
        "else echo '[!] Qt %s not installed -- the launcher cross build needs "
        "it; press \"2. Install Qt\"'; fi" % (shq(QT_MOC), shq(QT_MOC), QT_VER),
        "echo '== Host build tools =='",
        "if command -v gcc >/dev/null 2>&1; then printf '[OK] '; "
        "gcc --version | head -1; "
        "else echo '[!] no host gcc -- press \"3. Build tools\"'; fi",
        "if command -v make >/dev/null 2>&1; then printf '[OK] '; "
        "make --version | head -1; "
        "else echo '[!] no make -- press \"3. Build tools\"'; fi",
    ])


# ============================================================================
# SSH plumbing
# ============================================================================
def build_ssh_cmd(ip, remote_script):
    """WSL-side bash: ssh <opts> root@<ip> '<remote_script>'.

    The whole remote script is wrapped in single quotes by shq(), so it is the
    EVM's shell that parses it -- $VAR expands on the board, not here.
    """
    return "ssh %s root@%s %s" % (SSH_OPTS, shq(ip), shq(remote_script))


def _unshq(s):
    """Undo shq(): strip the outer quotes and turn '\\'' back into '."""
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("'\\''", "'")
    return s


def _split_top_semicolons(script):
    """Split a shell script on its *top-level* semicolons, for display.

    Honours '...', "...", $(...)/(...) and backslash escapes inside double
    quotes, so a ; nested in a quote or a subshell is not a split point --
    splitting there would produce something that no longer runs. Each segment
    keeps its trailing ; or ;; (;; ends a case branch and is not torn in two),
    so "".join(result) == script exactly.
    """
    segs, buf = [], []
    i, n = 0, len(script)
    sq = dq = False        # inside single / double quotes
    depth = 0              # ( ) / $( ) nesting
    while i < n:
        c = script[i]
        if sq:
            buf.append(c)
            i += 1
            if c == "'":
                sq = False
            continue
        if dq:
            buf.append(c)
            if c == "\\" and i + 1 < n:
                buf.append(script[i + 1])
                i += 2
                continue
            if c == '"':
                dq = False
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            buf.append(c)
            buf.append(script[i + 1])
            i += 2
            continue
        if c == "'":
            sq = True
            buf.append(c)
            i += 1
            continue
        if c == '"':
            dq = True
            buf.append(c)
            i += 1
            continue
        if c == "(":
            depth += 1
            buf.append(c)
            i += 1
            continue
        if c == ")":
            if depth > 0:
                depth -= 1
            buf.append(c)
            i += 1
            continue
        if c == ";" and depth == 0:
            if i + 1 < n and script[i + 1] == ";":
                buf.append(";;")
                segs.append("".join(buf))
                buf = []
                i += 2
                continue
            buf.append(";")
            segs.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    if buf:
        segs.append("".join(buf))
    return segs


def _format_remote_script(raw, base, unit="    "):
    """Break a remote script at top-level semicolons and indent it by
    if/then/else/elif/fi and for/while/do/done nesting.

    Presentation only: the split is lossless and this just adds or removes
    whitespace, so flattening the result (dropping the \\ continuations) gives
    back something equivalent that still runs when pasted.
    """
    segs = [s.strip() for s in _split_top_semicolons(raw) if s.strip()]
    lines = []                          # [indent level, text]
    level = 0
    for s in segs:
        # A segment starting with then/do: join the keyword onto the previous
        # line, indent the body that follows (elif's then does not add a level)
        m = re.match(r"(then|do)\b\s*(.*)$", s, re.S)
        if m and lines:
            kw, rest = m.group(1), m.group(2).strip()
            prev_first = (lines[-1][1].split() or [""])[0]
            lines[-1][1] += " " + kw
            if not (kw == "then" and prev_first == "elif"):
                level += 1
            if rest:
                lines.append([level, rest])
                rt = rest.rstrip(";").split()
                if rt and rt[-1] in ("then", "do"):
                    level += 1
            continue
        # A segment starting with else (not elif): else on its own line one
        # level out, body back at the current level.
        if re.match(r"else\b", s) and not s.startswith("elif"):
            rest = s[4:].strip()
            lines.append([max(0, level - 1), "else"])
            if rest:
                lines.append([level, rest])
            continue
        toks = s.rstrip(";").split()
        first = toks[0] if toks else ""
        last = toks[-1] if toks else ""
        if first in ("fi", "done", "esac"):
            level = max(0, level - 1)
        plvl = level
        if first == "elif":
            plvl = max(0, level - 1)
        lines.append([plvl, s])
        if last in ("then", "do") and first != "elif":
            level += 1
    out = []
    for idx, (plvl, txt) in enumerate(lines):
        cont = " \\" if idx < len(lines) - 1 else ""
        # Line 0 sits right after the opening quote that shq() adds.
        out.append((txt if idx == 0 else base + unit * plvl + txt) + cont)
    return "\n".join(out)


def cmd_multiline(bash_cmd, indent="    "):
    """Re-flow an ssh command over several lines for the log.

    First line is ssh (or sshpass -e ssh) plus its first -o; each remaining
    -o, the user@host, and the quoted remote script each get their own line,
    continued with a trailing backslash. Pasting the result into bash, Tera
    Term or PuTTY still runs the same single command.

    Handles both key login (ssh ...) and password login (sshpass -e ssh ...);
    options are read from the command itself rather than assumed. Anything
    that is not in ssh form is returned unchanged.
    """
    m = re.match(r"^((?:sshpass\s+-e\s+)?ssh)\s+(.*)$", bash_cmd, re.S)
    if not m:
        return bash_cmd
    head, rest = m.group(1), m.group(2)
    toks = rest.split(" ")
    opts, i = [], 0
    while i + 1 < len(toks) and toks[i] == "-o":
        opts.append("-o " + toks[i + 1])
        i += 2
    if i >= len(toks):
        return bash_cmd                      # no user@host: leave it alone
    userhost = toks[i]
    i += 1
    script = " ".join(toks[i:])              # the shq'd '<remote_script>'
    lines = [head + ((" " + opts[0]) if opts else "") + " \\"]
    lines += [indent + o + " \\" for o in opts[1:]]
    if script:
        lines.append(indent + userhost + " \\")
        pretty = _format_remote_script(_unshq(script), " " * (len(indent) + 1))
        lines.append(indent + shq(pretty))
    else:
        lines.append(indent + userhost)
    return "\n".join(lines)


# ============================================================================
# CC3351 Wi-Fi remote scripts  (tab 2)
# ============================================================================
# CC3351 M.2: Wi-Fi rides SDIO (MMC2) -> cc33xx_sdio -> cc33xx -> mac80211 ->
# wlan0. To test reachability, force the traffic out of wlan0 (ping -I wlan0)
# and use a *hostname* rather than an IP so DNS is exercised too. The EVM
# usually has eth0 up as well; without -I the packets leave over the wire and
# Wi-Fi is never touched.
DEFAULT_PING_HOST = "www.google.com"


def remote_wifi_status():
    """wlan0 address, associated AP/SSID/signal (iw link), default route."""
    return (
        "echo '== wlan0 interface =='; "
        "ip -br addr show wlan0 2>/dev/null || echo '  (no wlan0)'; "
        "echo; echo '== association (iw dev wlan0 link) =='; "
        "iw dev wlan0 link 2>/dev/null || echo '  (not associated / no iw)'; "
        "echo; echo '== default route =='; "
        "ip route 2>/dev/null | grep -E 'default|wlan0' "
        "|| echo '  (no matching route)'"
    )


def remote_wifi_ping(host):
    """Reachability over wlan0: ping a hostname, forced out of the Wi-Fi
    interface, which checks association + route + DNS + the outside world in
    one shot. Ends with a verdict."""
    return (
        "echo '== ping %s via wlan0 (hostname -> also checks DNS + route) =='; "
        "ping -I wlan0 -c 4 -W 3 %s; rc=$?; echo; "
        "if [ $rc -eq 0 ]; then echo '[OK] Wi-Fi reaches the outside world'; "
        "else echo '[X] Wi-Fi is not getting through. "
        "\"Destination Host Unreachable\" = cannot even reach the Wi-Fi "
        "gateway; \"100%% packet loss\" = packets leave but nothing answers'; "
        "fi"
    ) % (host, host)


def remote_wifi_scan():
    """Scan for nearby APs: SSID / signal / freq."""
    return (
        "echo '== scanning for APs (iw dev wlan0 scan) =='; "
        "iw dev wlan0 scan 2>&1 | grep -E 'SSID|signal|freq' | head -60 "
        "|| echo '[!] scan failed (wlan0 down or busy)'"
    )


def remote_wifi_driver():
    """Driver, firmware and regulatory state."""
    return (
        "echo '== regulatory domain (iw reg get) =='; "
        "iw reg get 2>/dev/null | head -8; "
        "echo; echo '== firmware blobs (/lib/firmware/ti-connectivity) =='; "
        "ls /lib/firmware/ti-connectivity/ 2>/dev/null; "
        "echo -n 'cc33xx-nvs.bin: '; "
        "if [ -f /lib/firmware/ti-connectivity/cc33xx-nvs.bin ]; "
        "then echo 'present'; "
        "else echo 'absent -> driver reports error -2 and Linux falls back to "
        "a default MAC (basic connectivity still works)'; fi; "
        "echo; echo '== dmesg: cc33xx / wlan / nvs / regulatory =='; "
        "dmesg 2>/dev/null | grep -iE 'cc33xx|wlan0|nvs|regulatory|sdio.*0097' "
        "| tail -25"
    )


# ============================================================================
# Cross-compile + deploy command builders  (tab 3)
# ============================================================================
# The project path is not hard-coded. Every builder below takes proj_dir plus
# the script names; EdgePilot_Github_Demo is only the default in the form.
#   build script : lives in the project, sources the SDK env, cross-compiles
#                  for aarch64 (e.g. build.sh -> build/edgepilot-launcher).
#   deploy script: lives in the project, takes the board address from EVM_IP,
#                  and uses WSL's own ssh keys to reach it. This tool does not
#                  look inside it.
# These run inside WSL directly, not through this tool's ssh wrapper. When the
# project path is given in \\wsl$\<distro>\... UNC form, the distro is pulled
# out of it and wsl.exe -d <distro> is used.
def _proj_guard(proj_dir):
    """cd into the project, abort if it is not there."""
    return ("cd %s || { echo '[X] project directory not found: '%s; "
            "echo '    Check the \"Project path\" field above, or press "
            "\"Scan projects\" to list what is available.'; "
            "exit 1; }; " % (shq(proj_dir), shq(proj_dir)))


def _script_guard(script, kind):
    """Confirm the script exists inside the project."""
    return ("[ -f %s ] || { echo '[X] no %s script in the project: '%s; "
            "echo '    Change the \"%s script\" field above, or press "
            "\"4. Check\" to list every .sh in the project.'; "
            "exit 1; }; " % (shq("./" + script), kind, shq(script), kind))


def build_only_cmd(proj_dir, build_sh=DEFAULT_BUILD_SH):
    """Cross-compile only: cd, source the SDK env, run the build script."""
    return (_proj_guard(proj_dir) + _script_guard(build_sh, "build") +
            "echo '== Cross build (source SDK env, aarch64) =='; "
            "echo '   project      : '%s; echo '   build script : '%s; "
            "source %s; bash %s"
            % (shq(proj_dir), shq(build_sh), shq(ENV_SETUP),
               shq("./" + build_sh)))


def deploy_only_cmd(proj_dir, ip, deploy_sh=DEFAULT_DEPLOY_SH):
    """Deploy an already-built artifact: EVM_IP=<ip> bash <deploy script>."""
    return (_proj_guard(proj_dir) + _script_guard(deploy_sh, "deploy") +
            "echo '== Deploying to EVM %s =='; "
            "echo '   project       : '%s; echo '   deploy script : '%s; "
            "EVM_IP=%s bash %s"
            % (ip, shq(proj_dir), shq(deploy_sh), shq(ip),
               shq("./" + deploy_sh)))


def build_deploy_cmd(proj_dir, ip, build_sh=DEFAULT_BUILD_SH,
                     deploy_sh=DEFAULT_DEPLOY_SH):
    """Build then deploy, chained under set -e so a failed build never
    deploys."""
    return (_proj_guard(proj_dir) + _script_guard(build_sh, "build") +
            _script_guard(deploy_sh, "deploy") +
            "echo '== [1/2] Cross build (source SDK env, aarch64) =='; "
            "echo '   project       : '%s; echo '   build script  : '%s; "
            "echo '   deploy script : '%s; "
            "source %s; set -e; bash %s; "
            "echo; echo '== [2/2] Deploying to EVM %s =='; "
            "EVM_IP=%s bash %s; "
            "echo; echo '[OK] Cross build + deploy finished.'"
            % (shq(proj_dir), shq(build_sh), shq(deploy_sh), shq(ENV_SETUP),
               shq("./" + build_sh), ip, shq(ip), shq("./" + deploy_sh)))


def project_check_cmd(proj_dir, build_sh, deploy_sh):
    """Read-only check: no build, no board access. Reports whether the
    directory and both scripts exist, which .sh files could serve as scripts,
    the build-system marker files, any existing cross-built artifacts and
    their architecture, and whether the SDK env and Qt host are ready.

    Press this first when pointing the tab at a new project -- it tells you
    what to put in the script fields.
    """
    return (
        "D=%s; B=%s; P=%s; "
        "echo \"== Checking project: $D ==\"; "
        "[ -d \"$D\" ] || { echo '[X] directory does not exist (check the "
        "path, or press \"Scan projects\")'; exit 1; }; "
        "echo '[OK] directory exists'; cd \"$D\" || exit 1; "
        "for s in \"$B\" \"$P\"; do "
        "if [ -f \"$s\" ]; then echo \"[OK] script present: $s\"; "
        "else echo \"[X] script missing: $s\"; fi; done; "
        "echo; echo '== .sh files in the project (candidates for the script "
        "fields) =='; "
        "find . -maxdepth 2 -name '*.sh' -type f 2>/dev/null "
        "| sed 's|^\\./||' | sort | head -40; "
        "echo; echo '== build-system markers =='; "
        "for f in CMakeLists.txt Makefile meson.build; do "
        "[ -f \"$f\" ] && echo \"  [OK] $f\"; done; "
        "[ -f CMakeLists.txt ] || [ -f Makefile ] || [ -f meson.build ] "
        "|| echo '  (no CMakeLists.txt / Makefile / meson.build)'; "
        "echo; echo '== existing cross-built artifacts (build/) =='; "
        "if [ -d build ]; then ls -lh build 2>/dev/null | head -12; "
        "if command -v file >/dev/null 2>&1; then echo '  -- architecture --'; "
        "for f in build/*; do [ -f \"$f\" ] && [ -x \"$f\" ] && "
        "{ printf '  %%s : ' \"$f\"; file -b \"$f\" | cut -c1-58; }; done; fi; "
        "else echo '  (no build/ yet -- press \"1. Cross build\")'; fi; "
        "echo; echo '== SDK env / Qt host =='; "
        "[ -f %s ] && echo '[OK] SDK environment-setup present' "
        "|| echo '[X] SDK environment-setup not found (see the Install tab)'; "
        "[ -x %s ] && echo '[OK] Qt host moc present' "
        "|| echo '[!] Qt %s host not installed (needed for Qt cross builds, "
        "see the Install tab)'"
        % (shq(proj_dir), shq(build_sh), shq(deploy_sh),
           shq(ENV_SETUP), shq(QT_MOC), QT_VER)
    )


def project_scan_cmd(root_dir, build_sh):
    """List directories under root_dir (maxdepth 4) that contain the build
    script, one per line prefixed with "PROJ " so the GUI can parse them into
    the project dropdown. Read-only."""
    return (
        "R=%s; B=%s; "
        "echo \"== Scanning $R for projects containing $B ==\"; "
        "[ -d \"$R\" ] || { echo \"[X] scan root does not exist: $R\"; "
        "exit 1; }; "
        "find \"$R\" -maxdepth 4 -type f -path \"*/$B\" -printf '%%p\\n' "
        "2>/dev/null | sed \"s|/$B\\$||\" | sort -u | sed 's|^|PROJ |'; "
        "echo '== scan finished =='"
        % (shq(root_dir), shq(build_sh))
    )


# ============================================================================
# Password-login SSH  (tab 4)
# ============================================================================
# Every other tab logs in with a key (BatchMode=yes). This one is for a board
# that only takes a password: sshpass reads it from the SSHPASS environment
# variable (-e), so it never lands in the command string, in `ps`, or in the
# log. Public-key auth is turned off so the server cannot silently accept a
# key instead and hide a wrong password.
#   Requires sshpass inside WSL:  sudo apt-get install -y sshpass
#
# Note the EVM runs dropbear, not OpenSSH: there is no /etc/ssh/sshd_config
# and no sshd binary, so do not go looking for one when password login fails.
# dropbear's password policy lives in its command-line flags (extra flags come
# from $DROPBEAR_EXTRA_ARGS in /etc/default/dropbear):
#     -s  disable all password login      -g  disable root password login
#     -w  refuse root login entirely      -B  allow blank passwords
# Check with `ps aux | grep dropbear` on the board. Without -s/-g/-w, root
# password login is enabled and a failure is almost always a wrong password;
# `passwd -S <user>` shows whether the account has one at all. dropbear is
# socket-activated, so `systemctl is-active sshd` reporting inactive is normal
# and does not mean SSH is off.
PW_SSH_OPTS = ("-o BatchMode=no -o PubkeyAuthentication=no "
               "-o PreferredAuthentications=password,keyboard-interactive "
               "-o NumberOfPasswordPrompts=3 -o StrictHostKeyChecking=accept-new "
               "-o ConnectTimeout=8")
DEFAULT_PW_USER = "root"
PW_CONN_TEST = "echo SSH_OK; hostname; uname -a"
PW_OS_VER = ("echo '== /etc/os-release =='; cat /etc/os-release 2>/dev/null "
             "|| echo '  (no /etc/os-release)'; echo; "
             "echo '== /proc/version =='; cat /proc/version 2>/dev/null "
             "|| echo '  (cannot read /proc/version)'")

CUSTOM_CMD_PRESETS = [
    ("System summary",
     "echo '== uname =='; uname -a; echo '== os-release =='; "
     "head -3 /etc/os-release 2>/dev/null; echo '== uptime =='; uptime; "
     "echo '== mem =='; free -h; echo '== rootfs =='; df -h / 2>/dev/null"),
    ("hwmon temperatures",
     "for h in /sys/class/hwmon/hwmon*; do n=$(cat \"$h/name\" 2>/dev/null); "
     "t=$(cat \"$h/temp1_input\" 2>/dev/null); "
     "[ -n \"$t\" ] && echo \"$n: $((t/1000)) C\"; done"),
]


def build_pw_ssh_cmd(user, ip, remote_script):
    """What actually runs: sshpass -e ssh <opts> user@ip '<script>'. The
    password arrives through SSHPASS (-e), never in the command string."""
    return "sshpass -e ssh %s %s@%s %s" % (PW_SSH_OPTS, shq(user), shq(ip),
                                           shq(remote_script))


def build_pw_ssh_display(user, ip, remote_script):
    """What the log shows: plain ssh, no sshpass and no password, so it can be
    copied into Tera Term or PuTTY, where it will prompt interactively.
    user/ip are already validated to shell-safe characters."""
    return "ssh %s %s@%s %s" % (PW_SSH_OPTS, user, ip, shq(remote_script))


# ============================================================================
# Shared: log widget + streaming execution
# ============================================================================
class LogMixin:
    """Log helpers. The host class must set self.log (and self.root)."""

    def _append(self, text, tag=None):
        self.log.configure(state="normal")
        if tag:
            self.log.insert("end", text, tag)
        else:
            self.log.insert("end", text)
        self.log.see("end")
        self.log.configure(state="disabled")

    def _log_line(self, text, tag=None):
        self._append(text + "\n", tag)

    def _make_log(self, parent):
        log = scrolledtext.ScrolledText(parent, bg=CODE, fg=INK,
                                        insertbackground=INK,
                                        font=("Consolas", 12),
                                        relief="flat", wrap="word")
        log.configure(state="disabled")
        log.tag_configure("err", foreground=RED)
        log.tag_configure("ok", foreground=GREEN)
        log.tag_configure("info", foreground=ACCENT)
        log.tag_configure("warn", foreground=AMBER)
        # "cmd" is the command echo every tab prints before it runs something:
        # accent-coloured and 2pt larger than the output, which together with
        # cmd_multiline's line breaking keeps long ssh commands readable.
        log.tag_configure("cmd", foreground=ACCENT, font=("Consolas", 14))
        return log


class RunnerPanel(LogMixin):
    """Base for every tab that runs one command at a time.

    Model: Popen -> reader thread -> queue -> root.after, so output streams in
    without blocking the UI. Subclasses implement _build_ui(), put the buttons
    that must be disabled while busy into self._action_btns, and start work
    through _launch_remote() (over SSH) or _launch_local() (inside WSL).

    Tasks listed in LOOP_TASKS stream until stopped, so a non-zero return code
    there is an ordinary stop rather than a failure.
    """

    LABELS = {}            # task id -> label used in the status line
    LOOP_TASKS = set()     # tasks that stream until stopped

    def __init__(self, parent, root):
        self.parent = parent
        self.root = root
        self.proc = None
        self.worker = None
        self.q = queue.Queue()
        self.start_time = None
        self.running = False
        self.current_task = None
        self._returncode = None
        self._status_running_text = ""
        self._action_btns = []
        self._distro = ""
        self._build_ui()
        self.root.after(50, self._drain_queue)

    # --- subclasses must override -----------------------------------------
    def _build_ui(self):
        raise NotImplementedError

    # --- small widget factories (one place for the colours) ---------------
    def _mkbtn(self, parent, text, cmd, primary=False, width=12):
        return tk.Button(parent, text=text, command=cmd,
                         bg=(GREEN if primary else PANEL),
                         fg=(CODE if primary else INK),
                         activebackground=ACCENT, activeforeground=CODE,
                         relief="flat", font=("Segoe UI", 10, "bold"),
                         width=width)

    def _mkstop(self, parent):
        return tk.Button(parent, text="Stop", command=self._on_stop, bg=RED,
                         fg=INK, activebackground=AMBER, activeforeground=CODE,
                         relief="flat", font=("Segoe UI", 10, "bold"), width=8,
                         state="disabled")

    def _mkclear(self, parent):
        return tk.Button(parent, text="Clear", command=self._on_clear,
                         bg=PANEL, fg=INK, activebackground=ACCENT,
                         activeforeground=CODE, relief="flat",
                         font=("Segoe UI", 10, "bold"), width=8)

    def _mkstatus_and_log(self, p):
        self.status_var = tk.StringVar(value="Ready.")
        self.status_label = tk.Label(p, textvariable=self.status_var, bg=BG,
                                     fg=MUTED, anchor="w",
                                     font=("Segoe UI", 10))
        self.status_label.pack(side="top", fill="x", padx=12, pady=(2, 4))
        self.log = self._make_log(p)
        self.log.pack(side="top", fill="both", expand=True, padx=10,
                      pady=(2, 10))

    # --- input validation --------------------------------------------------
    def _validate_ip(self, raw):
        s = (raw or "").strip()
        if re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", s):
            if all(0 <= int(o) <= 255 for o in s.split(".")):
                return s
            self._log_line("[error] each IPv4 octet must be 0-255 (got %r)."
                           % raw, "err")
            return None
        if re.fullmatch(r"[A-Za-z0-9.\-]+", s):
            return s
        self._log_line("[error] EVM IP / hostname has illegal characters "
                       "(got %r)." % raw, "err")
        return None

    # --- starting work -----------------------------------------------------
    def _launch_remote(self, ip, remote_script, task, status):
        """Run a script on the board over SSH."""
        if self.running:
            self._log_line("[remote] a task is already running; stop it first.",
                           "warn")
            return
        self._launch(build_ssh_cmd(ip, remote_script), task, status,
                     target="root@%s" % ip, kind="remote")

    def _launch_local(self, bash_cmd, task, status, target, distro=""):
        """Run a command inside WSL (no board involved)."""
        if self.running:
            self._log_line("[local] a task is already running; stop it first.",
                           "warn")
            return
        self._launch(bash_cmd, task, status, target=target, kind="local",
                     distro=distro)

    def _launch(self, bash_cmd, task, status, target, kind="remote",
                display_cmd=None, distro="", user=None):
        argv = wsl_argv(distro, bash_cmd, user=user)
        tagword = "local" if kind == "local" else "remote"
        self._log_line("=" * 64, "info")
        self._log_line("[%s] %s  ->  %s" % (tagword, status, target), "info")
        if distro:
            self._log_line("[%s] WSL distro: %s" % (tagword, distro), "info")
        self._log_line("[%s] command:" % tagword, "info")
        # display_cmd lets the password tab show a plain ssh form with no
        # sshpass and no password in it.
        self._log_line(cmd_multiline(display_cmd or bash_cmd), "cmd")
        self._log_line("=" * 64, "info")
        self.running = True
        self.current_task = task
        self._returncode = None
        self._last_kind = kind          # _rc_hint tailors its advice on this
        self.start_time = time.time()
        self._status_running_text = status
        self._set_buttons_running(True)
        self.status_var.set("%s... 0.0 s" % status)
        self.status_label.config(fg=AMBER)
        self.worker = threading.Thread(target=self._run_worker, args=(argv,),
                                       daemon=True)
        self.worker.start()
        self.root.after(100, self._tick_elapsed)

    def _set_buttons_running(self, running):
        s = "disabled" if running else "normal"
        for b in self._action_btns:
            b.config(state=s)
        self.stop_btn.config(state="normal" if running else "disabled")

    def _run_worker(self, argv):
        try:
            # _proc_env lets a subclass pass environment variables through --
            # the password tab uses it for SSHPASS + WSLENV. None means
            # inherit, which is what every other tab wants.
            self.proc = subprocess.Popen(
                argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
                env=getattr(self, "_proc_env", None),
                creationflags=_no_window_flags())
        except Exception as exc:  # noqa: BLE001
            self.q.put(("err", "[error] could not start wsl.exe: %s" % exc))
            self.q.put(("rc", None))
            self.q.put(("done", None))
            return
        try:
            for raw_line in self.proc.stdout:
                self.q.put(("line", strip_ansi(raw_line.rstrip("\n"))))
        except Exception as exc:  # noqa: BLE001
            self.q.put(("err", "[error] exception while reading output: %s"
                        % exc))
        finally:
            rc = None
            try:
                rc = self.proc.wait()
            except Exception:  # noqa: BLE001
                pass
            self.q.put(("rc", rc))
            self.q.put(("done", None))

    @staticmethod
    def _tag_for(payload):
        """Colour a line of output. The [OK]/[X]/[!] markers the remote
        scripts print are language-neutral on purpose."""
        low = payload.lower()
        p = payload.lstrip()
        if ("error" in low or "fail" in low or "refused" in low
                or "timed out" in low or "permission denied" in low
                or "no route" in low or p.startswith("[X]")):
            return "err"
        if p.startswith("[OK]"):
            return "ok"
        if (payload.startswith("==") or payload.startswith("###")
                or payload.startswith("==>")):
            return "info"
        if "warning" in low or "warn" in low or p.startswith("[!]"):
            return "warn"
        return None

    def _drain_queue(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "line":
                    self._on_line(payload)
                elif kind == "err":
                    self._log_line(payload, "err")
                elif kind == "rc":
                    self._returncode = payload
                elif kind == "done":
                    self._on_finished()
        except queue.Empty:
            pass
        self.root.after(50, self._drain_queue)

    def _on_line(self, payload):
        """Per-line hook. Subclasses that scrape results override this."""
        self._log_line(payload, self._tag_for(payload))

    def _tick_elapsed(self):
        if self.running and self.start_time is not None:
            elapsed = time.time() - self.start_time
            self.status_var.set("%s... %.1f s"
                                % (self._status_running_text, elapsed))
            self.root.after(200, self._tick_elapsed)

    def _on_finished(self):
        elapsed = (time.time() - self.start_time
                   if self.start_time is not None else 0.0)
        rc = getattr(self, "_returncode", None)
        task = self.current_task
        self.running = False
        self.proc = None
        self.current_task = None
        self._set_buttons_running(False)
        label = self.LABELS.get(task, "Task")
        if rc == 0:
            self.status_var.set("%s finished. (%.1f s)" % (label, elapsed))
            self.status_label.config(fg=GREEN)
            self._log_line("[done] %s (rc=0, %.1f s)." % (label, elapsed), "ok")
            self._on_success(task)
        else:
            is_loop_stop = task in self.LOOP_TASKS
            self.status_var.set("%s ended (rc=%s, %.1f s)."
                                % (label, rc, elapsed))
            self.status_label.config(fg=MUTED if is_loop_stop else RED)
            self._log_line("[end] %s (rc=%s, %.1f s).%s"
                           % (label, rc, elapsed, self._rc_hint(rc)),
                           "warn" if is_loop_stop else "err")

    def _on_success(self, task):
        """Hook for a follow-up hint after a clean run."""

    def _rc_hint(self, rc):
        """Turn a return code into advice. Subclasses extend this.

        255 is deliberately not reported as "ssh failed" outright: scp and ssh
        both use it for a *local* problem too -- most commonly `scp: stat
        local "x": No such file or directory`, where the connection was fine
        and the file simply is not in the project. Saying "check the network"
        there sends people looking in the wrong place, so both causes are
        named and the reader is pointed at the output above.
        """
        if rc == 255:
            if getattr(self, "_last_kind", "remote") == "local":
                return ("  The script returned 255. ssh/scp use that both for "
                        "a failed connection and for a local file it could "
                        "not read -- check the lines above for a 'stat local "
                        "... No such file or directory', which means the file "
                        "is missing from the project, not that the board is "
                        "unreachable.")
            return ("  ssh failed: check the EVM IP and the network, and that "
                    "key login is set up (BatchMode never asks for a "
                    "password). Note scp also returns 255 when a *local* file "
                    "is missing -- check the output above for 'stat local'.")
        return ""

    def _on_stop(self):
        if not self.running or self.proc is None:
            return
        self._log_line("[stop] terminating...", "warn")
        try:
            self.proc.terminate()
        except Exception as exc:  # noqa: BLE001
            self._log_line("[stop] terminate failed: %s" % exc, "err")
        try:
            self.proc.kill()
        except Exception:  # noqa: BLE001
            pass

    def _on_clear(self):
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        if not self.running:
            self.status_var.set("Ready.")
            self.status_label.config(fg=MUTED)


# ============================================================================
# Tab bar that wraps onto more than one row
# ============================================================================
class MultiRowTabs:
    """A tab bar that moves onto a second row when the tabs no longer fit.

    ttk.Notebook is not used because its tab bar does not wrap: tabs that do
    not fit are simply cut off, and the window has to be dragged very wide to
    reach the later ones. This draws its own button row instead, accumulating
    real text widths and starting a new row when the available width runs out.

    The content frames are stacked in one grid cell and switched with
    tkraise() rather than pack_forget(), so scroll position, log contents and
    running work all survive moving away from a tab and back.
    """

    def __init__(self, root, initial_width=1020, gap=2):
        self.root = root
        self.gap = gap
        self._initial_width = initial_width
        self.bar = tk.Frame(root, bg=BG)
        self.bar.pack(side="top", fill="x")
        self.body = tk.Frame(root, bg=BG)
        self.body.pack(side="top", fill="both", expand=True)
        self.body.rowconfigure(0, weight=1)
        self.body.columnconfigure(0, weight=1)
        self._font = tkfont.Font(family="Segoe UI", size=10, weight="bold")
        self._tabs = []          # [text, frame, button]
        self._rows = []
        self._current = None
        self._last_width = 0
        root.bind("<Configure>", self._on_configure)

    def add(self, text):
        """Add a tab and return the content frame (like Notebook.add)."""
        frame = tk.Frame(self.body, bg=BG)
        frame.grid(row=0, column=0, sticky="nsew")
        self._tabs.append([text, frame, None])
        self._relayout()
        if self._current is None:
            self.select(0)
        else:
            # Stacked in a grid, the most recently added frame lands on top,
            # so raise the current one again after every add -- otherwise the
            # view jumps to the last tab built while the highlight stays put.
            self._tabs[self._current][1].tkraise()
        return frame

    def select(self, idx):
        if not (0 <= idx < len(self._tabs)):
            return
        self._current = idx
        self._tabs[idx][1].tkraise()
        self._paint()

    def _paint(self):
        for i, (_text, _frame, btn) in enumerate(self._tabs):
            if btn is None:
                continue
            sel = (i == self._current)
            btn.config(bg=ACCENT if sel else PANEL, fg=CODE if sel else INK)

    def _avail_width(self):
        w = self.root.winfo_width()
        return (w if w > 1 else self._initial_width) - 8

    @staticmethod
    def _pack_rows(widths, avail, target=None):
        """Fill rows in order and return how many tabs land in each. target is
        a soft limit used for balancing; avail is the hard one."""
        rows, used, n = [], 0, 0
        for w in widths:
            wrap = n > 0 and (used + w > avail
                              or (target is not None and used + w > target))
            if wrap:
                rows.append(n)
                n, used = 0, 0
            n += 1
            used += w
        if n:
            rows.append(n)
        return rows

    def _relayout(self):
        for r in self._rows:
            r.destroy()
        self._rows = []
        avail = self._avail_width()
        widths = [self._font.measure(t[0]) + 34 + self.gap * 2
                  for t in self._tabs]

        # Two-pass packing. Plain greedy fills the early rows and leaves the
        # last one nearly empty, so: find the minimum row count R greedily,
        # then re-pack with total/R as a per-row target. The average can spill
        # into an R+1th row when the tabs differ a lot in width, so loosen the
        # target step by step and take the first result that is still R rows.
        # It never uses more rows than greedy, so balancing never costs height.
        plan = self._pack_rows(widths, avail)
        rows_n = len(plan)
        if rows_n > 1:
            avg = sum(widths) / rows_n
            for slack in (1.00, 1.05, 1.10, 1.15, 1.25, 1.4):
                cand = self._pack_rows(widths, avail, avg * slack)
                if len(cand) == rows_n:
                    plan = cand
                    break

        idx = 0
        for count in plan:
            row = tk.Frame(self.bar, bg=BG)
            row.pack(side="top", fill="x")
            self._rows.append(row)
            for _ in range(count):
                tab = self._tabs[idx]
                btn = tk.Button(row, text=tab[0],
                                command=lambda k=idx: self.select(k),
                                bg=PANEL, fg=INK, activebackground=ACCENT,
                                activeforeground=CODE, relief="flat", bd=0,
                                padx=14, pady=6, font=("Segoe UI", 10, "bold"),
                                cursor="hand2")
                btn.pack(side="left", padx=self.gap, pady=self.gap)
                tab[2] = btn
                idx += 1
        self._paint()

    def _on_configure(self, ev):
        # Only the main window's width matters, and only when it moves enough
        # to be worth rebuilding the buttons.
        if ev.widget is not self.root:
            return
        if abs(ev.width - self._last_width) < 24:
            return
        self._last_width = ev.width
        self._relayout()


# ============================================================================
# Tab 1 - Install SDK
# ============================================================================
class SdkInstallPanel(RunnerPanel):
    LABELS = {"sdk": "TI SDK install", "qt": "Qt host install",
              "hosttools": "Host build tools install", "verify": "Verification"}

    def _build_ui(self):
        pad = {"padx": 8, "pady": 4}
        p = self.parent

        tk.Label(p, text="Install the TI Processor SDK into WSL (silent)",
                 bg=BG, fg=ACCENT, font=("Segoe UI", 13, "bold")
                 ).pack(side="top", anchor="w", padx=12, pady=(10, 2))
        tk.Label(p, text="Runs InstallBuilder in unattended mode, as root "
                         "inside WSL (the target is under /opt). The launcher "
                         "cross build additionally needs the Qt host "
                         "toolchain - button 2 below.",
                 bg=BG, fg=MUTED, font=("Segoe UI", 9), justify="left",
                 wraplength=960).pack(side="top", anchor="w", padx=12,
                                      pady=(0, 6))

        form = tk.Frame(p, bg=PANEL)
        form.pack(side="top", fill="x", padx=10, pady=4)
        form.columnconfigure(1, weight=1)

        tk.Label(form, text="Installer (.bin):", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=0, column=0, sticky="w", **pad)
        self.bin_var = tk.StringVar(value=DEFAULT_BIN_WIN)
        tk.Entry(form, textvariable=self.bin_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 10), relief="flat"
                 ).grid(row=0, column=1, sticky="we", **pad)
        tk.Button(form, text="Browse", command=self._on_browse_bin,
                  bg=PANEL, fg=INK, activebackground=ACCENT,
                  activeforeground=CODE, relief="ridge", width=9
                  ).grid(row=0, column=2, **pad)

        tk.Label(form, text="WSL distro:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=1, column=0, sticky="w", **pad)
        self.distro_var = tk.StringVar(value=DEFAULT_DISTRO)
        self.distro_combo = ttk.Combobox(form, textvariable=self.distro_var,
                                         values=[DEFAULT_DISTRO], width=24)
        self.distro_combo.grid(row=1, column=1, sticky="w", **pad)
        tk.Button(form, text="Refresh", command=self._refresh_distros,
                  bg=PANEL, fg=INK, activebackground=ACCENT,
                  activeforeground=CODE, relief="ridge", width=9
                  ).grid(row=1, column=2, **pad)

        tk.Label(form, text="Install prefix:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=2, column=0, sticky="w", **pad)
        self.prefix_var = tk.StringVar(value=DEFAULT_PREFIX)
        tk.Entry(form, textvariable=self.prefix_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 10), relief="flat"
                 ).grid(row=2, column=1, sticky="we", **pad)

        opt = tk.Frame(form, bg=PANEL)
        opt.grid(row=3, column=0, columnspan=3, sticky="we", **pad)
        tk.Label(opt, text="Installer language:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).pack(side="left")
        self.lang_var = tk.StringVar(value=DEFAULT_LANG)
        ttk.Combobox(opt, textvariable=self.lang_var, values=LANG_CHOICES,
                     state="readonly", width=8).pack(side="left", padx=(6, 16))
        self.copy_var = tk.BooleanVar(value=False)
        tk.Checkbutton(opt,
                       text="Copy the installer into WSL first "
                            "(faster, needs ~4.5GB more)",
                       variable=self.copy_var, bg=PANEL, fg=INK,
                       activebackground=PANEL, activeforeground=INK,
                       selectcolor=CODE, font=("Segoe UI", 9)).pack(side="left")

        btns = tk.Frame(p, bg=BG)
        btns.pack(side="top", fill="x", padx=10, pady=(6, 2))
        self.install_btn = self._mkbtn(btns, "1. Install TI SDK",
                                       self._on_install_sdk, primary=True,
                                       width=16)
        self.qt_btn = self._mkbtn(btns, "2. Install Qt", self._on_install_qt,
                                  width=13)
        self.hosttools_btn = self._mkbtn(btns, "3. Build tools",
                                         self._on_install_hosttools, width=13)
        self.verify_btn = self._mkbtn(btns, "Verify", self._on_verify, width=9)
        self.stop_btn = self._mkstop(btns)
        self.clear_btn = self._mkclear(btns)
        for b in (self.install_btn, self.qt_btn, self.hosttools_btn,
                  self.verify_btn, self.stop_btn, self.clear_btn):
            b.pack(side="left", padx=4)
        self._action_btns = [self.install_btn, self.qt_btn,
                             self.hosttools_btn, self.verify_btn]

        self._mkstatus_and_log(p)

    # --- browse / distro ---------------------------------------------------
    def _on_browse_bin(self):
        chosen = filedialog.askopenfilename(
            title="Select the TI SDK installer",
            filetypes=[("SDK installer", "*.bin"), ("All files", "*.*")])
        if chosen:
            self.bin_var.set(chosen)

    def _refresh_distros(self):
        names = list_wsl_distros()
        if names:
            self.distro_combo.config(values=names)
            cur = self.distro_var.get()
            if cur not in names:
                pick = next((n for n in names if "ubuntu" in n.lower()),
                            names[0])
                self.distro_var.set(pick)
            self._log_line("[distro] found: %s" % ", ".join(names), "info")
        else:
            self._log_line("[distro] could not list them (wsl.exe -l -q "
                           "failed); type the name by hand.", "warn")

    # --- validation --------------------------------------------------------
    def _validate_prefix(self, raw):
        s = (raw or "").strip()
        if not s.startswith("/"):
            self._log_line("[error] the install prefix must be an absolute "
                           "POSIX path (starting with /).", "err")
            return None
        if not re.fullmatch(r"/[\w./\-]+", s):
            self._log_line("[error] the install prefix has illegal characters "
                           "(allowed: letters, digits, . _ - /).", "err")
            return None
        return _trim_trailing_slash(s)

    def _validate_distro(self, raw):
        s = (raw or "").strip()
        if not s:
            self._log_line("[error] pick or type a WSL distro.", "err")
            return None
        if not re.fullmatch(r"[\w.\- ]+", s):
            self._log_line("[error] the distro name has illegal characters.",
                           "err")
            return None
        return s

    # --- actions -----------------------------------------------------------
    def _on_install_sdk(self):
        if self.running:
            self._log_line("[install] a task is already running; stop it "
                           "first.", "warn")
            return
        bin_wsl, unc_distro = win_to_wsl_path(self.bin_var.get())
        if not bin_wsl:
            self._log_line("[error] select the SDK installer (.bin).", "err")
            return
        if "\n" in bin_wsl or "\r" in bin_wsl:
            self._log_line("[error] the installer path cannot contain a "
                           "newline.", "err")
            return
        # If a Windows path was typed, check it from the Windows side too --
        # a soft warning, not a hard stop.
        win_raw = self.bin_var.get().strip()
        if re.match(r"^[A-Za-z]:[\\/]", win_raw) and not os.path.exists(win_raw):
            self._log_line("[warn] installer not found: %s (trying anyway; "
                           "check the path)." % win_raw, "warn")
        prefix = self._validate_prefix(self.prefix_var.get())
        if prefix is None:
            return
        distro = self._validate_distro(self.distro_var.get())
        if distro is None:
            return
        if unc_distro and not self.distro_var.get().strip():
            distro = unc_distro
        lang = self.lang_var.get().strip()
        if lang not in LANG_CHOICES:
            lang = DEFAULT_LANG

        # Find the user builds will actually run as, and hand
        # example-applications over to them after a root install.
        build_user = detect_wsl_user(distro)

        cmd = build_sdk_install_cmd(bin_wsl, prefix, lang,
                                    self.copy_var.get(), build_user)
        self._log_line("installer : %s" % bin_wsl, "info")
        self._log_line("prefix    : %s" % prefix, "info")
        self._log_line("language  : %s     copy into WSL first: %s"
                       % (lang, "yes" if self.copy_var.get() else "no"), "info")
        if build_user:
            self._log_line("build user: %s (example-applications will be "
                           "chowned to them)" % build_user, "info")
        else:
            self._log_line("build user: root (no chown needed)", "info")
        self._launch(cmd, "sdk", "Installing the TI SDK",
                     target="WSL %s (as root)" % distro, kind="local",
                     distro=distro, user="root")

    def _on_install_qt(self):
        if self.running:
            self._log_line("[install] a task is already running; stop it "
                           "first.", "warn")
            return
        distro = self._validate_distro(self.distro_var.get())
        if distro is None:
            return
        self._launch(build_qt_install_cmd(), "qt",
                     "Installing Qt %s host" % QT_VER,
                     target="WSL %s (as root)" % distro, kind="local",
                     distro=distro, user="root")

    def _on_install_hosttools(self):
        if self.running:
            self._log_line("[install] a task is already running; stop it "
                           "first.", "warn")
            return
        distro = self._validate_distro(self.distro_var.get())
        if distro is None:
            return
        self._log_line("[install] build-essential, for host-side build "
                       "tooling. The aarch64 cross compiler and cmake already "
                       "ship inside the TI SDK.", "info")
        self._launch(build_hosttools_install_cmd(), "hosttools",
                     "Installing host build tools",
                     target="WSL %s (as root)" % distro, kind="local",
                     distro=distro, user="root")

    def _on_verify(self):
        if self.running:
            self._log_line("[verify] a task is already running; stop it "
                           "first.", "warn")
            return
        prefix = self._validate_prefix(self.prefix_var.get())
        if prefix is None:
            return
        distro = self._validate_distro(self.distro_var.get())
        if distro is None:
            return
        self._launch(build_verify_cmd(prefix), "verify", "Verifying",
                     target="WSL %s  prefix=%s" % (distro, prefix),
                     kind="local", distro=distro, user="root")

    def _on_success(self, task):
        if task == "sdk":
            self._log_line("[hint] next: \"2. Install Qt\" (needed for the "
                           "launcher cross build) and \"3. Build tools\", "
                           "then go to the Cross-compile + Deploy tab.",
                           "info")

    def _on_stop(self):
        if self.running and self.proc is not None:
            self._log_line("[stop] interrupting an install can leave the SDK "
                           "half-written.", "warn")
        RunnerPanel._on_stop(self)


# ============================================================================
# Tab 2 - CC3351 Wi-Fi
# ============================================================================
class WifiPanel(RunnerPanel):
    LABELS = {"status": "Wi-Fi status", "ping": "Reachability test",
              "scan": "AP scan", "driver": "Driver / firmware"}

    def _build_ui(self):
        pad = {"padx": 8, "pady": 4}
        p = self.parent
        tk.Label(p, text="CC3351 Wi-Fi  -  does wlan0 actually reach the "
                         "outside world?",
                 bg=BG, fg=ACCENT, font=("Segoe UI", 13, "bold")
                 ).pack(side="top", anchor="w", padx=12, pady=(10, 2))
        tk.Label(p, text="Pings a hostname (not an IP) forced out of wlan0, "
                         "so one test covers association, routing, DNS and "
                         "external reachability. The EVM has eth0 up as well: "
                         "without -I wlan0 the traffic leaves over the wire "
                         "and Wi-Fi is never exercised. Reading the result: "
                         "\"Destination Host Unreachable\" means the Wi-Fi "
                         "gateway itself is unreachable; \"100% loss\" means "
                         "packets leave but nothing answers.",
                 bg=BG, fg=MUTED, font=("Segoe UI", 9), justify="left",
                 wraplength=960).pack(side="top", anchor="w", padx=12,
                                      pady=(0, 6))

        form = tk.Frame(p, bg=PANEL)
        form.pack(side="top", fill="x", padx=10, pady=4)
        form.columnconfigure(1, weight=1)
        tk.Label(form, text="EVM Ethernet IP:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=0, column=0, sticky="w", **pad)
        self.ip_var = tk.StringVar(value=DEFAULT_EVM_IP)
        tk.Entry(form, textvariable=self.ip_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 11), relief="flat"
                 ).grid(row=0, column=1, columnspan=3, sticky="we", **pad)
        tk.Label(form, text="Ping hostname:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=1, column=0, sticky="w", **pad)
        self.host_var = tk.StringVar(value=DEFAULT_PING_HOST)
        tk.Entry(form, textvariable=self.host_var, width=24, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 11), relief="flat"
                 ).grid(row=1, column=1, sticky="w", **pad)
        tk.Label(form, text="(a hostname is what makes this test DNS too)",
                 bg=PANEL, fg=MUTED, font=("Segoe UI", 9)
                 ).grid(row=1, column=2, columnspan=2, sticky="w", **pad)

        btns = tk.Frame(p, bg=BG)
        btns.pack(side="top", fill="x", padx=10, pady=(6, 2))
        self.status_btn = self._mkbtn(btns, "1. Status", self._on_status,
                                      width=11)
        self.ping_btn = self._mkbtn(btns, "2. Test reachability",
                                    self._on_ping, primary=True, width=19)
        self.scan_btn = self._mkbtn(btns, "3. Scan APs", self._on_scan,
                                    width=12)
        self.drv_btn = self._mkbtn(btns, "Driver / firmware", self._on_driver,
                                   width=16)
        self.stop_btn = self._mkstop(btns)
        self.clear_btn = self._mkclear(btns)
        for b in (self.status_btn, self.ping_btn, self.scan_btn, self.drv_btn,
                  self.stop_btn, self.clear_btn):
            b.pack(side="left", padx=4)
        self._action_btns = [self.status_btn, self.ping_btn, self.scan_btn,
                             self.drv_btn]

        self._mkstatus_and_log(p)

    def _validate_host(self, raw):
        s = (raw or "").strip()
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.\-]{0,253}", s):
            return s
        self._log_line("[error] a hostname may only contain letters, digits, "
                       ". and - (got %r)." % raw, "err")
        return None

    def _on_status(self):
        ip = self._validate_ip(self.ip_var.get())
        if ip:
            self._launch_remote(ip, remote_wifi_status(), "status",
                                "Reading Wi-Fi status")

    def _on_ping(self):
        ip = self._validate_ip(self.ip_var.get())
        if ip is None:
            return
        host = self._validate_host(self.host_var.get())
        if host is None:
            return
        self._launch_remote(ip, remote_wifi_ping(host), "ping",
                            "Testing reachability")

    def _on_scan(self):
        ip = self._validate_ip(self.ip_var.get())
        if ip:
            self._launch_remote(ip, remote_wifi_scan(), "scan",
                                "Scanning for APs")

    def _on_driver(self):
        ip = self._validate_ip(self.ip_var.get())
        if ip:
            self._launch_remote(ip, remote_wifi_driver(), "driver",
                                "Reading driver / firmware state")


# ============================================================================
# Tab 3 - Cross-compile + Deploy
# ============================================================================
class BuildDeployPanel(RunnerPanel):
    LABELS = {"build": "Cross build", "deploy": "Deploy",
              "builddeploy": "Cross build + deploy", "check": "Project check"}

    def _build_ui(self):
        pad = {"padx": 8, "pady": 4}
        p = self.parent
        tk.Label(p, text="Cross-compile + Deploy  -  build a project in WSL "
                         "and push it to the EVM",
                 bg=BG, fg=ACCENT, font=("Segoe UI", 13, "bold")
                 ).pack(side="top", anchor="w", padx=12, pady=(10, 2))
        tk.Label(p, text="The project path is not fixed (EdgePilot_Github_Demo "
                         "is only the default). Any project works if its build "
                         "script sources the SDK environment and "
                         "cross-compiles for aarch64, its deploy script takes "
                         "the board address from EVM_IP, and both run with the "
                         "project directory as the working directory. Press "
                         "\"4. Check\" first when pointing this at something "
                         "new: it is read-only and tells you what to put in "
                         "the script fields.",
                 bg=BG, fg=MUTED, font=("Segoe UI", 9), justify="left",
                 wraplength=960).pack(side="top", anchor="w", padx=12,
                                      pady=(0, 6))

        form = tk.Frame(p, bg=PANEL)
        form.pack(side="top", fill="x", padx=10, pady=4)
        form.columnconfigure(1, weight=1)
        tk.Label(form, text="Project path:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=0, column=0, sticky="w", **pad)
        self.proj_var = tk.StringVar(value=DEFAULT_PROJECT_DIR)
        self.proj_combo = ttk.Combobox(form, textvariable=self.proj_var,
                                       values=[])
        self.proj_combo.grid(row=0, column=1, sticky="we", **pad)
        tk.Button(form, text="Browse", command=self._on_browse, bg=PANEL,
                  fg=INK, activebackground=ACCENT, activeforeground=CODE,
                  relief="ridge", width=9).grid(row=0, column=2, **pad)
        tk.Button(form, text="Scan projects", command=self._on_scan, bg=PANEL,
                  fg=INK, activebackground=ACCENT, activeforeground=CODE,
                  relief="ridge", width=13).grid(row=0, column=3, **pad)

        tk.Label(form, text="Build script:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=1, column=0, sticky="w", **pad)
        self.build_sh_var = tk.StringVar(value=DEFAULT_BUILD_SH)
        tk.Entry(form, textvariable=self.build_sh_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 11), relief="flat",
                 width=24).grid(row=1, column=1, sticky="w", **pad)

        tk.Label(form, text="Deploy script:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=2, column=0, sticky="w", **pad)
        self.deploy_sh_var = tk.StringVar(value=DEFAULT_DEPLOY_SH)
        tk.Entry(form, textvariable=self.deploy_sh_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 11), relief="flat",
                 width=24).grid(row=2, column=1, sticky="w", **pad)

        tk.Label(form, text="EVM Ethernet IP:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=3, column=0, sticky="w", **pad)
        self.ip_var = tk.StringVar(value=DEFAULT_EVM_IP)
        tk.Entry(form, textvariable=self.ip_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 11), relief="flat",
                 width=24).grid(row=3, column=1, sticky="w", **pad)

        quick = tk.Frame(p, bg=BG)
        quick.pack(side="top", fill="x", padx=12, pady=(0, 2))
        tk.Label(quick, text="Quick projects:", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left")
        for _label, _path in PROJECT_QUICK_DIRS:
            tk.Button(quick, text=_label, bg=PANEL, fg=INK,
                      activebackground=ACCENT, activeforeground=CODE,
                      relief="ridge",
                      command=lambda q=_path: self._set_quick_project(q)
                      ).pack(side="left", padx=4, pady=2)

        btns = tk.Frame(p, bg=BG)
        btns.pack(side="top", fill="x", padx=10, pady=(6, 2))
        self.build_btn = self._mkbtn(btns, "1. Cross build", self._on_build,
                                     width=14)
        self.deploy_btn = self._mkbtn(btns, "2. Deploy", self._on_deploy,
                                      width=11)
        self.bd_btn = self._mkbtn(btns, "3. Build + deploy",
                                  self._on_build_deploy, primary=True,
                                  width=17)
        self.check_btn = self._mkbtn(btns, "4. Check", self._on_check, width=10)
        self.stop_btn = self._mkstop(btns)
        self.clear_btn = self._mkclear(btns)
        for b in (self.build_btn, self.deploy_btn, self.bd_btn,
                  self.check_btn, self.stop_btn, self.clear_btn):
            b.pack(side="left", padx=4)
        self._action_btns = [self.build_btn, self.deploy_btn, self.bd_btn,
                             self.check_btn]

        self._mkstatus_and_log(p)

    # --- project / script resolution ---------------------------------------
    def _set_quick_project(self, path):
        self.proj_var.set(path)
        self._log_line("[project] switched to: %s" % path, "info")

    def _resolve_project(self):
        """Project path field -> (wsl_path, distro), or (None, "")."""
        raw = self.proj_var.get()
        wsl_path, distro = win_to_wsl_path(raw)
        if not wsl_path:
            self._log_line("[error] type or browse to a project path (the "
                           "directory must contain the build/deploy scripts).",
                           "err")
            return None, ""
        if not wsl_path.startswith("/"):
            self._log_line("[error] cannot resolve the project path (got %r). "
                           "Use a WSL path (/opt/ti/...), a UNC path "
                           "(\\\\wsl$\\<distro>\\...) or a Windows drive path "
                           "(C:\\...)." % raw, "err")
            return None, ""
        wsl_path = _trim_trailing_slash(wsl_path)
        if wsl_path.startswith("/mnt/"):
            self._log_line("[hint] the project sits on a Windows drive (%s), "
                           "so it goes through 9p and builds noticeably "
                           "slower. Consider moving it into WSL's ext4."
                           % wsl_path, "warn")
        return wsl_path, distro

    def _validate_script(self, raw, kind):
        """Script name / project-relative path. Everything is shq'd before it
        reaches a shell anyway; this is a second layer plus a clear message."""
        s = re.sub(r"/+", "/", (raw or "").strip().replace("\\", "/"))
        while s.startswith("./"):
            s = s[2:]
        if not s:
            self._log_line("[error] enter the %s script name (e.g. build.sh)."
                           % kind, "err")
            return None
        if s.startswith("/") or ".." in s.split("/"):
            self._log_line("[error] the %s script must be a path inside the "
                           "project -- no absolute paths and no .. (got %r)."
                           % (kind, raw), "err")
            return None
        if not re.fullmatch(r"[A-Za-z0-9._\-/]+\.sh", s):
            self._log_line("[error] the %s script may only contain A-Z a-z 0-9 "
                           ". _ - / and must end in .sh (got %r)."
                           % (kind, raw), "err")
            return None
        return s

    # --- browse / scan -----------------------------------------------------
    def _on_browse(self):
        """Folder picker. initialdir is pushed back into UNC form so the
        dialog opens inside WSL -- Windows file dialogs cannot take a POSIX
        path like /opt/..."""
        cur = self.proj_var.get().strip()
        distro = self._distro or DEFAULT_DISTRO
        if cur.startswith("/"):
            init = "\\\\wsl$\\%s%s" % (distro, cur.replace("/", "\\"))
        elif cur:
            init = cur
        else:
            init = "\\\\wsl$\\%s%s" % (distro, EXAMPLES_ROOT.replace("/", "\\"))
        chosen = filedialog.askdirectory(
            title="Select the project directory (with the build/deploy "
                  "scripts)",
            initialdir=init)
        if chosen:
            self.proj_var.set(chosen)
            self._log_line("[project] selected: %s" % chosen, "info")

    def _on_scan(self):
        """Look one level above the current project path for directories
        containing the build script and fill the dropdown. Follows wherever
        the user is rather than being tied to the SDK tree; falls back to
        EXAMPLES_ROOT when the path cannot be resolved. Runs synchronously --
        find is fast -- with a 60 s timeout."""
        if self.running:
            self._log_line("[scan] a task is running; stop it first.", "warn")
            return
        build_sh = self._validate_script(self.build_sh_var.get(), "build")
        if build_sh is None:
            return
        wsl_path, distro = win_to_wsl_path(self.proj_var.get())
        if wsl_path and wsl_path.startswith("/"):
            root = os.path.dirname(_trim_trailing_slash(wsl_path)) or "/"
        else:
            root, distro = EXAMPLES_ROOT, ""
        self._log_line("=" * 64, "info")
        self._log_line("[scan] root: %s%s  (looking for %s)"
                       % (root, ("  (distro=%s)" % distro) if distro else "",
                          build_sh), "info")
        argv = wsl_argv(distro, project_scan_cmd(root, build_sh))
        try:
            cp = subprocess.run(argv, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True,
                                encoding="utf-8", errors="replace",
                                creationflags=_no_window_flags(), timeout=60)
        except Exception as exc:  # noqa: BLE001
            self._log_line("[scan] running wsl.exe failed: %s" % exc, "err")
            return
        found = []
        for line in strip_ansi(cp.stdout or "").splitlines():
            line = line.strip()
            if line.startswith("PROJ "):
                d = line[5:].strip()
                if d and d not in found:
                    found.append(d)
            elif line and not line.startswith("=="):
                self._log_line(line, "err" if line.startswith("[X]") else None)
        if not found:
            self._log_line("[scan] nothing found containing %s. Change the "
                           "build-script field and scan again, or use "
                           "\"Browse\"." % build_sh, "warn")
            return
        self.proj_combo.config(values=found)
        for d in found:
            self._log_line("  - %s" % d, "ok")
        self._log_line("[scan] %d project(s) found, dropdown filled."
                       % len(found), "ok")

    # --- actions -----------------------------------------------------------
    def _on_build(self):
        proj, distro = self._resolve_project()
        if proj is None:
            return
        build_sh = self._validate_script(self.build_sh_var.get(), "build")
        if build_sh is None:
            return
        self._launch_local(build_only_cmd(proj, build_sh), "build",
                           "Cross building",
                           target="%s  (WSL only, board not touched)" % proj,
                           distro=distro)

    def _on_deploy(self):
        proj, distro = self._resolve_project()
        if proj is None:
            return
        deploy_sh = self._validate_script(self.deploy_sh_var.get(), "deploy")
        if deploy_sh is None:
            return
        ip = self._validate_ip(self.ip_var.get())
        if not ip:
            return
        self._launch_local(deploy_only_cmd(proj, ip, deploy_sh), "deploy",
                           "Deploying",
                           target="%s -> EVM root@%s" % (proj, ip),
                           distro=distro)

    def _on_build_deploy(self):
        proj, distro = self._resolve_project()
        if proj is None:
            return
        build_sh = self._validate_script(self.build_sh_var.get(), "build")
        deploy_sh = self._validate_script(self.deploy_sh_var.get(), "deploy")
        if build_sh is None or deploy_sh is None:
            return
        ip = self._validate_ip(self.ip_var.get())
        if not ip:
            return
        self._launch_local(build_deploy_cmd(proj, ip, build_sh, deploy_sh),
                           "builddeploy", "Cross building + deploying",
                           target="%s -> EVM root@%s" % (proj, ip),
                           distro=distro)

    def _on_check(self):
        proj, distro = self._resolve_project()
        if proj is None:
            return
        build_sh = self._validate_script(self.build_sh_var.get(), "build")
        deploy_sh = self._validate_script(self.deploy_sh_var.get(), "deploy")
        if build_sh is None or deploy_sh is None:
            return
        self._launch_local(project_check_cmd(proj, build_sh, deploy_sh),
                           "check", "Checking the project",
                           target="%s  (read-only, board not touched)" % proj,
                           distro=distro)


# ============================================================================
# Tab 4 - Password SSH
# ============================================================================
class PasswordSshPanel(RunnerPanel):
    """Log in to a board that only takes a password. Same streaming model as
    every other tab; the command becomes sshpass -e ssh, with the password
    travelling through SSHPASS (forwarded into WSL via WSLENV) so it never
    reaches the command string or the log."""

    LABELS = {"conn": "Connection test", "osver": "Linux version",
              "custom": "Custom remote command"}

    def _build_ui(self):
        pad = {"padx": 8, "pady": 4}
        p = self.parent
        tk.Label(p, text="Password SSH  -  connect to a board that has no key "
                         "login",
                 bg=BG, fg=ACCENT, font=("Segoe UI", 13, "bold")
                 ).pack(side="top", anchor="w", padx=12, pady=(10, 2))
        tk.Label(p, text="Every other tab uses key login (BatchMode=yes). This "
                         "one feeds the password to sshpass through the "
                         "SSHPASS environment variable, so it never appears in "
                         "the command string, in ps, or in the log, and turns "
                         "public-key auth off so a key cannot silently mask a "
                         "wrong password. Requires sshpass in WSL: sudo "
                         "apt-get install -y sshpass. The command shown in the "
                         "log is plain ssh with no password, ready to paste "
                         "into Tera Term or PuTTY. Note: commands run as the "
                         "account you give, so do not paste anything "
                         "destructive.",
                 bg=BG, fg=MUTED, font=("Segoe UI", 9), justify="left",
                 wraplength=960).pack(side="top", anchor="w", padx=12,
                                      pady=(0, 6))

        form = tk.Frame(p, bg=PANEL)
        form.pack(side="top", fill="x", padx=10, pady=4)
        form.columnconfigure(1, weight=1)
        tk.Label(form, text="EVM IP / hostname:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=0, column=0, sticky="w", **pad)
        self.ip_var = tk.StringVar(value=DEFAULT_EVM_IP)
        tk.Entry(form, textvariable=self.ip_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 11), relief="flat"
                 ).grid(row=0, column=1, columnspan=2, sticky="we", **pad)
        tk.Label(form, text="User:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=1, column=0, sticky="w", **pad)
        self.user_var = tk.StringVar(value=DEFAULT_PW_USER)
        tk.Entry(form, textvariable=self.user_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 11), relief="flat",
                 width=18).grid(row=1, column=1, sticky="w", **pad)
        tk.Label(form, text="Password:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=2, column=0, sticky="w", **pad)
        self.pw_var = tk.StringVar(value="")
        self.pw_entry = tk.Entry(form, textvariable=self.pw_var, bg=CODE,
                                 fg=INK, insertbackground=INK,
                                 font=("Consolas", 11), relief="flat", show="*")
        self.pw_entry.grid(row=2, column=1, sticky="we", **pad)
        self.show_pw_var = tk.BooleanVar(value=False)
        tk.Checkbutton(form, text="Show", variable=self.show_pw_var,
                       command=self._toggle_pw, bg=PANEL, fg=INK,
                       selectcolor=CODE, activebackground=PANEL,
                       activeforeground=INK, font=("Segoe UI", 9)
                       ).grid(row=2, column=2, sticky="w", **pad)

        quick = tk.Frame(p, bg=BG)
        quick.pack(side="top", fill="x", padx=12, pady=(0, 2))
        tk.Label(quick, text="Presets:", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left")
        for _label, _cmd in CUSTOM_CMD_PRESETS:
            tk.Button(quick, text=_label, bg=PANEL, fg=INK,
                      activebackground=ACCENT, activeforeground=CODE,
                      relief="ridge",
                      command=lambda c=_cmd: self._set_preset(c)
                      ).pack(side="left", padx=4, pady=2)

        tk.Label(p, text="Remote command:", bg=BG, fg=INK,
                 font=("Segoe UI", 10)).pack(side="top", anchor="w", padx=12,
                                             pady=(4, 0))
        self.cmd_text = tk.Text(p, height=5, bg=CODE, fg=INK,
                                insertbackground=INK, font=("Consolas", 10),
                                relief="flat", wrap="word", undo=True)
        self.cmd_text.pack(side="top", fill="x", padx=10, pady=(2, 4))
        self.cmd_text.insert("1.0", PW_CONN_TEST)

        btns = tk.Frame(p, bg=BG)
        btns.pack(side="top", fill="x", padx=10, pady=(2, 2))
        self.conn_btn = self._mkbtn(btns, "1. Test connection", self._on_conn,
                                    primary=True, width=18)
        self.osver_btn = self._mkbtn(btns, "2. Linux version", self._on_osver,
                                     width=16)
        self.run_btn = self._mkbtn(btns, "3. Run command", self._on_run,
                                   width=15)
        self.stop_btn = self._mkstop(btns)
        self.clear_btn = self._mkclear(btns)
        for b in (self.conn_btn, self.osver_btn, self.run_btn, self.stop_btn,
                  self.clear_btn):
            b.pack(side="left", padx=4)
        self._action_btns = [self.conn_btn, self.osver_btn, self.run_btn]

        self._mkstatus_and_log(p)

    def _toggle_pw(self):
        self.pw_entry.config(show="" if self.show_pw_var.get() else "*")

    def _set_preset(self, cmd):
        self.cmd_text.delete("1.0", "end")
        self.cmd_text.insert("1.0", cmd)

    def _validate_user(self, raw):
        s = (raw or "").strip()
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", s):
            return s
        self._log_line("[error] the user name has illegal characters (got %r)."
                       % raw, "err")
        return None

    def _on_conn(self):
        self._do_launch(PW_CONN_TEST, "conn", "Testing the connection")

    def _on_osver(self):
        self._do_launch(PW_OS_VER, "osver", "Reading the Linux version")

    def _on_run(self):
        script = self.cmd_text.get("1.0", "end").strip()
        if not script:
            self._log_line("[error] the command is empty.", "err")
            return
        if "\x00" in script:
            self._log_line("[error] the command contains a NUL character.",
                           "err")
            return
        self._do_launch(script, "custom", "Running the custom command")

    def _do_launch(self, script, task, status):
        if self.running:
            self._log_line("[remote] a task is already running; stop it first.",
                           "warn")
            return
        ip = self._validate_ip(self.ip_var.get())
        if ip is None:
            return
        user = self._validate_user(self.user_var.get())
        if user is None:
            return
        pw = self.pw_var.get()
        if pw == "":
            self._log_line("[error] the password is empty. If that board uses "
                           "key login, use one of the other tabs.", "err")
            return
        # The password goes through SSHPASS, forwarded into WSL with WSLENV.
        # It is absent from the command string, from ps and from the log.
        env = dict(os.environ)
        env["SSHPASS"] = pw
        wslenv = env.get("WSLENV", "")
        keys = [x.split("/")[0] for x in wslenv.split(":") if x]
        if "SSHPASS" not in keys:
            wslenv = (wslenv + ":SSHPASS") if wslenv else "SSHPASS"
        env["WSLENV"] = wslenv
        self._proc_env = env
        self._launch(build_pw_ssh_cmd(user, ip, script), task, status,
                     target="%s@%s" % (user, ip), kind="remote",
                     display_cmd=build_pw_ssh_display(user, ip, script))

    def _rc_hint(self, rc):
        if rc == 127:
            return ("  sshpass not found: install it in WSL with "
                    "sudo apt-get install -y sshpass.")
        if rc in (5, 255):
            return ("  Password login failed, most often simply a wrong "
                    "password. To check whether the server is refusing it: "
                    "this board runs dropbear, not OpenSSH, so there is no "
                    "sshd_config -- run `ps aux | grep dropbear` on the board "
                    "and look for -s (passwords disabled) or -g (root "
                    "password disabled). `passwd -S <user>` shows whether the "
                    "account has a password at all.")
        return ""


# ============================================================================
# Tab 5 - BLE Scan Step
# ============================================================================
# Unlike a one-shot scan, this tab keeps a bluetoothctl session open:
#     wsl.exe ... ssh root@<EVM IP> bluetoothctl
# with its stdin held open, writing one command at a time (power on / scan on /
# pair / yes / menu gatt / select-attribute / notify on ...). A reader thread
# pushes stdout into the queue line by line.
#
# This is the same model the launcher uses in src/blescanner.cpp, where a
# QProcess drives an interactive bluetoothctl -- only here the local QProcess
# is replaced by an SSH hop into the board. bluetoothctl still flushes per
# event when its output is a pipe rather than a tty (the app detecting the
# "Confirm passkey" prompt without a trailing newline is the proof), so the
# step-by-step output arrives live, and pair / yes / subscribe stay coherent
# because they share one session.
#
# loadConnParams (raw MGMT opcode 0x0035) is not a bluetoothctl command and is
# therefore absent here; use the launcher app when connection parameters need
# tuning. Apollo510b runs a 15 s supervision timeout (numericSupervisionUnits).

# Temperature characteristic, same as blescanner.cpp
BLE_STD_TEMP_CHAR = "00002a1c-0000-1000-8000-00805f9b34fb"   # SIG HTS
# Advertised name, i.e. the token isApollo510Device() matches on
BLE_TARGET_NAME = "EdgePilot-510B"

# "Confirm passkey N (yes/no):" -- the numeric-comparison agent holds the bus
# until the user answers. bluetoothctl redraws this repeatedly, so only the
# digits are matched.
_BLE_PASSKEY_RE = re.compile(r"Confirm passkey\s+(\d+)")
# "Attribute ... Value:" -- the hex dump follows on this line or the next one.
_BLE_VALUE_RE = re.compile(r"Value:\s*(.*)$")


class BleScanStepPanel(LogMixin):
    """Persistent interactive bluetoothctl, driven one command at a time,
    following the BLE Scan flow against Apollo510b."""

    def __init__(self, parent, root):
        self.parent = parent
        self.root = root
        self.proc = None
        self.worker = None
        self.q = queue.Queue()
        self.start_time = None
        self.session_open = False
        self._steps_ready = False        # only release buttons once stdin works
        self._pending_value = False      # previous line was a "Value:" header
        self._pairing_in_flight = False  # passkey shown, yes/no not answered
        self._last_temp = None
        self._step_btns = []
        self._build_ui()
        self.root.after(50, self._drain_queue)

    # --- UI ----------------------------------------------------------------
    def _mkbtn(self, parent, text, cmd, color=PANEL, fg=INK, step=True):
        b = tk.Button(parent, text=text, command=cmd, bg=color, fg=fg,
                      activebackground=ACCENT, activeforeground=CODE,
                      relief="flat", font=("Segoe UI", 9, "bold"))
        b.pack(side="left", padx=3, pady=2)
        if step:
            self._step_btns.append(b)
        return b

    def _phase_row(self, parent, label):
        row = tk.Frame(parent, bg=BG)
        row.pack(side="top", fill="x", padx=10, pady=1)
        tk.Label(row, text=label, bg=BG, fg=MUTED, width=11, anchor="w",
                 font=("Segoe UI", 9, "bold")).pack(side="left", padx=(2, 4))
        return row

    def _build_ui(self):
        pad = {"padx": 8, "pady": 4}
        p = self.parent

        tk.Label(p, text="BLE Scan Step  -  persistent interactive "
                         "bluetoothctl (target " + BLE_TARGET_NAME + ")",
                 bg=BG, fg=ACCENT, font=("Segoe UI", 13, "bold")
                 ).pack(side="top", anchor="w", padx=12, pady=(10, 2))
        tk.Label(p, text="Opens `ssh root@<EVM IP> bluetoothctl` as a standing "
                         "session and sends one command at a time: power on -> "
                         "scan -> pair -> yes (six-digit comparison) -> trust "
                         "-> menu gatt -> select 2A1C -> notify on. The "
                         "passkey and the 2A1C temperature are shown live. "
                         "Same sequence as the launcher's BLE Scan page. Note "
                         "the subscribe issues no read: Apollo510b's 2A1C is "
                         "indicate-only, so read returns NotPermitted and only "
                         "delays the CCCD write that actually starts the data.",
                 bg=BG, fg=MUTED, font=("Segoe UI", 9), justify="left",
                 wraplength=980).pack(side="top", anchor="w", padx=12,
                                      pady=(0, 6))

        form = tk.Frame(p, bg=PANEL)
        form.pack(side="top", fill="x", padx=10, pady=4)
        form.columnconfigure(1, weight=1)
        tk.Label(form, text="EVM Ethernet IP:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=0, column=0, sticky="w", **pad)
        self.ip_var = tk.StringVar(value=DEFAULT_EVM_IP)
        tk.Entry(form, textvariable=self.ip_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 11), relief="flat"
                 ).grid(row=0, column=1, sticky="we", **pad)
        tk.Label(form, text="Target MAC:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).grid(row=1, column=0, sticky="w", **pad)
        self.mac_var = tk.StringVar(value="")
        tk.Entry(form, textvariable=self.mac_var, bg=CODE, fg=INK,
                 insertbackground=INK, font=("Consolas", 11), relief="flat"
                 ).grid(row=1, column=1, sticky="we", **pad)
        tk.Label(form, text="(pair / connect / trust / disconnect / "
                            "cancel-pairing / remove all use this MAC, "
                            "e.g. AA:BB:CC:DD:EE:FF)",
                 bg=PANEL, fg=MUTED, font=("Segoe UI", 8)
                 ).grid(row=2, column=0, columnspan=2, sticky="w", padx=8,
                        pady=(0, 4))

        sess = tk.Frame(p, bg=BG)
        sess.pack(side="top", fill="x", padx=10, pady=(6, 2))
        self.open_btn = tk.Button(sess, text="Open session",
                                  command=self._open_session, bg=GREEN,
                                  fg=CODE, activebackground=ACCENT,
                                  activeforeground=CODE, relief="flat",
                                  font=("Segoe UI", 10, "bold"), width=14)
        self.open_btn.pack(side="left", padx=4)
        self.close_btn = tk.Button(sess, text="Close session",
                                   command=self._close_session, bg=RED, fg=INK,
                                   activebackground=AMBER,
                                   activeforeground=CODE, relief="flat",
                                   font=("Segoe UI", 10, "bold"), width=14,
                                   state="disabled")
        self.close_btn.pack(side="left", padx=4)
        self.clear_btn = tk.Button(sess, text="Clear log",
                                   command=self._on_clear, bg=PANEL, fg=INK,
                                   activebackground=ACCENT,
                                   activeforeground=CODE, relief="flat",
                                   font=("Segoe UI", 10, "bold"), width=10)
        self.clear_btn.pack(side="left", padx=4)

        self.temp_var = tk.StringVar(value="Temperature:  --.--")
        tk.Label(p, textvariable=self.temp_var, bg=BG, fg=ACCENT,
                 font=("Consolas", 26, "bold")).pack(side="top", pady=(4, 2))

        groups = tk.Frame(p, bg=BG)
        groups.pack(side="top", fill="x", padx=2, pady=(2, 2))

        r = self._phase_row(groups, "S0 init")
        self._mkbtn(r, "power on", lambda: self._send("power on"))
        self._mkbtn(r, "init agent", self._send_init)
        self._mkbtn(r, "show", lambda: self._send("show"))

        r = self._phase_row(groups, "S1 scan")
        self._mkbtn(r, "scan on", lambda: self._send("scan on"))
        self._mkbtn(r, "scan off", lambda: self._send("scan off"))
        self._mkbtn(r, "devices", lambda: self._send("devices"))

        r = self._phase_row(groups, "S2 pair")
        self._mkbtn(r, "pair", self._do_pair, color=GREEN, fg=CODE)
        self._mkbtn(r, "confirm yes", lambda: self._send("yes"), color=GREEN,
                    fg=CODE)
        self._mkbtn(r, "reject no", lambda: self._send("no"), color=AMBER,
                    fg=CODE)
        self._mkbtn(r, "cancel-pairing", self._do_cancel_pairing)
        self._mkbtn(r, "trust", self._do_trust)

        r = self._phase_row(groups, "S3 link")
        self._mkbtn(r, "connect", self._do_connect, color=GREEN, fg=CODE)
        self._mkbtn(r, "disconnect", self._do_disconnect, color=AMBER, fg=CODE)

        r = self._phase_row(groups, "S6 subscribe")
        self._mkbtn(r, "menu gatt", lambda: self._send("menu gatt"))
        self._mkbtn(r, "select 2A1C",
                    lambda: self._send("select-attribute " + BLE_STD_TEMP_CHAR))
        # read is not part of the Apollo510b flow (indicate-only -> the call
        # returns NotPermitted). Kept as a single step for comparing against
        # other devices by hand; the one-touch flow never sends it.
        self._mkbtn(r, "read (not needed)", lambda: self._send("read"))
        self._mkbtn(r, "notify on", lambda: self._send("notify on"),
                    color=GREEN, fg=CODE)
        self._mkbtn(r, "notify off", lambda: self._send("notify off"))
        self._mkbtn(r, "back", lambda: self._send("back"))

        r = self._phase_row(groups, "S8 clear")
        self._mkbtn(r, "remove", self._do_remove, color=RED, fg=INK)

        r = self._phase_row(groups, "One touch")
        self._mkbtn(r, "1. init + scan", self._flow_init_scan, color=ACCENT,
                    fg=CODE)
        self._mkbtn(r, "2. pair (then yes)", self._flow_pair, color=ACCENT,
                    fg=CODE)
        self._mkbtn(r, "3. subscribe 2A1C", self._flow_subscribe, color=ACCENT,
                    fg=CODE)
        self._mkbtn(r, "4. unpair / disconnect", self._flow_clear, color=RED,
                    fg=INK)

        custom = tk.Frame(p, bg=PANEL)
        custom.pack(side="top", fill="x", padx=10, pady=(6, 2))
        tk.Label(custom, text="Custom command:", bg=PANEL, fg=INK,
                 font=("Segoe UI", 10)).pack(side="left", padx=(8, 4), pady=4)
        self.custom_var = tk.StringVar(value="")
        self.custom_entry = tk.Entry(custom, textvariable=self.custom_var,
                                     bg=CODE, fg=INK, insertbackground=INK,
                                     font=("Consolas", 11), relief="flat")
        self.custom_entry.pack(side="left", fill="x", expand=True, padx=4,
                               pady=4)
        self.custom_entry.bind("<Return>", lambda e: self._send_custom())
        sb = tk.Button(custom, text="Send", command=self._send_custom,
                       bg=ACCENT, fg=CODE, activebackground=GREEN,
                       activeforeground=CODE, relief="flat",
                       font=("Segoe UI", 10, "bold"), width=8)
        sb.pack(side="left", padx=(4, 8), pady=4)
        self._step_btns.append(sb)

        self.status_var = tk.StringVar(value="Ready. Press \"Open session\".")
        self.status_label = tk.Label(p, textvariable=self.status_var, bg=BG,
                                     fg=MUTED, anchor="w",
                                     font=("Segoe UI", 10))
        self.status_label.pack(side="top", fill="x", padx=12, pady=(2, 4))

        self.log = self._make_log(p)
        self.log.pack(side="top", fill="both", expand=True, padx=10,
                      pady=(2, 10))
        self._set_session_state(False)

    # --- validation --------------------------------------------------------
    def _validate_ip(self, raw):
        s = (raw or "").strip()
        if re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", s):
            if all(0 <= int(o) <= 255 for o in s.split(".")):
                return s
            self._log_line("[error] each IPv4 octet must be 0-255 (got %r)."
                           % raw, "err")
            return None
        if re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.\-]*[A-Za-z0-9])?", s):
            return s
        self._log_line("[error] EVM IP / hostname has illegal characters "
                       "(got %r)." % raw, "err")
        return None

    def _validate_mac(self, raw):
        s = (raw or "").strip().upper()
        if not s:
            self._log_line("[error] enter the target MAC above "
                           "(e.g. AA:BB:CC:DD:EE:FF).", "err")
            return None
        if re.fullmatch(r"[0-9A-F]{2}(:[0-9A-F]{2}){5}", s):
            return s
        self._log_line("[error] the MAC must look like XX:XX:XX:XX:XX:XX "
                       "(got %r)." % raw, "err")
        return None

    # --- session state -----------------------------------------------------
    def _set_session_state(self, open_, steps_ready=None):
        self.session_open = open_
        self.open_btn.config(state="disabled" if open_ else "normal")
        self.close_btn.config(state="normal" if open_ else "disabled")
        # steps_ready defaults to open_; opening passes False so the command
        # buttons stay disabled until the process can actually take stdin --
        # otherwise they look clickable while commands are silently dropped.
        self._enable_steps(open_ if steps_ready is None else steps_ready)

    def _enable_steps(self, on):
        self._steps_ready = on
        s = "normal" if on else "disabled"
        for b in self._step_btns:
            b.config(state=s)
        try:
            self.custom_entry.config(state=s)
        except Exception:  # noqa: BLE001
            pass

    # --- open / close ------------------------------------------------------
    def _open_session(self):
        if self.session_open:
            self._log_line("[!] the session is already open.", "warn")
            return
        ip = self._validate_ip(self.ip_var.get())
        if ip is None:
            return
        # ServerAlive on a standing session, so a dead peer or network is
        # noticed and the line is dropped.
        opts = SSH_OPTS + " -o ServerAliveInterval=20 -o ServerAliveCountMax=3"
        bash_cmd = "ssh %s root@%s %s" % (opts, shq(ip), shq("bluetoothctl"))
        argv = wsl_argv("", bash_cmd)        # default distro, which holds the keys
        self._log_line("=" * 64, "info")
        self._log_line("[session] opening interactive bluetoothctl  ->  "
                       "root@%s" % ip, "info")
        self._log_line("[session] command:", "info")
        self._log_line(cmd_multiline(bash_cmd), "cmd")
        self._log_line("=" * 64, "info")
        self._last_temp = None
        self._pending_value = False
        self._pairing_in_flight = False
        self.temp_var.set("Temperature:  --.--")
        self.start_time = time.time()
        self._set_session_state(True, steps_ready=False)
        self.status_var.set("Session starting...")
        self.status_label.config(fg=AMBER)
        self.worker = threading.Thread(target=self._run_worker, args=(argv,),
                                       daemon=True)
        self.worker.start()
        self._auto_init(0)

    def _auto_init(self, attempt):
        """As soon as the session is usable, send S0: power on -> agent
        KeyboardDisplay -> default-agent. KeyboardDisplay is what makes bluez
        forward the numeric-comparison Confirm passkey to us at all."""
        if not self.session_open:
            return
        if self.proc is None or self.proc.stdin is None:
            if attempt < 10:
                self.root.after(500, lambda: self._auto_init(attempt + 1))
            else:
                self._log_line("[!] the session did not come up in time; use "
                               "\"init agent\" by hand.", "warn")
            return
        self._enable_steps(True)
        self._log_line("[session] auto-init (power on / agent KeyboardDisplay "
                       "/ default-agent)...", "info")
        self.status_var.set("Session connected; initialising...")
        self.status_label.config(fg=GREEN)
        self._send_init()

    def _close_session(self):
        if not self.session_open:
            return
        self._log_line("[session] closing (sending back / quit)...", "warn")
        # back first: if we are sitting in the gatt submenu, quit is only taken
        # as a top-level command after leaving it (back is a harmless no-op in
        # the main menu). Otherwise bluetoothctl can be left stranded.
        self._pairing_in_flight = False      # let back/quit through the guard
        self._send("back", echo=False)
        self._send("quit")
        try:
            if self.proc and self.proc.stdin:
                self.proc.stdin.close()      # EOF -> bluetoothctl exits -> ssh
        except Exception:  # noqa: BLE001
            pass
        self.root.after(1500, self._force_kill)

    def _force_kill(self):
        if self.proc is None:
            return
        try:
            if self.proc.poll() is None:
                self.proc.terminate()
        except Exception:  # noqa: BLE001
            pass
        try:
            self.proc.kill()
        except Exception:  # noqa: BLE001
            pass

    # --- sending commands --------------------------------------------------
    def _send(self, cmd, echo=True):
        if not self.session_open or self.proc is None or self.proc.stdin is None:
            self._log_line("[!] no session (or still starting); cannot send: "
                           "%s" % cmd, "warn")
            return False
        # Pairing guard, mirroring m_pairingAddress in blescanner.cpp. Once
        # "Confirm passkey" is on screen and before yes/no is answered, the
        # agent holds the bus: anything else sent now is read by BlueZ as the
        # agent's reply (and it is not "yes"), which aborts SMP with
        # AuthenticationFailed. So only yes/no get through -- including the
        # menu gatt/select/notify that a one-touch flow would have queued.
        stripped = cmd.strip().lower()
        if self._pairing_in_flight and stripped not in ("yes", "no"):
            self._log_line("[!] pairing confirmation is pending (the agent "
                           "holds the bus): only yes / no can be sent now. "
                           "Press \"confirm yes\" or \"reject no\" first -- "
                           "anything else is taken as the agent's reply and "
                           "aborts SMP with AuthenticationFailed.", "warn")
            self.status_var.set("Pairing confirmation pending: press "
                                "\"confirm yes\" or \"reject no\".")
            self.status_label.config(fg=AMBER)
            return False
        try:
            self.proc.stdin.write(cmd + "\n")
            self.proc.stdin.flush()
        except Exception as exc:  # noqa: BLE001
            self._log_line("[error] could not send %s (%s)" % (cmd, exc), "err")
            return False
        if echo:
            self._log_line(">> %s" % cmd, "cmd")
        if stripped in ("yes", "no"):
            self._pairing_in_flight = False  # answered: the bus is free again
        return True

    def _send_seq(self, steps):
        t = 0
        for delay, cmd in steps:
            t += delay
            self.root.after(t, lambda c=cmd: self._send(c))

    def _send_init(self):
        self._send_seq([(0, "power on"), (400, "agent KeyboardDisplay"),
                        (300, "default-agent")])

    def _send_custom(self):
        cmd = (self.custom_var.get() or "").strip()
        if not cmd:
            return
        if self._send(cmd):
            self.custom_var.set("")

    # --- MAC-carrying single steps -----------------------------------------
    def _do_pair(self):
        mac = self._validate_mac(self.mac_var.get())
        if mac:
            self._send("pair " + mac)

    def _do_trust(self):
        mac = self._validate_mac(self.mac_var.get())
        if mac:
            self._send("trust " + mac)

    def _do_connect(self):
        mac = self._validate_mac(self.mac_var.get())
        if mac:
            self._send("connect " + mac)

    def _do_disconnect(self):
        mac = self._validate_mac(self.mac_var.get())
        if mac:
            self._send("disconnect " + mac)

    def _do_cancel_pairing(self):
        mac = self._validate_mac(self.mac_var.get())
        if mac:
            self._send("cancel-pairing " + mac)

    def _do_remove(self):
        mac = self._validate_mac(self.mac_var.get())
        if mac:
            self._send("remove " + mac)

    # --- one-touch flows ---------------------------------------------------
    def _flow_init_scan(self):
        """back (make sure we are in the main menu) -> S0 init -> S1 scan."""
        self._log_line("== one touch: back -> power on -> agent "
                       "KeyboardDisplay -> default-agent -> devices -> "
                       "scan on ==", "info")
        self._send_seq([(0, "back"), (200, "power on"),
                        (400, "agent KeyboardDisplay"), (300, "default-agent"),
                        (300, "devices"), (300, "scan on")])

    def _flow_pair(self):
        mac = self._validate_mac(self.mac_var.get())
        if not mac:
            return
        self._log_line("== one touch: scan off -> pair (numeric comparison; "
                       "press \"confirm yes\" when the passkey appears) ==",
                       "info")
        self._send_seq([(0, "scan off"), (300, "pair " + mac)])

    def _flow_subscribe(self):
        """menu gatt -> select 2A1C -> notify on, with no read.

        Apollo510b declares 0x2A1C as ATT_PROP_INDICATE only, so a read comes
        back org.bluez.Error.NotPermitted, and the extra round-trip delays the
        CCCD write -- which is precisely what makes the firmware emit its first
        sample, and then one per second. Matches blescanner.cpp:
        doRead = !m_standardMode && !isApollo510Device().
        """
        self._log_line("== subscribe: menu gatt -> select 2A1C -> notify on "
                       "(indicate-only, so no read) ==", "info")
        self._send_seq([(0, "menu gatt"),
                        (200, "select-attribute " + BLE_STD_TEMP_CHAR),
                        (200, "notify on")])

    def _flow_clear(self):
        """back -> disconnect -> remove, the same order the launcher uses when
        clearing a bond."""
        mac = self._validate_mac(self.mac_var.get())
        if not mac:
            return
        self._log_line("== one touch: back -> disconnect -> remove ==", "info")
        self._send_seq([(0, "back"), (200, "disconnect " + mac),
                        (600, "remove " + mac)])

    # --- reader thread (stdin stays open; read stdout to EOF) --------------
    def _run_worker(self, argv):
        try:
            self.proc = subprocess.Popen(
                argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                errors="replace", bufsize=1, creationflags=_no_window_flags())
        except Exception as exc:  # noqa: BLE001
            self.q.put(("err", "[error] could not start wsl.exe / ssh: %s"
                        % exc))
            self.q.put(("done", None))
            return
        try:
            for raw_line in self.proc.stdout:
                # bluetoothctl redraws its prompt with \r, so treat that as a
                # line break too and handle each piece separately.
                for seg in re.split(r"[\r\n]", raw_line):
                    line = strip_ansi(seg).rstrip()
                    if line:
                        self.q.put(("line", line))
        except Exception as exc:  # noqa: BLE001
            self.q.put(("err", "[error] exception while reading output: %s"
                        % exc))
        finally:
            try:
                self.proc.wait()
            except Exception:  # noqa: BLE001
                pass
            self.q.put(("done", None))

    def _drain_queue(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "line":
                    self._handle_line(payload)
                elif kind == "err":
                    self._log_line(payload, "err")
                elif kind == "done":
                    self._on_session_finished()
        except queue.Empty:
            pass
        self.root.after(50, self._drain_queue)

    # --- output parsing ----------------------------------------------------
    def _handle_line(self, line):
        # Drop bare prompt redraws ([bluetoothctl]> / [EdgePilot-510B]> /
        # [bluetooth]# ...). This build ends the prompt with ">", which becomes
        # [device name]> once connected, so both # and > must be recognised.
        # Crucially this filter runs first and does NOT consume _pending_value:
        # a prompt landing between a "Value:" header and its hex dump would
        # otherwise eat the flag and the temperature would be missed.
        if re.fullmatch(r"\[[^\]]*\][#>]\s*", line):
            return
        mp = _BLE_PASSKEY_RE.search(line)
        if mp:
            self._pairing_in_flight = True   # bus held: _send allows yes/no only
            self._log_line(line, "warn")
            self.status_var.set("Numeric comparison, passkey=%s: check it "
                                "matches the device, then press \"confirm "
                                "yes\" (or \"reject no\")." % mp.group(1))
            self.status_label.config(fg=AMBER)
            return
        # Previous line was a "Value:" header, so try this one as hex.
        if self._pending_value:
            self._pending_value = False
            b = self._extract_hex(line)
            if b:
                self._log_line("    hex: " + " ".join("%02x" % x for x in b))
                self._commit_temp_from_bytes(b)
                return
            # no hex: fall through and treat it as an ordinary line
        mv = _BLE_VALUE_RE.search(line)
        if mv and ("Attribute" in line or "Characteristic" in line
                   or "/org/" in line):
            self._log_line(line, "info")
            inline = self._extract_hex(mv.group(1))
            if inline:
                self._commit_temp_from_bytes(inline)
            else:
                self._pending_value = True   # hex is on the next line
            return
        low = line.lower()
        if ("failed" in low or "error" in low or "not available" in low
                or "not permitted" in low or "no default controller" in low):
            if "pair" in low or "authentication" in low:
                self._pairing_in_flight = False   # pairing died: release guard
            self._log_line(line, "err")
            return
        if ("paired: yes" in low or "pairing successful" in low
                or "notify started" in low or "connected: yes" in low
                or "servicesresolved: yes" in low or "bonded: yes" in low):
            if ("paired: yes" in low or "pairing successful" in low
                    or "bonded: yes" in low):
                self._pairing_in_flight = False   # bonded: release guard
            self._log_line(line, "ok")
            if "servicesresolved: yes" in low:
                # Connecting is not reading: menu gatt -> select 2A1C ->
                # notify on still has to happen before any Value appears.
                self.status_var.set("Connected and services resolved -> press "
                                    "\"3. subscribe 2A1C\". Connecting alone "
                                    "never produces a temperature.")
                self.status_label.config(fg=ACCENT)
            return
        if "connected: no" in low or "servicesresolved: no" in low:
            self._log_line(line, "warn")
            return
        self._log_line(line)

    def _extract_hex(self, s):
        """Take the leading run of 2-digit hex out of a bluetoothctl dump,
        stopping at the ASCII column."""
        out = []
        for t in s.split():
            if re.fullmatch(r"[0-9a-fA-F]{2}", t):
                out.append(int(t, 16))
            else:
                break
        return out

    def _commit_temp_from_bytes(self, b):
        r = self._parse_temp(b)
        if r is None:
            self._log_line("    (not a decodable HTS temperature packet, "
                           "skipped)", "warn")
            return
        v, unit = r
        self._last_temp = (v, unit)
        # unit is "C" or "F", decided by bit 0 of the HTS flags -- do not
        # hard-code it here.
        self.temp_var.set("Temperature:  %.2f °%s" % (v, unit))
        self._log_line("    -> %.2f °%s" % (v, unit), "ok")
        self.status_var.set("2A1C temperature received: %.2f °%s."
                            % (v, unit))
        self.status_label.config(fg=GREEN)

    @staticmethod
    def _parse_temp(b):
        """HTS temperature decoding, matching parseTemperatureBytes() in
        blescanner.cpp: standard HTS (n>=5) is flags + 24-bit signed mantissa +
        int8 exponent -> mantissa x 10^exp. Everything below that is a loose
        fallback (16-bit SFLOAT / IEEE float / fixed point). Returns
        (value, "C"/"F") or None.
        """
        n = len(b)
        if n > 13:
            return None
        # Standard HTS Temperature Measurement. The sanity gate matches the C++
        # side: illegal flags or a zero mantissa return early and never reach
        # the fallbacks -- otherwise a vendor notification leak like
        # "10 06 ..." gets misread by the fixed-point branch as a plausible
        # but entirely fictional reading.
        if n >= 5:
            if (b[0] & 0xF0) != 0:
                return None                   # illegal HTS flags
            if b[1] == 0 and b[2] == 0 and b[3] == 0:
                return None                   # zero-mantissa placeholder
            unit = "F" if (b[0] & 0x01) else "C"
            mant = b[1] | (b[2] << 8) | (b[3] << 16)
            if mant & 0x00800000:
                mant -= 0x01000000
            exp = b[4] - 256 if b[4] >= 128 else b[4]
            v = mant * (10.0 ** exp)
            lo, hi = (-50.0, 100.0) if unit == "C" else (-58.0, 212.0)
            if lo <= v <= hi:
                return (v, unit)
            # legal flags but out of range: fall through, as the C++ does
        # 16-bit IEEE-11073 SFLOAT
        if n >= 2:
            raw = b[0] | (b[1] << 8)
            if raw not in (0x07FF, 0x0800, 0x0801, 0x0802):
                mant = raw & 0x0FFF
                exp = (raw >> 12) & 0x0F
                if mant & 0x0800:
                    mant -= 0x1000
                if exp & 0x08:
                    exp -= 0x10
                v = mant * (10.0 ** exp)
                if 25.0 <= v <= 50.0:
                    return (v, "C")
        # 32-bit IEEE float, little-endian
        if n >= 4:
            v = struct.unpack("<f", bytes(b[:4]))[0]
            if 25.0 <= v <= 50.0:
                return (v, "C")
        # 16-bit fixed point (x0.01)
        if n >= 2:
            v = b[0] | (b[1] << 8)
            if 1000 <= v <= 4500:
                return (v / 100.0, "C")
        # single-byte integer Celsius
        if n >= 1 and 25 <= b[0] <= 50:
            return (float(b[0]), "C")
        return None

    def _on_session_finished(self):
        elapsed = (time.time() - self.start_time) if self.start_time else 0.0
        self.proc = None
        self.worker = None
        self._pending_value = False
        self._set_session_state(False)
        self.status_var.set("Session closed. (%.0f s)" % elapsed)
        self.status_label.config(fg=MUTED)
        self._log_line("[session] bluetoothctl session ended.", "warn")

    def _on_clear(self):
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")


# ============================================================================
# Main
# ============================================================================
def main():
    root = tk.Tk()
    root.title("EdgePilot Workbench  -  SDK / Build / Wi-Fi / Deploy / SSH / "
               "BLE  (WSL)")
    root.configure(bg=BG)
    root.geometry("1180x820")
    root.minsize(880, 660)

    style = ttk.Style()
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass
    style.configure("TCombobox", fieldbackground=CODE, background=PANEL,
                    foreground=INK, arrowcolor=INK)
    style.map("TCombobox", fieldbackground=[("readonly", CODE)],
              foreground=[("readonly", INK)])

    nb = MultiRowTabs(root, initial_width=1180)
    tab_install = nb.add("1. Install SDK")
    tab_wifi = nb.add("2. CC3351 Wi-Fi")
    tab_deploy = nb.add("3. Cross-compile + Deploy")
    tab_pwssh = nb.add("4. Password SSH")
    tab_blestep = nb.add("5. BLE Scan Step")

    installer = SdkInstallPanel(tab_install, root)
    wifi = WifiPanel(tab_wifi, root)
    deploy = BuildDeployPanel(tab_deploy, root)
    pwssh = PasswordSshPanel(tab_pwssh, root)
    blestep = BleScanStepPanel(tab_blestep, root)

    panels = (installer, wifi, deploy, pwssh, blestep)

    # Try to list the distros at startup. Non-blocking, and harmless if it
    # fails -- the field can always be typed into.
    try:
        installer._refresh_distros()
    except Exception:  # noqa: BLE001
        pass

    def _on_close():
        for app in panels:
            try:
                if app.proc is not None:
                    app.proc.kill()
            except Exception:  # noqa: BLE001
                pass
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", _on_close)
    root.mainloop()


if __name__ == "__main__":
    main()
