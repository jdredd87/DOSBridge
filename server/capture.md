# Video capture — seeing the DOS box for real

`doscap` points a USB capture card at the DOS machine's video output, so you
can watch it live, record it, and take stills. It is optional and off unless
configured.

**Everything else in this bridge is the machine reporting on itself.**
`WriteLn` goes through captured stdout, `SCRAPE` reads the text buffer back,
`VSHOT` reads mode 13h back, and `RAYCAST` prints its own ASCII thumbnail
because nothing else could photograph an unchained mode. All of that can only
show what somebody wrote code to show, and only while the box is still
running.

A capture card sees what a monitor sees: POST, the F1 prompt from the dead
CMOS, whichever way the video card lost the boot lottery, a frozen screen with
the last line still on it, and every graphical demo as it actually renders.

It earned its place during its own build. `dosctl status` said:

```
DOS box: STALE, last poll 2518s ago (hung? powered off?)
```

and it cannot do better, because the thing that would have to answer is the
thing that is not running. One frame showed the box sitting in **MS-DOS EDIT
with a dialog open** — somebody had been at the keyboard. Not hung, not off,
and a power cycle would have been exactly the wrong response.

---

## Quick start

You need **ffmpeg** (`ffplay` comes with it and is what draws the live window):

```
winget install Gyan.FFmpeg
```

A winget install is found automatically **even before you restart the shell**,
which is exactly the session you install it in and then try to use it.

Then:

```
doscap devices                    what capture hardware is on this machine
copy capture.example.json capture.json
```

Edit `capture.json` and set `"device"` to the name `doscap devices` printed,
**exactly**. Check it took:

```
doscap status
```

```
ffmpeg  : ...\ffmpeg.exe
device  : USB3.0 Video
audio   : Digital Audio Interface (USB3.0 Audio)
format  : 1600x1200 yuyv422 @ 60 fps
frame   : picture in 0.7s
          rgb(77, 80, 168) average, spread 90.9
saved   : C:\dosbridge\capture\status.png
```

`frame : picture` means a real image arrived. `blank` means a uniform frame —
no signal, a blanked monitor, or a screen that genuinely is one colour.

---

## Watching it live

```
doscap live
```

A window opens showing the DOS box in real time, **with sound**. **Press `q`
or `Esc` in the window to quit.**

```
doscap live                       sound on — this is the one to use
doscap live --mute                silent
doscap live --scale 1600x1200     bigger window (capture is 1600x1200 either way)
```

Sound is on by default because on this rig it is the only way to hear the
AdLib at all. `--mute` turns it off; so does `"preview_audio": false` in the
config.

### `-sync video`, and a throughput problem that wasn't one

Adding audio to the preview made the real-time buffer climb without bound:

```
too full (63% of size: 512000000)! frame dropped!
too full (64% ...)  ... 70% ... 75% ... 76% and still rising
```

That reads as "the machine cannot keep up", and it is worth knowing why that
diagnosis is wrong, because the obvious fixes all do nothing:

| preview | result |
|---|---|
| no audio | **clean, zero warnings** |
| audio, default sync | CLIMBING 63% → 87% |
| audio, 1024x768 — a quarter of the pixels | CLIMBING 63% → 93% |
| audio, 30 fps instead of 60 | CLIMBING 72% → 84% |
| audio, `rtbufsize` 32M instead of 512M | CLIMBING 72% → 108% |
| audio, `-af aresample=async=1000` | CLIMBING 63% → 87% |
| **audio, `-sync video`** | **clean, zero warnings** |

**A throughput problem responds to less work. A clock problem does not.**
ffplay slaves the video clock to the **audio** clock by default. On a capture
stick the two clocks are independent, so video frames are held waiting on
audio timestamps, the dshow queue backs up, and the buffer grows for ever.
Making video the master removes the dependency entirely.

The cost is that audio may drift slightly over a long session, since it now
follows video rather than the reverse. For a preview that is the right trade —
the point is seeing the machine *now*. Use `rec --audio` when the audio has to
be exact; recording has no such problem, because nothing is being synced to a
playback clock.

