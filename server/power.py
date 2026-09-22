#!/usr/bin/env python3
r"""
DOS Bridge  --  StevenC

power.py -- optional smart-plug control, so a wedged DOS box can be recovered
without somebody walking over to it.

WHY THIS EXISTS
---------------
Every unrecoverable failure this project has hit ends the same way: "needs
hands on the keyboard". A driver that hangs before the network is up, a
packet driver handle left dangling, a PicoMEM card that freezes during POST --
none of them can be fixed from the Windows side, because the agent that would
have to act is exactly the thing that is not running. A switched plug is the
one lever that still works when nothing on the box does.

It is entirely OPTIONAL and OFF by default. With no configuration file
present, every entry point here returns "not configured" and nothing can
touch a relay -- which is what ships in the installer. Cutting mains power to
a machine is not a default.

CONFIGURATION
-------------
A JSON file, `power.json`, beside this script. It is deliberately NOT created
by the installer or by any code here: `power.example.json` is shipped to be
copied and edited, so an existing configuration is never overwritten by an
upgrade.

    {
      "model": "shelly",
      "host": "192.168.1.30",
      "channel": 0,
      "off_secs": 6,
      "max_cycles": 3,
      "window_secs": 3600,
      "min_interval_secs": 90,
      "auto": true
    }

`DOSBRIDGE_POWER` overrides the path; setting it empty disables the feature
outright even if a file exists.

THE GUARDS ARE THE POINT
------------------------
A recovery mechanism that can loop is worse than none: a box that fails to
come back for a reason power cannot fix -- a bad AUTOEXEC.BAT, a dead PSU,
an unplugged network -- would otherwise be power-cycled every couple of
minutes, indefinitely, which is a fine way to corrupt a filesystem or cook
hardware nobody is watching.

So:

  * `min_interval_secs` refuses a second cycle too soon after the last one.
  * `max_cycles` within `window_secs` is a hard ceiling on how often the
    machine may be cut, regardless of who asks.
  * The state behind both lives in `power.state`, on disk, so the limits
    survive a dosctl that is re-run in a loop or a shell script. Holding them
    in memory would make them trivially defeatable by the exact mistake they
    exist to prevent.

`--force` overrides the interval, never the window ceiling.
"""

import json
import os
import re
import socket
import struct
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("DOSBRIDGE_POWER",
                             os.path.join(HERE, "power.json"))
STATE_PATH = os.path.join(HERE, "power.state")

HTTP_TIMEOUT = 8

DEFAULTS = {
    "model": None,
    "host": None,
    "channel": 0,
    "username": None,
    "password": None,
    # Long enough for a real power-off. PSU capacitors hold a small machine
    # up for a surprising fraction of a second, and a cycle the hardware does
    # not actually see is worse than useless -- it looks like it worked.
    "off_secs": 6,
    "max_cycles": 3,
    "window_secs": 3600,
    "min_interval_secs": 90,
    "auto": True,
    # Generic HTTP driver only.
    "on_url": None,
    "off_url": None,
    "status_url": None,
    "status_on": "(?i)\\bon\\b|\"?true\"?|\"state\"\\s*:\\s*1",
    # Home Assistant only.
    "entity_id": None,
    "token": None,
}


class PowerError(Exception):
    """Anything that stopped us from driving the plug."""


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Which DOS box this process is switching, and what it overrides.
#
# power.json stays the schema; boxes.json supplies per-box overrides. Only
# `host` and `channel` are genuinely per box -- model, max_cycles,
# window_secs and min_interval_secs are policy and stay shared.
#
# The CYCLE HISTORY is per box and that is not cosmetic: the rate limit
# exists to stop a recovery loop hammering a machine that power is not
# fixing, and if one box's cycles ate the other's budget the guard would
# refuse a machine it had never touched and allow one it had.
_SCOPE = {"box": None, "over": {}}


def set_scope(box, over=None):
    """Switch this box from now on. box=None is the single-machine case."""
    _SCOPE["box"] = box
    _SCOPE["over"] = dict(over or {})


def scope_box():
    return _SCOPE["box"]


def load(path=None):
    """Return the plug config, or None if the feature is not set up.

    None is a normal, expected answer -- it is what every unconfigured
    install returns -- so callers must treat it as "no plug" and carry on,
    never as an error.
    """
    if path is None:
        path = CONFIG_PATH
    if not path:                      # DOSBRIDGE_POWER= explicitly empty
        return None
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as e:
        raise PowerError("%s is not readable JSON: %s" % (path, e))
    if not isinstance(raw, dict):
        raise PowerError("%s must contain a JSON object" % path)

    cfg = dict(DEFAULTS)
    # Comment keys, so the example file can explain itself in a format with
    # no comment syntax.
    cfg.update({k: v for k, v in raw.items() if not k.startswith("_")})
    cfg.update({k: v for k, v in _SCOPE["over"].items()
                if not k.startswith("_")})
    if _SCOPE["box"]:
        cfg["box"] = _SCOPE["box"]
    if not cfg.get("model"):
        raise PowerError("%s has no \"model\"" % path)
    return cfg


