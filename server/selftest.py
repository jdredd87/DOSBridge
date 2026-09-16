#!/usr/bin/env python3
"""Exercise the whole loop: dosd + a simulated DOS box + dosctl."""
import subprocess, sys, time, os, signal, tempfile, socket

HERE = os.path.dirname(os.path.abspath(__file__))
procs = []

def spawn(name, *args):
    p = subprocess.Popen([sys.executable, os.path.join(HERE, name)] + list(args),
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    procs.append(p)
    return p

def cli(*args, timeout=60):
    r = subprocess.run([sys.executable, os.path.join(HERE, "dosctl.py")] + list(args),
                       capture_output=True, text=True, timeout=timeout)
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
    print("\nALL TESTS PASSED")
finally:
    for p in procs:
        p.send_signal(signal.SIGTERM)
    time.sleep(0.4)
    for p in procs:
        if p.poll() is None: p.kill()
