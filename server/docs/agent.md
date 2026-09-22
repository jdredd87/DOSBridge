# The agent loop: upgrading, stopping, and the box's own screen

`C:\AI\AI.BAT` and the machinery around it -- how it is updated over
the wire, how it is stopped safely, what it prints, and every way it
has gone quiet.

Split out of `CLAUDE.md`, which keeps the summary and the pointer here.

## Upgrading the DOS box over the wire

Once the bridge is up, the client half updates itself; no USB, no floppy.

```
dosctl upgrade --dry-run      always start here
dosctl upgrade                tools that differ, then the agent, then reboot
```

**Tools** are ordinary `dosdeploy`s into `C:\TOOLS`. One `DIR` listing is
compared against `starter/build` by **file size** and only the differences are
sent — one round trip instead of twenty-five. Size is a proxy for deciding
*what to send*, so `--force` resends everything.

**What arrived is then checked by CRC-32, not by size.** Deployment used to be
confirmed with `IF EXIST` alone, which means a transfer that arrived truncated
to exactly the expected length -- or corrupted without changing length -- would
have reported success. Not hypothetical: when the box went silent after an
upgrade on 2026-09-02, a silently bad `UGET.EXE` was the leading suspect and
there was no way to rule it out from this side. `HD` on the box produces the
same CRC-32 as Python's `zlib.crc32`, so the check needs no new tool:

```
1 tool(s) sent, 0 failed
verified by CRC-32: 1 of 1 match
```

`dosctl verify` runs the same check over **every** tool on demand, which is the
answer to "is the box's toolset actually intact?". It takes a minute -- `HD`
reads every byte on an 8086.

Two details in it are load-bearing. Each check is preceded by an
`ECHO ##F=<name>` marker rather than trusting the `crc32` lines to come back in
request order: a missing file makes `HD` print an error and **no** `crc32` line
at all, which without markers would shift every later result by one and
mis-report every tool after it. And a box with no `HD.EXE` yet reports
"not verified" rather than failing the upgrade -- a fresh install has no tools
to check with.

**The agent loop is the dangerous one, and the ordering is the safety
mechanism.** COMMAND.COM reads a batch file incrementally *by byte offset*,
re-opening it after every line. Overwrite `C:\AI\AI.BAT` while it is running
and control returns to the old offset inside the new file, landing mid-line and
executing whatever text is there — on a machine that no longer has a working
agent to tell you about it. So the swap happens inside `JOB.BAT` and is
followed immediately by `REBOOT.COM`: `AI.BAT` is never read again after it is
overwritten. Same trick the driver path uses to end with `COLDBOOT.COM`.

Three guards run before anything is overwritten:

* **The end marker.** `dosctl` appends `REM ##AGENT-END` as the last line when
  staging, and the DOS side runs `FIND` for it. A truncated download therefore
  cannot become the agent. This costs nothing and needs no CRC.
* **The address check.** `dosctl` pulls the running `AI.BAT` first and compares
  `SET SRV=` / `SET UPHOST=`. The box is reaching you on those values right
  now, so they are the only ones known to work; sending an agent with different
  ones produces a machine that boots, never polls, and needs hands. Refused
  unless `--force`.
* **The rollback.** The outgoing agent is kept as `C:\AI\AI.BAK`.

If it does not come back, at the keyboard: `COPY C:\AI\AI.BAK C:\AI\AI.BAT`.

## "It did not come back" was wrong, twice over

On 2026-09-02 an agent upgrade that **completely succeeded** was reported as a
failure: `dosctl` printed the rollback instructions above and skipped the
version stamp, while the box was sitting there polling happily on the new
agent. Verified afterwards -- the running `AI.BAT` was byte-identical to the
staged one, and the freshly deployed `UGET.EXE` matched Windows exactly
(47158 bytes, CRC-32 `94F4A595` both sides).

Blaming the box for doing exactly what it was told is the failure this project
keeps having to design against, so both causes are worth keeping:

* **The "it is back" threshold was shorter than one poll cycle.**
  `wait_for_box` decided the box had returned when its last poll was under
  **12 seconds** old. A poll that gets no reply costs about 11 seconds and the
  offline branch waits 5 more, so a perfectly healthy box regularly shows an
  age above 12 and the return can be missed entirely between samples. It has
  to be larger than the worst *normal* gap, not smaller. Now 30.
* **The overall limit ignored which polls are least reliable.** It was 240
  seconds, and the polls right after a reboot are the *worst* ones: this
  host's ARP entry for the box has expired by then and our stack does not
  answer ARP, so several cycles fail before one gets through. Measured here:
  over five minutes to land the first poll after a swap. Now 420.

  **The ARP half of that was fixed on 2026-09-12** -- `net.pas` keeps the 0806
  handle and answers requests for the box, so the entry resolves and stays
  Reachable rather than ageing into Unreachable. See the ARP section in
  `docs/network.md`; it was also the mid-transfer stall. The 420 stays: it was
  sized against a measured worst case, and a box that has *just rebooted* has
  not opened a handle yet, so the very first poll is still the one with no
  cache entry behind it. Lower it against a measurement, not against this note.

The wording changed too. `##AGENT` has already confirmed the swap by that
point, so the message now says "the swap was confirmed but the box has not
polled yet", tells you to wait a minute and run `dosctl status`, and puts the
rollback last -- and it says outright that the version stamp was skipped, so
`C:\AI\VERSION.TXT` still names the old build until the upgrade is re-run.

**`dosctl reboot` had a second, hand-copied version of that loop** with the
same two thresholds, so the fix would have had to be found twice. It calls
`wait_for_box` now.

## A dropped packet must not silence a safety check

The address check listed above compares the running agent's `SET SRV=` against
the new one, and it does that by **pulling the running `AI.BAT` off the box**.
That pull can fail -- the transport is flaky enough that a single one does now
and then, and one did on the very run that found this. The code then had
`cur_srv = None` and only refused when `cur_srv` was truthy *and* differed, so
an unreadable agent read as **"checked, and fine"**.

That is the worst way for this particular guard to go, because what it prevents
is the one mistake nothing on this side can undo. `dosctl` now treats
"could not read it" as its own outcome and refuses, saying to try again or pass
`--force`.

