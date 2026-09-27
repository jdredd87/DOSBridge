"""emudoskey.py -- run DOSKEY programs (MS-DOS 6.22's and ours) in an 8086
emulator over a model PC and DOS, drive them the way COMMAND.COM and a
person at the keyboard do, and compare.  StevenC & Claude, 2026.

    python emudoskey.py REF.COM TEST.COM [--seed N] [--fuzz N] [-v]

The model: a BIOS written in Python on real video memory and the real BIOS
data area (80x25 colour text, teletype wrap and scroll); a DOS that gives
the program INT 21h -- console input 08h/0Bh, output 02h/09h, the generic
IOCTL for the screen, find-first/next over a small made-up disk, memory,
vectors, TSR -- and COMMAND.COM's side of the DOSKEY interface: INT 2Fh
AX=4810h with a 128-byte buffer that keeps the last line as the template.

A SESSION is a list of steps: a keystroke stream typed at the prompt (the
COMMAND.COM loop keeps calling 4810h until the keys run out), or a second
run of the program with a command tail (DOSKEY /M, a macro definition...).
After every call both programs are compared on: the line handed back, the
whole screen and cursor, the cursor shape, the BIOS insert flag, beeps,
and the exit code of each run.
"""
import struct, sys, random
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR
from unicorn.x86_const import *

STUBS = 0xF000
PSP1 = 0x1000          # resident copy
PSP2 = 0x6000          # a second run (transient)
ENVSEG = 0x0F00
CMDSEG = 0x0800        # "COMMAND.COM": its input buffer and a call stub
BUFOFF = 0x0100
CALLOFF = 0x0000


class OutOfKeys(Exception):
    pass


class Exit(Exception):
    pass


# a small disk for find-first/next: path -> list of (name, attr)
DISK = {
    'C:\\': [('AUTOEXEC.BAT', 0x20), ('CONFIG.SYS', 0x20), ('COMMAND.COM', 0x21), ('DOS', 0x10),
             ('DRIVERS', 0x10), ('TOOLS', 0x10), ('WORK', 0x10), ('AI', 0x10), ('AGENT', 0x10),
             ('IO.SYS', 0x27), ('MSDOS.SYS', 0x27), ('WINA20.386', 0x20), ('AUTOEXEC.SAV', 0x20),
             ('CONFIG.SC0', 0x20), ('CONFIG.SC1', 0x20), ('CONFIG.SC2', 0x20)],
    'C:\\DOS\\': [('.', 0x10), ('..', 0x10), ('ANSI.SYS', 0x20), ('ATTRIB.EXE', 0x20), ('CHKDSK.EXE', 0x20),
                  ('DEBUG.EXE', 0x20), ('DOSKEY.COM', 0x20), ('EDIT.COM', 0x20), ('EMM386.EXE', 0x20),
                  ('FORMAT.COM', 0x20), ('HIMEM.SYS', 0x20), ('MEM.EXE', 0x20), ('MODE.COM', 0x20),
                  ('MORE.COM', 0x20), ('QBASIC.EXE', 0x20), ('SYS.COM', 0x20), ('XCOPY.EXE', 0x20),
                  ('DEVLOAD.COM', 0x20)],
    'C:\\TOOLS\\': [('.', 0x10), ('..', 0x10), ('BENCH.EXE', 0x20), ('BEEP.EXE', 0x20), ('DEVS.EXE', 0x20),
                    ('DSTAT.EXE', 0x20), ('FPU.EXE', 0x20), ('HD.EXE', 0x20), ('HWINFO.EXE', 0x20)],
    'C:\\WORK\\': [('.', 0x10), ('..', 0x10)],
    'C:\\AI\\': [('.', 0x10), ('..', 0x10), ('AI.BAT', 0x20), ('AI.BAK', 0x20), ('NET.CFG', 0x20),
                 ('REBOOT.COM', 0x20), ('COLDBOOT.COM', 0x20), ('SUB', 0x10)],
    'C:\\AI\\SUB\\': [('.', 0x10), ('..', 0x10), ('ONE.TXT', 0x20)],
    'C:\\DRIVERS\\': [('.', 0x10), ('..', 0x10), ('PM2000.COM', 0x20), ('PM2000.ORG', 0x20),
                      ('UMBSC.SYS', 0x20), ('ANSISC.SYS', 0x20), ('PMEMMSC.SYS', 0x20)],
    'C:\\AGENT\\': [('.', 0x10), ('..', 0x10)],
}


