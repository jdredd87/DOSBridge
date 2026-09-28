#!/usr/bin/env python3
"""
simulate_dos.py - pretends to be the DOS machine so you can test dosd without hardware.

It polls for work, does a crude interpretation of the generated JOB.BAT, and
sends the result back. Run it alongside dosd.py.

**It speaks the real transport.** The bridge moved off mTCP onto its own
IPv4/UDP stack, so a job poll, a file fetch and a result are all TFTP on UDP
8069 now (`starter/tftp.pas`, `UGET.EXE`, `UPUT.EXE`). This simulator therefore
does real TFTP -- RRQ/WRQ, block numbering, ACKs, and the RFC 2348 `blksize`
negotiation -- rather than pattern-matching the batch and fetching over HTTP.

That distinction is the whole value of the file. The previous version grepped
each batch for `HTGET -o <url>` and fetched over HTTP; when the transport
changed, the regex simply stopped matching, so every selftest run "passed"
while never transferring a single byte. It also meant the one bug that has
actually cost this project a day -- a block-size variable shadowed by a block
NUMBER, which truncated every transfer to 513 bytes -- could not have been
caught here, because nothing in the test ever crossed a 512-byte boundary on
the real code path. `selftest.py` now moves a file bigger than one block for
exactly that reason.

The HTTP path is still understood, so this also works against an older dosd.
"""
import os
import re
import socket
import struct
import sys
import time
import urllib.request

SRV = "127.0.0.1:8080"
BOXID = ""
LOCAL = ""
for _a in sys.argv[1:]:
    if _a.startswith("--box="):
        BOXID = _a.split("=", 1)[1].strip().lower()
    elif _a.startswith("--from="):
        LOCAL = _a.split("=", 1)[1].strip()
    elif not _a.startswith("-"):
        SRV = _a
HOST = SRV.split(":")[0]
TFTP_PORT = int(os.environ.get("DOSD_TFTP_PORT", "8069"))

# The resource name this box polls under. `--box=v30` makes it `job.v30`,
# which is exactly what AI.BAT does with SET BOXID= -- one daemon, one UDP
# port, identity in the NAME. Without it the name is the bare `job` every
# agent built before multi-box support sends, and dosd routes it on the
# source address instead.
#
# It matters that this is the same string the real agent puts on the wire.
# The previous version of this simulator pattern-matched the batch and
# fetched over HTTP, so when the transport moved it kept passing while
# transferring nothing at all. A simulator that models its own idea of the
# protocol is worth less than no simulator, because it is counted as
# evidence.
JOB_NAME = ("job." + BOXID) if BOXID else "job"


