#!/usr/bin/env python3
"""
DOS Bridge  --  StevenC

dosd - job server bridging a Windows dev box to a real DOS machine over WiFi.

Runs on Windows. The DOS box polls it for work over TFTP and sends results
back the same way, using the bridge's own IPv4/UDP stack -- no mTCP anywhere.

  port 8069  UDP    TFTP. THE transport: job polls, file fetches, results,
                    and `dosctl pull`. Reserved names `job`, `result`, `pull`;
                    `name@<offset>` resumes a stalled transfer from a byte
                    offset; RFC 2348 blksize is negotiated up to 1400
  port 8080  HTTP   /queue        (CLI) queue a job, returns job id
                    /result/<id>  (CLI) long-poll for that job's result
                    /status       (CLI) health / last-seen-boot info
                    /shutdown     (CLI, loopback only) stop the daemon
                    /job, /f/     legacy DOS-side paths, kept for an old agent
  port 8081  raw    legacy result intake (text; parses ##JOB=/##RC= framing)
  port 8082  raw    legacy binary intake for `dosctl pull`

The three legacy listeners cost one idle socket each and are the only way
bytes could still arrive from a box running a batch an older dosd generated.
Nothing this version emits uses them.

Start it once and leave it running:  python dosd.py
"""

import base64
import io
import json
import os
import re
import queue
import socket
import socketserver
import struct
import sys
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

HTTP_PORT = 8080
RESULT_PORT = 8081
PULL_PORT = 8082
# TFTP, the UDP replacement for HTGET and NC. 69 is the real TFTP port
# but binding it needs privilege on most systems, and nothing else here
# is privileged -- so it sits with the bridge's other ports instead.
TFTP_PORT = 8069
FILES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "files")

# A staged file is referenced as either NAME (the serving root -- EXIT0.COM and
# PEND.BAT live there) or PROJECT/NAME. One directory level, no more.
#
# Projects exist because files/ used to be a single flat namespace keyed on the
# basename, so two projects that both built a HELLO.EXE silently overwrote each
# other with no warning and last-writer-wins. 8.3 filenames leave only eight
# characters, far too few to prefix a project name into, so the separation has
# to be by directory.
SAFE_SEG = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")


def safe_rel(name):
    """Validate a staged-file reference. Returns the clean form, or None.

    Rejected rather than normalised, because this string is both joined onto
    FILES_DIR and pasted verbatim into a URL inside a generated DOS batch. A
    caller that meant well gets a clear refusal; anything with '..', a
    backslash, a leading slash or a second directory level gets nothing.
    """
    if not name or "\\" in name or name.startswith("/"):
        return None
    parts = [seg for seg in name.split("/") if seg != ""]
    if not 1 <= len(parts) <= 2:
        return None
    for seg in parts:
        if seg in (".", "..") or not SAFE_SEG.match(seg):
            return None
    return "/".join(parts)


def list_staged():
    """Every staged reference: root files first, then PROJECT/NAME."""
    out = []
    if not os.path.isdir(FILES_DIR):
        return out
    for entry in sorted(os.listdir(FILES_DIR)):
        full = os.path.join(FILES_DIR, entry)
        if os.path.isfile(full):
            out.append(entry)
        elif os.path.isdir(full):
            for sub_name in sorted(os.listdir(full)):
                if os.path.isfile(os.path.join(full, sub_name)):
                    out.append("%s/%s" % (entry, sub_name))
    return out


def rel_to_path(rel):
    """FILES_DIR-rooted absolute path for an already-validated reference."""
    return os.path.join(FILES_DIR, *rel.split("/"))


def leaf_of(rel):
    """The DOS-side filename: the last component, with no directory."""
    return rel.split("/")[-1]


# How long /job holds a connection open before returning an idle response.
# Keep this well under mTCP's socket timeout so HTGET never gives up on us.
# How long a job request is held open before answering "nothing for you".
#
# This is the single number that decides whether an idle poll gets an answer
# at all, and it is not obvious why. Each poll begins with the DOS box ARPing
# for us, which is what puts this host's ARP entry for the box into a state it
# can actually send to. We then sit on the request. Answer 8 seconds later and
# that entry may have gone stale -- and nothing on the box answers the re-probe,
# because by then `Net` has released the 0806 handle and holds only 0800. The
# reply is simply undeliverable. Answer at 2 seconds and it is still fresh.
#
# Measured on hardware 2026-09-02, four minutes of idle polling each way:
#
#     hold = 8s    24 polls,  4 unacked   (17%)
#     hold = 2s    30 polls,  1 unacked   (3.3%)
#
# The 3.3% left over is just this WiFi link -- it matches the loss measured
# with 30 pings -- so what the long hold was costing was five sixths of the
# failures, all of it self-inflicted.
#
# The cost is polls every ~6 seconds instead of ~11, which is nothing on a
# LAN and was checked with the owner of this one. A wired box loses less to
# begin with and pays even less for the shorter hold. Raise it with
# DOSD_POLL_HOLD if a link ever makes the chatter matter more than the misses.
#
# Careful: this used to read TFTP_HOLD_SECS in one place and POLL_HOLD_SECS in
# another. Only this one is live -- see the note on TFTP_HOLD_SECS.
POLL_HOLD_SECS = float(os.environ.get("DOSD_POLL_HOLD", "2"))

# Max errorlevel we bother to capture. DOS 6.22 has no way to read ERRORLEVEL
# into a variable, so the generated batch tests each value in turn.
MAX_ERRORLEVEL = 20

# A 5-byte DOS program that does nothing but exit with code 0:
#   B8 00 4C   mov ax, 4C00h
#   CD 21      int 21h
# Served to the DOS box so raw-command jobs can force a known ERRORLEVEL before
# the ladder reads it. Written into FILES_DIR at startup if it isn't there.
EXIT0_COM = bytes([0xB8, 0x00, 0x4C, 0xCD, 0x21])

# Optional: URL the server hits to power-cycle the DOS box (Tasmota/Shelly).
# e.g. "http://192.168.1.77/cm?cmnd=Power%20Off" -- left unset by default.
POWERCYCLE_OFF_URL = os.environ.get("DOSD_POWER_OFF", "")
POWERCYCLE_ON_URL = os.environ.get("DOSD_POWER_ON", "")


class Job:
    def __init__(self, batch, label, timeout):
        self.id = uuid.uuid4().hex[:8]
        self.batch = batch
        self.label = label
        self.timeout = timeout
        self.kind = "run"
        self.done = threading.Event()
        self.output = None
        self.rc = None
        self.blob = None              # raw bytes, for pull jobs
        self.dispatched_at = None


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.pending = queue.Queue()
        self.jobs = {}
        self.awaiting = None          # job dispatched, waiting on its result
        self.awaiting_pull = None     # pull job whose bytes are due on PULL_PORT
        self.last_poll = 0.0          # last time DOS asked for work
        self.boot_events = []         # ##BOOTOK / ##BOOTFAIL reports
        self.wake = threading.Event()

    def submit(self, job):
        with self.lock:
            self.jobs[job.id] = job
        self.pending.put(job)
        self.wake.set()
        return job.id

    def take(self, hold):
        """Block up to `hold` seconds for a job. Returns Job or None."""
        deadline = time.time() + hold
        while True:
            try:
                return self.pending.get(timeout=max(0.05, deadline - time.time()))
            except queue.Empty:
                if time.time() >= deadline:
                    return None

    def deliver(self, job_id, output, rc):
        with self.lock:
            job = self.jobs.get(job_id)
        if not job:
            return False
        job.output = output
        job.rc = rc
        job.done.set()
        with self.lock:
            if self.awaiting is job:
                self.awaiting = None
            if self.awaiting_pull is job:
                self.awaiting_pull = None
        return True

    def deliver_blob(self, data):
        """
        Attach raw bytes arriving on PULL_PORT to the pull job in flight.

        There is no framing on the wire: NC just opens a socket and streams the
        file. That is safe here because the DOS box runs exactly one job at a
        time -- it polls, CALLs one JOB.BAT, and only then polls again -- so at
        most one pull can ever be outstanding.
        """
        with self.lock:
            job = self.awaiting_pull
            self.awaiting_pull = None
        if not job:
            return False
        job.blob = data
        job.rc = 0
        job.output = "pulled %d bytes" % len(data)
        job.done.set()
        with self.lock:
            if self.awaiting is job:
                self.awaiting = None
        return True


STATE = State()


# ---------------------------------------------------------------------------
# JOB.BAT generation
# ---------------------------------------------------------------------------

def errorlevel_capture():
    """DOS 6.22 can't read ERRORLEVEL into a variable, so ladder it."""
    lines = ["SET RC=0"]
    for n in range(1, MAX_ERRORLEVEL + 1):
        lines.append("IF ERRORLEVEL %d SET RC=%d" % (n, n))
    return lines



# ---------------------------------------------------------------------------
# Transport for the generated batches: our own UDP, and nothing else.
#
# There is no mTCP fallback any more. There was one while the UDP stack was
# being trusted -- every transfer tried UGET/UPUT and dropped to HTGET/NC on
# failure -- and it was removed on 2026-09-02 along with the last mTCP call,
# because keeping it meant every kit still had to ship with mTCP, which was
# the whole reason for moving off it.
#
# What replaced it is retry inside the transport: UGET resends a lost request
# and a lost block itself, and rebuilds the flow outright if one stalls. So a
# dropped packet costs a moment rather than falling through to a second
# protocol. See `starter/tftp.pas`.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Breadcrumbs, for finding out where the box was when it froze.
#
# The machine has hung four times in a day with nothing to show for it: the
# console's last line is whatever finished BEFORE the hang, so all it says is
# "not there yet". This is the same trick dosdrv already uses to survive a
# driver that wedges the machine -- write a marker to disk, then read it back
# on the next boot -- applied to the ordinary job path.
#
# APPEND, not overwrite. The obvious design writes one word to PHASE.TXT and
# reads it after a reboot, and it cannot work: reading the file needs a job,
# and that job's own batch overwrites the marker before the pull runs. An
# append-only log keeps the frozen job's last line underneath whatever the
# recovery job adds.
#
# ECHO opens, writes and closes, so each line is committed to disk before the
# next command starts. That is the property this depends on -- a buffered
# write would be lost in exactly the case it exists for.
#
# DOSD_PHASE=0 turns it off. It costs a file open/write/close per phase, and
# if that ever becomes a suspect itself, it has to be possible to remove it
# without redeploying the agent.
PHASE_LOG = "C:\\AGENT\\PHASE.LOG"
PHASE_ON = os.environ.get("DOSD_PHASE", "1").lower() not in ("0", "no", "off")


