# This machine: CPU, coprocessor, CMOS, power and capture

What the hardware actually is and how to ask it, including the two
recovery levers -- the smart plug and the capture card.

Split out of `CLAUDE.md`, which keeps the summary and the pointer here.

## Portability, and the `Cpu` unit

Everything is compiled `-Pi8086` and sticks to the plain 8086 instruction set,
so a binary built here loads on any DOS box. That is deliberate and should stay
that way: a program that will not run on the machine at the other end is worse
than one that runs slower.

`starter/cpu.pas` is how to go faster without giving that up.

```pascal
uses Cpu;

CpuClass   { cpu8086, cpuNecV, cpu186, cpu286, cpu386 }
CpuName    { 'NEC V20/V30', 'Intel 80286', ... }
Has186     { the 80186 instruction-set extensions are safe to execute }
```

**`Has186` is the gate for any CPU-specific code.** The NEC V20/V30 and the
80186 add instructions the 8086 lacks — shifts by an immediate count, `IMUL`
with an immediate, `PUSHA`/`POPA`, `ENTER`/`LEAVE`, string I/O. Executing one
on an 8086 is an invalid opcode. So: write the portable version, write the fast
version, choose between them with `if Has186`, and never delete the portable
one. Emit the non-baseline instruction as `db` bytes — the assembler targets
the 8086 and is right to reject it as source. `BENCH` does this for immediate
shifts and prints both numbers, which is the place to check whether a fast path
is worth writing at all.

The probe runs three tests in an order that matters: FLAGS bits 12-15 to split
8086-class from 286 from 386+, then the undocumented `AAD` opcode to split NEC
from Intel, then shift-count masking to split 8086 from 186. The shift test is
last because sources disagree about whether the V20/V30 masks shift counts, so
the probe never asks it that question. Two steps have now been run on real
hardware: `AAD` on the V30, and the FLAGS split on a **Gateway 2000 386SX/25**,
which reports `cpu386` with `Has186` true and the immediate-shift path taken.
A 186 or 286 result is still unconfirmed.

`SYSINFO` and `HWINFO` both report `CpuName`, so the answer costs one round
trip.

## The math coprocessor

**The V30 box has an 8087 fitted, confirmed on the hardware 2026-09-20 and
by its owner.** Everything below was written when it had none, and the
warnings are all still exactly right -- they are about what happens on a
machine *without* one, which is the case the code still has to survive. What
changed is that this machine is no longer that case, and the `HasFpu` paths
run here for the first time.

`FPU /T` passes all seven arithmetic tests, including the FDIV round-trip and
the zero-divide flag, with a control word of `03FF` -- an 8087, not a 287 or
later. `BENCH` prints its four coprocessor rows here now:

| | software | 8087 |
|---|---|---|
| 32-bit multiply | 11,484/s | **61,661/s** |
| 32-bit divide | 6,916/s | **34,361/s** |
| FPU add | -- | 71,780/s |
| FPU sqrt | -- | 42,460/s |

So x87 arithmetic is about **five times** the software 32-bit routines on
this machine. That does **not** overturn the advice in the performance
section, and the reason is worth keeping: `FRACTAL` ran its integer loop at
108 rows in 73 ticks against the 8087's 60 rows in 76 -- the integer path is
nearly twice as fast. It wins because it is Q8 fixed point in **16-bit**
`IMUL`, which never used the slow software routines in the first place. The
8087 beats software 32-bit maths; it does not beat good 16-bit maths.

**`docs/raycast.md` got there first and put it more sharply**, in the
section "Casting in assembler ... and the 8087 stops being worth it": FILD,
FDIVR, FISTP and FWAIT go through memory in both directions and cost about
300 cycles against a 16-bit `DIV`'s 90. Its table is `FPU` 10.1 fps against
`INT` 10.5; re-measured 2026-09-20 on a fresh V30 run, 9.8 against 10.1.
The ordering and the margin both hold.

**That section and this one used to contradict each other, and the
contradiction is worth remembering rather than just deleting.** This file
said the machine had no coprocessor; the raycaster notes were measuring one
and reasoning carefully about when it was worth using. Both were written
honestly and one of them was stale -- and nothing in either file could tell
you which, because neither cited a date or a probe. `FPU.EXE` settles it in
one run and always could have. **When two documents disagree about the
hardware, run the probe; do not pick the one that reads better.**

