#!/usr/bin/env python3
"""
DOS Bridge  --  StevenC

dosctl - run things on the real DOS machine from the Windows command line.

This is the piece Claude Code actually drives. It blocks until the DOS box has
finished, prints that program's stdout as its own stdout, and exits with the
DOS errorlevel. So from Claude's point of view the DOS machine is just a test runner.

  dosctl new NAME                   scaffold projects/NAME/ for a new project
  dosctl clean [--all]              delete regenerable build junk (--all: EXEs too)
  dosctl version                    what build the DOS machine is running
  dosctl upgrade [--tools|--agent]  update the DOS machine over the wire
        --dry-run                   ...say what would change, touch nothing
        --force                     redeploy every tool; skip the address guard
  dosctl run PROG.EXE [args...]     push, run, capture stdout, return rc
  dosctl push FILE [FILE...]        stage files for later /f/ fetches
  dosctl deploy FILE [C:\\DEST]      stage AND copy onto the DOS box, verified
  dosctl pull C:\\PATH\\FILE          copy a file off the DOS box, byte-exact
  dosctl drv NEWDRV.SYS [args...]   stage a driver, reboot, report if it hung
        --device NAME               ...and fail unless NAME registers as a device
  dosctl exec "DIR C:\\WORK"           run arbitrary DOS commands
  dosctl reboot [--cold]            reboot it and wait for it to come back
  dosctl stop                       stop the agent loop (ONE-WAY -- see below)
  dosctl status                     is the DOS box alive and polling?

`stop` leaves the DOS machine at a prompt with nothing polling, so nothing
here can reach it afterwards -- restarting means someone at its keyboard typing
C:\\AI\\AI.BAT, or a power cycle. Pressing Q on the box does the same thing.

Options: --timeout SECS (default 120), --reboot (reboot after run),
         --cold (cold boot instead of warm), --server HOST:PORT,
         --out PATH (where `pull` writes; default: basename in the cwd),
         --project NAME (which staging namespace to use; normally inferred)

Staging is namespaced by project. A file under projects/NAME/ stages as
NAME/FILE.EXE, one under starter/ as starter/FILE.EXE, and anything else as
local/FILE.EXE. Two projects can therefore both build a HELLO.EXE without one
silently overwriting the other -- which is what a flat files/ used to do.
The DOS side is unaffected: C:\\WORK is flat and every job deletes its target
before fetching, so only the leaf name ever reaches the box.
"""

import argparse
import base64
import datetime
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FILES_DIR = os.path.join(HERE, "files")
DEFAULT_SERVER = os.environ.get("DOSD_SERVER", "127.0.0.1:8080")

# Stashed by await_result so callers can inspect what the box actually said,
# not just its exit code -- `drv` needs this to spot ##DEVFAIL.
LAST_OUTPUT = {}


# ---------------------------------------------------------------------------
# Templates for `dosctl new`
#
# A scaffold rather than a documented convention, because "which folder should
# this go in?" is a question that gets answered differently every time it is
# asked from memory. Answering it with a command means every project lands
# somewhere the staging namespace can see, and nothing ends up in the built
# installer tree, which makeinst.cmd overwrites wholesale.
# ---------------------------------------------------------------------------

BUILD_CMD = """@echo off
REM  build.cmd [target]      compile <target>.pas for real-mode DOS
REM  build.cmd [target] run  ...and immediately run it on the DOS machine
REM
REM  Default target is @@NAME@@. Units shared with the tool suite (Cpu, Tester,
REM  VGA, Prof) are found via -Fu on ..\\..\\starter and compiled into THIS
REM  project's build\\ -- so no .ppu is ever shared between projects.

setlocal
set ROOT=%~dp0..\\..
set TARGET=%1
if "%TARGET%"=="" set TARGET=@@NAME@@
if not exist build mkdir build

fpc -Tmsdos -Pi8086 -WmLarge -Fu"%ROOT%\\starter" -FEbuild -FUbuild %TARGET%.pas
if errorlevel 1 (
  echo.
  echo BUILD FAILED
  exit /b 1
)

if /I "%2"=="run" (
  echo.
  python "%ROOT%\\dosctl.py" run build\\%TARGET%.exe
  exit /b %ERRORLEVEL%
)

echo.
echo Built build\\%TARGET%.exe  --  stages under the @@NAME@@/ namespace
echo Run it with:  python "%ROOT%\\dosctl.py" run build\\%TARGET%.exe
"""

TEST_CMD = """@echo off
REM  Compile and run on the DOS machine in one step. Exits non-zero if any
REM  test failed, so you can branch on it.
setlocal
call build.cmd %1 run
exit /b %ERRORLEVEL%
"""

