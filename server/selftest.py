#!/usr/bin/env python3
"""Exercise the whole loop: dosd + a simulated DOS box + dosctl."""
import subprocess, sys, time, os, signal, tempfile, socket

HERE = os.path.dirname(os.path.abspath(__file__))
procs = []

# Steps 1-6 run the bridge as a SINGLE machine, and say so explicitly rather
# than relying on there being no boxes.json. There is one in this tree now,
# and without this the simulated box -- which polls from 127.0.0.1, an
# address no real machine is registered at -- would be unroutable and every
# step would fail for a reason that has nothing to do with what it tests.
#
# DOSD_BIND=127.0.0.1 IS THE IMPORTANT ONE HERE. This test starts its own
# dosd, and a daemon bound to 0.0.0.0 is indistinguishable -- to a real DOS
# machine polling the LAN -- from the one it replaced. On 2026-09-21 both
# live boxes polled a selftest daemon and raced the simulated box for its
# jobs. Step 1 dispatches `run local/PROG.EXE`, and PROG.EXE is 3600 bytes
# of generated pattern rather than a program: a real 386SX executed it and
# had to be recovered by hand.
#
# It had always been this way and had never bitten, because the host
# firewall was quietly dropping every inbound poll. Fixing the firewall took
# that accidental protection away and the hazard appeared the same
# afternoon. Binding to loopback makes it structurally impossible rather
# than a thing to remember.
#
ONE_BOX = dict(os.environ, DOSBRIDGE_BOXES="", DOSD_BIND="127.0.0.1")

LOGS = []


def spawn(name, *args, env=None):
    """Start dosd or a simulated box, with its output going to a FILE.

    Not a pipe. Nothing here ever read those pipes, so once a child had
    written about 8 KB it blocked on the next print and simply stopped
    being a DOS box -- and the simulator dumps a whole JOB.BAT per job, so
    that took three or four jobs. The symptom was a job timing out several
    steps into the run with the daemon looking perfectly healthy, which is
    indistinguishable from the transport faults this test exists to catch.
    A file cannot fill, and it is still there to read afterwards.
    """
    base = os.path.splitext(name)[0]
    # Distinct per instance, or two simulated boxes truncate and interleave
    # one file and neither can be read afterwards.
    tag = "%s-%d" % (base, sum(1 for x in LOGS if base in x) + 1)
    path = os.path.join(tempfile.gettempdir(), "selftest-%s.log" % tag)
    fh = open(path, "w")
    LOGS.append(path)
    p = subprocess.Popen([sys.executable, os.path.join(HERE, name)] + list(args),
                         stdout=fh, stderr=subprocess.STDOUT,
                         text=True, env=env or ONE_BOX)
    p._logfile = path
    procs.append(p)
    return p

def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    time.sleep(0.6)
    for p in procs:
        if p.poll() is None:
            p.kill()
    del procs[:]
    time.sleep(0.6)

def cli(*args, timeout=60, env=None):
    r = subprocess.run([sys.executable, os.path.join(HERE, "dosctl.py")] + list(args),
                       capture_output=True, text=True, timeout=timeout,
                       env=env or ONE_BOX)
    return r

