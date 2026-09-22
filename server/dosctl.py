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
  dosctl verify                     CRC-32 every tool on the box against the build
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
  dosctl boxes                      which DOS machines this bridge knows
  dosctl shutdown                   stop dosd itself (this machine only)
  dosctl power [status|on|off|cycle]  smart plug, if one is configured
        reset                       forget the cycle history
  dosctl capture devices            what capture hardware is on this machine
        modes                       what the configured device can produce
        status                      device present? is a picture arriving?
        live                        watch it live, with sound (q to quit)
                                    --mute, --scale WxH
        shot [FILE]                 one still of the DOS box's real screen
        rec SECS [FILE]             record it. --audio, --shots N
        burst N [--every S]         a series of stills, S seconds apart
        still REC SECS [FILE]       pull a frame out of a recording

`stop` leaves the DOS machine at a prompt with nothing polling, so nothing
here can reach it afterwards -- restarting means someone at its keyboard typing
C:\\AI\\AI.BAT, or a power cycle. Pressing Q on the box does the same thing.

Options: --timeout SECS (default 120), --reboot (reboot after run),
         --cold (cold boot instead of warm), --server HOST:PORT,
         --out PATH (where `pull` writes; default: basename in the cwd),
         --project NAME (which staging namespace to use; normally inferred),
         --box ID (which DOS machine; `--box all` runs on every one)

MORE THAN ONE DOS MACHINE. With a boxes.json registering several, every
command needs to know which one it means. In order: --box ID, then $DOSBOX,
then a .dosbox file at or above the working directory (so projects/foo/ can
pin itself to one machine), then "default" in boxes.json, then the sole
registered box. Ambiguity is a hard error listing the candidates, never a
guess -- a job that silently picks a machine returns a result that looks
entirely correct and simply ran on the wrong CPU.

`--box all` runs `run`, `exec` and `verify` on every machine at once and
prints the answers side by side with the differences called out. That is the
point of the whole thing: CLAUDE.md requires everything in starter/ to work
on both machines, and that requirement is otherwise enforced by a human
swapping an SD card and remembering.

With no boxes.json none of this applies and the bridge talks to one machine
exactly as it always has.

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
import threading
import time
import zlib
import urllib.error
import urllib.request

import boxes as boxreg

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
        "kind": "raw", "cmds": ["TYPE %s" % AGENT_VER_DOS], "timeout": args.timeout, "echo": False,
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


def agent_boxid(text):
    """The SET BOXID= an agent loop declares itself as, or None.

    BOXID is the same class of fact as the two addresses above, and for the
    same reason: it is per machine, it lives in a file that one template
    overwrites wholesale, and getting it wrong needs hands on a keyboard to
    find. Without this, `dosctl upgrade --agent` would stamp the template's
    id onto every box it touched and leave two machines claiming one
    identity -- the cloned-SD-card footgun arriving by a second route, from
    a command that is supposed to be routine.
    """
    for raw in text.splitlines():
        t = raw.strip()
        if t.upper().startswith("SET BOXID="):
            return t.split("=", 1)[1].strip() or None
    return None


def set_agent_boxid(text, box):
    """Rewrite SET BOXID= to `box`. Returns (text, how).

    Substitution rather than refusal, which is the opposite of what the
    address guard does, and deliberately: the addresses are the same for
    every machine on this bridge, so a mismatch there means somebody got
    something wrong. The id is different for every machine by definition,
    so one template can only ever carry one of them -- refusing would make
    upgrading the second box impossible.

    The value comes from boxes.json, which is the registry dosd routes on.
    Taking it from there rather than from the file being deployed is what
    stops the two disagreeing.
    """
    out, done = [], False
    for raw in text.splitlines(True):
        if raw.strip().upper().startswith("SET BOXID=") and not done:
            eol = "\r\n" if raw.endswith("\r\n") else "\n"
            out.append("SET BOXID=%s%s" % (box or "", eol))
            done = True
        else:
            out.append(raw)
    return "".join(out), ("rewritten" if done else "absent")


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


def poll_age(st, box=None):
    """How long since THIS box polled, from a /status body.

    The top-level `last_poll_secs_ago` is the newest poll from ANY machine,
    kept so an old dosctl still reads a new dosd. Watching a reboot with it
    would be a wrong-box bug of the worst kind: the other box polls every
    six seconds, so a machine that never came back would be declared healthy
    within two samples and the rollback instructions would never print.
    """
    box = box if box is not None else current_box()
    per = st.get("boxes") or {}
    if box and box in per:
        return per[box].get("last_poll_secs_ago")
    return st.get("last_poll_secs_ago")


def _watch_box(server, label, limit=420, back=30, assume_gone=False):
    """Watch the box drop and come back. Returns True if it returned.

    Both numbers were wrong, and on 2026-09-02 they reported an upgrade that
    had completely succeeded as a failure: the agent had swapped, the box was
    polling on the new loop, and dosctl printed rollback instructions and
    skipped the version stamp. Blaming the box for doing exactly what it was
    told is the failure this project keeps having to design against.

    `back` was 12 seconds, which is shorter than one poll CYCLE. A poll that
    gets no reply costs about 11 seconds and the offline branch waits 5 more,
    so a healthy box regularly shows a last-poll age above 12 and the return
    can be missed between samples. It has to exceed the worst NORMAL gap.

    `limit` was 240 seconds, and the polls right after a reboot are the least
    reliable ones: this host's ARP entry for the box has expired by then and
    our stack does not answer ARP, so several cycles fail before one gets
    through. Measured here: over five minutes to land the first poll after a
    swap.
    """
    if assume_gone:
        # After a power cut there is nothing to watch for: the box is
        # certainly down, and waiting to observe it going down would burn the
        # whole budget before we ever started waiting for it to come back.
        sys.stderr.write("dosctl: %s -- waiting for it to boot...\n" % label)
    else:
        sys.stderr.write("dosctl: %s -- waiting for the box to drop...\n"
                         % label)
    gone = assume_gone
    t0 = time.time()
    while time.time() - t0 < limit:
        time.sleep(2)
        age = poll_age(api(server, "/status"))
        if age is None:
            continue
        if not gone and age > 15:
            gone = True
            sys.stderr.write("dosctl:   down, waiting for it to boot...\n")
        elif gone and age < back:
            sys.stderr.write("dosctl: back up after %.0fs\n" % (time.time() - t0))
            return True
    sys.stderr.write("dosctl: box did not come back within %ds -- check its screen\n"
                     % limit)
    return False


