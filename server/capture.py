#!/usr/bin/env python3
r"""
DOS Bridge  --  StevenC

capture.py -- optional video capture, so the DOS box's REAL video output can
be seen, recorded and photographed from the Windows side.

WHY THIS EXISTS
---------------
Everything else in this bridge reads the DOS box through DOS: WriteLn goes
through the captured stdout, SCRAPE reads the text buffer back, VSHOT reads
mode 13h back, and the raycaster prints its own ASCII thumbnail because
nothing else could photograph an unchained mode. All of that is the machine
REPORTING on itself, and it can only report what somebody wrote code to
report -- and only while it is still running.

A capture card is the first thing here that does not go through DOS at all.
It sees what a monitor sees: POST, the F1 prompt from the dead CMOS, a mode
the card came up in that nothing predicted, a frozen screen with the last
line still on it, and every graphical demo exactly as it renders rather than
as its own thumbnail describes it.

The case that proves it: `dosctl status` says "STALE, last poll 2518s ago
(hung? powered off?)" and cannot do better, because the thing that would have
to answer is the thing that is not running. One frame off the capture card
showed the box sitting in MS-DOS EDIT with a dialog open -- somebody had been
at the keyboard. Not hung, not off, and a power cycle would have been exactly
the wrong response.

IT IS A SECOND OPINION, NOT A REPLACEMENT
-----------------------------------------
SCRAPE and VSHOT read the framebuffer and give exact bytes. This gives
photons, after a VGA-to-HDMI converter has scaled them and a capture chip has
subsampled the colour. Text is legible and geometry is faithful, but do not
CRC a captured frame or read exact pixel values out of one. Use it for "what
is on the screen", and the existing tools for "what exactly is in the buffer".

WHAT THE HARDWARE HERE TURNED OUT TO DO
---------------------------------------
Measured, not assumed -- and none of it is baked in as a default, because
every one of these numbers belongs to one particular capture stick:

  * The device is EXCLUSIVE. A second capture while one is running fails with
    "device already in use", promptly and cleanly. It does not hang, which is
    the failure mode this project actually fears. `rec --shots N` therefore
    records first and extracts stills from the recording afterwards, rather
    than trying to hold the device open twice.
  * `rtbufsize` must be raised a long way. The default is about 3 MB and one
    1600x1200 yuyv422 frame is 3.84 MB -- less than a single frame of buffer,
    so it drops frames immediately and says so.
  * x264 `ultrafast` keeps up with 1600x1200 at 60 fps and `veryfast` does
    not. Measured over 8 seconds: ultrafast 481 frames and zero drops at
    3.1 MB, veryfast dropped frames. MJPEG stream-copy also drops nothing but
    is 26x the size (80 MB for the same 8 seconds).
  * The first frame out of the device can be stale, so a snapshot asks for a
    few frames and keeps the last.

THE FRAME RATE IS NOT AN INSTRUMENT
-----------------------------------
Worth stating plainly, because this file sits in a project that measures
frame rates carefully. The DOS box's text and mode 13h output is 70 Hz, the
capture is 60 Hz, and there is a scaler in between doing its own thing. A
captured video therefore duplicates and drops frames against the original by
construction. It shows you WHAT was drawn; it cannot tell you how fast.
`RAYCAST`'s own reported fps and `FlipLate` remain the measurements.

CONFIGURATION
-------------
A JSON file, `capture.json`, beside this script. It is deliberately NOT
created by the installer or by any code here -- `capture.example.json` is
shipped to be copied and edited, the same rule as `power.json` and for the
same reason: a kit that arrived carrying somebody else's device name, or that
overwrote a working local config on upgrade, would be worse than not having
the feature.

Configuration is required rather than auto-detected because the device NAME
is a property of one machine. `doscap devices` prints the JSON to paste.

`DOSBRIDGE_CAPTURE` overrides the path; setting it empty disables the feature
outright even if a file exists.
"""

import glob
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("DOSBRIDGE_CAPTURE",
                             os.path.join(HERE, "capture.json"))

