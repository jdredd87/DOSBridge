#!/usr/bin/env python3
"""
DOS Bridge  --  StevenC

dosd - job server bridging a Windows dev box to a real DOS machine over WiFi.

Runs on Windows 11. The DOS box polls it for work over HTTP (mTCP HTGET) and
posts results back over a raw TCP socket (mTCP NC).

  port 8080  HTTP   /job          long-poll, returns a JOB.BAT for DOS to CALL
                    /f/<name>     serves files from ./files
                    /queue        (CLI) queue a job, returns job id
                    /result/<id>  (CLI) long-poll for that job's result
                    /status       (CLI) health / last-seen-boot info
  port 8081  raw    result intake from NC (text; parses ##JOB=/##RC= framing)
  port 8082  raw    binary intake from NC for `dosctl pull` -- no decoding at
                    all, so files come back byte-exact

Start it once and leave it running:  python dosd.py
"""

import base64
import json
import os
import re
import queue
import socket
import socketserver
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

HTTP_PORT = 8080
RESULT_PORT = 8081
PULL_PORT = 8082
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
POLL_HOLD_SECS = 8

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


def build_run_batch(job_id, exe_name, args, reboot_after, cold):
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
        "ECHO [dosd] job %s: %s" % (job_id, exe_name),
        "IF EXIST C:\\WORK\\%s DEL C:\\WORK\\%s" % (exe, exe),
        "HTGET -o C:\\WORK\\%s http://%%SRV%%/f/%s > NUL" % (exe, exe_name),
        "IF NOT EXIST C:\\WORK\\%s GOTO NOFILE" % exe,
        "IF EXIST C:\\WORK\\OUT.TXT DEL C:\\WORK\\OUT.TXT",
        cmd + " > C:\\WORK\\OUT.TXT",
    ]
    lines += errorlevel_capture()
    lines += [
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "IF EXIST C:\\WORK\\OUT.TXT TYPE C:\\WORK\\OUT.TXT >> C:\\WORK\\RES.TXT",
        "ECHO ##RC=%RC% >> C:\\WORK\\RES.TXT",
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
        "GOTO END",
        ":NOFILE",
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: download of %s failed >> C:\\WORK\\RES.TXT" % exe_name,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
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
        "ECHO [dosd] job %s: staging driver %s" % (job_id, drv_name),
        "IF EXIST C:\\WORK\\%s DEL C:\\WORK\\%s" % (drv, drv),
        "HTGET -o C:\\WORK\\%s http://%%SRV%%/f/%s > NUL" % (drv, drv_name),
        "IF NOT EXIST C:\\WORK\\%s GOTO NOFILE" % drv,
        "IF EXIST C:\\AGENT\\PEND.BAT DEL C:\\AGENT\\PEND.BAT",
        "HTGET -o C:\\AGENT\\PEND.BAT http://%SRV%/f/PEND.BAT > NUL",
        "IF NOT EXIST C:\\AGENT\\PEND.BAT GOTO NOFILE",
        "ECHO ##JOB=%s > C:\\AGENT\\PENDID.TXT" % job_id,
        "COLDBOOT.COM" if cold else "REBOOT.COM",
        "GOTO END",
        ":NOFILE",
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: download of %s failed >> C:\\WORK\\RES.TXT" % drv_name,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
        ":END",
    ]
    return lines


def build_pull_batch(job_id, remote_path):
    """
    Ship a file off the DOS box byte-exact.

    NC reads the file itself, so this never passes through TYPE and is immune
    to the 0x1A (Ctrl-Z) truncation that makes `dosexec "TYPE ..."` useless for
    binaries. The bytes land on PULL_PORT, which does no decoding and no
    line-ending normalisation at all.

    `-bin` is load-bearing and must not be dropped. Without it NC opens stdin
    in text mode and silently eats every 0x0D and 0x1A on the way out: a 27298
    byte SYSINFO.EXE arrived as 27258, corrupt but plausible-looking. Measured
    on a 5-byte probe containing both, plain NC delivered 3 bytes and `NC -bin`
    delivered 5.

    Only the not-found path reports on RESULT_PORT; a successful transfer is
    signalled by the bytes themselves arriving.
    """
    return [
        "@ECHO OFF",
        "ECHO [dosd] job %s: pull %s" % (job_id, remote_path),
        "IF NOT EXIST %s GOTO NOFILE" % remote_path,
        "NC -bin -target %UPHOST% " + str(PULL_PORT)
        + " < " + remote_path + " > NUL",
        "GOTO END",
        ":NOFILE",
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: %s not found on the DOS box >> C:\\WORK\\RES.TXT" % remote_path,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
        ":END",
    ]