def phase(job_id, tag):
    """Batch line recording that the box reached `tag`. Possibly none."""
    if not PHASE_ON:
        return []
    # No ">" and no "%" in the tag: COMMAND.COM cannot escape a redirection
    # inside an ECHO, and would read one as a second redirect.
    clean = "".join(c for c in tag if c not in ">%<|")[:24]
    return ["ECHO %s %s >> %s" % (job_id[:4], clean, PHASE_LOG)]


HD_DOS   = "C:\\TOOLS\\HD.EXE"   # the checksum tool a deploy verifies with
UGET_DOS = "C:\\TOOLS\\UGET.EXE"
UPUT_DOS = "C:\\TOOLS\\UPUT.EXE"


def fetch_lines(name, dest, job_id="----"):
    """Batch lines that put the served file `name` at `dest` on the DOS box.

    No mTCP fallback any more. UGET retransmits a lost request and a lost
    block on its own, so the fallback was only ever covering a bug in our own
    stack -- and keeping it meant every kit still had to ship with mTCP,
    which was the whole reason for moving off it.

    The caller tests for `dest`, not for an exit code. UGET's exit code is
    honest, but the file test also catches a tool that is missing entirely.
    """
    return phase(job_id, "fetch " + leaf_of(name)) + [
        "IF EXIST %s DEL %s" % (dest, dest),
        UGET_DOS + " %UPHOST% " + name + " " + dest,
    ] + phase(job_id, "got " + leaf_of(name))


def send_result_lines(tag, job_id="----"):
    r"""Batch lines that return C:\WORK\RES.TXT to the server.

    One line now that mTCP is gone -- the labels only existed to branch
    around the NC fallback. `tag` is kept in the signature so the call sites
    do not all have to change, and so a future fallback has somewhere to go.
    """
    return phase(job_id, "send") + [
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
    ]



# ---------------------------------------------------------------------------
# What the DOS console shows for each job.
#
# The agent's boot banner now stays on screen permanently, so everything below
# it is a running status display rather than a scrollback. That only works if
# every line fits: the screen is 80 columns and a line that wraps costs two
# rows and reads as damage. So each job gets exactly two short lines -- what
# it is, and how it ended -- and both are truncated to fit.
#
# The job id is cut to four characters. That is plenty to match a line on the
# screen against a line in dosd's log, and the full id would eat a tenth of
# the width for no benefit anyone standing at the machine cares about.
# ---------------------------------------------------------------------------

CONSOLE_COLS = 78


def job_head(job_id, what):
    return "ECHO " + ("[%s] %s" % (job_id[:4], what))[:CONSOLE_COLS]


def job_foot(job_id, what):
    return "ECHO " + ("[%s]   %s" % (job_id[:4], what))[:CONSOLE_COLS]



# COMMAND.COM's internal commands never touch ERRORLEVEL, so a job made only
# of those reports a number that means nothing: DIR C:\NOSUCH exits 0, and
# EXIT0.COM has already forced the ladder to read a clean 0. The result sent
# back to Windows still carries ##RC either way -- that is dosctl's contract
# and dosexec's documented caveat -- but the console is read by somebody
# standing at the machine with no way to know that, so it says "done" rather
# than inventing an authoritative-looking "rc 0" for them to trust.
#
# IF and FOR are deliberately NOT in this set. Either can invoke an external
# program, so their rc may well be real. Printing a possibly-stale number is
# the status quo and merely unhelpful; printing "done" over a program that
# actually failed would hide a failure. The doubt resolves towards the number.
INTERNAL_CMDS = frozenset("""
    break call cd chcp chdir cls copy ctty date del dir echo erase exit
    goto lh loadhigh md mkdir path pause prompt rd rem ren rename rmdir
    set shift time truename type ver verify vol
""".split())


def sets_errorlevel(cmd):
    """Can this command line leave a meaningful ERRORLEVEL behind?"""
    tok = cmd.strip().split()
    if not tok:
        return False
    word = tok[0].split("\\")[-1]          # C:\TOOLS\FPU.EXE -> FPU.EXE
    if "." in word:
        word = word.rsplit(".", 1)[0]        # FPU.EXE -> FPU
    return word.lower() not in INTERNAL_CMDS


# The marker a batch writes when a command names a program that is not on
# the disk. It travels back inside the captured output, because that is the
# one channel a job already has; dosctl lifts it out again.
NOEXEC_MARK = "##NOEXEC="

_EXE_SUFFIX = (".exe", ".com", ".bat")


def explicit_program(cmd):
    r"""The program a command names, but only when that is beyond doubt.

    Returns e.g. "C:\BAD.EXE" for `C:\BAD.EXE /x`, and None for anything
    whose existence this cannot test honestly.

    The rule is deliberately narrow: an explicit path (it has a backslash or a
    drive letter) AND an executable extension. Both halves matter.

    * Without the path requirement, `FOO.EXE` would be checked with IF EXIST,
      which searches only the current directory -- so every tool resolved
      through PATH would be reported missing. A false "not found" on a command
      that works is far worse than the silence this replaces.
    * Without the extension requirement, `C:\TOOLS\FPU` would be reported
      missing even though COMMAND.COM would happily find FPU.EXE for it.

    Narrow is the right shape here because the case that actually bites is the
    explicit path: C:\TOOLS is not on the box's PATH, so the documented way to
    call every tool in the kit is by full path, and a typo in one of those is
    exactly what goes silent today.
    """
    tok = cmd.strip().split()
    if not tok:
        return None
    prog = tok[0]
    if not prog.lower().endswith(_EXE_SUFFIX):
        return None
    if "\\" not in prog and ":" not in prog:
        return None
    return prog


def noexec_guard(cmd):
    """Batch lines that flag `cmd` if its program is missing. Possibly none.

    This exists because a missing program is otherwise *completely* invisible
    from Windows. COMMAND.COM writes "Bad command or file name" to a console
    this bridge cannot capture -- 6.22 has no stderr redirection at all -- and
    it leaves ERRORLEVEL alone, which EXIT0.COM has just forced to 0. So the
    job comes back with no output and rc 0: a confident success for a program
    that never ran.
    """
    prog = explicit_program(cmd)
    if not prog:
        return []
    # One IF with an internal command (ECHO), so the chained-IF trap does not
    # apply. No ">" inside the ECHO text either -- COMMAND.COM cannot escape
    # one, and it would be read as a second redirection.
    return ["IF NOT EXIST %s ECHO %s%s >> C:\\WORK\\OUT.TXT"
            % (prog, NOEXEC_MARK, prog)]


def job_rc_lines(job_id, meaningful=True, tag="FR"):
    """The footer's second line -- how the job ended -- as ECHO statements.

    Success and failure occupy the same single row: the point is that a
    failure is legible from across the room, not that it is longer. A column
    of identical "rc 0" lines hides the one "rc 3" in it; "ok" against
    "rc 3 FAILED" does not.

    Two separate IFs rather than one chained pair, because COMMAND.COM 6.22
    silently drops the second half of a chained IF when the command is
    external. ECHO is internal so it would survive here, but that is not a
    rule worth relearning the hard way in a batch nobody can debug.
    """
    if not meaningful:
        return timed_foot(job_id, [(None, "done")], tag)
    return timed_foot(job_id, [
        ('IF "%RC%"=="0" ', "ok"),
        ('IF NOT "%RC%"=="0" ', "rc %RC% FAILED"),
    ], tag)



ELAPSED_DOS = "C:\\TOOLS\\ELAPSED.COM"


OUT_DOS = "C:\\WORK\\OUT.TXT"

# Whether a job's captured output is also dumped on the DOS console.
#
# On by default: the machine standing in front of you should be able to show
# what it just did, not only what it was asked to do. The result still goes
# back over the wire either way -- this is a second copy for the screen.
#
# It is the one thing here that deliberately breaks the two-lines-per-job
# budget, and it does scroll the boot banner away sooner. That is the trade
# for being able to read a job's output at the machine, and it is per-job
# reversible: `dosrun --quiet`, `dosexec --quiet`, or DOSD_ECHO_OUTPUT=0 to
# flip the default for a whole session. dosctl's own bookkeeping jobs (the
# version TYPE, the C:\TOOLS listing, the stop flag) always pass echo=False,
# because a 36-file DIR on the console every upgrade is nobody's idea of a
# status display.
ECHO_OUTPUT = os.environ.get("DOSD_ECHO_OUTPUT", "1").lower() \
    not in ("0", "no", "off", "false")


def echo_output_lines(echo=None):
    """TYPE the captured output onto the console, unredirected.

    Sits between the head line and the footer, so a job reads as: what it is,
    what it said, how it ended. The footer's elapsed time therefore includes
    this dump -- which is honest, since it is work the box really did.
    """
    if echo is None:
        echo = ECHO_OUTPUT
    if not echo:
        return []
    return ["IF EXIST %s TYPE %s" % (OUT_DOS, OUT_DOS)]


def stash_time():
    """Start the job stopwatch.

    Goes immediately after the head line, so the time a job reports is the
    whole job -- fetch included -- and not just the program. That is the
    number somebody standing at the machine is asking about.

    One IF with an external command is fine; it is a *chained* IF that
    COMMAND.COM 6.22 silently drops when the command is external.
    """
    return ["IF EXIST %s %s /S" % (ELAPSED_DOS, ELAPSED_DOS)]


def timed_foot(job_id, alts, tag):
    """A footer that carries how long the job took.

    `alts` is a list of (if-prefix or None, text) -- more than one because
    the choice between "ok" and "rc 3 FAILED" has to be made on the DOS side.

    ELAPSED.COM prints the caller's text and appends the time, rather than
    just printing a number, because the footer has to stay ONE row: ECHO
    always terminates its line, so nothing can be appended to a row ECHO
    printed. See starter/elapsed.asm.

    The whole group is guarded on the tool existing, and falls back to plain
    ECHO. A box that has not had `dosctl upgrade --tools` run against it then
    still gets its footer -- without the time -- instead of a "Bad command or
    file name" where the status line should be.

    The guard is a GOTO rather than `SET F=ECHO` and `%F%`, which would be
    two lines instead of seven. The environment on this box is nearly full,
    and a SET that failed with "Out of environment space" would expand to
    nothing and leave COMMAND.COM trying to execute the footer text itself.
    """
    body, plain = [], []
    for prefix, text in alts:
        line = ("[%s]   %s" % (job_id[:4], text))[:CONSOLE_COLS]
        body.append((prefix or "") + ELAPSED_DOS + " " + line)
        plain.append((prefix or "") + "ECHO " + line)
    return (["IF NOT EXIST %s GOTO N%s" % (ELAPSED_DOS, tag)]
            + body
            + ["GOTO D%s" % tag, ":N%s" % tag]
            + plain
            + [":D%s" % tag])


