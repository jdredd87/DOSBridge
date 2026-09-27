"""emuansi.py -- run console drivers (ANSI.SYS and ours) in an 8086 emulator
over a model PC, drive them every way DOS and programs do, and compare.
StevenC & Claude, 2026.

    python emuansi.py [--count] REF.SYS[@6.22] TEST.SYS[@6.22] [...]

The first driver is the reference; every other one is compared with it,
in every combination of:

  hardware  vga, vgamono (a VGA that booted mono, as the V30 sometimes
            does), ega (5154 colour), ega5151 (EGA on a mono display), cga
            (its BIOS never sets the row count), mda
  switches  none, /X, /K, /R, /S, /X /R, /L
  path      'req'   the device driver WRITE request -- a handle write
            'int29' INT 29h -- what DOS uses for a fast console
  code      for our drivers also with the 8086 code forced (No186),
            so both the 8086 and the 186/V20/V30 paths are proven

and for every scenario (SCENARIOS below): text, wrapping, scrolling,
every escape sequence, bad ones, keyboard input with key reassignment
and the extended keys, the generic IOCTL (MODE CON) get and set, the
INT 2Fh interface, programs setting video modes through INT 10h, pages,
40 columns, 43/50 rows, graphics.

What is compared: the whole screen (characters and attributes) of the
active page, the cursor in the BIOS data area and in the CRTC, the video
mode and rows, beeps, and the result of every operation (keyboard bytes
read, request status words, IOCTL packets returned, INT 2Fh registers).

The model PC is a BIOS written in Python working on real video memory and
the real BIOS data area -- so a driver that bypasses the BIOS and one
that goes through it are held to the same result.  The video buffer the
adapter does not decode reads back FFh, as on the hardware.

--count also reports instructions executed per character written: a
proxy for speed that needs no hardware (it is not cycle-exact).
"""
import struct, sys
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN, UC_HOOK_CODE
from unicorn.x86_const import *

DRV = 0x1000            # driver load segment
STUBS = 0xF000          # BIOS stubs at F000:xxxx
REQ = 0x0700            # request header (linear)
PKT = 0x0780            # IOCTL / INT 2Fh packet (linear)
CMDL = 0x07C0
BUF = 0x0800            # transfer buffer (linear, 2 KB)
CALLSTUB = 0x0600

CONFIGS = {
    # mode, equipment bits 4-5, ega, vga, sets 40:84, 12h/10h BH (mono), CX switches
    'vga':     dict(mode=3, equip=0x20, ega=True, vga=True, dcc=8, rows84=True, egamono=0, sw=0x09),
    'vgamono': dict(mode=7, equip=0x30, ega=True, vga=True, dcc=7, rows84=True, egamono=1, sw=0x0B),
    'ega':     dict(mode=3, equip=0x20, ega=True, vga=False, dcc=None, rows84=True, egamono=0, sw=0x09),
    'ega5151': dict(mode=7, equip=0x30, ega=True, vga=False, dcc=None, rows84=True, egamono=1, sw=0x0B),
    'cga':     dict(mode=3, equip=0x20, ega=False, vga=False, dcc=None, rows84=False, egamono=0, sw=0),
    'mda':     dict(mode=7, equip=0x30, ega=False, vga=False, dcc=None, rows84=False, egamono=0, sw=0),
}


