"""Wait for a request typed at a DOS machine -- StevenC & Claude, 2026-10-13.

    python askwatch.py [--every SECS]

A DOS box's agent loop (AI.BAT) opens ASK.EXE when F10 is pressed and sends
what was typed to dosd as asks/<box>.txt; dosd keeps any upload it does not
route under files/, so it lands in files/asks/.  This waits for one, moves
it to asks/<date>-<time>-<box>.txt beside this file (out of the served
tree, and kept), prints it, and exits.

Run it in the background from a Claude Code session: the exit is what wakes
the session, which reads the request, does it, answers on the box's screen,
and starts this again.  Nothing here acts on a request by itself.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
INBOX = os.path.join(HERE, "files", "asks")
KEPT = os.path.join(HERE, "asks")


def main():
    every = float(sys.argv[sys.argv.index("--every") + 1]) if "--every" in sys.argv else 2.0
    os.makedirs(INBOX, exist_ok=True)
    os.makedirs(KEPT, exist_ok=True)
    while True:
        names = sorted(n for n in os.listdir(INBOX) if n.lower().endswith(".txt"))
        if names:
            name = names[0]
            src = os.path.join(INBOX, name)
            time.sleep(0.5)                     # dosd writes it whole, but be sure
            text = open(src, "rb").read().decode("cp437", "replace").replace("\r\n", "\n")
            dst = os.path.join(KEPT, time.strftime("%Y%m%d-%H%M%S-") + name)
            os.replace(src, dst)
            print("ASK from %s  (kept as %s)" % (name[:-4], os.path.relpath(dst, HERE)))
            print(text.rstrip("\n"))
            more = len(names) - 1
            if more:
                print("(%d more waiting)" % more)
            return 0
        time.sleep(every)


if __name__ == "__main__":
    sys.exit(main())