Worth noting what is still missing: **tool deployment is verified with
`IF EXIST`, not a checksum.** A truncated transfer would report success, and
when the box went quiet the new `UGET.EXE` was the leading suspect for exactly
that reason. `HD` on the box already produces a CRC-32 that matches Python's
`zlib.crc32`, so `dosctl upgrade` has everything it needs to check and simply
does not.

Verified on hardware 2026-08-31: a tool and the agent both went over the wire,
the box rebooted into the new agent and resumed polling, and `AI.BAK` held the
previous one.

## What version is the box on?

`C:\AI\VERSION.TXT` on the DOS machine, three short lines. `AI.BAT` `TYPE`s it
in the boot banner, so the machine answers the question on its own screen
instead of someone having to go and ask the Windows side:

```
DOS Bridge client
build 1+
deployed 2026-08-31
```

The client installer writes it; `dosctl upgrade` rewrites it, **last and only
on success** -- a stamp claiming a build the machine did not receive is worse
than no stamp at all. `dosctl version` reads it back over the wire and prints
it next to what this bridge would send.

**The `+` matters.** A packaged installer stamps a bare `build 1`. `dosctl
upgrade` sends whatever is in the working tree, which is normally *ahead* of
the last build cut, so it stamps `build 1+` -- "at least build 1". Claiming a
plain build number for an unpackaged tree would be a lie the moment anyone
edited a `.pas` file.

A box with no `VERSION.TXT` predates stamping or was installed by hand;
`dosctl version` says so rather than guessing, and the next upgrade fixes it.

Note `AUTOEXEC.BAT` and `CONFIG.SYS` are **not** upgradeable this way and
should not be. A bad `AUTOEXEC.BAT` breaks the network before the agent runs,
which is unrecoverable from here; `CONFIG.SYS` is worse still.

## Stopping the agent loop

Three ways, and they fail differently.

| | |
|---|---|
| **ScrollLock** at the box | clean. Noticed within one poll, always between jobs |
| **`dosctl stop`** from Windows | clean, same exit point. One-way: see below |
| **Ctrl-C** at the box | the hammer. Use it for a job that is genuinely stuck |

`AI.BAT` checks both signals at the **top** of the loop, before the `HTGET`
that fetches work. That ordering is the whole point: an exit taken after the
fetch would discard a job the server had already dispatched, and `dosd` would
then wait out its full timeout and report the box as hung -- blaming the
machine for doing what it was told, which is the failure this project keeps
having to design around.

Ctrl-C has no such safe point. Landing mid-`JOB.BAT` means the closing `NC`
never runs and the Windows side times out the same way; landing inside
`:TRYIT` leaves `TRYING.FLG` on disk, and the *next* boot then reports
`##BOOTFAIL rc=253` for a driver that was fine.

**`dosctl stop` is a one-way door.** Once the loop exits, the box sits at a
prompt with nothing polling, so nothing on the Windows side can reach it.
Restarting needs someone at its keyboard typing `C:\AI\AI.BAT`, or a power
cycle. `dosctl` says so before it acts, and then watches the box go quiet
rather than claiming success the moment the flag lands.

**Verified on hardware 2026-09-01**: a reboot into the new agent, ScrollLock
pressed at the keyboard, the loop stopped, and `C:\AI\AI.BAT` restarted it.
Note the box comes back with ScrollLock still *on* if you do not clear it --
the stop message says so, because the agent would otherwise quit again on
its first poll.

## The offline branch quit instead of retrying

**Observed on hardware 2026-09-03: the agent stopped polling on its own and
sat at a prompt.** No `STOP.FLG` had ever been staged, ScrollLock was off, and
the last two entries in `dosd.log` were consecutive `NO ACK`s on idle polls --
which is the only route into `:OFFLINE`.

The branch ended:

```
CHOICE /C:QY /N /T:Y,5 > NUL
IF ERRORLEVEL 2 GOTO LOOP
GOTO QUIT
```

and its comment claimed the fallback was safe: *"If CHOICE is missing the
errorlevel is whatever the poll left, which is >= 20, so this falls to
`GOTO LOOP`."*

**That was an `HTGET` property, and it died with `HTGET`.** `HTGET` returned
>= 20 even on success, which is the same quirk that forces every job batch to
verify with `IF EXIST` rather than an exit code. `UGET`'s code is deliberately
honest, and `uget.pas` returns **1** on a failed poll.

So the guard had silently inverted. Reaching that line at all means the poll
just failed, so `ERRORLEVEL` is 1; 1 is below 2; the agent quits. Every case
that is not a clean `CHOICE` timeout -- `CHOICE` failing to resolve, a
truncated `PATH` out of the nearly-full environment, a Ctrl-Break landing
inside it -- turns a network outage into a stopped agent on a box nothing can
then reach.

The fix forces a known `ERRORLEVEL` first, which makes the three cases
distinguishable again:

```
IF EXIST C:\AGENT\EXIT0.COM C:\AGENT\EXIT0.COM
CHOICE /C:QY /N /T:Y,5 > NUL
IF ERRORLEVEL 2 GOTO LOOP
IF ERRORLEVEL 1 GOTO QUIT
GOTO LOOP
```

| | |
|---|---|
| 2 | `CHOICE` timed out | keep polling |
| 1 | somebody pressed Q | stop |
| 0 | `CHOICE` never ran, or was interrupted | keep polling |

**Stopping is now the only outcome that needs positive evidence**, which is
the right way round for the one branch that cannot be undone from Windows.

Two things generalise:

* **A fallback that depends on another program's exit code is coupled to that
  program.** Nothing here referenced `HTGET`; the dependency lived entirely in
  a comment asserting a number. Replacing the transport could not have been
  expected to make anyone re-read it. If a branch relies on a stale
  `ERRORLEVEL`, run `EXIT0.COM` and make the reliance explicit.
* **`IF ERRORLEVEL n` is `>=`, so the default arm of any such ladder is
  whatever is left over.** Point the default at the recoverable outcome. Here
  the unrecoverable one was the default, and it took a transport change three
  weeks earlier to expose it.

The same hazard exists at the `KEYHIT` test and is already handled correctly
there -- `IF NOT EXIST C:\TOOLS\KEYHIT.COM GOTO NOKEY` means the test is
never reached with a stale value. That guard is why ScrollLock did not have
this bug.