**The probe itself is unaffected**, and it is worth saying why it was never
in doubt: it seeds the status word and reads it back, so it reports what is
fitted rather than what anyone expected. It said `no coprocessor` for as long
as there was none and `Intel 8087` the moment there was one, with no change
to the code.

Same unit, same rule, but the failure mode is nastier:

```pascal
HasFpu       { a coprocessor -- or an emulator -- is there }
FpuClass     { fpuNone, fpu8087, fpu287, fpu387 }
FpuName      { 'Intel 8087', '80387 or later', 'none' }
FpuCw, FpuSw { control and status words straight after FNINIT }
```

**An x87 instruction with no coprocessor fitted does not fault on an 8086.**
The CPU decodes the ESC opcode, runs a dummy bus cycle, and carries on — so
the code runs and quietly produces garbage. Nothing reports it. Every tool and
demo in `starter/` therefore stays on the integer path regardless of what is
fitted; `FPU.EXE` is the only program that executes an ESC opcode, and even it
checks `HasFpu` first.

Three things in the probe must not be "simplified":

* **`FNINIT`/`FNSTSW`/`FNSTCW`, never the un-prefixed forms.** `FINIT` and
  friends assemble a `WAIT` (9Bh) in front, and `WAIT` with no coprocessor
  waits on the TEST pin forever. That hangs the box, and over the bridge a hang
  looks like every other hang — it needs hands on the keyboard. FPC emits the
  FN forms verbatim; the probe in the linked binary is
  `DB E3 / B9 14 00 / 49 / 75 FD / DD 3E / D9 3E`, checked byte by byte, no 9Bh.
* **Seed the status word with `5A5Ah`.** With no coprocessor nothing writes
  back, so the seed survives; reading 0 is what proves something answered.
* **Delay between `FNINIT` and the store.** The 8086 does not interlock with
  the 8087 and can reach the store first.

Generation comes from control-word bit 7 — the 8087's Interrupt Enable Mask,
which `FNINIT` sets, giving `03FFh`; a 287 or later dropped the bit and gives
`037Fh`. A software emulator on INT 7 is indistinguishable from silicon here,
and `FPU.EXE` says so rather than overclaiming.

`HWINFO` also decodes equipment-word bit 1, the BIOS's own opinion, and prints
`** MISMATCH` when it disagrees with the probe.

**This box is exactly such a case, confirmed on hardware 2026-08-30.** Its
equipment word reads `4223`, which has bit 1 set -- the BIOS claims a
coprocessor is fitted. `FNINIT` says there is none, and there is none:

```
    coproc bit     : yes   (BIOS opinion; probe says none)
    ** MISMATCH    : equipment word and FNINIT probe disagree
```

Believe the probe. The equipment bit is stamped by POST from a jumper or a
strap and is simply wrong on plenty of clones. This matters because reading
that bit is the *obvious* way to detect a coprocessor and it is what a lot of
period software does -- trust it here and you execute x87 on a machine with no
coprocessor, which on an 8086 does not fault. It quietly computes nothing.

**The 8087 is worth using, and the earlier guidance here was wrong.**
**...and see the raycaster section below, where this conclusion inverted
again once the thing it was compared against got 15x faster.** Measured
2026-09-01, against the integer paths in the same run:

| | |
|---|---|
| 8087 vs **16-bit** integer | a wash — 61661 against 60660 multiplies/sec |
| 8087 vs **32-bit** `LongInt` | **5.6x faster** — 61661 against 10920 |
| 8087 divide vs `LongInt` divide | **5.0x faster** — 34361 against 6916 |
| `FSQRT` | 42460/sec, with no integer equivalent at all |

So: anything using `LongInt` arithmetic is a strong candidate, and gets full
64-bit double precision for free. Anything already in 16-bit fixed point gains
nothing in throughput — but can trade that even swap for far more precision,
**`fractal.pas` now carries both loops**, chosen at run time:

```
FRACTAL                 use the 8087 if fitted, else Q8 integer
FRACTAL INT             force the integer path
FRACTAL FPU             force the 8087 (refuses if none is fitted)
FRACTAL ZOOM 300 SECS 45    deep zoom -- needs the coprocessor
```

Measured on this box: the Q8 path completes all 200 rows in ten seconds, the
8087 path manages 124. **The coprocessor version is slower**, and that is not a
contradiction of the `BENCH` figures above -- the multiply rates are near
identical, but the x87 loop keeps its values in memory and pays for a
load/store per operation, plus an `FSTSW`/`FWAIT` round trip for every escape
test. It buys precision, not speed.

