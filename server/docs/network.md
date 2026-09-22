# Networking: the packet driver, our own UDP, and TFTP

How the bridge stopped needing mTCP, and everything the transport has
been caught doing since.

Split out of `CLAUDE.md`, which keeps the summary and the pointer here.

## Writing network tools in Pascal

FPC has **no TCP/IP stack for `-Tmsdos`** -- no `Sockets` unit, no resolver,
nothing. Two routes exist and they differ enormously in ambition:

**Shell out to mTCP.** `C:\NETWORK\MTCP` holds `PING`, `NC`, `HTGET`, `SNTP`,
`DNSTEST`, `FTP`, `TELNET`, `SPDTEST`, `PKTTOOL` and more. Drive them with
`dosexec` and read their output. Nothing to build, but you get only what they
already do.

**Talk to the packet driver.** This is the layer mTCP itself sits on: a small,
documented interrupt API published by a resident driver on one vector in
60h..80h. `starter/pktdrv.pas` is the entry point. It finds the driver by the
`PKT DRVR` signature the spec places at offset 3 of the handler, then calls
`driver_info` (AH=1Fh). On this box:

```
INT 60h  name NE2000, spec 11, class 1 (DIX Ethernet), type 54, funcs 2
```

Note the name. `AUTOEXEC.BAT` loads `C:\drivers\pm2000.com`, but PicoMEM's
driver presents an NE2000-compatible interface and reports itself as `NE2000`.
Both statements are true: the file is not the name.

Calling a vector known only at run time needs a trick, because the `INT` opcode
takes an immediate operand. `pktdrv.pas` reads the vector out of the table and
does `PUSHF` followed by a far `CALL`, which leaves the stack exactly as `INT`
would and unwinds correctly on the driver's `IRET`. The fiddly part is that the
call returns with `DS` pointing at the *driver's* segment, so until `DS` is put
back every global in the program is unreachable and storing a result would
write into the driver. Move what you need into registers first, restore `DS`,
then store -- `MOV` does not touch the flags, so the carry the driver returned
is still valid when you test it.

## Capturing frames: `PKTCAP`

`starter/pktcap.pas` is the next step up and the only program here that calls
`access_type` (AH=02h).

**Give it the third argument on a bridge machine.** `PKTCAP 10 ALL 65`
captures from the driver at INT 65h; without it, it attaches to the first
packet driver between 60h and 80h — which here is the network the bridge
itself runs over. With `ALL`, frames it captures are frames nobody else
gets, so an unqualified capture can quietly starve the link you are working
over. Naming a second driver makes it harmless: it steals only from the card
being debugged. Same rule as everything else that reaches for a packet
driver — name the vector, never take the first one you find. Verified on hardware 2026-08-31 -- eight seconds of ARP
gave six frames, zero dropped, and the bridge was unaffected:

```
    destination  : FF:FF:FF:FF:FF:FF        (broadcast)
    source       : AA:BB:CC:11:22:33
    ethertype    : 0806  (ARP)
      0000  FF FF FF FF FF FF AA BB CC 11 22 33 08 06 00 01
      0010  08 00 06 04 00 01 AA BB CC 11 22 33 C0 A8 01 28
      0020  00 00 00 00 00 00 C0 A8 01 D3 ...
```

which decodes as 192.168.1.40 asking who has 192.168.1.211.

Three things in it are load-bearing:

* **`access_type` hands the driver a far pointer to your code**, which it then
  calls at interrupt time for every matching frame. Exit without
  `release_type` (AH=03h) and that pointer dangles into memory DOS has since
  reused -- the next matching frame jumps into it. That is a box with no
  network, and the bridge runs over that network, so recovery needs hands on
  the keyboard. Everything between acquire and release is straight-line code
  with **no DOS calls and no WriteLn**; nothing is printed until the handle is
  back.
* **A frame delivered to your handle is not delivered to mTCP's.** `ALL` takes
  every frame away from the stack this bridge uses, so it is opt-in and the
  default is ARP -- broadcast, frequent, and not something an established
  connection depends on moment to moment.
* **The receiver runs at interrupt time with `DS` belonging to the driver**, so
  none of the program's data is reachable until `DS` is replaced. The first
  fourteen bytes of `PktRecv` are hand-written `db`/`dw` precisely so the two
  words needing run-time patching sit at known offsets `+7` (data segment) and
  `+12` (`Ofs(Shared)`). Let the assembler choose the encoding and those
  offsets stop being knowable from Pascal. **If you edit that prologue, re-check
  the offsets against the linked binary before running it** -- a wrong patch
  corrupts an interrupt-time routine, which fails at the worst possible moment.

The driver calls the receiver twice per frame: `AX=0` asks for a buffer of
`CX` bytes (return `ES:DI`, or `0:0` to drop it), `AX=1` says it has been
copied in. A `Busy` flag makes the second call's buffer safe to read from the
main loop: while it is set the handler returns `0:0` and counts a drop rather
than overwriting a frame being read.

## Transmitting: `ARP`

`starter/arp.pas` sends as well as receives, and the striking thing is how much
easier sending is. `send_pkt` (AH=04h) takes `DS:SI` and `CX` and nothing
else -- no handle, no callback, no interrupt-time code, nothing to release. All
the care in `pktcap.pas` is about the receive path; the transmit half here is a
dozen lines.

ARP was the right first thing to send: complete in 42 bytes, no IP stack
needed, and a reply proves both directions of the driver at once. Verified on
hardware 2026-08-31:

```
ARP 192.168.1.1        ->  192.168.1.1   AA:BB:CC:44:55:66
ARP -scan 192.168.1    ->  every host that answered, MAC for each
```

`get_address` (AH=06h) is in there too -- it needs the handle, so it lives
between Acquire and Release. On a PicoMEM the address it returns carries a
Raspberry Pi OUI (`28:CD:C1`), because what answers is the card's own WiFi
radio rather than anything NE2000-shaped.

