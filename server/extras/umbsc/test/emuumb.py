"""emuumb.py -- run a UMB manager (USE!UMBS.SYS, UMBSC.SYS, PMUMB.SYS) in an
8086 emulator the way DOS runs it at boot, and report what DOS would get.
StevenC & Claude, 2026.  Public domain (the Unlicense).

    python emuumb.py DRIVER.SYS [more.SYS ...]

For each driver, four boots:

  plain     no XMS driver before it -- the V30's case
  chain     an XMS driver without UMBs already loaded: the new one must
            serve UMBs and pass everything else on
  managed   an XMS driver WITH UMBs already loaded: it must not install,
            and must leave INT 2Fh alone
  badline   a command line it cannot parse: likewise

In each it reports what the INIT call returned -- status, attribute word,
units and break address, i.e. how much conventional memory DOS keeps --
then does what MS-DOS SYSINIT does for DOS=UMB: finds the entry point
through INT 2Fh 4300h/4310h and asks for the largest block until none is
left, writing an MCB at the start of each block it is given.  Then it
calls the entry point again, so a resident part that DOS overwrote would
show.  Nothing here is timing: it is whether DOS would get the same
blocks, and how much low memory it costs.
"""
import struct, sys
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR
from unicorn.x86_const import *

LOADSEG = 0x0B00          # where DOS would load a CONFIG.SYS driver
STUB = 0x0500
REQ = 0x0700
CMDL = 0x0740
IRETSTUB = 0x0600         # the INT 2Fh vector before anything hooks it
FAKE2F = 0x0800           # a fake XMS driver's INT 2Fh handler
FAKEXMS = 0x0840          # ...and its entry point