Precision is the whole point of `ZOOM`. Q8 resolves 1/256, so past ~100x the
window is narrower than one fixed-point step and the picture collapses to flat
blocks; the integer path refuses `ZOOM` for that reason rather than drawing a
lie. Two things learned finding a zoom target worth looking at: every point on
the **real axis** is solidly inside or outside the set, so magnifying the cusp
or the Feigenbaum point just fills the screen with one colour (both tried, both
flat black at 200-400x). The structure is on the boundary and the boundary is
**off-axis** -- so zoomed runs use seahorse valley and give up the mirror,
drawing all 200 rows for a picture that is actually worth looking at.

Two caveats that have not gone away. **Gate it on `HasFpu`** — this suite is
built for machines that may have no coprocessor, and x87 arithmetic carries
`WAIT` prefixes that hang hard when nothing answers. And **`FPU /T` is opt-in**
for the same reason: a probe wrong in the optimistic direction turns a
diagnostic into a machine somebody has to walk over to.

## The 386SX's BIOS will not take a date past 2010

**A hardware ceiling, not a fault to fix.** The BIOS on this machine is
dated 03/25/92 and its setup screen refuses any year later than 2010, so
every file the box writes is stamped around sixteen years before the fact.

Worth stating plainly because the obvious reading is that its clock has
drifted and wants correcting. It has not, and **the `SNTP -set` fix that
straightened the V30's clock does not apply here** -- the BIOS will not hold
the year, so whatever DOS manages to write to the RTC is good until the next
cold boot at best. Attempting it wastes a trip and leaves the same dates.

Consequences, both small:

* **Never compare file dates between the two machines.** One is roughly
  right and the other is far out, so a side-by-side `DIR` makes the 386SX's
  files look ancient no matter when they were written. That is the only way
  this misleads anybody.
* **Nothing in the bridge depends on it.** `dosctl upgrade --tools` decides
  what to send by comparing sizes, `verify` compares CRC-32, and neither
  reads a timestamp. `parse_dos_dir` matches the date field only to locate
  the columns either side of it, and a two-digit year of `10` parses like
  any other.

## The second box: a Gateway 2000 386SX/25, measured

`BENCH` on the **Gateway 2000 386SX/25** (no 387), 2026-09-19 -- the PicoMEM 1
was in the machine at the time, which makes no difference here because `BENCH`
never touches the card --
against the V30 figures in
`CLAUDE.md`. Both machines have no coprocessor, so the four x87 rows print
`skipped` on each.

| | V30 | 386 | |
|---|---|---|---|
| loop + increment | 88,961 | 458,021 | 5.1x |
| 16-bit add | 72,800 | 385,221 | 5.3x |
| 16-bit multiply | 58,640 | 288,160 | 4.9x |
| 16-bit divide | 52,561 | 248,721 | 4.7x |
| 32-bit multiply | 10,920 | 48,521 | 4.4x |
| 32-bit divide | 7,280 | 30,321 | 4.2x |
| array[] store | 68,322 | 307,507 | 4.5x |
| procedure call | 46,501 | 197,160 | 4.2x |
| shl by CL | 185,021 | 1,028,300 | 5.6x |
| shl by immediate (186) | 206,260 | 1,108,671 | 5.4x |
| MemW[] to B800 | 58,640 | 297,260 | 5.1x |
| REP STOSW to B800 | 439,821 | 1,823,021 | 4.1x |

Roughly **four to five times the V30** across the board, and the two ratios
the tuning advice rests on are unchanged: 32-bit arithmetic still costs 5-8x
its 16-bit equivalent, and `REP STOSW` still beats per-element `MemW[]` by
about 6x. The immediate shift is 8% faster than going through CL here, against
11% on the V30 -- still not worth a gated fast path on its own.

## The runtime hooks INT 10h, and on a 386 with no 387 that kills the machine

**Found 2026-09-19, on the second box: a Gateway 2000 386SX/25 with a PicoMEM
1, running the same boot disk image as the V30.** Every Free Pascal tool that touched the screen
froze it solid, printing nothing at all -- `HWINFO`, `VMODES`, `VSHOT`, and
`UGET` at the keyboard, which is how it presented: `AI.BAT` stopped dead after
its `server` line and the box never polled. A hand-assembled 35-byte `.COM`
doing the same `INT 10h AH=0Fh` returned mode 3 perfectly on that machine,
which is what finally separated the machine from our software.