**A bug worth keeping as a warning.** The first version guessed our own sender
address as `.0` of the target's range and got *no replies at all*. The packet
driver has no idea what our IP is -- addresses are a concept one layer up -- so
it has to come from somewhere, and `.0` is a network address that well-behaved
hosts are right to ignore. `arp.pas` now reads `IPADDR` from the file
`%MTCPCFG%` points at, the same place every mTCP tool looks, with `-ip` to
override. If a tool here ever transmits and hears nothing back, suspect the
sender address before suspecting the wire.

## IPv4 and UDP without mTCP: the `Net` unit

`starter/net.pas` is IPv4 and UDP on top of the packet driver, and it is step
one of getting rid of the mTCP dependency entirely. **Verified on hardware
2026-09-02** against Cloudflare's anycast NTP server, which is off-subnet, so
the gateway path was exercised too:

```
  packet driver  : INT 60h
  our address    : 192.168.1.20  28:CD:C1:00:11:22
  server         : 162.159.200.1  via gateway 192.168.1.1 at AA:BB:CC:44:55:66
  leap / mode    : LI=0  mode=4  stratum=3
  server says    : 2026-09-02 04:59:58  UTC
```

```pascal
uses Net;

NetReadConfig;              { IPADDR / NETMASK / GATEWAY out of %MTCPCFG% }
NetOpen(PeerIP);            { find driver, ARP the peer or the gateway }
NetUdpSend(SrcPort, DstPort, Buf, Len);
NetUdpRecv(Port, Buf, Max, Got, TimeoutTicks);
NetClose;                   { MANDATORY -- see below }
```

### Driving a SECOND interface: three optional overrides

Added 2026-09-10 for CH375Net, which needed to test a USB Ethernet adapter
on vector 65h while the bridge carried on over the NE2000 at 60h. All three
default to exactly the old behaviour, so nothing that does not set them can
be affected -- but note the BINARIES are not identical: the two globals and
their tests make `UGET` 138 bytes bigger, CRC `04A4A6DA` becoming
`2F7FA149`. That was checked by building both ways from git rather than
assumed, and `starter/build/UGET.EXE` was put back to the original so
`dosctl verify` still agrees with what is deployed.

```pascal
NetVecWant : Byte;          { 0 = scan 60h..80h and take the first }
NetCfgWant : ShortString;   { '' = NET_CFG then %MTCPCFG% }
NetRxBcast : Boolean;       { False = accept only our own address }
```

**`NetVecWant` exists because "the first packet driver" is the wrong one on
a two-interface box.** The scan takes whatever answers lowest, which here is
always the network the machine is administered over -- so a tool meaning to
test a second adapter would quietly test the first and come back
reassuringly clean.

**`NetCfgWant` follows from it:** a second interface needs its own address,
and `NET_CFG` names the first. Get this wrong and the failure is
misdirecting rather than obvious -- `NetMyIP` falls back to the bridge's
address, the peer's reply is sent to the *other* adapter's MAC, and the
symptom is "no reply" with nothing to suggest the cause was local.

**`NetRxBcast` is not a convenience, it is the only way a long-running
listener can be reached at all.** Nothing on this box answers ARP while the
Net unit holds only the 0800 handle -- the 0806 handle is released as soon as
`NetOpen`'s ARP phase finishes -- so a peer's cache entry for us expires
after a couple of minutes and it silently stops delivering unicast.
Measured: **9 datagrams arrived in fifteen minutes out of roughly forty
thousand sent.** `KNET` hit the identical wall from the other direction and
its section above records the identical fix.

The cost of broadcast is real and bit hard. It reaches every host on the
segment, and on this machine that includes the PicoMEM WiFi interface the
bridge itself runs over: a test blasting 55 KB/s to the broadcast address
starved the agent's own ARP, took it offline, and cost a fifteen-minute
window's result. 16 KB/s is the rate that has proved reliable. A static ARP
entry on the sending side avoids the whole problem and allows unicast at
full rate, but needs elevation.

`CH375Net/src/usbget.pas` and `usbvfy.pas` are the worked examples. Both
refuse vector 60h in code: taking an IP handle on the bridge's own network
is how the box is lost with no way in to undo it.

**A real server is the only worthwhile test.** An echo bounced off our own
daemon would pass even if both ends agreed on the same mistake; an NTP server
validates the UDP checksum, validates the addresses, and answers in a format we
did not invent. `NTP.EXE` and mTCP's `SNTP` were pointed at the same server
seventeen seconds apart and agreed **to the second** -- two independent stacks,
which is the check that means something.

Four things in it are load-bearing:

* **`NetClose` on every exit path, including the error ones.** Same rule as
  `pktcap`: the driver holds a far pointer to our receiver, and exiting without
  releasing leaves it dangling into memory DOS reuses. The next matching frame
  jumps into it, and the bridge runs over that network.
* **Two handles are never held at once.** The spec lets a driver refuse a
  second `access_type` for a type already in use, so the ARP phase opens 0806,
  finishes, releases, and only then does the IP phase open 0800. Sequential,
  never concurrent -- which is also why this can coexist with mTCP at all.
* **The checksum accumulator is 16-bit with an end-around carry**, not a 32-bit
  sum. `BENCH` puts 32-bit arithmetic at 5-8x its 16-bit equivalent, and a
  checksum is the one thing every packet pays for.
* **Fragments are dropped, not reassembled.** Nothing the bridge sends needs
  fragmenting, and a wrong reassembly is worse than a retry.

Note `NTP.EXE` takes an address, not a name -- there is no DNS here. That is not
worth fixing for the bridge, which only ever talks to one host by IP. It also
means the default (the configured `GATEWAY`) often does not answer: this router
does not serve NTP, and mTCP's `SNTP` times out against it in exactly the same
way, which is how we established our stack was not the problem.

## Moving off mTCP: TFTP over our own UDP

**Done and running on hardware 2026-09-02.** The job poll, every file fetch
and every result now go over our own stack by default, with mTCP kept as the
fallback on each one.

| | |
|---|---|
| `starter/tftp.pas` | TFTP client, both directions, on top of `Net` |
| `starter/uget.pas` | `UGET` -- fetch. Replaces `HTGET` |
| `starter/uput.pas` | `UPUT` -- send. Replaces `NC` |
| `dosd.py` | TFTP server on **UDP 8069**, plus the `job` resource |