def build_deploy_batch(job_id, name, dest_dir):
    """
    Fetch a staged file onto the DOS box and confirm it actually landed.

    HTGET exits >= 20 even on success, so its errorlevel is worthless as a
    signal -- IF EXIST is the only trustworthy check.
    """
    dest = dest_dir.rstrip("\\") + "\\" + leaf_of(name)
    return [
        "@ECHO OFF",
        "ECHO [dosd] job %s: deploy %s -> %s" % (job_id, name, dest),
        "IF EXIST %s DEL %s" % (dest, dest),
        "HTGET -o %s http://%%SRV%%/f/%s > NUL" % (dest, name),
        "IF NOT EXIST %s GOTO NOFILE" % dest,
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "DIR %s >> C:\\WORK\\RES.TXT" % dest,
        "ECHO ##RC=0 >> C:\\WORK\\RES.TXT",
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
        "GOTO END",
        ":NOFILE",
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: download of %s failed >> C:\\WORK\\RES.TXT" % name,
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
        ":END",
    ]


def build_raw_batch(job_id, body_lines):
    """
    Arbitrary DOS commands, with output captured and returned.

    EXIT0.COM runs immediately before the caller's commands to force ERRORLEVEL
    to a known 0. Without it the ladder below reads a stale value: DOS internal
    commands (ECHO, VER, DIR, IF, DEL, TYPE) never touch ERRORLEVEL, so a list
    made only of those reports whatever the last *external* program left behind
    -- in practice the HTGET that fetched this JOB.BAT, which exits high enough
    to pin the ladder at MAX_ERRORLEVEL. If the fetch fails we degrade to that
    old stale-value behaviour rather than breaking the job.
    """
    lines = [
        "@ECHO OFF",
        "IF NOT EXIST C:\\AGENT\\EXIT0.COM HTGET -o C:\\AGENT\\EXIT0.COM "
        "http://%SRV%/f/EXIT0.COM > NUL",
        "IF EXIST C:\\WORK\\OUT.TXT DEL C:\\WORK\\OUT.TXT",
        "IF EXIST C:\\AGENT\\EXIT0.COM C:\\AGENT\\EXIT0.COM",
    ]
    for c in body_lines:
        lines.append("%s >> C:\\WORK\\OUT.TXT" % c)
    lines += errorlevel_capture()
    lines += [
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "IF EXIST C:\\WORK\\OUT.TXT TYPE C:\\WORK\\OUT.TXT >> C:\\WORK\\RES.TXT",
        "ECHO ##RC=%RC% >> C:\\WORK\\RES.TXT",
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
    ]
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
        "ECHO [dosd] job %s: agent upgrade" % job_id,
        "IF EXIST C:\\AGENT\\AINEW.BAT DEL C:\\AGENT\\AINEW.BAT",
        "HTGET -o C:\\AGENT\\AINEW.BAT http://%%SRV%%/f/%s > NUL" % name,
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
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
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
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
        "GOTO END",
        ":NOFILE",
        "ECHO ##JOB=%s > C:\\WORK\\RES.TXT" % job_id,
        "ECHO dosd: download of the new agent failed >> C:\\WORK\\RES.TXT",
        "ECHO ##RC=254 >> C:\\WORK\\RES.TXT",
        "NC -target %UPHOST% " + str(RESULT_PORT) + " < C:\\WORK\\RES.TXT > NUL",
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
            job = STATE.take(POLL_HOLD_SECS)
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
                                    req.get("reboot", False), req.get("cold", False))
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
            batch = build_raw_batch(jid, req["cmds"])
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
        raw = b"".join(chunks).decode("cp437", errors="replace")
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


class PullHandler(socketserver.BaseRequestHandler):
    """
    Raw binary intake for `dosctl pull`.

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


def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


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
    log("dosd listening: http :%d   results :%d   pull :%d"
        % (HTTP_PORT, RESULT_PORT, PULL_PORT))
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


if __name__ == "__main__":
    main()