def fcb_match(pat, name):
    """DOS 8.3 wildcard match, the way find-first does it."""
    def split(s):
        if s in ('.', '..'):
            return s.ljust(8), '   '
        n, _, e = s.partition('.')
        return n, e
    def expand(p, w):
        out = ''
        for ch in p:
            if ch == '*':
                out += '?' * (w - len(out)); break
            out += ch
        return out[:w].ljust(w)
    pn, pe = split(pat)
    nn, ne = split(name)
    pn, pe, nn, ne = expand(pn, 8), expand(pe, 3), nn.ljust(8), ne.ljust(3)
    return all(a == '?' or a == b for a, b in zip(pn + pe, nn + ne))


class PC:
    def __init__(self, image, ansi=True, cwd='C:\\', trace=False):
        self.image = image
        self.ansi = ansi
        self.cwd = cwd
        self.trace = trace
        self.keys = []
        self.beeps = 0
        self.dosout = []
        self.exitcode = None
        self.resident = None
        self.dta = (0, 0x80)
        self.finds = {}
        self.calls_2f = 0
        self.vector21 = False
        self.files = {}                 # name -> bytearray
        self.handles = {}               # handle -> [name, pos]
        uc = self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        uc.mem_map(0, 0x100000)
        # BIOS stubs: INT n through the IVT lands on "int F0+k ; retf 2"
        for k, n in enumerate((0x10, 0x16, 0x28, 0x2F, 0x23, 0x24, 0x1B, 0x21)):
            addr = 0x100 + k * 0x10
            uc.mem_write(STUBS * 16 + addr, bytes([0xCD, 0xF0 + k, 0xCA, 0x02, 0x00]))
            uc.mem_write(n * 4, struct.pack('<HH', addr, STUBS))
        uc.hook_add(UC_HOOK_INTR, self._intr)
        # BDA: colour 80x25
        self.w16(0x410, 0x0021 | 0x20)
        self.w8(0x449, 3); self.w16(0x44A, 80); self.w16(0x44C, 4096); self.w16(0x44E, 0)
        self.w8(0x462, 0); self.w16(0x463, 0x3D4); self.w8(0x484, 24); self.w8(0x485, 16)
        self.w16(0x460, 0x0607)
        self.w8(0x417, 0)
        uc.mem_write(0xB8000, b'\x20\x07' * 2000)
        env = b'COMSPEC=C:\\COMMAND.COM\x00PATH=C:\\DOS\x00\x00\x01\x00C:\\DOS\\DOSKEY.COM\x00'
        uc.mem_write(ENVSEG * 16, env)

    # ---- memory
    def r8(self, a): return self.uc.mem_read(a, 1)[0]
    def r16(self, a): return struct.unpack('<H', bytes(self.uc.mem_read(a, 2)))[0]
    def w8(self, a, v): self.uc.mem_write(a, bytes([v & 0xFF]))
    def w16(self, a, v): self.uc.mem_write(a, struct.pack('<H', v & 0xFFFF))
    def reg(self, r): return self.uc.reg_read(r)
    def setreg(self, r, v): self.uc.reg_write(r, v)
    def asciiz(self, a, n=128):
        b = bytes(self.uc.mem_read(a, n)); return b[:b.index(0)] if 0 in b else b

    # ---- video
    def getcur(self):
        v = self.r16(0x450); return v >> 8, v & 0xFF
    def setcur(self, r, c): self.w16(0x450, (r << 8) | c)
    def cell(self, r, c): return 0xB8000 + (r * 80 + c) * 2

    def scrollup(self):
        scr = bytes(self.uc.mem_read(0xB8000, 4000))
        self.uc.mem_write(0xB8000, scr[160:] + b'\x20\x07' * 80)

    def teletype(self, ch):
        r, c = self.getcur()
        if ch == 7: self.beeps += 1; return
        if ch == 8:
            if c: c -= 1
        elif ch == 13: c = 0
        elif ch == 10:
            if r < 24: r += 1
            else: self.scrollup()
        else:
            self.w8(self.cell(r, c), ch)
            c += 1
            if c >= 80:
                c = 0
                if r < 24: r += 1
                else: self.scrollup()
        self.setcur(r, c)

    def screen(self):
        s = bytes(self.uc.mem_read(0xB8000, 4000))[0::2]
        rows = [s[i * 80:(i + 1) * 80].decode('cp437') for i in range(25)]
        # 6.22 misspells "Insufficient"; ours does not.  Same otherwise.
        return [r.replace('Insufficient', 'Insufficent') + ' ' if 'Insufficient' in r else r for r in rows]

    def state(self):
        return (tuple(self.screen()), self.getcur(), self.r16(0x460), self.r8(0x417) & 0x80, self.beeps)

    # ---- interrupts
    def _flags_cf(self, cf):
        # INT 21h is served right here, in place of the instruction: the
        # carry the caller tests is the live one
        f = self.reg(UC_X86_REG_FLAGS)
        self.setreg(UC_X86_REG_FLAGS, (f | 1) if cf else (f & ~1))

    def _vector(self, n):
        uc = self.uc
        ip, cs = self.reg(UC_X86_REG_IP), self.reg(UC_X86_REG_CS)
        fl = self.reg(UC_X86_REG_FLAGS)
        sp = (self.reg(UC_X86_REG_SP) - 6) & 0xFFFF; ss = self.reg(UC_X86_REG_SS)
        uc.mem_write(ss * 16 + sp, struct.pack('<HHH', ip, cs, fl))
        self.setreg(UC_X86_REG_SP, sp); self.setreg(UC_X86_REG_FLAGS, fl & ~0x0300)
        off, seg = struct.unpack('<HH', bytes(uc.mem_read(n * 4, 4)))
        self.setreg(UC_X86_REG_CS, seg); self.setreg(UC_X86_REG_IP, off)

    def _intr(self, uc, n, ud):
        g = self.reg
        if n in (0x10, 0x16, 0x28, 0x2F, 0x23, 0x24, 0x1B):
            self._vector(n); return
        if n == 0x21 and self.vector21:
            self._vector(n); return
        if n == 0xF7: self.int21(); return            # INT 21h through its vector
        if n == 0xF0: self.int10(); return
        if n in (0xF1, 0xF2): return                 # INT 16h, 28h: nothing
        if n == 0xF3: return                         # INT 2Fh end of chain: not ours
        if n == 0xF4: return                         # INT 23h: carry on
        if n == 0xF5: self.setreg(UC_X86_REG_AX, 3); return   # INT 24h: fail
        if n == 0x21: self.int21(); return
        if n == 0x27:
            self.resident = (g(UC_X86_REG_CS), g(UC_X86_REG_DX))
            self.exitcode = 0; raise Exit()
        raise RuntimeError('unexpected INT %02Xh AX=%04X at %04X:%04X' % (
            n, g(UC_X86_REG_AX), g(UC_X86_REG_CS), g(UC_X86_REG_IP)))

    def int10(self):
        g, s = self.reg, self.setreg
        ax, bx, cx, dx = g(UC_X86_REG_AX), g(UC_X86_REG_BX), g(UC_X86_REG_CX), g(UC_X86_REG_DX)
        ah, al = ax >> 8, ax & 0xFF
        if ah == 0x01: self.w16(0x460, cx)
        elif ah == 0x02: self.setcur(dx >> 8, dx & 0xFF)
        elif ah == 0x03:
            r, c = self.getcur(); s(UC_X86_REG_DX, (r << 8) | c); s(UC_X86_REG_CX, self.r16(0x460))
        elif ah == 0x0E: self.teletype(al)
        elif ah == 0x0F: s(UC_X86_REG_AX, (80 << 8) | 3); s(UC_X86_REG_BX, bx & 0xFF)
        elif ah == 0x08:
            r, c = self.getcur(); s(UC_X86_REG_AX, 0x0700 | self.r8(self.cell(r, c)))
        elif ah == 0x06 and al == 0:
            r0, c0, r1, c1 = cx >> 8, cx & 0xFF, dx >> 8, dx & 0xFF
            for r in range(r0, min(r1, 24) + 1):
                for c in range(c0, min(c1, 79) + 1):
                    self.w8(self.cell(r, c), 0x20); self.w8(self.cell(r, c) + 1, bx >> 8)
        else:
            raise RuntimeError('INT 10h AH=%02X' % ah)

    def out(self, ch):
        self.teletype(ch)

    def int21(self):
        g, s, uc = self.reg, self.setreg, self.uc
        ax = g(UC_X86_REG_AX); ah, al = ax >> 8, ax & 0xFF
        ds, dx = g(UC_X86_REG_DS), g(UC_X86_REG_DX)
        if self.trace: print('  21/%02X' % ah)
        if ah == 0x0B:
            if not self.keys: raise OutOfKeys()
            s(UC_X86_REG_AX, (ax & 0xFF00) | 0xFF)
        elif ah == 0x08:
            if not self.keys: raise OutOfKeys()
            k = self.keys.pop(0)
            if k >= 0x100:
                self.keys.insert(0, k & 0xFF); k = 0
            s(UC_X86_REG_AX, (ax & 0xFF00) | k)
        elif ah == 0x02:
            self.out(dx & 0xFF); s(UC_X86_REG_AX, (ax & 0xFF00) | (dx & 0xFF))
        elif ah == 0x06:
            if (dx & 0xFF) == 0xFF: raise RuntimeError('06h input')
            self.out(dx & 0xFF); s(UC_X86_REG_AX, (ax & 0xFF00) | (dx & 0xFF))
        elif ah == 0x09:
            a = ds * 16 + dx
            while True:
                c = self.r8(a); a += 1
                if c == 0x24: break
                self.out(c)
        elif ah == 0x40:
            cx = g(UC_X86_REG_CX); h = g(UC_X86_REG_BX)
            data = bytes(uc.mem_read(ds * 16 + dx, cx))
            if h in self.handles and self.handles[h][0] != 'CON':
                f = self.handles[h]; buf = self.files[f[0]]
                buf[f[1]:f[1] + cx] = data; f[1] += cx
            else:
                for b in data: self.out(b)
            s(UC_X86_REG_AX, cx); self._flags_cf(False)
        elif ah in (0x3C, 0x3D):
            name = self.asciiz(ds * 16 + dx).decode('latin1').upper()
            if ah == 0x3C: self.files[name] = bytearray()
            if name != 'CON' and name not in self.files:
                s(UC_X86_REG_AX, 2); self._flags_cf(True); return
            h = 5 + len(self.handles)
            self.handles[h] = [name, 0]
            s(UC_X86_REG_AX, h); self._flags_cf(False)
        elif ah == 0x45:
            h = 5 + len(self.handles); self.handles[h] = ['CON', 0]
            s(UC_X86_REG_AX, h); self._flags_cf(False)
        elif ah == 0x46:
            self._flags_cf(False)
        elif ah == 0x3E:
            self.handles.pop(g(UC_X86_REG_BX), None); self._flags_cf(False)
        elif ah == 0x3F:
            f = self.handles[g(UC_X86_REG_BX)]; cx = g(UC_X86_REG_CX)
            data = bytes(self.files[f[0]][f[1]:f[1] + cx]); f[1] += len(data)
            uc.mem_write(ds * 16 + dx, data); s(UC_X86_REG_AX, len(data)); self._flags_cf(False)
        elif ah == 0x30:
            s(UC_X86_REG_AX, 0x1606); s(UC_X86_REG_BX, 0); s(UC_X86_REG_CX, 0)
        elif ah == 0x25:
            uc.mem_write(al * 4, struct.pack('<HH', dx, ds))
        elif ah == 0x35:
            off, seg = struct.unpack('<HH', bytes(uc.mem_read(al * 4, 4)))
            s(UC_X86_REG_BX, off); s(UC_X86_REG_ES, seg)
        elif ah == 0x49 or ah == 0x4A:
            self._flags_cf(False)
        elif ah == 0x4C:
            self.exitcode = al; raise Exit()
        elif ah == 0x31:
            self.resident = (g(UC_X86_REG_CS), dx * 16)
            self.exitcode = al; raise Exit()
        elif ah == 0x44 and al == 0x0C:
            if self.ansi and g(UC_X86_REG_BX) == 2 and (g(UC_X86_REG_CX) & 0xFF) == 0x7F:
                uc.mem_write(ds * 16 + dx, struct.pack('<BBHHBBHHHHH', 0, 0, 14, 0, 1, 0, 4, 640, 400, 80, 25))
                self._flags_cf(False)
            else:
                s(UC_X86_REG_AX, 1); self._flags_cf(True)
        elif ah == 0x1A:
            self.dta = (ds, dx)
        elif ah == 0x2F:
            s(UC_X86_REG_ES, self.dta[0]); s(UC_X86_REG_BX, self.dta[1])
        elif ah == 0x19:
            s(UC_X86_REG_AX, (ax & 0xFF00) | 2)
        elif ah == 0x4E:
            spec = self.asciiz(ds * 16 + dx).decode('latin1').upper()
            self.find_first(spec, g(UC_X86_REG_CX))
        elif ah == 0x4F:
            self.find_next()
        elif ah == 0x62:
            s(UC_X86_REG_BX, self.psp)
        else:
            raise RuntimeError('INT 21h AH=%02X at %04X:%04X' % (ah, g(UC_X86_REG_CS), g(UC_X86_REG_IP)))

    # ---- find first / next, on the made-up disk
    def find_first(self, spec, attr):
        if len(spec) >= 2 and spec[1] == ':':
            drive, rest = spec[:2], spec[2:]
        else:
            drive, rest = 'C:', spec
        if not rest.startswith('\\'):
            rest = self.cwd[2:] + rest
        i = rest.rfind('\\')
        d, pat = drive + rest[:i + 1], rest[i + 1:]
        parts = []
        for p in d[3:].split('\\'):
            if p == '' or p == '.': continue
            if p == '..':
                if parts: parts.pop()
                continue
            parts.append(p)
        d = 'C:\\' + ''.join(p + '\\' for p in parts)
        if drive != 'C:' or d not in DISK or pat == '':
            self.setreg(UC_X86_REG_AX, 3 if d not in DISK else 2); self._flags_cf(True); return
        want = [(n, a) for n, a in DISK[d] if fcb_match(pat, n) and
                (not (a & 0x16) or (a & 0x16 & attr) == (a & 0x16))]
        self.found = want
        self.find_next()

    def find_next(self):
        if not self.found:
            self.setreg(UC_X86_REG_AX, 0x12); self._flags_cf(True); return
        n, a = self.found.pop(0)
        seg, off = self.dta
        blk = bytearray(43)
        blk[0x15] = a
        blk[0x1E:0x1E + len(n)] = n.encode()
        self.uc.mem_write(seg * 16 + off, bytes(blk))
        self._flags_cf(False)

    # ---- running things
    def run(self, cs, ip, ss, sp, limit=20_000_000):
        self.setreg(UC_X86_REG_CS, cs); self.setreg(UC_X86_REG_IP, ip)
        self.setreg(UC_X86_REG_SS, ss); self.setreg(UC_X86_REG_SP, sp)
        self.setreg(UC_X86_REG_FLAGS, 0x0202)
        stop = CMDSEG * 16 + CALLOFF + 0x20
        try:
            self.uc.emu_start(cs * 16 + ip, stop, count=limit)
        except (Exit, OutOfKeys):
            raise
        at = self.reg(UC_X86_REG_CS) * 16 + self.reg(UC_X86_REG_IP)
        if at != stop:
            raise RuntimeError('ran away: %05X' % at)

    def program(self, tail, psp=PSP1):
        """Run the program with a command tail; returns its exit code."""
        self.psp = psp
        uc = self.uc
        psp_b = bytearray(256)
        psp_b[0:2] = b'\xcd\x20'
        struct.pack_into('<H', psp_b, 2, 0xA000)
        struct.pack_into('<H', psp_b, 0x2C, ENVSEG)
        t = tail.encode('latin1')
        psp_b[0x80] = len(t); psp_b[0x81:0x81 + len(t)] = t; psp_b[0x81 + len(t)] = 13
        uc.mem_write(psp * 16, bytes(psp_b))
        uc.mem_write(psp * 16 + 0x100, self.image)
        for r in (UC_X86_REG_DS, UC_X86_REG_ES):
            self.setreg(r, psp)
        self.setreg(UC_X86_REG_AX, 0); self.setreg(UC_X86_REG_BX, 0)
        self.exitcode = None
        # a word of zero on the stack: RET goes to PSP:0 (INT 20h) as on DOS
        uc.mem_write(psp * 16 + 0xFFFE, b'\x00\x00')
        self.setreg(UC_X86_REG_CS, psp); self.setreg(UC_X86_REG_IP, 0x100)
        self.setreg(UC_X86_REG_SS, psp); self.setreg(UC_X86_REG_SP, 0xFFFE)
        self.setreg(UC_X86_REG_FLAGS, 0x0202)
        try:
            self.uc.emu_start(psp * 16 + 0x100, 0xFFFFF, count=50_000_000)
            raise RuntimeError('program did not exit')
        except Exit:
            pass
        return self.exitcode

    def prompt(self, text='C:\\>'):
        for b in text.encode(): self.teletype(b)

    def readline(self, template):
        """COMMAND.COM's call: INT 2Fh AX=4810h, DS:DX -> 128-byte buffer.
        Returns the bytes handed back, or None if DOSKEY declined."""
        uc = self.uc
        base = CMDSEG * 16
        buf = bytearray(130)
        buf[0] = 0x80; buf[1] = len(template)
        buf[2:2 + len(template)] = template; buf[2 + len(template)] = 13
        uc.mem_write(base + BUFOFF, bytes(buf))
        uc.mem_write(base + CALLOFF + 0x20, b'\xcd\x2f\xf4')    # int 2Fh here, stop after
        self.setreg(UC_X86_REG_AX, 0x4810)
        self.setreg(UC_X86_REG_DS, CMDSEG); self.setreg(UC_X86_REG_DX, BUFOFF)
        self.setreg(UC_X86_REG_ES, CMDSEG)
        self.setreg(UC_X86_REG_CS, CMDSEG); self.setreg(UC_X86_REG_IP, CALLOFF + 0x20)
        self.setreg(UC_X86_REG_SS, 0x9000); self.setreg(UC_X86_REG_SP, 0xFFF0)
        self.setreg(UC_X86_REG_FLAGS, 0x0202)
        self.uc.emu_start(base + CALLOFF + 0x20, base + CALLOFF + 0x22, count=20_000_000)
        at = self.reg(UC_X86_REG_CS) * 16 + self.reg(UC_X86_REG_IP)
        if at != base + CALLOFF + 0x22:
            raise RuntimeError('4810h ran away: %05X' % at)
        if self.reg(UC_X86_REG_AX) != 0:
            return None
        n = self.r8(base + BUFOFF + 1)
        b = bytes(uc.mem_read(base + BUFOFF + 2, n + 1))
        if b[-1] != 13:
            raise RuntimeError('no CR after the line')
        return b[:-1]

    def call2f(self, ax):
        base = CMDSEG * 16
        self.uc.mem_write(base + 0x40, b'\xcd\x2f\xf4')
        self.setreg(UC_X86_REG_AX, ax)
        self.setreg(UC_X86_REG_CS, CMDSEG); self.setreg(UC_X86_REG_IP, 0x40)
        self.setreg(UC_X86_REG_SS, 0x9000); self.setreg(UC_X86_REG_SP, 0xFFF0)
        self.uc.emu_start(base + 0x40, base + 0x42, count=1_000_000)
        return self.reg(UC_X86_REG_AX), self.reg(UC_X86_REG_ES)