TFTP rather than a reimplementation of HTTP, because "our own HTGET and NC"
means writing TCP -- HTTP runs on TCP and `NC` is a TCP client -- and TCP's
failure mode is the one that cannot be tolerated here: correct on the bench,
silently corrupting under loss, in the component whose failure needs hands on
the keyboard. TFTP is four opcodes and one packet in flight, and every failure
it can have is a visible timeout.

Verified byte-exact in both directions by CRC-32, which is the check that
means something -- `HD` on the box and `zlib.crc32` on Windows agree:

```
files/starter/HELLO.EXE   26118 bytes  CRC-32 A78BF602      (Windows)
C:\WORK\UT.EXE            26118 bytes  crc32  A78BF602      (after UGET)
files/local/UPTEST.BIN    26118 bytes  CRC-32 A78BF602      (after UPUT back)
```

**Everything falls back.** Each transfer tries UDP and drops to `HTGET`/`NC`
if the tool is missing or the transfer fails, so a bug degrades into a slower
job instead of a silent box, and both routes stay exercised. The two never
collide: they are separate programs, so they never hold a packet driver handle
at the same moment.

Four things that are load-bearing:

* **Stop-and-wait makes the disk safe.** Writing to a file while a packet
  handle is open would normally race the receiver, which drops anything
  arriving while its buffer is busy. With stop-and-wait the server does not
  send block N+1 until it has our ACK for N, so nothing is on the wire while
  we are in DOS. Do not "optimise" this into a windowed transfer.
* **A duplicate DATA block must be re-ACKed and NOT written.** That is the
  classic way a stop-and-wait transfer corrupts silently.
* **The server answers from a new port.** TFTP's transfer identifier is an
  ephemeral port, not the well-known one, so `Net` reports `NetFromPort` and
  the client locks onto it. Keep replying to 8069 and a correct server ignores
  you -- which looks exactly like a server that is not running.
* **The job poll never retransmits its request.** dosd holds a job request
  open for `POLL_HOLD_SECS` -- 2 seconds since 2026-09-02, 8 before that; a
  retransmit would read as a second poll and take a second job off the queue.
  `UGET ... POLL` therefore makes one attempt and gives up. It used to fall
  through to `HTGET`; there is no fallback now, so it just waits for the next
  cycle. dosd deduplicates a repeat request from an address it is already
  holding one for, which is the other half of making that safe.

**The cost of that rule, measured:** file transfers never fail (208 blocks,
zero resends) because a lost request is simply resent, while the job poll
fails outright on a lost request -- observed at roughly one poll in five on
this WiFi link, each costing 11 seconds before the fallback. Correct, but not
free. Making the poll reliable enough to drop `HTGET` altogether needs
at-least-once delivery: requeue on failed dispatch (**done** -- a job whose
UDP delivery fails is put back rather than lost), plus client retransmit with
server-side deduplication so a resent request joins the existing wait instead
of starting a second one.

`UGET` and `UPUT` deliberately do **not** `uses About`. The loop runs them
every poll, and About prints from its unit initialisation -- linking it
repainted the attribution banner on the console every eight seconds, which is
the papercut this whole exercise was meant to remove. Same reasoning as
`KEYHIT.COM` being hand-assembled. They are also silent on success (`-V` for
the numbers), so the boot banner now survives instead of scrolling away.

## What is still left

**mTCP is gone. Not reduced -- gone.** The job poll, every file fetch, every
result and the binary pull all run on our own UDP, and on 2026-09-02 the last
`HTGET` line came out of `AI.BAT` too. Nothing the bridge does touches
`C:\NETWORK\MTCP`; what is left there is diagnosis you may or may not have.

The **packet driver is still required** and is a different thing -- it is the
driver for the network card, not part of mTCP.

`SET SRV=` stays in `AI.BAT` even though nothing on the box reads it now. It is
half of the address check `dosctl upgrade --agent` runs, which is what stops an
upgrade installing an agent pointed somewhere the machine cannot reach.

**The pull was the last one, and the least obvious.** Two things forced it out
beyond the dependency itself. `NC` printed a **thirteen-line version banner
straight to the console** on every pull -- `> NUL` was already on the line and
made no difference, because COMMAND.COM 6.22 has no stderr redirection at all,
so it could not be silenced from a batch at all. And `-bin` was load-bearing
with nothing on the wire enforcing it: without it `NC` opened stdin in text
mode and silently ate every 0x0D and 0x1A, so a 27298-byte `SYSINFO.EXE`
arrived as 27258 -- corrupt but entirely plausible-looking. TFTP is a block
protocol with a byte count, so there is no text mode to get wrong and nothing
to opt out of.

Verified byte-exact on hardware 2026-09-02: `C:\TOOLS\SYSINFO.EXE` pulled
over the new path, 28928 bytes, CRC-32 `EB1ABFF1` matching the Windows copy.
The bytes arrive under the reserved TFTP name `pull` and land in the same sink
the NC port used, so `dosctl pull` did not change. The TCP listener on 8082 is
kept anyway -- it costs one idle socket and is the only way bytes could still
arrive from a box running a batch generated by an older `dosd`.

Every transfer is verifiable end to end, which is what made all of this safe to
attempt: `HD`'s CRC-32 matches Python's `zlib.crc32`, so silent corruption is
detectable from either side.

### The number that made dropping `HTGET` safe

The fallback was kept because roughly one poll in five got no reply, and that
was the right call at the time -- but the figure was the wrong thing to look
at. Measured properly on 2026-09-02 by logging `dosd` to a file and counting:

```
24 job polls served, 4 with no ACK  (17%)
[12:06:22]    idle batch -> 192.168.1.20:22358  NO ACK
[12:07:40]    idle batch -> 192.168.1.20:23928  NO ACK
[12:08:35]    idle batch -> 192.168.1.20:20831  NO ACK
[12:09:30]    idle batch -> 192.168.1.20:21829  NO ACK
```

**Every single failure is an `idle batch` -- the "nothing for you" reply. Not
one job dispatch was ever lost.** That is what makes the fallback dispensable:
losing an idle reply costs the box one wasted cycle (UGET gives up, the offline
branch waits 5 seconds, it polls again) and nothing else. A job queued in that
window is picked up on the next poll, and `dosd` already requeues a dispatch
that goes unacked.