def build_run_batch(job_id, exe_name, args, reboot_after, cold, echo=None):
    """A job that fetches an .EXE/.COM, runs it, and ships stdout back."""
    # exe_name is the staged reference (NAME or PROJECT/NAME). The DOS box only
    # ever sees the leaf, because C:\WORK is flat. That stays safe despite the
    # shared directory: the DEL runs before the fetch, so a same-named binary
    # left behind by another project can never be the one that executes.
    exe = leaf_of(exe_name)
    cmd = "C:\\WORK\\" + exe
    if args:
        cmd += " " + args
    lines = [
        "@ECHO OFF",
        job_head(job_id, "run " + exe_name + (" " + args if args else "")),
    ] + stash_time() + fetch_lines(exe_name, "C:\\WORK\\" + exe, job_id) + [
        "IF NOT EXIST C:\\WORK\\%s GOTO NOFILE" % exe,
        "IF EXIST C:\\WORK\\OUT.TXT DEL C:\\WORK\\OUT.TXT",
    ] + phase(job_id, "run " + exe) + [
        cmd + " > C:\\WORK\\OUT.TXT",
    ] + phase(job_id, "ran " + exe) + [
    ]
    lines += errorlevel_capture()
    lines += [
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "IF EXIST C:\\WORK\\OUT.TXT TYPE C:\\WORK\\OUT.TXT >> C:\\WORK\\RES.TXT",
        "ECHO ##RC=%RC% >> C:\\WORK\\RES.TXT",
    ] + echo_output_lines(echo) + job_rc_lines(job_id) + [
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        "GOTO END",
        ":NOFILE",
        job_foot(job_id, "FAILED - could not fetch " + leaf_of(exe_name)),
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: download of %s failed >> C:\\WORK\\RES.TXT" % exe_name,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        ":END",
    ]
    if reboot_after:
        lines.append("COLDBOOT.COM" if cold else "REBOOT.COM")
    return lines


def build_driver_batch(job_id, drv_name, drv_args, cold, device=None):
    """
    A job that stages a driver for the *next* boot.

    The risky DEVLOAD goes into PEND.BAT, which the agent loop runs after the
    network is already up and behind a crash-guard flag. If the driver wedges
    the machine, the next boot finds TRYING.FLG still present, reports the
    failure, and skips the driver -- so a power cycle is always enough to
    recover. Nothing risky ever touches CONFIG.SYS.

    PEND.BAT is written here and fetched over HTTP rather than being assembled
    on the DOS side with ECHO. COMMAND.COM has no way to escape a '>' inside an
    ECHO, so an ECHO-built PEND.BAT could never contain a redirection -- and a
    redirection is exactly what we need to capture DEVLOAD's output. Serving it
    as a file sidesteps the problem completely.

    `device` is the character-device name the driver should register (e.g.
    TESTDEV). Without it a driver that fails quietly is indistinguishable from
    one that loaded: DEVLOAD returns 0 for a character device either way, and
    the crash guard only ever proves the machine survived.
    """
    drv = leaf_of(drv_name)
    pend = [
        "@ECHO OFF",
        "IF EXIST C:\\AGENT\\DRVOUT.TXT DEL C:\\AGENT\\DRVOUT.TXT",
        "DEVLOAD /V C:\\WORK\\%s %s > C:\\AGENT\\DRVOUT.TXT" % (drv, drv_args),
    ]
    if device:
        d = device.upper()
        pend += [
            "IF EXIST %s ECHO ##DEVICE %s registered >> C:\\AGENT\\DRVOUT.TXT"
            % (d, d),
            "IF NOT EXIST %s ECHO ##DEVFAIL %s did not register "
            ">> C:\\AGENT\\DRVOUT.TXT" % (d, d),
        ]
    with open(os.path.join(FILES_DIR, "PEND.BAT"), "wb") as fh:
        fh.write(to_dos_text(pend))

    lines = [
        "@ECHO OFF",
        job_head(job_id, "driver " + leaf_of(drv_name) + " - will reboot"),
    ] + fetch_lines(drv_name, "C:\\WORK\\" + drv, job_id) + [
        "IF NOT EXIST C:\\WORK\\%s GOTO NOFILE" % drv,
    ] + fetch_lines("PEND.BAT", "C:\\AGENT\\PEND.BAT", job_id) + [
        "IF NOT EXIST C:\\AGENT\\PEND.BAT GOTO NOFILE",
        "ECHO ##JOB=%s > C:\\AGENT\\PENDID.TXT" % job_id,
        "COLDBOOT.COM" if cold else "REBOOT.COM",
        "GOTO END",
        ":NOFILE",
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: download of %s failed >> C:\\WORK\\RES.TXT" % drv_name,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        ":END",
    ]
    return lines


def build_pull_batch(job_id, remote_path):
    """
    Ship a file off the DOS box byte-exact.

    UPUT reads the file itself, so this never passes through TYPE and is
    immune to the 0x1A (Ctrl-Z) truncation that makes `dosexec "TYPE ..."`
    useless for binaries. TFTP is a block protocol with a byte count, so
    there is no text mode to get wrong and nothing to opt out of.

    This was mTCP's `NC -bin` until 2026-09-02, and dropping it took the last
    mTCP call out of every generated batch. Two reasons it had to go, beyond
    the dependency. `NC` printed a thirteen-line version banner **straight to
    the console** on every pull -- `> NUL` was already there and made no
    difference, because COMMAND.COM 6.22 has no stderr redirection at all, so
    it could not be silenced from a batch. And `-bin` was load-bearing in a
    way nothing on the wire enforced: without it NC opened stdin in text mode
    and silently ate every 0x0D and 0x1A, so a 27298-byte SYSINFO.EXE arrived
    as 27258 -- corrupt but entirely plausible-looking.

    The bytes now arrive on TFTP_PORT under the reserved name `pull` and land
    in the same sink, so `dosctl pull` is unchanged.

    Only the not-found path reports on RESULT_PORT; a successful transfer is
    signalled by the bytes themselves arriving.
    """
    return [
        "@ECHO OFF",
        job_head(job_id, "pull " + remote_path),
    ] + stash_time() + [
        "IF NOT EXIST %s GOTO NOFILE" % remote_path,
        UPUT_DOS + " %UPHOST% " + remote_path + " pull",
        "IF ERRORLEVEL 1 GOTO SENDFAIL",
    ] + timed_foot(job_id, [(None, "sent")], "FP") + [
        "GOTO END",
        ":SENDFAIL",
        job_foot(job_id, "FAILED - upload"),
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: upload of %s from the DOS box failed >> C:\\WORK\\RES.TXT" % remote_path,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
    ] + send_result_lines("pullfail") + [
        "GOTO END",
        ":NOFILE",
        job_foot(job_id, "FAILED - not found"),
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: %s not found on the DOS box >> C:\\WORK\\RES.TXT" % remote_path,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        ":END",
    ]



def verify_then_install(name, dest):
    r"""Check the download's CRC-32 on the box, then swap it into place.

    This exists because of 2026-09-02, when a deploy of UGET.EXE fetched the
    file, wrote a corrupt copy over C:\TOOLS\UGET.EXE and stranded the
    machine. The batch tested `IF EXIST` and nothing else -- so a truncated or
    half-written download passed the guard and was installed over the one
    binary the agent cannot poll without. Recovering it took hands on the
    keyboard, because the mTCP fallback had been removed the same day.

    Two guards, in the order that matters:

    * **Verify before installing.** `HD` on the box prints the same CRC-32 as
      Python's zlib.crc32, and `FIND` sets ERRORLEVEL 1 when the expected
      value is absent -- so the box can check its own download against a
      number computed here, with no new tool and no arithmetic in batch. A
      mismatch leaves the existing file untouched.
    * **Keep the outgoing copy.** The previous binary is kept alongside as
      .BAK, so recovery is one COPY at the keyboard rather than a hand-typed
      HTGET against a URL. Same reasoning as C:\AI\AI.BAK for the agent.

    A box with no HD.EXE yet -- a fresh install -- skips the checksum and
    falls back to the existence test, because refusing to deploy the tools
    onto a machine that has none of them would be a fine way to make the
    installer unusable.
    """
    rel = safe_rel(name)
    src = rel_to_path(rel) if rel else None
    want = None
    if src and os.path.isfile(src):
        with open(src, "rb") as fh:
            want = "%08X" % (zlib.crc32(fh.read()) & 0xFFFFFFFF)

    bak = dest.rsplit(".", 1)[0] + ".BAK" if "." in dest.rsplit(
        chr(92), 1)[-1] else dest + ".BAK"

    lines = []
    if want:
        lines += [
            "IF NOT EXIST %s GOTO NOCRC" % HD_DOS,
            "IF EXIST C:\\WORK\\CRC.TXT DEL C:\\WORK\\CRC.TXT",
            "%s C:\\WORK\\DEPLOY.TMP 0 1 > C:\\WORK\\CRC.TXT" % HD_DOS,
            'FIND "%s" C:\\WORK\\CRC.TXT > NUL' % want,
            "IF ERRORLEVEL 1 GOTO BADCRC",
            ":NOCRC",
        ]
    lines += [
        "IF EXIST %s COPY %s %s > NUL" % (dest, dest, bak),
        "COPY C:\\WORK\\DEPLOY.TMP %s > NUL" % dest,
        "DEL C:\\WORK\\DEPLOY.TMP",
    ]
    return lines