class PC:
    def __init__(self, image, dosver=(6, 22), cmdline=b'ANSI.SYS', config='vga', no186=False, count=False):
        self.cfg = CONFIGS[config]
        self.dosver = dosver
        self.out = []
        self.keys = []
        self.beeps = 0
        self.crtc = {}
        self.crtc_idx = 0
        self.retrace = 0
        self.icount = 0
        uc = self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        mono = self.cfg['mode'] == 7
        # conventional + everything up to the undecoded half of the video area
        uc.mem_map(0, 0xB0000)
        if mono:
            uc.mem_map(0xB0000, 0x8000)
            uc.mmio_map(0xB8000, 0x8000, self._nobus_r, None, self._nobus_w, None)
        else:
            uc.mmio_map(0xB0000, 0x8000, self._nobus_r, None, self._nobus_w, None)
            uc.mem_map(0xB8000, 0x8000)
        uc.mem_map(0xC0000, 0x40000)
        for k, n in enumerate((0x10, 0x16, 0x15, 0x11)):
            addr = 0x100 + k * 0x10
            uc.mem_write(STUBS * 16 + addr, bytes([0xCD, 0xF0 + k, 0xCA, 0x02, 0x00]))
            uc.mem_write(n * 4, struct.pack('<HH', addr, STUBS))
        uc.mem_write(STUBS * 16 + 0x180, b'\xcf')
        for n in (0x2F, 0x2A, 0x1B, 0x23, 0x24, 0x29):
            uc.mem_write(n * 4, struct.pack('<HH', 0x180, STUBS))
        con = STUBS * 16 + 0x200            # DOS's own CON underneath
        uc.mem_write(con, struct.pack('<HHHHH', 0xFFFF, 0xFFFF, 0x8013, 0x212, 0x220) + b'CON     ')
        uc.mem_write(con + 0x12, b'\x2e\x89\x1e\x40\x02\x2e\x8c\x06\x42\x02\xcb')
        uc.mem_write(con + 0x20, b'\x1e\x53\x2e\xc5\x1e\x40\x02\xc7\x47\x03\x00\x01\x5b\x1f\xcb')
        uc.mem_write(STUBS * 16 + 0x300, bytes([0xFF, 0xFF, 0x0F, 0, 0, 0, 0, 0x07]) + bytes(8))
        if no186:
            image = bytearray(image)
            i = image.find(b'SC_NO186')
            if i < 0: raise RuntimeError('this driver has no No186 marker')
            image[i + 8] = 1
            image = bytes(image)
        uc.mem_write(DRV * 16, image)
        uc.mem_write(DRV * 16, struct.pack('<HH', 0x200, STUBS))
        uc.hook_add(UC_HOOK_INTR, self._intr)
        uc.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)
        uc.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        if count:
            uc.hook_add(UC_HOOK_CODE, self._count)
        self.w16(0x410, self.cfg['equip'] | 0x0001)
        self.w8(0x496, 0x10)
        self.w8(0x487, 0x60 if not mono else 0x62); self.w8(0x488, self.cfg['sw']); self.w8(0x489, 0x11)
        self.set_mode(self.cfg['mode'])
        self.icount = 0
        self.init(cmdline)

    def _count(self, uc, addr, size, ud):
        self.icount += 1

    def _nobus_r(self, uc, off, size, ud):
        return (1 << (8 * size)) - 1

    def _nobus_w(self, uc, off, size, value, ud):
        pass

    # ---- memory helpers
    def r8(self, a): return self.uc.mem_read(a, 1)[0]
    def r16(self, a): return struct.unpack('<H', bytes(self.uc.mem_read(a, 2)))[0]
    def w8(self, a, v): self.uc.mem_write(a, bytes([v & 0xFF]))
    def w16(self, a, v): self.uc.mem_write(a, struct.pack('<H', v & 0xFFFF))
    def reg(self, r): return self.uc.reg_read(r)
    def setreg(self, r, v): self.uc.reg_write(r, v)

    # ---- the video BIOS
    def mode(self): return self.r8(0x449)
    def cols(self): return self.r16(0x44A)
    def rows(self):
        r = self.r8(0x484)
        return r + 1 if r else 25
    def page(self): return self.r8(0x462)
    def text(self): return self.mode() in (0, 1, 2, 3, 7)
    def vseg(self): return 0xB000 if self.mode() == 7 else (0xA000 if self.mode() >= 0x0D else 0xB800)

    def cell(self, pg, r, c):
        return self.vseg() * 16 + pg * self.r16(0x44C) + (r * self.cols() + c) * 2

    def getcur(self, pg):
        v = self.r16(0x450 + pg * 2)
        return v >> 8, v & 0xFF

    def setcur(self, pg, r, c):
        self.w16(0x450 + pg * 2, (r << 8) | c)
        if pg == self.page():
            pos = self.r16(0x44E) // 2 + r * self.cols() + c
            self.crtc[0x0E] = (pos >> 8) & 0xFF; self.crtc[0x0F] = pos & 0xFF

    def set_mode(self, m):
        mm = m & 0x7F
        cols = {0: 40, 1: 40, 2: 80, 3: 80, 4: 40, 5: 40, 6: 80, 7: 80, 0x0D: 40, 0x0E: 80,
                0x0F: 80, 0x10: 80, 0x11: 80, 0x12: 80, 0x13: 40}.get(mm, 80)
        self.w8(0x449, mm); self.w16(0x44A, cols)
        self.w16(0x44C, 4096 if cols == 80 else 2048)
        self.w16(0x44E, 0); self.w8(0x462, 0)
        self.w16(0x463, 0x3B4 if mm == 7 else 0x3D4)
        if self.cfg['rows84']:
            self.w8(0x484, 29 if mm in (0x11, 0x12) else 24); self.w8(0x485, 16)
        for pg in range(8): self.w16(0x450 + pg * 2, 0)
        self.crtc[0x0E] = self.crtc[0x0F] = 0
        self.gfx = {}
        if not (m & 0x80):
            if mm in (0, 1, 2, 3, 7):
                self.uc.mem_write(self.vseg() * 16, b'\x20\x07' * 0x4000)
            else:
                self.uc.mem_write(0xA0000, bytes(0x10000))

    def put(self, pg, r, c, ch, attr=None):
        if self.text():
            a = self.cell(pg, r, c)
            self.w8(a, ch)
            if attr is not None: self.w8(a + 1, attr)
        else:
            self.gfx[(r, c)] = (ch, attr if attr is not None else self.gfx.get((r, c), (0, 0))[1])

    def get(self, pg, r, c):
        if self.text():
            a = self.cell(pg, r, c)
            return self.r8(a), self.r8(a + 1)
        return self.gfx.get((r, c), (0x20, 0))

    def scroll(self, up, n, attr, r0, c0, r1, c1):
        pg = self.page()
        r1 = min(r1, self.rows() - 1); c1 = min(c1, self.cols() - 1)
        if r0 > r1 or c0 > c1: return
        h = r1 - r0 + 1
        if n == 0 or n > h: n = h
        rng = range(r0, r1 + 1) if up else range(r1, r0 - 1, -1)
        for r in rng:
            src = r + n if up else r - n
            for c in range(c0, c1 + 1):
                if r0 <= src <= r1:
                    ch, a = self.get(pg, src, c)
                else:
                    ch, a = 0x20, attr
                self.put(pg, r, c, ch, a)

    def teletype(self, ch, colour):
        pg = self.page()
        r, c = self.getcur(pg)
        if ch == 7:
            self.beeps += 1; return
        if ch == 8:
            if c: c -= 1
        elif ch == 13:
            c = 0
        elif ch == 10:
            if r < self.rows() - 1:
                r += 1
            else:
                attr = self.get(pg, r, c)[1] if self.text() else 0
                self.scroll(True, 1, attr, 0, 0, self.rows() - 1, self.cols() - 1)
        else:
            self.put(pg, r, c, ch, None if self.text() else colour)
            c += 1
            if c >= self.cols():
                c = 0
                if r < self.rows() - 1:
                    r += 1
                else:
                    attr = self.get(pg, r, 0)[1] if self.text() else 0
                    self.scroll(True, 1, attr, 0, 0, self.rows() - 1, self.cols() - 1)
        self.setcur(pg, r, c)

    def int10(self):
        g = self.reg; s = self.setreg; cfg = self.cfg
        ax, bx, cx, dx = g(UC_X86_REG_AX), g(UC_X86_REG_BX), g(UC_X86_REG_CX), g(UC_X86_REG_DX)
        ah, al, bh, bl = ax >> 8, ax & 0xFF, bx >> 8, bx & 0xFF
        if ah == 0x00: self.set_mode(al)
        elif ah == 0x01: self.w16(0x460, cx); self.cursor_shape = cx
        elif ah == 0x02: self.setcur(bh & 7, dx >> 8, dx & 0xFF)
        elif ah == 0x03:
            r, c = self.getcur(bh & 7); s(UC_X86_REG_DX, (r << 8) | c); s(UC_X86_REG_CX, self.r16(0x460))
        elif ah == 0x05:
            self.w8(0x462, al); self.w16(0x44E, al * self.r16(0x44C))
        elif ah in (0x06, 0x07):
            self.scroll(ah == 6, al, bh, cx >> 8, cx & 0xFF, dx >> 8, dx & 0xFF)
        elif ah == 0x08:
            r, c = self.getcur(bh & 7); ch, a = self.get(bh & 7, r, c); s(UC_X86_REG_AX, (a << 8) | ch)
        elif ah in (0x09, 0x0A):
            pg = bh & 7; r, c = self.getcur(pg)
            for i in range(cx):
                cc = c + i; rr = r + cc // self.cols(); cc %= self.cols()
                if rr >= self.rows(): break
                self.put(pg, rr, cc, al, bl if (ah == 9 or not self.text()) else None)
        elif ah == 0x0E: self.teletype(al, bl)
        elif ah == 0x0F: s(UC_X86_REG_AX, (self.cols() << 8) | self.mode()); s(UC_X86_REG_BX, (self.page() << 8) | bl)
        elif ah == 0x10:
            if al == 0x03 and cfg['ega']: self.blink = bl
        elif ah == 0x11 and cfg['ega']:
            h = {0x11: 14, 0x12: 8, 0x14: 16, 0x01: 14, 0x02: 8, 0x04: 16}.get(al)
            if h:
                scans = 350 if not cfg['vga'] else 400
                if hasattr(self, 'scans'): scans = self.scans
                self.w8(0x485, h); self.w8(0x484, scans // h - 1)
            elif al == 0x30:
                s(UC_X86_REG_CX, self.r8(0x485)); s(UC_X86_REG_DX, self.r8(0x484))
        elif ah == 0x12 and cfg['ega']:
            if bl == 0x10: s(UC_X86_REG_BX, (cfg['egamono'] << 8) | 0x03); s(UC_X86_REG_CX, cfg['sw'])
            elif bl == 0x30 and cfg['vga']:
                self.scans = {0: 200, 1: 350, 2: 400}.get(al, 400); s(UC_X86_REG_AX, (ah << 8) | 0x12)
            elif bl in (0x20, 0x31, 0x32, 0x33, 0x34, 0x36) and cfg['vga']: s(UC_X86_REG_AX, (ah << 8) | 0x12)
            elif bl == 0x20: pass
        elif ah == 0x1A and cfg['vga']:
            if al == 0: s(UC_X86_REG_AX, 0x001A); s(UC_X86_REG_BX, cfg['dcc'])
        elif ah == 0x1B and cfg['vga']:
            es, di = g(UC_X86_REG_ES), g(UC_X86_REG_DI)
            blk = bytearray(64)
            struct.pack_into('<HH', blk, 0, 0x300, STUBS)
            blk[4] = self.mode(); struct.pack_into('<H', blk, 5, self.cols())
            blk[0x22] = self.rows(); blk[0x25] = cfg['dcc']; blk[0x26] = 0; blk[0x2A] = 2
            blk[0x2D] = 0x01 | (0x20 if getattr(self, 'blink', 1) else 0)
            self.uc.mem_write(es * 16 + di, bytes(blk)); s(UC_X86_REG_AX, (ah << 8) | 0x1B)

    def int16(self):
        ah = self.reg(UC_X86_REG_AX) >> 8
        fl = self.reg(UC_X86_REG_FLAGS)
        if ah in (0x00, 0x10):
            if not self.keys: raise RuntimeError('keyboard read with nothing queued')
            k = self.keys.pop(0)
            if ah == 0x00 and (k & 0xFF) == 0xE0: k &= 0xFF00          # the old call
            self.setreg(UC_X86_REG_AX, k)
        elif ah in (0x01, 0x11):
            if self.keys:
                k = self.keys[0]
                if ah == 0x01 and (k & 0xFF) == 0xE0: k &= 0xFF00
                self.setreg(UC_X86_REG_AX, k); fl &= ~0x40
            else:
                fl |= 0x40
            self._flags(fl)
        elif ah in (0x02, 0x12):
            self.setreg(UC_X86_REG_AX, 0)

    def _flags(self, fl):
        ss, sp = self.reg(UC_X86_REG_SS), self.reg(UC_X86_REG_SP)
        self.w16(ss * 16 + sp + 4, fl)

    def _intr(self, uc, n, ud):
        ip, cs = self.reg(UC_X86_REG_IP), self.reg(UC_X86_REG_CS)
        ax = self.reg(UC_X86_REG_AX)
        if n in (0x10, 0x16, 0x15, 0x11, 0x2F, 0x29, 0x2A, 0x1B):
            fl = self.reg(UC_X86_REG_FLAGS)
            sp = self.reg(UC_X86_REG_SP) - 6; ss = self.reg(UC_X86_REG_SS)
            uc.mem_write(ss * 16 + sp, struct.pack('<HHH', ip, cs, fl))
            self.setreg(UC_X86_REG_SP, sp); self.setreg(UC_X86_REG_FLAGS, fl & ~0x0300)
            off, seg = struct.unpack('<HH', bytes(uc.mem_read(n * 4, 4)))
            self.setreg(UC_X86_REG_CS, seg); self.setreg(UC_X86_REG_IP, off)
            return
        if n == 0xF0: self.int10(); return
        if n == 0xF1: self.int16(); return
        if n == 0xF2:
            self.setreg(UC_X86_REG_AX, (0x86 << 8) | (ax & 0xFF)); self._flags(self.reg(UC_X86_REG_FLAGS) | 1); return
        if n == 0xF3: self.setreg(UC_X86_REG_AX, self.r16(0x410)); return
        if n == 0x21:
            ah = ax >> 8
            if ah == 0x30:
                maj, mnr = self.dosver; self.setreg(UC_X86_REG_AX, (mnr << 8) | maj); self.setreg(UC_X86_REG_BX, 0)
            elif ah == 0x09:
                ds, dx = self.reg(UC_X86_REG_DS), self.reg(UC_X86_REG_DX)
                m = bytes(uc.mem_read(ds * 16 + dx, 400)); self.out.append(m[:m.index(b'$')].decode('latin1'))
            elif ah == 0x40:
                ds, dx, cx = self.reg(UC_X86_REG_DS), self.reg(UC_X86_REG_DX), self.reg(UC_X86_REG_CX)
                self.out.append(bytes(uc.mem_read(ds * 16 + dx, cx)).decode('latin1')); self.setreg(UC_X86_REG_AX, cx)
            elif ah == 0x35:
                off, seg = struct.unpack('<HH', bytes(uc.mem_read((ax & 0xFF) * 4, 4)))
                self.setreg(UC_X86_REG_BX, off); self.setreg(UC_X86_REG_ES, seg)
            elif ah == 0x25:
                uc.mem_write((ax & 0xFF) * 4, struct.pack('<HH', self.reg(UC_X86_REG_DX), self.reg(UC_X86_REG_DS)))
            elif ah == 0x59:
                self.setreg(UC_X86_REG_AX, 0)
            elif ah in (0x38, 0x65, 0x66, 0x44, 0x62, 0x51, 0x2F, 0x34, 0x63):
                self.setreg(UC_X86_REG_FLAGS, self.reg(UC_X86_REG_FLAGS) | 1)
            else:
                raise RuntimeError('INT 21h AH=%02X from %04X:%04X' % (ah, cs, ip))
            return
        raise RuntimeError('unexpected INT %02Xh AX=%04X at %04X:%04X' % (n, ax, cs, ip))

    def _out(self, uc, port, size, value, ud):
        if port in (0x3D4, 0x3B4):
            self.crtc_idx = value & 0xFF
            if size == 2: self.crtc[self.crtc_idx] = value >> 8
        elif port in (0x3D5, 0x3B5):
            self.crtc[self.crtc_idx] = value & 0xFF

    def _in(self, uc, port, size, ud):
        if port in (0x3DA, 0x3BA):
            self.retrace ^= 1
            return 0x09 if self.retrace else 0x00
        if port in (0x3D5, 0x3B5):
            return self.crtc.get(self.crtc_idx, 0)
        return 0xFF

    # ---- calling the driver
    def run(self, seg, off, stop, limit=60_000_000):
        self.setreg(UC_X86_REG_CS, seg); self.setreg(UC_X86_REG_IP, off)
        self.uc.emu_start(seg * 16 + off, stop, count=limit)
        at = self.reg(UC_X86_REG_CS) * 16 + self.reg(UC_X86_REG_IP)
        if at != stop:
            raise RuntimeError('did not come back: %05X' % at)

    def _callstub(self):
        strat, intr = struct.unpack('<HH', bytes(self.uc.mem_read(DRV * 16 + 6, 4)))
        self.uc.mem_write(CALLSTUB, b'\x9a' + struct.pack('<HH', strat, DRV) + b'\x9a' + struct.pack('<HH', intr, DRV) + b'\xf4')
        for r, v in ((UC_X86_REG_ES, 0), (UC_X86_REG_BX, REQ), (UC_X86_REG_DS, 0),
                     (UC_X86_REG_SS, 0x9000), (UC_X86_REG_SP, 0xFFF0), (UC_X86_REG_FLAGS, 0x0202)):
            self.setreg(r, v)
        self.run(0, CALLSTUB, CALLSTUB + 10)

    def request(self, cmd, data=b'', count=None, hdr=None):
        req = bytearray(32); req[0] = 32; req[2] = cmd
        struct.pack_into('<HH', req, 14, BUF, 0)
        struct.pack_into('<H', req, 18, len(data) if count is None else count)
        if hdr:
            for off, b in hdr.items(): req[off] = b
        self.uc.mem_write(REQ, bytes(req))
        if data: self.uc.mem_write(BUF, data)
        self._callstub()
        return bytes(self.uc.mem_read(REQ, 32))

    def init(self, cmdline):
        self.uc.mem_write(CMDL, cmdline + b'\r\n')
        req = bytearray(32); req[0] = 32; req[2] = 0
        struct.pack_into('<HH', req, 18, CMDL, 0)
        self.uc.mem_write(REQ, bytes(req))
        self._callstub()
        r = bytes(self.uc.mem_read(REQ, 32))
        self.init_status = struct.unpack_from('<H', r, 3)[0]
        bo, bs = struct.unpack_from('<HH', r, 14)
        self.resident = (bs - DRV) * 16 + bo

    def write(self, data, via):
        if via == 'req':
            for i in range(0, len(data), 1024):
                self.request(8, data[i:i + 1024])
        else:
            prog = bytearray()
            for b in data:
                prog += bytes([0xB0, b, 0xCD, 0x29])
            prog += b'\xf4'
            base = getattr(self, 'progbase', 0x20000)
            self.progbase = base + ((len(prog) + 0xF) & ~0xF)
            if self.progbase > 0x80000:
                raise RuntimeError('INT 29h text too long')
            self.uc.mem_write(base, bytes(prog))
            for r, v in ((UC_X86_REG_SS, 0x9000), (UC_X86_REG_SP, 0xFFF0), (UC_X86_REG_DS, 0x9000),
                         (UC_X86_REG_ES, 0x9000), (UC_X86_REG_FLAGS, 0x0202)):
                self.setreg(r, v)
            self.run(base >> 4, 0, base + len(prog) - 1)

    def callint(self, n, **regs):
        base = getattr(self, 'progbase', 0x20000)
        self.progbase = base + 16
        self.uc.mem_write(base, bytes([0xCD, n, 0xF4]))
        for r, v in ((UC_X86_REG_SS, 0x9000), (UC_X86_REG_SP, 0xFFF0), (UC_X86_REG_FLAGS, 0x0202),
                     (UC_X86_REG_DS, 0), (UC_X86_REG_ES, 0)):
            self.setreg(r, v)
        for k, v in regs.items():
            self.setreg(getattr(__import__('unicorn.x86_const', fromlist=['x']), 'UC_X86_REG_' + k.upper()), v)
        self.run(base >> 4, 0, base + 2)
        g = self.reg
        return dict(ax=g(UC_X86_REG_AX), bx=g(UC_X86_REG_BX), cx=g(UC_X86_REG_CX), dx=g(UC_X86_REG_DX),
                    cf=g(UC_X86_REG_FLAGS) & 1)

    def snapshot(self):
        pg = self.page()
        if self.text():
            base = self.vseg() * 16 + self.r16(0x44E)
            scr = bytes(self.uc.mem_read(base, self.rows() * self.cols() * 2))
        else:
            scr = repr(sorted(self.gfx.items())).encode()
        return dict(mode=self.mode(), rows=self.rows(), cur=self.getcur(pg),
                    crtc=(self.crtc.get(0x0E), self.crtc.get(0x0F)) if self.text() else None,
                    beeps=self.beeps, screen=scr, shape=self.r16(0x460),
                    equip=self.r16(0x410), cemu=self.r8(0x487))


# ------------------------------------------------------------ scenarios
E = b'\x1b['


def long_text(n):
    return b''.join(b'line %03d ' % i + bytes(range(65, 65 + (i % 50))) + b'\r\n' for i in range(n))


def pkt(mode=1, colors=16, width=640, length=400, cols=80, rows=25, flags=0, level=0, length_field=14, reserved=0):
    return struct.pack('<BBHHBBHHHHH', level, 0, length_field, flags, mode, reserved, colors, width, length, cols, rows)


SCENARIOS = [
    ('plain text and scrolling', [('w', long_text(40))]),
    ('wrap at the last column', [('w', b'X' * 200 + b'\r\n' + b'Y' * 80 + b'Z')]),
    ('control characters', [('w', b'abc\x08\x08D\rE\x07\tF\x08\x08\x08\x08\x08\x08G\r\n\x08H\x0c\x1b\x00\x01\xff')]),
    ('every SGR code', [('w', b''.join(E + b'%dm%02d ' % (n, n) for n in (0, 1, 4, 5, 7, 8, 30, 31, 32, 33, 34, 35, 36, 37,
                                                                        40, 41, 42, 43, 44, 45, 46, 47, 2, 3, 6, 9, 22, 39, 49, 99)) + E + b'0m')]),
    ('SGR combined and repeated', [('w', E + b'1;31;44mA' + E + b'0;;7mB' + E + b';;;mC' + E + b'1;1;1;1;1;1;1;1;1;1;1;1;1;32mD' + E + b'm')]),
    ('SGR then scroll: fill colour', [('w', E + b'44;33m' + long_text(30) + E + b'0m' + long_text(3))]),
    ('scroll with the cursor on a coloured cell', [('w', E + b'25;1H' + E + b'41mR' + E + b'0m' + E + b'25;1H\n\n' + E + b'42m\n\n')]),
    ('cursor position H and f', [('w', E + b'10;20Hat' + E + b'1;1Hhome' + E + b'25;80Hcorner' + E + b'99;99Hclamp' + E + b';5Hcol5'
                                       + E + b'Hhome2' + E + b'5fF5' + E + b'0;0Hzero' + E + b'12;Hnocol' + E + b'26;1Hoff')]),
    ('cursor moves A B C D, counts and clamping', [('w', E + b'12;40H*' + E + b'5A^' + E + b'3B_' + E + b'10C>' + E + b'20D<'
                                                     + E + b'99A|' + E + b'99D!' + E + b'99B#' + E + b'99C$' + E + b'A' + E + b'0B%' + E + b'255C&')]),
    ('cursor down to the bottom, then text', [('w', E + b'1;1H' + E + b'30BX' + E + b'BY' + b'\r\nZ')]),
    ('erase display and line', [('w', long_text(20) + E + b'5;10H' + E + b'K' + E + b'7;1H' + E + b'1K' + E + b'2J' + b'after clear'
                                 + E + b'44m' + E + b'2J' + E + b'0m' + b'blue clear' + E + b'J' + E + b'0J' + E + b'2K')]),
    ('save and restore cursor', [('w', E + b'8;8Hsaved' + E + b's' + E + b'20;1Hmoved' + E + b'u' + b'back' + E + b'u' + E + b'u')]),
    ('wrap off and on', [('w', E + b'=7l' + b'N' * 100 + b'\r\n' + E + b'=7h' + b'W' * 100 + E + b'?7l' + b'Q' * 90 + E + b'7h')]),
    ('bad and partial sequences', [('w', b'\x1bX' + b'\x1b[' + b'Q' + b'\x1b[12;' + b'Z' + b'\x1b[?7h' + b'\x1b[' + b'"quoted"' + b'm text'
                                    + b'\x1b[=h' + b'\x1b[' + b'1' * 40 + b'm long' + b'\x1b' + b'\x1b[2' + b'\x1b[3m' + b'end')]),
    ('many parameters', [('w', E + b';'.join(b'%d' % (i % 50) for i in range(80)) + b'mX' + E + b'0m')]),
    ('device status report', [('w', E + b'7;33H' + E + b'6n'), ('r', 8), ('w', E + b'25;80H' + E + b'6n'), ('r', 8)]),
    ('key reassignment: a key to a string', [('w', E + b'65;"hello"p'), ('k', [0x1E41]), ('r', 5), ('k', [0x3062]), ('r', 1)]),
    ('key reassignment: a string to a string', [('w', E + b'"ab";"XY"p'), ('k', [0x1E61, 0x3062]), ('r', 3)]),
    ('key reassignment: F1 and redefine', [('w', E + b'0;59;"dir";13p'), ('k', [0x3B00]), ('r', 4), ('w', E + b'0;59;"cls"p'),
                                           ('k', [0x3B00]), ('r', 3), ('w', E + b'0;59;0;59p'), ('k', [0x3B00]), ('r', 2)]),
    ('key reassignment: grey arrow vs keypad arrow', [('w', E + b'224;72;"grey"p'), ('k', [0x48E0]), ('r', 4), ('k', [0x4800]), ('r', 2)]),
    ('extended keys: F11, grey keys', [('k', [0x8500, 0x48E0, 0x53E0, 0x1C0D, 0xE00D]), ('r', 9)]),
    ('many reassignments', [('w', b''.join(E + b'%d;"%s"p' % (65 + i, (b'x' * (i % 20 + 1))) for i in range(26))),
                            ('k', [0x1E41 + i for i in range(5)]), ('r', 15)]),
    ('non-destructive read and flush', [('nd',), ('k', [0x1E41, 0x3062]), ('nd',), ('r', 1), ('fl',), ('nd',)]),
    ('mono text and scrolling', [('m', 7), ('w', E + b'1mbright ' + E + b'0m' + E + b'4munder' + E + b'0m' + long_text(30) + E + b'10;10Hmono')]),
    ('40 columns', [('m', 1), ('w', b'Q' * 100 + b'\r\n' + long_text(30) + E + b'5;35Hforty' + E + b'40C|')]),
    ('50 rows set behind the driver', [('rows', 49), ('w', long_text(60) + E + b'45;10Hfifty' + E + b'99B*')]),
    ('page 1 active', [('page', 1), ('w', b'on page one\r\n' + long_text(30) + E + b'5;5Hp1' + E + b'2J' + b'x')]),
    ('graphics mode 13h', [('m', 0x13), ('w', b'graphics text\r\n' + E + b'1;34mblue' + E + b'0m' + E + b'3;3Hat 3,3' + long_text(30))]),
    ('graphics mode 12h, 30 rows', [('m', 0x12), ('w', long_text(35) + E + b'2J' + b'x')]),
    ('set mode by escape', [('w', E + b'=1h' + b'forty' + E + b'=3h' + b'eighty' + E + b'=13h' + b'graph' + E + b'=3h' + b'back'
                             + E + b'=0l' + b'x' + E + b'=2h' + b'bw80')]),
    ('program sets a mode through INT 10h', [('w', b'before'), ('i10', 0x0013), ('w', b'in 13h\r\n'), ('i10', 0x0003), ('w', b'after')]),
    ('program sets cursor shapes', [('i10', 0x0100, 0, 0x0607), ('i10', 0x0100, 0, 0x2000), ('i10', 0x0100, 0, 0x0B0D)]),
    ('IOCTL get', [('ioctl', 0x7F, pkt()), ('ioctl', 0x7F, pkt(level=1)), ('ioctl', 0x7F, pkt(length_field=13)), ('ioctl', 0x7F, pkt(length_field=40))]),
    ('IOCTL set 43, 50, 25 rows', [('ioctl', 0x5F, pkt(rows=43)), ('w', long_text(60)), ('ioctl', 0x7F, pkt()),
                                   ('ioctl', 0x5F, pkt(rows=50)), ('w', long_text(60)), ('ioctl', 0x7F, pkt()),
                                   ('ioctl', 0x5F, pkt(rows=25)), ('w', long_text(30)), ('ioctl', 0x7F, pkt())]),
    ('IOCTL set: errors', [('ioctl', 0x5F, pkt(rows=30)), ('ioctl', 0x5F, pkt(flags=2)), ('ioctl', 0x5F, pkt(level=1)),
                           ('ioctl', 0x5F, pkt(length_field=15)), ('ioctl', 0x5F, pkt(cols=81)), ('ioctl', 0x5F, pkt(mode=3)),
                           ('ioctl', 0x5F, pkt(colors=3)), ('ioctl', 0x5F, pkt(reserved=1)), ('ioctl', 0x3F, pkt())]),
    ('IOCTL set: intensity, 40 columns, graphics', [('ioctl', 0x5F, pkt(flags=1)), ('ioctl', 0x7F, pkt()), ('ioctl', 0x5F, pkt(flags=0)),
                                                    ('ioctl', 0x5F, pkt(cols=40)), ('w', b'forty'), ('ioctl', 0x7F, pkt()),
                                                    ('ioctl', 0x5F, pkt(mode=2, colors=256, width=320, length=200, cols=40, rows=25)),
                                                    ('w', b'graphics'), ('ioctl', 0x7F, pkt()),
                                                    ('ioctl', 0x5F, pkt(mode=2, colors=2, width=640, length=200, cols=80, rows=25)), ('ioctl', 0x7F, pkt())]),
    ('IOCTL 50 rows then a program mode set', [('ioctl', 0x5F, pkt(rows=50)), ('i10', 0x0003), ('w', long_text(40)), ('ioctl', 0x7F, pkt())]),
    ('INT 2Fh', [('i2f', 0x1A00, 0), ('i2f', 0x1A01, 0x7F, pkt()), ('i2f', 0x1A01, 0x5F, pkt(rows=43)), ('i2f', 0x1A01, 0x7F, pkt()),
                 ('i2f', 0x1A01, 0x3F, pkt()), ('i2f', 0x1A02, 0, b'\x00\x01' + bytes(10)), ('i10', 0x0003),
                 ('i2f', 0x1A02, 0, b'\x00\x00' + bytes(10)), ('i2f', 0x1A02, 0, b'\x01\x00\x55' + bytes(9)), ('i2f', 0x1A03, 0),
                 ('i2f', 0x1B00, 0)]),
]

SWITCHES = [b'', b' /X', b' /K', b' /R', b' /S', b' /X /R', b' /L', b' /S /K']


def run_scenario(path, dosver, steps, via, config='vga', cmdline=b'ANSI.SYS', no186=False, count=False):
    pc = PC(open(path, 'rb').read(), dosver, cmdline=cmdline, config=config, no186=no186, count=count)
    got = []
    written = 0
    for st in steps:
        op, args = st[0], st[1:]
        if op == 'w':
            pc.write(args[0], via); written += len(args[0])
        elif op == 'm': pc.set_mode(args[0])
        elif op == 'rows': pc.w8(0x484, args[0])
        elif op == 'page': pc.w8(0x462, args[0]); pc.w16(0x44E, args[0] * pc.r16(0x44C))
        elif op == 'k': pc.keys += args[0]
        elif op == 'r':
            r = pc.request(4, b'\0' * args[0], count=args[0])
            got.append(('r', bytes(pc.uc.mem_read(BUF, args[0])), struct.unpack_from('<H', r, 3)[0]))
        elif op == 'nd':
            r = pc.request(5); got.append(('nd', struct.unpack_from('<H', r, 3)[0], r[13]))
        elif op == 'fl':
            r = pc.request(7); got.append(('fl', struct.unpack_from('<H', r, 3)[0], len(pc.keys)))
        elif op == 'i10':
            ax = args[0]; bx = args[1] if len(args) > 1 else 0; cx = args[2] if len(args) > 2 else 0
            res = pc.callint(0x10, ax=ax, bx=bx, cx=cx)
            got.append(('i10', res['ax'] if (ax >> 8) == 0x0F else None, pc.r16(0x460)))
        elif op == 'ioctl':
            minor, packet = args
            pc.uc.mem_write(PKT, packet)
            hdr = {13: 3, 14: minor, 19: PKT & 0xFF, 20: PKT >> 8, 21: 0, 22: 0}
            r = pc.request(0x13, hdr=hdr)
            got.append(('ioctl', struct.unpack_from('<H', r, 3)[0], bytes(pc.uc.mem_read(PKT, 18))))
        elif op == 'i2f':
            ax, cx = args[0], args[1]
            packet = args[2] if len(args) > 2 else bytes(18)
            pc.uc.mem_write(PKT, packet)
            res = pc.callint(0x2F, ax=ax, cx=cx, dx=PKT, ds=0)
            got.append(('i2f', res['ax'], res['cf'], bytes(pc.uc.mem_read(PKT, 18))))
    snap = pc.snapshot()
    snap['results'] = got
    snap['icount'] = pc.icount
    snap['written'] = written
    return pc, snap


KEYS = ('screen', 'cur', 'crtc', 'beeps', 'results', 'mode', 'rows', 'shape', 'equip', 'cemu')


def describe(path):
    if '@' in path:
        p, v = path.rsplit('@', 1)
        maj, mnr = v.split('.')
        return p, (int(maj), int(mnr))
    return path, (6, 22)


def first_diff(a, b, cols):
    if not isinstance(a, bytes) or len(a) != len(b):
        return 'sizes %d / %d' % (len(a), len(b))
    for k in range(len(a)):
        if a[k] != b[k]:
            return 'row %d col %d %s: %02X vs %02X' % (k // 2 // cols, k // 2 % cols, 'attr' if k % 2 else 'char', a[k], b[k])
    return '?'


def main():
    args = sys.argv[1:]
    count = '--count' in args
    quick = '--quick' in args
    args = [a for a in args if not a.startswith('--')]
    drivers = [describe(a) for a in args]
    ref = drivers[0]
    tests = []
    for p, v in drivers[1:]:
        tests.append((p, v, False))
        try:
            if b'SC_NO186' in open(p, 'rb').read(): tests.append((p, v, True))
        except OSError:
            pass
    configs = ['vga'] if quick else list(CONFIGS)
    switches = [b''] if quick else SWITCHES
    total = diffs = errors = 0
    counts = {}
    for config in configs:
        for sw in switches:
            for name, steps in SCENARIOS:
                for via in ('req', 'int29'):
                    try:
                        _, base = run_scenario(ref[0], ref[1], steps, via, config, b'ANSI.SYS' + sw, count=count)
                    except Exception as e:
                        base = None; berr = str(e)
                    for p, v, n186 in tests:
                        total += 1
                        tag = '%s%s' % (p.split('/')[-1].split('\\')[-1], ' 8086' if n186 else '')
                        try:
                            pc, snap = run_scenario(p, v, steps, via, config, b'ANSI.SYS' + sw, no186=n186, count=count)
                            err = None
                        except Exception as e:
                            snap = None; err = str(e)
                        if base is None or snap is None:
                            if (base is None) != (snap is None) or (base is None and berr != err):
                                errors += 1
                                print('ERROR %-8s %-9s %-44s %-5s %s: ref %s / test %s' % (config, sw.decode().strip() or '-', name, via, tag,
                                      'ok' if base else berr, 'ok' if snap else err))
                            continue
                        d = [k for k in KEYS if snap[k] != base[k]]
                        if d:
                            diffs += 1
                            print('DIFF  %-8s %-9s %-44s %-5s %s: %s' % (config, sw.decode().strip() or '-', name, via, tag, ','.join(d)))
                            if 'screen' in d:
                                print('        screen: ' + first_diff(base['screen'], snap['screen'], pc.cols()))
                            for k in d:
                                if k != 'screen':
                                    print('        %s: %r\n            vs %r' % (k, base[k], snap[k]))
                        if count and snap['written']:
                            c = counts.setdefault(tag, [0, 0, 0])
                            c[0] += base['icount']; c[1] += snap['icount']; c[2] += snap['written']
    print('--- %d comparisons, %d differences, %d errors ---' % (total, diffs, errors))
    for tag, (ib, it, w) in counts.items():
        print('instructions per character written: reference %.1f, %s %.1f' % (ib / w, tag, it / w))


if __name__ == '__main__':
    main()