MAIN_PAS = """program @@NAME@@;
{ A new dosbridge project.

  Built -Pi8086, so it runs on any DOS machine from an original PC upwards.
  If you want a faster path on better hardware, gate it at run time on
  Has186 or HasFpu from the Cpu unit -- never assume, because an x87 or a
  186 instruction on a plain 8086 fails silently rather than crashing.

  Output must go through DOS. WriteLn is captured and comes back over the
  bridge; anything written straight to video memory does not. }

uses Cpu, Tester;

begin
  WriteLn('=== @@NAME@@ ===');
  Note('CPU: ' + CpuName);
  if HasFpu then
    Note('coprocessor: ' + FpuName)
  else
    Note('coprocessor: none');

  Check('replace this with a real test', True);

  Finish;
end.
"""

PROJ_README = """# @@NAME@@

    cd projects\\@@NAME@@
    test.cmd                compile @@NAME@@.pas and run it on the DOS machine
    build.cmd               compile only
    build.cmd other run     build and run other.pas instead

Binaries land in `build\\` and stage as **`@@NAME@@/NAME.EXE`** -- the project
name is the staging namespace, so a `HELLO.EXE` here cannot overwrite one
belonging to another project.

On the DOS side it still arrives in `C:\\WORK` under its plain 8.3 name. That
is safe: every job deletes its target before fetching, so a same-named binary
from another project is never the one that runs.

Shared units (`Cpu`, `Tester`, `VGA`, `Prof`) come from `starter\\` and are
compiled into this project's own `build\\`.

Hard limits worth remembering: exit codes must be <= 20, filenames are 8.3,
and a DOS critical error blocks forever and looks exactly like a hang.
See `CLAUDE.md` at the repo root.
"""


def clean_tree(deep):
    """Delete what can be regenerated, and nothing else.

    The dev tree accumulates a lot of output that looks like content: FPC
    leaves .a/.o/.s/.ppu and a *.sl directory per program beside every binary,
    which is where most of starter/ came from. None of it is source and all of
    it comes back on the next build.

    Built .EXEs are kept unless --all, because the client half of the installer
    takes its tools from starter/build by default -- clearing them means a
    rebuild before makeinst will produce a complete kit.

    files/ project subdirectories go too: they are a serving cache that
    re-fills on the next push. Files at the root of files/ are left alone --
    EXIT0.COM is written by dosd at startup and would not come back until it
    was restarted.
    """
    junk_ext = (".a", ".o", ".s", ".ppu")
    targets = []

    builds = [os.path.join(HERE, "starter", "build")]
    if os.path.isdir(PROJECTS_DIR):
        for pr in sorted(os.listdir(PROJECTS_DIR)):
            b = os.path.join(PROJECTS_DIR, pr, "build")
            if os.path.isdir(b):
                builds.append(b)

    for b in builds:
        if not os.path.isdir(b):
            continue
        for entry in sorted(os.listdir(b)):
            full = os.path.join(b, entry)
            ext = os.path.splitext(entry)[1].lower()
            if os.path.isdir(full):
                if entry.lower().endswith(".sl"):
                    targets.append(full)
            elif ext in junk_ext or (deep and ext == ".exe"):
                targets.append(full)

    if os.path.isdir(FILES_DIR):
        for entry in sorted(os.listdir(FILES_DIR)):
            full = os.path.join(FILES_DIR, entry)
            if os.path.isdir(full):
                targets.append(full)

    for dirpath, dirs, _ in os.walk(HERE):
        for d in list(dirs):
            if d == "__pycache__":
                targets.append(os.path.join(dirpath, d))
                dirs.remove(d)

    freed = 0
    for t in targets:
        if os.path.isdir(t):
            for dp, _, ns in os.walk(t):
                for n in ns:
                    try:
                        freed += os.path.getsize(os.path.join(dp, n))
                    except OSError:
                        pass
        else:
            try:
                freed += os.path.getsize(t)
            except OSError:
                pass

    gone = 0
    stuck = []
    for t in targets:
        try:
            if os.path.isdir(t):
                shutil.rmtree(t)
            else:
                os.remove(t)
            gone += 1
        except OSError as e:
            stuck.append("%s (%s)" % (os.path.relpath(t, HERE), e.strerror))

    return gone, freed, stuck

# Commands that take the machine down. A job containing one of these can never
# report back: the reboot happens partway through JOB.BAT, so the NC that would
# send the result never runs. Without this check `dosexec reboot` looks like a
# hang -- it sits silent for the full timeout and then blames the DOS box for
# doing exactly what it was told.
REBOOT_LEAVES = ("REBOOT", "REBOOT.COM", "COLDBOOT", "COLDBOOT.COM")