**What it is.** FPC's i8086 runtime installs a coprocessor-error handler at
startup, and it puts that handler on **INT 10h** -- the video BIOS vector --
as well as on INT 00h and INT 75h. `VECX` read it back:

```
INT 00 -> 1476:008E   in this program    (divide by zero)
INT 10 -> 1476:00CA   in this program    <-- video BIOS, hooked
INT 75 -> 1476:0111   in this program    (IRQ13 coprocessor error)
```

The handler begins `DD 3E` -- `FNSTSW` -- reads the x87 status word, and if
bit 7 says an exception is pending it raises a runtime error instead of
chaining to the video BIOS. With no coprocessor fitted that read is
meaningless, and **what it returns is not the same on every CPU**:

| | |
|---|---|
| 8086 / V30, no 8087 | nothing drives the bus, the word stays 0, the stub chains, all is well |
| 386, no 387 | the word reads back with bit 7 set, the error path is taken, the call never reaches the BIOS |

So the same binaries that have run on the V30 for months cannot make a single
video BIOS call on the 386. It is not a 386 instruction problem and not a
memory-model problem: both were measured and excluded first.

**The fix is `starter/vidfix.pas`**, pulled in by `About` so every tool that
prints a banner gets it, and added by hand to `UGET` and `UPUT`, which
deliberately have no banner. It carries its own coprocessor probe rather than
`uses Cpu`, so it is ONE drop-in file: the same unit is copied into
`CH375USBTOOLS/src` and pulled in there by `chtool`, which every CH375 program
uses, with the handful that bypass `chtool` naming it themselves. In its initialization -- which FPC runs before
the program body, so before any video call -- it acts only when ALL of:

* `Cpu.HasFpu` is false, so the handler cannot have real work to do;
* INT 10h points into RAM rather than ROM, which the real BIOS never does
  -- the first version tested "inside the running program's code segment"
  and was wrong, because a large-model program has SEVERAL code segments
  and in a big binary the stub sits in a different one from the unit
  doing the checking.  `CAMLIVE` found INT 10h at 5238:0202, concluded
  nothing had hooked it, and froze on its first video call anyway;
* the bytes there are the stub's prologue and start the body with `FNSTSW`;
* the address the runtime saved can be read back out of the stub and is in
  ROM (C000 or above).

Then it puts that address back. On the V30 the second test fails, so the unit
is inert and the same binary is correct on both machines. The saved address is
not inline: the stub's chain path copies two words out of the runtime's data
segment over the return address and IRETs, so the unit takes the data segment
from the `mov bp,imm16` in the prologue and reads the two words that pattern
names. On the 386 it recovered `C000:729B`, the card's video BIOS.

**Three things this cost, worth not repeating:**

* **Four wrong theories, each measured and dropped**: bad RAM (`MEMCHK` passed
  all 29 pieces with four patterns), corrupt downloads (a 128 KB file
  round-tripped byte-identical), the large memory model (a large-model
  `WriteLn` program ran fine over the bridge), and the `Dos` unit (a
  large-model program using it ran fine).
* **The evidence had to survive the crash.** These programs print nothing,
  because FPC's output sits in a buffer when the machine dies -- even on
  stderr. The probe that answered it wrote each step to a FILE and closed it
  each time, so the log could be read after a power cycle. Its last line named
  the call that never returned.
* **`dosctl upgrade --tools` re-broke the box** by deploying tools built
  before the fix, and the agent's own `UGET` was among them, which takes the
  bridge down with it. When the fix is in the tools themselves, upgrade the
  transport last, or check the binaries carry it first: `coprocessor, and the
  stub` appears in every fixed EXE.

## Code in upper memory runs about 2.4 times slower

**Measured 2026-09-27.**  On the V30 the upper memory blocks (C800h and
D800h) are RAM on the PicoMEM card, reached over the 8-bit ISA bus.  Data
there reads at ~89% of the PC's own RAM (`PMBENCH`), but **code** fetched
from it is far slower: the same console driver, the same test, loaded into
each by `extras/ansisc/bin/ANSITEST.EXE`:

| characters per second, INT 29h | conventional | upper memory |
|---|---|---|
| MS-DOS 6.22 `ANSI.SYS` | 1,826 | 1,359 |
| ANSISC | 9,743 | 4,059 |

So `DEVICEHIGH`/`LH` trades speed for conventional memory on this machine,
and a driver whose code runs constantly -- the console, the packet driver
(`PM2000`), the EMS driver -- pays it on every call.  `ANSISC` is loaded low
for that reason.  Whether `PM2000` and `PMEMMSC` would gain from the same was
not measured.