class Session:
    """A PC with DOSKEY installed, and a COMMAND.COM loop on top."""
    def __init__(self, image, tail='', ansi=True):
        self.pc = PC(image, ansi=ansi)
        self.template = b''
        self.log = []
        self.pc.prompt('C:\\>')
        rc = self.pc.program(tail)
        self.pc.teletype(13); self.pc.teletype(10)
        self.log.append(('install', rc, self.pc.resident is not None, self.pc.state()))

    def run(self, tail):
        pc = self.pc
        pc.prompt('C:\\>DOSKEY ' + tail)
        pc.teletype(13); pc.teletype(10)
        rc = pc.program(tail, psp=PSP2)
        self.log.append(('run', tail, rc, pc.state()))
        return rc

    def type(self, keys, maxcalls=40):
        """Type the keystrokes at the prompt; call 4810h until they are used up."""
        pc = self.pc
        pc.keys = list(keys)
        for _ in range(maxcalls):
            pc.prompt('C:\\>')
            try:
                line = pc.readline(self.template)
            except OutOfKeys:
                self.log.append(('wait', pc.state()))
                # leave the half-typed line: the next call starts afresh
                pc.teletype(13); pc.teletype(10)
                return
            if line is None:
                raise RuntimeError('DOSKEY declined 4810h')
            self.template = line
            pc.teletype(13); pc.teletype(10)
            self.log.append(('line', line, pc.state()))
        raise RuntimeError('too many lines')