def build_deploy_batch(job_id, name, dest_dir):
    """
    Fetch a staged file onto the DOS box and confirm it actually landed.

    The exit code of the fetch is not the check. That began as a workaround
    for HTGET, which exited >= 20 even on success; UGET's code is honest, but
    IF EXIST is still what runs, because it also catches the tool being absent
    altogether -- which an exit code cannot distinguish from a clean failure.

    Note IF EXIST is not sufficient on its own either: a transfer truncated to
    exactly the right length passes it. `dosctl deploy` follows up with a
    CRC-32 from HD.EXE, which is the check that actually means something.
    """
    dest = dest_dir.rstrip("\\") + "\\" + leaf_of(name)
    return [
        "@ECHO OFF",
        # "to", never "->". COMMAND.COM cannot escape a > inside an ECHO,
        # so "-> C:\TOOLS\UGET.EXE" is parsed as a REDIRECT and writes the
        # announce text straight into the destination file. That silently
        # truncated every deploy target to ~48 bytes for as long as this line
        # has existed -- invisible, because the download that followed
        # immediately overwrote it. It stopped being invisible when the
        # destination became the tool doing the downloading: the ECHO
        # clobbered C:\TOOLS\UGET.EXE, the next line executed those 48 bytes
        # as a program, and the machine needed a power cycle.
        job_head(job_id, "deploy %s to %s" % (leaf_of(name), dest_dir)),
    ] + stash_time() + [
        # Fetch to a scratch name and COPY into place, rather than deleting
        # the destination and downloading over it.
        #
        # Two reasons, and the first one bit hard. Deploying UGET.EXE itself
        # DELETED C:\TOOLS\UGET.EXE and then tried to run it to do the
        # download -- a tool cannot replace itself that way, any more than
        # AI.BAT can overwrite itself while COMMAND.COM is reading it. The
        # box survived only because the agent still had an mTCP fallback for
        # its poll, and recovering needed HTGET to put the file back.
        #
        # Second: a download that fails now leaves the existing file alone
        # instead of destroying it. The old order deleted first and asked
        # questions later.
        "IF EXIST C:\\WORK\\DEPLOY.TMP DEL C:\\WORK\\DEPLOY.TMP",
        UGET_DOS + " %UPHOST% " + name + " C:\\WORK\\DEPLOY.TMP",
        "IF NOT EXIST C:\\WORK\\DEPLOY.TMP GOTO NOFILE",
    ] + verify_then_install(name, dest) + [
        "IF NOT EXIST %s GOTO NOCOPY" % dest,
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "DIR %s >> C:\\WORK\\RES.TXT" % dest,
        "ECHO ##RC=0 >> C:\\WORK\\RES.TXT",
    ] + timed_foot(job_id, [(None, "ok")], "FD") + [
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        "GOTO END",
        ":BADCRC",
        job_foot(job_id, "FAILED - bad checksum, NOT installed"),
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: %s arrived corrupt; the old copy was left in place"
        " >> C:\\WORK\\RES.TXT" % name,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
    ] + send_result_lines("badcrc") + [
        "GOTO END",
        # Two failures used to share the NOFILE label, and so shared its
        # message.  They are not the same fault, and the wrong one sends you
        # looking at the network: the fetch can succeed perfectly well and
        # the COPY into place still fail.  Most often that is a destination
        # given as a full file path where a DIRECTORY is wanted -- DOS says
        # "Path not found" for C:\DIR\FILE.EXE\FILE.EXE, and the deploy then
        # reported "download failed" about a transfer that had worked.
        ":NOCOPY",
        job_foot(job_id, "FAILED - could not put it in place"),
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: %s downloaded, but copying it to %s failed."
        " >> C:\\WORK\\RES.TXT" % (name, dest),
        "ECHO The destination is a DIRECTORY, not a file path."
        " >> C:\\WORK\\RES.TXT",
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        "GOTO END",
        ":NOFILE",
        job_foot(job_id, "FAILED - download"),
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: download of %s failed >> C:\\WORK\\RES.TXT" % name,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        ":END",
    ]


def build_raw_batch(job_id, body_lines, echo=None):
    """
    Arbitrary DOS commands, with output captured and returned.

    EXIT0.COM runs immediately before the caller's commands to force ERRORLEVEL
    to a known 0. Without it the ladder below reads a stale value: DOS internal
    commands (ECHO, VER, DIR, IF, DEL, TYPE) never touch ERRORLEVEL, so a list
    made only of those reports whatever the last *external* program left
    behind -- in practice the UGET that fetched this JOB.BAT. If the fetch of
    EXIT0.COM itself fails we degrade to that stale-value behaviour rather
    than breaking the job.
    """
    lines = [
        "@ECHO OFF",
        # Raw jobs used to run in complete silence, which made the console
        # useless for telling "busy" from "wedged". The other builders always
        # announced themselves; this one now does too.
        job_head(job_id, "exec %d cmd(s): %s"
                 % (len(body_lines), body_lines[0] if body_lines else "")),
    ] + stash_time() + [
        # One IF, one external command. NOT "IF NOT EXIST ... UGET ..."
        # chained with another IF: COMMAND.COM 6.22 honours a chained IF
        # when the command is INTERNAL and silently drops it when it is
        # EXTERNAL, so the chained form would never fetch anything.
        "IF EXIST C:\\AGENT\\EXIT0.COM GOTO HAVE0",
        UGET_DOS + " %UPHOST% EXIT0.COM C:\\AGENT\\EXIT0.COM",
        ":HAVE0",
        "IF EXIST C:\\WORK\\OUT.TXT DEL C:\\WORK\\OUT.TXT",
        "IF EXIST C:\\AGENT\\EXIT0.COM C:\\AGENT\\EXIT0.COM",
    ]
    for ci, c in enumerate(body_lines):
        # Checked immediately before the command rather than all at the top,
        # so a program an earlier command in the same job creates is judged
        # at the moment it is actually invoked.
        lines += noexec_guard(c)
        # One breadcrumb per command, not per job. A `dosexec` that sticks
        # needs to say WHICH command it stuck on, and an exec job is the
        # one shape where the commands are arbitrary.
        lines += phase(job_id, "cmd%d %s" % (ci, leaf_of(c.split()[0])
                                             if c.split() else "?"))
        lines.append("%s >> C:\\WORK\\OUT.TXT" % c)
    lines += phase(job_id, "cmds done")
    lines += errorlevel_capture()
    lines += [
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "IF EXIST C:\\WORK\\OUT.TXT TYPE C:\\WORK\\OUT.TXT >> C:\\WORK\\RES.TXT",
        "ECHO ##RC=%RC% >> C:\\WORK\\RES.TXT",
    ] + echo_output_lines(echo) + job_rc_lines(
        job_id, bool(body_lines) and sets_errorlevel(body_lines[-1]),
        tag="FX") + phase(job_id, "send") + [
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
    ] + phase(job_id, "sent")
    return lines


# The last line every deployable agent must end with. dosctl appends it when
# staging, so its presence proves the whole file arrived: FIND on the DOS side
# is then a complete-transfer check that costs nothing and needs no CRC.
AGENT_END = "##AGENT-END"


def build_agent_batch(job_id, name):
    r"""Replace C:\AI\AI.BAT -- the agent loop that is running this very batch.

    This is the one genuinely dangerous thing the bridge does, and the ordering
    below is the entire safety mechanism, not a nicety.

    COMMAND.COM reads a batch file incrementally, by byte offset, re-opening it
    after every line. Overwrite AI.BAT while it is running and control returns
    to the *old offset* inside the *new* file -- landing mid-line, executing
    whatever text happens to be there. That is a reliable way to wedge a
    machine that no longer has a working agent to report it.

    So: the swap is the last thing that happens before REBOOT.COM, inside
    JOB.BAT. AI.BAT is never read again after it is overwritten. The same
    trick the driver path uses when it ends with COLDBOOT.COM.

    Three guards before anything is overwritten:
      * the download must have produced a file at all;
      * that file must end with the AGENT_END marker, so a truncated transfer
        cannot become the agent;
      * the outgoing agent is kept as C:\AI\AI.BAK for a manual rollback.

    If the new agent is broken, nothing here can save the machine -- it will
    boot, fail to poll, and need hands. dosctl refuses to send one whose server
    address differs from the running agent's, which is the failure that would
    otherwise happen silently.
    """
    exe = leaf_of(name)
    return [
        "@ECHO OFF",
        job_head(job_id, "agent upgrade - will reboot"),
    ] + fetch_lines(name, "C:\\AGENT\\AINEW.BAT", job_id) + [
        "IF NOT EXIST C:\\AGENT\\AINEW.BAT GOTO NOFILE",
        'FIND "%s" C:\\AGENT\\AINEW.BAT > NUL' % AGENT_END,
        "IF ERRORLEVEL 1 GOTO TRUNC",
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "IF EXIST C:\\AI\\AI.BAK DEL C:\\AI\\AI.BAK",
        "COPY C:\\AI\\AI.BAT C:\\AI\\AI.BAK > NUL",
        "COPY C:\\AGENT\\AINEW.BAT C:\\AI\\AI.BAT > NUL",
        "DEL C:\\AGENT\\AINEW.BAT",
        "ECHO ##AGENT swapped from %s, previous kept as C:\\AI\\AI.BAK"
        " >> C:\\WORK\\RES.TXT" % exe,
        "ECHO ##RC=0 >> C:\\WORK\\RES.TXT",
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        # Absolute path first: a job that changed directory (compiling in
        # C:\BPDEMOS, say) would leave a bare REBOOT.COM unresolvable, and
        # failing to reboot *here* is the one place it must not happen.
        "IF EXIST C:\\AI\\REBOOT.COM C:\\AI\\REBOOT.COM",
        "REBOOT.COM",
        "GOTO END",
        ":TRUNC",
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: new agent has no end marker -- transfer was incomplete,"
        " NOT swapped >> C:\\WORK\\RES.TXT",
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        "GOTO END",
        ":NOFILE",
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: download of the new agent failed >> C:\\WORK\\RES.TXT",
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        UPUT_DOS + " %UPHOST% C:\\WORK\\RES.TXT result",
        ":END",
    ]

def build_reboot_batch(cold):
    """Just reboot. No result comes back -- the machine is gone."""
    # Absolute path first, bare name as the fallback: the bare form only
    # resolves because AUTOEXEC leaves the current directory at C:\AI, and a
    # job that changed directory would break it.
    boot = "COLDBOOT.COM" if cold else "REBOOT.COM"
    return ["@ECHO OFF", "ECHO [dosd] reboot requested",
            "IF EXIST C:\\AI\\%s C:\\AI\\%s" % (boot, boot),
            boot]


IDLE_BATCH = ["@ECHO OFF", "REM idle"]


