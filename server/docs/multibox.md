# More than one DOS box at a time

> **2026-09-26: back to one box.** The 386SX is retired and gone from
> `boxes.json`; the V30 is the only machine. Everything below still works
> and still describes the code -- adding a machine again is one
> `boxes.json` entry -- but the "two real machines" in the examples and
> measurements are history. A running `dosd` keeps showing a removed box
> as `NOT in boxes.json` until it is restarted; that is leftover state,
> not a fault.

**Phases 1 to 6 are built, and phase 0 turned out not to be needed.** The
design below was written 2026-09-21 while the bridge still talked to one
machine; it was implemented the same day and is kept whole, because the
argument for *why* each piece is shaped the way it is has outlived the
question of whether it exists yet. **What is built, and what is not, is in
[Status](#status-2026-09-21) at the end** -- read that first and treat the
rest as the reasoning behind it.

Everything here that describes the *current* code was read out of the source
rather than recalled. Where the implementation departed from the proposal it
says so, at the point of departure, rather than being quietly rewritten.

The goal: two or more DOS machines on the bridge simultaneously, so different
projects can be built against different boxes, and so a single test can be run
on every machine at once and the answers compared.

`docs/hardware.md` describes the two machines. This file is about the bridge.

---

# Part 1 -- How it works, and how to set it up

Everything from **The finding that decides the architecture** onward is the
design record: why each piece is shaped the way it is, and which hypotheses
were paid for and discarded. This part is the operating manual. Read it
first; read the rest when you need to change something.

## The one-paragraph version

One `dosd` serves every DOS machine. Each box polls for work under a TFTP
resource name that can carry its identity -- `job.v30` instead of the bare
`job` -- and `dosd` keeps a separate job queue, liveness clock and log tag
per box. Every `dosctl` command takes `--box ID`; `--box all` runs it on
every machine at once and prints the answers side by side. **With no
`boxes.json` none of this engages and the bridge behaves exactly as it did
when it could only ever mean one machine.**

## How a poll finds its box

This is the part worth understanding, because everything else follows from
it. When a box asks for work, `dosd` resolves which machine it is in three
steps (`box_for_poll()` in `dosd.py`):

| | layer | how |
|---|---|---|
| 1 | **declared** | the id in the resource name -- `job.v30` -- put there by `SET BOXID=` in `C:\AI\AI.BAT` |
| 2 | **observed** | the source IP of the poll, looked up in `boxes.json` |
| 3 | **fallback** | if exactly one box is registered, it is that one |

**The declared id wins when both are present**, and a disagreement is a loud
log line rather than a silent reroute:

```
!! boxid v30 polled from 192.168.1.21, but sx386 is registered at that
   address and v30 is at 192.168.1.20. An SD card that moved machines, a
   cloned disk, or a box that was re-addressed.
```

Rerouting on the address instead would mean an SD card moved between machines
quietly starts answering for the other one, which is the single worst failure
this design exists to prevent.

**Layer 2 alone is enough**, and that is the single most useful property
here: an agent that has never heard of `BOXID` polls for the bare name `job`
from a fixed address, and `boxes.json` routes it correctly with **nothing on
the DOS box touched at all.** No recompile, no agent swap, no reboot, no trip
to a keyboard. Adding `BOXID` later buys the cross-check, not the routing.

A poll that matches nothing -- several boxes registered, no id declared, and
an unrecognised address -- is answered with an idle batch and a loud log
line. It is not dropped: a machine retrying forever with nothing on any
screen to explain why is the failure mode this project is built to avoid.

## What is per box, and what deliberately is not

| | |
|---|---|
| job queue | **per box.** Jobs stay strictly serialised within a machine for free, because the queue is drained by a box that polls, runs one `JOB.BAT`, then polls again. Across machines they run in parallel |
| liveness (`last_poll`) | **per box.** Read by `dosctl status` and by every reboot/upgrade wait |
| in-flight job (`awaiting`) | **per box**, and cleared when that box next polls -- a poll proves the previous job is over |
| boot events | **per box**, tagged in `/status` |
| log lines | **tagged** `[v30  ]` / `[sx386]` once more than one box is registered; untagged with one, so single-box logs read exactly as before |
| pull bytes | **per JOB ID**, not per box -- see below |
| results | routed by the `##JOB=` id inside the payload, which is globally unique. The box id on a result name is only ever a log tag |
| **`files/` staging** | **NOT per box, and must never become so** |

`files/` staying box-agnostic is the point of the whole exercise: the same
binary running on both machines is what makes a comparison mean anything. A
box dimension in staging would make the fan-out meaningless by construction.

### Why pulls are keyed on the job id

`dospull` bytes arrive with no framing -- the box simply streams the file
under an agreed name. That was safe with one machine, because one box runs
one job at a time, so only one pull could ever be outstanding, and the bytes
went into a single global slot.

**With two machines that slot silently returns the wrong file.** Two
concurrent pulls and the bytes attach to whichever pull the slot happens to
hold: you get the other machine's file, byte-exact, complete-looking, and
wrong -- the same failure shape as `NC` without `-bin` turning a 27298-byte
EXE into a plausible 27258-byte one.

So `build_pull_batch` writes the job id into the upload name -- `pull.3f2a91bc`
-- and the blob is keyed on that. Keying on the job is strictly stronger than
keying on the box: per-box would still let two pulls cross if one machine's
agent ever became concurrent, and per-job cannot. It is generated server-side,
so no DOS binary knows or cares.

`selftest.py` step 7d is the regression test, and it fails if this is reverted.

---

## Setting it up

### What you need first

| | |
|---|---|
| **a boot disk per machine** | they cannot share one. The PicoMEM's SD card *is* the boot disk, so two simultaneous boxes need two cards |
| **a static address per machine** | outside any DHCP pool. `dosd` cross-checks against it, and `docs/network.md` records what an expired lease cost when the box ran DHCP |
| **the host firewall open** | see step 3. This is not optional and its failure looks nothing like a firewall |

### 1. Give the second machine its own address

On the box, `C:\AI\NET.CFG` carries the address the bridge's own stack uses:

```
IPADDR 192.168.1.21
NETMASK 255.255.255.0
GATEWAY 192.168.1.1
```

The boot banner prints it, so the machine reports its own identity to anyone
standing in front of it. **If you cloned the first card, change this before
both machines are ever powered on together.** Two machines at one address
does not present as a configuration mistake -- it presents as a flaky link,
which is the misdiagnosis that cost this project weeks.

### 2. Register the machines

```
copy boxes.example.json boxes.json
```

```json
{
  "default": "v30",
  "boxes": {
    "v30":   { "ip": "192.168.1.20",
               "desc": "NEC V30, MS-DOS 6.22, 8087 fitted",
               "capture": {}, "power": {},
               "expect": { "cpu": "V30", "fpu": true } },
    "sx386": { "ip": "192.168.1.21",
               "desc": "Gateway 2000 386SX/25, no 387",
               "capture": null, "power": null,
               "expect": { "cpu": "386", "fpu": false } }
  }
}
```

Rules the loader enforces, each for a reason:

* **ids are `[a-z0-9]{1,8}`** -- they ride in a TFTP resource name, so they
  must stay 8.3-safe and path-safe. Lower case only, so two ids cannot differ
  by case alone on a platform that upper-cases half of everything.
* **`ip` is mandatory and must be unique.** A duplicate is refused at load
  time, because catching it there costs one error message and catching it on
  the wire costs a week. Use `"any"` for a box with no fixed address -- it
  opts out of the cross-check, so such a box **must** declare a `BOXID`.
* **`default`** is optional when only one box is registered.
* **`_`-prefixed keys are comments**, the same convention `power.json` uses.

`boxes.json` is per machine and **never ships** -- it is in `.gitignore`
alongside `power.json` and `capture.json`. `boxes.example.json` is the schema.

### 3. Open the firewall -- do not skip this

```
dosfirewall.cmd            (right-click, Run as administrator)
```

It adds inbound rules for UDP 8069 and TCP 8080-8082, scoped to your boxes'
subnet. Port rules rather than a rule for `python.exe`, because port rules
survive a Python upgrade and do not open every Python program on the machine.

**Why this has its own step:** on 2026-09-21 both machines went silent at
once and stayed silent through a reboot, a power cycle and a daemon restart.
Nothing was broken. The LAN interface was on the **Private** profile, the
only Allow rules for `python.exe` were scoped to **Public**, and the default
inbound action is block -- so every poll was dropped before `dosd` saw it,
while `netstat` showed the daemon correctly bound and both boxes showed a
healthy agent banner on their own screens. An interface that disconnects and
re-identifies can be re-filed under a different profile, which is how working
rules stop applying without anyone changing them.

### 4. Restart dosd and confirm

```
dosctl shutdown                  (then start dosd.py in its own window)
dosboxes                         which machines it knows, and which is targeted
dosstatus                        a row per box
```

`dosd` prints the registry at startup, so a wrong registry is caught on the
line above the first poll rather than three hours later in a result from the
wrong machine:

```
box sx386 192.168.1.21   Gateway 2000 386SX/25, no 387
box v30   192.168.1.20   NEC V30, 8087 fitted   (default)
waiting for 2 DOS box(es) to poll ...
```

### 5. Prove both machines are actually correct

```
dosctl verify --all
```

CRC-32s every tool on every box against `starter/build`. **This is the step
that replaces a property you have just lost.** With one SD card there was one
`C:\TOOLS` and drift was impossible; with two there are two, and `verify
--all` is the drift alarm. Run it as routine, not as a special occasion.

### 6. Optional -- give each box a declared identity

Everything above works without this. `SET BOXID=` adds the cross-check that
catches a moved or cloned SD card:

```
dosctl upgrade --agent --box v30
```

`dosctl` stamps the id from `boxes.json` into the agent it deploys, so the
registry `dosd` routes on and the file the box runs cannot disagree. It
**refuses to rename** a box that already declares a different id, because a
rename means `dosd` routes to the new name while jobs queued under the old
one wait for a machine that no longer answers -- pass `--force` if the rename
is deliberate.

Note this is the one step that can cost a trip to a keyboard, which is
exactly why it is last and optional. `docs/agent.md` has the recovery
(`COPY C:\AI\AI.BAK C:\AI\AI.BAT`).

### 7. Peripherals, if you have them

`capture.json` and `power.json` stay the schema; `boxes.json` supplies
per-box overrides. `{}` means "this box has one, with the shared settings";
`null` or omitting the key means it has none.

That distinction is load-bearing. **`doscap --box sx386` with no device
configured must refuse, and must never show you the other machine's screen.**
A capture that silently shows the wrong box does not produce a wrong answer,
it produces a convincing one -- every visual verification in this project's
history would have been reasoned about confidently and wrongly.

Genuinely per box: `device`, `audio_device`, `out_dir` for capture; `host`
and `channel` for power. Everything else -- `rtbufsize`, `preset`,
`max_cycles`, `window_secs` -- is a property of the capture stick or of
policy, and duplicating it per box guarantees it drifts.

The smart plug's **cycle history is also per box** (`power.state` keys them
separately), or one machine's cycles would eat the other's rate-limit budget
and the guard that stops a recovery loop would refuse a machine it had never
touched.

