#!/usr/bin/env python3
"""
Read-only verification of the Windows half of dosbridge.

Changes nothing. Prints one line per prerequisite and exits non-zero if
anything essential is missing, so it can be used in a script.

  python check.py            check everything
  python check.py --quiet    only show problems
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def find_root(here):
    """Locate the dosbridge files, whichever layout this script is sitting in.

    Three are valid, and all three happen in practice:

      installed  the files sit next to this script
      repo       this file is Installer/server/check.py, files two levels up
      kit        a copy of Installer/ elsewhere, payload in kit/

    Assuming only "repo" meant that copying Installer/ to a new machine and
    running check there reported five FAILs pointing at the Desktop, when the
    payload was sitting in kit/ the whole time.
    """
    # 1. Installed: this script sits alongside the files it is checking.
    if os.path.isfile(os.path.join(here, "dosd.py")):
        return here, True, "installed"
    # 2. In the repo, where this file is Installer/server/check.py. This is
    #    tried before kit/ deliberately: inside the repo the repo is the live
    #    install and kit/ is only a build artifact, so reporting the kit there
    #    would describe the wrong thing.
    up = os.path.dirname(os.path.dirname(here))
    if os.path.isfile(os.path.join(up, "dosd.py")):
        return up, True, "repo"
    # 3. A copy of Installer/ on another machine, payload in kit/.
    kit = os.path.join(here, "kit")
    if os.path.isfile(os.path.join(kit, "dosd.py")):
        return kit, True, "kit"
    return up, False, "none"


ROOT, ROOT_OK, ROOT_KIND = find_root(HERE)

FAILS = []
WARNS = []
QUIET = "--quiet" in sys.argv


def line(state, what, detail=""):
    if state == "FAIL":
        FAILS.append(what)
    elif state == "WARN":
        WARNS.append(what)
    if QUIET and state == "ok":
        return
    tag = {"ok": "  ok  ", "FAIL": " FAIL ", "WARN": " warn "}[state]
    print("[%s] %-34s %s" % (tag, what, detail))


def head(t):
    if not QUIET:
        print("\n--- %s" % t)


def which(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d.strip('"'), name)
        if os.path.isfile(p):
            return p
    return None


def find_fpc_root():
    """FPC's own installer does not put itself on PATH, so look in the usual
    places as well. Returns the versioned root, e.g. C:\\FPC\\3.2.2."""
    onpath = which("fpc.exe")
    if onpath:
        # ...\bin\i386-win32\fpc.exe -> ...\
        return os.path.dirname(os.path.dirname(os.path.dirname(onpath)))
    for base in (r"C:\FPC", r"C:\lazarus\fpc", os.path.expanduser(r"~\FPC")):
        if os.path.isdir(base):
            vers = sorted(d for d in os.listdir(base)
                          if os.path.isdir(os.path.join(base, d)))
            if vers:
                return os.path.join(base, vers[-1])
    return None


# --------------------------------------------------------------------------
head("Python")
v = sys.version_info
line("ok" if v >= (3, 8) else "FAIL", "Python 3.8+",
     "%d.%d.%d" % (v.major, v.minor, v.micro))

# --------------------------------------------------------------------------
head("dosbridge files")
if ROOT_OK and ROOT_KIND == "kit":
    print("  Found a built kit, not yet installed:")
    print("    %s" % ROOT)
    print(r"  Copy that folder somewhere permanent (C:\dosbridge is the")
    print("  usual choice), then run install.cmd and check.cmd from inside it.")
    print("  The PATH and firewall results below refer to that folder.")
    print()
if not ROOT_OK:
    print("  Cannot find the dosbridge files.")
    print("  Looked in : %s" % ROOT)
    print("  and in    : %s" % HERE)
    print()
    print("  Run this from inside the installed folder (the one holding")
    print(r"  dosd.py), or from Installer\server\ in the repo. Copying")
    print(r"  only Installer\ somewhere else leaves it nothing to check.")
    print()
for f in ("dosd.py", "dosctl.py", "dosrun.cmd", "dosdeploy.cmd", "dospull.cmd"):
    line("ok" if os.path.isfile(os.path.join(ROOT, f)) else "FAIL",
         f, ROOT)
files_dir = os.path.join(ROOT, "files")
line("ok" if os.path.isdir(files_dir) else "WARN", "files/ serving directory",
     files_dir if os.path.isdir(files_dir) else "missing - dosd creates it at startup")

# --------------------------------------------------------------------------
head("Free Pascal")
fpc_root = find_fpc_root()
if not fpc_root:
    line("FAIL", "FPC installation", "not found on PATH or in C:\\FPC")
else:
    line("ok", "FPC installation", fpc_root)
    binw32 = os.path.join(fpc_root, "bin", "i386-win32")

    # The i386/win32 native compiler is what the cross package depends on.
    # A win64 install is the classic wrong turn here.
    line("ok" if os.path.isfile(os.path.join(binw32, "fpc.exe")) else "FAIL",
         "native i386-win32 compiler",
         binw32 if os.path.isdir(binw32) else
         "missing - did you install the x86_64 build instead?")

    cross = os.path.join(binw32, "ppcross8086.exe")
    line("ok" if os.path.isfile(cross) else "FAIL",
         "i8086-msdos cross-compiler",
         cross if os.path.isfile(cross) else
         "missing - install fpc-3.2.2.i386-win32.cross.i8086-msdos.exe")

    nasm = os.path.join(binw32, "nasm.exe")
    line("ok" if os.path.isfile(nasm) else "WARN", "bundled NASM",
         nasm if os.path.isfile(nasm) else "not bundled - put one on PATH")

    # -iV can answer even when the units are absent, so check them directly.
    units = os.path.join(fpc_root, "units", "msdos")
    models = []
    if os.path.isdir(units):
        models = sorted(d for d in os.listdir(units) if d.startswith("8086-"))
    line("ok" if models else "FAIL", "msdos 8086 unit sets",
         ", ".join(models) if models else "missing - cross package incomplete")

# --------------------------------------------------------------------------
head("PATH")
path_dirs = [os.path.normcase(os.path.normpath(d.strip('"')))
             for d in os.environ.get("PATH", "").split(os.pathsep) if d.strip()]
line("ok" if os.path.normcase(os.path.normpath(ROOT)) in path_dirs else "WARN",
     "dosbridge on PATH",
     ROOT if os.path.normcase(os.path.normpath(ROOT)) in path_dirs
     else "not on PATH - dosrun/dosdeploy will not resolve by name")
if fpc_root:
    b = os.path.normcase(os.path.normpath(os.path.join(fpc_root, "bin", "i386-win32")))
    line("ok" if b in path_dirs else "WARN", "FPC bin on PATH",
         b if b in path_dirs else "not on PATH - build.cmd/test.cmd will fail")

# --------------------------------------------------------------------------
head("Firewall")
try:
    ps = ("$r = Get-NetFirewallRule -Direction Inbound -Enabled True "
          "-ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'dosbridge' }; "
          "if ($r) { foreach ($x in $r) { "
          "$p = $x | Get-NetFirewallPortFilter; "
          "Write-Output ($x.DisplayName + '|' + $x.Profile + '|' + $p.LocalPort) } } "
          "else { Write-Output 'NONE' }")
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                         capture_output=True, text=True, timeout=60).stdout.strip()
    if not out or out == "NONE":
        line("WARN", "inbound rule for 8080/8081/8082",
             "no 'dosbridge' rule found - the DOS box may be unable to reach us")
    else:
        ports = out.replace("\n", " ")
        need = all(p in out for p in ("8080", "8081", "8082"))
        line("ok" if need else "WARN", "inbound rule for 8080/8081/8082", ports)
except Exception as e:
    line("WARN", "firewall rule", "could not check (%s)" % e.__class__.__name__)

# --------------------------------------------------------------------------
head("Runtime")
try:
    with urllib.request.urlopen("http://127.0.0.1:8080/status", timeout=5) as r:
        st = json.loads(r.read().decode())
    line("ok", "dosd responding on 8080", "%d file(s) staged" % len(st.get("files", [])))
    age = st.get("last_poll_secs_ago")
    if age is None:
        line("WARN", "DOS box polling", "never seen since dosd started")
    elif age < 20:
        line("ok", "DOS box polling", "last poll %.1fs ago" % age)
    else:
        line("WARN", "DOS box polling",
             "STALE, %.0fs ago - powered off, hung, or firewall" % age)
except urllib.error.URLError:
    line("WARN", "dosd responding on 8080",
         "not running - fine for now; run selftest.py first, then dosd.cmd")
except Exception as e:
    line("WARN", "dosd responding on 8080", str(e))

# --------------------------------------------------------------------------
print()
if FAILS:
    print("%d problem(s) must be fixed: %s" % (len(FAILS), ", ".join(FAILS)))
    print("See Installer/server/README.md, or run install.cmd for PATH and firewall.")
if WARNS:
    print("%d warning(s): %s" % (len(WARNS), ", ".join(WARNS)))
if not FAILS and not WARNS:
    print("All checks passed.")
sys.exit(1 if FAILS else 0)