def reboot_index(cmds):
    """Index of the first command that reboots the machine, or None."""
    for i, c in enumerate(cmds):
        first = (c.strip().split() or [""])[0]
        leaf = first.replace("/", "\\").split("\\")[-1].upper()
        if leaf in REBOOT_LEAVES:
            return i
    return None

AGENT_VER_DOS = r"C:\AI\VERSION.TXT"


def local_build():
    """(build number, is_dev) for whichever copy of the bridge this is.

    An installed copy carries VERSION.txt next to dosd.py, written when the
    installer was packaged. The dev tree has no such file and instead has
    installer-src/buildno.txt, which records the last build *cut* -- the tree
    itself may well be ahead of it. The caller marks that difference rather
    than pretending a working tree is a released build.
    """
    v = os.path.join(HERE, "VERSION.txt")
    if os.path.isfile(v):
        try:
            for line in open(v):
                if line.strip().lower().startswith("build "):
                    return line.split()[1].strip(), False
        except OSError:
            pass
    b = os.path.join(HERE, "installer-src", "buildno.txt")
    if os.path.isfile(b):
        try:
            return (open(b).read().strip() or "0"), True
        except OSError:
            pass
    return "?", True


def version_stamp_text(how):
    """The three lines that live in C:\\AI\\VERSION.TXT on the DOS machine.

    Short lines on purpose: AI.BAT TYPEs this into an 80-column boot banner.

    The '+' on a dev build is the honest bit. `dosctl upgrade` sends whatever
    is in the working tree, which is normally newer than the last packaged
    build, so plain "build 1" would claim more than is true.
    """
    n, dev = local_build()
    return ("DOS Bridge client\r\n"
            "build %s%s\r\n"
            "%s %s\r\n" % (n, "+" if dev else "",
                           how, datetime.date.today().isoformat()))


def read_box_version(args):
    """What the DOS machine says it is running, or None."""
    job = api(args.server, "/queue", {
        "kind": "raw", "cmds": ["TYPE %s" % AGENT_VER_DOS], "timeout": args.timeout,
    })
    # Read the result directly rather than through await_result: that helper
    # both prints the output and is the only thing that fills LAST_OUTPUT, so
    # using it here would echo the file and reading LAST_OUTPUT without it
    # silently returns whatever the previous job left behind.
    res = api(args.server, "/result/%s" % job["id"], timeout=args.timeout + 30)
    txt = (res.get("output") or "").strip()
    if not txt or "File not found" in txt or "Invalid" in txt:
        return None
    return txt


def write_box_version(args, how):
    """Stamp the DOS machine with what was just put on it."""
    staged = os.path.join(FILES_DIR, "agent")
    os.makedirs(staged, exist_ok=True)
    path = os.path.join(staged, "VERSION.TXT")
    with open(path, "wb") as fh:
        fh.write(version_stamp_text(how).encode("ascii", "replace"))
    j = api(args.server, "/queue", {
        "kind": "deploy", "name": "agent/VERSION.TXT", "dest": r"C:\AI",
        "timeout": args.timeout,
    })
    r = api(args.server, "/result/%s" % j["id"], timeout=args.timeout + 30)
    return 1 if (r.get("error") or r.get("rc")) else 0

AGENT_END_LINE = "REM ##AGENT-END"
TOOLS_DIR_DOS = r"C:\TOOLS"


def agent_addresses(text):
    """The SET SRV= / SET UPHOST= an agent loop will use once it is running."""
    srv = uphost = None
    for raw in text.splitlines():
        t = raw.strip()
        u = t.upper()
        if u.startswith("SET SRV="):
            srv = t.split("=", 1)[1].strip()
        elif u.startswith("SET UPHOST="):
            uphost = t.split("=", 1)[1].strip()
    return srv, uphost


def parse_dos_dir(text):
    """{NAME.EXT: size} from a DOS `DIR` listing.

    DOS prints `FPU      EXE        35,350 08-30-24  11:53a` -- name and
    extension in fixed columns, size with thousands separators.
    """
    out = {}
    for raw in text.splitlines():
        m = re.match(r"^([A-Z0-9_~\-!@#$%^&()]{1,8})\s+([A-Z0-9]{1,3})\s+"
                     r"([\d,]+)\s+\d\d-\d\d-\d\d", raw.strip().upper())
        if m:
            out["%s.%s" % (m.group(1), m.group(2))] = int(m.group(3).replace(",", ""))
    return out


