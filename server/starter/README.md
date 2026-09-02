# starter — Free Pascal for the DOS machine

A working edit-compile-test loop. One command builds a real-mode DOS binary on
Windows and runs it on the DOS machine, returning its output and exit code.

Everything here targets the plain **8086** instruction set, so it runs on any
DOS box from an original PC upwards. Where a faster CPU can do better, the
fast path is chosen at run time — see *CPU detection* below.

```
C:\dosbridge\starter> test.cmd sysinfo
=== sysinfo ===
      DOS version: 6.22
PASS  DOS 6.x or later
      heap available (bytes): 415632
PASS  at least 32K of heap
      CPU: NEC V20/V30
        186-class instructions: available
PASS  CPU identified

--- 3 passed, 0 failed ---
```

Exit code is the number of failures, so Claude Code can just run `test.cmd` and
react to a non-zero result.

---

## Installing the cross-compiler

There is no native FPC for 16-bit DOS — you cross-compile. Two downloads from
freepascal.org, **in this order**:

1. **`fpc-3.2.2.i386-win32.exe`** (~39 MB) — the native Win32 compiler.
2. **`fpc-3.2.2.i386-win32.cross.i8086-msdos.exe`** (~161 MB) — the cross-compiler.

The gotcha: it's the **i386/win32** native compiler that the cross package
depends on, not the Win64 one. Installing the x86_64 build first and then the
cross package will leave you with an `fpc` that doesn't know `-Tmsdos`. Both
run fine on Windows 11 x64.

Verify:

```
> fpc -Tmsdos -Pi8086 -iV
3.2.2
```

If it complains about a missing assembler, install NASM and put it on PATH —
FPC uses an external assembler for the i8086 target.

---

## Files

Every `.pas` here, grouped by what it is for. Units are the shared ones a tool
pulls in with `uses`; everything else builds to an `.EXE` of the same name.

**Units**

| | |
|---|---|
| `about.pas` | the `DOS Bridge -- StevenC` banner; `uses About` is all it takes |
| `tester.pas` | test harness: `Check`, `Note`, `Finish`, `Failures` |
| `cpu.pas` | run-time CPU and coprocessor identification: `Has186`, `HasFpu` |
| `vga.pas` | mode 13h plumbing: `SetMode`, `FillSpan`, palette, retrace |
| `prof.pas` | section timing and a stack watermark, PIT-resolution |
| `modex.pas` | unchained 320x200x256, virtual screen wider than the display |

**Machine and diagnostics**

| | |
|---|---|
| `sysinfo.pas` | DOS version, free heap, CPU, coprocessor |
| `hwinfo.pas` | the full sweep: BIOS, memory, equipment, ports, video, drives |
| `fpu.pas` | is a coprocessor fitted, which one, does it compute right (`/T`) |
| `fpuprobe.pas` | coprocessor timing diagnostic; no `FWAIT`, safe either way |
| `bench.pas` | measured cost of the operations that matter here |
| `memmap.pas` | walk the MCB chain: every block, owner, size |
| `devs.pas` | the DOS device chain; `DEVS NAME` exits 0 if loaded |
| `ivt.pas` | interrupt vectors, each attributed to its owner |
| `dstat.pas` | recursive file/dir/byte totals |
| `hd.pas` | hex dump + CRC-32 of any file |
| `serial.pas` | UART/RS232 probe, optional type ID and byte monitor |
| `mouse.pas` | exercise the mouse through INT 33h |
| `beep.pas` | PC speaker; `ALERT` when a human is needed |
| `mkkeyhit.py` | **not Pascal** -- emits the 22-byte `KEYHIT.COM` the agent polls |
| `opl2.pas` | AdLib / OPL2 plumbing: detect, register writes, patches, notes |

**Video**