def to_dos_text(lines):
    """DOS needs CRLF and a trailing newline or COMMAND.COM may drop the tail."""
    return ("\r\n".join(lines) + "\r\n").encode("cp437", errors="replace")


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # mTCP HTGET is happiest without keep-alive

    def log_message(self, fmt, *args):
        pass  # we do our own logging

    def _send(self, code, body, ctype="text/plain"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        # The whole response is guarded, not just the body. end_headers()
        # flushes the header block down the socket, so a client that has
        # already hung up raises there -- before the old try block was even
        # reached. HTGET closes connections routinely, especially on the idle
        # long-poll, so this is normal traffic rather than an error.
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def handle_one_request(self):
        """Swallow a client vanishing mid-request without a traceback."""
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        except (BrokenPipeError, ConnectionResetError, OSError):
            self.close_connection = True

    def handle_error(self, request, client_address):
        """ThreadingHTTPServer prints a full traceback per failed request.

        A DOS box dropping a poll is not worth twenty lines of Python stack in
        the window someone is watching for job results, so it becomes one line.
        """
        log("   (client %s went away mid-request)" % (client_address[0],))

    def do_GET(self):
        path = unquote(urlparse(self.path).path)

        if path == "/job":
            STATE.last_poll = time.time()
            job = STATE.take(TFTP_HOLD_SECS)
            if job is None:
                self._send(200, to_dos_text(IDLE_BATCH))
                return
            job.dispatched_at = time.time()
            with STATE.lock:
                STATE.awaiting = job
                if job.kind == "pull":
                    STATE.awaiting_pull = job
            log("-> dispatch %s  %s" % (job.id, job.label))
            self._send(200, to_dos_text(job.batch))
            return

        if path.startswith("/f/"):
            rel = safe_rel(path[3:])
            full = rel_to_path(rel) if rel else None
            if full is None or not os.path.isfile(full):
                # Empty body on purpose. HTGET writes whatever it receives
                # to -o regardless of status, and the job batch can only
                # test IF EXIST -- so an error page becomes a file that
                # passes the guard and is then executed. "no such file"
                # as machine code is OUTSB/OUTSW: writes to I/O ports.
                self._send(404, b"")
                return
            with open(full, "rb") as fh:
                data = fh.read()
            self._send(200, data, "application/octet-stream")
            return

        if path.startswith("/result/"):
            job_id = path[len("/result/"):]
            with STATE.lock:
                job = STATE.jobs.get(job_id)
            if not job:
                self._send(404, json.dumps({"error": "unknown job"}))
                return
            if job.done.wait(timeout=job.timeout):
                payload = {"id": job.id, "rc": job.rc, "output": job.output}
                if job.blob is not None:
                    # base64 so the bytes survive JSON untouched -- the DOS side
                    # does no encoding, this is purely a Windows-side transport.
                    payload["blob_b64"] = base64.b64encode(job.blob).decode()
                self._send(200, json.dumps(payload))
            else:
                self._send(200, json.dumps({
                    "id": job.id, "rc": None, "output": None,
                    "error": "timeout after %ss -- the DOS box is hung, "
                             "not polling, or the job rebooted it. A job that "
                             "reboots cannot send its result: use dosreboot, "
                             "or dosrun --reboot to run then reboot."
                             % job.timeout,
                }))
            return

        if path == "/status":
            with STATE.lock:
                age = time.time() - STATE.last_poll if STATE.last_poll else None
                self._send(200, json.dumps({
                    "last_poll_secs_ago": round(age, 1) if age else None,
                    "boot_events": STATE.boot_events[-10:],
                    "files": sorted(list_staged()),
                }))
            return

        self._send(404, "not found\r\n")

    def do_POST(self):
        path = unquote(urlparse(self.path).path)

        if path == "/shutdown":
            # Loopback only, and deliberately so. Every other endpoint
            # here exists to be reached by the DOS box across the LAN;
            # this one would let anything on that LAN stop the bridge,
            # which is a far worse trade than making somebody use the
            # machine dosd itself runs on.
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                self._send(403, "shutdown is local-only\r\n")
                return
            self._send(200, "stopping\r\n")
            log("shutdown requested -- bye")
            # shutdown() cannot be called from inside a handler: it waits
            # for the serve_forever loop to finish, and that loop is
            # waiting on this handler. A thread breaks the cycle.
            threading.Thread(target=self.server.shutdown,
                             daemon=True).start()
            return

        if path != "/queue":
            self._send(404, "not found\r\n")
            return
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")

        kind = req.get("kind", "run")
        timeout = float(req.get("timeout", 120))
        jid = uuid.uuid4().hex[:8]

        # Refuse to dispatch a job whose file is not staged. Catching it here
        # costs one clear error; letting it through costs a wedged DOS box,
        # because the download 404s and the batch cannot tell the difference.
        if kind in ("run", "driver", "deploy", "agent"):
            want = req.get("name", "")
            rel = safe_rel(want)
            if rel is None or not os.path.isfile(rel_to_path(rel)):
                self._send(404, json.dumps({
                    "error": "%s is not staged on the server. Push it first "
                             "(dospush/dosdeploy stage automatically when given "
                             "a real path), or check the name. References are "
                             "NAME or PROJECT/NAME -- one directory level."
                             % want}))
                log("!! refused %s: %s not in files/" % (kind, want))
                return
            req["name"] = rel

        if kind == "run":
            batch = build_run_batch(jid, req["name"], req.get("args", ""),
                                    req.get("reboot", False),
                                    req.get("cold", False),
                                    echo=req.get("echo"))
            label = "run %s" % req["name"]
        elif kind == "driver":
            batch = build_driver_batch(jid, req["name"], req.get("args", ""),
                                       req.get("cold", True),
                                       req.get("device"))
            label = "driver %s" % req["name"]
        elif kind == "reboot":
            batch = build_reboot_batch(req.get("cold", False))
            label = "reboot"
        elif kind == "raw":
            batch = build_raw_batch(jid, req["cmds"], echo=req.get("echo"))
            label = "raw (%d cmds)" % len(req["cmds"])
        elif kind == "pull":
            batch = build_pull_batch(jid, req["path"])
            label = "pull %s" % req["path"]
        elif kind == "agent":
            batch = build_agent_batch(jid, req["name"])
            label = "agent upgrade %s" % req["name"]
        elif kind == "deploy":
            batch = build_deploy_batch(jid, req["name"], req.get("dest", "C:\\WORK"))
            label = "deploy %s -> %s" % (req["name"], req.get("dest", "C:\\WORK"))
        else:
            self._send(400, json.dumps({"error": "bad kind"}))
            return

        job = Job(batch, label, timeout)
        job.id = jid
        job.kind = kind
        STATE.submit(job)
        self._send(200, json.dumps({"id": jid}))


# ---------------------------------------------------------------------------
# Raw TCP result intake (mTCP NC pushes here)
# ---------------------------------------------------------------------------

def ingest_result(payload):
    """Parse one result report and hand it to the waiting job.

    Factored out of ResultHandler so the TCP path (NC) and the TFTP path
    (UPUT) cannot drift: they are two transports for one wire format, and a
    result that parsed differently depending on how it arrived would be a
    genuinely horrible bug to chase.
    """
    raw = payload.decode("cp437", errors="replace")
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")

    job_id, rc, body = None, None, []
    for line in raw.split("\n"):
        s = line.strip()
        if s.startswith("##JOB="):
            job_id = s[6:].strip()
        elif s.startswith("##RC="):
            try:
                rc = int(s[5:].strip())
            except ValueError:
                rc = None
        elif s.startswith("##BOOTOK") or s.startswith("##BOOTFAIL"):
            STATE.boot_events.append({"t": time.time(), "event": s})
            log("<- boot event: %s" % s)
            body.append(s)
        else:
            body.append(line)

    text = "\n".join(body).strip("\n")
    if job_id and STATE.deliver(job_id, text, rc):
        log("<- result  %s  rc=%s  (%d bytes)" % (job_id, rc, len(text)))
    else:
        log("<- unmatched report:\n%s" % text[:400])


class ResultHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(20)
        chunks = []
        try:
            while True:
                b = self.request.recv(4096)
                if not b:
                    break
                chunks.append(b)
        except socket.timeout:
            pass
        ingest_result(b"".join(chunks))


class PullHandler(socketserver.BaseRequestHandler):
    """
    Legacy raw binary intake for `dosctl pull`.

    Nothing generates a batch that uses this any more -- pulls go over TFTP
    under the name `pull`. It is kept listening because it costs one idle
    socket and it is the only way bytes could still arrive from a DOS box
    running a batch generated by an older dosd.

    Deliberately does nothing to the bytes: no cp437 decode, no CRLF folding,
    no line splitting. That is the whole point of a separate port -- the
    RESULT_PORT handler has to do all three to parse ##JOB=/##RC= framing, and
    every one of them corrupts binary.
    """

    def handle(self):
        self.request.settimeout(60)
        chunks = []
        try:
            while True:
                b = self.request.recv(65536)
                if not b:
                    break
                chunks.append(b)
        except socket.timeout:
            pass
        data = b"".join(chunks)
        if STATE.deliver_blob(data):
            log("<- pulled %d bytes" % len(data))
        else:
            log("<- unexpected %d-byte upload on :%d (no pull in flight)"
                % (len(data), PULL_PORT))


class ReuseTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


# Where log() mirrors its output, in addition to the console.
#
# The daemon's console has been the only record of what it did, and that has
# cost real time: every question of the form "was that job actually
# dispatched, and did the box acknowledge it?" is answered in these lines and
# nowhere else, so anyone not sitting in front of that window has to reason
# from symptoms instead. Worse, the window scrolls -- the evidence for a
# failure is routinely gone by the time somebody asks about it.
#
# So it is mirrored to a file, unconditionally and by default. The volume is
# a few lines per poll, and DOSD_LOGFILE= (empty) turns it off for anyone who
# would rather it did not write.
LOG_PATH = os.environ.get(
    "DOSD_LOGFILE",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "dosd.log"))
_log_lock = threading.Lock()


def log(msg):
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    if not LOG_PATH:
        return
    # Never let a logging problem take the daemon down: a full disk or a
    # locked file is a reason to lose the log, not the bridge.
    try:
        with _log_lock:
            with io.open(LOG_PATH, "a", encoding="utf-8", newline="\n") as fh:
                fh.write("%s %s\n" % (time.strftime("%Y-%m-%d"), line))
    except Exception:
        pass