## The CMOS battery is dead, and it breaks power-cycle recovery

**Found 2026-09-03.** The box's clock reads `01-01-80 12:08a` a few minutes
after boot, and POST stops with **"Press F1 to continue"** waiting for a
keypress.

**It is probably NOT a flat battery, and the first version of this section
said it was.** Running the PS/2 utility at the keyboard showed the RTC holding
`09-03-2056` -- the correct month and day, today's, with only the year wrong.
A dead battery loses everything; a chip that keeps the date and drifts the
year is one that still has power. What fits is a corrupt CMOS *configuration*
record: that is what halts POST, and what makes the BIOS hand DOS nothing
usable so DOS falls back to `01-01-80` while the RTC itself still knows the
day.

It is also the same fault recorded on 2026-08-31 -- "month, day, hour and
minute all correct, only the year wrong" -- drifted further. On a PS/2 the
repair is *Set Configuration* from the Reference Diskette, not a CR2032.

The POST code distinguishes them and costs nothing to read: **161** is the
battery, **162** a configuration/checksum error, **163** time and date not
set.

This file said on 2026-08-31 that "the CMOS battery is fine and the year had
simply never been set", on the evidence that a *warm* reboot preserved the
time. That test could not distinguish the two: a warm reboot never re-reads
CMOS. Only a power cut does, and the first one was months later.

**So the smart plug cannot currently recover this box unattended**, which is
the one thing it exists for. A hard cut runs POST, POST halts at F1, and the
machine sits there drawing ~37 W and never polling -- indistinguishable over
the bridge from the hang it was cutting power to fix. Twice on 2026-09-03 a
cycle was scored as "box did not come back" when it was really sitting at the
prompt.

Until the battery is replaced:

* Read a failed recovery as "check the screen", not "the machine is dead".
* `dospower status` still separates *off* from *powered*, which is the half
  that still works: ~37 W and no polling now means POST, not a wedge.
* A warm `dosreboot` does not trigger it. Prefer it over a power cut whenever
  the box is still answering.

**On 2026-09-25 a cycle of the V30's plug came straight back**: DOS,
the packet driver and the agent banner on `doscap` inside a minute, no F1
prompt. One success is not a cure -- it was running the 386SX's SD card
and a PicoMEM 1 that day, and whether POST halts may depend on what the
BIOS finds -- but it is no longer "a cycle never recovers this box". Still
check the screen before scoring a cycle.

Note this is entirely separate from the mid-run freezes. Those happen on a
machine that has already booted and is polling, and nothing about POST
explains them.

## Recovering a box that cannot be reached: the smart plug

Optional, and off unless configured. Every unrecoverable failure this project
has hit ends the same way -- "needs hands on the keyboard" -- because the
thing that would have to act is the thing that is not running: a driver that
hangs before the network is up, a leaked packet driver handle, a PicoMEM card
that freezes during POST. A switched plug is the one lever left.

```
dospower                      state, power draw, and how many cycles are left
dospower on | off
dospower cycle [--force]      off, wait, on
dospower reset                forget the cycle history
```

Verified on hardware 2026-09-03 against a Shelly Plug US Gen4
(`S4PL-00116US`, fw 2.0.0): two real cuts, and the box was **polling again 21
and 29 seconds after power returned**, answering `dosexec "VER"` immediately
after.

**The 386SX has its own plug as of 2026-09-22**, the same model and
firmware, set as a per-box override in `boxes.json`
(`"power": { "host": ..., "channel": 0 }`) so `dospower --box sx386` switches
it and `--box v30` still switches the original. `dospower status` reads it
correctly.

**A cut recovers the 386 unattended**, unlike the V30: cycled 2026-09-22 at
22:24:43 with a 6 s off, polling again at 22:25:56 -- **about 70 s after
power returned**, against the V30's 21-29 s. `dosctl`'s own wait after a
cut (`_watch_box`, 420 s) covers that with room to spare; a hand-rolled
wait tuned on the V30 would not. Afterwards
`VER`, `FPU` (none, rc 1 as expected), `VIDCHK` (colour) and `HWINFO` were
all normal, and `PHASE.LOG` carried straight on.

Watch the watts, not only the relay. The plug read **~31 W before** the cut
and **~82-85 W after**, flat, while polling normally. The most likely reason
is that something else on the same outlet, most likely the monitor, was in
standby before and came up on the cold boot. So "how many watts" has no
single healthy value for this box. Find out what shares the outlet before
reading a wattage as a fault.