### 8. Optional -- pin a project to a machine

A `.dosbox` file containing a box id, in a project directory or any parent,
pins everything run from there to that machine.

---

## Using it day to day

### Choosing a machine

Resolution order, and **ambiguity is a hard error listing the candidates,
never a guess**:

1. `--box ID`
2. `$DOSBOX`
3. a `.dosbox` file at or above the working directory
4. `default` in `boxes.json`
5. the sole registered box

A job that silently picks a machine returns a result that looks entirely
correct and simply ran on the wrong CPU, with nothing in the output to say
so. That is the same lesson `files/` taught when two projects both built a
`HELLO.EXE`, and worse, because the wrong answer is invisible.

**`dosctl stop` and `dospower cycle` refuse a default outright** and make you
name the machine, whenever more than one is registered. They are the two
commands whose mistake needs hands on a keyboard to undo.

### Running on everything at once

```
dosrun FPU.EXE --box all
dosctl exec "VER" --box all
dosctl verify --all
```

Dispatch is parallel -- different addresses, independent queues, and `dosd`
is already threaded. The output is a table and then the diff, not two logs
end to end:

```
              sx386       v30
rc            0           0
lines out     8           15
--- sx386 and v30 first differ at line 3 ---
```

`--box all` is accepted only by commands that can meaningfully compare --
`run`, `exec`, `verify`, `status`, `boxes` -- and is refused by everything
else rather than quietly running on the default.