# ---------------------------------------------------------------------------
# TFTP  --  the UDP transport that replaces HTGET and NC
#
# Four opcodes, 512-byte blocks, one packet in flight. Chosen over
# reimplementing HTTP because HTTP means TCP, and TCP's failure mode is the
# one that matters here: correct on the bench, silently corrupting under
# loss, in the component whose failure cannot be fixed from this side.
#
# Note each transfer gets its OWN socket, on an ephemeral port. That is not
# an implementation detail -- it is the TFTP transfer identifier, and the DOS
# client locks onto it from the first packet. Serving a whole transfer from
# the well-known port would work against a naive client and against nothing
# else.
# ---------------------------------------------------------------------------

TFTP_BLK = 512
# Retry budget for a lossy link. The DOS client is deliberately the MORE
# patient of the two -- whichever side gives up first decides the outcome,
# and the client is the one that can actually report what happened.
# RFC 2347 option acknowledgement, and RFC 2348's blksize.
#
# 512-byte blocks put a 5 MB transfer at nearly eight minutes on this link,
# almost all of it per-packet overhead rather than bandwidth. Bigger blocks
# are the single biggest throughput win available and cost one extra round
# trip to negotiate.
#
# The ceiling is what fits in one Ethernet frame without fragmenting, because
# the DOS side drops fragments rather than reassembling them: 1500 - 20 (IP)
# - 8 (UDP) - 4 (TFTP) = 1468. 1400 leaves room for any tunnelling or
# driver-side overhead and still cuts the packet count by nearly two thirds.
OP_OACK = 6
TFTP_BLK_MAX = 1400
TFTP_RETRIES = 8
# Retransmits when SERVING A FILE. Separate from the job reply, which
# wants a short budget (nobody is listening past ~11s), and from this
# default, which a file transfer wants to exceed: a stalled transfer on
# this link does not recover inside 16 seconds and dies, while the very
# next attempt succeeds -- which is what a link-level dropout looks
# like rather than a lost packet. Overridable so the outage can be
# measured instead of guessed at.
FILE_SEND_RETRIES = int(os.environ.get("DOSD_FILE_RETRIES", "8"))
# Retransmits for a JOB reply only. The client's own patience is about 11
# seconds, so anything past ~5 attempts at the 2-second timeout is spent
# talking to nobody. File transfers keep the full budget: there the client
# really is still waiting.
POLL_SEND_RETRIES = 5
TFTP_TIMEOUT = 2.0
# The job hold is SHORT, and deliberately much shorter than the HTTP
# path's. Our DOS stack does not answer ARP -- while it holds the IPv4
# handle it never even sees an ARP request -- so if this host's ARP
# entry for the box expires during the hold, the reply cannot be
# delivered and the poll fails with no packet on the wire at all.
# Measured: an 8-second hold outlived the cache entry often enough to
# fail roughly one poll in three. Two seconds always lands inside it.
#
# THE REAL FIX IS DONE, as of 2026-09-12: net.pas holds the 0806 handle
# alongside 0800 and answers ARP requests for the box, so this host's entry
# now resolves properly and stays Reachable instead of ageing out into
# Unreachable. The same fault was the mid-transfer stall -- see the ARP
# section in docs/network.md, which has the neighbour-state traces.
#
# The hold is NOT being raised on the strength of that. The comment above
# describes a poll failure measured against the old behaviour, and whether a
# longer hold is safe now is a question for a measurement rather than for
# reasoning from the fix. It is also a box running an OLD UGET that a longer
# hold would break, and there is no way from here to tell which it is.
# NOTE: serve_job holds for POLL_HOLD_SECS, not this. This constant was
# added when the hold was 'reduced 8s -> 2s' to chase the poll losses,
# and nothing ever read it -- which is why that change appeared to make
# no difference. It did not: the hold stayed at 8 seconds.
TFTP_HOLD_SECS = 2  # unused; see POLL_HOLD_SECS

# Clients that currently have a job request being held open, keyed by their
# address. The job poll is a LONG poll -- the server sits on the request for
# several seconds -- so a client that retransmits because it thinks the
# request was lost would otherwise start a second hold and take a second job
# off the queue while the first went nowhere. Ignoring the duplicate lets the
# original hold answer it, which is what makes client retransmission safe,
# and retransmission is what lets the poll survive a lost packet without an
# mTCP fallback underneath it.
_job_holds = {}
_job_holds_lock = threading.Lock()

# The same idea for file transfers, keyed by (client address, opcode, name).
# See the long note in tftp_serve for what a duplicate flow does to a client
# that is already talking to the first one.
_xfer_holds = {}
_xfer_holds_lock = threading.Lock()

OP_RRQ, OP_WRQ, OP_DATA, OP_ACK, OP_ERROR = 1, 2, 3, 4, 5


def tftp_error(sock, addr, code, msg):
    sock.sendto(struct.pack("!HH", OP_ERROR, code)
                + msg.encode("latin-1", "replace") + b"\0", addr)


# Flows currently serving a file, keyed by (client IP, name). The value is a
# list of threading.Event, one per live flow, set to ask that flow to stop.
#
# THE ZOMBIE AVALANCHE, which is what this exists to stop.
#
# When a transfer stalls, the client's recovery is to tear its flow down,
# take a NEW local port and ask for the rest of the file. That is the only
# thing that has ever cleared a stall, and it stays. What nobody accounted
# for is what the ABANDONED flow does next: nothing tells this end, so it
# sits in tftp_send_blob retransmitting the block in flight 8 times at a
# 2-second timeout -- sixteen full seconds of DATA aimed at a port the client
# has already stopped listening on.
#
# The client restarts after three silent timeouts, about six seconds. So a
# zombie outlives its replacement by ten seconds, and at 16 seconds of life
# against a 6-second restart interval roughly three of them are shouting at
# any moment. Every one of those packets still arrives at the card, still has
# to be inspected, and -- this is what makes it an avalanche rather than
# waste -- the DOS receiver holds exactly ONE frame at a time. A zombie's
# DATA sitting in that slot means the real flow's next block is dropped on
# arrival. Dropped blocks cause a stall; a stall causes a restart; a restart
# creates another zombie.
#
# The measurement that showed it: a 5 MB fetch failed after 461s with 23
# stalls, and of the 90 frames that arrived DURING those stall windows, 89
# were rejected as "not ours" -- against 8% foreign traffic over the transfer
# as a whole. During a stall the card is not quiet and it is not deaf. It is
# busy carrying our own dead flows' retransmissions.
#
# So: a new request for the same file from the same client means every
# earlier flow is abandoned by definition -- the client just said so -- and
# they are cancelled rather than left to time out.
_flows = {}
_flows_lock = threading.Lock()


def flow_begin(ip, name):
    """Register a flow, cancelling any earlier one for the same file."""
    key = (ip, name.lower())
    ev = threading.Event()
    with _flows_lock:
        old = _flows.get(key) or []
        for prev in old:
            prev.set()
        _flows[key] = [e for e in old if not e.is_set()] + [ev]
    if old:
        log("tftp: %s asked for %s again -- cancelling %d superseded flow(s)"
            % (ip, name, len(old)))
    return ev


def flow_end(ip, name, ev):
    key = (ip, name.lower())
    with _flows_lock:
        live = _flows.get(key)
        if live is not None:
            if ev in live:
                live.remove(ev)
            if not live:
                _flows.pop(key, None)


def tftp_send_blob(sock, addr, blob, retries=None, blk=None, cancel=None):
    """Serve a blob as a TFTP read.

    Returns (ok, blocks_acked). The count matters for the job resource: a
    client that acknowledged nothing definitely never saw the batch, so the
    job can be safely put back on the queue. One that acknowledged part of it
    may well have the whole thing, and requeueing then would run somebody's
    job twice.

    `retries` exists because retransmitting is only useful while somebody is
    still listening. The default budget is 8 attempts at a 2-second timeout --
    16 seconds - which is right for a file transfer the client will wait out,
    and pure waste for the job poll: UGET gives up after about 11 seconds, so
    the last five were spent shouting at a client that had already gone, on a
    thread that could not report the failure until it finished. It also
    delayed the NO ACK log line past the point where it lined up with anything
    else on the screen.
    """
    if retries is None:
        retries = TFTP_RETRIES
    if blk is None:
        blk = TFTP_BLK
    block, off = 1, 0
    acked_count = 0
    while True:
        chunk = blob[off:off + blk]
        pkt = struct.pack("!HH", OP_DATA, block & 0xFFFF) + chunk
        acked = False
        for _ in range(retries):
            # Checked before every send, not just per block: the whole point
            # is to stop putting packets on the wire the moment the client
            # tells us it has moved on, and the retry loop is where a dead
            # flow spends all of its time.
            if cancel is not None and cancel.is_set():
                return False, acked_count
            sock.sendto(pkt, addr)
            try:
                while True:
                    data, src = sock.recvfrom(1024)
                    if src != addr or len(data) < 4:
                        continue
                    # NOT `blk` -- that is the block SIZE, and unpacking
                    # the acknowledged block NUMBER over it silently rewrote
                    # the size to 1 on the first ACK. Every transfer then sent
                    # 512 bytes followed by a single byte, which the client
                    # correctly read as a short final block: a 513-byte file,
                    # complete as far as both ends could tell. That truncated
                    # a job batch to its first few lines -- the program ran and
                    # the result send was never in the file -- and it is where
                    # "UGET.EXE is 513 bytes" came from when a deploy of it
                    # stranded the box.
                    op, ack_blk = struct.unpack("!HH", data[:4])
                    if op == OP_ERROR:
                        return False, acked_count
                    if op != OP_ACK:
                        continue
                    if ack_blk == (block & 0xFFFF):
                        acked = True
                        break
                    # A duplicate ACK for an earlier block. It means our DATA
                    # never arrived, so break out and send it again NOW.
                    #
                    # This line is the whole fix for large transfers, and the
                    # bug it removes is a genuine deadlock rather than a lost
                    # packet. `continue` here -- which is what it used to do --
                    # goes back to recvfrom with a FRESH two-second timeout.
                    # The client, having timed out waiting for the block,
                    # re-ACKs the previous one every two seconds. Each of those
                    # reset this timer, so the server never reached its
                    # timeout and therefore never retransmitted, while the
                    # client sat waiting for a block that was never coming.
                    # Both sides then waited for each other until the client
                    # exhausted its retries and declared the transfer stalled.
                    #
                    # One lost DATA packet was enough to trigger it, which is
                    # why it looked size-dependent: 68-block transfers almost
                    # always got through untouched and 600-block ones never
                    # did. Measured before the fix: 34 KB succeeded 38 times
                    # out of 38, while 300 KB failed 6 times out of 6, each at
                    # a different block. The next transfer always worked,
                    # which is what sent the investigation chasing link-level
                    # dropouts and ARP expiry for far too long.
                    break
            except socket.timeout:
                continue
            if acked:
                break
        if not acked:
            return False, acked_count
        acked_count += 1
        off += len(chunk)
        block += 1
        # A short block ends the transfer by definition; a file that is an
        # exact multiple of the block size ends with an empty one.
        if len(chunk) < blk:
            return True, acked_count