def wait_for_box(server, label, limit=240):
    """Watch the box drop and come back. Returns True if it returned."""
    sys.stderr.write("dosctl: %s -- waiting for the box to drop...\n" % label)
    gone = False
    t0 = time.time()
    while time.time() - t0 < limit:
        time.sleep(2)
        age = api(server, "/status").get("last_poll_secs_ago")
        if age is None:
            continue
        if not gone and age > 15:
            gone = True
            sys.stderr.write("dosctl:   down, waiting for it to boot...\n")
        elif gone and age < 12:
            sys.stderr.write("dosctl: back up after %.0fs\n" % (time.time() - t0))
            return True
    sys.stderr.write("dosctl: box did not come back within %ds -- check its screen\n"
                     % limit)
    return False


def upgrade_tools(args, tail, dry, force):
    """Push the built tools to C:\\TOOLS, skipping those already identical.

    Comparison is by size, from a single DIR listing. That is one round trip
    instead of one per tool, and a rebuilt binary that changed at all changes
    length in practice -- but it is a proxy, not a hash, so --force exists.
    """
    build = os.path.join(HERE, "starter", "build")
    if not os.path.isdir(build):
        die("no starter/build -- build the tools first")
    local = {}
    for f in sorted(os.listdir(build)):
        # .COM as well as .EXE: KEYHIT is hand-assembled because AI.BAT runs it
        # once per poll and a 25 KB FPC binary is the wrong shape for that.
        if f.lower().endswith((".exe", ".com")):
            local[f.upper()] = os.path.getsize(os.path.join(build, f))
    if not local:
        die("starter/build has no .EXE or .COM -- build the tools first")

    job = api(args.server, "/queue", {
        "kind": "raw", "cmds": ["DIR %s" % TOOLS_DIR_DOS], "timeout": args.timeout,
    })
    # Same reason as read_box_version, plus one of its own: await_result would
    # print a 27-line directory listing into the middle of the upgrade report.
    res = api(args.server, "/result/%s" % job["id"], timeout=args.timeout + 30)
    if res.get("error"):
        die("could not list %s on the box: %s" % (TOOLS_DIR_DOS, res["error"]))
    remote = parse_dos_dir(res.get("output") or "")

    todo = []
    for name, size in sorted(local.items()):
        if force or name not in remote:
            todo.append((name, "new" if name not in remote else "forced"))
        elif remote[name] != size:
            todo.append((name, "%d -> %d bytes" % (remote[name], size)))

    print()
    print("tools: %d built, %d already current, %d to send"
          % (len(local), len(local) - len(todo), len(todo)))
    for name, why in todo:
        print("  %-14s %s" % (name, why))
    if not todo:
        return 0
    if dry:
        print("\n--dry-run: nothing sent")
        return 0

    bad = 0
    for name, _ in todo:
        src = os.path.join(build, name)
        if not os.path.isfile(src):
            src = os.path.join(build, name.lower())
        sys.stderr.write("dosctl: deploying %s\n" % name)
        n = stage([src], args.project)[0]
        j = api(args.server, "/queue", {
            "kind": "deploy", "name": n, "dest": TOOLS_DIR_DOS,
            "timeout": args.timeout,
        })
        jr = api(args.server, "/result/%s" % j["id"], timeout=args.timeout + 30)
        if jr.get("error") or jr.get("rc"):
            sys.stderr.write("dosctl: FAILED to deploy %s\n" % name)
            bad += 1
    print()
    print("%d tool(s) sent, %d failed" % (len(todo) - bad, bad))
    return 1 if bad else 0