class Boot:
    def __init__(self, image, cmdline, xms=None):
        self.out = []
        uc = self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        uc.mem_map(0, 0x100000)
        uc.mem_write(LOADSEG * 16, image)
        uc.mem_write(IRETSTUB, b'\xcf')
        uc.mem_write(0x2F * 4, struct.pack('<HH', IRETSTUB, 0))
        if xms:
            # fake XMS: INT 2Fh 4300h -> AL=80h, 4310h -> ES:BX = FAKEXMS
            h = (b'\x80\xfc\x43\x75\x13'            # cmp ah,43h ; jne iret
                 b'\x3c\x00\x75\x03\xb0\x80\xcf'     # cmp al,0 ; jne +3 ; mov al,80h ; iret
                 b'\x3c\x10\x75\x07'                 # cmp al,10h ; jne iret
                 b'\xbb' + struct.pack('<H', FAKEXMS) +  # mov bx,FAKEXMS
                 b'\x31\xc0\x8e\xc0'                 # xor ax,ax ; mov es,ax
                 b'\xcf')                             # iret
            uc.mem_write(FAKE2F, h)
            uc.mem_write(0x2F * 4, struct.pack('<HH', FAKE2F, 0))
            if xms == 'noumb':
                # AH=10h -> AX=0 BL=80h ; else AX=0300h BX=1234h DX=0001h
                e = (b'\xeb\x03\x90\x90\x90'
                     b'\x80\xfc\x10\x75\x05\x31\xc0\xb3\x80\xcb'
                     b'\xb8\x00\x03\xbb\x34\x12\xba\x01\x00\xcb')
            else:
                # UMBs managed: AH=10h -> AX=0 BL=B1h DX=0
                e = (b'\xeb\x03\x90\x90\x90'
                     b'\x31\xc0\xb3\xb1\x31\xd2\xcb')
            uc.mem_write(FAKEXMS, e)
        uc.hook_add(UC_HOOK_INTR, self._intr)
        self.vec2f_before = self.vec(0x2F)
        self.init(cmdline)

    def vec(self, n):
        return struct.unpack('<HH', bytes(self.uc.mem_read(n * 4, 4)))

    def _intr(self, uc, n, ud):
        ip = uc.reg_read(UC_X86_REG_IP); cs = uc.reg_read(UC_X86_REG_CS)
        ax = uc.reg_read(UC_X86_REG_AX)
        if n == 0x2F:
            fl = uc.reg_read(UC_X86_REG_FLAGS)
            sp = uc.reg_read(UC_X86_REG_SP) - 6; ss = uc.reg_read(UC_X86_REG_SS)
            uc.mem_write(ss * 16 + sp, struct.pack('<HHH', ip, cs, fl))
            uc.reg_write(UC_X86_REG_SP, sp)
            uc.reg_write(UC_X86_REG_FLAGS, fl & ~0x0300)
            off, seg = self.vec(0x2F)
            uc.reg_write(UC_X86_REG_CS, seg); uc.reg_write(UC_X86_REG_IP, off)
            return
        if n == 0x21 and ax >> 8 == 9:
            ds = uc.reg_read(UC_X86_REG_DS); dx = uc.reg_read(UC_X86_REG_DX)
            m = bytes(uc.mem_read(ds * 16 + dx, 600))
            self.out.append(m[:m.index(b'$')].decode('latin1'))
        elif n == 0x21 and ax >> 8 == 0x35:
            off, seg = self.vec(ax & 0xFF)
            uc.reg_write(UC_X86_REG_BX, off); uc.reg_write(UC_X86_REG_ES, seg)
        elif n == 0x21 and ax >> 8 == 0x25:
            uc.mem_write((ax & 0xFF) * 4, struct.pack('<HH', uc.reg_read(UC_X86_REG_DX), uc.reg_read(UC_X86_REG_DS)))
        elif n == 0x13 and ax == 0x6000:
            uc.reg_write(UC_X86_REG_DX, 0xAA55)
        elif n == 0x13 and ax == 0x6002:
            uc.reg_write(UC_X86_REG_BX, 0x0300)
        else:
            raise RuntimeError('unexpected INT %02Xh AX=%04X at %04X:%04X' % (n, ax, cs, ip))

    def run(self, seg, off, stop):
        self.uc.reg_write(UC_X86_REG_CS, seg); self.uc.reg_write(UC_X86_REG_IP, off)
        self.uc.emu_start(seg * 16 + off, stop, count=5_000_000)
        at = self.uc.reg_read(UC_X86_REG_CS) * 16 + self.uc.reg_read(UC_X86_REG_IP)
        if at != stop:
            raise RuntimeError('did not come back: %05X' % at)

    def regs(self, **r):
        for k, v in r.items():
            self.uc.reg_write(getattr(__import__('unicorn.x86_const', fromlist=['x']), 'UC_X86_REG_' + k.upper()), v)
        self.uc.reg_write(UC_X86_REG_SS, 0x9000); self.uc.reg_write(UC_X86_REG_SP, 0xFFF0)

    def init(self, cmdline):
        uc = self.uc
        base = LOADSEG * 16
        strat, intr = struct.unpack('<HH', bytes(uc.mem_read(base + 6, 4)))
        uc.mem_write(CMDL, cmdline + b'\r\n')
        req = bytearray(26); req[0] = 26
        struct.pack_into('<HH', req, 18, CMDL, 0)
        uc.mem_write(REQ, bytes(req))
        stub = b'\x9a' + struct.pack('<HH', strat, LOADSEG) + b'\x9a' + struct.pack('<HH', intr, LOADSEG) + b'\xf4'
        uc.mem_write(STUB, stub)
        self.regs(es=0, bx=REQ, ds=0)
        self.run(0, STUB, STUB + 10)
        r = bytes(uc.mem_read(REQ, 26))
        self.status, = struct.unpack_from('<H', r, 3)
        self.units = r[13]
        bo, bs = struct.unpack_from('<HH', r, 14)
        self.attr, = struct.unpack('<H', bytes(uc.mem_read(base + 4, 2)))
        self.brk = (bs * 16 + bo) - base
        # what DOS keeps: nothing if it is erased (block device, 0 units)
        if not (self.attr & 0x8000) and self.units == 0:
            self.kept = 0
        else:
            self.kept = (self.brk + 15) // 16 * 16

    def call2f(self, ax):
        self.uc.mem_write(STUB + 0x20, b'\xcd\x2f\xf4')
        self.regs(ax=ax, bx=0, es=0)
        self.run(0, STUB + 0x20, STUB + 0x22)
        return (self.uc.reg_read(UC_X86_REG_AX), self.uc.reg_read(UC_X86_REG_ES), self.uc.reg_read(UC_X86_REG_BX))

    def xms(self, entry, ax, dx=0, bx=0):
        seg, off = entry
        self.uc.mem_write(STUB + 0x30, b'\x9a' + struct.pack('<HH', off, seg) + b'\xf4')
        self.regs(ax=ax, dx=dx, bx=bx)
        self.run(0, STUB + 0x30, STUB + 0x35)
        g = lambda r: self.uc.reg_read(r)
        return g(UC_X86_REG_AX), g(UC_X86_REG_BX), g(UC_X86_REG_DX)