DEFAULTS = {
    "device": None,
    "audio_device": None,

    # 4:3 at 1600x1200 is what this stick offers and what a DOS box wants;
    # anything here is only a default, and `doscap modes` lists the truth for
    # whatever device is actually plugged in.
    "video_size": "1600x1200",
    "framerate": 60,

    # yuyv422 is uncompressed off the stick. mjpeg is the alternative and is
    # cheaper on USB but recompresses text badly.
    "pixel_format": "yuyv422",

    # One 1600x1200 yuyv422 frame is 3.84 MB and ffmpeg's default real-time
    # buffer is smaller than that, so it drops frames before it has a whole
    # one. This is not a tuning knob so much as a correctness one.
    "rtbufsize": "512M",

    # The first frame off a capture device can be whatever was in the buffer
    # before we opened it. Ask for a few and keep the last.
    "warmup_frames": 6,

    # ultrafast keeps up at 1600x1200x60 here; veryfast does not.
    "preset": "ultrafast",
    "crf": 23,

    "out_dir": os.path.join(HERE, "capture"),

    # Window size for `doscap live`. Smaller than the capture on purpose --
    # 1600x1200 does not fit on most desktops, and the preview is for
    # watching, not for reading exact pixels.
    "preview_size": "1280x960",

    # Sound is ON by default in the preview. `--mute` turns it off.
    "preview_audio": True,

    # Milliseconds of audio the capture device buffers before handing it over.
    # Too small and the audio renderer starves, which sounds choppy; too large
    # and sound lags the picture. 0 means the device's own default.
    "audio_buffer_ms": 100,

    # Explicit paths, if ffmpeg is not on PATH.
    "ffmpeg": None,
    "ffprobe": None,
    "ffplay": None,

    # A capture that cannot open its device must FAIL, not wait. Everything
    # in this project that ever needed hands on the keyboard looked like a
    # hang first.
    "open_timeout": 30,
}


class CaptureError(Exception):
    pass


# ---------------------------------------------------------------- tools ---

def _winget_ffmpeg(name):
    """Find a winget-installed ffmpeg, whose shim is not on PATH until the
    shell is restarted -- which is exactly the session somebody installs it
    in and then tries to use it."""
    root = os.path.join(os.environ.get("LOCALAPPDATA", ""),
                        "Microsoft", "WinGet", "Packages")
    hits = glob.glob(os.path.join(root, "*FFmpeg*", "**", "bin", name),
                     recursive=True)
    return sorted(hits)[-1] if hits else None


def tool(cfg, which="ffmpeg"):
    """Locate ffmpeg/ffprobe: configured path, then PATH, then winget."""
    exe = which + (".exe" if os.name == "nt" else "")
    cfgd = (cfg or {}).get(which)
    if cfgd:
        if not os.path.isfile(cfgd):
            raise CaptureError("%s configured as %r, which is not a file"
                               % (which, cfgd))
        return cfgd
    found = shutil.which(which) or _winget_ffmpeg(exe)
    if not found:
        raise CaptureError(
            "ffmpeg not found. Install it (winget install Gyan.FFmpeg) or "
            "set \"%s\" in capture.json to its full path." % which)
    return found


def _run(argv, timeout, expect_file=None):
    """Run ffmpeg with a hard timeout. Returns (rc, combined output)."""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise CaptureError(
            "timed out after %gs waiting for the capture device.\n"
            "        Nothing was killed on the DOS box -- this is the Windows "
            "side giving up\n"
            "        rather than hanging. Check the device is not open in "
            "another program." % timeout)
    out = (p.stdout or b"").decode("utf-8", "replace")

    if p.returncode != 0 or (expect_file and not os.path.isfile(expect_file)):
        low = out.lower()
        if "already in use" in low or "could not run graph" in low:
            raise CaptureError(
                "the capture device is already in use.\n"
                "        It is exclusive -- one capture at a time. Close OBS "
                "or whatever else\n"
                "        has it open, or wait for a `doscap rec` to finish. "
                "To get stills out\n"
                "        of a recording instead, use `doscap still`.")
        if "i/o error" in low or "no such device" in low:
            raise CaptureError(
                "could not open the capture device.\n"
                "        Check it is plugged in and that the name in "
                "capture.json matches\n"
                "        `doscap devices` exactly.")
        tail = "\n".join(l for l in out.splitlines()
                         if l.strip())[-1200:]
        raise CaptureError("ffmpeg failed (rc %s):\n%s" % (p.returncode, tail))
    return p.returncode, out