def tftp_parse_options(parts):
    """Options from an RRQ: name\0mode\0 then key\0value\0 pairs."""
    opts = {}
    rest = parts[2:]
    for i in range(0, len(rest) - 1, 2):
        k = rest[i].decode("latin-1", "replace").lower()
        v = rest[i + 1].decode("latin-1", "replace")
        if k:
            opts[k] = v
    return opts


def tftp_send_oack(sock, addr, opts, retries, cancel=None):
    """Acknowledge the options we accepted, and wait for the ACK of block 0.

    RFC 2347: the OACK replaces DATA block 1 as the first thing the client
    hears, and the client answers it with an ACK for block 0 before any data
    moves. Only options we are actually honouring get echoed; anything left
    out keeps its default, which is what lets an old client and a new server
    (or the reverse) still talk.
    """
    pkt = struct.pack("!H", OP_OACK)
    for k, v in opts:
        pkt += k.encode() + b"\0" + str(v).encode() + b"\0"
    for _ in range(retries):
        if cancel is not None and cancel.is_set():
            return False
        sock.sendto(pkt, addr)
        try:
            while True:
                data, src = sock.recvfrom(1024)
                if src != addr or len(data) < 4:
                    continue
                op, blk = struct.unpack("!HH", data[:4])
                if op == OP_ERROR:
                    return False
                if op == OP_ACK and blk == 0:
                    return True
                # Anything else: resend the OACK now rather than waiting out
                # the timeout, for the same reason DATA does.
                break
        except socket.timeout:
            continue
    return False


# Writes that stalled partway, keyed by (client address, name).
#
# The client tears its flow down and asks again from the byte it last had
# acknowledged -- the same trick TftpGet uses, because a fresh flow is the
# only thing that has ever cleared this link's mid-transfer stall. That only
# works if the server still holds what arrived before, so the bytes outlive
# the flow that carried them.
#
# Pruned by age rather than on failure: the whole point is to keep a partial
# alive across a gap, so it cannot be discarded when the transfer that made
# it goes quiet.
_uploads = {}
_uploads_lock = threading.Lock()
UPLOAD_TTL = 600


def upload_buf(key, resume_at):
    """The buffer to append a write into, or None if it cannot be resumed."""
    now = time.time()
    with _uploads_lock:
        for k in [k for k, v in _uploads.items() if now - v[1] > UPLOAD_TTL]:
            del _uploads[k]
        if resume_at == 0:
            buf = bytearray()
            _uploads[key] = [buf, now]
            return buf
        ent = _uploads.get(key)
        # The client resumes from the last byte IT saw acknowledged, so it is
        # normally BEHIND us: every ACK we sent whose reply was lost left us
        # holding a block the client still believes it owes. Rewinding to the
        # client's figure is correct -- it is about to send those blocks
        # again, identically.
        #
        # Asking to resume PAST what we hold is the one case that must be
        # refused: there is no way to fill the gap, and appending anyway would
        # produce a plausible file with a hole in it that nothing downstream
        # would notice.
        if ent is None or resume_at > len(ent[0]):
            _uploads.pop(key, None)
            return None
        # A fresh bytearray rather than truncating in place. The flow that
        # stalled may still be inside its retry loop on another thread,
        # holding a reference to the old object; letting it append into the
        # buffer this flow is filling would interleave two writers.
        buf = bytearray(ent[0][:resume_at])
        _uploads[key] = [buf, now]
        return buf


def tftp_recv_blob(sock, addr, blk_size=None, oack=None, out=None,
                   cancel=None):
    """Take a TFTP write. Returns the bytes, or None if it failed.

    `blk_size` is the negotiated block size; `oack` is the option list to
    acknowledge, or None to start the transfer with a plain ACK of block 0.
    RFC 2347 puts the OACK in place of that first ACK -- sending both would
    have the client answer twice.
    """
    if blk_size is None:
        blk_size = TFTP_BLK
    if out is None:
        out = bytearray()
    expect, last_ack = 1, 0
    if oack:
        first = struct.pack("!H", OP_OACK)
        for k, v in oack:
            first += k.encode() + b"\0" + str(v).encode() + b"\0"
    else:
        first = struct.pack("!HH", OP_ACK, 0)
    sock.sendto(first, addr)
    while True:
        got = None
        for _ in range(TFTP_RETRIES):
            # A superseded write flow re-ACKs into a port the client has
            # stopped listening on, for exactly the same reason and with
            # exactly the same effect as a superseded read flow. See _flows.
            if cancel is not None and cancel.is_set():
                return None
            try:
                data, src = sock.recvfrom(blk_size + 512)
            except socket.timeout:
                # Re-send whatever started or last advanced the transfer. On
                # the very first block that is the OACK, not an ACK: a client
                # waiting for its options to be confirmed ignores an ACK 0 it
                # never asked for, and the transfer would stall here.
                sock.sendto(first if last_ack == 0 else
                            struct.pack("!HH", OP_ACK, last_ack), addr)
                continue
            if src != addr or len(data) < 4:
                continue
            op, blk = struct.unpack("!HH", data[:4])
            if op == OP_ERROR:
                return None
            if op != OP_DATA:
                continue
            got = (blk, data[4:])
            break
        if got is None:
            return None
        blk, payload = got
        if blk == (expect & 0xFFFF):
            out += payload
            sock.sendto(struct.pack("!HH", OP_ACK, blk), addr)
            last_ack, expect = blk, expect + 1
            if len(payload) < blk_size:
                return bytes(out)
        elif blk == ((expect - 1) & 0xFFFF):
            # They did not hear the ACK. Re-ACK without appending, or the
            # blob silently gains a duplicate block.
            sock.sendto(struct.pack("!HH", OP_ACK, blk), addr)


def serve_job(sock, addr):
    """Hold a job request open, then hand over whatever came up."""
    # last_poll is stamped before the hold, so `dosctl status` does not call a
    # box stale while it is legitimately waiting on us.
    STATE.last_poll = time.time()
    log("   job RRQ from %s:%d -- holding" % addr)
    job = STATE.take(POLL_HOLD_SECS)
    if job is None:
        ok, _ = tftp_send_blob(sock, addr, to_dos_text(IDLE_BATCH),
                               retries=POLL_SEND_RETRIES)
        log("   idle batch -> %s:%d  %s" % (addr[0], addr[1],
                                            "acked" if ok else "NO ACK"))
        return
    job.dispatched_at = time.time()
    with STATE.lock:
        STATE.awaiting = job
        if job.kind == "pull":
            STATE.awaiting_pull = job
    log("-> dispatch %s  %s  (tftp)" % (job.id, job.label))
    ok, acked = tftp_send_blob(sock, addr, to_dos_text(job.batch),
                               retries=POLL_SEND_RETRIES)
    if ok:
        return

    # Delivery failed. Whether the job can be put back depends on how far it
    # got: a client that acknowledged NOTHING never saw the batch, so
    # requeueing is safe and stops the job being lost. One that acknowledged
    # part of it may hold the complete file already, and requeueing would run
    # it twice -- worse than losing it, because a repeat of an arbitrary
    # command is not something the caller can see or undo.
    if acked == 0:
        with STATE.lock:
            if STATE.awaiting is job:
                STATE.awaiting = None
            if STATE.awaiting_pull is job:
                STATE.awaiting_pull = None
        STATE.pending.put(job)
        log("   udp dispatch of %s failed with nothing acked -- requeued"
            % job.id)
    else:
        log("   udp dispatch of %s failed after %d block(s) acked -- NOT "
            "requeued, it may already have run" % (job.id, acked))