def load(p):
    return open(p, 'rb').read()


def trial(path, name, cmdline=b'C:\\DRIVERS\\X.SYS C800-D000 D800-E000', xms=None):
    b = Boot(load(path), cmdline, xms)
    L = ['[%s]' % name]
    L += ['  | ' + s.replace('\r', '').replace('\n', ' / ').strip(' /') for s in b.out if s.strip()]
    L.append('  init: status %04X attr %04X units %d  conventional kept: %d bytes'
             % (b.status, b.attr, b.units, b.kept))
    v = b.vec(0x2F)
    L.append('  INT 2Fh %s' % ('unchanged' if v == b.vec2f_before else 'hooked -> %04X:%04X' % (v[1], v[0])))
    ax, es, bx = b.call2f(0x4300)
    L.append('  4300h -> AL=%02X' % (ax & 0xFF))
    if (ax & 0xFF) != 0x80:
        return L
    ax, es, bx = b.call2f(0x4310)
    entry = (es, bx)
    # DOS=UMB: largest first, until nothing is left
    got = []
    for _ in range(20):
        ax, bx, dx = b.xms(entry, 0x1000, dx=0xFFFF)
        if ax != 0:
            L.append('  !! 10h FFFFh succeeded'); break
        if dx == 0 or (bx & 0xFF) == 0xB1:
            L.append('  10h FFFFh -> BL=%02X DX=%04X: done' % (bx & 0xFF, dx)); break
        ax2, bx2, dx2 = b.xms(entry, 0x1000, dx=dx)
        L.append('  10h FFFFh -> BL=%02X largest %04X;  10h %04X -> AX=%d seg %04X size %04X'
                 % (bx & 0xFF, dx, dx, ax2, bx2, dx2))
        if ax2 != 1:
            break
        got.append((bx2, dx2))
        b.uc.mem_write(bx2 * 16, b'M' + b'\x00' * 15)       # DOS writes an MCB there
    # blocks must lie inside the ranges asked for, not overlap each other
    # or whatever the driver left resident in upper memory
    home = v[1] if v != b.vec2f_before and v[1] >= 0xA000 else None
    for s, n in got:
        inside = (0xC800 <= s and s + n <= 0xD000) or (0xD800 <= s and s + n <= 0xE000)
        clash = home is not None and s <= home < s + n
        if not inside or clash:
            L.append('  !! block %04X+%04X %s' % (s, n, 'outside the ranges' if not inside else 'overlaps the resident part'))
    L.append('  UMB total given to DOS: %d bytes' % (sum(n for s, n in got) * 16))
    # after DOS has written into its blocks, the entry point must still work
    for f, nm in ((0x0000, 'version'), (0x0800, 'query ext'), (0x1100, 'release'), (0x1000, 'again')):
        ax, bx, dx = b.xms(entry, f, dx=0xFFFF if f == 0x1000 else 0)
        L.append('  after: %-9s AH=%02Xh -> AX=%04X BL=%02X DX=%04X' % (nm, f >> 8, ax, bx & 0xFF, dx))
    ax, es, bx = b.call2f(0x4300)
    L.append('  after: 4300h -> AL=%02X' % (ax & 0xFF))
    ax, es, bx = b.call2f(0x1600)
    L.append('  other INT 2Fh passed on: %s' % ('yes' if (ax & 0xFF) == 0 else 'AL=%02X' % (ax & 0xFF)))
    return L


if __name__ == '__main__':
    for p in sys.argv[1:]:
        print('=== %s ===' % p)
        for t in (('plain', {}), ('chain', {'xms': 'noumb'}), ('managed', {'xms': 'umb'}),
                  ('badline', {'cmdline': b'X.SYS C800-ZZZZ'})):
            try:
                print('\n'.join(trial(p, t[0], **t[1])))
            except Exception as e:
                print('[%s] EXCEPTION %s' % (t[0], e))
        print()