def upgrade_agent(args, tail, dry, force):
    """Replace the agent loop on the box, then reboot into it."""
    src = None
    for i, t in enumerate(tail):
        if t == "--agent-file" and i + 1 < len(tail):
            src = tail[i + 1]
    if src is None:
        src = os.path.join(HERE, "dos", "live", "AI.BAT")
    if not os.path.isfile(src):
        die("no agent file at %s (pass --agent-file PATH)" % src)
    with open(src, "r", errors="replace") as fh:
        new_text = fh.read()

    new_srv, new_up = agent_addresses(new_text)
    if not new_srv or not new_up:
        die("%s has no SET SRV= / SET UPHOST= -- that cannot be an agent loop"
            % src)

    # Pull what is running now. The box is demonstrably reaching us with those
    # addresses, so they are the only ones known to work; replacing them is how
    # you get a machine that boots, never polls, and needs hands on it.
    print("checking the running agent's addresses...")
    j = api(args.server, "/queue", {
        "kind": "pull", "path": r"C:\AI\AI.BAT", "timeout": args.timeout,
    })
    res = api(args.server, "/result/%s" % j["id"], timeout=args.timeout + 30)
    cur_srv = cur_up = None
    if res.get("blob_b64"):
        cur_text = base64.b64decode(res["blob_b64"]).decode("cp437", "replace")
        cur_srv, cur_up = agent_addresses(cur_text)

    print("  running : SRV=%s  UPHOST=%s" % (cur_srv, cur_up))
    print("  new     : SRV=%s  UPHOST=%s" % (new_srv, new_up))
    if cur_srv and (cur_srv != new_srv or cur_up != new_up):
        msg = ("the new agent points somewhere else. The box is reaching this\n"
               "      server on %s right now; sending an agent that uses %s\n"
               "      means it reboots, never polls, and needs someone at the\n"
               "      keyboard. Pass --force only if you are moving the server\n"
               "      on purpose." % (cur_srv, new_srv))
        if not force:
            die(msg)
        sys.stderr.write("dosctl: WARNING -- %s\n" % msg)

    if dry:
        print("\n--dry-run: agent NOT replaced")
        return 0

    # Append the end marker so the DOS side can prove the whole file arrived.
    staged = os.path.join(FILES_DIR, "agent")
    os.makedirs(staged, exist_ok=True)
    tmp = os.path.join(staged, "AI.BAT")
    body = new_text.replace("\r\n", "\n").rstrip("\n") + "\n"
    # The dev copy already ends with the marker (it is a whole agent file, not
    # a fragment), so only add one when it is missing -- otherwise every round
    # trip through pull-and-redeploy grows another.
    if not body.rstrip("\n").endswith(AGENT_END_LINE):
        body += AGENT_END_LINE + "\n"
    with open(tmp, "w", newline="\r\n") as fh:
        fh.write(body)
    print("staged agent/AI.BAT (%d bytes, end marker appended)"
          % os.path.getsize(tmp))

    job = api(args.server, "/queue", {
        "kind": "agent", "name": "agent/AI.BAT",
        "timeout": max(args.timeout, 180),
    })
    rc = await_result(args.server, job["id"], max(args.timeout, 180))
    if rc != 0:
        sys.stderr.write("dosctl: agent NOT replaced (rc=%d). The box is still\n"
                         "        running the old one, which is the safe outcome.\n" % rc)
        return rc
    if "##AGENT" not in LAST_OUTPUT.get("text", ""):
        sys.stderr.write("dosctl: no ##AGENT confirmation came back -- check the box\n")
        return 1

    if not wait_for_box(args.server, "agent swapped, rebooting"):
        sys.stderr.write(
            "dosctl: it did not come back. At the machine, boot to a prompt and\n"
            "        run:  COPY C:\\AI\\AI.BAK C:\\AI\\AI.BAT\n")
        return 124
    print("agent upgraded and the box is polling again.")
    return 0

def api(server, path, payload=None, timeout=300):
    url = "http://%s%s" % (server, path)
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        # Must come before URLError: HTTPError subclasses it, so the
        # order matters. dosd refusing a request is not dosd being
        # absent, and reporting it as "cannot reach dosd" sends people
        # off restarting a daemon that was working fine.
        try:
            msg = json.loads(e.read().decode()).get("error", "")
        except Exception:
            msg = ""
        die(msg or "server returned HTTP %s for %s" % (e.code, path))
    except urllib.error.URLError as e:
        die("cannot reach dosd at %s (%s).\n"
            "      Is 'python dosd.py' running?" % (server, e))


PROJECTS_DIR = os.path.join(HERE, "projects")
PROJ_RE = re.compile(r"^[A-Za-z0-9_]{1,8}$")


def check_project(name):
    """Project names seed a directory, a URL segment and an 8.3 filename, so
    they are held to the strictest of the three."""
    if not PROJ_RE.match(name or ""):
        die("'%s' is not a usable project name -- letters, digits and "
            "underscore, 8 characters max (it becomes a folder, a URL "
            "segment and an 8.3 filename)" % name)
    return name


def project_for(path):
    """Which staging namespace a source file belongs to, from where it lives.

    Deliberately positional rather than configured: the folder a file is in is
    the one thing that is always true and never drifts out of date.
    """
    full = os.path.abspath(path)
    root = os.path.abspath(HERE)
    if full.lower().startswith(os.path.join(root, "projects").lower() + os.sep):
        rest = full[len(os.path.join(root, "projects")) + 1:]
        return rest.split(os.sep)[0][:8].lower()
    if full.lower().startswith(os.path.join(root, "starter").lower() + os.sep):
        return "starter"
    return "local"