# ---------------------------------------------------------------------------
# Drivers
#
# Only the Shelly one has been run against real hardware (a Gen4 PlugUSG4).
# The others are written from published local APIs and are UNVERIFIED -- they
# are here so that somebody with different hardware has a starting point, not
# because they are known to work. Each says so in its docstring.
# ---------------------------------------------------------------------------

def _get(url, timeout=HTTP_TIMEOUT, headers=None, data=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")[:200]
        except Exception:
            pass
        raise PowerError("HTTP %s from %s %s" % (e.code, url, body))
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        raise PowerError("cannot reach %s (%s)" % (url, e))


def _auth_opener(cfg):
    """Shelly Gen2+ uses HTTP digest auth, and only when it is enabled."""
    if not cfg.get("password"):
        return
    mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    mgr.add_password(None, "http://%s/" % cfg["host"],
                     cfg.get("username") or "admin", cfg["password"])
    urllib.request.install_opener(
        urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(mgr)))


class ShellyGen2:
    """Shelly Gen2/3/4 RPC over HTTP. VERIFIED on a Gen4 PlugUSG4.

    Switch.GetStatus also reports instantaneous power draw, which is the
    single most useful thing here: it separates "the machine is off" from
    "the machine has power and is hung", and those need opposite responses.
    """

    name = "shelly"

    def __init__(self, cfg):
        self.cfg = cfg
        self.base = "http://%s" % cfg["host"]
        self.ch = int(cfg.get("channel") or 0)
        _auth_opener(cfg)

    def _rpc(self, method, **params):
        q = urllib.parse.urlencode(params)
        url = "%s/rpc/%s%s" % (self.base, method, ("?" + q) if q else "")
        body = _get(url)
        try:
            return json.loads(body)
        except ValueError:
            raise PowerError("%s did not return JSON: %s" % (url, body[:120]))

    def info(self):
        d = self._rpc("Shelly.GetDeviceInfo")
        return "%s gen%s fw %s" % (d.get("model", "?"), d.get("gen", "?"),
                                   d.get("ver", "?"))

    def status(self):
        d = self._rpc("Switch.GetStatus", id=self.ch)
        return {"on": bool(d.get("output")), "watts": d.get("apower"),
                "volts": d.get("voltage")}

    def set(self, on):
        self._rpc("Switch.Set", id=self.ch, on="true" if on else "false")


class ShellyGen1:
    """Shelly Gen1 (Plug S, 1PM, ...). UNVERIFIED -- no Gen1 hardware here."""

    name = "shelly-gen1"

    def __init__(self, cfg):
        self.cfg = cfg
        self.base = "http://%s" % cfg["host"]
        self.ch = int(cfg.get("channel") or 0)
        _auth_opener(cfg)

    def info(self):
        return json.loads(_get(self.base + "/shelly")).get("type", "shelly")

    def status(self):
        d = json.loads(_get("%s/relay/%d" % (self.base, self.ch)))
        return {"on": bool(d.get("ison")), "watts": None, "volts": None}

    def set(self, on):
        _get("%s/relay/%d?turn=%s" % (self.base, self.ch,
                                      "on" if on else "off"))


class Tasmota:
    """Tasmota firmware over HTTP. UNVERIFIED."""

    name = "tasmota"

    def __init__(self, cfg):
        self.cfg = cfg
        self.base = "http://%s" % cfg["host"]
        ch = int(cfg.get("channel") or 0)
        self.relay = "Power%s" % (ch + 1 if ch else "")

    def _cmnd(self, cmd):
        q = {"cmnd": cmd}
        if self.cfg.get("username"):
            q["user"] = self.cfg["username"]
            q["password"] = self.cfg.get("password") or ""
        body = _get("%s/cm?%s" % (self.base, urllib.parse.urlencode(q)))
        try:
            return json.loads(body)
        except ValueError:
            return {"raw": body}

    def info(self):
        d = self._cmnd("Status 0")
        return str(d.get("StatusFWR", {}).get("Version", "tasmota"))

    def status(self):
        d = self._cmnd(self.relay)
        val = str(list(d.values())[0] if d else "").upper()
        return {"on": val == "ON", "watts": None, "volts": None}

    def set(self, on):
        self._cmnd("%s %s" % (self.relay, "On" if on else "Off"))