def plug_config(quiet=True):
    """The smart-plug config, or None if the feature is not set up.

    None is the normal answer -- no power.json ships with the installer -- so
    every caller treats it as "no plug" and carries on. A config file that IS
    present but malformed is worth a word, because somebody meant it to work.
    """
    try:
        import power
    except ImportError:
        return None
    try:
        return power.load()
    except Exception as e:
        if not quiet:
            sys.stderr.write("dosctl: ignoring power config -- %s\n" % e)
        return None


def wait_for_box(server, label, limit=420, back=30, allow_power=True):
    """Wait for the box, and if it never comes back, try cutting its power.

    This is the whole point of the smart-plug support. Everything else in the
    bridge assumes a machine that is running well enough to poll; the failures
    that actually cost time -- a driver that hangs before the network is up, a
    card that freezes during POST -- leave nothing to talk to, and until now
    ended in somebody walking over to the machine.

    The retry is bounded by power.may_cycle, not by a count here, and those
    limits live on disk. A dosctl run in a loop therefore cannot turn a box
    that will never boot into a machine being power-cycled indefinitely --
    which is a far worse failure than the one being recovered from.
    """
    if _watch_box(server, label, limit, back):
        return True

    cfg = plug_config()
    if not cfg or not cfg.get("auto") or not allow_power:
        return False

    import power
    while True:
        ok, why = power.may_cycle(cfg)
        if not ok:
            sys.stderr.write("dosctl: not power-cycling -- %s\n" % why)
            return False
        sys.stderr.write("dosctl: power-cycling the DOS box...\n")
        try:
            power.cycle(cfg, log=lambda m: sys.stderr.write("dosctl: %s\n" % m))
        except Exception as e:
            sys.stderr.write("dosctl: power cycle failed -- %s\n" % e)
            return False
        if _watch_box(server, "powered back on", limit, back,
                      assume_gone=True):
            return True



# "  crc32 : 468D4151" as HD prints it.
CRC_LINE = re.compile(r"crc32\s*:\s*([0-9A-Fa-f]{8})")


def local_crc(path):
    with open(path, "rb") as fh:
        return zlib.crc32(fh.read()) & 0xFFFFFFFF


def build_path(build, name):
    """starter/build holds a mix of cases; the box is always upper."""
    p = os.path.join(build, name)
    return p if os.path.isfile(p) else os.path.join(build, name.lower())