def udp():
    """A UDP socket, bound to this box's own source address if it has one.

    `--from=127.0.0.2` is how two simulated boxes get two ADDRESSES on one
    machine, and it is not cosmetic. Several pieces of dosd's transport
    state are keyed on the source IP -- the in-flight flow registry in
    particular, where a fresh request for a file already being sent to that
    address deliberately supersedes the older transfer, because that is how
    a stalled transfer recovers. Two boxes sharing 127.0.0.1 therefore
    cancel each other's fetches whenever they ask for the same file at the
    same moment, which is exactly what a fan-out does.

    Real machines have distinct addresses -- boxes.json refuses to register
    two at one address, precisely because it cannot be made to work -- so
    the loopback alias is what keeps the simulation honest rather than a
    limitation being papered over.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if LOCAL:
        s.bind((LOCAL, 0))
    return s

FAKE_STDOUT = ("network card probe\nIO=0x300 IRQ=3\n"
               "Packets RX=41 TX=39\nAll checks passed\n")
FAKE_RC = 0

# What the DOS box would have on disk. Keyed by the destination path a batch
# names, so a later UPUT of the same path can send back what was fetched --
# which is what makes a round-trip check meaningful.
DISK = {}

OP_RRQ, OP_WRQ, OP_DATA, OP_ACK, OP_ERROR, OP_OACK = 1, 2, 3, 4, 5, 6
BLK_DEFAULT = 512
BLK_WANT = 1400          # what UGET/UPUT ask for
WIN_WANT = 8             # what UGET asks for on a file fetch (windowsize)


def _rq(op, name, blk, win=0):
    """A read or write request, with the blksize and windowsize options when
    they are wanted."""
    pkt = struct.pack("!H", op) + name.encode("cp437") + b"\0octet\0"
    if blk:
        pkt += b"blksize\0" + str(blk).encode() + b"\0"
    if win > 1:
        pkt += b"windowsize\0" + str(win).encode() + b"\0"
    return pkt


def _opts(data):
    """The option pairs out of an OACK."""
    parts = data[2:].split(b"\0")
    return {parts[i].decode("cp437", "replace").lower():
            parts[i + 1].decode("cp437", "replace")
            for i in range(0, len(parts) - 1, 2) if parts[i]}


def tftp_get(name, blk_want=BLK_WANT, timeout=10, tries=5, win_want=WIN_WANT):
    """Fetch `name` from dosd over TFTP. Returns bytes, or None.

    Stop-and-wait, like the DOS client: one packet in flight, every block
    acknowledged before the next is sent. The server answers from an ephemeral
    port -- TFTP's transfer identifier -- so the reply address is locked onto
    after the first packet and 8069 is never written to again.
    """
    s = udp()
    s.settimeout(timeout)
    try:
        req = _rq(OP_RRQ, name, blk_want, win_want if blk_want else 0)
        s.sendto(req, (HOST, TFTP_PORT))

        blk = BLK_DEFAULT
        win = 1                  # blocks per window, once the OACK says
        inwin = 0                # in-order blocks since our last ACK
        dup_acked = gap_acked = False
        out = bytearray()
        want = 1
        peer = None
        left = tries

        while True:
            try:
                data, addr = s.recvfrom(65535)
            except socket.timeout:
                left -= 1
                if left <= 0:
                    return None
                # Re-ask. Before the first reply that means the request; after
                # it, the ACK for the last block we took.
                if peer is None:
                    s.sendto(req, (HOST, TFTP_PORT))
                else:
                    s.sendto(struct.pack("!HH", OP_ACK, (want - 1) & 0xFFFF),
                             peer)
                continue

            if peer is None:
                peer = addr
            elif addr != peer:
                continue
            left = tries

            op = struct.unpack("!H", data[:2])[0]
            if op == OP_ERROR:
                return None

            if op == OP_OACK:
                o = _opts(data)
                if o.get("blksize"):
                    blk = int(o["blksize"])
                if o.get("windowsize"):
                    win = int(o["windowsize"])
                inwin = 0
                # RFC 2347: ACK block 0 to start the transfer.
                s.sendto(struct.pack("!HH", OP_ACK, 0), peer)
                continue

            if op != OP_DATA:
                continue

            n = struct.unpack("!H", data[2:4])[0]
            payload = data[4:]
            # As TftpGet does it: where is this block relative to the one
            # we want (block numbers wrap at 65536)?
            diff = ((n - want + 0x8000) & 0xFFFF) - 0x8000
            if diff == 0:
                dup_acked = gap_acked = False
                out += payload
                inwin += 1
                last = len(payload) < blk
                # ACK the end of each window, or the last block
                if last or inwin >= win:
                    s.sendto(struct.pack("!HH", OP_ACK, n), peer)
                    inwin = 0
                want += 1
                if last:
                    return bytes(out)
            elif diff < 0:
                # A block we already have. Re-ACK the last we took and do NOT
                # write it again -- that is the classic way a stop-and-wait
                # transfer corrupts silently. Once per burst when windowed.
                if win <= 1 or not dup_acked:
                    s.sendto(struct.pack("!HH", OP_ACK, (want - 1) & 0xFFFF),
                             peer)
                    dup_acked = True
                    inwin = 0
            elif win > 1 and not gap_acked:
                # A block went missing inside the window: say where we are.
                s.sendto(struct.pack("!HH", OP_ACK, (want - 1) & 0xFFFF), peer)
                gap_acked = True
                inwin = 0
    finally:
        s.close()


def tftp_put(name, blob, blk_want=BLK_WANT, timeout=10, tries=5,
             win_want=WIN_WANT):
    """Send `blob` to dosd under `name`. Returns True on success.

    As UPUT does it: ask for windowsize, and if the server grants a window,
    send that many blocks and wait for the ACK saying how many arrived; go
    on from there (from the first one missing, if some did not); on
    silence send the window again.  Without a window, stop-and-wait.
    """
    s = udp()
    s.settimeout(timeout)
    try:
        req = _rq(OP_WRQ, name, blk_want, win_want if blk_want else 0)
        s.sendto(req, (HOST, TFTP_PORT))

        blk = BLK_DEFAULT
        win = 1
        peer = None
        left = tries

        # Wait for the go-ahead: ACK 0, or an OACK naming the options. The
        # OACK REPLACES ack 0 rather than joining it, and unlike a read the
        # client does not acknowledge it -- the first DATA block is the answer.
        while peer is None:
            try:
                data, addr = s.recvfrom(65535)
            except socket.timeout:
                left -= 1
                if left <= 0:
                    return False
                s.sendto(req, (HOST, TFTP_PORT))
                continue
            op = struct.unpack("!H", data[:2])[0]
            if op == OP_ERROR:
                return False
            if op == OP_OACK:
                o = _opts(data)
                if o.get("blksize"):
                    blk = int(o["blksize"])
                if o.get("windowsize"):
                    win = int(o["windowsize"])
                peer = addr
            elif op == OP_ACK and struct.unpack("!H", data[2:4])[0] == 0:
                peer = addr

        n = 1                    # the first block not yet acknowledged
        off = 0                  # its offset in the blob
        left = tries
        while True:
            # up to `win` blocks from there (one, stop-and-wait)
            sent, lens, final = 0, [], False
            pos = off
            while sent < win and not final:
                chunk = blob[pos:pos + blk]
                s.sendto(struct.pack("!HH", OP_DATA, (n + sent) & 0xFFFF)
                         + chunk, peer)
                pos += len(chunk)
                lens.append(len(chunk))
                sent += 1
                final = len(chunk) < blk
            moved = None
            while moved is None:
                try:
                    data, addr = s.recvfrom(65535)
                except socket.timeout:
                    break
                if addr != peer:
                    continue
                op = struct.unpack("!H", data[:2])[0]
                if op == OP_ERROR:
                    return False
                if op != OP_ACK:
                    continue
                d = ((struct.unpack("!H", data[2:4])[0] - (n - 1) + 0x8000)
                     & 0xFFFF) - 0x8000
                if 0 <= d <= sent:
                    moved = d    # anything else is a stale ACK
            if moved is None:
                left -= 1
                if left <= 0:
                    return False
                continue         # silence: the window again
            left = tries
            off += sum(lens[:moved])
            n += moved
            if moved == sent and final:
                return True
    finally:
        s.close()


def send_result_tcp(text):
    """The legacy result path, kept so this still drives an older dosd."""
    s = socket.create_connection((HOST, 8081), timeout=10,
                                 source_address=(LOCAL, 0) if LOCAL else None)
    s.sendall(text.replace("\n", "\r\n").encode("cp437", "replace"))
    s.shutdown(socket.SHUT_WR)
    s.close()


def say(msg):
    """Prefixed with the box id, because two simulated boxes share one
    console and an interleaved log with nothing saying which machine each
    line came from is the text version of the bug this all guards against."""
    print(("[%s] " % BOXID if BOXID else "") + msg, flush=True)


def run_batch(bat):
    say("---- JOB.BAT ----\n%s----------------" % bat)
    m = re.search(r"ECHO ##JOB=(\w+)", bat)
    job_id = m.group(1) if m else None
    reported = False

    for line in bat.split("\r\n"):
        # --- fetch: UGET, or HTGET against an older dosd ------------------
        m = re.search(r"UGET\.EXE\s+\S+\s+(\S+)\s+(\S+)", line, re.I)
        if m:
            name, dest = m.group(1), m.group(2)
            data = tftp_get(name)
            if data is None:
                say("   FETCH FAILED %s" % name)
                return
            DISK[dest.upper()] = data
            say("   fetched %s -> %s (%d bytes)" % (name, dest, len(data)))
            continue

        m = re.search(r"HTGET -o (\S+) (http://\S+)", line)
        if m:
            dest, url = m.group(1), m.group(2).replace("%SRV%", SRV)
            try:
                data = urllib.request.urlopen(url, timeout=10).read()
            except Exception as e:
                say("   FETCH FAILED %s: %s" % (url, e))
                return
            DISK[dest.upper()] = data
            say("   fetched %s (%d bytes)" % (url, len(data)))
            continue

        # --- send: UPUT ---------------------------------------------------
        m = re.search(r"UPUT\.EXE\s+\S+\s+(\S+)\s+(\S+)", line, re.I)
        if m:
            src, name = m.group(1), m.group(2)
            if name.lower() == "result":
                # Only ever once. A batch carries several result-sending
                # lines, guarded by IF/GOTO for the success and failure
                # paths, and this loop walks every line rather than modelling
                # COMMAND.COM's control flow -- so without this the same
                # result is delivered two or three times.
                if job_id and not reported:
                    body = ("##JOB=%s\n%s##RC=%d\n"
                            % (job_id, FAKE_STDOUT, FAKE_RC))
                    ok = tftp_put("result", body.replace("\n", "\r\n")
                                  .encode("cp437", "replace"))
                    say("   reported result for %s%s"
                        % (job_id, "" if ok else "  (FAILED)"))
                    reported = reported or ok
            else:
                # A pull: hand back whatever that path holds. Falling back to
                # a generated body keeps the shape right for a file this
                # simulator never fetched.
                blob = DISK.get(src.upper(),
                                b"simulated contents of " +
                                src.encode("cp437", "replace") + b"\r\n")
                ok = tftp_put(name, blob)
                say("   sent %s as %s (%d bytes)%s"
                    % (src, name, len(blob), "" if ok else "  (FAILED)"))
            continue

    if job_id and not reported:
        # Nothing in the batch shipped a result -- an older dosd, or a batch
        # shape this does not model. Use the legacy port so the job still
        # completes instead of timing out.
        try:
            send_result_tcp("##JOB=%s\n%s##RC=%d\n"
                            % (job_id, FAKE_STDOUT, FAKE_RC))
            say("   reported result for %s (legacy 8081)" % job_id)
        except Exception as e:
            say("   result FAILED for %s: %s" % (job_id, e))


def poll():
    """One job poll. TFTP first, HTTP if that is not answering."""
    bat = tftp_get(JOB_NAME, blk_want=0, timeout=20, tries=1)
    if bat is not None:
        return bat.decode("cp437")
    return urllib.request.urlopen(
        "http://%s/job" % SRV, timeout=60).read().decode("cp437")


def main():
    print("simulated DOS box%s polling %s as %r  (TFTP udp/%d)"
          % (" " + BOXID if BOXID else "", SRV, JOB_NAME, TFTP_PORT))
    while True:
        try:
            bat = poll()
        except Exception as e:
            say("poll failed: %s" % e)
            time.sleep(3)
            continue
        if bat is None or "REM idle" in bat:
            continue
        run_batch(bat)


if __name__ == "__main__":
    main()