def resolve_staged(name):
    """Turn a bare NAME typed on the command line into a staged reference.

    Exact matches at the serving root win (EXIT0.COM lives there). Otherwise
    every project is searched, and finding it in more than one is an error --
    that ambiguity is precisely the collision projects exist to surface, so
    guessing here would defeat the point.
    """
    if "/" in name or "\\" in name:
        return name.replace("\\", "/")
    if os.path.isfile(os.path.join(FILES_DIR, name)):
        return name
    hits = []
    if os.path.isdir(FILES_DIR):
        for proj in sorted(os.listdir(FILES_DIR)):
            d = os.path.join(FILES_DIR, proj)
            if os.path.isdir(d) and os.path.isfile(os.path.join(d, name)):
                hits.append("%s/%s" % (proj, name))
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        die("'%s' is staged in more than one project: %s\n"
            "      Name it explicitly, e.g. %s"
            % (name, ", ".join(hits), hits[0]))
    return name


def die(msg):
    sys.stderr.write("dosctl: %s\n" % msg)
    sys.exit(2)


def stage(paths, project=None):
    """Copy files into files/<project>/ and return their staged references."""
    names = []
    for p in paths:
        if not os.path.isfile(p):
            die("no such file: %s" % p)
        name = os.path.basename(p).upper()
        if len(name.split(".")[0]) > 8:
            die("'%s' breaks DOS 8.3 naming -- rename it first" % name)
        proj = check_project(project or project_for(p))
        d = os.path.join(FILES_DIR, proj)
        os.makedirs(d, exist_ok=True)
        shutil.copy2(p, os.path.join(d, name))
        names.append("%s/%s" % (proj, name))
    return names


