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
    """Is something already listening on this port?"""
    s = socket.socket()
    s.settimeout(0.5)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


# This test starts its OWN dosd and its own simulated DOS box. A dosd already
# running takes port 8080, the copy spawned here cannot bind, and the symptom
# is a 25 second timeout and an assertion failure that says nothing about the
# real cause. Better to say so up front.
for _p in (8080, 8081, 8082):
    if port_busy(_p):
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

    PROG = os.path.join(tempfile.gettempdir(), "PROG.EXE")
    open(PROG, "w").write("MZ fake\n")

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

    print("\n### 4. inspect a generated driver JOB.BAT")
    sys.path.insert(0, HERE)
    import dosd
    for ln in dosd.build_driver_batch("abc12345", "NEWDRV.SYS", "/i:3", True):
        print("   " + ln)

    print("\n### 5. errorlevel ladder length: %d lines" % len(dosd.errorlevel_capture()))
    print("\nALL TESTS PASSED")
finally:
    for p in procs:
        p.send_signal(signal.SIGTERM)
    time.sleep(0.4)
    for p in procs:
        if p.poll() is None: p.kill()
