"""
boxes.py -- the registry of DOS machines on the bridge.

WHY THIS EXISTS

The bridge talked to exactly one DOS box for its whole life, and every piece
of state that implied lived in one of two places: a single slot in `dosd`'s
`State`, or an unqualified `capture.json` / `power.json` that could only ever
mean "the machine". `docs/multibox.md` is the design; this file is the part
both halves need, so `dosd` and `dosctl` cannot drift on what a box id means.

ABSENT MEANS OFF. With no `boxes.json` every caller here returns None or an
empty mapping, and both halves fall back to exactly the single-box behaviour
they had before -- same log lines, same status text, same defaults. That is
the acceptance test for phase 1 of the design: with one box registered, or
none, nothing about the bridge changes.

THE IDENTIFIER SHAPE IS NOT ARBITRARY. `@` is taken -- `dosd` splits a resume
offset off a TFTP name with `rpartition("@")`. `/` is taken -- `safe_rel`
uses it for the per-project namespacing under `files/`. A dot is free and is
already inside `SAFE_SEG`'s character class, so `job.v30` reaches `dosd`
unmangled through a transport nobody has to recompile. `[a-z0-9]{1,8}` keeps
an id 8.3-safe, path-safe, usable as a directory name and short enough to
head a table column.

DUPLICATE ADDRESSES ARE REFUSED HERE. Two boxes at one IP is the failure this
whole design most has to avoid, because it does not present as a
configuration mistake: it presents as "the link drops frames", which is
precisely the misdiagnosis that cost this project weeks before mTCP was used
as an independent control. A clone of an SD card produces it. Catching it at
config-load time costs one error message; catching it on the wire costs a
week.
"""

import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("DOSBRIDGE_BOXES",
                             os.path.join(HERE, "boxes.json"))

# See the module docstring. Lower case only, so an id cannot differ from
# another by case alone -- DOS upper-cases half of everything it touches and
# a pair that differed only in case would be two boxes on Windows and one on
# the machine they describe.
BOX_RE = re.compile(r"^[a-z0-9]{1,8}$")

# The marker a project directory uses to pin itself to one machine.
PIN_FILE = ".dosbox"


class BoxError(Exception):
    """A registry that cannot be trusted. Always fatal -- see the docstring:
    the failures this catches are the ones that are invisible later."""


_cache = {"path": None, "mtime": None, "reg": None}


def _validate(raw, path):
    if not isinstance(raw, dict):
        raise BoxError("%s must contain a JSON object" % path)
    boxes = raw.get("boxes")
    if not isinstance(boxes, dict) or not boxes:
        raise BoxError("%s has no \"boxes\" object" % path)

    out, by_addr = {}, {}
    for bid, spec in boxes.items():
        if bid.startswith("_"):          # a comment key, same as power.json
            continue
        if not BOX_RE.match(bid):
            raise BoxError("%s: box id %r must be 1-8 characters of a-z0-9"
                           % (path, bid))
        if not isinstance(spec, dict):
            raise BoxError("%s: box %r must be an object" % (path, bid))
        spec = {k: v for k, v in spec.items() if not k.startswith("_")}
        ip = spec.get("ip")
        if not ip:
            raise BoxError("%s: box %r has no \"ip\". The address is what "
                           "lets dosd cross-check a box's declared identity "
                           "against where it actually polled from. Use "
                           "\"any\" for a box that has no fixed one."
                           % (path, bid))
        # "any" opts out of the address check, for a box whose address is
        # not fixed -- a simulated one in selftest, or a machine still on
        # DHCP. It gives up the cross-check, so such a box MUST declare a
        # BOXID: nothing else can tell it from another.
        if ip == "any":
            pass
        elif ip in by_addr:
            raise BoxError(
                "%s: %s and %s are both registered at %s.\n"
                "      Two machines at one address do not read as a "
                "configuration\n"
                "      mistake -- they read as a flaky link. Fix the "
                "addresses first."
                % (path, by_addr[ip], bid, ip))
        if ip != "any":
            by_addr[ip] = bid
        out[bid] = spec

    if not out:
        raise BoxError("%s has no boxes in it" % path)

    default = raw.get("default")
    if default is not None and default not in out:
        raise BoxError("%s: \"default\" is %r, which is not a registered box "
                       "(%s)" % (path, default, ", ".join(sorted(out))))
    if default is None and len(out) == 1:
        default = next(iter(out))

    return {"default": default, "boxes": out, "path": path}


def load(path=None):
    """The registry, or None when there is no boxes.json.

    Re-read when the file's mtime changes, so editing the registry does not
    need dosd restarting -- and restarting dosd while the boxes are polling
    is exactly the kind of avoidable disturbance this bridge keeps paying
    for.
    """
    path = path or CONFIG_PATH
    if not path or not os.path.isfile(path):
        return None
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return None
    if _cache["path"] == path and _cache["mtime"] == mtime:
        return _cache["reg"]
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as e:
        raise BoxError("%s is not readable JSON: %s" % (path, e))
    reg = _validate(raw, path)
    _cache.update({"path": path, "mtime": mtime, "reg": reg})
    return reg