The honest cost of removing it: in the polls that miss, a job arriving just
then waits up to about 16 extra seconds, because `HTGET` used to pick it up
over TCP the moment UDP failed. Latency, not loss -- and the miss rate went
from 17% to 2.2% the same day, once the poll hold below was fixed, so the
expected cost of having dropped the fallback is now about an eighth of what it
looked like at the time.

**The mechanism, finally observed rather than inferred.** Watching this host's
ARP table while the box polled:

```
12:10:48    192.168.1.20   28-cd-c1-00-11-22  dynamic
12:10:56    192.168.1.20   28-cd-c1-00-11-22  dynamic
12:11:04  (no entry for .66)
12:11:12    192.168.1.20   28-cd-c1-00-11-22  dynamic
```

The entry **comes and goes**. Each poll's ARP exchange refreshes it and it
lapses in between, and **nothing on the box ever answers an ARP request** -- by
the time the IP phase is running, `Net` has released the 0806 handle and holds
only 0800, so it does not even see the query. Any reply `dosd` has to send
during a gap is therefore undeliverable.

That also explains why only idle replies suffer: a job dispatch goes out
promptly, while the entry is still fresh from the poll's own ARP, whereas an
idle reply waits out the server's hold first.

Shortening the hold to 2 seconds fixed this, and **answering ARP would add
nothing to it** -- see below, where that idea was built, tested and thrown
away.

## Large transfers: fixed, and what it took

**Multi-megabyte transfers work and are byte-exact.** Verified on hardware
2026-09-02, CRC-32 checked on the box against `zlib.crc32` on Windows:

| | blocks | resends | time | CRC-32 |
|---|---|---|---|---|
| 300 KB | 601 | 1-7 | ~25s | `1FF2AF8D` |
| 1 MB | 2049 | 11 | ~90s | `1DA381B3` |
| **5 MB** | **10241** | **53** | **7m 39s** | `07E75E7F` |

About 11.4 KB/s. The same 300 KB file failed **6 times out of 6** before this
work, and the 30-47 KB tool deploys failed about 11% of the time.

### Two real bugs: the same mistake in both directions

Both ends treated an unexpected packet as a reason to keep waiting, when a
**duplicate ACK is information**: it means the packet you last sent is gone.

* `dosd.py`, serving a download: on any non-matching packet it went back to
  `recvfrom` with a **fresh 2-second timeout**. A client that has timed out
  re-ACKs the previous block every 2 seconds, and each of those reset the
  server's timer -- so the server never retransmitted the lost block while
  the client sat waiting for it. **A deadlock, from one lost packet.**
* `starter/tftp.pas`, sending an upload: identical, mirrored. A stale ACK did
  `Inc(TftpDups)` and looped. It had never been hit because a result is only
  a block or two -- it would have broken the first large `dospull` anyone
  tried.

Both now retransmit immediately on a duplicate ACK.

**One lost packet was enough**, which is why it looked size-dependent: 68-block
transfers nearly always got through untouched, 600-block ones never did.

### A third bug: every transfer truncated to 513 bytes

Introduced on 2026-09-02 by the `blksize` work and found the same evening,
after it had stranded the box and cost hours of blaming the hardware. The
whole thing is one shadowed name in `tftp_send_blob`:

```python
def tftp_send_blob(sock, addr, blob, retries=None, blk=None):
    blk = TFTP_BLK                              # blk is the block SIZE
    chunk = blob[off:off + blk]
    op, blk = struct.unpack("!HH", data[:4])    # ...now the block NUMBER
    if len(chunk) < blk:                        # ...compared against a number
```

The first ACK rewrites the block size to 1. So every transfer sent 512 bytes,
then a **single byte**, which the client correctly read as a short final block
and treated as a complete file. **513 bytes, and both ends believed it.**

What makes it worth recording is how convincingly it framed the DOS box:

* **A job batch ran.** 513 bytes is the head line and the first command or
  two; the `RES.TXT` write and the closing `UPUT` live at the end of the
  batch and were simply not in the file. So the program ran, nothing ever
  reported, and the agent loop carried on polling -- which reads exactly like
  a broken result path.
* **Every idle poll logged `NO ACK`.** The idle batch is under 512 bytes, so
  the client got it whole and stopped; the server marched on to a phantom
  block 2 and retransmitted to nobody for ten seconds. 100% failures on a
  link that was completely healthy.
* **A deploy of `UGET.EXE` wrote a 513-byte file over it.** With no mTCP
  fallback left, that stranded the machine and needed hands on the keyboard.

Three separate symptoms, all pointing at the box, none of them its fault. The
hours went into ARP, packet driver handles, firewall rules and CRCs on tools
that turned out to be fine, because **the daemon's log lived only in its
console window** and nobody reading it could see that `acked` had become
`NO ACK` on every line. That is why `log()` now mirrors to `dosd.log`.

The lesson that generalises: a transfer protocol whose length check and whose
sequence check share a variable can agree with itself perfectly and still be
wrong. Both ends here were internally consistent -- the client's "short block
means done" is correct TFTP -- so nothing detected it. Only comparing the
delivered byte count against the source did, which is what the CRC-32 check on
deploys now does automatically.

## One box loses RESULTS, and it is the size of the output that predicts it

**Found 2026-09-21, upgrading the tools on both machines.** The V30 took all
33 files inside one foreground window with no retries. The 386SX lost 7 of
33, and then kept failing in a way that read as a dead box and was not.

What is actually failing is the **result coming back**, not the file going
out. The signature is unambiguous once you look for it:

* Every deploy job reported `rc=0`. Files arrived, often via a resume --
  `resuming starter/BENCH.EXE at byte 12600` -- and the transfers completed.
* `dosctl verify` came back **empty**, and empty is indistinguishable from
  "no `HD.EXE` on the box", which is what it printed. `HD.EXE` was there, at
  exactly the right size, and ran correctly when asked directly.
* A one-command `DIR C:\TOOLS` timed out after 300 seconds while the box was
  polling every three seconds throughout.