**This is the reason the rest of it exists.** `CLAUDE.md` already requires
that everything in `starter/` runs on both machines, and that requirement was
previously enforced by a human swapping an SD card and remembering. Both
faults the 386 ever found were found by moving machines and noticing a
difference; `--box all` makes that mechanical.

### A machine on a weak link

If one box is far from the access point, **make its jobs smaller rather than
retrying the big ones.** One file per deploy; a handful of checksums per
verify. The failure mode is whole job *results* failing to return -- the
largest payload the bridge ever asks a box to send -- and it presents as a
dead box that is in fact perfectly healthy. `docs/network.md` has the
measurements and the signature.

---

## When something looks wrong

| symptom | what it usually is |
|---|---|
| every box `never seen`, `dosd` bound correctly | the host firewall -- run `dosfirewall.cmd`. Two machines failing identically at once means look at what they share, and that is this PC |
| one box `STALE` **and** `busy:` | it is running a long job, not hung. A box polls only between jobs |
| one box `STALE`, nothing queued | send a UDP datagram to it and read `netsh interface ipv4 show neighbors`. `Reachable` means its stack answered, so it is alive and we are not hearing it; `Unreachable` means nothing is polling on it. `ping` proves nothing -- nothing DOS-side answers ICMP |
| box at a DOS prompt on `doscap` | the agent **exited** -- not a hang. Nothing on this side can reach it; a power cycle restarts it because `AUTOEXEC.BAT` runs `AI.BAT` |
| `verify` says `HD.EXE is not on the box` | possibly true, but on a weak link it is more often the whole result being lost. Check `HD` directly before believing it |
| a job returns the wrong machine's file | should be impossible; `selftest.py` step 7d covers it. Check the `!!` lines in `dosd.log` |
| `!!` identity warnings | a box is polling from an address it is not registered at. A moved SD card, a clone, or a re-addressed machine |

## The failure this is all arranged around

**A silent wrong-box result** -- a job, a pull or a capture that lands on the
other machine and looks completely normal. The mitigations, in order of how
much they carry: explicit ambiguity errors, per-job pull keying, the
source-IP cross-check on every poll, the box id on every log line, and the
peripheral guards that refuse rather than fall back.

Everything else here is plumbing in service of that.

---

# Part 2 -- The design record

## The finding that decides the architecture

There are two ways to do this and the code settles which, so this comes first.

**Option A -- one daemon per box, each on its own ports.** `dosctl` already has
`DOSD_SERVER`, so selecting between daemons costs nothing on the Windows side.
It fails on the DOS side: `TFTP_PORT = 8069` is a **compile-time constant** in
`starter/tftp.pas:48`, read by `starter/uget.pas:197` and
`starter/uput.pas:125`. A second daemon on a second UDP port therefore needs a
*recompiled, per-box* `UGET.EXE` and `UPUT.EXE`, deployed to each machine over
the very transport they implement.

`CLAUDE.md` records what that costs:

> Upgrade the transport last. `dosctl upgrade --tools` deploying tools built
> before that fix took the 386 off the bridge, because `UGET` was among them and
> the agent needs it to poll. Recovery was `HTGET` at the keyboard.

`HTGET` is no longer in the agent loop -- it was removed on 2026-09-02 -- so
that recovery no longer exists. And the two boxes' transport binaries would
diverge, which breaks the one-binary-for-both-machines rule everything else
here is written to.

**Option B -- one daemon, many boxes, identity carried in the resource name.**
Look at what the box actually puts on the wire, in `dos/live/AI.BAT`:

```
C:\TOOLS\UGET.EXE %UPHOST% job C:\AGENT\JOB.BAT POLL
C:\TOOLS\UPUT.EXE %UPHOST% C:\AGENT\RES.TXT result
```

`job` and `result` are TFTP resource names passed as **command-line
arguments**. Making them `job.v30` and `result.v30` costs one `SET BOXID=v30`
and two substitutions in a batch file, and **no change to any DOS binary at
all**: no recompile, no transport upgrade, no trip to the keyboard.

