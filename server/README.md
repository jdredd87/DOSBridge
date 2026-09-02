# dosbridge

Run and test DOS software on a real 8086-class DOS machine from your Windows 11
command line,
over the PicoMEM's WiFi. Claude Code drives it like any other test runner:
it types `dosrun PROG.EXE`, gets the program's stdout back, and gets the
errorlevel as the exit code.

No MCP server. Claude Code already has a shell; this just gives that shell a
command that happens to execute on a 40-year-old computer.

```
Claude Code  ──shell──>  dosrun PROG.EXE
                              │
                         dosd.py (Windows, ports 8080/8081/8082)
                              │  HTTP  ▲ raw TCP
                              ▼        │
                   AUTOEXEC.BAT loop on the DOS machine
                     HTGET job → run → NC result back
```

---

## What you need

**On Windows 11:** Python 3.8+. Nothing else, no pip installs.

**On the DOS machine:**

| | |
|---|---|
| `NE2000.COM` or `PM2000.COM` | PicoMEM packet driver, from FreddyV's GitHub |
| `HTGET.EXE`, `NC.EXE`, `DHCP.EXE` | from mTCP (Michael Brutman), in `C:\MTCP` |
| `DEVLOAD.COM` | only for `dosdrv`; freeware, not part of DOS 6.22 |
| `REBOOT.COM`, `COLDBOOT.COM` | in `dos/`, 16 bytes each, included here |
| `CHOICE.COM` | ships with DOS 6.22, used as a sleep |

---

## Setup

> **The scripted installer is built with `makeinst.cmd`,** which writes
> `C:\DosBridgeInstaller\` (`server\` for the Windows PC, `client\` to carry to
> the DOS machine). Its sources live in `installer-src\`.
> Inside the built `server\`, `check.cmd` reports what is missing without
> changing anything and `install.cmd` does the PATH and firewall work. The rest
> of this section is the same thing done by hand.

**1. Windows side.** Put this folder anywhere, e.g. `C:\dosbridge`. Add it to
your PATH so Claude Code can call `dosrun` directly. Start the daemon in its own
window and leave it running:

```
C:\dosbridge> dosd.cmd
[10:14:02] dosd listening: http :8080   results :8081   pull :8082
[10:14:02] waiting for the DOS box to poll /job ...
```

**2. Firewall.** This is the step that eats an afternoon if you skip it. Set
the WiFi profile to **Private**, then, in an admin PowerShell:

```powershell
New-NetFirewallRule -DisplayName "dosbridge" -Direction Inbound `
  -Protocol TCP -LocalPort 8080,8081,8082 -Action Allow -Profile Private
```

8082 carries `dospull`'s binary traffic and is as necessary as the other two.

**3. Addresses.** Fill in your own: this PC's LAN address wherever the DOS
agent names the server, and a free address on the same subnet for the DOS
machine (static, from `MTCP.CFG`). Reserve both in your router by MAC, or
exclude the DOS machine's address from the DHCP pool so nothing else grabs it.
Check the `gateway` line in `MTCP.CFG` matches your router.

**4. DOS side.** Create `C:\AGENT` (bridge state), `C:\TOOLS` (tools, put it
on PATH), `C:\WORK` (per-job scratch) and `C:\MTCP`. Copy in
the mTCP binaries, `dos/REBOOT.COM`, `dos/COLDBOOT.COM`, `dos/MTCP.CFG`, and
`dos/AUTOEXEC.BAT`. Edit the top of `AUTOEXEC.BAT`:

```
SET SRV=10.0.0.5:8080         <- put YOUR Windows box's LAN address here
SET UPHOST=10.0.0.5           <- the same address, without the port
...
NE2000.COM 0x60 3 0x300       <- match your PicoMEM IRQ/port
```

> **The files at the top of `dos/` are templates for a fresh install, not a
> mirror of the DOS machine this was developed against.** That machine uses
> `pm2000.com` rather than `NE2000.COM`, keeps mTCP in `C:\NETWORK\MTCP`, and
> runs the agent loop from a separate `C:\AI\AI.BAT`. Copying
> `dos/AUTOEXEC.BAT` onto it would break its networking.
>
> Byte-verified copies of what that box actually runs are in **`dos/live/`**,
> and `dos/README.md` explains the difference. `CLAUDE.md` records the rest of
> the machine's layout.

Reboot. You should see `dosd` log `waiting...` turn into steady polling.

```
C:\dosbridge> dosctl status
DOS box: alive, polled 0.4s ago
```

---

## Using it

```
dosrun build\PROG.EXE                 push, run, capture, return errorlevel
dosrun build\PROG.EXE -v --loop 5     args after the exe pass through
dosrun PROG.EXE --timeout 300         for slow tests
dospush FONT.DAT DATA.BIN             stage on the Windows side only
dosdeploy FONT.DAT C:\WORK            copy onto the DOS box, verified
dospull C:\AI\AI.BAT                  copy a file back, byte-exact
dospull C:\WORK\PROG.EXE --out saved.exe ...to a chosen local path
dosexec "MEM /C" "DIR C:\WORK"        arbitrary DOS commands
dosdrv build\NEWDRV.SYS /i:3          stage a driver, reboot, report
dosdrv build\NEWDRV.SYS --device MYDEV fail unless MYDEV registers
dosreboot [--cold]                    reboot and wait for it to come back
dosctl status                         is it alive?
```