# ---- keys
def K(s):
    """Keys from text; {Name} for special keys."""
    ext = dict(F1=0x3B, F2=0x3C, F3=0x3D, F4=0x3E, F5=0x3F, F6=0x40, F7=0x41, F8=0x42, F9=0x43,
               F10=0x44, AF7=0x6E, AF10=0x71, UP=0x48, DOWN=0x50, LEFT=0x4B, RIGHT=0x4D,
               HOME=0x47, END=0x4F, PGUP=0x49, PGDN=0x51, INS=0x52, DEL=0x53, CLEFT=0x73,
               CRIGHT=0x74, CHOME=0x77, CEND=0x75, STAB=0x0F, AF1=0x68)
    ctl = dict(ESC=0x1B, BS=0x08, CR=0x0D, TAB=0x09, LF=0x0A)
    out = []
    i = 0
    while i < len(s):
        if s[i] == '{':
            j = s.index('}', i)
            name = s[i + 1:j]
            if name in ext: out.append(0x100 | ext[name])
            elif name in ctl: out.append(ctl[name])
            elif name.startswith('^'): out.append(ord(name[1]) & 0x1F)
            elif name.startswith('x'): out.append(int(name[1:], 16))
            else: raise ValueError(name)
            i = j + 1
        else:
            out.append(ord(s[i])); i += 1
    return out