Note also that a **big `rtbufsize` is a recording setting, not a preview
one**: it made the climb slower to notice, not slower. For live viewing you
want to drop stale frames immediately rather than queue half a gigabyte of
them, which is what `-framedrop` plus a sane clock achieves.

### Audio and video are two separate processes, and that is the design

Worth reading, because the obvious build is the one that sounds bad and it
took three attempts to stop guessing.

Hand ffplay a single dshow input carrying both streams and it has to
reconcile two clocks that are not related to each other — the capture stick's
video clock and its audio clock free-run independently. Whichever one is made
master, the other gets stretched:

* **Audio as master** (ffplay's default) holds video frames waiting on audio
  timestamps, so the real-time buffer climbs without bound — 63% → 87% and
  still rising, dropping frames the whole way.
* **`-sync video`** bounds the buffer but continuously resamples and drops
  audio samples to chase the video clock. That is heard as **choppy or fuzzy
  sound**.

**Neither is a buffering problem, and buffering does not fix either.**
Measured, all with audio in the same process:

| change | result |
|---|---|
| 1024x768 — a quarter of the pixels | still climbing |
| 30 fps instead of 60 | still climbing |
| `rtbufsize` 32M / 512M | still climbing |
| `-af aresample=async=1000` | still climbing |
| `-audio_buffer_size`, dropping `nobuffer` | bounded, still choppy |
| **audio in its own process** | **clean** |

A throughput problem responds to less work. A clock problem does not.

**Confirmed by ear**, which is the only test that counts here — every row
above except the last was also "no errors on screen".

So `doscap live` stops asking for sync at all. **The video capture and the
audio capture are different DirectShow devices**, so two processes can open
them at once — verified, both run clean together. Audio on its own has
nothing to sync to, so ffplay plays the samples exactly as they arrive: the
same condition under which a `rec --audio` file comes back clean. Video on its
own keeps the aggressive low-latency flags, with no audio renderer to starve.

What is given up is A/V sync *between* the two, and for watching a DOS box
that is worth nothing. If sound and picture must line up exactly, record it —
`rec --audio` syncs to no playback clock.

**If it is still choppy**, the one knob left is `audio_buffer_ms` in
`capture.json` (default 100). Raise it to 150–200. That is the *device's*
buffer, and too small starves the renderer.

### The audio player has no window, so it is reaped deliberately

The audio process runs `-nodisp`. If `doscap live` is killed outright rather
than quit with `q`, its cleanup never runs and that player is left holding the
audio device with **nothing on screen to show for it**. So its pid is written
to `capture/live-audio.pid` and the next `doscap live` reaps it first,
checking with `tasklist` that the pid really is an ffplay — pids get reused,
and killing a stale number could take out something else entirely.

Verified: hard-kill the parent, close the stray video window, and the next run
comes up with exactly one audio process rather than two.

### It will look frozen, and it almost certainly is not

This is the first thing everyone hits. **An idle DOS console is a still
image.** The agent loop prints nothing while it waits for work — the only
thing moving on the entire screen is `UGET`'s one-character spinner.

Measured on a 4-second idle recording, comparing frames against the first:

| frames apart | pixels changed, of 1,920,000 |
|---|---|
| 1.0 s | 137 |
| 2.0 s | 32 |
| 3.0 s | 197 |

That is the spinner and nothing else. The picture is live; the machine is
simply not doing anything.

**To convince yourself, make it move.** In another window:

```
dosexec "C:\TOOLS\MATRIX.EXE 20"          falling green text, unmistakable
dosexec "C:\TOOLS\RAYCAST.EXE SECS 20"    the maze walk, in mode X
```

### Running it manually, without the wrapper

`doscap live` is a thin wrapper. The raw command is worth knowing, because it
is what you adjust when something is wrong:

The video window — this is all `--mute` runs, and it is also exactly what
plain `doscap live` runs for the picture:

```
ffplay -f dshow -rtbufsize 512M ^
       -video_size 1600x1200 -framerate 60 -pixel_format yuyv422 ^
       -i "video=USB3.0 Video" -an ^
       -fflags nobuffer -flags low_delay -framedrop ^
       -x 1280 -y 960
```

The sound, as a **separate process** — start it first, leave it running:

```
ffplay -nodisp -f dshow -audio_buffer_size 100 ^
       -i "audio=Digital Audio Interface (USB3.0 Audio)"
```

`-nodisp` means it has no window, so remember it is there: quit it from the
terminal it was started in, or it keeps the audio device open invisibly.
`doscap live` handles that for you.

Substitute your own device name — `USB3.0 Video` is what this particular
capture stick happens to be called, and the name belongs to one machine.

| flag | why |
|---|---|
| `-rtbufsize 512M` | **not optional** — see below |
| `-fflags nobuffer -flags low_delay` | show frames as they arrive |
| `-framedrop` | keep up with the clock rather than falling behind |
| `-x -y` | 1600x1200 does not fit on most desktops |

**`-t` does not work on a live capture.** dshow timestamps start at a huge
value rather than zero, so a duration limit is computed against nonsense and
ignored — asking for `-t 4` gave a window that ran for 169 seconds. The same
quirk made ffmpeg's `fps` filter emit 22 stills for a 6-second window. Quit
the window instead.

### You cannot watch and record at the same time

**The capture device is exclusive.** One program at a time. While a preview is
open, `doscap shot` and `doscap rec` both fail — cleanly and immediately, with
"device already in use", rather than hanging.

Piping ffmpeg into ffplay so one device open feeds both a file and a window
**was tried and does not work here**: this ffmpeg build has no `sdl` output
device, and the `pipe:1 | ffplay` version hung instead of exiting and had to
be killed, while still holding the card. Do not reach for it.

So: **record, then watch the recording.** `doscap rec 30 --shots 8` gives you
the video and eight stills out of it, from a single device open.

---

## The commands

```
doscap devices                what capture hardware is on this machine
doscap modes                  what the configured device can produce
doscap status                 device present? is a picture arriving?
doscap live                   live preview WITH SOUND (q to quit)
                              --mute, --scale WxH
doscap shot [FILE]            one still
doscap rec SECS [FILE]        record. --audio, --shots N
doscap burst N [--every S]    a series of stills, S seconds apart
doscap still REC SECS [FILE]  pull one frame out of a recording
```

`devices` works with **no `capture.json` at all**, because it is what you need
in order to write one. Everything else needs the config.

Output lands in `capture/` (override with `out_dir`), named with a timestamp
unless you give a filename. That directory is gitignored.

### Examples

```
doscap shot                             one still, timestamped
doscap shot before.png                  one still, named

doscap rec 30                           30 seconds of video
doscap rec 30 --audio                   ...with the sound card's audio
doscap rec 45 demo.mp4 --shots 8        ...and 8 stills pulled out of it

doscap burst 6 --every 2                6 stills, 2 seconds apart
doscap still demo.mp4 12.5              the frame at 12.5 seconds
```

Recording a demo, in two windows — the recording has to start first, because
a job takes a few seconds to be picked up:

```
window 1:   doscap rec 45 raycast.mp4 --audio --shots 8
window 2:   dosexec "C:\TOOLS\RAYCAST.EXE SECS 20"
```

---

## How it works

There is no clever machinery. `capture.py` builds an ffmpeg command line,
runs it under a hard timeout, and checks the file appeared:

```
capture card  --DirectShow-->  ffmpeg  -->  PNG  or  H.264 MP4
                                  |
                            capture.py  (timeout, error translation)
                                  |
                             dosctl capture  -->  doscap.cmd
```

* **Stills** ask for `warmup_frames` frames and keep the last, written with
  `-update 1` so each overwrites the same file. The first frame out of a
  capture device can be whatever was in its buffer before we opened it.
* **Recordings** are H.264 in an MP4, optionally with the HDMI audio.
* **`--shots N`** runs *after* the recording finishes and extracts frames from
  the file, spaced at `(i + 0.5)/N` through it — inside the clip rather than
  from zero, so the first is not the device still settling. It works this way
  because the device is exclusive and cannot be opened twice.
* **`analyse`** loads the PNG with Pillow and takes the per-channel standard
  deviation. Below 1.0 the frame is uniform, which is what "no signal" looks
  like. That is how `status` distinguishes a picture from a blank screen
  without knowing what the picture should be.

Every ffmpeg call is bounded by a timeout and every failure is translated into
a sentence that says what to do. `doscap live` is the **one** exception with no
timeout, and it is the exception because a person is sitting in front of it.

---

## Four things that were measured, not guessed

**The device is exclusive.** A second capture fails with "already in use" —
promptly and cleanly, *not* as a hang, which is the failure this project
actually fears.

**`rtbufsize` is a correctness setting, not a tuning knob.** ffmpeg's default
real-time buffer is about 3 MB. One 1600x1200 yuyv422 frame is **3.84 MB** —
less than a single frame — so it drops frames before it has a whole one, and
says so. Raise it with the **resolution**, not with the length of the
recording.

**x264 `ultrafast` keeps up and `veryfast` does not.** Over 8 seconds at
1600x1200x60:

| | frames | drops | size |
|---|---|---|---|
| x264 `ultrafast` | 481 | **0** | 3.1 MB |
| x264 `veryfast` | — | **dropped** | — |
| MJPEG stream-copy | 480 | 0 | **80 MB** |

MJPEG drops nothing either, but it is 26x the size and recompresses text
badly — and text is most of what a DOS screen is. **If a capture ever drops
frames, make the preset faster before you make anything else smaller.**

**A recording survives a DOS video mode change.** This was expected to be the
weak point and it is not. Across a whole `RAYCAST SECS 20` run — text to
unchained mode X and back — the recording was **2701 frames in 45.016
seconds, exactly 60 fps, zero drops**, one continuous valid MP4.

What the switch costs is about a second of **black** while the converter
re-syncs: a still sampled during it reads a uniform `rgb(0,0,0)`, spread 0.0.
So a mode change costs frames of content, not the recording. Sample a still
near one and expect `blank`.

---

## The sound: the AdLib yes, the PC speaker NO

`rec --audio` and `live --audio` take the `Digital Audio Interface` the same
stick presents over HDMI.

**Measured, because the obvious assumption was wrong.** The PC speaker is a
buzzer soldered to the motherboard and the AdLib feeds a sound card; only one
of them has an electrical path into the converter's audio input, and guessing
which would have been a coin flip. Three recordings, same setup:

| what was playing | RMS | Peak |
|---|---|---|
| nothing — box idle | −65.3 dB | −77.4 dB |
| **`MOZART` — PC speaker** | **−64.9 dB** | **−77.3 dB** |
| `RAYCAST` — AdLib/OPL2 | **−27.7 dB** | −40.8 dB |

`MOZART` is **0.5 dB from silence**: the PC speaker does not reach the capture
at all. The AdLib is **37 dB above the noise floor** and comes through loudly.

So this makes `AMOZART`, `RAYCAST`'s music and anything else on the OPL2
checkable from another machine for the first time. It does **not** help with
`MOZART`, `BEEP`, or `RAYCAST SPKR` — for those the speaker gate bits in the
program's own PASS/FAIL output remain the only evidence, and somebody has to
be in the room to hear them.

**The wiring is why**, and it is deliberate on this rig: the sound card's
line-out is patched into the converter's audio input, so anything the card
plays is embedded into the HDMI stream. The PC speaker is not on that path
and no cable can put it there without a mixer.

So this is **one machine's wiring**, not a property of capture sticks — a rig
with nothing patched in captures no sound at all, and one with the speaker
mixed in would read differently. Measure yours the same way rather than
trusting the table.

**And it has been listened to.** A `RAYCAST` recording was played back and
the OPL2 music is clean — so the audio path is confirmed end to end, by ear,
and not merely measured to be above a noise floor. That last step needed a
person: nothing here can tell the difference between a tune and 37 dB of the
wrong thing.

---

## Configuration

`capture.json`, beside `capture.py`. Copy `capture.example.json`, which
documents every key inline. The live file is **gitignored and never ships** —
same rule as `power.json`.

The reason differs, though. A smart plug is off by default because cutting
mains power is dangerous. Capture is off by default because **the DirectShow
device name belongs to one machine**, so a shipped default would be wrong
everywhere else.

| key | |
|---|---|
| `device` | DirectShow name, exactly as `doscap devices` prints it |
| `audio_device` | the HDMI audio, or `null` to disable `--audio` |
| `video_size`, `framerate` | ask `doscap modes` what is available |
| `pixel_format` | `yuyv422` uncompressed, or `mjpeg` |
| `rtbufsize` | see above — scale with resolution |
| `warmup_frames` | frames discarded before a still |
| `preset`, `crf` | x264 speed and quality |
| `preview_size` | window size for `doscap live` |
| `preview_audio` | sound on in the preview (default `true`) |
| `audio_buffer_ms` | device audio buffer; raise it if sound is choppy |
| `out_dir` | where files land; `null` = `<dosbridge>/capture` |
| `ffmpeg`, `ffprobe`, `ffplay` | full paths, only if not on PATH |
| `open_timeout` | seconds before giving up on the device |

`DOSBRIDGE_CAPTURE` overrides the config path; setting it **empty** disables
the feature outright even if a file exists.

**`doscap devices` offers a device name only when there is exactly one.** This
machine has a webcam as well as the capture stick and they are
indistinguishable from the enumeration — naming the webcam because it sorted
first would be a confident wrong answer rather than no answer.

---

## When it goes wrong

Every failure is fast and says what to do. Nothing waits, because everything
in this project that ever needed hands on the keyboard looked like a hang
first.

| symptom | what it means |
|---|---|
| `the capture device is already in use` | something else has it — a preview, a `rec`, OBS. It is exclusive |
| `** NOT FOUND **` and a list | the name in `capture.json` does not match; `status` lists what *is* present |
| `could not open the capture device` | unplugged, or the name is wrong |
| `No capture device configured` | no `capture.json` yet |
| `ffmpeg not found` | `winget install Gyan.FFmpeg`, or set the path in the config |
| `timed out after 30s` | the device did not open. Nothing on the DOS box was touched |
| frame reads `blank` | no signal, a blanked monitor, or a mode change in progress |
| the preview looks frozen | the DOS box is idle. See above — it is almost never the capture |
| dropped frames in a recording | raise `rtbufsize`, then make `preset` faster |

If the device gets stuck after something was killed, the holder is an orphaned
process:

```
Get-Process ffmpeg,ffplay | Stop-Process -Force
```

---

## What this is not

**It is a second opinion, not a replacement.** `SCRAPE` and `VSHOT` read the
framebuffer and give exact bytes. This gives photons, after a VGA-to-HDMI
converter has scaled them and a capture chip has subsampled the colour. Text
is legible and geometry is faithful, but **do not CRC a captured frame or read
exact pixel values out of one.** Use it for what is on the screen, and the
existing tools for what is exactly in the buffer.

**It is not a frame-rate instrument.** The box's text and mode 13h output is
**70 Hz**, the capture is **60 Hz**, and there is a scaler in between doing its
own thing. A recording duplicates and drops frames against the original **by
construction**. It shows what was drawn; it cannot say how fast. `RAYCAST`'s
own reported fps and `modex.pas`'s `FlipLate` remain the measurements.

**Still unmeasured:** whether a mode the converter cannot lock at all — an
SVGA mode from `VMODES -t`, say — gives the same clean one-second black gap or
actually drops the stream.

---

## What it has already settled

The long-running complaint that RAYCAST's walls "render really strange
looking" at oblique angles, which `SCRAPE` and the ASCII thumbnail could never
show. In a captured mode X frame the top edge of every oblique wall steps in
**4-pixel jumps** and each mortar line is broken into 4-pixel segments instead
of running as a straight diagonal.

The step size matches the ray width exactly: **80 rays across 320 pixels**. It
is a resolution artifact, not a bug, and it is consistent with the pivot-cache
measurement in `docs/raycast.md` rather than an alternative to it.

Note that `RAYCAST COARSE` is only **half** an A/B for this. It halves the
column to 2 px and the geometry edges do visibly smooth — but `raycast.pas`
line 3542 reads `if not UseX then Textured := False`, and `COARSE` sets
`WantX := False`, so a `COARSE` frame is flat-shaded and always will be. It
can show the wall-edge half of the symptom and can never show the texture
half.