One path touches a constant in `tftp.pas`; the other touches a string in a
batch file. **Take Option B.** It is not a matter of taste.

### Separator and identifier shape

`@` is taken -- `name.rpartition("@")` in `dosd.py` carries the resume offset
for both reads and writes. `/` is taken -- `safe_rel` uses it for the project
namespacing under `files/`. A dot is free and already inside `SAFE_SEG`'s
character class.

So: `job.v30`, `result.v30`, and box ids matching `[a-z0-9]{1,8}`. That keeps
them 8.3-safe, path-safe, usable as a log directory name, and short enough to
sit in a table column. `v30` and `sx386` are the two.

## What is already multi-box safe

This is the good news, and it is larger than expected. Every piece of transfer
state in `dosd.py` is **already keyed on the source address**, as a side effect
of the resume and deduplication work done for the transport stall -- not by
design for this, but it holds:

| state | keyed on | |
|---|---|---|
| `flow_begin(addr[0], name)` | source IP | safe |
| `_uploads[(addr[0], name.lower())]` | source IP | safe |
| `_xfer_holds[(addr, op, name.lower())]` | source addr | safe |
| `_job_holds[addr]` | source addr | safe |
| result routing, `##JOB=<id>` to `STATE.deliver` | job id (uuid4) | safe |
| `/result/<jid>` | job id | safe |
| `files/` serving | nothing | safe, and must stay box-agnostic |

Two boxes at two IP addresses cannot collide anywhere in the transport. Most of
the risk in this project is gone before any of it is written.

`files/` staying box-agnostic is deliberate and is argued below under
**What not to build**.

## The one genuine silent-corruption bug

`State.deliver_blob()` in `dosd.py` attaches raw pull bytes to
`STATE.awaiting_pull`, a **single global slot**, and its own comment says
exactly why that is allowed today:

> There is no framing on the wire: `NC` just opens a socket and streams the
> file. That is safe here because the DOS box runs exactly one job at a time --
> it polls, CALLs one `JOB.BAT`, and only then polls again -- so at most one
> pull can ever be outstanding.

True of one box. **False the moment there are two.** Two concurrent `dospull`s
and the bytes attach to whichever pull job the slot happens to hold: you get
the other machine's file, byte-exact, complete-looking, and wrong.

That is the same failure shape as the two faults this project has already paid
for -- `NC` without `-bin` turning a 27298-byte EXE into a plausible 27258-byte
one, and two daemons on one UDP port splitting a transfer between two state
machines. Plausible and undetectable downstream is the worst category there is.

**The fix is better than per-box, and it is dosd-only.** `build_pull_batch`
generates the upload name on the server side:

```python
UPUT_DOS + " %UPHOST% " + remote_path + " pull"              # today
UPUT_DOS + " %UPHOST% " + remote_path + " pull." + job_id    # proposed
```

Keying the blob on the **job id** rather than the box is strictly stronger:
per-box would still let two pulls cross if the agent loop ever became
concurrent, and per-job cannot. No DOS-side change, so this can and should land
before a second machine is ever on the wire.

## Identity: declare, observe, measure

The rule from `docs/hardware.md` and from the PicoMEM work is *read the card,
do not trust the note*. The same rule applies to a box's own identity, and for
a sharper reason than usual -- see the SD card below.

Three layers, of increasing cost and increasing truth:

1. **Declared** -- `SET BOXID=` in `C:\AI\AI.BAT`, carried for free in the
   resource name on every poll.
2. **Observed** -- the source IP of the poll. `dosd` already has it on every
   packet and currently throws it away for routing purposes.
3. **Measured** -- CPU class, FPU, PicoMEM BIOS date, free memory, mono or
   colour. One cheap job per boot, from tools that already exist.

`dosd` routes on (1), cross-checks against (2) on every poll at zero cost, and
against (3) once per boot. **A mismatch is a loud warning, never a silent
reroute.** That one guard catches all of: the SD card having been moved to the
other machine, a cloned disk with a stale id, a box that was re-addressed, and
a capture device or smart plug pointed at the wrong machine.

### The hardware prerequisite, and the property it costs

> **Settled 2026-09-21: there are two SD cards now.** Both machines boot and
> reach the network at once -- `192.168.1.20` (V30) and `192.168.1.21`
> (386SX) -- so the gating purchase below was already made. The property it
> costs is real and is now live: there are two `C:\TOOLS` and they can
> drift, which is what `dosctl verify --all` exists to catch.

**There is only ONE SD card**, and it moves between the two PicoMEM cards. The
boot disk is physically the same disk whichever machine is running. Two boxes
online at once therefore requires a second one; this is the gating purchase.

| | have | need |
|---|---|---|
| PicoMEM cards | 2 | 2 |
| **SD cards** | **1** | **2** |
| static IP addresses | -- | 2, outside any DHCP pool |
| capture sticks | 1 | 1 or 2; must degrade gracefully |
| smart plugs | 1 | 1 or 2; must degrade gracefully |

The cost nobody bills for: `CLAUDE.md` currently leans on *"one `C:\TOOLS`, no
drift and nothing to re-sync after a swap"*. **That property dies with the
second SD card.** `dosctl verify` today compares the box against the local
build with no notion of *which* box, so `verify` and `upgrade` have to become
box-aware in the same phase as identity, not in a later one.

### Cloning the card duplicates the identity

A cloned SD card carries the same `IPADDR` and would carry the same `BOXID`.
Two machines at one IP address on one LAN reads as *"the link drops frames"* --
which is precisely the misdiagnosis that cost this project weeks before mTCP
was used as an independent control.