The measurement that settles it: check the tools in **chunks** and the
answers come back all-or-nothing per job -- `5/5 answered` or `0/5`, never
partial. Individual lines are not being dropped; whole result uploads are.
A `verify` of 41 tools is one job whose result is 40-odd lines, and it is the
largest payload the bridge ever asks a box to send.

So on a box like this:

| | |
|---|---|
| one file per deploy job | 11 of 11 sent, every one first attempt |
| CRC check 5 files per job | two chunks of five lost, nothing wrong |
| CRC check 2 files per job | 10 of 10 answered |

Final state was 41 of 41 byte-identical on both machines, zero mismatches --
reached by making the jobs smaller, not by retrying the big ones.

**Two traps worth carrying forward.** First, `dosctl upgrade --tools` decides
what to send by comparing SIZE from a `DIR` listing, so a file that arrived
corrupt at exactly the right length is invisible to it and never re-sent.
Three of the five genuine mismatches here would have survived another full
pass untouched. Working from a CRC list instead is what caught them -- the
same argument the post-deploy CRC check is built on, applied to deciding what
to send rather than confirming what was sent. Second, **`verify`'s
all-in-one-job design fails silently in the direction of reporting a healthy
toolset as a missing tool.** It should chunk on every box, not just this one.

**The cause is RF, and it is not subtle once you know where the machines
are.** The 386SX is DOWNSTAIRS; the V30 sits beside the router. That is the
whole of it -- weaker signal, more loss, and the loss lands hardest on the
largest thing the box ever has to send, which is a job's result.

Recorded because the wrong answer was already written here and had to be
taken out. The two boxes differ in several ways at once -- CPU, PicoMEM card
model, card firmware date -- and with the machines' locations unstated it was
the card that looked causal: the slow box had the older card on the older
firmware, which is a tidy story and was wrong. The measurements above were
all correct; the explanation bolted onto them was invented. Nobody needed to
swap a card or flash anything, and a session was one step from recommending
both.

**So: ask where the machines physically are before attributing a link
difference to what is plugged into them.** Same lesson as running mTCP as a
control, and as reading the neighbour state rather than `arp -a` -- the
instrument, or in this case the inventory, has to be able to express the
answer before a null result means anything.

What survives, and is the useful part: **on a box with a weak link, make the
JOBS smaller rather than retrying the big ones.** One file per deploy, a
handful of checksums per verify. That is the correct mitigation for signal
loss and needs no hardware changed. If the 386SX is ever moved nearer the
AP, or put on a better antenna, expect these symptoms to disappear -- and if
they do not, then the card is worth looking at.

## The Windows firewall, 2026-09-21: the fault that is not on the wire

Before suspecting anything in this file, check that the polls are arriving at
all. On 2026-09-21 **both** DOS machines went silent at once and stayed
silent through a reboot, a power cycle and a daemon restart, and neither was
broken. This PC's LAN interface is on the **Private** profile; the only
inbound Allow rules for `python.exe` were scoped to **Public**; the default
inbound action is block. Every poll was dropped before `dosd` could see it,
while `netstat` showed the daemon bound to `0.0.0.0:8069` the whole time and
both boxes' screens showed a healthy agent banner. `dosfirewall.cmd` adds
port-scoped rules for UDP 8069 and TCP 8080-8082, limited to the boxes'
subnet.

**The instrument matters here as much as it did for the stall below.** `ping`
proves nothing -- nothing on the DOS side answers ICMP unless mTCP is
loaded. Sending a UDP datagram to the box forces this host to ARP for it, and
then:

```
netsh interface ipv4 show neighbors "Ethernet"
```

`Reachable` means the box's own stack answered the ARP, so the machine is
running and transmitting; the fault is that we are not listening. That is a
different question from "is it hung", and it is the one worth asking first
when nothing is arriving. Note `arp -a` cannot express it -- it prints a
`dynamic` entry for an address whose neighbour state is `Unreachable`, which
is exactly how the right hypothesis was discarded for months below.

And the structural lesson, which is the ARP one arriving from the other
direction: **two independent machines failing identically at the same moment
points at what they share.** mTCP was the independent control that proved the
fault was ours; a second DOS box is an independent control that proves the
fault is not the box's.

## THE STALL: solved on 2026-09-12. It was ARP all along

Everything in the three sections below was written while this was unexplained,
and they are kept because the workaround they describe is still in the code and
still earns its place. But the cause is no longer a mystery, and the summary is
short: **the DOS box never answered ARP, so the peer's neighbour entry for it
expired mid-transfer and the peer stopped sending.** Not the card, not the
driver, not the link, not the wire. The packets were never transmitted at all.

### What settles it

Three independent measurements, none of which existed before:

**1. A control on a different transport.** mTCP's `HTGET` over TCP, same box,
same card, same packet driver, same AP, against a plain HTTP server on this
machine:

| | time | rate | result |
|---|---|---|---|
| 1 MB | 14.8 s | 70.9 KB/s | byte-exact |
| 5 MB | 62.5 s | 83.9 KB/s | byte-exact |
| 10 MB | 125.7 s | 83.4 KB/s | byte-exact |

16 MB with no stall, no restart, nothing. Our own stack managed 12 KB/s on the
same link and could not finish 5 MB. A link fault that spares one program
entirely and cripples another is not a link fault. **mTCP answers ARP.**

**2. The peer's neighbour table, watched during a transfer.** `arp -a` cannot
answer this, and that is why the question stayed open for weeks: it prints a
`dynamic` entry whether or not the entry is usable. `Get-NetNeighbor` prints
the NUD state, and during a 1 MB fetch that stalled three times:

```
01:32:31 Unreachable   -> dosd logged a resume at 01:32:36
01:32:44 Unreachable   -> dosd logged a resume at 01:32:49
01:33:53 Unreachable   -> dosd logged a resume at 01:33:56
01:32:49 .. 01:33:50   no state change at all -- the one clean 61s stretch
```

Every stall sits inside a window where Windows had given up resolving the box,
and the only uninterrupted stretch of the transfer is the only stretch where
the entry was left alone. The `LinkLayerAddress` was `00-00-00-00-00-00` in
every sample of every run: Windows never once learned the box's MAC.