def tftp_serve(req, addr):
    if len(req) < 4:
        return
    op = struct.unpack("!H", req[:2])[0]
    parts = req[2:].split(b"\0")
    name = parts[0].decode("latin-1", "replace")

    # A repeat of a request we are ALREADY serving is a retransmit, and the
    # flow that is running will answer it. Starting a second one does active
    # harm, which is not obvious and cost weeks.
    #
    # The client retransmits its request when the first reply does not arrive
    # in time -- from the SAME local port, because only a flow REBUILT after a
    # stall picks a new one. So the two requests are indistinguishable to us,
    # and each used to get its own thread, its own socket and its own copy of
    # the file. Both then answered. The client locks on to whichever TID it
    # hears from first (RFC 1350's transfer identifier, and correct), so the
    # loser spent its entire retry budget -- 8 attempts at 2 seconds -- taking
    # to a client that could never reply. Every `did not confirm blksize 1400`
    # in dosd.log is one of those, 32 of them, and they cluster exactly where
    # transfers were failing.
    #
    # The cost was never the wasted thread. It was what the phantom did to the
    # client: an OACK every two seconds, which the client accepted (its OACK
    # branch did not check the TID) and answered by resetting its stall
    # counter and re-ACKing block 0 at the real flow. Resetting that counter
    # held off the rebuild-the-flow recovery for as long as the phantom kept
    # talking -- the transfer was pinned inside the one fault it knows how to
    # escape -- and the stray ACK 0 made the real flow retransmit the block in
    # flight, on a link whose card holds one frame at a time.
    #
    # This is the same deduplication the job poll has had since it was found
    # that a retransmitted poll took a second job off the queue. It was always
    # needed on both, and only the job case had been hit.
    #
    # A resume is deliberately NOT caught: it carries `name@offset` and comes
    # from a new port, so it differs in both halves of the key. That matters,
    # because a resume arriving while the stalled flow is still winding down
    # is the normal case, not the exception.
    hold = None
    if op in (OP_RRQ, OP_WRQ) and name.lower() != "job":
        hold = (addr, op, name.lower())
        with _xfer_holds_lock:
            if hold in _xfer_holds:
                log("tftp: %s re-asked for %s while it is already being "
                    "served -- dropped, the running flow will answer"
                    % (addr[0], name))
                return
            _xfer_holds[hold] = True

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 0))
    sock.settimeout(TFTP_TIMEOUT)
    try:
        if op == OP_RRQ:
            if name.lower() == "job":
                with _job_holds_lock:
                    if addr in _job_holds:
                        # A retransmit of a request we are already holding.
                        # Drop it; the original hold will answer.
                        return
                    _job_holds[addr] = True
                try:
                    serve_job(sock, addr)
                finally:
                    with _job_holds_lock:
                        _job_holds.pop(addr, None)
                return

            # "name@12345" means "send me this file from byte 12345".
            #
            # TFTP has no notion of resuming, and this is the smallest thing
            # that gives us one. It exists because of a failure this link has
            # that nothing on the DOS side can reach: partway through a long
            # transfer, frames addressed to the box's MAC stop being delivered
            # to it while broadcasts keep arriving, and no amount of retrying,
            # re-taking the packet driver handle, or even putting the card in
            # promiscuous mode brings them back. A brand new flow, however,
            # always works -- which is why every transfer succeeded on the
            # attempt after the one that stalled.
            #
            # So rather than start a 5 MB file again from nothing, the client
            # tears its flow down completely and asks for the rest.
            resume_at = 0
            if "@" in name:
                name, _, tail = name.rpartition("@")
                if not tail.isdigit():
                    tftp_error(sock, addr, 4, "bad resume offset")
                    return
                resume_at = int(tail)

            rel = safe_rel(name)
            full = rel_to_path(rel) if rel else None
            if full is None or not os.path.isfile(full):
                log("tftp: %s asked for %r -- not found" % (addr[0], name))
                tftp_error(sock, addr, 1, "file not found")
                return
            with open(full, "rb") as fh:
                blob = fh.read()
            blk = TFTP_BLK
            opts = tftp_parse_options(parts)
            if "blksize" in opts:
                try:
                    want = int(opts["blksize"])
                except ValueError:
                    want = TFTP_BLK
                blk = max(8, min(want, TFTP_BLK_MAX))
            if resume_at:
                if resume_at > len(blob):
                    # The client believes it has more of this file than
                    # exists. That is a client-side overcount and it ends the
                    # transfer, so say so here -- it used to be answered with
                    # an ERROR and no log line at all, which made a 5 MB fetch
                    # die at 95% for no recorded reason.
                    log("tftp: %s asked to resume %s at byte %d but it is "
                        "only %d bytes -- refusing"
                        % (addr[0], name, resume_at, len(blob)))
                    tftp_error(sock, addr, 1, "resume past end of file")
                    return
                log("tftp: %s resuming %s at byte %d"
                    % (addr[0], name, resume_at))
                blob = blob[resume_at:]
            # Registered AFTER the file is known to exist, so a request for a
            # missing name cannot cancel a transfer that is going fine.
            cancel = flow_begin(addr[0], name)
            try:
                if blk != TFTP_BLK:
                    if not tftp_send_oack(sock, addr, [("blksize", blk)],
                                          FILE_SEND_RETRIES, cancel=cancel):
                        if cancel.is_set():
                            log("tftp: %s superseded before blksize %d was "
                                "confirmed for %s" % (addr[0], blk, name))
                        else:
                            log("tftp: %s did not confirm blksize %d for %s"
                                % (addr[0], blk, name))
                        return
                ok, _ = tftp_send_blob(sock, addr, blob,
                                       retries=FILE_SEND_RETRIES, blk=blk,
                                       cancel=cancel)
            finally:
                flow_end(addr[0], name, cancel)
            if cancel.is_set() and not ok:
                log("tftp: send of %s to %s stopped -- superseded by a newer "
                    "request" % (name, addr[0]))
            else:
                log("tftp: sent %s (%d bytes, blk %d) to %s%s"
                    % (name, len(blob), blk, addr[0], "" if ok else "  FAILED"))

        elif op == OP_WRQ:
            # "name@12345" resumes a write that stalled, the mirror of the
            # read side above.
            resume_at = 0
            if "@" in name:
                name, _, tail = name.rpartition("@")
                if not tail.isdigit():
                    tftp_error(sock, addr, 4, "bad resume offset")
                    return
                resume_at = int(tail)

            ukey = (addr[0], name.lower())
            buf = upload_buf(ukey, resume_at)
            if buf is None:
                log("tftp: %s cannot resume write of %s at byte %d "
                    "-- nothing held that far" % (addr[0], name, resume_at))
                tftp_error(sock, addr, 3, "cannot resume there")
                return
            if resume_at:
                log("tftp: %s resuming write of %s at byte %d"
                    % (addr[0], name, resume_at))

            wopts = tftp_parse_options(parts)
            wblk, wack = TFTP_BLK, None
            if "blksize" in wopts:
                try:
                    want = int(wopts["blksize"])
                except ValueError:
                    want = TFTP_BLK
                wblk = max(8, min(want, TFTP_BLK_MAX))
                if wblk != TFTP_BLK:
                    wack = [("blksize", wblk)]
            wcancel = flow_begin(addr[0], "wrq:" + name)
            try:
                blob = tftp_recv_blob(sock, addr, blk_size=wblk, oack=wack,
                                      out=buf, cancel=wcancel)
            finally:
                flow_end(addr[0], "wrq:" + name, wcancel)
            if blob is None:
                # Keep what arrived. The client is expected to come back with
                # a new flow asking to carry on, and throwing the bytes away
                # here would make that impossible.
                log("tftp: write of %r from %s stalled at %d bytes"
                    % (name, addr[0], len(buf)))
                return
            with _uploads_lock:
                _uploads.pop(ukey, None)
            if name.lower() in ("result", "result.txt"):
                ingest_result(blob)
            elif name.lower() == "pull":
                # A pull's bytes, over our own stack. Same sink the legacy
                # NC path used, so dosctl is unchanged either way.
                if STATE.deliver_blob(blob):
                    log("tftp: pulled %d bytes from %s" % (len(blob), addr[0]))
                else:
                    log("tftp: %d-byte pull from %s with no pull in flight"
                        % (len(blob), addr[0]))
            else:
                rel = safe_rel(name)
                full = rel_to_path(rel) if rel else None
                if full is None:
                    log("tftp: refusing write to %r" % name)
                    return
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "wb") as fh:
                    fh.write(blob)
                log("tftp: received %s (%d bytes) from %s"
                    % (name, len(blob), addr[0]))
        else:
            tftp_error(sock, addr, 4, "illegal TFTP operation")
    except OSError as e:
        log("tftp: %s" % e)
    finally:
        sock.close()
        if hold is not None:
            with _xfer_holds_lock:
                _xfer_holds.pop(hold, None)


def tftp_listen():
    # NO SO_REUSEADDR HERE, and that is the whole point of this function's
    # first three lines.
    #
    # UDP has no TIME_WAIT, so SO_REUSEADDR buys nothing on this socket --
    # and on Windows it lets a SECOND dosd bind the same port silently.
    # Two sockets on one UDP port means each arriving datagram is delivered
    # to one of them arbitrarily, so a multi-datagram TFTP transfer gets
    # split between two daemons that each hold their own transfer state.
    # That produces stalled transfers, deploys that fail their CRC, and job
    # results that never come back -- all of which read as faults on the
    # DOS side or on the wire.
    #
    # Found on 2026-09-10 with two daemons 30 minutes apart in the process
    # list, both bound to 8069, both appending to the same dosd.log so the
    # log looked perfectly continuous. These notes already warned that "is
    # exactly one running?" is worth checking before believing any
    # measurement; this makes the question unnecessary.
    #
    # Without it the second instance fails to bind, which is the correct
    # outcome and is now said out loud rather than left as a traceback in a
    # daemon thread.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("0.0.0.0", TFTP_PORT))
    except OSError as exc:
        log("dosd: cannot bind UDP %d -- another dosd is already running."
            % TFTP_PORT)
        log("      Stop it first (Ctrl-C in its window, or dosctl shutdown).")
        log("      Two daemons on this port split TFTP transfers between")
        log("      them and the symptoms look like a failing DOS box: %s"
            % exc)
        os._exit(1)
    while True:
        try:
            req, addr = s.recvfrom(2048)
        except OSError:
            continue
        threading.Thread(target=tftp_serve, args=(req, addr),
                         daemon=True).start()


def main():
    os.makedirs(FILES_DIR, exist_ok=True)
    exit0 = os.path.join(FILES_DIR, "EXIT0.COM")
    if not os.path.isfile(exit0):
        with open(exit0, "wb") as fh:
            fh.write(EXIT0_COM)
    http = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    http.daemon_threads = True
    raw = ReuseTCPServer(("0.0.0.0", RESULT_PORT), ResultHandler)
    pull = ReuseTCPServer(("0.0.0.0", PULL_PORT), PullHandler)

    threading.Thread(target=raw.serve_forever, daemon=True).start()
    threading.Thread(target=pull.serve_forever, daemon=True).start()
    threading.Thread(target=tftp_listen, daemon=True).start()
    log("dosd listening: http :%d   results :%d   pull :%d   tftp/udp :%d"
        % (HTTP_PORT, RESULT_PORT, PULL_PORT, TFTP_PORT))
    # Present only in a built installer, never in the dev tree -- so this line
    # appears exactly when it is useful: telling you which packaged build a
    # machine is running, without having to ask its owner.
    ver = os.path.join(os.path.dirname(os.path.abspath(__file__)), "VERSION.txt")
    if os.path.isfile(ver):
        try:
            with open(ver) as fh:
                log("DOS Bridge " + " ".join(fh.read().split()))
        except OSError:
            pass
    log("serving files from %s" % FILES_DIR)
    log("waiting for the DOS box to poll /job ...")
    try:
        http.serve_forever()
    except KeyboardInterrupt:
        log("bye")
    finally:
        # Restarting dosd is routine -- several times in a bad session -- so
        # release the listeners rather than leaving the next start to fail on
        # "address already in use".
        # Stop each accept loop BEFORE closing its socket. Closing one out
        # from under the thread still selecting on it raises WinError 10038
        # on the way out -- harmless, but a stack trace at shutdown is
        # indistinguishable at a glance from a crash.
        for srv in (raw, pull):
            try:
                srv.shutdown()
            except Exception:
                pass
        for srv in (http, raw, pull):
            try:
                srv.server_close()
            except Exception:
                pass


if __name__ == "__main__":
    main()