So the clone-then-edit checklist is mandatory, and more usefully: `dosd` should
shout when an id polls from an address it is not registered at.

```
!! boxid v30 polled from 192.168.1.21 but is registered at 192.168.1.20
```

One line, and it converts the worst failure class here into an error message.

### The trap in `upgrade --agent`

`agent_addresses()` at `dosctl.py:357` exists because replacing `SET SRV=` /
`SET UPHOST=` with the template's values gives you, in `upgrade_agent`'s own
words, *"a machine that boots, never polls, and needs hands on it"*.

`BOXID` is now exactly that same class of fact. **Without extending that guard,
`dosctl upgrade --agent` overwrites each box's identity with the template's,
and you get two machines claiming one id** -- the clone footgun arriving by a
second route, from a command that is supposed to be routine.

The `BOXID` change to `AI.BAT` and the extension of `agent_addresses()` are one
commit, not two.

## dosd: the change list

Everything below is in `dosd.py`. The `State` class is where the single-box
assumption lives; the transport, per the table above, is already fine.

**Must become per-box:**

| | today | proposed |
|---|---|---|
| `State.pending` | one `queue.Queue` | one per box; `Job` carries `box` |
| `State.awaiting` | single slot | one per box |
| `State.awaiting_pull` | single slot | **keyed by job id**, see above |
| `State.last_poll` | one float | one per box; what `dosctl status` reads |
| `State.boot_events` | one list | tagged per box |
| `serve_job(sock, addr)` | name must equal `job` | parse the box out of the name; fall back to an IP lookup; fall back to the sole registered box |
| `/queue` POST | no box | accept `box`; refuse unknown; refuse ambiguous |
| `/status` | one machine | per box, plus a fleet summary |
| `log()` | untagged | **box id on every line** |

One `dosd.log` still. Interleaving is *informative* when both machines are
running the same test, which is the case that matters most. A per-box mirror
under `logs/<boxid>.log` is optional and cheap.

**Must not change: do not run two daemons.** The single-instance guard in
`tftp_listen()` exists because two daemons sharing one UDP port split a TFTP
transfer between two state machines, and every resulting symptom read as a
DOS-side or a wire fault. Adding boxes must not quietly walk that back.

## The registry, and why peripherals layer rather than duplicate

`boxes.json`, following the conventions `power.json` and `capture.json`
already set: never shipped in an installer, `_`-prefixed keys as comments,
absent means the feature is simply off.

```
{
  "default": "v30",
  "boxes": {
    "v30":   { "ip": "...", "desc": "NEC V30 + 8087",
               "capture": { "device": "..." },
               "power":   { "host": "..." },
               "expect":  { "cpu": "v30", "fpu": true } },
    "sx386": { "ip": "...", "desc": "Gateway 2000 386SX/25", ... }
  }
}
```

**The existing config files stay as the schema; `boxes.json` supplies
per-box overrides.** This matters. `capture.json` carries about twenty tuned
fields -- `rtbufsize`, `preset`, `warmup_frames`, `open_timeout` -- and every
one of them is a property of *the capture stick and this PC*, not of the DOS
box on the other end of it. Duplicating them per box guarantees they drift, and
the comments in `capture.example.json` explaining why `rtbufsize` is not a
tuning knob would then exist in one copy and not the other.

Genuinely per box: `device`, `audio_device`, `out_dir` for capture; `host` and
`channel` for power. Everything else -- `model`, `max_cycles`, `window_secs`,
`min_interval_secs` -- is policy and stays shared.

### The wrong-screen guard is the important one

With one capture stick, `doscap --box sx386` must fail with

```
no capture device is configured for sx386
```

and **must never show the V30's screen instead.** This is the most dangerous
peripheral failure in the whole design, because every visual verification in
this project's history would have been reasoned about confidently and wrongly
if the picture had come from the other machine: the magenta screen, the
see-through cars, the sun centroid at +4.5 then -3.4. A capture that silently
shows the wrong box does not produce a wrong answer, it produces a *convincing*
one.

`capture.py:199` already fails cleanly on "device already in use", so two
sticks need no new locking. `capture.py:403`'s `_audio_pidfile()` is a single
pidfile for the `ffplay` preview and does need a device dimension.

`power.state` must go per box as well, or the 386's cycles eat the V30's
rate-limit budget and the guard that stops a recovery loop stops guarding.

## dosctl: addressing, and the ambiguity rule

Resolution order for which box a command targets:

1. `--box ID`
2. the `DOSBOX` environment variable
3. a `.dosbox` file in the current project directory, so `projects/foo/` can
   pin itself to one machine
4. `default` in `boxes.json`
5. if exactly one box is registered, that one

Then the rule this project already learned from `files/`: **ambiguity is a hard
error listing the candidates, never a guess.** A bare `dosrun HELLO.EXE` that
silently picks a machine is the two-projects-one-`HELLO.EXE` bug again and
worse, because the result looks entirely fine -- it simply ran on the wrong
CPU, and nothing in the output says so.

**`dospower cycle` and `dosctl stop` should require `--box` explicitly even
when a default exists.** They are the two commands whose mistake needs hands on
a keyboard to undo.

## The fan-out is the actual prize

Everything above is plumbing. This is the reason to build it:

```
dosrun --box all PARALLAX.EXE SECS 5
dosctl verify --all
starter/test.cmd parallax --all
```

`CLAUDE.md` already *requires* that everything in `starter/` runs on both
machines -- "gate a faster path at run time, never at compile time" -- and that
requirement is today enforced by a human swapping an SD card and remembering.
`--box all` makes it mechanical.