def session_script(seed, n):
    """A random session: a few commands, edits, recalls, macros."""
    rnd = random.Random(seed)
    words = ['dir', 'cls', 'type autoexec.bat', 'echo hello world', 'cd \\dos', 'mem /c',
             'copy a.txt b.txt', 'ver', 'x', 'a b c d e f', 'EDIT CONFIG.SYS', 'del *.bak']
    keys = ['{LEFT}', '{RIGHT}', '{HOME}', '{END}', '{UP}', '{DOWN}', '{PGUP}', '{PGDN}', '{INS}',
            '{DEL}', '{BS}', '{ESC}', '{CLEFT}', '{CRIGHT}', '{CHOME}', '{CEND}', '{F1}', '{F3}',
            '{F5}', '{F6}', '{F8}', '{^A}', '{^T}', '{x14}', '{x15}', '{TAB}', ' ', 'q', 'Z', '$',
            '{F2}e', '{F4}o', '{F2}{UP}', '{F10}', '{AF1}', '{LF}', '{^F}', '{xE9}', '{x7F}']
    steps = []
    for k in range(rnd.randint(0, 4)):
        nm = rnd.choice(['a', 'bb', 'ccc', 'long', 'x1', 'Q'])
        steps.append(('run', nm + '=' + rnd.choice(['echo ' * rnd.randint(1, 20), 'dir $1$t$2', '', 'type $* $$ $b more', 'x', 'xy', 'z' * rnd.randint(0, 9)])))
    for _ in range(n):
        r = rnd.random()
        if r < 0.10:
            steps.append(('run', rnd.choice(['/H', '/M', '/INSERT', '/OVERSTRIKE', 'M=echo $1 $2 $* $$ $g $t ver',
                                             'dd=dir $1', 'm=', 'q=echo one$Techo two$ttwo',
                                             'bad', '/BUFSIZE=100', '/h /m', 'Z = cls ',
                                             'long=' + 'x' * 100])))
        else:
            s = ''
            for _ in range(rnd.randint(0, 12)):
                if rnd.random() < 0.4:
                    s += rnd.choice(words)
                else:
                    s += rnd.choice(keys)
            if rnd.random() < 0.3: s += '{F7}'
            elif rnd.random() < 0.2: s += '{F9}' + str(rnd.randint(0, 12)) + rnd.choice(['{CR}', '{ESC}', '{BS}{CR}'])
            s += '{CR}'
            steps.append(('type', s))
    return steps