**It is off by default and the installer cannot turn it on.** `power.py` and
`power.example.json` ship; `power.json` does not, and with no such file every
entry point returns "not configured" and no code can reach a relay. Same rule
as `MTCP.CFG`: a kit that arrived carrying somebody else's plug address, or
that overwrote a working local config on upgrade, would be worse than not
having the feature.

**The guards are the feature, not the on/off.** A recovery that can loop is
worse than none -- a box that will not come back for a reason power cannot
fix (a bad `AUTOEXEC.BAT`, a dead PSU, an unplugged aerial) would otherwise
be cut every couple of minutes, forever, with nobody watching.

| | |
|---|---|
| `min_interval_secs` | refuse a second cycle too soon. `--force` overrides |
| `max_cycles` / `window_secs` | hard ceiling. `--force` does **not** override |

That asymmetry is deliberate. Being asked twice in a minute is impatience,
and a human typing `--force` settles it. Hitting the ceiling means power has
already failed to fix this three times, and the honest conclusion is that it
is not going to -- so passing it needs somebody to think, not a flag.

Both limits are counted in `power.state` **on disk**, so they survive a
`dosctl` re-run in a loop or from a shell script. Holding them in memory
would make them trivially defeatable by the exact mistake they exist to
prevent.

`dosreboot` and `dosctl upgrade` use it automatically when `"auto": true`:
`wait_for_box` cuts power and waits again if the box never returns, bounded
by those same limits. The retry after a cut skips the wait-for-it-to-go-down
phase (`assume_gone`), because after a power cut the box is certainly down
and watching for that would burn the whole budget before the useful waiting
started.

**Read the power draw, not just the relay state.** `dospower` reports watts,
and that is the part worth having: it separates a machine that is *off* from
one that has power and has *hung*, and those need opposite responses. This
box idles at about 38 W.

```
plug    : shelly at 192.168.1.30
device  : S4PL-00116US gen4 fw 2.0.0
state   : ON  38.1 W  124 V
          drawing current, so the machine has power
cycles  : 0 in the last 60 min (max 3)
```

Other drivers exist and are **unverified** -- written from published local
APIs, never run against hardware, and they say so the first time they are
used: `shelly-gen1`, `tasmota`, `kasa` (not HTTP -- length-prefixed JSON over
TCP 9999 with an autokey XOR seeded at 171), `homeassistant` (worth having
because it covers hardware with no usable local API of its own), and `http`,
where you supply the URLs so an unsupported plug is a config entry rather
than a code change.

Two things learned wiring it up, both the same shape as failures recorded
elsewhere in these notes:

* **Check the guards before printing the warning.** The "this is a HARD cut"
  banner printed first, so a *refused* attempt still told you the machine had
  just been power-cycled when nothing had happened.
* **`dosctl power cycle` silently ran `status`.** The action was read from
  `args.rest`, which is always empty: the parser only ever sees the first
  passthru word, and the rest lives in `tail`. Every action read as the
  default. The same class of bug as `--quiet` falling through into the
  command tail.

## Seeing the box for real: video capture

Optional, off unless configured, and the first thing here that does not look
at the DOS box **through DOS**. **`capture.md` is the full write-up** --
setup, watching it live, the raw `ffplay` command, and troubleshooting. What
follows is the part worth knowing without going there.

```
doscap devices                what capture hardware is on this machine
doscap modes                  what the configured device can produce
doscap status                 device present? is a picture arriving?
doscap shot [FILE]            one still
doscap rec SECS [FILE]        record. --audio, --shots N
doscap burst N [--every S]    a series of stills
doscap still REC SECS [FILE]  pull a frame out of a recording
```

Verified on hardware 2026-09-05 against a MacroSilicon-class USB 3.0 HDMI
capture stick (`VID_345F&PID_2131`), at **1600x1200 yuyv422 60 fps, 4:3**.

**Everything else in this bridge is the machine reporting on itself.**
`WriteLn` goes through captured stdout, `SCRAPE` reads the text buffer back,
`VSHOT` reads mode 13h back, and the raycaster prints its own ASCII thumbnail
because nothing else could photograph an unchained mode. All of that can only
show what somebody wrote code to show, and only while the box is still
running. A capture card sees what a monitor sees: POST, the **F1 prompt from
the dead CMOS**, whichever way the video card lost the boot lottery, a frozen
screen with the last line still on it, and every graphical demo as it renders
rather than as its own thumbnail describes it.