Dispatch in parallel: different IPs, independent queues, and the daemon is
already threaded. Within a box, jobs stay strictly serialised for free, because
the per-box queue is drained by a machine that polls, CALLs one `JOB.BAT`, and
only then polls again.

Both faults the 386 ever found -- FPC's runtime hooking INT 10h, and
CH375Camera counting packets where it should have measured time -- were found
by moving machines and noticing a difference. **Surfacing that difference
automatically is the highest-value thing in this file.**

The output shape matters. Not two logs end to end; a table and then the diff:

```
                 v30          sx386
rc                 0              0
PARALLAX        33.6 fps     141.2 fps
8087           1067ms         (none)
--- output differs at line 14 ---
```

And `--requires fpu` / `--requires 386`, so a test that legitimately applies to
only one machine **skips the other with a stated reason** rather than failing,
or worse, being quietly omitted.

### Reservations

Two boxes, and possibly two sessions or two projects, means a long interactive
run on one machine should not have another job land in its queue partway
through. A lease held in `dosd` -- `dosctl claim v30 --for 30m`, `dosctl
release v30` -- refusing other holders with a clear message rather than
queueing behind them.

This is worth more than it looks. The failure without it is a job running
between two frames of somebody's visual test, with `doscap` catching it.

## KNET bites with no code change at all

`CLAUDE.md`, on the live remote keyboard: **"Keys must be BROADCAST."**

Two machines both running `KNET` means every keystroke goes to **both**. Typing
into the V30 also types into the 386, into whatever it happens to be running.

This is the only existing tool whose *correct* behaviour today becomes
*incorrect* the instant a second box is on the wire, without anybody changing a
line of it. It needs either a box id in the packet, filtered on the DOS side,
or unicast. Until then the rule is one `KNET` at a time and `dosctl` refuses a
second.

Check `starter/knet.asm`'s filter first in the peripheral phase. `KINJ` and the
mouse injection path are worth a look too, though INT 16h injection is local
and is probably unaffected.

## Running order

The order is forced by one fact: **an agent upgrade that goes wrong needs hands
on that machine's keyboard**, and that is true per box.

| phase | |
|---|---|
| **0** | **Hardware.** Second SD card, cloned then edited -- `IPADDR`, `BOXID`. Second static address outside any DHCP pool. Confirm both PicoMEM cards boot their machine. This is the gating purchase. |
| **1** | **Windows side only, one box, zero behaviour change.** `boxes.json` with a single box registered; per-box state inside `dosd`; `dosd` accepts **both** the bare `job` name and `job.<id>`, the bare one mapping to the sole registered box. Nothing on the DOS side moves. The acceptance test is that the bridge behaves exactly as it does now. |
| **2** | **Teach `simulate_dos.py` two boxes.** It speaks the real transport, and this project already knows what a simulator that only pattern-matches costs: the old one grepped for `HTGET` and kept passing while transferring nothing, during the very session the 513-byte bug was loose. Two simulated boxes polling and transferring concurrently, including a deliberate **concurrent-pull** case that fails against today's `awaiting_pull`. A bug found here costs a re-run; found on hardware it costs a trip to the keyboard. |
| **3** | **`pull.<jobid>` keying.** `dosd` only. Before a second machine is ever live. |
| **4** | **`AI.BAT`: `SET BOXID=` and the two resource names. One box at a time, with the other left alone as the control.** Extend `agent_addresses()` in the same commit. Keep the bare-name fallback in `dosd` for at least one release. |
| **5** | **Peripherals.** Per-box capture device and plug, the wrong-screen guard, per-box `power.state`, the `KNET` question. |
| **6** | **Fleet ergonomics.** `--box all`, the diff table, `dosctl boxes`, `verify --all` and its drift table, claims, per-box log tags. |
| **7** | **Installer.** `installer-src/client/makekit.py` writes `BOXID` into the kit. Cut a public release only after the dev tree has driven two machines for a while. |

## What not to build

* **Not a daemon per box.** The `TFTP_PORT` constant settles it; see the top of
  this file.
* **Not a generic scheduler or a job database.** Two to four machines on a LAN.
* **Not per-box namespacing under `files/`.** The same binary running on both
  machines is the entire point of the fan-out; a box dimension in staging would
  make the comparison meaningless by construction.
* **Not automatic failover** -- "run it on whichever box is free". These
  machines are not interchangeable. *Which one ran it* is the single most
  important fact about any result they produce.

## Risks, ranked

1. **A silent wrong-box result** -- a pull, a capture or a job that lands on the
   other machine and looks completely normal. Mitigated by: explicit ambiguity
   errors, per-job pull keying, the source-IP cross-check on every poll, and the
   box id on every log line and in every result header.
2. **Duplicate identity from a cloned SD card**, which presents as a flaky link.
   Mitigated by `dosd` shouting when an id polls from an unregistered address.
3. **`upgrade --agent` clobbering `BOXID`.** Mitigated by extending the guard
   that already protects the addresses.
4. **Drift between two `C:\TOOLS`.** Mitigated by `verify --all` and a drift
   table, run as routine rather than as a special occasion.
5. **`KNET` broadcast reaching both machines.**
6. **Power-cycling the wrong machine.** Mitigated by requiring an explicit
   `--box` and by per-box rate limits.
7. **One box's outage reading as a fleet outage** in status and in the log.
   Mitigated by per-box liveness and a two-column status board.

## Two questions to settle before phase 5

Neither of them blocks phase 1, and both should be answered before the
peripheral work starts.