def compare(ref_img, test_img, steps, tail='', ansi=True, verbose=False, ttail='/NOTAB'):
    a = Session(ref_img, tail, ansi); b = Session(test_img, (tail + ' ' + ttail).strip(), ansi)
    for st in steps:
        for s in (a, b):
            if st[0] == 'run': s.run(st[1])
            else: s.type(K(st[1]) + [0x0D] * 0)
        if a.log != b.log:
            return describe(a.log, b.log, st)
    return None


def describe(la, lb, step):
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            out = ['step %r, log entry %d' % (step, i)]
            out.append('ref : %r' % (x[:-1],))
            out.append('test: %r' % (y[:-1],))
            sa, sb = x[-1], y[-1]
            if sa != sb:
                out.append('ref  cur %r shape %04X ins %d beeps %d' % sa[1:])
                out.append('test cur %r shape %04X ins %d beeps %d' % sb[1:])
                for r in range(25):
                    if sa[0][r] != sb[0][r]:
                        out.append('row %2d ref : %r' % (r, sa[0][r].rstrip()))
                        out.append('       test: %r' % sb[0][r].rstrip())
            return '\n'.join(out)
    return 'logs differ in length: %d vs %d' % (len(la), len(lb))


def show(img, steps, tail=''):
    s = Session(img, tail)
    for st in steps:
        if st[0] == 'run': s.run(st[1])
        else: s.type(K(st[1]))
    for e in s.log:
        print(e[:-1])
    print('\n'.join(r.rstrip() for r in s.pc.screen()))
    print('cursor', s.pc.getcur())