**It proved itself before it was finished.** During the build `dosctl status`
said `STALE, last poll 2518s ago (hung? powered off?)` -- and it cannot do
better, because the thing that would have to answer is the thing that is not
running. One frame showed the box sitting in **MS-DOS EDIT with a dialog
open**: somebody had been at the keyboard. Not hung, not off, and a power
cycle would have been exactly the wrong response. That is the ambiguity this
file records being resolved the wrong way three times in one day on
2026-09-03, and it is now one command.

## It is a second opinion, not a replacement

`SCRAPE` and `VSHOT` read the framebuffer and give exact bytes. This gives
photons, after a VGA-to-HDMI converter has scaled them and a capture chip has
subsampled the colour. Text is legible and geometry is faithful, but **do not
CRC a captured frame or read exact pixel values out of one.** Use it for what
is on the screen, and the existing tools for what is exactly in the buffer.

## The frame rate is not an instrument

Worth stating plainly in a project that measures frame rates this carefully.
The box's text and mode 13h output is **70 Hz**, the capture is **60 Hz**, and
there is a scaler in between doing its own thing. A recording therefore
duplicates and drops frames against the original **by construction**. It shows
what was drawn; it cannot say how fast. `RAYCAST`'s own reported fps and
`modex.pas`'s `FlipLate` remain the measurements.

## Four things measured, none of them guessed

* **The device is EXCLUSIVE.** A second capture while one is running fails
  with "device already in use" -- promptly, cleanly, and *not* as a hang,
  which is the failure this project actually fears. So `rec --shots N`
  records first and extracts the stills from the finished file afterwards,
  rather than trying to hold the device open twice. `doscap still` does the
  same thing on demand.
* **`rtbufsize` is a correctness setting, not a tuning knob.** ffmpeg's
  default real-time buffer is about 3 MB and one 1600x1200 yuyv422 frame is
  **3.84 MB** -- less than a single frame -- so it drops frames before it has
  a whole one, and says so. It is 512M here. Raise it with the resolution,
  not with the length of the recording.
* **x264 `ultrafast` keeps up and `veryfast` does not.** Measured over 8
  seconds at 1600x1200x60: ultrafast gave **481 frames, zero drops, 3.1 MB**;
  veryfast dropped frames. MJPEG stream-copy also drops nothing and is
  **80 MB for the same 8 seconds** -- 26x the size, for a codec that
  recompresses text badly. If a capture ever drops frames, make the preset
  faster before making anything else smaller.
* **The first frame can be stale**, so a snapshot asks for `warmup_frames`
  and keeps the last. Six frames costs a tenth of a second.

## The 386SX had a dead PC speaker, and it was replaced

Found 2026-09-20, while building a tool that beeps to ask the person at the
machine to type something. Nothing was audible, and the split that settled it
took one job: five `C:\TOOLS\BEEP.EXE ALERT` in a row -- the kit's own tool,
long since proven on the V30 -- all returned cleanly and all were silent.
`BEEP` programs the 8253 and gates port 61h, the same three ports every PC
speaker has used since 1981, so a clean return with no sound exonerates the
software. The speaker itself was faulty and a replacement fixed it.

Worth knowing for two reasons. **A beep is the only cue a remote session has
for somebody standing at the machine**, and without one there is no way to
tell whether a person did the thing a measurement depends on -- which is the
difference between a measurement and a guess. And **the PC speaker is not the
PicoMEM's audio**: the card emulates an AdLib at 388h with its own output,
so a dead PC speaker says nothing about whether the card's OPL2 is audible,
and fixing it does not make the card audible either.

The lead is a loose 2-pin or 4-pin flying connector on a header near the
front-panel block, easy to dislodge when an ISA card goes in or out -- worth
checking first, before condemning the speaker.

## HDMI carries the AdLib but NOT the PC speaker

`rec --audio` records it, and `doscap live` plays it by default.

**`live` runs audio and video as TWO SEPARATE PROCESSES**, and that is the
whole design rather than an implementation detail. One ffplay given both
streams has to reconcile two unrelated clocks -- the stick's video and audio
clocks free-run independently -- and either choice is bad: audio as master
makes the real-time buffer climb without bound (63% -> 87% and rising), and
`-sync video` bounds it but continuously resamples audio to chase video,
which is audibly choppy. Neither is a buffering problem: a quarter of the
pixels, half the frame rate, `rtbufsize` from 32M to 512M and
`-af aresample=async` all changed nothing. **A throughput problem responds to
less work; a clock problem does not.** The split version is confirmed good
by ear; note every rejected variant above was also silent on screen, so the
absence of errors proved nothing.