1. **Does the second machine get its own capture stick and smart plug, or do
   those stay on whichever box is under test?** The second is cheaper and
   honest; the first is better. It decides whether the peripheral layer is
   per-box configuration or a "where is the capture pointed right now"
   declaration.
2. **Do both machines keep running one identical `C:\TOOLS` build?**
   Everything in `CLAUDE.md` says yes -- one binary, gated at run time. While
   that holds, `verify --all` is a drift alarm and the staging model never needs
   a box dimension. It is worth resisting any pressure to change it.

## Status (2026-09-21)

**Built, and verified on both real machines.** The V30 and the 386SX poll one
`dosd` simultaneously and are addressed independently. What was actually run,
rather than what was expected to work:

| | |
|---|---|
| both boxes polling at once | `dosstatus` shows two rows alive, log lines tagged `[v30  ]` and `[sx386]` |
| addressed jobs | `dosexec --box v30 VER` and `--box sx386 VER` each return `MS-DOS Version 6.22`, rc 0 |
| **fan-out** | `dosrun FPU.EXE --box all` -- one binary, both machines, in parallel. The table named the difference: `NEC V20/V30` + Intel 8087 against `80386 or later` + none, which is what `boxes.json` says to expect of each |
| **concurrent pulls** | two `dospull C:\AI\NET.CFG` at once returned **each machine's own file** -- `IPADDR 192.168.1.20` to the V30, `.67` to the 386SX. This is the case that silently returned the other box's bytes before the pull was keyed on the job id |
| **drift** | `verify --all`: 41 tools checked per box, and the two are **byte-identical to each other** on all 33 that differ from the current local build, with `PARALLAX.EXE` missing on both. No drift between the machines; both are simply still on the 2026-09-19 deploy |
| identity cross-check | no `!!` lines. Both poll untagged and both match by address, which is the routing path a box with no `BOXID` takes |

Getting there needed a host-side fix that had nothing to do with any of this
-- see *The firewall* below.

| phase | |
|---|---|
| **0** Hardware | **not needed.** There are two SD cards already; both machines boot and are on the LAN at `.66` and `.67` |
| **1** Windows side, per-box state | **done.** `boxes.py` + `boxes.json`; `State` keyed per box; `dosd` accepts `job` and `job.<id>` |
| **2** Two simulated boxes | **done.** `simulate_dos.py --box=ID --from=ADDR`, two of them concurrently in `selftest.py` step 7 |
| **3** `pull.<jobid>` keying | **done**, and the concurrent-pull case is a regression test that fails if it is reverted |
| **4** `SET BOXID=` in `AI.BAT` | **written, not deployed.** See below -- it turned out not to be needed to get two boxes working |
| **5** Peripherals | **done.** Per-box capture and plug, the wrong-screen guard, per-box `power.state` |
| **6** Fleet ergonomics | **done.** `--box all`, the diff table, `dosctl boxes`, `verify --all`, per-box log tags |
| **7** Installer | **not done**, and deliberately: nothing ships until the dev tree has driven two real machines for a while |

Not built, and still worth building: **reservations** (`dosctl claim`), and
the **`KNET` broadcast** problem, which remains exactly as described above --
one `KNET` at a time, by hand, for now.

**Also not built: the MEASURED identity check** -- layer 3 under "Identity"
above. `expect` in `boxes.json` is parsed by `boxes.expectations()` and read
by nothing. It was listed as the guard that catches "the SD card having been
moved to the other machine", and **on 2026-09-25 exactly that happened and
nothing noticed.** The 386SX's SD card went into the V30 with a PicoMEM 1,
so the V30 booted the 386's `NET.CFG`, polled from `.67`, and was routed as
`sx386` for hours. `FPU.EXE` said `NEC V20/V30` against an `expect` of
`386`, and no warning was printed anywhere. It cost one wrong power cut:

* **A box id follows the SD card; a smart plug follows the machine.**
  `dospower cycle --box sx386` switched the 386SX's plug (`.205`) -- a
  machine with no card in it, so nothing was lost -- while the V30 sat
  unchanged. The V30's plug was `--box v30`, the id whose SD card was not in
  it. `doscap` has the same split in the other direction: the capture stick
  is wired to the V30, so `doscap` (default `v30`) showed the right screen
  only because the V30 is the only machine it can see.

Until the check exists: **after any card or SD swap, run `FPU.EXE` and
`PMINFO.EXE` on the box and compare with `dosctl boxes`**, and pick a plug by
the machine it is plugged into, not by the id the box is polling as. Building
it is small -- one `FPU`/`PMINFO` job on the first poll after a box goes from
stale to alive, compared against `expect`, and a loud line in the log and in
`dosctl status` on a mismatch.

### The finding that made phase 4 optional

**Routing on the source address alone is enough**, and that was not obvious
when the running order was written. Phase 4 -- putting `SET BOXID=` on each
machine -- was assumed to be the step that made two boxes possible, and it is
the one step that risks a trip to a keyboard.

It is not. `dosd` resolves a poll in three steps: the id declared in the
resource name, then the source address, then the sole registered box. Every
agent built before this change polls for the bare name `job` from a fixed
address, so `boxes.json` alone routes both machines correctly **with nothing
on either DOS box touched at all.** No recompile, no agent swap, no reboot,
no keyboard.

So the `BOXID` work is still worth doing and is written -- `dosctl upgrade
--agent` stamps each box's id from `boxes.json`, and `agent_boxid()` refuses
to rename a box that already has one -- but it buys the *cross-check* rather
than the routing. A machine that says who it is AND polls from where it
should be lets `dosd` shout when those two stop agreeing, which is what a
moved or cloned SD card looks like. That is worth having and it is not worth
a keyboard trip to get, so it lands with the next agent upgrade rather than
on its own.