if __name__ == '__main__':
    args = sys.argv[1:]
    if args and args[0] == 'show':
        img = open(args[1], 'rb').read()
        steps = [('run', a[1:]) if a.startswith('@') else ('type', a) for a in args[2:]]
        show(img, steps)
        sys.exit(0)
    ref = open(args[0], 'rb').read()
    test = open(args[1], 'rb').read()
    seed = 1; fuzz = 200
    if '--seed' in args: seed = int(args[args.index('--seed') + 1])
    if '--fuzz' in args: fuzz = int(args[args.index('--fuzz') + 1])
    bad = 0
    for k in range(fuzz):
        rnd = random.Random(seed + k)
        steps = session_script(seed + k, rnd.choice([12, 30, 60]))
        tail = rnd.choice(['', '', '/INSERT', '/BUFSIZE=260', '/BUFSIZE=262', '/BUFSIZE=264', '/BUFSIZE=300 /INSERT', '/BUFSIZE=400', '/OVERSTRIKE'])
        for ansi in (True, False):
            r = compare(ref, test, steps, tail=tail, ansi=ansi)
            if r:
                bad += 1
                print('SESSION seed %d ansi=%s DIFFERS\n%s' % (seed + k, ansi, r))
                break
        if bad >= 3: break
    print('%d sessions, %d differ' % (fuzz, bad))
    sys.exit(1 if bad else 0)