# --------------------------------------------------------------- config ---

# Which DOS box this process is capturing, and what it overrides.
#
# capture.json stays the schema and this supplies per-box overrides on top of
# it. That split is deliberate: about twenty of the fields in there --
# rtbufsize, preset, warmup_frames, open_timeout -- are properties of the
# capture stick and this PC rather than of any DOS box, and duplicating them
# per machine guarantees they drift. Genuinely per box: device,
# audio_device, out_dir.
_SCOPE = {"box": None, "over": {}}


def set_scope(box, over=None):
    """Capture this box from now on. box=None is the single-machine case."""
    _SCOPE["box"] = box
    _SCOPE["over"] = dict(over or {})


def scope_box():
    return _SCOPE["box"]


def load(path=None):
    """Read capture.json. Returns None when the feature is not configured,
    which is the normal answer -- no capture.json ships with the installer."""
    path = path or CONFIG_PATH
    if path == "" or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except ValueError as e:
        raise CaptureError("%s is not valid JSON -- %s" % (path, e))
    if not isinstance(raw, dict):
        raise CaptureError("%s must contain a JSON object" % path)

    cfg = dict(DEFAULTS)
    # Keys beginning with _ are comments, the same convention power.json uses
    # for a format that has none.
    cfg.update({k: v for k, v in raw.items() if not k.startswith("_")})
    cfg.update({k: v for k, v in _SCOPE["over"].items()
                if not k.startswith("_")})
    if _SCOPE["box"]:
        cfg["box"] = _SCOPE["box"]
    if not cfg.get("device"):
        raise CaptureError("%s has no \"device\" -- run `doscap devices`"
                           % path)
    return cfg


def out_path(cfg, name):
    d = cfg.get("out_dir") or os.path.join(HERE, "capture")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, name)


def stamp(prefix, ext):
    return "%s-%s.%s" % (prefix, time.strftime("%Y%m%d-%H%M%S"), ext)


# ------------------------------------------------------------ enumerate ---

def list_devices(cfg=None):
    """Every DirectShow capture device. Works with no capture.json at all,
    because it is what you need in order to write one."""
    ff = tool(cfg, "ffmpeg")
    argv = [ff, "-hide_banner", "-list_devices", "true",
            "-f", "dshow", "-i", "dummy"]
    p = subprocess.run(argv, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=60)
    text = (p.stdout or b"").decode("utf-8", "replace")

    video, audio = [], []
    for line in text.splitlines():
        line = line.strip()
        if line.endswith('" (video)') or line.endswith('" (audio)'):
            name = line[line.index('"') + 1:line.rindex('"')]
            (video if line.endswith("(video)") else audio).append(name)
    return video, audio


def list_modes(cfg):
    """What the configured device can actually produce."""
    ff = tool(cfg, "ffmpeg")
    argv = [ff, "-hide_banner", "-f", "dshow", "-list_options", "true",
            "-i", "video=%s" % cfg["device"]]
    p = subprocess.run(argv, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=60)
    text = (p.stdout or b"").decode("utf-8", "replace")

    modes = []
    for line in text.splitlines():
        if "max s=" not in line:
            continue
        # Two lines are printed per mode, the second with colour metadata.
        if line.rstrip().endswith(")"):
            continue
        fmt = None
        for key in ("pixel_format=", "vcodec="):
            if key in line:
                fmt = line.split(key, 1)[1].split()[0]
                break
        size = line.split("max s=", 1)[1].split()[0]
        fps = line.rsplit("fps=", 1)[1].strip()
        modes.append((fmt, size, fps))
    return modes