class Kasa:
    """TP-Link Kasa (HS100/HS103/HS110/KP115). UNVERIFIED.

    Not HTTP: a length-prefixed JSON payload over TCP 9999, obfuscated with
    an autokey XOR seeded at 171. It is not encryption and is not treated as
    any kind of security -- it is simply the framing the device expects.
    """

    name = "kasa"
    PORT = 9999

    def __init__(self, cfg):
        self.host = cfg["host"]

    @staticmethod
    def _encrypt(s):
        key, out = 171, bytearray()
        for b in s.encode():
            key ^= b
            out.append(key)
        return struct.pack(">I", len(out)) + bytes(out)

    @staticmethod
    def _decrypt(data):
        key, out = 171, bytearray()
        for c in data:
            out.append(key ^ c)
            key = c
        return out.decode("utf-8", "replace")

    def _cmd(self, obj):
        try:
            with socket.create_connection((self.host, self.PORT), 6) as s:
                s.sendall(self._encrypt(json.dumps(obj)))
                head = s.recv(4)
                if len(head) < 4:
                    raise PowerError("short reply from %s" % self.host)
                need = struct.unpack(">I", head)[0]
                buf = b""
                while len(buf) < need:
                    chunk = s.recv(need - len(buf))
                    if not chunk:
                        break
                    buf += chunk
        except (OSError, socket.timeout) as e:
            raise PowerError("cannot reach %s:%d (%s)"
                             % (self.host, self.PORT, e))
        return json.loads(self._decrypt(buf))

    def info(self):
        d = self._cmd({"system": {"get_sysinfo": {}}})["system"]["get_sysinfo"]
        return "%s %s" % (d.get("model", "?"), d.get("sw_ver", ""))

    def status(self):
        d = self._cmd({"system": {"get_sysinfo": {}}})["system"]["get_sysinfo"]
        return {"on": bool(d.get("relay_state")), "watts": None, "volts": None}

    def set(self, on):
        self._cmd({"system": {"set_relay_state": {"state": 1 if on else 0}}})


class HomeAssistant:
    """Anything Home Assistant can switch. UNVERIFIED.

    Worth having because it covers hardware with no usable local API of its
    own -- HA has already done that integration work.
    """

    name = "homeassistant"

    def __init__(self, cfg):
        self.cfg = cfg
        self.base = "http://%s" % cfg["host"]
        if not cfg.get("token") or not cfg.get("entity_id"):
            raise PowerError("homeassistant needs \"token\" and \"entity_id\"")
        self.head = {"Authorization": "Bearer " + cfg["token"],
                     "Content-Type": "application/json"}

    def info(self):
        return "home assistant %s" % self.cfg["entity_id"]

    def status(self):
        body = _get("%s/api/states/%s" % (self.base, self.cfg["entity_id"]),
                    headers=self.head)
        return {"on": json.loads(body).get("state") == "on",
                "watts": None, "volts": None}

    def set(self, on):
        domain = self.cfg["entity_id"].split(".")[0]
        _get("%s/api/services/%s/turn_%s"
             % (self.base, domain, "on" if on else "off"),
             headers=self.head,
             data=json.dumps({"entity_id": self.cfg["entity_id"]}).encode())


class GenericHttp:
    """Whatever else: you supply the URLs. UNVERIFIED by definition.

    The escape hatch, so an unsupported plug is a config entry rather than a
    code change. `status_url` is optional -- without it we report unknown and
    a cycle proceeds blind, which is still better than no recovery at all.
    """

    name = "http"

    def __init__(self, cfg):
        self.cfg = cfg
        if not cfg.get("on_url") or not cfg.get("off_url"):
            raise PowerError("http driver needs \"on_url\" and \"off_url\"")

    def info(self):
        return "generic http"

    def status(self):
        if not self.cfg.get("status_url"):
            return {"on": None, "watts": None, "volts": None}
        body = _get(self.cfg["status_url"])
        return {"on": bool(re.search(self.cfg["status_on"], body)),
                "watts": None, "volts": None}

    def set(self, on):
        _get(self.cfg["on_url"] if on else self.cfg["off_url"])


DRIVERS = {
    "shelly": ShellyGen2,
    "shelly-gen2": ShellyGen2,
    "shelly-gen1": ShellyGen1,
    "tasmota": Tasmota,
    "kasa": Kasa,
    "homeassistant": HomeAssistant,
    "http": GenericHttp,
}

# Only this one has met real hardware. Everything else prints a warning the
# first time it is used, because a recovery tool that quietly does nothing is
# the worst possible kind.
VERIFIED = {"shelly", "shelly-gen2"}


