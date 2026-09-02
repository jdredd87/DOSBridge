#!/usr/bin/env python3
"""
simulate_dos.py - pretends to be the DOS machine so you can test dosd without hardware.

It polls /job exactly like AUTOEXEC.BAT does, does a crude interpretation of
the generated JOB.BAT (HTGET -> fetch, the program -> canned output, NC -> send
back), and reports results on port 8081. Run it alongside dosd.py.
"""
import re
import socket
import sys
import time
import urllib.request

SRV = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8080"
HOST = SRV.split(":")[0]
FAKE_STDOUT = "PicoMEM NE2000 probe\nIO=0x300 IRQ=3\nPackets RX=41 TX=39\nAll checks passed\n"
FAKE_RC = 0


def send_result(text):
    s = socket.create_connection((HOST, 8081), timeout=10)
    s.sendall(text.replace("\n", "\r\n").encode("cp437", "replace"))
    s.shutdown(socket.SHUT_WR)
    s.close()


def run_batch(bat):
    print("---- JOB.BAT ----\n%s----------------" % bat)
    job_id = None
    m = re.search(r"ECHO ##JOB=(\w+)", bat)
    if m:
        job_id = m.group(1)

    for line in bat.split("\r\n"):
        m = re.search(r"HTGET -o \S+ (http://\S+)", line)
        if m:
            url = m.group(1).replace("%SRV%", SRV)
            try:
                data = urllib.request.urlopen(url, timeout=10).read()
                print("   fetched %s (%d bytes)" % (url, len(data)))
            except Exception as e:
                print("   FETCH FAILED %s: %s" % (url, e))
                return

    if job_id:
        send_result("##JOB=%s\n%s##RC=%d\n" % (job_id, FAKE_STDOUT, FAKE_RC))
        print("   reported result for %s" % job_id)


def main():
    print("simulated DOS box polling %s" % SRV)
    while True:
        try:
            bat = urllib.request.urlopen(
                "http://%s/job" % SRV, timeout=60).read().decode("cp437")
        except Exception as e:
            print("poll failed: %s" % e)
            time.sleep(3)
            continue
        if "REM idle" in bat:
            continue
        run_batch(bat)


if __name__ == "__main__":
    main()