# -------------------------------------------------------------- capture ---

def _input_args(cfg):
    return [
        "-f", "dshow",
        "-rtbufsize", str(cfg["rtbufsize"]),
        "-video_size", str(cfg["video_size"]),
        "-framerate", str(cfg["framerate"]),
        "-pixel_format", str(cfg["pixel_format"]),
        "-i", "video=%s" % cfg["device"],
    ]


def shot(cfg, path=None, scale=None):
    """One still. Grabs a few frames and keeps the last -- see warmup_frames."""
    path = path or out_path(cfg, stamp("shot", "png"))
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)

    argv = [tool(cfg, "ffmpeg"), "-hide_banner", "-loglevel", "warning"]
    argv += _input_args(cfg)
    argv += ["-frames:v", str(max(1, int(cfg["warmup_frames"])))]
    if scale:
        argv += ["-vf", "scale=%s:flags=lanczos" % scale]
    argv += ["-update", "1", "-y", path]

    _run(argv, timeout=float(cfg["open_timeout"]), expect_file=path)
    return path


def record(cfg, secs, path=None, audio=False, shots=0):
    """Record `secs` seconds. Optionally pull `shots` evenly spaced stills out
    of the finished file afterwards -- the device is exclusive, so they cannot
    be taken while it is recording."""
    path = path or out_path(cfg, stamp("rec", "mp4"))
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)

    argv = [tool(cfg, "ffmpeg"), "-hide_banner", "-loglevel", "warning"]
    argv += _input_args(cfg)
    if audio:
        if not cfg.get("audio_device"):
            raise CaptureError(
                "no \"audio_device\" in capture.json.\n"
                "        HDMI carries the box's PC speaker and AdLib output, "
                "which is the\n"
                "        only way to check the sound demos remotely. Run "
                "`doscap devices`.")
        argv += ["-f", "dshow", "-rtbufsize", str(cfg["rtbufsize"]),
                 "-i", "audio=%s" % cfg["audio_device"]]

    argv += ["-t", str(secs),
             "-c:v", "libx264", "-preset", str(cfg["preset"]),
             "-crf", str(cfg["crf"]), "-pix_fmt", "yuv420p"]
    argv += (["-c:a", "aac", "-b:a", "128k"] if audio else ["-an"])
    argv += ["-y", path]

    # The device open itself is what can stall; the recording then takes as
    # long as it was told to.
    _run(argv, timeout=float(secs) + float(cfg["open_timeout"]) + 15,
         expect_file=path)

    made = []
    if shots > 0:
        base = os.path.splitext(path)[0]
        for i in range(shots):
            # Spread them inside the clip rather than from 0, so the first is
            # not the device still settling.
            at = (float(secs) * (i + 0.5)) / shots
            p = "%s-%02d.png" % (base, i + 1)
            try:
                still(cfg, path, at, p)
                made.append(p)
            except CaptureError:
                pass
    return path, made


def still(cfg, video, at, path=None):
    """Pull one frame out of an existing recording."""
    if not os.path.isfile(video):
        raise CaptureError("no such recording: %s" % video)
    path = path or "%s-%.2fs.png" % (os.path.splitext(video)[0], float(at))
    argv = [tool(cfg, "ffmpeg"), "-hide_banner", "-loglevel", "error",
            "-ss", str(at), "-i", video,
            "-frames:v", "1", "-update", "1", "-y", path]
    _run(argv, timeout=60, expect_file=path)
    return path


def burst(cfg, count, every, prefix=None):
    """A series of stills spaced `every` seconds apart, for watching something
    change without holding the device open for a whole recording."""
    prefix = prefix or out_path(cfg, stamp("burst", ""))[:-1]
    made = []
    for i in range(count):
        if i:
            time.sleep(max(0.0, every))
        made.append(shot(cfg, "%s-%02d.png" % (prefix, i + 1)))
    return made