Starting something new, and keeping the DOS side current:

```
dosnew mandel                         scaffold projects\mandel\
dosctl clean [--all]                  delete regenerable build junk
dosctl upgrade --dry-run              what would change on the DOS box
dosctl upgrade                        send new tools + agent, then reboot
dosctl version                        what build the DOS machine is running
makeinst.cmd                          build C:\DosBridgeInstaller
```

Your own work goes in `projects\NAME\`, never in `starter\` (reserved for the
bridge's own tools) and never in the built installer tree (overwritten
wholesale). Staging is namespaced per project, so two projects can both build a
`HELLO.EXE` without one silently clobbering the other.

`dospush` stages a file into `files/` so the DOS box *can* fetch it over `/f/`;
it does not put anything on the box. `dosdeploy` does the whole job — stage,
`HTGET` it down, then confirm with `IF EXIST`, because HTGET exits >= 20 even
when it succeeded.

`dospull` is binary-exact and is the only correct way to get a file back.
It streams over `NC -bin` into a dedicated raw port (8082) that does no
decoding. Do not substitute `dosexec "TYPE ..."` for it on anything but text —
see the file-transfer note below.

A typical Claude Code loop then looks like:

```
fpc -Tmsdos -WmLarge prog.pas  &&  dosrun prog.exe
```

See `starter/README.md` for the cross-compiler setup and `drvtest/README.md`
for testing driver deployment.

Claude reads the compiler errors, fixes them, reads the DOS machine's output,
iterates.
You don't touch the DOS machine.

---

## How driver testing survives a hang

`dosdrv` never writes to `CONFIG.SYS`. That's deliberate: a bad `CONFIG.SYS`
hangs the machine *before* `AUTOEXEC.BAT` runs, so no software on the box can
undo it, and power-cycling just re-runs the same bad config. You'd need hands.

Instead the driver is staged into `PEND.BAT` and loaded via `DEVLOAD` from
`AUTOEXEC.BAT`, **after** the network is already up, behind a flag file:

```
boot ──> NE2000 + DHCP ──> TRYING.FLG present?
                             yes ──> last boot hung. Report it, delete the
                                     staged driver, carry on. Self-healed.
                             no  ──> create flag, DEVLOAD driver, delete flag,
                                     report success + MEM /C output.
```

So a wedged driver costs you one power cycle and reports itself. Nothing is
ever left in a state that won't boot.

**A driver that fails *quietly* is the harder case**, and the crash guard says
nothing about it — surviving the boot is not the same as loading. Pass
`--device NAME` and the staged `PEND.BAT` checks whether the driver actually
registered, emitting `##DEVFAIL` if not, which `dosctl` turns into a non-zero
exit. DEVLOAD's own output is captured to `C:\AGENT\DRVOUT.TXT` and folded into the
report; without that it goes to a screen nobody is watching. This is why
`PEND.BAT` is served over HTTP instead of being built with `ECHO` on the DOS
side: COMMAND.COM has no way to escape a `>` inside an `ECHO`, so an ECHO-built
`PEND.BAT` could never redirect anything.

For a driver that genuinely must live in `CONFIG.SYS`, don't automate it.
Boot from a PicoMEM floppy image with a known-good minimal config and keep the
test surface on the hard disk.

---

## Things that will bite you

**Direct video writes vanish.** `> C:\WORK\OUT.TXT` only captures output that goes
through DOS. Anything writing straight to B800 produces an empty log. Have your
test harnesses print deliberately to stdout.

**A DHCP lease is a time bomb.** `DHCP.EXE` is one-shot — it stamps `IPADDR`,
`TIMESTAMP` and `LEASE_TIME` into `MTCP.CFG` and exits, and nothing renews it.
When the lease expires every mTCP tool refuses to run and the box goes silent.
It cannot recover on its own either: the agent loop retries `HTGET` forever but
never re-runs `DHCP`, so it sits retrying the one thing that cannot work and you
end up walking to the machine. Use a static address — `dos/live/MTCP.CFG` shows
the shape, being the same address DHCP was handing out with the two lease lines
removed.

Easy to misdiagnose, too: from the CLI this looks exactly like `dosd` having
died. Check `netstat` for listeners on 8080/8081/8082 before blaming the daemon.

**Errorlevel is capped at 20.** DOS 6.22 can't read `ERRORLEVEL` into a
variable, so the generated batch ladders `IF ERRORLEVEL n` from 1 to 20. Return
small codes. (Raise `MAX_ERRORLEVEL` in `dosd.py` if you must; it costs a line
of batch each.)