| | |
|---|---|
| `vmodes.pas` | every mode; `-t` sets each, `-d n` draws and holds it |
| `vidchk.pas` | mono or colour, as a branchable exit code |
| `vesachk.pas` | what the VESA BIOS claims to offer |
| `scrape.pas` | capture the text screen back through DOS |
| `vshot.pas` | capture a mode 13h screen as ASCII art |

**Networking** — no TCP/IP stack; these talk to the packet driver directly

| | |
|---|---|
| `pktdrv.pas` | find the driver and describe it. Read-only, opens no handle |
| `pktcap.pas` | capture Ethernet frames. Opens a handle — read its header first |
| `arp.pas` | who-has queries and `/24` sweeps; the first tool that transmits |

**Demos**

| | |
|---|---|
| `hello.pas` | smoke test, deliberately fails one check |
| `fractal.pas` | Mandelbrot, Q8 integer or 8087, with `ZOOM` |
| `balls.pas` | bouncing balls in mode 13h |
| `matrix.pas` | falling green text, text mode |
| `svgatext.pas` | rotating text; VBE 640x480x256 if offered, else mode 13h |
| `scroller.pas` | mode X scroller: sprites, AdLib music, 70 fps. See `SCROLLER.md` |
| `music.pas` | the scroller's tune, driven from inside a frame loop |
| `gtest.pas` | mode 13h test pattern, leaves the mode set for `VSHOT` |
| `mozart.pas` | Eine kleine Nachtmusik on the PC speaker, one voice |
| `amozart.pas` | the same in two voices on an AdLib/OPL2, detected first |
| `proftest.pas` | exercises the `Prof` unit |

**Build**

| | |
|---|---|
| `build.cmd` | `build.cmd sysinfo` → compiles to `build\SYSINFO.EXE` |
| `test.cmd` | `test.cmd sysinfo` → compiles *and* runs it on the DOS machine |

Start with `test.cmd hello`. It should report one pass, one deliberate failure,
and exit 1. That proves the whole chain: cross-compiler → dosd → DOS box → back.

---

## Writing tests that actually work over the wire

**Print through DOS, not to video memory.** `WriteLn` is fine. Anything that
writes directly to B800 bypasses stdout, so `> OUT.TXT` captures nothing and
you get an empty result on Windows. If you're testing something that legitimately
draws to the screen, have it *also* `WriteLn` what it did.

**Keep exit codes under 20.** `Finish` caps the halt code at 20 because DOS 6.22
can't read `ERRORLEVEL` into a variable — dosd generates an `IF ERRORLEVEL n`
ladder, and it stops at 20.

**Avoid SysUtils.** `IntToStr` and friends drag a lot of dead weight into a
real-mode binary. That's why `Note` has a `LongInt` overload instead.

**Memory model.** `build.cmd` uses `-WmLarge`. Drop to `-WmSmall` if the binary
is tight and you don't need >64K of data; go `-WmHuge` only if you must.

---

## CPU detection, and the rule about CPU-specific code

Everything is compiled with `-Pi8086`. That is the baseline, and it is not
negotiable: a binary that will not load on the machine at the other end is a
much worse outcome than one that runs a little slower.

`cpu.pas` is how you get the speed back without giving that up. It identifies
the processor at run time and exposes three things:

```pascal
uses Cpu;

CpuClass    { cpu8086, cpuNecV, cpu186, cpu286, cpu386 }
CpuName     { 'NEC V20/V30', 'Intel 80286', ... }
Has186      { the 80186 instruction-set extensions are safe to execute }
```

**`Has186` is the gate.** The NEC V20/V30 and the 80186 both add instructions
the 8086 lacks — shifts by an immediate count, `IMUL` with an immediate,
`PUSHA`/`POPA`, `ENTER`/`LEAVE`, the string I/O instructions. Using one of them
on an 8086 is an invalid opcode, so:

> Never assemble a 186-class instruction on a path an 8086 can reach. Write
> both versions, choose with `if Has186`, and keep the 8086 version working —
> it is the one that has to run on an unknown machine.