def ids(reg=None):
    reg = reg if reg is not None else load()
    return sorted(reg["boxes"]) if reg else []


def get(box_id, reg=None):
    reg = reg if reg is not None else load()
    if not reg:
        return None
    return reg["boxes"].get(box_id)


def default_id(reg=None):
    reg = reg if reg is not None else load()
    return reg["default"] if reg else None


def by_ip(ip, reg=None):
    """Which registered box polls from this address, if any.

    This is the OBSERVED layer of identity in docs/multibox.md, and it is
    free: dosd has the source address on every packet already. It is what
    makes a box that has never heard of BOXID route correctly, so no DOS
    machine has to be touched before a second one can join.
    """
    reg = reg if reg is not None else load()
    if not reg:
        return None
    if not ip or ip == "any":
        return None
    for bid, spec in reg["boxes"].items():
        if spec.get("ip") == ip:
            return bid
    return None


def ip_of(box_id, reg=None):
    spec = get(box_id, reg)
    return spec.get("ip") if spec else None


def desc_of(box_id, reg=None):
    spec = get(box_id, reg)
    return (spec or {}).get("desc") or ""


def pinned(start_dir=None):
    """The box id in a `.dosbox` file at or above `start_dir`, if any.

    Walks upward so `projects/foo/` can pin itself and a command run from
    `projects/foo/build/` still finds it.
    """
    d = os.path.abspath(start_dir or os.getcwd())
    seen = set()
    while d and d not in seen:
        seen.add(d)
        p = os.path.join(d, PIN_FILE)
        if os.path.isfile(p):
            try:
                with open(p, "r", encoding="utf-8") as fh:
                    want = fh.read().strip().lower()
            except OSError:
                return None
            return want or None
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def resolve(explicit=None, start_dir=None, reg=None):
    """Which box a command targets: (box_id, how-we-decided).

    Order, from docs/multibox.md:
        1. --box ID
        2. $DOSBOX
        3. a .dosbox file at or above the working directory
        4. "default" in boxes.json
        5. the sole registered box

    Returns (None, "") when there is no registry at all, which is the
    unconfigured single-box case and is not an error.

    AMBIGUITY IS A HARD ERROR. This project already learned that from
    `files/`: two projects that both built a HELLO.EXE used to overwrite each
    other silently, last writer winning. Guessing a machine is worse, because
    the result of the guess looks entirely correct -- it simply ran on the
    wrong CPU, and nothing in the output says so.
    """
    reg = reg if reg is not None else load()
    if not reg:
        if explicit:
            raise BoxError(
                "--box %s, but there is no boxes.json.\n"
                "      Copy boxes.example.json to boxes.json and register "
                "your machines." % explicit)
        return None, ""

    known = sorted(reg["boxes"])

    def check(want, how):
        want = (want or "").strip().lower()
        if not want:
            return None
        if want == "all":
            return "all"
        if want not in reg["boxes"]:
            raise BoxError("no box called %r (%s says so). Registered: %s"
                           % (want, how, ", ".join(known)))
        return want

    got = check(explicit, "--box")
    if got:
        return got, "--box"
    got = check(os.environ.get("DOSBOX"), "$DOSBOX")
    if got:
        return got, "$DOSBOX"
    got = check(pinned(start_dir), "a .dosbox file")
    if got:
        return got, ".dosbox"
    if reg["default"]:
        return reg["default"], "the default in boxes.json"
    if len(known) == 1:
        return known[0], "the only registered box"
    raise BoxError(
        "which box? %s are registered and boxes.json names no default.\n"
        "      Say --box ID, set DOSBOX, or add a \"default\"."
        % ", ".join(known))


def overrides(box_id, section, reg=None):
    """The per-box slice of a peripheral config, or None if it has none.

    The existing config files stay as the schema and this supplies overrides
    on top -- `capture.json` carries about twenty fields that are properties
    of the capture stick and this PC rather than of any DOS box, and
    duplicating them per box guarantees they drift.

    None means "this box has no such peripheral", which callers MUST report
    rather than falling back to the shared config. Falling back is how
    `doscap --box sx386` would show the V30's screen -- a capture that
    silently shows the wrong machine does not produce a wrong answer, it
    produces a convincing one.
    """
    spec = get(box_id, reg)
    if spec is None:
        return None
    sub = spec.get(section)
    if sub is None or sub is False:
        return None
    if not isinstance(sub, dict):
        raise BoxError("box %s: \"%s\" must be an object or null"
                       % (box_id, section))
    return {k: v for k, v in sub.items() if not k.startswith("_")}


def expectations(box_id, reg=None):
    """What this box should MEASURE as -- the third identity layer."""
    return overrides(box_id, "expect", reg) or {}