**3. The fix, and the same table afterwards.** With the box answering ARP:

```
01:41:43 Reachable 28-CD-C1-11-6B-27     <- resolved, for the first time
01:42:16 Probe     28-CD-C1-11-6B-27     <- Windows revalidates
01:42:24 Reachable 28-CD-C1-11-6B-27     <- we answered, so it stays up
```

and it cycled Reachable/Probe/Stale for six more minutes without ever reaching
Unreachable again.

### Why the restart workaround worked, which is what made this so hard

`NetOpen` sends an ARP **request** for the peer. A host that receives a request
naming it as the target is obliged by RFC 826 to record the sender -- so every
flow rebuild refreshed the peer's entry for us as a side effect. That is the
entire reason "a completely fresh flow always works" was true, and it is why
the mechanism looked like it was recovering from a link fault when it was
really just re-announcing our address. The workaround treated the symptom so
effectively that it hid the cause.

It also explains the shape of everything else that was observed:

* **Broadcasts kept arriving.** They need no resolution. The observation was
  correct; the inference from it -- that the card was selectively deaf -- was
  not.
* **Raising the retry budget from 10 to 60 changed nothing.** Nothing the
  client says on port 8069 can refresh a neighbour entry. Only ARP can.
* **Promiscuous mode changed nothing.** The frames were not on the wire to be
  heard.
* **KNET had already measured it** -- 0 unicast frames against 23 broadcast in
  the same 15 seconds -- and `net.pas` has carried a comment saying this box
  answers no ARP since long before any of this. Nobody connected that to the
  transport. The fact was known; only its consequence was missed.

### The fix, in two parts

**Answer ARP** (`ArpService` in `net.pas`). `NetOpen` now KEEPS the 0806 handle
instead of releasing it after the resolve, so ARP requests for us are delivered
and replied to. The old comment declined to hold two handles at once on the
grounds that a driver may refuse a second `access_type` for a type already in
use -- true of the SAME type, but 0800 and 0806 are different and this driver
takes both. It is not assumed: if the 0800 acquire fails while 0806 is held,
the ARP handle is dropped and the acquire is retried alone, so the worst case
is the behaviour this unit had before rather than a box that cannot talk at
all. The two handles also get **separate filter buffers**, because
`access_type` is handed a pointer to the ethertype and the spec does not
promise the driver copies it.

**Keep the entry warm** (`NetArpEvery`, default ~8 seconds). An unsolicited ARP
request for the peer while waiting in `NetUdpRecv`. This is secondary -- the
replies are the fix -- but it covers a peer that has evicted the entry outright
rather than merely aged it, and it costs one 60-byte frame per eight seconds.

A request rather than a gratuitous reply, deliberately: a request names the
peer as its target and obliges it to record us, while an unsolicited reply is
advisory and may be ignored. And **preventive rather than on demand**: the old
`NetArpPoke` fired during a stall, by which point the entry was already dead
and the flow already lost, which is why it was recorded as changing nothing.

### What it was worth

Same 5 MB file, same link, measured the same night:

| | time | stalls | result |
|---|---|---|---|
| before | 461.5 s | 23 | **FAILED** |
| + superseded-flow cancellation | 428.1 s | 25 | ok |
| + ARP replies and keepalive | **291.8 s** | **0** | ok |

and 1 MB went 94.8 s / 3 stalls to 51.8 s / **0 stalls**, with resends down
from 14 to 2.

**10 MB, which had never been attempted, went through on the first try**: 506.4
s, zero stalls, 20 resends, CRC-32 `149CCED3` on the box against `149CCED3`
here. That run used the INSTALLED `C:\TOOLS\UGET.EXE` rather than a copy in
`C:\WORK`, so it also confirms the deployed toolset. A 1 MB `dospull` back off
the box in the same session was byte-identical too, so the upload direction is
fixed by the same change -- as it should be, since the cache that was expiring
was the peer's entry for the box, not ours for it.

One thing to expect after a big fetch: `HD` on a 10 MB file takes **ten and a
half minutes** on this machine, because it reads every byte to CRC it. The box
stops polling for the whole of it and `dosctl status` says STALE, which is
indistinguishable from a hang from here. It drew 40 W throughout and came back
on its own. Check the watts before reaching for `dospower cycle`.

The remaining gap to mTCP's 83 KB/s is throughput, not reliability: we are
stop-and-wait with one packet in flight and a per-byte UDP checksum on an 8086,
about 78 ms per 1400-byte block round trip. That is real and separate work -- a
sliding window is what mTCP has and we do not -- but it is no longer a
correctness problem.

### The other half: duplicate server flows

Found in the same session and fixed alongside, because it is what produced
every `did not confirm blksize 1400` in `dosd.log` (32 of them).

`dosd` spawns a thread with a fresh socket for every request and deduplicated
only the job poll. A client whose first request goes missing retransmits **from
the same local port**, so the two requests are indistinguishable to the server
and both used to be answered. The client locks on to whichever transfer
identifier it hears first, which is correct RFC 1350, so the loser spent its
whole 8x2s budget re-OACKing a client that could never reply.

The cost was not the wasted thread. `TftpGet`'s OACK branch did not check the
TID -- only its DATA branch did -- so it *accepted* those strays, and every one
of them reset `Tries` to 0. A phantom talking every two seconds meant the stall
counter could never reach `RESTART_AFTER`, which pinned the transfer inside the
one fault its rebuild recovery exists to escape. Each stray also made the
client re-ACK block 0 at the real flow, which reads that as a duplicate ACK and
answers with an immediate retransmit.

Three changes:

* `dosd` drops a request it is already serving, the way it always has for the
  job poll. A resume is deliberately exempt: it carries `name@offset` and comes
  from a new port, so it differs in both halves of the key.
* `dosd` **cancels superseded flows**. A new request for the same file from the
  same client means every earlier flow is abandoned by definition, so they stop
  immediately instead of retransmitting into a dead port for sixteen seconds.
* `TftpGet` ignores OACK **and ERROR** from a port it is not locked on to, and
  counts them as `TftpStrays`. The ERROR case matters most: an ERROR ends the
  transfer, so honouring one from a phantom would kill a transfer that was
  going perfectly.