def _audio_pidfile(cfg):
    """One pidfile per DEVICE, not one per machine.

    Two capture sticks can preview at once and each needs its own ffplay
    tracked separately; a single pidfile would make the second preview kill
    the first one's audio. Keyed on the box when there is one, because that
    is what names the device here -- and the bare name is kept for the
    single-machine case so an ffplay started before this change is still
    found and cleaned up.
    """
    d = cfg.get("out_dir") or os.path.join(HERE, "capture")
    box = cfg.get("box") or _SCOPE["box"]
    return os.path.join(d, "live-audio%s.pid" % ("-" + box if box else ""))


def _is_ffplay(pid):
    """True if that pid really is an ffplay right now.

    Checked rather than assumed, because pids get reused: killing a stale
    number could take out something else entirely.
    """
    try:
        out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"],
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=15)
        return b"ffplay" in (out.stdout or b"").lower()
    except Exception:
        return False


def _reap_audio(cfg):
    """Kill an audio player left behind by a previous run that was killed."""
    pf = _audio_pidfile(cfg)
    try:
        with open(pf, "r") as f:
            pid = int(f.read().strip())
    except Exception:
        return
    if _is_ffplay(pid):
        try:
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=15)
        except Exception:
            pass
    try:
        os.remove(pf)
    except OSError:
        pass