## Why ScrollLock and not a keypress

The obvious design is to read the keyboard buffer and look for a letter. **It
cannot work here, and it fails silently.** mTCP's tools watch the keyboard so
ESC or Ctrl-Break can abort a transfer, and in doing so they *consume* whatever
is queued. The agent spends effectively all of its time inside `HTGET`
long-polling for a job, so a keypress is eaten before the loop looks at it.
Measured on hardware 2026-09-01, faking the keystroke by writing into the BIOS
buffer at `0040:001E`:

```
STUFFQ then KEYHIT             ->  rc 1   the key was there
STUFFQ then HTGET then KEYHIT  ->  rc 0   HTGET ate it
```

ScrollLock is not a queued keystroke at all -- it is bit 4 of the BIOS keyboard
flags byte at `0040:0017`, set by the keyboard ISR and touched by nothing else.
It survived the same test with the `HTGET` in the middle. It also has an LED,
so the machine displays its own armed state with nothing on screen.

`KEYHIT.COM` is 22 bytes of hand-assembled code, generated by
`starter/mkkeyhit.py` -- the listing and the byte table are the same file, so
they cannot drift. It is deliberately **not** an FPC program: the loop runs it
every eight seconds forever, and 25 KB of binary re-loaded each time would be
silly, quite apart from `uses About` repainting the attribution banner on the
console every eight seconds.

`CHOICE` in the `:OFFLINE` branch is the one place a real keypress works, since
`CHOICE` reads the keyboard itself. `Q` quits there.

## What the box says on its own screen

`AI.BAT` prints a boot banner: the build from `C:\AI\VERSION.TXT`, the job
server and result host it will use, and its own `IPADDR` read out of whatever
`%MTCPCFG%` points at. That last line exists because when this box went silent
on an expired DHCP lease, the screen looked perfectly healthy and said nothing
at all about the network.

**It used to scroll off within about a minute, and now it stays.** mTCP printed
a four-line version block on every poll, straight to the console; `> NUL` does
not catch it and COMMAND.COM 6.22 has no stderr redirection. With the poll
moved onto our own UDP the loop prints nothing at all, so the screen is now a
live status display rather than a scrollback.

The heartbeat this section predicted was built, and it is what makes the
silence safe: **`UGET` draws a spinner in place while it waits** -- one
character then a backspace, phase taken from the BIOS tick at `0040:006C`, so
it needs no state of its own and scrolls nothing. Jobs announce themselves as
they run, raw `dosexec` jobs included, which used to be silent. `UGET`/`UPUT`
are otherwise silent on success (`-V` for the numbers) and neither uses
`About` -- the loop runs them every poll and About prints from its unit
initialisation, so linking it repainted the attribution banner every eight
seconds. Same reasoning as `KEYHIT.COM` being hand-assembled.

Everything below is the reasoning from when mTCP still drove the loop. It is
kept because the argument is the important part, and it is exactly why the
spinner had to exist before the chatter could go.

`HTGET -quiet` **does** suppress it -- measured 2026-09-01: with it on, 55
seconds of idle polling left the screen completely unchanged, against roughly
seven version blocks without it. It was tried, and then taken back out.

The reason is worth keeping. That chatter is the **only continuous evidence the
box has not wedged**, and a machine that has stopped polling looks exactly like
a machine that is quietly waiting -- which is the failure this bridge keeps
having to design around, and the one that costs a walk to the keyboard. Four
noisy lines every eight seconds buys a heartbeat you can see from across the
room. Quieting them buys a readable banner nobody is looking at.

So treat the banner as a boot-time display. The stop message repeats the same
addresses, which is the other place to read them, and `dosctl version` /
`dosctl status` answer from this side.

If the banner ever does need to persist, the way to do it is not `-quiet` --
it is a tiny .COM printing a spinner character followed by a backspace, which
animates in place and scrolls nothing. Same trick as `KEYHIT`, about 30 bytes,
and it can take its state from the BIOS tick counter at `0040:006C` so it needs
none of its own.

`AI.BAT` also sets `TZ`, which `AUTOEXEC.BAT` does not. Without it mTCP refuses
to stamp file timestamps and says so on every poll -- a quarter of everything
on that screen was this one warning. It goes in `AI.BAT` and **not**
`AUTOEXEC.BAT` for the usual reason: a mistake in `AUTOEXEC.BAT` breaks the
network before the agent runs and needs hands on the keyboard, while a mistake
in `AI.BAT` is fixable over the wire.

The environment on this box is nearly full, so a `SET` in the agent can fail
with `Out of environment space`. That is survivable for `TZ` -- you lose the
timestamps and nothing else -- but it is why the banner reads `%MTCPCFG%`
directly rather than copying it to a working variable first. Copying it
*truncated the path* and made a present config file look missing.

## The DOS console is a status display, not a scrollback

Everything the loop prints is built to fit **78 columns**. The screen is 80
wide and the boot banner now stays on it, so a line that wraps costs two rows
and reads as damage rather than information. Two rules follow:

* **`dosd` truncates every console line it generates** (`job_head` /
  `job_foot`, `CONSOLE_COLS = 78`) and gives each job exactly two lines: what
  it is, and how it ended. The job id is cut to four characters -- enough to
  match a screen line against a line in dosd's log, where the full id would
  eat a tenth of the width for nobody's benefit.