**8.3 names.** `dosctl` uppercases and rejects long names rather than letting
DOS silently truncate.

**Binary files need `dospull`, and `-bin` is load-bearing.** Two separate things
silently corrupt binaries on the way out of DOS. `TYPE` stops at the first 0x1A
(Ctrl-Z), so `dosexec "TYPE PROG.EXE"` returns a truncated prefix. And `NC`
without `-bin` opens stdin in text mode and eats every 0x0D and 0x1A: a
27298-byte `SYSINFO.EXE` arrived as 27258 bytes — corrupt, but the right shape
and size to look plausible. Measured on a 5-byte probe holding both bytes, plain
`NC` delivered 3 and `NC -bin` delivered 5. `dospull` uses `-bin` into port 8082,
which does no decoding, no CRLF folding, and no line splitting; the same file now
round-trips MD5-identical. The inbound direction was never affected — `HTGET`
writes files in binary mode.

**`dosexec` exit codes are only as good as the last command.** DOS internal
commands (`ECHO`, `VER`, `DIR`, `IF`, `DEL`, `TYPE`) never set `ERRORLEVEL`, so
the ladder has nothing of its own to read. `dosd` works around this by running
a 5-byte `EXIT0.COM` immediately before your commands to force a known 0 — it
writes that file into `files/` at startup and the DOS box fetches it once into
`C:\AGENT\`. What this *cannot* fix: a failing internal command still reports 0,
because DOS never told anyone it failed. `DIR C:\NOSUCH` exits 0. Assert on
stdout for those; the exit code is trustworthy only when the last command is an
external program. If `dosexec` starts returning 20 for everything again,
`EXIT0.COM` isn't reaching the DOS box.

**Reserve exit codes.** 253 = driver hung the machine, 254 = file download
failed, 124 = timed out waiting for the DOS box.

---

## Files

```
CLAUDE.md         project instructions for Claude Code -- read this first
installer-src/    authored installer scripts. `makeinst.cmd` turns these
                  plus the tree below into C:\DosBridgeInstaller -- nothing
                  generated is kept in here
projects/         your own work; one folder per project, made by `dosnew NAME`
starter/          FPC cross-compiler setup, test harness, worked examples.
                  Reserved for the bridge's own tools, not for new projects
drvtest/          throwaway drivers for exercising dosdrv's recovery path
dosd.py           the daemon: file serving, job queue, result + binary intake
dosctl.py         the CLI Claude Code drives
dos*.cmd          Windows shims: dosrun, dospush, dosdeploy, dospull, dosexec,
                  dosdrv, dosreboot, dosd
files/            what dosd serves over /f/ -- staged programs, plus the
                  EXIT0.COM it generates on first run
simulate_dos.py   fake DOS box for testing the plumbing without hardware
selftest.py       runs dosd + simulator + CLI end to end
dos/              files that live on the DOS box: templates at the top,
                  dos/live/ mirroring the real machine, dos/archive/ for
                  superseded versions, plus AUTOEXEC.proposed.bat
```

## Tools on the DOS machine

Built from `starter/` and deployed to `C:\TOOLS`. The full list and the traps
are in `CLAUDE.md`; the ones worth knowing about up front:

| | |
|---|---|
| `HWINFO` `SYSINFO` | CPU, coprocessor, BIOS, memory, ports, drives |
| `DSTAT` `DEVS` `MEMMAP` `IVT` `HD` | filesystem, device chain, memory map, vectors, hex dump |
| `SCRAPE` `VSHOT` | capture a text or graphics screen back through DOS |
| `VMODES` `VIDCHK` `VESACHK` | every video mode; `-t` sets each, `-d n` displays it |
| `FPU` `BENCH` `PROFTEST` | coprocessor tests, measured timings, profiling |
| `PKTDRV` `PKTCAP` `ARP` | packet driver probe, frame capture, who-has and `/24` sweeps |
| `SERIAL` `MOUSE` `BEEP` | UART, INT 33h mouse, PC speaker |

Anything that draws to the screen is **invisible over the bridge** — video
writes bypass DOS. Run `SCRAPE` or `VSHOT` in the same job to get the screen
back as text.

Run `python selftest.py` to confirm the Windows half works before you touch
the DOS machine.

## If you are picking this up cold

`CLAUDE.md` is the real reference and is worth reading before changing
anything. The parts that cost the most to rediscover:

* **Exit codes must be <= 20**, filenames are 8.3, and a DOS critical error
  blocks forever and looks exactly like a hang.
* **Output must go through DOS.** `WriteLn` comes back; direct video writes do
  not.
* **Never write `CONFIG.SYS`, and do not deploy `AUTOEXEC.BAT` remotely.** Both
  run before the agent, so a bad one is unrecoverable without hands on the
  machine.
* **A job that reboots cannot report its result** — the machine is gone before
  the reply is sent. Use `dosreboot`, or `dosrun --reboot`.
* **Anything that opens a packet-driver handle must release it.** Exit without
  `release_type` and the driver calls into freed memory, which takes the box
  off the network entirely.