def verify_tools(args, names, build, chunk=8):
    """CRC-32 the named tools on the DOS box against the local build.

    Deploying a tool was only ever confirmed with `IF EXIST`, and the
    pre-flight comparison in upgrade_tools is by SIZE -- so a transfer that
    arrived corrupted without changing length, or truncated to exactly the
    expected length, reported success either way. That is not hypothetical:
    when the box went silent after an upgrade on 2026-09-02 a silently bad
    UGET.EXE was the leading suspect, and there was no way to rule it out
    from this side. There is now.

    `HD` on the box produces the same CRC-32 as Python's `zlib.crc32` --
    proven on a 25,872-byte file -- so this needs no new tool on the DOS
    side. One job carries every check; a job per file would cost a round
    trip each.

    Each check is preceded by an `ECHO ##F=<name>` marker rather than trusting
    the crc32 lines to arrive in request order. A file that is missing makes
    `HD` print an error and no crc32 line at all, which without the markers
    would shift every later result by one and mis-report every tool after it.

    ASKED IN CHUNKS, and that is not a performance tweak. One job carrying
    all 41 checks produces a 40-odd line result, which is the largest payload
    the bridge ever asks a box to send -- and on a box with a weak link the
    whole result is what gets lost. Empty output then reached the code below
    as "no crc lines at all", which it reported as `HD.EXE is not on the
    box`: a healthy, fully-deployed toolset described as a missing tool, from
    the one command whose entire job is to tell you the truth. Measured on
    hardware 2026-09-21: five files per job answered 5/5 or 0/5 and never
    partially, so the cure is a smaller job, not a longer timeout.

    "NOT MEASURED" IS A THIRD ANSWER and is kept separate from MISSING. A
    file whose `##F=` marker arrived but which produced no crc32 line really
    is absent or unreadable -- the output reached that point. A file whose
    marker never arrived tells us nothing at all. Collapsing the two is
    exactly the mistake above, one level down.

    Returns (checked, [(name, want, got), ...], [unmeasured]), or
    (None, [], []) if the box genuinely has no HD.EXE.
    """
    if not names:
        return 0, [], []

    # Settle "is HD even there?" with one tiny job before asking anything
    # large. Its result is a single line, so it survives a link that loses
    # the big ones -- which is what makes the distinction trustworthy.
    probe = api(args.server, "/queue", {
        "kind": "raw", "timeout": max(args.timeout, 60), "echo": False,
        "cmds": ["IF EXIST %s\\HD.EXE ECHO ##HD-OK" % TOOLS_DIR_DOS],
    })
    pres = api(args.server, "/result/%s" % probe["id"],
               timeout=max(args.timeout, 60) + 30)
    if "##HD-OK" not in (pres.get("output") or ""):
        return None, [], []

    seen, unmeasured = {}, []
    for i in range(0, len(names), chunk):
        batch = names[i:i + chunk]
        cmds = []
        for n in batch:
            cmds.append("ECHO ##F=%s" % n)
            cmds.append("%s\\HD.EXE %s\\%s 0 1"
                        % (TOOLS_DIR_DOS, TOOLS_DIR_DOS, n))
        # HD reads the whole file to checksum it, and these are 8086 disk
        # reads. Budget per file rather than relying on the default.
        tmo = max(args.timeout, 30 + 4 * len(batch))

        marked = set()
        for attempt in (1, 2):
            job = api(args.server, "/queue", {
                "kind": "raw", "cmds": cmds, "timeout": tmo, "echo": False,
            })
            res = api(args.server, "/result/%s" % job["id"], timeout=tmo + 30)
            cur = None
            for line in (res.get("output") or "").splitlines():
                line = line.strip()
                if line.startswith("##F="):
                    cur = line[4:].strip().upper()
                    marked.add(cur)
                else:
                    m = CRC_LINE.match(line)
                    if m and cur:
                        seen[cur] = m.group(1).upper()
            # One retry, for a chunk whose result went missing entirely.
            # Retrying a chunk that answered would only cost time.
            if marked:
                break

        for n in batch:
            if n.upper() not in marked:
                unmeasured.append(n)

    bad = []
    for n in names:
        if n in unmeasured:
            continue
        want = "%08X" % local_crc(build_path(build, n))
        got = seen.get(n.upper(), "MISSING")
        if want != got:
            bad.append((n, want, got))
    return len(names) - len(unmeasured), bad, unmeasured


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
        "kind": "raw", "cmds": ["DIR %s" % TOOLS_DIR_DOS], "timeout": args.timeout, "echo": False,
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

    # Confirm what actually landed. Size said these files were different;
    # only a checksum says they are now right.
    #
    # Note carefully what a pass does and does not mean when some sends
    # failed. It says the box's copy matches the build -- NOT that the failed
    # send succeeded. A --force resend of a file that was already correct
    # fails harmlessly and still checksums clean, which is genuinely useful
    # (the failure cost nothing) but reads as "never mind" if the two numbers
    # are printed side by side without saying so.
    sent = [n for n, _ in todo]
    checked, mismatched, unmeasured = verify_tools(args, sent, build)
    if checked is None:
        print("not verified: %s\\HD.EXE is not on the box yet"
              % TOOLS_DIR_DOS)
    else:
        for name, want, got in mismatched:
            sys.stderr.write("dosctl: %s CORRUPT -- local %s, box %s\n"
                             % (name, want, got))
        print("checked by CRC-32: %d of %d on the box match the build"
              % (checked - len(mismatched), checked))
        # Said out loud rather than folded into the count. These were sent
        # and may well be fine; what is true is that nobody knows, and a
        # deploy reported as verified when part of it was never checked is
        # the quiet half-truth this whole command exists to avoid.
        if unmeasured:
            print("NOT CHECKED (no answer came back): %s"
                  % ", ".join(unmeasured))
            print("  Re-run `dosctl verify` -- these were deployed, but the")
            print("  box's reply was lost, so they are unproven either way.")
        if bad and not mismatched:
            print("  ...so the %d failed send(s) were harmless: the box already"
                  % bad)
            print("     held a correct copy. Still worth a retry to be sure.")
        bad += len(mismatched)
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
    cur_srv = cur_up = cur_box = None
    if res.get("blob_b64"):
        cur_text = base64.b64decode(res["blob_b64"]).decode("cp437", "replace")
        cur_srv, cur_up = agent_addresses(cur_text)
        cur_box = agent_boxid(cur_text)

    want_box = current_box()
    print("  running : SRV=%s  UPHOST=%s  BOXID=%s"
          % (cur_srv, cur_up, cur_box or "(none)"))
    print("  new     : SRV=%s  UPHOST=%s  BOXID=%s"
          % (new_srv, new_up, want_box or "(none)"))
    # Changing an id that is already set is a different act from setting one
    # for the first time: it renames a machine dosd is already routing to,
    # and the jobs queued for the old name then go nowhere.
    if cur_box and want_box and cur_box != want_box and not force:
        die("this box calls itself %s and boxes.json says it should be %s.\n"
            "      Renaming it means dosd routes to the new name while any\n"
            "      job queued under the old one waits for a machine that no\n"
            "      longer answers to it. Fix boxes.json, or pass --force if\n"
            "      the rename is what you want." % (cur_box, want_box))
    # A pull that failed leaves cur_srv None, and "None" must not read as
    # "checked and fine". This guard exists to stop the one mistake that
    # needs hands on the keyboard, so losing it silently to a dropped
    # packet is the worst way for it to go -- and the transport is flaky
    # enough that a single pull fails outright now and then. It did on the
    # very run that found this.
    if cur_srv is None:
        msg = ("could not read the running agent, so its addresses cannot be\n"
               "      checked against the new one. That check is what stops an\n"
               "      agent that boots, never polls and needs someone at the\n"
               "      keyboard. Try again -- a single pull fails now and then --\n"
               "      or pass --force to swap the agent unchecked.")
        if not force and not dry:
            die(msg)
        sys.stderr.write("dosctl: WARNING -- %s\n" % msg)

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
    # Stamp THIS machine's identity into the copy being deployed. One
    # template, one registry, and the per-box fact written in at the last
    # possible moment -- see set_agent_boxid().
    if want_box:
        body, how = set_agent_boxid(body, want_box)
        if how == "absent":
            sys.stderr.write(
                "dosctl: WARNING -- %s has no SET BOXID= line, so this box\n"
                "        will keep polling under the bare name. That still\n"
                "        works (dosd routes it by address), but the declared\n"
                "        identity cross-check is lost.\n" % src)
        else:
            print("stamped BOXID=%s into the agent being deployed" % want_box)
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

# Which machine this call means.
#
# Thread-local, not a plain global, because `--box all` runs the same command
# against every box CONCURRENTLY -- one thread each -- and a global would let
# two fan-out workers overwrite each other's target. That failure would be
# silent and would produce exactly the wrong-box result this design exists to
# make impossible.
#
# Injected in api() rather than threaded through thirty call sites. Every one
# of them already carries args.server the same way, and the alternative is a
# second thing to remember in each new command -- which is precisely how
# --quiet once fell through into the DOS command tail.
_target = threading.local()


def set_box(box):
    _target.box = box


def current_box():
    return getattr(_target, "box", None)


def api(server, path, payload=None, timeout=300, soft=False):
    """`soft` returns None instead of dying when dosd is not there.

    Only for commands that are still useful without it -- `dosctl boxes`
    answers "what machines are registered", which is a question about a
    config file and should not depend on a daemon being up.
    """
    if path == "/queue" and isinstance(payload, dict) and "box" not in payload:
        box = current_box()
        if box:
            payload = dict(payload, box=box)
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
        if soft:
            return None
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


# A command that could not be executed. 127 is the conventional shell code
# for it, and it cannot collide with a DOS program's own exit status: the
# ERRORLEVEL ladder in dosd.py stops at 20.
RC_NOEXEC = 127

NOEXEC_MARK = "##NOEXEC="


def split_noexec(text):
    """Lift the not-found markers out of a job's output.

    Returns (clean_output, [programs]). The marker is written by the batch
    with ECHO, and COMMAND.COM leaves the space that preceded the redirection
    on the end of the line, so it always arrives with trailing whitespace.
    """
    keep, missing = [], []
    for ln in (text or "").splitlines():
        s = ln.strip()
        if s.startswith(NOEXEC_MARK):
            prog = s[len(NOEXEC_MARK):].strip()
            if prog:
                missing.append(prog)
        else:
            keep.append(ln)
    return "\n".join(keep), missing