* **`UGET`/`UPUT` messages are short by construction.** `Fit()` truncates,
  `Leaf()` drops directories, and the `Tftp` error strings were rewritten from
  prose ("gave up after 5 retries at block 46") into labels ("stalled at
  block 46"). A failure prints two lines: the reason, then the counters.

```
 server      : 192.168.1.10   (UDP 8069, HTTP fallback)
 address     : 192.168.1.20   mask 255.255.255.0
 gateway     : 192.168.1.1   from C:\AI\NET.CFG
 stop        : ScrollLock, or Ctrl-C
-------------------------------------------------------------------
[815b] exec 1 cmd(s): MEM /C
[815b]   ok
[cf49] exec 1 cmd(s): DIR C:\WORK
[cf49]   done
[e6ed] exec 1 cmd(s): C:\TOOLS\DEVS.EXE NOSUCHDEV
[e6ed]   rc 1 FAILED
[e9e3] pull C:\AI\VERSION.TXT
[e9e3]   sent
[1f72] run starter/HELLO.EXE
 uget: HELLO.EXE FAILED - stalled at block 3
       rx 28 (26 foreign, 1 dropped)  tx 14 (0 refused)
```

### The footer wording, and the `rc 0` that was a lie

Every job ends in exactly one row, worded so a failure is legible from across
the room. Verified on hardware 2026-09-02, all six states:

| | |
|---|---|
| `ok` | the job's last command was an external program and it exited 0 |
| `rc 3 FAILED` | ...and it exited non-zero |
| `done` | the commands ran; nothing here can say whether they worked |
| `sent` | a pull shipped the file |
| `FAILED - not found` | a pull found nothing at that path |
| `FAILED - could not fetch X` | the job never got as far as running anything |

**It used to print `rc 0` for every job that survived, and half the time that
was a fabrication.** DOS internal commands -- `ECHO`, `DIR`, `DEL`, `COPY`,
`TYPE`, `SET`, `VER` -- never touch `ERRORLEVEL`, and `EXIT0.COM` has already
forced the ladder to read a clean 0, so a job made only of those reported a
confident `rc 0` that meant nothing: `DIR C:\NOSUCH` exits 0. Those now print
`done`, because whoever is reading that screen is standing at the machine with
no way to know which commands set an exit code. Removing misinformation was
worth more than adding information.

`IF` and `FOR` are deliberately classed as external (`sets_errorlevel` in
`dosd.py`). Either can invoke a real program, so their rc may well be genuine.
A possibly-stale number is merely unhelpful; `done` printed over a program that
actually failed would hide a failure, so the doubt resolves towards the number.

The result returned to Windows is **unchanged** -- it still carries `##RC`
either way, because that is `dosctl`'s contract. This is console wording only,
and the Hard-constraints rule about not trusting `dosexec`'s exit code for
internal commands still applies on the Windows side.

Also note `ok` and `rc 3 FAILED` are two single `IF`s, not one chained pair.
`ECHO` is internal so a chained `IF` would survive here, but that is not a rule
worth relearning inside a batch nobody can debug.

Batches are generated per job, so all of this landed on the next poll: no tool
rebuild, no `dosctl upgrade`, no reboot.

### How long did it take: `ELAPSED.COM`

`starter/elapsed.asm` is the job stopwatch, and the odd thing about it is that
it prints the caller's text rather than just a number:

```
IF EXIST C:\TOOLS\ELAPSED.COM C:\TOOLS\ELAPSED.COM /S      right after the head line
...
IF "%RC%"=="0" C:\TOOLS\ELAPSED.COM [bd01]   ok            instead of ECHO
```

**That is forced by the one-row budget.** `ECHO` always terminates its line, so
nothing can be appended to a row `ECHO` printed -- and a job that spent a
second row saying how long it took would scroll the display away twice as
fast. So whatever holds the time has to print the whole row.

The time covers the **whole job, fetch included**, because the stash goes
immediately after the head line. That is the number somebody standing at the
machine is actually asking about.

Three details worth keeping:

* **It reads `0040:006Ch` directly, not `INT 1Ah AH=0`.** That call returns the
  midnight-rollover flag in `AL` and *clears* it, and DOS reads the same flag
  to advance the date -- so a stopwatch built on it would occasionally eat a
  day.
* **It trims trailing spaces off the command tail.** COMMAND.COM strips a
  redirection off the line but leaves the space that preceded it in the tail,
  so the identical footer arrived a column wider whenever the caller
  redirected. Alignment must not depend on the call site.
* **The footer group is guarded with `GOTO`, not `SET F=ECHO`.** The `SET`
  version is two lines instead of seven and was the first thing tried, but the
  environment on this box is nearly full: a `SET` failing with `Out of
  environment space` expands to nothing and leaves COMMAND.COM trying to
  execute the footer text as a command. A box without the tool falls back to
  plain `ECHO` and simply gets no time.

Only the low word of the tick is kept, so a job over about an hour -- or one
spanning midnight -- reports nonsense. Jobs here are seconds and dosd's own
default timeout is 120s, so 32-bit arithmetic for a status line is not worth
the bytes.

It is 293 bytes of NASM rather than the Python byte-table `KEYHIT.COM` uses,
because 130-odd hand-encoded bytes with hand-computed jump displacements is not
reviewable. `nasm` ships with FPC, and `cpu 8086` in the source makes the
assembler enforce the baseline instead of a read-through:

```
nasm -f bin elapsed.asm -o build/ELAPSED.COM
```

The directive is wrapped in `%ifndef __MININASM__` so the file still builds on
the DOS box itself.

### A job shows its output on the box, too

Default on since 2026-09-02: a job's captured output is `TYPE`d onto the DOS
console between the head line and the footer, so the machine in front of you
can show what it actually said and not only what it was asked to do. The result
still goes back over the wire exactly as before -- this is a second copy, for
the screen.

```
[eb32] exec 1 cmd(s): C:\TOOLS\MOZART.EXE
DOS Bridge tools  --  StevenC  --  built 2026/09/01
=== Mozart, Eine kleine Nachtmusik K.525 (opening) -- PC speaker ===
  ...
--- 3 passed, 0 failed ---
[eb32]   ok  11.1s
```

**This is the one thing here that deliberately breaks the two-lines-per-job
budget**, and it does scroll the banner away sooner -- a `MEM /C` is twenty-odd
rows. That is the trade for being able to read a job at the machine, and it is
reversible three ways:

| | |
|---|---|
| `dosrun --quiet`, `dosexec --quiet` | this job only |
| `DOSD_ECHO_OUTPUT=0` in dosd's environment | the default, for a session |
| nothing to change on the box | it is generated per job |

Long output lines still wrap -- MOZART's melody line is 120 columns. That is
deliberate: truncating a data dump to fit would hide the data, and the
*status* lines are the ones that must never wrap.

`dosctl`'s own bookkeeping jobs pass `echo=False` explicitly -- the version
`TYPE`, the `C:\TOOLS` listing, the stop flag. A 36-file `DIR` on the console
every upgrade is nobody's idea of a status display.

**And a documented switch is not a switch.** `DOSD_ECHO_OUTPUT=0` was written
up here before it was tried, and it did nothing: `dosctl` sent `"echo"` on
*every* job, and dosd consults its own default only when the job does not carry
one -- so the environment variable was dead for precisely the two commands it
exists to govern. `dosctl` now sends that key only to turn the echo *off*.
All three paths are verified on hardware: default on, `--quiet`, and the
environment override.

**A flag added to the parser is not a flag.** `--quiet` was added to
`dosctl.py`'s `argparse` and did nothing: the tail is `argparse.REMAINDER`, and
a hand-written list right beside the parser decides which arguments are ours
versus the program's. `--quiet` was not in it, so it fell through into the
command tail and the DOS box tried to **execute** it -- `Bad command or file
name`, and a job reporting two commands when it was given one. That list is now
derived from the parser's own actions, so the two cannot drift again.

### An outage says so once, not once per retry

A dosd restart used to cost two screen lines per failed poll -- `uget: job
FAILED` plus its counter line, forever -- and eight pairs of them scrolled the
banner away during one daemon restart. Fixed in two halves:

* `UGET` is **silent on a failed `POLL`** unless `-V`. A poll that gets no
  reply is the normal state of a box that cannot reach its server, not an
  event; the counters are still there for diagnosis.
* `AI.BAT` prints `[offline]` **once per outage**, guarded by
  `C:\AGENT\OFFLINE.FLG`, and prints `[online] ... is answering again` when a
  job finally arrives. The retries show as `UGET`'s spinner, which animates in
  place and scrolls nothing.

**It takes two consecutive misses to say anything, and that only became clear
after `HTGET` was removed.** With the fallback gone, every lost idle poll --
about one in six on this link -- fell into the offline branch, so a single
dropped packet printed an `[offline]` and then an `[online]` on the very next
poll. Two lines for something that cost five seconds and lost nothing, three
times over in one screenful. `HTGET` had been hiding it.

So the first failure sets `OFFLINE.FLG` and says **nothing**; only a second
consecutive failure prints, and it sets a second flag, `OFFSAID.FLG`. Recovery
prints `[online]` only if `OFFSAID.FLG` exists -- otherwise the notice would
reappear for an outage nobody was ever told about. Both are cleared at agent
startup. A dropped packet is now completely silent; a server that is really
gone still says so once.

**And on its own it bought nothing, because the premise was wrong.** The
failures were not isolated single drops at all -- they arrived in *consecutive
pairs*, so every pair tripped the threshold and printed anyway. dosd's log is
what showed it:

```
[12:20:13]  idle batch -> :21245  NO ACK
[12:20:36]  idle batch -> :21661  NO ACK
[12:20:43]  idle batch -> :22080  acked
```

The rule was behaving exactly as written; two consecutive misses is what it was
told to report. Chasing *why* they came in pairs is what found the real bug
below -- and with that fixed the misses are isolated again, which is the case
this rule was built for. Worth remembering as a pattern: a mitigation that
changes nothing is usually evidence about the cause, not a failed fix.

This is still the same shape as the difference between an average frame rate
and `FlipLate` in the scroller notes: the interesting question is rarely "did
something go wrong" but "did it go wrong twice in a row".

## The poll hold was the bug, and it was 8 seconds of dead code

**`serve_job` holds for `POLL_HOLD_SECS`. The `TFTP_HOLD_SECS = 2` added when
the hold was supposedly "reduced 8s to 2s" was never read by anything.** That
is why these notes used to say shortening the hold "did not clear it" -- the hold
had never changed. It was 8 seconds the whole time, and the note recording that
non-result was itself the evidence of an unapplied change.

Why the number matters, and it is not obvious: every poll *begins* with the DOS
box ARPing for us, which is what puts this host's ARP entry for the box into a
state it can actually send to. dosd then sits on the request. Answer 8 seconds
later and that entry may already have gone stale -- and **nothing on the box
answers the re-probe**, because by then `Net` has released the 0806 handle and
holds only 0800. The reply is undeliverable. Answer at 2 seconds and the entry
is still fresh.

Measured on hardware 2026-09-02, four minutes of idle polling each way:

| hold | polls | unacked | |
|---|---|---|---|
| 8s | 24 | 4 | 17% |
| **2s** | **30** | **1** | **3.3%** |

The 3.3% that remains is just this WiFi link -- it matches the loss measured
with 30 pings -- so the long hold had been causing **five sixths of the
failures**, all of them self-inflicted.

The cost is a poll every ~6 seconds instead of ~11. That is nothing on a LAN,
and a wired box both loses less to begin with and pays less for the shorter
hold. `DOSD_POLL_HOLD` overrides it if some link ever makes the chatter matter
more than the misses.

**This is the third time on this machine that a plausible cause was accepted
without checking that the fix took effect** -- the others being `HTGET -quiet`
and `dos/live/AI.BAT` having drifted from the box. The pattern to distrust is a
change that produces no measurable difference: it is far likelier to be
unapplied than ineffective.

**`CHOICE` echoes the answer it picks, and `/N` does not stop it.** `/N` hides
the `[Q,Y]?` prompt only; on every timeout CHOICE still printed a bare `Y`, so
an outage cost a line per retry anyway -- most of what putting the `[offline]`
notice behind a flag was meant to fix. It needs `> NUL` as well. CHOICE reads
the keyboard directly rather than through stdin, so redirecting its output does
not stop `Q` from working.

The flag is created with `ECHO . >` and not `COPY C:\AGENT\EXIT0.COM`, because
`EXIT0.COM` is fetched by the first job -- on a box that has not run one yet
there would be nothing to copy, so the flag would never appear and the message
would be back every five seconds. It is deleted at agent startup too: a flag
left by the outage that was in progress when the box went down would otherwise
silence the first notice after a reboot.

The address lines come from `UGET -INFO`, not from `FIND` on the config file.
`FIND` printed a filename header as well as the address -- two lines, one of
them noise -- and it could only ever read mTCP's config, never the bridge's
own. `-INFO` reports whichever file was actually used, which matters now that
there are two candidates. Its label field is 12 wide to match the banner: two
lines printed by different programs under one heading look accidental unless
their colons line up.

`CHOICE /N` in the `:OFFLINE` branch hides CHOICE's own `[Q,Y]?` prompt -- the
line above it already says which keys work.

**The banner still scrolls once a dozen or so jobs have run.** That is the
trade for showing job detail at all, and it is the right way round: an idle box
keeps its banner indefinitely, and a busy one shows what it is busy with.

## The box was never freezing. It was still retrying.

**Settled on hardware 2026-09-03, by leaving it alone and watching.** A file
transfer stalled at 16:32:53 and the box stopped polling. Nobody touched it:

```
16:32:53  box goes quiet, mid-transfer
16:37:38  box polling again        <- unattended, 4m 45s
```

It is not a hang. `UGET` hits a stalled transfer, tears the flow down and
rebuilds it -- new handle, new ARP, new local port, re-request from the byte
it reached -- and keeps doing that. Throughout, the agent loop is running and
the machine is healthy; it simply is not polling, and from Windows that is
indistinguishable from a wedge.

**Which is how it got misdiagnosed three times in one day.** Two of those
ended in a power cut to a machine that was going to come back on its own.
`dospower`'s own guard refusing a second cycle was more right than the reason
given for it at the time.

**The predicted number was wrong too, and by a lot.** `RESTART_AFTER` is 3
timeouts of ~2s and `MAX_RESTARTS` is 250, which reads as 25 minutes of
grinding -- so 25 minutes is what these notes said. Measured: 4m 45s. The full
budget is never walked; some earlier limit ends it. **Arithmetic over a
constant is not a measurement**, and the two differ here by 5x.

The 43- and 48-minute silences earlier that day were never verified at all --
they were power-cycled before anyone waited. They may well have been the same
self-recovering stall.

## The fix: budget restarts against progress, not against a count

`MAX_RESTARTS = 250` is right for what it was sized for. A 5 MB file over a
link that genuinely stalls every 45 KB needs about 110 restarts, and every one
of them moves data. It is useless as a stopping rule for a peer that is *not
there*, because a count cannot tell "slow and lossy" from "gone".

So `tftp.pas` now counts restarts that achieved **nothing**:

```pascal
if TftpBytes = DeadMark then Inc(DeadRuns) else DeadRuns := 0;
DeadMark := TftpBytes;
if DeadRuns > DEAD_RESTARTS then      { 3 }
begin
  TftpErr := 'no answer from the server';
  Break;
end;
```

A restart that recovers even one block is the fault the mechanism exists for
and costs nothing from this budget. Three in a row that move zero bytes is a
dead peer, which is about twenty seconds -- after which the transfer fails,
the agent's `:OFFLINE` branch takes over, and **the box keeps polling**. Both
directions, because the stall happens sending as well as receiving.

**This treats the consequence, not the cause.** The underlying mid-transfer
stall -- frames stopping for this card while broadcasts keep arriving -- is
still unexplained and still there. It should now cost seconds rather than
looking like a dead machine.

## Verified on hardware, both halves

The two cases are opposites and both had to be checked, because a budget that
ends dead flows too eagerly would break the large transfers that resume-on-
stall exists for.

**A stall that recovers -- the regression risk.** 1 MB over the WiFi link:

```
16:53:32  tftp: resuming local/BIG1M.BIN at byte 134400
16:53:44  tftp: sent local/BIG1M.BIN ... FAILED
16:54:17  tftp: sent local/BIG1M.BIN (914176 bytes)
          62s, 749 blocks of 1400, 5 resends, rc 0
          CRC-32 998E4325 on the box, 998E4325 on Windows
```

It stalled, rebuilt the flow, finished byte-exact. Restarts that move data
still cost nothing from the new budget.

**A peer that goes away -- the case the budget is for.** `dosd` killed 14
seconds into a 1 MB transfer and kept dead for a full minute:

```
17:13:29  shutdown requested -- bye
          ...61 seconds with no server at all...
17:14:30  dosd listening
17:14:32  job RRQ from the box          <- polling 2s later
```

Two seconds. The box had already given up, printed its failure and gone back
to the `:OFFLINE` retry, so it caught the first poll the moment there was
anything to answer it. `C:\AGENT\PHASE.LOG` confirms the job ended properly
rather than being abandoned:

```
8ff0 cmd0 C:\TOOLS\UGET.EXE
8ff0 cmds done                          <- UGET returned
8ff0 send
8ff0 sent                               <- and the result was delivered
```

Against 4m 45s of silence for the same event before the fix.

**Two earlier attempts at this test were spoiled and are worth remembering.**
The first measured the wrong thing -- it timed from when *its own* daemon
returned, by which point the box had been polling for half a minute, so it
reported 9s for something that had taken 16. The second was contaminated by a
second `dosd` starting mid-window: the server was only absent 13 seconds,
which is inside the budget, so the run could not have proved what it appeared
to. On Windows two daemons will both bind the same ports and delivery becomes
a coin flip, so "is exactly one running?" was worth checking before believing
any measurement that involves restarting it.

## The stall underneath is still unexplained, and it defeats instrumentation

The retry grind above is fixed. The thing that *causes* a stall is not, and it
is worth recording how many attempts to measure it have now failed, because
every one of them produced a plausible number that meant nothing.

`network.md` already carries four dead hypotheses -- ARP expiry, the server
deadlock, the receive handle wedging, the card's address filter -- each built,
measured and removed. Three more failed on 2026-09-03:

* **Sniffing it is not available.** The obvious move is `PKTCAP` on the box:
  watch whether the server's blocks reach the wire. It cannot work. Capturing
  needs an `access_type` handle for the same ethertype the transfer is using,
  which the driver may refuse, and capturing `ALL` takes frames away from the
  transfer being watched. The observer changes the observed. If this is ever
  worth doing properly it needs a *second* machine on the same segment.
* **A window that included what it was meant to exclude.** `tftp.pas` was made
  to sample the receiver's counters at each flow rebuild, giving "what arrived
  during the silence". The mark was taken at transfer *start*, so the first
  stall's window spanned the whole successful transfer before it -- and duly
  reported ~100 frames as having arrived during total silence. They were the
  good blocks.
* **A guard that could never fire.** The fix for that tested `Tries = 0` at
  the top of the stall branch. `Inc(Tries)` runs *before* that branch, so the
  condition was never true and the mark silently kept its transfer-start
  value. Same artifact, second time, from the code written to remove it.

**What caught both was a contradiction, not a review.** The counters read
`448 seen, 19 not ours`, implying 429 frames matched our IP and port during a
timeout -- impossible, because a match makes `NetUdpRecv` return instead of
timing out. A number that disproves itself is the only reason either bug was
found. Build the contradiction test into the reading, not the code review.

**Know what the counters mean before quoting them.** `NetRxFrames` counts
*every* frame pulled out of the receive buffer, ours or not; `NetRxWrong`
counts the ones that did not match. "Ours" is the difference. The first
version of the report labelled `NetRxFrames` as "ours", which is what made
the impossibility legible -- an accident that happened to help.

## A burst of stalls on 2026-09-04: it was the EMS card's jumpers

Worth reading as a whole, because the wrong answer was reached twice on the
way and the second one was reached *by a test that looked clean*.

The rate jumped sharply: several stalls in an afternoon against roughly one a
day before, all with the same signature -- powered at ~36 W, no polling, no
self-recovery, back immediately on a power cycle.

**First theory: the newly fitted 2 MB Lo-tech ISA EMS card.** An EMS page
frame is 64 KB of upper memory and the PicoMEM lives up there too, so an
overlap would give exactly this -- fine until something touches it.

**The test that appeared to disprove it.** The PicoMEM's memory expansions
were turned off and the box rebooted, which removed expanded memory entirely
(`MEM` reported none again, conventional back from 540 KB to 545 KB). It
stalled on the very next batch. That looked conclusive and was not:
**disabling a DRIVER does not stop a misjumpered ISA card from decoding its
address range.** The hardware still answers on whatever the jumpers select,
whether or not anything is driving it. The card was never actually out of the
picture.

**The second theory, from a real correlation.** Every stall had happened
during a run of `dosrun`s, and each `dosrun` pushes the binary over TFTP;
`RAYCAST.EXE` had grown to 57 KB, past the ~50 KB mark `network.md`
records as where transfers start failing, and its `dosctl upgrade` had failed
CRC twice the same day. Deploying once and iterating with `dosexec` -- which
transfers nothing -- gave **9 consecutive clean runs** where `dosrun` stalled
within a few. Consistent, reproducible, and still not the cause.

**The actual fix was the jumpers.** They were wrong from the moment the card
went in. Corrected, with the PicoMEM's memory handling left off and EMS
re-enabled on the dedicated card:

| | |
|---|---|
| before | stalled within 2-5 `dosrun`s |
| after | **11 consecutive `dosrun`s, no stall** |

including three `FLAT` runs, which had twice taken the box down.

Three things to take from it:

* **A disproof is only as good as its isolation.** Turning off the driver
  felt like removing the card and was not remotely the same thing. When
  ruling hardware out, rule out the *hardware*.
* **A strong correlation can be a symptom.** The transfer-size link was real
  and reproducible -- large transfers were simply the thing that reliably
  touched whatever the conflict broke. It would have been easy to stop there
  and write the wrong cause into these notes with measurements attached.
* **The `dosexec` habit is worth keeping anyway.** For repeated testing of a
  binary over ~50 KB, `dosdeploy` it once and iterate with `dosexec` on
  `C:\TOOLS\`. Nothing crosses the wire per run, so it is faster as well as
  one less thing that can fail. Use `dosrun` when the binary has changed.

**There is also a second failure, distinct from the grind.** On 2026-09-03 the
box went quiet for six minutes having issued **no requests at all**:

```
20:45:33  job RRQ from 192.168.1.20:20552 -- holding
20:45:45  idle batch -> 192.168.1.20:20552  NO ACK
          ...six minutes, no RRQ of any kind...
```

That cannot be the retry grind: a job poll runs with `MaxRq = 0` and gives up
on the first miss by design. Something stops the box *asking*. It needed a
power cycle. Do not fold this into the grind -- they have different
signatures and only one of them is fixed.

The corrected probe is deployed and will report on the next stall it sees, at
no cost. Treat whatever it says as a hypothesis until it survives the same
contradiction test.

## Finding out where a freeze happened: `C:\AGENT\PHASE.LOG`

The box has frozen repeatedly with nothing to show for it. The console's last
line is whatever finished BEFORE the hang, so all it ever says is "not there
yet", and the daemon's log only records that the box stopped answering.

Every generated batch now drops breadcrumbs as it goes, the same trick
`dosdrv` uses to survive a driver that wedges the machine:

```
ECHO ab12 fetch RAYCAST.EXE >> C:\AGENT\PHASE.LOG
C:\TOOLS\UGET.EXE %UPHOST% starter/RAYCAST.EXE C:\WORK\RAYCAST.EXE
ECHO ab12 got RAYCAST.EXE   >> C:\AGENT\PHASE.LOG
ECHO ab12 run RAYCAST.EXE   >> C:\AGENT\PHASE.LOG
C:\WORK\RAYCAST.EXE > C:\WORK\OUT.TXT
ECHO ab12 ran RAYCAST.EXE   >> C:\AGENT\PHASE.LOG
```

Read it after a freeze with:

```
dosexec "TYPE C:\AGENT\PHASE.LOG"      or  dospull C:\AGENT\PHASE.LOG
dosexec "DEL C:\AGENT\PHASE.LOG"       start a clean run
```

**How to read the last line:**

| last entry | where it froze |
|---|---|
| `fetch X` with no `got X` | inside the transfer -- UGET, our own stack |
| `got X` with no `run X` | between them, which is only `IF EXIST`/`DEL` |
| `run X` with no `ran X` | inside the program itself |
| `ran X` for the previous job, nothing since | in the POLL -- also UGET, but no batch was running to leave a mark |

That last row is the useful accident: a poll hang leaves *no* new entry at all,
so the absence of one is itself the signal. It means the poll case needs no
change to `AI.BAT` and therefore no reboot -- which matters, because with the
CMOS battery dead a reboot now stops at an F1 prompt and needs hands.

Three things about the design:

* **APPEND, not overwrite.** The obvious version writes one word to a file and
  reads it back after the reboot, and it cannot work: reading the file needs a
  job, and that job's own batch overwrites the marker before the pull runs. An
  append-only log keeps the frozen job's last line underneath whatever the
  recovery job adds.
* **`ECHO` opens, writes and closes**, so each line is committed before the
  next command starts. A buffered write would be lost in exactly the case this
  exists for.
* **`DOSD_PHASE=0` turns it off.** It costs a file open/write/close per phase,
  and if the disk I/O ever becomes a suspect itself, that has to be removable
  without redeploying the agent.

Batches are generated per job, so this needs a **dosd restart** and nothing on
the box.

The section below is the Status log this project kept in `CLAUDE.md` until
the file was split. It is the record of what was checked on hardware and
when, and of the quiet-failure gap `PEND.BAT` and `DRVOUT.TXT` were written
to close. `CLAUDE.md`'s Status section now carries only the parts still
true today.

## Drivers, and the verification record

Verified on hardware 2026-09-01, the agent controls:

- `KEYHIT.COM` reads ScrollLock correctly (rc 1 on, rc 0 off) **and the
  reading survives a full `HTGET`** -- which is the whole reason it tests a
  flag bit rather than the keyboard buffer. A stuffed keystroke did not
  survive the same test.
- The boot banner renders every line, `IPADDR` included, with no
  `Out of environment space`.
- `TZ` set in `AI.BAT` removed mTCP's timestamp warning from every poll.
- The `STOP.FLG` mechanism `dosctl stop` uses: `COPY` creates it, the DOS
  side sees it, `DEL` clears it.
- End to end at the keyboard: reboot, ScrollLock, loop stopped, restarted.

Verified on hardware 2026-09-04, at the keyboard: ScrollLock stopped the
agent and **the agent cleared it on the way out, lamp included** -- so the
restart-stops-again trap is gone rather than merely documented. That was the
half of `SCRLOFF` that could not be checked over the bridge, because the
keyboard lamp is only visible to somebody standing at the machine.

Still not exercised: `dosctl stop` itself over the wire (same `:QUIT` path,
but the flag arrives from Windows rather than the keyboard), and
`selftest.py` against these changes -- it needs port 8080, so it has to run
with `dosd` stopped.

Verified on the real hardware: the job loop, both directions of transport
(including the mTCP `NC` return path), FPC cross-compilation of `hello` and
`sysinfo`, errorlevel propagation through `dosrun` and `dosexec`, and the
`AAD`-based NEC detection now in `starter/cpu.pas`, which reports
`CPU: NEC V20/V30` correctly on this box.

Verified on hardware 2026-08-30, after the coprocessor work:

- The rewritten CPU probe still identifies the V30 (FLAGS test routes it into
  the 8086-class branch, `AAD` then splits NEC from Intel). `Has186` comes back
  true and the `db`-encoded 186 immediate shift really does execute -- so the
  whole gating mechanism works end to end, not just in theory.
- The **shift-count test has still never run here**: `AAD` answers NEC first
  and short-circuits it. The 386 branch IS now confirmed: a Gateway 2000
  386SX/25 reports `cpu386` and `Has186` true, 2026-09-19. 186 and 286
  remain unconfirmed.
- The FPU probe runs on a machine with **no** coprocessor without hanging,
  which was the main risk in it. `FPU.EXE` reports `none` and exits 1;
  `BENCH`'s four coprocessor rows skip cleanly.
- The BIOS equipment word disagrees with the probe on this box (see above).

`DEVLOAD.COM` is installed: v3.25 (FreeDOS, GPL2), copied from `E:\DEVLOAD.COM`
to `C:\DOS\DEVLOAD.COM`, which is on the box's PATH. Confirm with
`dosexec "IF EXIST C:\DOS\DEVLOAD.COM ECHO present"`. Its usage is
`DEVLOAD [switches] filename [params]`, which matches what `build_driver_batch`
generates. `dosdrv` is therefore unblocked.

The agent on the box was updated on 2026-08-29 to close the quiet-failure gap:

- `PEND.BAT` is now **served over HTTP** rather than assembled on the DOS side
  with `ECHO`. COMMAND.COM cannot escape a `>` inside an `ECHO`, so the old
  ECHO-built `PEND.BAT` could never contain a redirection — which is what was
  needed to capture DEVLOAD's output at all.
- It runs `DEVLOAD /V` and captures everything to `C:\AGENT\DRVOUT.TXT`, which
  `:TRYIT` now folds into the report. Previously that output went to a screen
  nobody was watching.
- With `--device NAME`, `PEND.BAT` also emits `##DEVICE` or `##DEVFAIL`, and
  `dosctl` turns `##DEVFAIL` into a non-zero exit.

`##RC=0` from `:TRYIT` still only means *the machine survived* — DEVLOAD exits 0
for a character device but returns the first assigned drive number for a block
device, so its errorlevel alone can't be trusted. `--device` is the reliable
check. The live agent is mirrored at `dos/live/AI.BAT`, the pre-change version
at `dos/archive/AI.pre-drvout.bat`, and `C:\AI\AI.BAK` on the box is a rollback
copy.

`dosdrv`'s **plumbing** is now verified on hardware: staging, `PEND.BAT`, the
`TRYING.FLG` guard, cold reboot, and the `##BOOTOK` report with `MEM /C` all
work, and `C:\AGENT` is left clean afterwards.

**But `drvtest/TESTDEV.SYS` is broken — it hangs the machine.** It is not the safe
driver its README claimed. Loaded via `dosdrv` it reported `##BOOTOK` while
silently failing to install (absent from `MEM /C`, `IF EXIST TESTDEV` false);
run directly as `DEVLOAD /V C:\WORK\TESTDEV.SYS` it wedged the machine and needed
a physical reset. Do not use it as a known-good driver. See `drvtest/README.md`.

This is the quiet-failure gap above, observed for real: `##BOOTOK` means "the
machine survived", not "the driver loaded". Always check `MEM /C` and
`IF EXIST <DEVICENAME>`.

`dosctl reboot` is verified: a warm reboot took the box down and back in 28
seconds, the drop-then-return detection worked, and the job loop was healthy
afterwards. `--cold` (full POST) is still untried.

Still not exercised: the `HANG.SYS` crash-recovery path. It deliberately wedges
the box and needs a physical power cycle — only run it when someone is at the
machine.