def driver(cfg):
    model = str(cfg.get("model", "")).lower()
    if model not in DRIVERS:
        raise PowerError("unknown model %r -- known: %s"
                         % (cfg.get("model"), ", ".join(sorted(DRIVERS))))
    if model not in ("homeassistant", "http") and not cfg.get("host"):
        raise PowerError("model %s needs a \"host\"" % model)
    return DRIVERS[model](cfg)


# ---------------------------------------------------------------------------
# Rate limiting, persisted
# ---------------------------------------------------------------------------

def _state_key():
    """The key this box's cycle history is filed under.

    "cycles" is the single-machine history and is kept as the key for a box
    with no id, so an existing power.state carries over unchanged rather
    than resetting a rate limit that may be the only thing standing between
    a wedged machine and a loop of hard power cuts.
    """
    box = _SCOPE["box"]
    return ("cycles:" + box) if box else "cycles"


def _read_all():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as fh:
            s = json.load(fh)
        return s if isinstance(s, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def _read_state():
    try:
        return [float(t) for t in _read_all().get(_state_key(), [])]
    except (ValueError, TypeError):
        return []


def _write_state(cycles):
    s = _read_all()
    s[_state_key()] = cycles[-50:]
    try:
        with open(STATE_PATH, "w", encoding="utf-8") as fh:
            json.dump(s, fh)
    except OSError:
        pass


def recent_cycles(cfg, now=None):
    now = now or time.time()
    window = float(cfg.get("window_secs") or 3600)
    return [t for t in _read_state() if now - t < window]


def may_cycle(cfg, force=False, now=None):
    """(allowed, why-not). The ceiling is not overridable; the interval is.

    Deliberately asymmetric. Being asked twice in quick succession is usually
    impatience, and a human saying --force settles it. Hitting the ceiling
    means power has already failed to fix this several times, and the honest
    conclusion is that it is not going to -- so pushing past it needs a
    person to think, not a flag.
    """
    now = now or time.time()
    hist = recent_cycles(cfg, now)
    limit = int(cfg.get("max_cycles") or 3)
    if len(hist) >= limit:
        mins = float(cfg.get("window_secs") or 3600) / 60.0
        return False, ("already power-cycled %d time(s) in the last %.0f "
                       "minutes, which is the configured max_cycles. Power "
                       "is not fixing this -- look at the machine."
                       % (len(hist), mins))
    if hist and not force:
        gap = now - max(hist)
        need = float(cfg.get("min_interval_secs") or 90)
        if gap < need:
            return False, ("last cycle was %.0fs ago; min_interval_secs is "
                           "%.0f. Use --force to override." % (gap, need))
    return True, ""


def note_cycle(now=None):
    now = now or time.time()
    hist = _read_state()
    hist.append(now)
    _write_state(hist)


def reset_history():
    """Forget this box's cycle history -- for when a real fix is applied.

    Scoped, so clearing the V30's history cannot quietly hand the 386 a
    fresh budget it did not earn.
    """
    if not _SCOPE["box"]:
        try:
            os.remove(STATE_PATH)
        except OSError:
            pass
        return
    s = _read_all()
    s.pop(_state_key(), None)
    try:
        with open(STATE_PATH, "w", encoding="utf-8") as fh:
            json.dump(s, fh)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

def cycle(cfg, log=print, force=False):
    """Off, wait, on. Returns True if the plug ended up on.

    The final state is READ BACK rather than assumed. A cycle that turns the
    machine off and fails to turn it on is the worst outcome this code can
    produce -- strictly worse than doing nothing -- so it is the one thing
    actually verified.
    """
    ok, why = may_cycle(cfg, force=force)
    if not ok:
        raise PowerError(why)

    d = driver(cfg)
    if d.name not in VERIFIED:
        log("power: driver %r has never been tested against real hardware"
            % d.name)

    off_secs = float(cfg.get("off_secs") or 6)
    note_cycle()

    log("power: switching OFF")
    d.set(False)
    time.sleep(off_secs)
    log("power: switching ON after %.0fs" % off_secs)
    d.set(True)

    # Give the relay a moment before believing what it says about itself.
    time.sleep(1.5)
    try:
        st = d.status()
    except PowerError:
        st = {"on": None}
    if st.get("on") is False:
        raise PowerError("the plug reports still OFF after switching on -- "
                         "the machine has no power. Check it.")
    log("power: on")
    return True


def describe(cfg):
    """One line for `dosctl power status`."""
    d = driver(cfg)
    st = d.status()
    bits = []
    if st.get("on") is None:
        bits.append("state unknown")
    else:
        bits.append("ON" if st["on"] else "OFF")
    if st.get("watts") is not None:
        bits.append("%.1f W" % st["watts"])
    if st.get("volts") is not None:
        bits.append("%.0f V" % st["volts"])
    return d, st, "  ".join(bits)