def await_result(server, job_id, timeout):
    res = api(server, "/result/%s" % job_id, timeout=timeout + 30)
    LAST_OUTPUT["text"] = res.get("output") or ""
    if res.get("error"):
        sys.stderr.write("dosctl: %s\n" % res["error"])
        return 124
    if res.get("output"):
        sys.stdout.write(res["output"].rstrip("\n") + "\n")
    rc = res.get("rc")
    return rc if rc is not None else 0


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("cmd", nargs="?")
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    ap.add_argument("--server", default=DEFAULT_SERVER)
    ap.add_argument("--out", default=None)
    ap.add_argument("--device", default=None)
    ap.add_argument("--project", default=None)
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--reboot", action="store_true")
    ap.add_argument("--cold", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")

    # split our flags out of the tail so program args pass through untouched
    argv, passthru = [], []
    it = iter(sys.argv[1:])
    for a in it:
        if a in ("--server", "--timeout", "--out", "--device", "--project"):
            argv += [a, next(it, "")]
        elif a in ("--reboot", "--cold", "-h", "--help"):
            argv.append(a)
        else:
            passthru.append(a)
    args = ap.parse_args(argv + passthru[:1])
    tail = passthru[1:]

    if args.help or not args.cmd:
        print(__doc__)
        return 0

    if args.cmd == "status":
        st = api(args.server, "/status")
        age = st.get("last_poll_secs_ago")
        if age is None:
            print("DOS box: never seen. Check AUTOEXEC.BAT and the firewall.")
        elif age < 20:
            print("DOS box: alive, polled %.1fs ago" % age)
        else:
            print("DOS box: STALE, last poll %.0fs ago (hung? powered off?)" % age)
        for ev in st.get("boot_events", []):
            print("  boot event: %s" % ev["event"])
        print("staged files: %s" % (", ".join(st.get("files", [])) or "(none)"))
        return 0

    if args.cmd == "reboot":
        api(args.server, "/queue", {"kind": "reboot", "cold": args.cold})
        print("reboot sent, waiting for the box to drop...")
        gone = False
        t0 = time.time()
        while time.time() - t0 < 240:
            time.sleep(2)
            age = api(args.server, "/status").get("last_poll_secs_ago")
            if age is None:
                continue
            if not gone and age > 15:
                gone = True
                print("  box is down, waiting for it to boot...")
            elif gone and age < 12:
                print("back up after %.0fs" % (time.time() - t0))
                return 0
        print("box did not come back within 240s -- check its screen")
        return 124

    if args.cmd == "stop":
        # Deliberately not "are you sure?" -- it is recoverable, just not from
        # here. Saying plainly what it costs is more useful than a prompt.
        print("Stopping the agent loop on the DOS box.")
        print("  This is a ONE-WAY door: once it stops, nothing on this side")
        print("  can reach the box. Restarting it needs someone at its")
        print("  keyboard (type C:\\AI\\AI.BAT) or a power cycle.")
        print()
        # COPY rather than "ECHO stop > FLG": build_raw_batch appends its own
        # ">> OUT.TXT" to every command, and two stdout redirections on one
        # line is COMMAND.COM behaviour I would rather not depend on. EXIT0.COM
        # is guaranteed present -- the generated batch just fetched it.
        job = api(args.server, "/queue", {
            "kind": "raw",
            "cmds": [r"COPY C:\AGENT\EXIT0.COM C:\AGENT\STOP.FLG",
                     r"IF EXIST C:\AGENT\STOP.FLG ECHO ##STOP-ARMED"],
            "timeout": args.timeout,
        })
        res = api(args.server, "/result/%s" % job["id"], timeout=args.timeout + 30)
        if res.get("error"):
            die("could not arm the stop flag: %s" % res["error"])
        if "##STOP-ARMED" not in (res.get("output") or ""):
            die("the stop flag was not created -- the agent is still running.\n"
                "      Check C:\\AGENT is writable on the box.")
        print("stop flag armed; the agent quits at the top of its next poll...")

        # The flag is read between jobs, so the box goes quiet within one poll
        # hold plus whatever job was already in flight. Watch it stop rather
        # than claiming success the moment the flag lands.
        t0 = time.time()
        while time.time() - t0 < 90:
            time.sleep(3)
            age = api(args.server, "/status").get("last_poll_secs_ago")
            if age is not None and age > 25:
                print("agent stopped after %.0fs -- the box is idle at a prompt"
                      % (time.time() - t0))
                return 0
        print("still polling after 90s -- the box may be busy with a long job,")
        print("or be running an agent that predates STOP.FLG support.")
        print("`dosctl version` says what build it is on.")
        return 1

    if args.cmd == "new":
        if not tail:
            die("new needs a project name, e.g. dosctl new mandel")
        name = check_project(tail[0].lower())
        d = os.path.join(PROJECTS_DIR, name)
        if os.path.isdir(d):
            die("projects/%s already exists" % name)
        os.makedirs(os.path.join(d, "build"))
        for fn, body in (
            ("build.cmd", BUILD_CMD),
            ("test.cmd", TEST_CMD),
            ("%s.pas" % name, MAIN_PAS),
            ("README.md", PROJ_README),
        ):
            with open(os.path.join(d, fn), "w", newline="\r\n") as fh:
                fh.write(body.replace("@@NAME@@", name))
        print("created projects\\%s\\" % name)
        print("  %s.pas      your program" % name)
        print("  build.cmd     compile it (FPC -> real-mode DOS)")
        print("  test.cmd      compile AND run it on the DOS box")
        print("  build\\        output; staged as %s/%s.EXE" % (name, name.upper()))
        print()
        print("cd projects\\%s  &&  test.cmd" % name)
        return 0

    if args.cmd == "version":
        n, dev = local_build()
        print("this bridge : build %s%s" % (n, "+" if dev else ""))
        box = read_box_version(args)
        if box is None:
            print("DOS machine : no %s -- it predates version stamping,"
                  % AGENT_VER_DOS)
            print("              or was installed by hand. `dosctl upgrade`"
                  " will write one.")
            return 1
        print("DOS machine :")
        for line in box.splitlines():
            print("              %s" % line.rstrip())
        return 0

    if args.cmd == "upgrade":
        dry = "--dry-run" in tail
        force = "--force" in tail
        want_tools = "--tools" in tail
        want_agent = "--agent" in tail
        if not want_tools and not want_agent:
            want_tools = want_agent = True
        box = read_box_version(args)
        n, dev = local_build()
        print("box is on   : %s" % (box.splitlines()[1].strip()
                                    if box and len(box.splitlines()) > 1
                                    else "unstamped (predates version stamping)"))
        print("sending     : build %s%s" % (n, "+" if dev else ""))

        rc = 0
        if want_tools:
            rc |= upgrade_tools(args, tail, dry, force)
        if want_agent:
            if want_tools:
                print()
            rc |= upgrade_agent(args, tail, dry, force)

        # Stamp last, and only on success: a version file claiming a build the
        # machine did not actually receive is worse than none at all.
        if rc == 0 and not dry:
            print()
            if write_box_version(args, "deployed") == 0:
                print("stamped %s with build %s%s"
                      % (AGENT_VER_DOS, n, "+" if dev else ""))
            else:
                sys.stderr.write("dosctl: upgrade worked but the version stamp"
                                 " failed to write\n")
        return 1 if rc else 0

    if args.cmd == "clean":
        deep = ("--all" in tail) or ("-a" in tail)
        gone, freed, stuck = clean_tree(deep)
        print("removed %d item(s), freed %.0f KB" % (gone, freed / 1024.0))
        if deep:
            print("built .EXEs went too -- rebuild starter/ before makeinst,")
            print("or the client half of the installer ships with no tools.")
        for t in stuck:
            print("  could not remove: %s" % t)
        return 1 if stuck else 0

    if args.cmd == "push":
        if not tail:
            die("push needs at least one file")
        print("staged: %s" % ", ".join(stage(tail, args.project)))
        return 0

    if args.cmd == "deploy":
        if not tail:
            die("deploy needs a file")
        name = stage([tail[0]], args.project)[0]
        dest = tail[1] if len(tail) > 1 else "C:\\WORK"
        job = api(args.server, "/queue", {
            "kind": "deploy", "name": name, "dest": dest,
            "timeout": args.timeout,
        })
        rc = await_result(args.server, job["id"], args.timeout)
        if rc == 0:
            sys.stderr.write("dosctl: deployed %s to %s\n" % (name, dest))
        return rc

    if args.cmd == "pull":
        if not tail:
            die("pull needs a path on the DOS box, e.g. C:\\AGENT\\AI.BAT")
        remote = tail[0]
        out = args.out or os.path.basename(remote.replace("\\", "/"))
        job = api(args.server, "/queue", {
            "kind": "pull", "path": remote, "timeout": args.timeout,
        })
        res = api(args.server, "/result/%s" % job["id"],
                  timeout=args.timeout + 30)
        if res.get("error"):
            sys.stderr.write("dosctl: %s\n" % res["error"])
            return 124
        if res.get("blob_b64") is None:
            # Only the not-found path reports on the text channel.
            if res.get("output"):
                sys.stdout.write(res["output"].rstrip("\n") + "\n")
            rc = res.get("rc")
            return rc if rc is not None else 1
        data = base64.b64decode(res["blob_b64"])
        with open(out, "wb") as fh:
            fh.write(data)
        sys.stderr.write("dosctl: pulled %s -> %s (%d bytes)\n"
                         % (remote, out, len(data)))
        return 0

    if args.cmd == "run":
        if not tail:
            die("run needs a program name")
        name = (stage([tail[0]], args.project)[0] if os.path.isfile(tail[0])
                else resolve_staged(tail[0].upper()))
        job = api(args.server, "/queue", {
            "kind": "run", "name": name, "args": " ".join(tail[1:]),
            "timeout": args.timeout, "reboot": args.reboot, "cold": args.cold,
        })
        return await_result(args.server, job["id"], args.timeout)

    if args.cmd == "drv":
        if not tail:
            die("drv needs a driver file")
        name = (stage([tail[0]], args.project)[0] if os.path.isfile(tail[0])
                else resolve_staged(tail[0].upper()))
        job = api(args.server, "/queue", {
            "kind": "driver", "name": name, "args": " ".join(tail[1:]),
            "timeout": max(args.timeout, 180), "cold": not args.reboot,
            "device": args.device,
        })
        sys.stderr.write("dosctl: staged %s, rebooting the DOS machine...\n" % name)
        rc = await_result(args.server, job["id"], max(args.timeout, 180))
        # ##BOOTOK only ever meant "the machine survived". If we were told what
        # device to expect, that check is the one that says whether it loaded.
        if rc == 0 and LAST_OUTPUT.get("text", "").find("##DEVFAIL") >= 0:
            sys.stderr.write(
                "dosctl: the machine survived but the driver did NOT register "
                "its device -- treating as failure\n")
            return 1
        if rc == 0 and args.device and "##DEVICE" not in LAST_OUTPUT.get("text", ""):
            sys.stderr.write(
                "dosctl: warning -- no device check came back; the agent on the "
                "box may predate this feature\n")
        return rc

    if args.cmd == "exec":
        if not tail:
            die("exec needs a command")

        # A job that reboots cannot send its result -- JOB.BAT dies with the
        # machine before it reaches the NC. Waiting for one is a guaranteed
        # timeout that then reports the box as hung, so switch to watching it
        # go down and come back instead, the way `dosctl reboot` does.
        ri = reboot_index(tail)
        if ri is not None:
            if ri != len(tail) - 1:
                sys.stderr.write(
                    "dosctl: '%s' reboots the machine -- the %d command(s) "
                    "after it will never run.\n"
                    % (tail[ri], len(tail) - ri - 1))
            if len(tail) == 1:
                sys.stderr.write(
                    "dosctl: this is what `dosreboot` is for; running it that "
                    "way so you get a result.\n")
            else:
                sys.stderr.write(
                    "dosctl: this job reboots the box, so no output can come "
                    "back from it.\n")
            api(args.server, "/queue", {
                "kind": "raw", "cmds": tail, "timeout": args.timeout,
            })
            return 0 if wait_for_box(args.server, "reboot sent") else 124

        job = api(args.server, "/queue", {
            "kind": "raw", "cmds": tail, "timeout": args.timeout,
        })
        return await_result(args.server, job["id"], args.timeout)

    die("unknown command '%s' "
        "(try: new clean upgrade version run push deploy pull drv exec "
        "reboot stop status)"
        % args.cmd)


if __name__ == "__main__":
    sys.exit(main())