def looks_external(cmd):
    """Might this command line have run a program, rather than a builtin?"""
    tok = cmd.strip().split()
    if not tok:
        return False
    word = tok[0].split("\\")[-1]
    if "." in word:
        word = word.rsplit(".", 1)[0]
    return word.upper() not in (
        "ECHO", "SET", "REM", "CD", "CHDIR", "MD", "MKDIR", "RD", "RMDIR",
        "DEL", "ERASE", "COPY", "REN", "RENAME", "TYPE", "DIR", "CLS",
        "PATH", "PROMPT", "VER", "VOL", "DATE", "TIME", "PAUSE", "GOTO",
        "IF", "FOR", "CALL", "SHIFT", "EXIT", "VERIFY", "BREAK", "CTTY")


def await_result(server, job_id, timeout, cmds=None):
    res = api(server, "/result/%s" % job_id, timeout=timeout + 30)
    out, missing = split_noexec(res.get("output"))
    LAST_OUTPUT["text"] = out
    if res.get("error"):
        sys.stderr.write("dosctl: %s\n" % res["error"])
        return 124
    if out.strip():
        sys.stdout.write(out.rstrip("\n") + "\n")

    rc = res.get("rc")
    rc = rc if rc is not None else 0

    # A program that is not there. The DOS box said so on its own screen and
    # had no way to tell us: COMMAND.COM writes "Bad command or file name" to
    # a console 6.22 cannot redirect, and leaves ERRORLEVEL alone -- which
    # EXIT0.COM has just forced to 0. Without this the job reports success.
    if missing:
        for p in missing:
            sys.stderr.write("dosctl: not found on the DOS box: %s\n" % p)
        sys.stderr.write(
            "dosctl: the box printed \"Bad command or file name\" on its own "
            "screen.\n"
            "        COMMAND.COM writes that to a console this bridge cannot "
            "capture,\n"
            "        and it leaves ERRORLEVEL untouched, so the job would "
            "otherwise\n"
            "        have reported rc 0 with no output at all.\n")
        return RC_NOEXEC if rc == 0 else rc

    # The general case: nothing came back, and nothing can prove why. Only
    # worth saying when a command could actually have been a program -- a job
    # made of DEL and SET is legitimately silent and should stay quiet.
    if (not out.strip() and rc == 0 and cmds
            and any(looks_external(c) for c in cmds)):
        sys.stderr.write(
            "dosctl: no output, and rc 0 -- but nothing here proves the "
            "command ran.\n"
            "        DOS internal commands never set ERRORLEVEL, and a "
            "missing program\n"
            "        reports exactly this. If you expected output, check the "
            "DOS screen.\n")
    return rc


# ---------------------------------------------------------------------------
# Fan-out: the same job on every machine at once
#
# This is the reason the rest of it is worth building. CLAUDE.md already
# REQUIRES that everything in starter/ runs on both machines -- "gate a
# faster path at run time, never at compile time" -- and until now that
# requirement was enforced by a human swapping an SD card and remembering.
#
# Both faults the 386 ever found (FPC's runtime hooking INT 10h, and
# CH375Camera counting packets where it should have measured time) were found
# by moving machines and noticing a difference. Surfacing that difference
# automatically is the highest-value thing here.
#
# Dispatch is parallel -- different addresses, independent queues, and dosd is
# already threaded. Within a box, jobs stay strictly serialised for free,
# because the queue is drained by a machine that polls, CALLs one JOB.BAT, and
# only then polls again.
# ---------------------------------------------------------------------------

def fan_out(server, box_ids, make_payload, timeout):
    """Run one job per box concurrently. {box: {"rc":..,"output":..}}.

    Nothing prints from inside a worker: two machines writing to one console
    interleave, and the whole value of this is being able to READ the
    difference between them.
    """
    results, lock = {}, threading.Lock()

    def worker(box):
        set_box(box)
        row = {"rc": None, "output": "", "error": None}
        try:
            job = api(server, "/queue", make_payload(box))
            res = api(server, "/result/%s" % job["id"], timeout=timeout + 30)
            if res.get("error"):
                row["error"] = res["error"]
            else:
                out, missing = split_noexec(res.get("output"))
                row["output"] = out or ""
                row["rc"] = res.get("rc")
                if missing:
                    row["error"] = ("not on this box: %s"
                                    % ", ".join(missing))
                    if not row["rc"]:
                        row["rc"] = RC_NOEXEC
        except SystemExit as e:           # die() inside api()
            row["error"] = "dosctl: %s" % e
        with lock:
            results[box] = row

    threads = [threading.Thread(target=worker, args=(b,), daemon=True)
               for b in box_ids]
    for t in threads:
        t.start()
    for t in threads:
        # Generous: the per-job timeout is enforced by dosd, and a worker
        # that outlives it is a bug worth seeing rather than hiding behind
        # a join that gives up first.
        t.join(timeout + 120)
    return results


def first_difference(a, b):
    """1-based line number where two outputs first differ, or None."""
    la, lb = a.splitlines(), b.splitlines()
    for i in range(max(len(la), len(lb))):
        if (la[i] if i < len(la) else None) != (lb[i] if i < len(lb) else None):
            return i + 1
    return None


def report_fanout(results, box_ids, label):
    """The table, then the diff. Returns the exit code for the whole run.

    Not two logs end to end: a column per machine, so the eye lands on the
    row that differs. Which machine ran it is the single most important fact
    about any result these boxes produce, so it heads every column.
    """
    # A worker that died without recording anything must not take the whole
    # report down with a KeyError -- the missing answer IS the finding.
    for b in box_ids:
        results.setdefault(b, {"rc": None, "output": "",
                               "error": "no answer from this box"})
    w = max(12, max(len(b) for b in box_ids) + 2)
    print()
    print("%-14s%s" % ("", "".join("%-*s" % (w, b) for b in box_ids)))
    print("%-14s%s" % ("rc", "".join(
        "%-*s" % (w, "ERR" if results[b].get("error")
                  else results[b].get("rc")) for b in box_ids)))
    print("%-14s%s" % ("lines out", "".join(
        "%-*d" % (w, len((results[b].get("output") or "").splitlines()))
        for b in box_ids)))

    for b in box_ids:
        if results[b].get("error"):
            print("  %-10s %s" % (b, results[b]["error"]))

    # Every output, in full, under the table. A one-line summary of a
    # difference is not enough to act on and the whole point is comparison.
    for b in box_ids:
        out = (results[b].get("output") or "").rstrip("\n")
        print()
        print("--- %s : %s ---" % (b, label))
        print(out if out else "(no output)")

    base = box_ids[0]
    same = True
    for b in box_ids[1:]:
        d = first_difference(results[base].get("output") or "",
                             results[b].get("output") or "")
        if d is not None:
            same = False
            print()
            print("--- %s and %s first differ at line %d ---" % (base, b, d))
    rcs = {b: results[b].get("rc") for b in box_ids}
    if same and len(set(rcs.values())) == 1:
        print()
        print("identical on %s" % ", ".join(box_ids))

    # Non-zero if ANY box failed. A fan-out that reports success because one
    # machine was happy is worse than not running it.
    bad = [b for b in box_ids
           if results[b].get("error") or (results[b].get("rc") or 0) != 0]
    return 1 if bad else 0