`bench.pas` does exactly this for immediate shifts and prints both numbers, so
you can see what the fast path is actually worth before writing another one.
Emit the non-baseline instruction as raw `db` bytes: the assembler is targeting
the 8086 and would be right to reject it as source.

### The math coprocessor

`cpu.pas` answers this too, and the same gate rule applies — more sharply,
because of how an x87 instruction fails:

```pascal
HasFpu      { a coprocessor (or an emulator) is there }
FpuClass    { fpuNone, fpu8087, fpu287, fpu387 }
FpuName     { 'Intel 8087', '80387 or later', 'none' }
FpuCw, FpuSw{ the control and status words straight after FNINIT }
```

> An x87 instruction on a machine with no coprocessor **does not fault on an
> 8086** — the CPU decodes the ESC opcode, runs a dummy bus cycle and carries
> on. Your code runs and quietly produces garbage. That is worse than a crash,
> because nothing reports it.

So: nothing in `starter/` executes an ESC opcode unless `HasFpu` is true. Every
tool and demo runs the integer path whether a coprocessor is fitted or not.
`FPU.EXE` is the single exception, and it is the exception on purpose — it is
the tool that exists to test coprocessors, and even it checks `HasFpu` before
executing anything.

Three details in the probe are load-bearing:

* **`FNINIT`/`FNSTSW`/`FNSTCW`, never `FINIT`/`FSTSW`/`FSTCW`.** The
  un-prefixed forms assemble a `WAIT` (9Bh) in front, and `WAIT` with no
  coprocessor waits on the TEST pin for a signal that never comes — which
  hangs the machine. Over the bridge that is indistinguishable from any other
  hang and needs hands on the keyboard. The generated binary has been checked
  byte by byte: the probe is `DB E3 / B9 14 00 / 49 / 75 FD / DD 3E / D9 3E`,
  with no 9Bh anywhere in it.
* **The status word is seeded with `5A5Ah` first.** With no coprocessor
  nothing ever writes back, so the seed survives. Reading 0 is the proof that
  something answered.
* **A short delay between `FNINIT` and the store.** The 8086 does not interlock
  with the 8087, so it can reach the store before the init has finished.

Generation comes from bit 7 of the control word: `FNINIT` leaves `03FFh` on an
8087, whose Interrupt Enable Mask lives there, and `037Fh` on a 287 or later
which dropped the bit.

**A software emulator hooking INT 7 answers this probe exactly like real
silicon.** There is no cheap way to tell them apart, and `FPU.EXE` says so
rather than pretending otherwise — "present" means floating point works, not
that a chip is socketed.

`FPU.EXE` exit codes follow the `VIDCHK` convention so a batch file can branch:
`0` present and every test passed, `1` no coprocessor, `2` present but wrong.

### Networking, without a TCP/IP stack

FPC has none for `-Tmsdos` — no `Sockets` unit, no resolver. What DOS gives you
instead is the **Packet Driver Specification**: a small interrupt API that a
resident driver publishes on one vector in 60h..80h. mTCP is built on it, and so
is everything here.

| | |
|---|---|
| `pktdrv.pas` | `driver_info` (AH=1Fh). No handle, no state, cannot disturb anything. |
| `pktcap.pas` | `access_type` (AH=02h) + a receive handler + `release_type`. |
| `arp.pas` | adds `send_pkt` (AH=04h) and `get_address` (AH=06h). |

**Sending is the easy half.** `send_pkt` takes `DS:SI` and `CX` and nothing
else — no handle, no callback, nothing to release. Every hard part is on the
receive side.

**Receiving is where the danger is.** `access_type` hands the driver a far
pointer to your code, which it calls *at interrupt time* for every matching
frame. Exit without `release_type` and that pointer dangles into memory DOS has
reused — the next frame jumps into it, and the machine loses its network with
nothing left to report it. So in both programs everything between acquire and
release is straight-line, with **no DOS calls and nothing printed** until the
handle is back.