def live(cfg, size=None, audio=None):
    """A live preview window. Blocks until you quit it with `q` or Esc.

    AUDIO AND VIDEO ARE TWO SEPARATE PROCESSES, AND THAT IS THE WHOLE DESIGN.

    The obvious build hands ffplay one dshow input carrying both, and it
    sounds bad. ffplay has to reconcile two clocks that are not related --
    the capture stick's video clock and its audio clock free-run
    independently -- and whichever one is made master, the other gets
    stretched. Slaving video to audio makes the real-time buffer climb
    without bound (63% -> 87% and rising, dropping frames the whole way).
    Slaving audio to video bounds the buffer but resamples and drops audio
    samples continuously, which is heard as choppy or fuzzy sound.

    Both of those were built and measured before this was. Neither is
    fixable by buffering: 1024x768 (a quarter of the pixels), 30 fps instead
    of 60, rtbufsize from 32M to 512M and -af aresample=async all changed
    NOTHING, while the same command with -an was perfectly clean.

    The fix is to stop asking for sync at all. The video capture and the
    audio capture are DIFFERENT DirectShow devices, so they can be opened by
    different processes at the same time -- verified, both run clean
    together. Audio on its own has nothing to sync to, so ffplay plays the
    samples exactly as they arrive, which is the same condition under which
    a `rec --audio` file comes back clean. Video on its own gets the
    aggressive low-latency flags with no audio renderer to starve.

    What is given up is A/V sync between the two windows, and for watching a
    DOS box that is worth nothing at all. If sound and picture ever must line
    up exactly, record with `rec --audio`, which syncs to no playback clock.

    IT WILL LOOK FROZEN, AND USUALLY IT IS NOT. An idle DOS console is a
    still image -- the agent loop prints nothing while it waits, so the only
    thing moving on the whole screen is UGET's one-character spinner.
    Measured over a 4-second idle recording: between frames a second apart,
    137 pixels changed out of 1,920,000. That is the spinner. Run something
    that obviously animates (`MATRIX`, `RAYCAST`) to convince yourself.

    `-t` DOES NOT WORK HERE. dshow timestamps start at a huge value rather
    than zero, so a duration limit is computed against nonsense and ignored
    -- the same quirk that made ffmpeg's `fps` filter emit 22 stills for a
    6-second window. Quit the window instead.
    """
    fp = tool(cfg, "ffplay")
    if audio is None:
        audio = bool(cfg.get("preview_audio", True))
    size = size or cfg.get("preview_size") or "1280x960"
    try:
        w, h = size.lower().split("x")
        int(w), int(h)
    except ValueError:
        raise CaptureError("preview size should look like 1280x960, not %r"
                           % size)

    aud = None
    if audio:
        if not cfg.get("audio_device"):
            raise CaptureError(
                "no \"audio_device\" in capture.json -- run `doscap devices`.")
        # An audio player started here has -nodisp, so it has NO WINDOW. If
        # this process is killed outright the finally below never runs and
        # that player is left holding the audio device with nothing on screen
        # to show for it -- invisible, and it would silently double up the
        # next time. So the pid is written down and any previous one is
        # reaped first.
        _reap_audio(cfg)
        aud_argv = [fp, "-hide_banner", "-loglevel", "error", "-nodisp",
                    "-f", "dshow"]
        ms = int(cfg.get("audio_buffer_ms") or 0)
        if ms > 0:
            aud_argv += ["-audio_buffer_size", str(ms)]
        aud_argv += ["-i", "audio=%s" % cfg["audio_device"]]
        try:
            aud = subprocess.Popen(aud_argv, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        except OSError as e:
            raise CaptureError("could not start audio playback -- %s" % e)
        try:
            pf = _audio_pidfile(cfg)
            os.makedirs(os.path.dirname(pf), exist_ok=True)
            with open(pf, "w") as f:
                f.write(str(aud.pid))
        except OSError:
            pass

    argv = [fp, "-hide_banner", "-loglevel", "warning"]
    argv += _input_args(cfg)
    # No audio in this process at all, so nothing can starve and there is
    # no second clock to reconcile -- which is what lets the aggressive
    # low-latency flags be unconditional here.
    argv += ["-an", "-fflags", "nobuffer", "-flags", "low_delay", "-framedrop",
             "-x", w, "-y", h,
             "-window_title", "DOS box -- %s (q to quit)" % cfg["device"]]

    # Deliberately no timeout: it is interactive and ends when the user says
    # so. Everything else in this module is bounded because it runs
    # unattended; this one is the exception, and it is the exception because
    # a person is sitting in front of it.
    #
    # The audio process MUST be torn down on every exit path, including
    # Ctrl-C and an ffplay that fails to start -- an orphaned one keeps the
    # audio device open and is invisible, since it has no window.
    try:
        return subprocess.call(argv)
    except KeyboardInterrupt:
        return 0
    finally:
        if aud is not None:
            try:
                aud.terminate()
                aud.wait(timeout=5)
            except Exception:
                try:
                    aud.kill()
                except Exception:
                    pass
            try:
                os.remove(_audio_pidfile(cfg))
            except OSError:
                pass



# --------------------------------------------------------------- signal ---

def analyse(path):
    """Is there a picture, or a blank screen? Returns (verdict, detail).

    A capture with no source, or a monitor-off screen, comes back as a
    perfectly uniform frame. Standard deviation separates that from a real
    picture without needing to know what the picture should be.
    """
    try:
        from PIL import Image, ImageStat
    except ImportError:
        return "unknown", "Pillow is not installed, so the frame was not checked"

    with Image.open(path) as im:
        im = im.convert("RGB")
        st = ImageStat.Stat(im)
        mean = tuple(round(v) for v in st.mean)
        spread = max(st.stddev)

    if spread < 1.0:
        return "blank", ("uniform rgb%s -- no signal, a blanked monitor, or a "
                         "screen that really is one colour" % (mean,))
    if spread < 6.0:
        return "nearly blank", "rgb%s, spread %.1f" % (mean, spread)
    return "picture", "rgb%s average, spread %.1f" % (mean, spread)


def describe(cfg):
    """Open the device, take a frame, and say what came back."""
    ff = tool(cfg, "ffmpeg")
    video, audio = list_devices(cfg)
    present = cfg["device"] in video

    info = {
        "ffmpeg": ff,
        "device": cfg["device"],
        "present": present,
        "audio_device": cfg.get("audio_device"),
        "audio_present": bool(cfg.get("audio_device")
                              and cfg["audio_device"] in audio),
        "video_devices": video,
        "audio_devices": audio,
    }
    if not present:
        return info

    t0 = time.time()
    p = shot(cfg, out_path(cfg, "status.png"))
    info["shot"] = p
    info["shot_secs"] = time.time() - t0
    info["verdict"], info["detail"] = analyse(p)
    return info