### What the implementation changed from the proposal

* **`ip` may be the string `"any"`.** The proposal made the address
  mandatory. A simulated box has no fixed address, and a box on DHCP has
  none either. `"any"` opts out of the cross-check and is excluded from the
  duplicate-address refusal; such a box must declare a `BOXID`, because
  nothing else can tell it from another.
* **`--all` is not an argparse flag**, and must never become one. `dosctl`
  derives its flag list from the parser in order to split its own options
  out of the DOS command tail, so registering `--all` there would lift it
  out of the tail -- and `clean --all` reads it *from* the tail. It is the
  `--quiet` trap in reverse: there, a flag missing from the list fell
  through to the DOS box; here, a flag added to it would be stolen from the
  command that already owns it.
* **`poll_age()` exists**, and nothing in the proposal predicted it.
  `/status` still carries a top-level `last_poll_secs_ago` so an old
  `dosctl` can read a new `dosd`, and it is the newest poll from *any*
  machine. Every liveness wait -- `dosreboot`, `upgrade --agent`, `stop` --
  used to read exactly that field. Left alone, watching one box reboot would
  have read the *other* box's polls: a machine that never came back would be
  declared healthy within two samples and the rollback instructions would
  never print. Per-box liveness is not a display nicety, it is load-bearing.
* **Two simulated boxes need two ADDRESSES**, not just two ids --
  `--from=127.0.0.2`, a loopback alias Windows accepts unconfigured. The
  transport's in-flight flow registry is keyed on the source IP, where a new
  request for a file already being sent to that address deliberately
  supersedes the older transfer, because that is how a stalled one recovers.
  Two boxes on one address therefore cancel each other's fetches whenever
  they ask for the same file at the same moment -- which is precisely what a
  fan-out does. It cost one confusing failure in `selftest` step 7e before
  it was understood.
* **`selftest.py` was silently strangling its own children.** Both `dosd`
  and the simulated box were spawned with `stdout=PIPE` and nothing ever
  read those pipes, so after about 8 KB a child blocked on its next `print`
  and simply stopped being a DOS box. The simulator dumps a whole `JOB.BAT`
  per job, so that took three or four jobs -- and the symptom was a job
  timing out several steps into the run with the daemon looking perfectly
  healthy, which is indistinguishable from the transport faults the test
  exists to catch. Output goes to files now, and the paths are printed on
  failure. This was live before any multi-box work and would have wasted
  somebody's afternoon eventually.

### The firewall, and why two boxes failing at once is a gift

Both machines stopped being heard at 13:48 on 2026-09-21 and stayed silent
through a reboot, a power cycle and a daemon restart. Neither was broken.

* the LAN interface holding this PC's address is on the **Private** profile
* the only inbound Allow rules for `python.exe` are scoped to **Public**
* `DefaultInboundAction` is `NotConfigured`, which means block

so every poll was dropped before `dosd` could see it. `netstat` showed the
daemon bound to `0.0.0.0:8069` the whole time, and the boxes' own screens
showed a healthy agent banner, so both ends looked fine and the wire between
them was doing the damage.

**Two machines failing identically at the same moment is the tell.** They
share exactly one thing, and it is this host. That should be the first
thought, not the last -- it is the same lesson as running mTCP as an
independent control, arriving from the other direction: when an independent
second client fails in the same way, the fault is in what they have in
common.

The instrument that settled it is worth keeping too. `ping` proves nothing
here -- nothing on the DOS side answers ICMP -- but **sending a UDP datagram
to the box forces this host to ARP for it**, and
`netsh interface ipv4 show neighbors` then reports `Reachable` if the box's
own stack answered. Both boxes read `Reachable` while `dosd` was hearing
nothing at all, which separates "the machine is dead" from "the machine is
talking and we are not listening". Note `arp -a` cannot express this: it
prints a `dynamic` entry for an address whose neighbour state is
`Unreachable`, which is how the right hypothesis was discarded once before.

`dosfirewall.cmd` adds the rules, scoped to the boxes' subnet and to the
ports rather than to `python.exe` -- port rules survive a Python upgrade,
and a program rule would open every Python program on the machine.

### One thing still unexplained, and it is the signal that would have helped

Both boxes resumed polling **by themselves** the moment the rules were added
-- no reboot, no keyboard, nothing touched. They had been healthy in the
offline retry loop the whole time.

So the V30's screen was telling the truth and I misread it. It showed a
healthy agent banner and **no `[offline]` line**, after many minutes of polls
that could not possibly have been answered, and I took the absence of any
change on screen as a wedge and power-cycled a machine that was working.
`AI.BAT` prints `[offline]` on the second consecutive failed poll and it
would have stayed on screen; it was not there. Either the box is not reaching
`:OFFSAY`, or it is not failing polls the way the batch expects.

That is worth fixing rather than filing, because **the missing line is
exactly the signal that distinguishes "cannot reach the server" from "hung"**
-- the one question the screen exists to answer, and the one that cost a
needless hard power cut here. The `UGET`-is-silent-on-a-failed-POLL change
that made the console restful may have taken the evidence with it.

The power cycle did settle one thing by accident: the V30 went through POST
and all the way back to the agent banner **without stopping at F1**, which
`docs/hardware.md` says it should have done. Either the CMOS fault is
intermittent or something has changed since 2026-09-03. Worth re-reading that
section before relying on either behaviour.