Two implementation notes that will save you an afternoon:

* **The handler runs with `DS` belonging to the driver**, so none of your data
  is reachable until you replace it — and you cannot load a segment you cannot
  address. The first fourteen bytes of `PktRecv` are hand-written `db`/`dw` so
  the two words needing run-time patching sit at *knowable* offsets, `+7` (data
  segment) and `+12` (record offset). Let the assembler choose the encoding and
  those offsets stop being knowable. Re-check them against the linked binary
  after any edit.
* **Calling a vector known only at run time** needs `PUSHF` plus a far `CALL`,
  because the `INT` opcode takes an immediate. That leaves the stack exactly as
  `INT` would and unwinds correctly on the driver's `IRET`.

And one bug worth inheriting as a warning: `arp.pas` originally guessed our own
sender address and got **zero replies**, because it guessed a `.0` network
address that hosts are right to ignore. The driver has no idea what your IP is —
addresses live a layer up. It now reads `IPADDR` from `%MTCPCFG%`. If a tool
transmits and hears nothing, suspect the sender address before the wire.

### Is an 8087 actually faster here?

Yes, measured on hardware 2026-09-01 — and this section used to say the
opposite, because the coprocessor probe was broken and reported "none" on a
machine that has one.

```
16-bit multiply    60660        FPU multiply    61661
32-bit multiply    10920        FPU divide      34361
32-bit divide       6916        FPU add         71780
                                FPU sqrt        42460
```

Against **16-bit** integer arithmetic the 8087 is a wash. Against **32-bit
`LongInt`** — which FPC implements in software — it is **5 to 6x faster**, and
in full double precision rather than fixed point.

So: `LongInt` maths is the thing worth converting. Q8 fixed point gains no
speed, but can trade an even swap for far more precision.

Gate any of it on `HasFpu`. x87 arithmetic carries `WAIT` prefixes, and `WAIT`
with nothing answering hangs the machine hard.

### How the probe works

Three tests, in an order that matters:

1. **FLAGS bits 12–15.** On the 8086/8088, the V20/V30 and the 186 they always
   read back as 1. A 286 in real mode reads them back as 0 and will not let you
   set them; a 386 or later reads bit 15 back as 0 but does allow NT and IOPL
   to be set. Two `POPF`/`PUSHF` round trips separate the three groups.
2. **The undocumented `AAD` opcode** (`D5h`) splits NEC from Intel within the
   first group. `AAD` takes a base operand: Intel honours it, NEC's parts
   ignore it and always use base 10. With `AH=1, AL=0` and base 11, Intel
   answers 11 and a V20/V30 answers 10.
3. **Shift-count masking** splits 8086 from 186 — but only once step 2 has
   already ruled NEC out. Sources disagree about whether the V20/V30 masks
   shift counts, so the probe never asks it that question.

**Verification status**, on a real NEC V30 box, 2026-08-30:

* Step 1 (FLAGS) and step 2 (`AAD`) both run and are correct — `SYSINFO`
  reports `CPU: NEC V20/V30`, `Has186` is true, and the `db`-encoded 186
  immediate shift in `BENCH` executes and measures ~11% faster than the CL
  form. The gate works end to end.
* Step 3 (shift-count masking) has **still never executed**, because `AAD`
  answers NEC first and short-circuits it. Treat a 186/286/386 result as
  unconfirmed until someone runs `SYSINFO` on one of those.
* The coprocessor probe runs on a machine with none fitted without hanging —
  the risk that mattered. `FPU.EXE` reports `none` and exits 1.
* That box's BIOS equipment word claims a coprocessor **is** fitted. It is not.
  `HWINFO` prints `** MISMATCH` for exactly this.

Everything else in `tester.pas` and `sysinfo.pas` compiles clean and was run
to verify the pass/fail counting and exit codes behave.