def port_busy(port):
    """Is something already listening on this TCP port?"""
    s = socket.socket()
    s.settimeout(0.5)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def udp_busy(port):
    """Is something already bound to this UDP port?

    Connecting proves nothing on UDP -- there is no handshake to refuse -- so
    this binds instead. SO_REUSEADDR is deliberately NOT set: on Windows it
    lets two processes hold the same port and the kernel then picks between
    them per datagram, which is how two dosd instances once ran side by side
    with delivery landing on a coin flip.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", port))
        return False
    except OSError:
        return True
    finally:
        s.close()


# This test starts its OWN dosd and its own simulated DOS box. A dosd already
# running takes port 8080, the copy spawned here cannot bind, and the symptom
# is a 25 second timeout and an assertion failure that says nothing about the
# real cause. Better to say so up front.
# 8069 included: it is the transport now, so a stray listener on it
# breaks every transfer while the TCP ports look perfectly free.
for _p, _busy in ((8069, udp_busy), (8080, port_busy),
                  (8081, port_busy), (8082, port_busy)):
    if _busy(_p):
        print("selftest: port %d is already in use." % _p)
        print()
        print("  This test runs its own dosd, so a dosd started with dosd.cmd")
        print("  must be stopped first. Close that window, then run this again.")
        print("  Start dosd.cmd afterwards -- selftest is the step that proves")
        print("  the Windows half works before any hardware is involved.")
        sys.exit(2)

try:
    d = spawn("dosd.py"); time.sleep(1.5)
    s = spawn("simulate_dos.py"); time.sleep(1.5)

    # Deliberately larger than one TFTP block, in both the 512-byte default
    # and the 1400-byte negotiated size. The old payload was 8 bytes, which is
    # why this test could not have caught the bug that truncated every
    # transfer to 513: nothing it moved ever reached a second block.
    PROG = os.path.join(tempfile.gettempdir(), "PROG.EXE")
    BLOB = bytes((i * 97 + 13) & 0xFF for i in range(3600))
    open(PROG, "wb").write(BLOB)

    print("### 1. run a program, expect stdout + rc 0")
    r = cli("run", PROG, "--timeout", "25", timeout=60)
    print("rc=%d" % r.returncode)
    print(r.stdout.rstrip())
    if r.stderr.strip(): print("stderr:", r.stderr.rstrip())
    assert r.returncode == 0, "expected rc 0"
    assert "All checks passed" in r.stdout, "DOS stdout did not come back"

    print("\n### 2. exec arbitrary DOS commands")
    r = cli("exec", "DIR C:\\WORK", "--timeout", "25", timeout=60)
    print("rc=%d\n%s" % (r.returncode, r.stdout.rstrip()))

    print("\n### 3. status")
    r = cli("status", timeout=20)
    print(r.stdout.rstrip())

    print("\n### 4. round-trip a file, byte for byte")
    # The point of this step is the length, not the plumbing. Both directions
    # of the transport are stop-and-wait with a short final block meaning
    # "done", so an off-by-one in block sizing produces a file that is
    # plausible, complete-looking, and wrong -- which is exactly what happened,
    # and what nothing in this test could see while the payload was 8 bytes.
    BACK = os.path.join(tempfile.gettempdir(), "PROGBACK.BIN")
    if os.path.exists(BACK):
        os.remove(BACK)
    r = cli("pull", "C:\\WORK\\PROG.EXE", "--out", BACK,
            "--timeout", "25", timeout=60)
    print("rc=%d %s" % (r.returncode, r.stdout.rstrip()))
    assert r.returncode == 0, "pull failed"
    got = open(BACK, "rb").read()
    assert len(got) == len(BLOB), (
        "round trip changed the length: sent %d, got %d"
        % (len(BLOB), len(got)))
    assert got == BLOB, "round trip corrupted the bytes"
    print("   %d bytes out and back, identical" % len(got))

    print("\n### 4b. a retransmitted request must not start a second flow")
    # dosd spawns a thread with a fresh socket per request and used to
    # deduplicate only the job poll. A client whose first request went missing
    # retransmits from the SAME local port, so the two are indistinguishable
    # here, and both used to be answered -- leaving the loser shouting an OACK
    # every two seconds at a client already locked on to the winner's transfer
    # identifier. That is where every "did not confirm blksize" came from, and
    # the stray OACKs reset the client's stall counter, pinning it inside the
    # one fault its flow-rebuild recovery exists to escape.
    #
    # Two identical RRQs, then count how many distinct server ports answer.
    # It must be exactly one. Revert the _xfer_holds guard in dosd.py and this
    # sees two, which is the check that makes the test worth having.
    rq = (b"\x00\x01" + b"local/PROG.EXE\x00" + b"octet\x00"
          + b"blksize\x001400\x00")
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.settimeout(3.0)
    probe.bind(("127.0.0.1", 0))
    try:
        probe.sendto(rq, ("127.0.0.1", 8069))
        time.sleep(0.3)
        probe.sendto(rq, ("127.0.0.1", 8069))
        answered = set()
        deadline = time.time() + 4.0
        while time.time() < deadline:
            try:
                _data, src = probe.recvfrom(2048)
            except socket.timeout:
                break
            answered.add(src[1])
    finally:
        probe.close()
    print("   distinct server flows that answered: %d" % len(answered))
    assert len(answered) == 1, (
        "a retransmitted RRQ started %d flows; exactly 1 must answer"
        % len(answered))

    print("\n### 5. inspect a generated driver JOB.BAT")
    sys.path.insert(0, HERE)
    import dosd
    for ln in dosd.build_driver_batch("abc12345", "NEWDRV.SYS", "/i:3", True):
        print("   " + ln)

    print("\n### 6. errorlevel ladder length: %d lines" % len(dosd.errorlevel_capture()))

    # -----------------------------------------------------------------
    # 7. Two boxes at once.
    #
    # Everything above proves the bridge works with one machine. This
    # proves that adding a second does not let one machine's answer come
    # back as the other's -- the only failure in the multi-box design
    # that produces a result looking entirely correct.
    #
    # Both simulated boxes poll from 127.0.0.1, so they are registered
    # with "ip": "any" and routed purely on the id they declare in the
    # resource name -- job.v30 and job.sx386. That is deliberate: it
    # exercises the DECLARED identity path, which is the one a real box
    # uses, rather than the address shortcut that also happens to work.
    # -----------------------------------------------------------------
    print("\n### 7. two boxes on one daemon")
    stop_all()

    # Two ADDRESSES, not just two ids. 127.0.0.2 is a loopback alias
    # Windows accepts without configuration, and the second box binds its
    # sockets to it. That matters: dosd's in-flight flow registry is keyed
    # on the source IP, where a new request for a file already going to
    # that address deliberately supersedes the older transfer -- which is
    # how a stalled one recovers. Two boxes on one address cancel each
    # other's fetches the moment they ask for the same file at once, which
    # is precisely what the fan-out below does. Real machines cannot share
    # an address anyway; boxes.json refuses to register two that way.
    REG = os.path.join(tempfile.gettempdir(), "selftest-boxes.json")
    import json as _json
    with open(REG, "w") as fh:
        _json.dump({"default": "v30", "boxes": {
            "v30": {"ip": "127.0.0.1", "desc": "simulated V30"},
            "sx386": {"ip": "127.0.0.2", "desc": "simulated 386SX"}}}, fh)
    # DOSD_BIND carried here too -- the two-box daemon must be just as
    # unreachable from the LAN as the single-box one above.
    TWO = dict(os.environ, DOSBRIDGE_BOXES=REG, DOSD_BIND="127.0.0.1")

    spawn("dosd.py", env=TWO); time.sleep(1.5)
    spawn("simulate_dos.py", "--box=v30", "--from=127.0.0.1", env=TWO)
    spawn("simulate_dos.py", "--box=sx386", "--from=127.0.0.2", env=TWO)
    time.sleep(3.0)

    r = cli("status", timeout=25, env=TWO)
    print(r.stdout.rstrip())
    for b in ("v30", "sx386"):
        assert b in r.stdout, "%s never appeared in the status board" % b
    assert "never seen" not in r.stdout, (
        "a registered box never polled -- routing by declared id is broken")

    print("\n### 7b. a job goes to the box it was addressed to")
    r = cli("exec", "--box", "sx386", "VER", "--timeout", "25",
            timeout=60, env=TWO)
    print("rc=%d" % r.returncode)
    assert r.returncode == 0, "addressed exec failed"

    print("\n### 7c. an unknown box is refused, not silently defaulted")
    r = cli("exec", "--box", "nosuch", "VER", timeout=25, env=TWO)
    assert r.returncode != 0, "an unknown box id was accepted"
    assert "nosuch" in (r.stdout + r.stderr), "the refusal did not name it"
    print("   refused: %s"
          % (r.stdout + r.stderr).strip().splitlines()[0])

    print("\n### 7d. TWO PULLS AT ONCE must not cross")
    # THE regression test for this change. The pull bytes used to land in
    # a single global slot on the server, which is correct for one DOS box
    # and silently wrong for two: whichever pull the slot happened to hold
    # got the other machine's file, byte-exact and complete-looking.
    #
    # The two boxes are asked for DIFFERENT paths, and the simulator
    # answers a path it never fetched with a body naming that path -- so a
    # crossed pull is visible in the bytes themselves. Revert
    # build_pull_batch to the bare name `pull` and this fails.
    import threading
    got = {}

    def do_pull(box, remote):
        out = os.path.join(tempfile.gettempdir(), "pull-%s.bin" % box)
        if os.path.exists(out):
            os.remove(out)
        rr = cli("pull", remote, "--box", box, "--out", out,
                 "--timeout", "30", timeout=70, env=TWO)
        got[box] = (rr.returncode,
                    open(out, "rb").read() if os.path.exists(out) else b"")

    ts = [threading.Thread(target=do_pull, args=a) for a in
          (("v30", "C:\\WORK\\ONLYV30.TXT"),
           ("sx386", "C:\\WORK\\ONLY386.TXT"))]
    for t in ts:
        t.start()
    for t in ts:
        t.join(90)

    for box, want in (("v30", b"ONLYV30.TXT"), ("sx386", b"ONLY386.TXT")):
        rc, blob = got.get(box, (None, b""))
        print("   %-6s rc=%s  %d bytes  %r" % (box, rc, len(blob), blob[:60]))
        assert rc == 0, "%s pull failed" % box
        assert want in blob, (
            "%s got the WRONG FILE -- two concurrent pulls crossed. That "
            "is the single-slot bug this keying exists to stop." % box)
    print("   both pulls came back with their own bytes")

    print("\n### 7e. --box all runs on every machine and compares")
    r = cli("run", PROG, "--box", "all", "--timeout", "30",
            timeout=90, env=TWO)
    print(r.stdout.rstrip())
    assert r.returncode == 0, "fan-out reported a failure"
    assert "v30" in r.stdout and "sx386" in r.stdout, "fan-out lost a box"

    print("\nALL TESTS PASSED")
except BaseException:
    # Where to look. A failure here is nearly always something the daemon
    # or the simulated box said, and until now neither was readable at all:
    # their output went into a pipe nobody drained.
    print("\nchild logs:")
    for path in LOGS:
        print("  %s" % path)
    raise
finally:
    for p in procs:
        try:
            p.send_signal(signal.SIGTERM)
        except Exception:
            pass
    time.sleep(0.4)
    for p in procs:
        if p.poll() is None: p.kill()