`selftest.py` step 4b sends two identical RRQs and asserts exactly one server
flow answers. Remove the guard in `dosd.py` and it sees two, which is the only
reason the test is worth having.

### A second fault found on the way: `packetint` pointed at nothing

`C:\NETWORK\MTCP\MTCP.CFG` on the box said `packetint 0x65` while the packet
driver has been on **INT 60h** since the USB Ethernet experiment was abandoned.
Every mTCP tool on the machine had been failing with `Could not setup packet
driver` and an unformatted `0x%X`, and nothing noticed because the bridge does
not use mTCP any more. It is corrected on the box, and `dos/live/MTCP.CFG` has
been re-mirrored from the real file -- it had drifted badly, exactly the way
`dos/live/AUTOEXEC.BAT` had, and deploying the stale mirror would have changed
the hostname and the MTU as a side effect.

Worth keeping for its own sake: mTCP is the only independent transport on this
box, which makes it the control for any future "is it the link?" question. It
is only a control if it works.

### The workaround: resume on stall

**Written before the cause was known. The mechanism is still in the code and
still useful -- it now recovers from ordinary loss rather than from a fault
that arrived every twenty seconds.**

There is a second fault underneath, and it is **still unexplained**. Partway
through a transfer, frames addressed to the box's MAC stop being delivered to
it, while broadcast frames keep arriving perfectly well. The server is provably
still sending. It is not a lost packet and not a shortage of patience.

What always works is a **completely fresh flow** -- every transfer that stalled
succeeded on the next attempt. So `TftpGet` builds one for itself after three
silent timeouts: `NetClose`, `NetOpen` (which redoes ARP), a new local port,
and a re-request for the rest of the file. `dosd` accepts `name@<byte offset>`
in an RRQ and serves from there; the file stays open and keeps appending, so
nothing already received is fetched twice.

Verified in the act, not just in theory -- dosd logged the resumes:

```
tftp: 192.168.1.20 resuming local/BIGTEST.BIN at byte 8192
tftp: 192.168.1.20 resuming local/BIGTEST.BIN at byte 130048
tftp: 192.168.1.20 resuming local/BIGTEST.BIN at byte 248832
```

Every offset is a multiple of 512, and the result CRC-matched.

### Four hypotheses that were wrong

Recorded because each one is plausible enough to be tried again, and each was
**built, measured and removed** -- the code is gone, the null results are not:

| theory | how it died |
|---|---|
| ARP entry expiring mid-transfer | `NetArpPoke` broadcast an ARP before every retransmit. Fired 10x per stall, changed nothing; `arp -a` showed the entry present throughout. **THIS ONE WAS RIGHT.** See the ARP section above |
| just the deadlock | fixed it, and 3 of 3 still failed at blocks 80-89 |
| the receive handle wedges | `NetReopen` released and re-took it. `reopens: 3` and still stalled -- and broadcasts kept arriving, so the handle was fine |
| the card's address filter | `set_rcv_mode(6)`, promiscuous. `modesets: 3`, no blocks arrived even with the card accepting everything on the wire |

**The first row was correct and was dismissed on bad evidence, which is the
most useful thing in this table.** Two mistakes killed it, and neither was the
hypothesis:

* **The instrument could not see the answer.** `arp -a` prints a `dynamic`
  entry for an address whose neighbour state is `Unreachable`, so "the entry
  was present throughout" was true and meant nothing. `Get-NetNeighbor` shows
  the state, and it shows the entry dead across every stall. A negative result
  is only worth what the instrument is worth.
* **The remedy was aimed at the wrong moment.** Poking during a stall is too
  late: the entry is already gone and the flow is already lost. The same idea
  applied *preventively*, plus actually answering the peer's own requests,
  takes the stall count to zero.

So the discipline of recording dead hypotheses did its job here in an
unexpected way -- not by stopping the idea being retried, but by preserving
exactly enough detail to show, months later, why the null result had been
believed. A row that had only said "not ARP" would have closed the question
permanently.

**The measurement that cracked it was a null result.** Raising the client's
retry budget from 10 to 60 -- two full minutes of asking -- changed nothing at
all. That is what ruled out impatience and transient outages together, and left
only something scoped to the flow, which is exactly what rebuilding the flow
fixes. The experiment that looked like a waste was the one that mattered.

### Bigger blocks: `blksize`, and what it actually bought

RFC 2348, client-driven, verified on hardware 2026-09-02. `UGET` asks for
1400-byte blocks on a file fetch; `dosd` answers with an OACK naming the size
it accepted, and the client ACKs block 0 to start the transfer.

The ceiling is **1400** and the reason is `Net`, not TFTP: one Ethernet frame
is 1500 bytes, less 20 for IP and 8 for UDP and 4 for the TFTP header, giving
1468 -- and `Net` **drops fragments rather than reassembling them**, so
anything above that would not merely be slower, it would not arrive at all.
1400 leaves headroom for that arithmetic being wrong somewhere.

Measured back to back on the same link and the same 1 MB file, the old client
kept runnable as `C:\TOOLS\UGET.BAK`:

| | blocks | resends | time | |
|---|---|---|---|---|
| 512-byte blocks | 2049 | 27 | 131.2s | 8.0 KB/s |
| **1400-byte blocks** | **749** | **7** | **72.3s** | **14.5 KB/s** |

**1.8x, not the 2.7x the packet count suggests**, because per-byte cost on an
8086 -- the copy and the UDP checksum -- does not go away when you send fewer
packets. Fewer packets does also mean proportionally fewer chances to lose
one, which is where the resend count went.

Three things in it are deliberate:

* **The job poll does not negotiate.** `TftpWantBlk` is set to 0 for a poll
  and only raised for a real fetch. A batch is a block or two, and an OACK
  round trip on every poll would cost more than it could ever save.
* **A resumed flow re-negotiates from scratch.** `TftpBlkSize` is reset to
  512 when `TftpGet` rebuilds its flow after a stall, because the new request
  is a new negotiation and assuming the old answer would silently mis-frame
  every block after it.
* **Asking is free against an old server.** An option a server does not
  understand is ignored, and it simply sends 512-byte blocks -- so a new
  client works against an old `dosd`, and an old client (which asks for
  nothing) works against a new one.