def status_board(st, server):
    """Print the per-box liveness table, or the single-box line."""
    per = st.get("boxes") or {}
    if not st.get("multibox") or len(per) <= 1:
        # Unchanged wording. This is what every note in CLAUDE.md quotes,
        # and what people grep for.
        age = st.get("last_poll_secs_ago")
        if age is None:
            print("DOS box: never seen. Check AUTOEXEC.BAT and the firewall.")
        elif age < 20:
            print("DOS box: alive, polled %.1fs ago" % age)
        else:
            print("DOS box: STALE, last poll %.0fs ago (hung? powered off?)"
                  % age)
        return

    # One box being down must not read as the whole bridge being down, so
    # every machine gets its own row and its own verdict.
    print("%-8s %-15s %-26s %s" % ("box", "address", "state", "queue"))
    for b in sorted(per):
        row = per[b]
        age = row.get("last_poll_secs_ago")
        if age is None:
            state = "never seen"
        elif age < 20:
            state = "alive, polled %.1fs ago" % age
        else:
            state = "STALE, %.0fs ago" % age
        note = ""
        if row.get("busy"):
            note = "busy: %s" % row["busy"]
        elif row.get("queued"):
            note = "%d queued" % row["queued"]
        if not row.get("registered"):
            note = (note + "  ") if note else ""
            note += "NOT in boxes.json"
        print("%-8s %-15s %-26s %s"
              % (b, row.get("ip") or "-", state, note))
    for b in sorted(per):
        if per[b].get("desc"):
            print("  %-6s %s" % (b, per[b]["desc"]))


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("cmd", nargs="?")
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    ap.add_argument("--server", default=DEFAULT_SERVER)
    ap.add_argument("--out", default=None)
    ap.add_argument("--device", default=None)
    ap.add_argument("--project", default=None)
    ap.add_argument("--box", default=None)
    # NOTE: --all is deliberately NOT a parser flag. The tail splitter below
    # derives its flag list from this parser, so registering --all here would
    # lift it out of the command tail -- and `clean --all` reads it FROM the
    # tail. That is the same trap --quiet fell into, in reverse: there, a
    # flag missing from the list fell through to the DOS box; here, a flag
    # added to it would be stolen from the command that already owns it.
    # `verify --all` reads the tail for the same reason.
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--quiet", action="store_true",
                    help="do not dump this job's output on the DOS console")
    ap.add_argument("--reboot", action="store_true")
    ap.add_argument("--cold", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")

    # Split our flags out of the tail so program args pass through untouched.
    #
    # These two lists used to be written out by hand here, and that broke the
    # moment --quiet was added to the parser above without being added here as
    # well: it fell straight through into the command tail, and the DOS box
    # tried to EXECUTE it -- "Bad command or file name", and a job that
    # reported running two commands when it was given one.
    #
    # So derive them from the parser. argparse's _actions is a private
    # attribute, which is worth it here: the alternative is a second list that
    # has to be kept in step with the first, and that is precisely what just
    # failed. If a future argparse renames it this crashes immediately and
    # loudly, which is the opposite of the silent misparse it replaces.
    takes_value, is_flag = set(), set()
    for act in ap._actions:
        for opt in act.option_strings:
            (is_flag if act.nargs == 0 else takes_value).add(opt)

    argv, passthru = [], []
    it = iter(sys.argv[1:])
    for a in it:
        if a in takes_value:
            argv += [a, next(it, "")]
        elif a in is_flag:
            argv.append(a)
        else:
            passthru.append(a)
    args = ap.parse_args(argv + passthru[:1])
    tail = passthru[1:]

    if args.help or not args.cmd:
        print(__doc__)
        return 0

    # Which machine, decided once, for everything below. api() carries it on
    # to dosd from here -- see set_box().
    try:
        reg = boxreg.load()
        want = args.box
        if want is None and "--all" in tail and args.cmd in ("verify", "run",
                                                             "exec", "status"):
            want = "all"
        box, how = boxreg.resolve(want)
    except boxreg.BoxError as e:
        die(str(e))
    all_ids = sorted(reg["boxes"]) if reg else []
    fan = (box == "all")
    set_box(None if fan else box)

    if args.cmd == "boxes":
        if not reg:
            print("No boxes.json -- this bridge talks to one DOS machine.")
            print()
            print("  A registry is only needed for more than one. To add")
            print("  it, copy boxes.example.json to boxes.json and list")
            print("  your machines there.")
            return 0
        st = api(args.server, "/status", soft=True) or {}
        per = st.get("boxes") or {}
        print("%-8s %-15s %-22s %s" % ("box", "address", "state", "what"))
        for b in all_ids:
            age = (per.get(b) or {}).get("last_poll_secs_ago")
            state = ("never seen" if age is None else
                     "alive, %.0fs ago" % age if age < 20 else
                     "STALE, %.0fs ago" % age)
            marks = []
            if b == reg["default"]:
                marks.append("default")
            if boxreg.overrides(b, "capture", reg) is not None:
                marks.append("capture")
            if boxreg.overrides(b, "power", reg) is not None:
                marks.append("plug")
            print("%-8s %-15s %-22s %s"
                  % (b, boxreg.ip_of(b, reg), state,
                     boxreg.desc_of(b, reg)))
            if marks:
                print("%-8s %-15s %-22s %s" % ("", "", "", ", ".join(marks)))
        print()
        print("this command would target: %s%s"
              % (box, "  (%s)" % how if how else ""))
        if not st:
            print("(dosd is not running, so no liveness is shown)")
        return 0

    # `--box all` only means something for commands that can be compared.
    # Anything else must refuse rather than quietly running on the default:
    # a `dosctl stop --box all` that stopped one machine and reported
    # nothing about the other is exactly the wrong-box result this is
    # arranged to prevent.
    FANNABLE = ("run", "exec", "verify", "status", "boxes")
    if fan and args.cmd not in FANNABLE:
        die("--box all works for %s, not for %s. Say which machine."
            % (", ".join(FANNABLE), args.cmd))

    # The two commands whose mistake needs hands on a keyboard to undo.
    # Both refuse a default: you have to say which machine out loud.
    if len(all_ids) > 1 and not (args.box or os.environ.get("DOSBOX")):
        one_way = (args.cmd == "stop"
                   or (args.cmd == "power" and tail and tail[0].lower()
                       in ("cycle", "off")))
        if one_way:
            die("%s needs --box said out loud when there is more than one\n"
                "      machine (%s). Cutting power to, or stopping the agent\n"
                "      on, the wrong box is undone with hands on a keyboard."
                % (args.cmd, ", ".join(all_ids)))

    if args.cmd == "verify":
        build = os.path.join(HERE, "starter", "build")
        if not os.path.isdir(build):
            die("no starter/build -- nothing to compare the box against")
        names = sorted(f.upper() for f in os.listdir(build)
                       if f.lower().endswith((".exe", ".com")))
        if not names:
            die("starter/build has no .EXE or .COM")
        print("CRC-32 checking %d tool(s) in %s against starter/build."
              % (len(names), TOOLS_DIR_DOS))
        print("HD reads every byte on an 8086, so give it a minute.")

        if fan:
            # The drift alarm. Both machines are supposed to run ONE
            # identical C:\TOOLS -- one binary, gated at run time -- and
            # that property used to be free because there was one SD card.
            # With two it has to be checked, as routine rather than as a
            # special occasion.
            print("checking %s" % ", ".join(all_ids))
            rows, lock = {}, threading.Lock()

            def check(b):
                set_box(b)
                try:
                    got = verify_tools(args, names, build)
                except SystemExit as e:          # die() inside api()
                    got = ("ERR", str(e), [])
                with lock:
                    rows[b] = got

            ts = [threading.Thread(target=check, args=(b,), daemon=True)
                  for b in all_ids]
            for t in ts:
                t.start()
            for t in ts:
                t.join(args.timeout + 240)

            rc = 0
            for b in all_ids:
                got = rows.get(b)
                print()
                if got is None:
                    print("%-8s no answer" % b)
                    rc = 1
                    continue
                checked, mismatched, unmeasured = got
                if checked == "ERR":
                    print("%-8s %s" % (b, mismatched))
                    rc = 1
                elif checked is None:
                    print("%-8s no HD.EXE on the box -- cannot verify" % b)
                    rc = 1
                else:
                    print("%-8s %d checked, %d match, %d differ"
                          % (b, checked, checked - len(mismatched),
                             len(mismatched)))
                    for name, wantc, gotc in mismatched:
                        print("         %-14s local %s  box %s"
                              % (name, wantc, gotc))
                    # Unproven, not passed. A drift alarm that stays quiet
                    # about the files it could not read is worse than one
                    # that says so, because the silence reads as a pass.
                    if unmeasured:
                        print("         NOT CHECKED (no reply): %s"
                              % ", ".join(unmeasured))
                        rc = 1
                    if mismatched:
                        rc = 1
            return rc

        checked, mismatched, unmeasured = verify_tools(args, names, build)
        if checked is None:
            die("%s\\HD.EXE is not on the box -- cannot verify" % TOOLS_DIR_DOS)
        for name, want, got in mismatched:
            print("  %-14s %s  local %s  box %s"
                  % (name, "MISSING" if got == "MISSING" else "MISMATCH",
                     want, got))
        print()
        print("%d checked, %d match, %d differ"
              % (checked, checked - len(mismatched), len(mismatched)))
        # A file nobody could read is not a file that passed. Reported
        # separately and counted as a failure, because the whole value of
        # this command is that a clean run means something.
        if unmeasured:
            print("%d NOT CHECKED -- no reply came back for: %s"
                  % (len(unmeasured), ", ".join(unmeasured)))
            print("Re-run to settle them; they are unproven, not wrong.")
        return 1 if (mismatched or unmeasured) else 0

    if args.cmd == "shutdown":
        # Not api(): dosd answers this in plain text, because a daemon on its
        # way down is a poor moment to depend on anything more elaborate.
        url = "http://%s/shutdown" % args.server
        try:
            with urllib.request.urlopen(
                    urllib.request.Request(url, data=b""), timeout=10) as r:
                r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                die("the running dosd predates this command. Stop it with "
                    "Ctrl-C in\n      its window and restart it; after that "
                    "`dosctl shutdown` works.")
            die("dosd refused: %s" % e.read().decode(errors="replace").strip())
        except urllib.error.URLError:
            print("dosd is not running at %s -- nothing to stop." % args.server)
            return 0
        # Confirm it actually went, rather than reporting the request as the
        # outcome. The same mistake as calling an upgrade successful because
        # the batch was sent.
        for _ in range(20):
            time.sleep(0.25)
            try:
                urllib.request.urlopen(
                    "http://%s/status" % args.server, timeout=2).read()
            except Exception:
                print("dosd stopped.")
                return 0
        print("dosd acknowledged the request but is still answering.")
        return 1

    if args.cmd == "power":
        try:
            import power
        except ImportError:
            die("power.py is missing from %s" % HERE)

        # A plug that is not this box's must not answer for it. Cutting
        # power to the wrong machine is item 6 on the risk list in
        # docs/multibox.md and the only recovery is a person standing in
        # front of it.
        pov = boxreg.overrides(box, "power", reg) if reg else {}
        if reg and pov is None:
            die("no smart plug is configured for %s.\n"
                "      %s has one; this box does not, and falling back to it\n"
                "      would cut power to the wrong machine."
                % (box, ", ".join(b for b in all_ids
                                  if boxreg.overrides(b, "power", reg)
                                  is not None) or "another box"))
        power.set_scope(box if reg else None, pov or {})
        # `tail`, not args.rest: the parser only ever sees the first
        # passthru word (it becomes args.cmd), so args.rest is always empty
        # here and every action silently read as "status".
        action = (tail[0].lower()
                  if tail and not tail[0].startswith("-")
                  else "status")
        force = "--force" in tail

        if action == "reset":
            power.reset_history()
            print("power: cycle history cleared")
            return 0

        try:
            cfg = power.load()
        except power.PowerError as e:
            die(str(e))
        if cfg is None:
            print("No smart plug configured.")
            print()
            print("  Smart-plug support is optional and off by default. To")
            print("  enable it, copy power.example.json to power.json and")
            print("  fill in your plug's model and address:")
            print()
            print("      copy power.example.json power.json")
            print()
            print("  Tested: Shelly Gen2/3/4. Also written, but never run")
            print("  against hardware: shelly-gen1, tasmota, kasa,")
            print("  homeassistant, and a generic http driver you point at")
            print("  your own URLs.")
            return 1

        try:
            if action == "status":
                d, st, line = power.describe(cfg)
                print("plug    : %s at %s" % (d.name, cfg.get("host") or "-"))
                try:
                    print("device  : %s" % d.info())
                except power.PowerError:
                    pass
                print("state   : %s" % line)
                # Power draw is the useful part: it separates a machine that
                # is off from one that has power and has hung, and those need
                # opposite responses.
                if st.get("on") and st.get("watts") is not None:
                    print("          %s"
                          % ("drawing current, so the machine has power"
                             if st["watts"] > 2 else
                             "on, but drawing almost nothing -- the machine "
                             "itself may be off"))
                hist = power.recent_cycles(cfg)
                print("cycles  : %d in the last %.0f min (max %d)"
                      % (len(hist), float(cfg.get("window_secs") or 3600) / 60,
                         int(cfg.get("max_cycles") or 3)))
                return 0

            if action in ("on", "off"):
                power.driver(cfg).set(action == "on")
                print("power: switched %s" % action.upper())
                return 0

            if action == "cycle":
                # Ask the guards BEFORE announcing anything. The warning used
                # to print first, so a refused attempt still told you the
                # machine had just been hard-cut when nothing had happened --
                # exactly the kind of misreporting this project keeps having
                # to design against.
                allowed, why = power.may_cycle(cfg, force=force)
                if not allowed:
                    die(why)
                print("Power-cycling the DOS box. This is a HARD cut -- the")
                print("same as pulling the plug, with no chance for DOS to")
                print("flush anything it has open.")
                power.cycle(cfg, force=force)
                return 0
        except power.PowerError as e:
            die(str(e))

        die("unknown power action %r -- use status, on, off, cycle or reset"
            % action)

    if args.cmd == "capture":
        try:
            import capture
        except ImportError:
            die("capture.py is missing from %s" % HERE)

        # THE WRONG-SCREEN GUARD, and it is the important one.
        #
        # Every visual verification in this project's history would have
        # been reasoned about confidently and wrongly if the picture had
        # come from the other machine: the magenta screen, the see-through
        # cars, the sun centroid at +4.5 then -3.4. A capture that silently
        # shows the wrong box does not produce a wrong answer, it produces
        # a CONVINCING one -- so with no device for this box, refuse.
        cov = boxreg.overrides(box, "capture", reg) if reg else {}
        has = [b for b in all_ids
               if boxreg.overrides(b, "capture", reg) is not None]
        # `devices` is exempt: it enumerates this PC's hardware and is what
        # you run in order to write the config in the first place, so it
        # cannot require a box that is already configured.
        asked = tail[0].lower() if tail else "status"
        if reg and cov is None and asked != "devices":
            die("no capture device is configured for %s.\n"
                "      %s has one. Showing you that screen instead would be\n"
                "      worse than showing you nothing."
                % (box, ", ".join(has) if has else "No box"))
        capture.set_scope(box if reg else None, cov or {})

        # `tail`, not args.rest -- same trap the power block documents above.
        words = [t for t in tail if not t.startswith("-")]
        action = words[0].lower() if words else "status"
        rest = words[1:]

        def flag(name):
            return name in tail

        def opt(name, default=None):
            """Values for flags the main parser does not know about: argparse
            leaves both the flag and its value in the tail."""
            if name in tail:
                i = tail.index(name)
                if i + 1 < len(tail):
                    v = tail[i + 1]
                    if v in rest:
                        rest.remove(v)
                    return v
            return default

        scale = opt("--scale")
        shots = int(opt("--shots", 0) or 0)

        try:
            # `devices` deliberately works with no capture.json, because it
            # is what you need in order to write one.
            if action == "devices":
                video, audio = capture.list_devices(capture.load()
                                                    if os.path.isfile(
                                                        capture.CONFIG_PATH)
                                                    else None)
                print("video capture devices:")
                for v in video or ["  (none)"]:
                    print("  %s" % v)
                print()
                print("audio capture devices:")
                for a in audio or ["  (none)"]:
                    print("  %s" % a)
                if video:
                    print()
                    print("To enable capture, copy capture.example.json to")
                    print("capture.json and set:")
                    print()
                    # Only offer a value when there is no choice to get wrong.
                    # A webcam and a capture card look identical from here,
                    # and naming the webcam because it sorted first would be
                    # a confident wrong answer rather than no answer.
                    if len(video) == 1:
                        print('    "device": %s,' % json.dumps(video[0]))
                    else:
                        print('    "device": "<one of the %d above>",'
                              % len(video))
                    if len(audio) == 1:
                        print('    "audio_device": %s' % json.dumps(audio[0]))
                    elif audio:
                        print('    "audio_device": "<the one on the same '
                              'card, or null>"')
                    print()
                    print("The name must match exactly. `doscap modes` then")
                    print("says what that device can actually produce.")
                return 0

            cfg = capture.load()
        except capture.CaptureError as e:
            die(str(e))

        if cfg is None:
            print("No capture device configured.")
            print()
            print("  Video capture is optional and off by default. It lets")
            print("  this bridge SEE the DOS box's real video output -- POST,")
            print("  the F1 prompt, a frozen screen, a graphical demo as it")
            print("  actually renders -- none of which can go through DOS.")
            print()
            print("      python dosctl.py capture devices")
            print("      copy capture.example.json capture.json")
            print()
            print("  Then edit capture.json with the device name it printed.")
            return 1

        try:
            if action == "status":
                info = capture.describe(cfg)
                print("ffmpeg  : %s" % info["ffmpeg"])
                print("device  : %s%s" % (info["device"],
                                          "" if info["present"]
                                          else "   ** NOT FOUND **"))
                if info.get("audio_device"):
                    print("audio   : %s%s" % (info["audio_device"],
                                              "" if info["audio_present"]
                                              else "   ** NOT FOUND **"))
                if not info["present"]:
                    print()
                    print("Devices that ARE present:")
                    for v in info["video_devices"] or ["  (none)"]:
                        print("  %s" % v)
                    return 1
                print("format  : %s %s @ %s fps"
                      % (cfg["video_size"], cfg["pixel_format"],
                         cfg["framerate"]))
                print("frame   : %s in %.1fs"
                      % (info["verdict"], info["shot_secs"]))
                print("          %s" % info["detail"])
                print("saved   : %s" % info["shot"])
                return 0

            if action == "modes":
                modes = capture.list_modes(cfg)
                if not modes:
                    die("the device listed no modes -- is it in use?")
                print("%-10s %-12s %s" % ("format", "size", "max fps"))
                for fmt, size, fps in modes:
                    print("%-10s %-12s %s" % (fmt or "?", size, fps))
                return 0

            if action == "shot":
                p = capture.shot(cfg, rest[0] if rest else None, scale=scale)
                verdict, detail = capture.analyse(p)
                print("%s" % p)
                print("  %s -- %s" % (verdict, detail))
                return 0

            if action == "rec":
                if not rest:
                    die("how many seconds? e.g. doscap rec 20")
                try:
                    secs = float(rest[0])
                except ValueError:
                    die("rec wants seconds, not %r" % rest[0])
                path, made = capture.record(
                    cfg, secs, rest[1] if len(rest) > 1 else None,
                    audio=flag("--audio"), shots=shots)
                print("%s" % path)
                for m in made:
                    print("  %s" % m)
                return 0

            if action == "live":
                print("Live preview -- press q or Esc in the window to quit.")
                print("The device is exclusive, so no shot or rec can run")
                print("while this is open.")
                print()
                print("If it looks frozen it probably is not: an idle DOS")
                print("console is a still image apart from UGET's spinner.")
                print("Run MATRIX or RAYCAST to see it move.")
                # Sound is on by default; --mute turns it off. Note --quiet
                # cannot be used for that: it is a real dosctl flag, so
                # argparse eats it before this code ever sees the tail.
                want = None
                if flag("--mute") or flag("--no-audio"):
                    want = False
                elif flag("--audio"):
                    want = True
                print()
                if want is False:
                    print("Muted.")
                else:
                    print("With sound, played by a second windowless process")
                    print("so neither stream is synced to the other. HDMI")
                    print("carries the SOUND CARD only -- the PC speaker is a")
                    print("separate buzzer and never reaches the capture.")
                return capture.live(cfg, scale, audio=want)

            if action == "burst":
                if not rest:
                    die("how many frames? e.g. doscap burst 6 --every 2")
                n = int(rest[0])
                every = float(opt("--every", 2.0))
                for p in capture.burst(cfg, n, every):
                    print("%s" % p)
                return 0

            if action == "still":
                if len(rest) < 2:
                    die("usage: doscap still <recording> <seconds> [out.png]")
                p = capture.still(cfg, rest[0], float(rest[1]),
                                  rest[2] if len(rest) > 2 else None)
                print("%s" % p)
                return 0
        except capture.CaptureError as e:
            die(str(e))

        die("unknown capture action %r -- use devices, modes, status, live, "
            "shot, rec, burst or still" % action)

    if args.cmd == "status":
        st = api(args.server, "/status")
        status_board(st, args.server)
        for ev in st.get("boot_events", []):
            print("  boot event: %s%s"
                  % (("[%s] " % ev["box"]) if ev.get("box")
                     and st.get("multibox") else "", ev["event"]))
        # A count, not the list. This tree stages well over two hundred
        # files and the roll call buried the two lines that answer the
        # question status is asked: is the box alive, and did it boot
        # cleanly. `--files` still prints them.
        files = st.get("files", [])
        if "--files" in tail:
            print("staged files: %s" % (", ".join(files) or "(none)"))
        else:
            print("staged files: %d  (--files to list them)" % len(files))
        return 0

    if args.cmd == "reboot":
        api(args.server, "/queue", {"kind": "reboot", "cold": args.cold})
        # This was a second, hand-copied version of wait_for_box's loop,
        # carrying the same two wrong thresholds -- so fixing them meant
        # finding both, and the copies had already drifted in their wording.
        if wait_for_box(args.server, "reboot sent"):
            return 0
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
            "timeout": args.timeout, "echo": False,
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
            age = poll_age(api(args.server, "/status"))
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
        payload = {
            "kind": "run", "name": name,
            # --all is ours, not the DOS program's. Without this it would be
            # passed through as an argument to whatever is being run, which
            # is the exact shape of the --quiet bug this file already
            # carries a note about.
            "args": " ".join(t for t in tail[1:] if t != "--all"),
            "timeout": args.timeout, "reboot": args.reboot, "cold": args.cold,
        }
        if fan:
            # Staging is deliberately NOT namespaced by box: the same binary
            # running on both machines is the entire point, and a box
            # dimension in files/ would make the comparison meaningless by
            # construction.
            print("running %s on %s" % (name, ", ".join(all_ids)))
            res = fan_out(args.server, all_ids,
                          lambda b: dict(payload), args.timeout)
            return report_fanout(res, all_ids, "run " + name)
        # Send this key ONLY to turn the echo off. Sending it on every job
        # pinned the server to an explicit value, and dosd consults its own
        # default only when the job does not carry one -- so
        # DOSD_ECHO_OUTPUT was dead for the two commands it exists to
        # govern. Documented as working before it was tested; it was not.
        if args.quiet:
            payload["echo"] = False
        job = api(args.server, "/queue", payload)
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

        cmds = [t for t in tail if t != "--all"]
        payload = {"kind": "raw", "cmds": cmds, "timeout": args.timeout}
        if fan:
            print("running %d command(s) on %s"
                  % (len(cmds), ", ".join(all_ids)))
            res = fan_out(args.server, all_ids,
                          lambda b: dict(payload), args.timeout)
            return report_fanout(res, all_ids, "exec")
        # Send this key ONLY to turn the echo off. Sending it on every job
        # pinned the server to an explicit value, and dosd consults its own
        # default only when the job does not carry one -- so
        # DOSD_ECHO_OUTPUT was dead for the two commands it exists to
        # govern. Documented as working before it was tested; it was not.
        if args.quiet:
            payload["echo"] = False
        job = api(args.server, "/queue", payload)
        return await_result(args.server, job["id"], args.timeout, cmds=tail)

    die("unknown command '%s' "
        "(try: new clean upgrade version run push deploy pull drv exec "
        "reboot stop status verify)"
        % args.cmd)


if __name__ == "__main__":
    sys.exit(main())