The video and audio captures are *different* DirectShow devices, so two
processes can hold them at once. Audio alone has nothing to sync to and plays
samples as they arrive -- the same condition that makes a `rec --audio` file
clean. The cost is A/V sync between the two, which is worth nothing for
watching a DOS box.

The audio player runs `-nodisp`, so it has **no window**: its pid goes in
`capture/live-audio.pid` and the next run reaps it, `tasklist`-checked
because pids get reused. The obvious assumption -- that this gets you the box's sound
-- is half wrong, and which half had to be measured: the PC speaker is a
buzzer on the motherboard while the AdLib feeds a sound card, and only one of
them has a path into the converter's audio input.

| playing | RMS | Peak |
|---|---|---|
| nothing, box idle | -65.3 dB | -77.4 dB |
| **`MOZART`, PC speaker** | **-64.9 dB** | **-77.3 dB** |
| `RAYCAST`, AdLib/OPL2 | **-27.7 dB** | -40.8 dB |

`MOZART` is **0.5 dB from silence** -- the speaker does not reach the capture
at all. The AdLib is **37 dB above the floor**. So `AMOZART` and `RAYCAST`'s
music are checkable from another machine for the first time, and `MOZART`,
`BEEP` and `RAYCAST SPKR` are not: for those the speaker-gate PASS in the
program's own output stays the only evidence.

**The wiring is why**, and it is deliberate here: the sound card's line-out
is patched into the converter's audio input, so what the card plays is
embedded into the HDMI stream. The speaker is not on that path and no cable
puts it there without a mixer. A rig with nothing patched in captures no
sound at all, so this is **this machine's wiring** rather than a property of
capture sticks.

**Confirmed by ear, not just by meter.** A `RAYCAST` recording was played
back and the OPL2 music is clean, so the path is verified end to end. That
step needed a person -- 37 dB above the floor is equally consistent with a
tune and with hum, and no measurement here separates them.

## Configuration, and why it is required rather than detected

A JSON file, `capture.json`, beside `capture.py`. Same rule as `power.json`:
`capture.example.json` ships, the live file never does, and its absence is
what keeps the feature off.

The reason differs though. A smart plug is off by default because cutting
mains power is dangerous. Capture is off by default because **the DirectShow
device name belongs to one machine** -- a shipped default would be wrong
everywhere else. `doscap devices` prints the block to paste, and it works
with no config at all, because it is what you need in order to write one.

**It offers a device name only when there is exactly one.** This machine has
a webcam as well as the capture stick, and they are indistinguishable from
the enumeration; naming the webcam because it sorted first would be a
confident wrong answer rather than no answer.

`ffmpeg` is needed and the kit does not install it (`winget install
Gyan.FFmpeg`). A winget install is found automatically **even before the
shell has been restarted**, which is exactly the session somebody installs it
in and then tries to use it.

## Every failure path fails fast

Deliberate, and checked one at a time -- a capture that cannot open its
device must **fail, not wait**, because everything in this project that ever
needed hands on the keyboard looked like a hang first. `open_timeout` bounds
the device open, and every ffmpeg call runs under a hard timeout.

| | |
|---|---|
| device in use | names the conflict, suggests `doscap still`, rc 2 |
| device not found | lists the devices that *are* present, rc 1 |
| wrong name in the config | says to check it against `doscap devices`, rc 2 |
| not configured | says how to configure it, rc 1 |
| no ffmpeg | says how to install it |

## A recording survives a video mode change

This was expected to be the weak point and it is not. The box switches
between 720x400 text at 70 Hz and unchained mode X constantly, and each
switch makes the converter renegotiate -- so a 45-second recording was taken
across a whole `RAYCAST SECS 20` run, text to mode X and back.

**2701 frames in 45.016 seconds -- exactly 60 fps, zero drops.** The stream
never broke, the file is one continuous valid MP4, and the geometry never
changed.

What the switch *does* cost is about a second of black: the still sampled at
8.4s reads a perfectly uniform `rgb(0,0,0)`, `spread 0.0`, which is the
converter re-syncing. So a mode change costs **frames of content, not the
recording**. Anything sampling stills near one should expect a black frame,
which is exactly what `analyse` reports as `blank`.

Still unmeasured: whether a mode the converter cannot lock at all -- an SVGA
mode from `VMODES -t`, say -- behaves the same way or drops the stream.