### The upload direction, and the first `dospull` that ever worked

`UPUT` negotiates the same way, and the OACK replaces ACK 0 rather than
joining it -- a server sending both would be answered twice. Unlike a read,
the client does not ACK the OACK: its first DATA block is the answer.

**Large `dospull` had never worked, and blksize is not why.** The first 1 MB
pull ever attempted stalled at block 5, and the retry stalled at block 401 --
scattered, which is this link's mid-transfer stall, the same fault the
download path has worked around since the 5 MB transfers. `TftpGet` rebuilt
its flow on a stall; `TftpPut` had no equivalent and simply gave up. The note
above about the upload deadlock predicted this exactly: *it would have broken
the first large `dospull` anyone tried*. It did.

So `TftpPut` now does what `TftpGet` does -- after `RESTART_AFTER` silent
timeouts it tears the flow down, re-opens, and re-requests as
`name@<bytes acked>` -- and `dosd` keeps the partial write across flows in
`_uploads`, keyed by client address and name.

Verified on hardware 2026-09-03: 1 MB, four stalls, four rebuilt flows, one
byte-exact file (CRC-32 `998E4325`).

```
resuming write of pull at byte 533400
resuming write of pull at byte 635600
resuming write of pull at byte 695800
```

Three things in it are load-bearing, and two of them were bugs first:

* **A resume rewinds; it does not have to match.** The client resumes from
  the last byte *it* saw acknowledged, so it is normally BEHIND the server:
  every ACK we sent whose reply was lost leaves us holding a block the client
  still believes it owes. The first version demanded `len(held) == resume_at`
  and refused the very first real resume -- `cannot resume write of pull at
  byte 14000`. Only resuming *past* what we hold is refused, because nothing
  can fill that gap and appending anyway would produce a plausible file with
  a hole in it.
* **The resumed buffer is a fresh copy, not a truncation in place.** The
  stalled flow may still be inside its retry loop on another thread holding a
  reference to the old object, and two writers interleaving into one buffer
  is a corruption nobody would trace.
* **A duplicate ACK never counts towards a restart -- only silence does.** A
  duplicate ACK is proof the far end is alive and listening, which is the
  opposite of a stall; the right answer there is an immediate retransmit.
  Restarting the flow would throw away a working connection.

### Limits worth knowing before moving big files

* **~33 MB per transfer.** The TFTP block number is 16 bits, so 65535 blocks
  of 512 bytes. 5 MB is 10241 blocks, so there is headroom, but it is a real
  ceiling and nothing checks for it.
* **Raise `--timeout`.** 5 MB takes nearly eight minutes against a 120s
  default.
* **`blksize` (RFC 2348) is done** -- see below. 1.8x, measured.
* **The single-slot receive buffer drops frames under retransmit bursts** --
  100 of them during the 5 MB run. Harmless, because they are retransmitted,
  but it is the next thing to look at for speed.

## The original investigation: large transfers are NOT ARP

Kept as history: this is how the large-transfer problem looked while it was
still open, and the reasoning is why the ARP theory got as far as it did. The
outcome is in the section above.

**What works.** Anything up to about 90 blocks is completely reliable. Thirty
consecutive 34 KB fetches moved 2040 blocks with **zero resends** -- so the
link does not drop packets in any ordinary sense, and the earlier claim in
these notes that "the residual matches raw link loss" was wrong.

**What does not.** A 300 KB file (600 blocks) failed **6 times out of 6**,
stalling at scattered points -- blocks 89, 20, 21 on one build and 85, 32, 86
on another. Bulk deploys of the 30-47 KB tools fail about 11% of the time
(4 of 36 on a `--force` resend), and those four came in *alphabetically
consecutive pairs* -- AMOZART/ARP, then VMODES/VSHOT -- so whatever it is
catches the transfer in flight and the one after it.

**ARP was the obvious suspect and it is not the cause.** Worth recording,
because it is a plausible enough story to be tried again by someone else:

* `starter/net.pas` grew a `NetArpPoke` -- broadcast an unsolicited ARP
  request before every retransmit, so the far side refreshes its entry for us.
  `send_pkt` (AH=04h) needs no handle, so this was main-loop code with no
  interrupt-time risk at all.
* It fired **10 times per failed transfer** and made **no difference**: 6 of 6
  still failed, at the same scattered block numbers as without it.
* Watching `arp -a` on the Windows side *during* a stall showed the entry
  **present the whole time**.

So it was reverted -- the rebuilt `UGET.EXE` is byte-identical to the one on
the box (47158 bytes, CRC-32 `94F4A595`), which is how the revert was checked.
Keeping an unproven fix in the transport is exactly the trap `TFTP_HOLD_SECS`
set: a plausible change that measures as nothing gets cited later as a reason
the cause must lie elsewhere.

**Practical impact today: none.** Every tool in the kit is under 50 KB, and
the largest, `UGET.EXE` at 47 KB, deploys fine (occasionally on the second
attempt -- which is what the CRC check above is for). But there is a ceiling
here, and anything that needs to move a few hundred KB will hit it.

**To reproduce**, serve a big file and fetch it:

```python
b = bytearray(); x = 12345
while len(b) < 300*1024:
    x = (x*1103515245 + 12345) & 0x7FFFFFFF
    b.append((x >> 16) & 0xFF)
open(r"files/local/BIGTEST.BIN", "wb").write(bytes(b))
```

```
dosexec "C:\TOOLS\UGET.EXE <server> local/BIGTEST.BIN C:\WORK\B.BIN -V"
```

It fails within a minute, every time. **Do not start from the ARP theory** --
that ground is covered. The untried leads are the DOS side's file writes as
the file grows (FAT allocation pauses long enough to desynchronise the
stop-and-wait), and `PKTCAP` on the box to see whether the server's blocks are
arriving at the wire and being lost above it.

**TCP is a different category and should not be written here.** Sequence
arithmetic, the connection state machine, retransmission timers, windowing,
out-of-order reassembly. Its failure mode is the bad one: correct on the bench,
silently corrupting data under loss. Write TCP only if writing TCP is the point.
