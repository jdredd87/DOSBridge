"""emuxms.py -- XMSSC in an 8086 emulator, against a reference model.
StevenC & Claude, 2026.  Public domain (the Unlicense).

    python emuxms.py                 every configuration, directed + fuzz
    python emuxms.py --quick         fewer fuzz operations
    python emuxms.py --only NAME     one configuration (see CONFIGS)
    python emuxms.py -v              print every transcript line

The driver under test is the real binary (build\\XMSSC.SYS, or .COM for the
TSR configurations), initialised the way DOS does it and then called through
the entry point INT 2Fh 4310h hands out, exactly as a program would.

The PicoMEM's EMS hardware is modelled as four 16 KB windows at E000h whose
page registers are I/O ports 2A8h-2ABh that read back, as on the card.  The
EMS driver behind it is either

  pmemm     the real PMEMMSC binary (C:\\CH375USB\\PicoMEM\\emm\\bin\\PMEMM.SYS,
            or $PMEMM), initialised and called through INT 67h, or
  model32 / model40
            an EMS 3.2 or 4.0 driver written here in Python, which hands out
            its pages in SHUFFLED order and moves them around on a
            reallocate -- so an XMS driver that assumed a block's pages were
            consecutive, or kept a stale map, would read the wrong memory.

Every XMS call is checked for: the answer the spec requires, the registers
it must not change, the direction flag, the interrupt flag, and the EMS
state -- the four page registers, and the EMS driver's own saved map --
exactly as it was.  Every block's contents are checked against a reference
copy by reading them through the EMS driver (INT 67h / the model), never
through XMSSC's own code.

What this proves and what it does not: it runs the driver's instructions,
so a wrong byte, a clobbered register or a window left borrowed shows up
here as it would on the machine.  It says nothing about speed or the
card's timing -- XMSTEST on the hardware does that.  Unicorn is a 386-class
core: /C:0 makes XMSSC take its 8086 paths, /C:3 its 386 ones.
"""
import ctypes, os, random, struct, sys, zlib
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN, UcError
from unicorn.x86_const import *

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, '..', 'build')
PMEMM = os.environ.get('PMEMM', r'C:\CH375USB\PicoMEM\emm\bin\PMEMM.SYS')
UMBSC = os.path.join(HERE, '..', '..', 'umbsc', 'bin', 'UMBSC.SYS')

FRAME = 0xE000
PORT = 0x2A8
PAGES = 256                 # card store pages; 0FFh = "disabled", its own page
ROMSEG = 0xF000             # IRET for every vector nobody set
EMSDEV = 0xF100             # the model EMS driver's device name lives here
STUB = 0x0600
REQ = 0x0700
CMDL = 0x0740
EMSSEG = 0x1000             # PMEMMSC
UMBSEG = 0x2000             # UMBSC
XSEG = 0x3000               # XMSSC (.SYS image, or the .COM's PSP)
X2SEG = 0x3200              # a second .COM, for /U
STACKSEG = 0x4000
DATA = 0x5000               # move structure, scratch
CONV = 0x60000              # conventional buffers, 0x60000-0x9FFFF
CONVEND = 0xA0000

R16 = dict(ax=UC_X86_REG_AX, bx=UC_X86_REG_BX, cx=UC_X86_REG_CX, dx=UC_X86_REG_DX,
           si=UC_X86_REG_SI, di=UC_X86_REG_DI, bp=UC_X86_REG_BP, ds=UC_X86_REG_DS,
           es=UC_X86_REG_ES)


class Exit(Exception):
    pass


class EmsModel:
    """An EMS driver in Python: shuffled pages, 3.2 or 4.0."""

    def __init__(self, m, version, npages=192, nhandles=24, seed=1):
        self.m, self.version = m, version
        self.rng = random.Random(seed)
        self.npages = npages
        self.free = list(range(npages))
        self.rng.shuffle(self.free)
        self.h = {}                     # handle -> [global pages]
        self.nhandles = nhandles
        self.calls = 0

    def int67(self):
        m = self.m
        self.calls += 1
        ax = m.r('ax'); ah, al = ax >> 8, ax & 0xFF
        bx, dx = m.r('bx'), m.r('dx')

        def ret(status, **kw):
            m.w('ax', (status << 8) | kw.pop('al', al))
            for k, v in kw.items():
                m.w(k, v)
        if ah == 0x40:
            return ret(0)
        if ah == 0x41:
            return ret(0, bx=FRAME)
        if ah == 0x42:
            return ret(0, bx=len(self.free), dx=self.npages)
        if ah == 0x43:
            if bx == 0:
                return ret(0x89)
            if bx > self.npages:
                return ret(0x87)
            if bx > len(self.free):
                return ret(0x88)
            if len(self.h) >= self.nhandles:
                return ret(0x85)
            hd = next(i for i in range(1, 256) if i not in self.h)
            self.h[hd] = [self.free.pop() for _ in range(bx)]
            return ret(0, dx=hd)
        if ah == 0x44:
            if al > 3:
                return ret(0x8B)
            if dx not in self.h:
                return ret(0x83)
            if bx == 0xFFFF:
                m.card_out(PORT + al, 0xFF)
                return ret(0)
            if bx >= len(self.h[dx]):
                return ret(0x8A)
            m.card_out(PORT + al, self.h[dx][bx])
            return ret(0)
        if ah == 0x45:
            if dx not in self.h:
                return ret(0x83)
            pg = self.h.pop(dx)
            self.free += pg
            self.rng.shuffle(self.free)
            return ret(0)
        if ah == 0x46:
            return ret(0, al=self.version)
        if ah == 0x4C:
            if dx not in self.h:
                return ret(0x83)
            return ret(0, bx=len(self.h[dx]))
        if ah == 0x4E:
            if al == 3:
                return ret(0, al=8)
            if al in (0, 2):
                es, di = m.r('es'), m.r('di')
                m.wr(es, di, b''.join(struct.pack('<H', v) for v in m.bank))
            if al in (1, 2):
                ds, si = m.r('ds'), m.r('si')
                regs = struct.unpack('<4H', m.rd(ds, si, 8))
                if any(v > 0xFF for v in regs):
                    return ret(0xA3)
                for w, v in enumerate(regs):
                    m.card_out(PORT + w, v)
            if al > 3:
                return ret(0x8F)
            return ret(0)
        if ah == 0x57 and al == 0 and self.version >= 0x40:
            # move memory region: an EMS 4.0 move, memmove semantics
            ds, si = m.r('ds'), m.r('si')
            n, st, sh, so, ss_, dt, dh, do, ds_ = struct.unpack('<IBHHHBHHH', m.rd(ds, si, 18))
            self.moves = getattr(self, 'moves', 0) + 1
            if n > 0x100000:
                return ret(0x96)

            def region(t, h, off, sp):
                if t == 0:
                    return ('c', sp * 16 + off)
                if h not in self.h:
                    raise KeyError(0x83)
                if off >= 0x4000:
                    raise KeyError(0x95)
                if sp + ((off + n - 1) >> 14 if n else 0) >= len(self.h[h]):
                    raise KeyError(0x93 if sp < len(self.h[h]) else 0x8A)
                return ('e', h, sp, off)

            def read(r):
                if r[0] == 'c':
                    return m.rdl(r[1], n)
                _, h, p, off = r
                out = bytearray()
                while len(out) < n:
                    out += m.store_page(self.h[h][p])[off:]
                    p, off = p + 1, 0
                return bytes(out[:n])

            def write(r, data):
                if r[0] == 'c':
                    return m.wrl(r[1], data)
                _, h, p, off = r
                i = 0
                while i < n:
                    pg = bytearray(m.store_page(self.h[h][p]))
                    k = min(0x4000 - off, n - i)
                    pg[off:off + k] = data[i:i + k]
                    m.store_page(self.h[h][p], pg)
                    i, p, off = i + k, p + 1, 0
            try:
                src, dst = region(st, sh, so, ss_), region(dt, dh, do, ds_)
            except KeyError as e:
                return ret(e.args[0])
            write(dst, read(src))
            return ret(0)
        if ah == 0x51 and self.version >= 0x40:
            if dx not in self.h:
                return ret(0x83)
            cur = self.h[dx]
            if bx > len(cur):
                need = bx - len(cur)
                if need > len(self.free):
                    return ret(0x88)
                cur += [self.free.pop() for _ in range(need)]
            else:
                self.free += cur[bx:]
                del cur[bx:]
            # a real driver may renumber: move one page's contents to a
            # fresh global page, so a stale map would read the wrong place
            if cur and self.free:
                i = self.rng.randrange(len(cur))
                new = self.free.pop()
                m.store_page(new, m.store_page(cur[i]))
                m.store_page(cur[i], bytes([0xDD]) * 16384)
                self.free.append(cur[i])
                cur[i] = new
            return ret(0, bx=len(cur))
        return ret(0x84)

    def read_page(self, hd, lp):
        return self.m.store_page(self.h[hd][lp])


class Machine:
    def __init__(self, ems='pmemm', seed=1, umb=True):
        self.out = []
        self.store = (ctypes.c_ubyte * ((PAGES + 1) * 16384))()
        self.bank = [0xFF] * 4
        self.exit = None
        uc = self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        uc.mem_map(0, 0xE0000)
        for w in range(4):
            self._map_window(w, 0xFF)
        uc.mem_map(0xF0000, 0x10000)
        uc.mem_map(0x100000, 0x10000)            # above 1 MB: A20 "on" on a 386
        uc.mem_write(ROMSEG * 16, b'\xcf')       # IRET
        uc.mem_write(EMSDEV * 16 + 10, b'EMMXXXX0')
        for v in range(256):
            uc.mem_write(v * 4, struct.pack('<HH', 0, ROMSEG))
        self.store_page(0xFF, b'\xff' * 16384)
        uc.hook_add(UC_HOOK_INTR, self._intr)
        uc.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)
        uc.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        self.model = None
        self.umb = None
        if umb:     # first, as in the V30's CONFIG.SYS
            self.umb = self.load_driver(UMBSEG, open(UMBSC, 'rb').read(), b'UMBSC.SYS C800-D000')
        if ems == 'pmemm':
            self.load_driver(EMSSEG, open(PMEMM, 'rb').read(), b'PMEMM.SYS /n')
        else:
            self.model = EmsModel(self, 0x32 if ems == 'model32' else 0x40, seed=seed)
            uc.mem_write(0x67 * 4, struct.pack('<HH', 0, EMSDEV))

    # ---- the card
    def _map_window(self, w, page):
        base = FRAME * 16 + w * 16384
        try:
            self.uc.mem_unmap(base, 16384)
        except UcError:
            pass
        idx = PAGES if page == 0xFF else page
        self.uc.mem_map_ptr(base, 16384, 3, ctypes.addressof(self.store) + idx * 16384)
        self.bank[w] = page

    def card_out(self, port, value):
        self._map_window(port - PORT, value & 0xFF)

    def store_page(self, page, data=None):
        idx = PAGES if page == 0xFF else page
        off = idx * 16384
        if data is None:
            return bytes(self.store[off:off + 16384])
        ctypes.memmove(ctypes.addressof(self.store) + off, bytes(data), 16384)

    def _out(self, uc, port, size, value, ud):
        if PORT <= port < PORT + 4:
            self.card_out(port, value)

    def _in(self, uc, port, size, ud):
        if PORT <= port < PORT + 4:
            return self.bank[port - PORT]
        return 0 if port == 0x61 else 0xFF

    # ---- registers and memory
    def r(self, k):
        return self.uc.reg_read(R16[k] if k in R16 else getattr(sys.modules[__name__], 'UC_X86_REG_' + k.upper()))

    def w(self, k, v):
        self.uc.reg_write(R16[k] if k in R16 else getattr(sys.modules[__name__], 'UC_X86_REG_' + k.upper()), v)

    def rd(self, seg, off, n):
        return bytes(self.uc.mem_read(seg * 16 + off, n))

    def wr(self, seg, off, data):
        self.uc.mem_write(seg * 16 + off, bytes(data))

    def code(self, lin, data):
        """write code, and throw away Unicorn's cached translation of those
        bytes -- a stub rewritten in place otherwise runs as it was"""
        self.uc.mem_write(lin, bytes(data))
        self.uc.ctl_remove_cache(lin, lin + len(data))

    def rdl(self, lin, n):
        return bytes(self.uc.mem_read(lin, n))

    def wrl(self, lin, data):
        self.uc.mem_write(lin, bytes(data))

    # ---- interrupts
    def _push_int(self, intno):
        uc = self.uc
        ip, cs = uc.reg_read(UC_X86_REG_IP), uc.reg_read(UC_X86_REG_CS)
        fl = uc.reg_read(UC_X86_REG_FLAGS)
        sp = (uc.reg_read(UC_X86_REG_SP) - 6) & 0xFFFF
        ss = uc.reg_read(UC_X86_REG_SS)
        uc.mem_write(ss * 16 + sp, struct.pack('<HHH', ip, cs, fl))
        uc.reg_write(UC_X86_REG_SP, sp)
        uc.reg_write(UC_X86_REG_FLAGS, fl & ~0x0300)
        off, seg = struct.unpack('<HH', self.rd(0, intno * 4, 4))
        uc.reg_write(UC_X86_REG_CS, seg)
        uc.reg_write(UC_X86_REG_IP, off)

    def _intr(self, uc, intno, ud):
        ax = self.r('ax')
        ah = ax >> 8
        if intno == 0x67 and self.model:
            self.model.int67()
        elif intno in (0x67, 0x2F):
            self._push_int(intno)
        elif intno == 0x13 and ax in (0x6000, 0x6001):
            if ax == 0x6000:
                self.w('dx', 0xAA55)
            else:
                self.w('cx', PORT)
                self.w('dx', FRAME)
            # the PicoMEM BIOS hands back its own flags: interrupts off
            self.uc.reg_write(UC_X86_REG_FLAGS, self.uc.reg_read(UC_X86_REG_FLAGS) & ~0x200)
        elif intno == 0x21:
            self._dos(ah, ax)
        elif intno == 0x16:
            self.uc.reg_write(UC_X86_REG_FLAGS, self.uc.reg_read(UC_X86_REG_FLAGS) | 0x40)
        else:
            raise RuntimeError('unexpected INT %02Xh AX=%04X at %04X:%04X' % (intno, ax, self.r('cs'), self.uc.reg_read(UC_X86_REG_IP)))

    def _dos(self, ah, ax):
        if ah == 0x09:
            m = self.rd(self.r('ds'), self.r('dx'), 600)
            self.out.append(m[:m.index(b'$')].decode('latin1'))
        elif ah == 0x02:
            self.out.append(chr(self.r('dx') & 0xFF))
        elif ah == 0x35:
            off, seg = struct.unpack('<HH', self.rd(0, (ax & 0xFF) * 4, 4))
            self.w('bx', off)
            self.w('es', seg)
        elif ah == 0x25:
            self.wr(0, (ax & 0xFF) * 4, struct.pack('<HH', self.r('dx'), self.r('ds')))
        elif ah == 0x30:
            self.w('ax', 0x1606)
        elif ah == 0x49:
            self.freed = getattr(self, 'freed', []) + [self.r('es')]
            fl = self.uc.reg_read(UC_X86_REG_FLAGS) & ~1
            self.uc.reg_write(UC_X86_REG_FLAGS, fl)
        elif ah in (0x31, 0x4C):
            self.exit = (ah, ax & 0xFF, self.r('dx'))
            self.uc.emu_stop()
        else:
            raise RuntimeError('unexpected INT 21h AH=%02X' % ah)

    # ---- running code
    def run(self, cs, ip, stop_lin, limit=50_000_000):
        self.exit = None
        self.uc.reg_write(UC_X86_REG_CS, cs)
        self.uc.reg_write(UC_X86_REG_IP, ip)
        self.uc.emu_start(cs * 16 + ip, stop_lin, count=limit)
        if self.exit:
            return
        at = self.r('cs') * 16 + self.uc.reg_read(UC_X86_REG_IP)
        if at != stop_lin:
            raise RuntimeError('did not come back: stopped at %05X' % at)

    def load_driver(self, seg, image, cmdline):
        uc = self.uc
        self.code(seg * 16, image)
        strat, intr = struct.unpack_from('<HH', image, 6)
        uc.mem_write(CMDL, cmdline + b'\r\n')
        req = bytearray(26); req[0] = 26
        struct.pack_into('<HH', req, 18, CMDL, 0)
        uc.mem_write(REQ, bytes(req))
        stub = (b'\x9a' + struct.pack('<HH', strat, seg) + b'\x9a' +
                struct.pack('<HH', intr, seg) + b'\xf4')
        self.code(STUB, stub)
        self.w('ss', STACKSEG); self.w('sp', 0xFFF0)
        self.w('es', 0); self.w('bx', REQ); self.w('ds', 0)
        self.uc.reg_write(UC_X86_REG_FLAGS, 0x0202)
        self.run(0, STUB, STUB + 10)
        status, = struct.unpack_from('<H', self.rd(0, REQ + 3, 2))
        boff, bseg = struct.unpack_from('<HH', self.rd(0, REQ + 14, 4))
        attr, = struct.unpack_from('<H', self.rd(seg, 4, 2))
        return status, (bseg - seg) * 16 + boff, attr, self.r('flags')

    def run_com(self, psp, image, tail):
        self.wr(psp, 0, b'\xcd\x20' + bytes(0xFE))
        self.wr(psp, 0x2C, struct.pack('<H', 0x2F00))
        t = tail.encode() if isinstance(tail, str) else tail
        self.wr(psp, 0x80, bytes([len(t)]) + t + b'\r')
        self.code(psp * 16 + 0x100, image)
        for k in ('ds', 'es', 'ss'):
            self.w(k, psp)
        self.w('sp', 0xFFFE)
        self.wr(psp, 0xFFFE, b'\0\0')
        self.uc.reg_write(UC_X86_REG_FLAGS, 0x0202)
        self.run(psp, 0x100, 0)
        return self.exit

    def intcall(self, intno, **r):
        for k, v in r.items():
            self.w(k, v)
        self.w('ss', STACKSEG); self.w('sp', 0xFFF0)
        self.code(STUB + 0x20, bytes([0xCD, intno, 0xF4]))
        self.run(0, STUB + 0x20, STUB + 0x22)

    def xms(self, ax, flags=0x0202, **r):
        """call the XMS entry; returns the registers afterwards"""
        uc = self.uc
        base = dict(bx=0x1111, cx=0x2222, dx=0x3333, si=0x4444, di=0x5555,
                    bp=0x6666, ds=0x7777, es=0x8888)
        base.update(r)
        for k, v in base.items():
            self.w(k, v)
        self.w('ax', ax)
        self.w('ss', STACKSEG); self.w('sp', 0xFFF0)
        uc.reg_write(UC_X86_REG_FLAGS, flags)
        self.code(STUB + 0x40, b'\x9a' + struct.pack('<HH', *self.entry) + b'\xf4')
        self.run(0, STUB + 0x40, STUB + 0x45)
        after = {k: self.r(k) for k in R16}
        after['ax'] = self.r('ax')
        after['sp'] = self.r('sp')
        after['flags'] = uc.reg_read(UC_X86_REG_FLAGS)
        after['in'] = base
        return after


# ---------------------------------------------------------------- the test
class Test:
    def __init__(self, name, ems, cpu, generic, com, seed, ops, verbose):
        self.name, self.ems, self.cpu, self.generic, self.com = name, ems, cpu, generic, com
        self.seed, self.ops, self.verbose = seed, ops, verbose
        self.lines, self.fails = [], 0
        self.rng = random.Random(seed)
        self.m = Machine(ems, seed)
        self.ref = {}                           # handle -> bytearray

    def T(self, s):
        self.lines.append(s)
        if self.verbose:
            print(s)

    def must(self, ok, what):
        if not ok:
            self.fails += 1
            self.T('  ** FAILED: ' + what)
        return ok

    # ---- loading
    def load(self, umb=True, extra=''):
        m = self.m
        if m.umb:
            self.T('UMBSC init %04X' % m.umb[0])
            self.must(m.umb[0] == 0x0100, 'UMBSC loaded')
        sw = '/C:%d%s%s' % (self.cpu, ' /G' if self.generic else '', extra)
        if self.com:
            img = open(os.path.join(BUILD, 'XMSSC.COM'), 'rb').read()
            ex = m.run_com(XSEG, img, ' ' + sw)
            self.T('COM exit %s' % (ex,))
            self.must(ex and ex[0] == 0x31, 'the TSR stayed resident')
            self.resident = ex[2] * 16 if ex else 0
        else:
            img = open(os.environ.get('XMSSC_SYS', os.path.join(BUILD, 'XMSSC.SYS')), 'rb').read()
            st, size, attr, fl = m.load_driver(XSEG, img, ('XMSSC.SYS ' + sw).encode())
            self.T('SYS init status %04X attr %04X' % (st, attr))
            self.must(fl & 0x200, 'init left interrupts on (the PicoMEM BIOS turns them off)')
            self.resident = size
        for s in ''.join(m.out).replace('\r', '').split('\n'):
            if s.strip():
                self.T('  | ' + s)
        m.out = []
        m.intcall(0x2F, ax=0x4300)
        self.T('2F 4300 -> AL=%02X' % (m.r('ax') & 0xFF))
        m.intcall(0x2F, ax=0x4310)
        m.entry = (m.r('bx'), m.r('es'))
        self.xseg = m.entry[1]
        self.T('2F 4310 -> entry at +%04X, resident %d bytes' % (m.entry[0], self.resident))
        self.must(m.rd(self.xseg, m.entry[0] - 8, 8) == b'XMSSC1.0', 'signature before the entry')

    # ---- a call, checked
    def x(self, ax, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'), flags=0x0202, **r):
        m = self.m
        regs0 = list(m.bank)
        map0 = self.emsmap()
        res = m.xms(ax, flags=flags, **r)
        ok = res['sp'] == 0xFFF0
        bad = [k for k in keep if res[k] != res['in'][k]]
        self.must(ok and not bad, 'fn %02X changed %s sp=%04X' % (ax >> 8, bad, res['sp']))
        self.must(not (res['flags'] & 0x400), 'fn %02X left DF set' % (ax >> 8))
        self.must((res['flags'] & 0x200) == (flags & 0x200), 'fn %02X changed IF' % (ax >> 8))
        bank = list(m.bank)
        if self.generic and not m.model:
            # EMS calls: PMEMMSC restores a window nobody mapped (FF) as
            # page 0 -- its own quirk, and its own map still says unmapped
            bank = [0xFF if (b == 0 and r0 == 0xFF) else b for b, r0 in zip(bank, regs0)]
        self.must(bank == regs0, 'fn %02X left the page registers %s (were %s)' % (ax >> 8, m.bank, regs0))
        self.must(self.emsmap() == map0, 'fn %02X changed the EMS driver\'s page map' % (ax >> 8))
        self.res = res
        return res

    def emsmap(self):
        """the EMS driver's own idea of the map (4Eh/00), without changing it"""
        m = self.m
        if m.model:
            return tuple(m.bank)
        save = [self.m.r(k) for k in R16]
        m.intcall(0x67, ax=0x4E00, es=DATA, di=0x0F00)
        mp = m.rd(DATA, 0x0F00, 28)
        for k, v in zip(R16, save):
            m.w(k, v)
        return mp

    def ok(self):
        return self.res['ax'] == 1

    def err(self):
        return 'AX=%d BL=%02X' % (self.res['ax'], self.res['bx'] & 0xFF)

    # ---- reading a block through EMS, independent of XMSSC
    def ems_handle(self, h):
        return struct.unpack('<H', self.m.rd(self.xseg, h + 4, 2))[0]

    def read_block(self, h, off=0, n=None):
        kb = struct.unpack('<H', self.m.rd(self.xseg, h + 2, 2))[0]
        if n is None:
            n = kb * 1024 - off
        eh = self.ems_handle(h)
        out = bytearray()
        p0, p1 = off >> 14, (off + n + 16383) >> 14
        m = self.m
        if m.model:
            for p in range(p0, p1):
                out += m.model.read_page(eh, p)
        else:
            regs = list(m.bank)
            m.intcall(0x67, ax=0x4E00, es=DATA, di=0x0E00)
            for p in range(p0, p1):
                m.intcall(0x67, ax=0x4403, bx=p, dx=eh)
                assert m.r('ax') >> 8 == 0, 'EMS map for reading failed'
                out += m.rd(FRAME + 0xC00, 0, 16384)
            m.intcall(0x67, ax=0x4E01, ds=DATA, si=0x0E00)
            for w, v in enumerate(regs):         # PMEMMSC restores never-mapped
                m.card_out(PORT + w, v)          # windows as page 0: undo that
        s = off - p0 * 16384
        return bytes(out[s:s + n])

    def check_block(self, h, what):
        got = self.read_block(h, 0, len(self.ref[h]))
        exp = bytes(self.ref[h])
        if got != exp:
            i = next(i for i in range(len(exp)) if got[i] != exp[i])
            return self.must(False, '%s: handle %04X byte %d is %02X, want %02X' % (what, h, i, got[i], exp[i]))
        return True

    # ---- XMS operations with the reference model
    def alloc(self, kb, note=True):
        r = self.x(0x0900, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'), dx=kb)
        if r['ax'] == 1:
            h = r['dx']
            self.ref[h] = bytearray(self.read_block(h, 0, kb * 1024)) if kb else bytearray()
            return h
        return None

    def mv(self, length, sh, so, dh, do):
        m = self.m
        m.wr(DATA, 0, struct.pack('<IHIHI', length, sh, so, dh, do))
        return self.x(0x0B00, ds=DATA, si=0)

    @staticmethod
    def seg(lin):
        return ((lin >> 4) << 16) | (lin & 15)

    def fill(self, lin, n, seed):
        data = bytes(random.Random(seed).getrandbits(8) for _ in range(n))
        self.m.wrl(lin, data)
        return data

    # ================================================================ tests
    def run(self):
        self.load()
        self.basics()
        self.moves()
        self.frame()
        self.overlap()
        self.realloc()
        self.errors()
        if self.cpu == 3:
            self.x386()
        self.fuzz()
        self.cleanup()
        crc = zlib.crc32('\n'.join(self.lines).encode())
        self.T('--- %s: %d checks failed, transcript crc %08X ---' % (self.name, self.fails, crc))
        return self.fails

    def basics(self):
        r = self.x(0x0000, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        self.T('00 version AX=%04X BX=%04X DX=%04X' % (r['ax'], r['bx'], r['dx']))
        self.must(r['ax'] == 0x0300 and r['dx'] == 0, 'version 3.00, no HMA')
        for f, nm in ((1, 'request HMA'), (2, 'release HMA')):
            self.x(f << 8, dx=0xFFFF); self.T('%02X %s %s' % (f, nm, self.err()))
            self.must(self.res['ax'] == 0 and self.res['bx'] & 0xFF == 0x90, nm + ' -> 90h')
        want_on = self.cpu == 3                 # the emulator maps memory above 1 MB
        for f, nm in ((3, 'global enable A20'), (4, 'global disable A20'), (5, 'local enable A20'),
                      (6, 'local disable A20'), (7, 'query A20')):
            self.x(f << 8); self.T('%02X %s %s' % (f, nm, self.err()))
        self.x(0x0700)
        self.must(self.res['ax'] == (1 if want_on else 0), 'A20 reported as it is')
        r = self.x(0x0800, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        self.free0 = r['ax']
        self.T('08 query free AX=%d DX=%d BL=%02X' % (r['ax'], r['dx'], r['bx'] & 0xFF))
        self.must(r['ax'] == r['dx'] and r['ax'] > 0, 'free memory reported')
        # a zero-size block, and one of each awkward size
        h0 = self.alloc(0)
        self.T('09 alloc 0 KB -> %s' % ('%04X' % h0 if h0 else self.err()))
        self.must(h0 is not None, 'a zero-size block')
        r = self.x(0x0E00, dx=h0, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        self.T('0E info 0 KB: AX=%d BH=%d DX=%d' % (r['ax'], r['bx'] >> 8, r['dx']))
        self.must(r['ax'] == 1 and r['dx'] == 0 and r['bx'] >> 8 == 0, '0E of a zero-size block')
        self.hs = [h0]
        for kb in (1, 16, 17, 64, 100):
            h = self.alloc(kb)
            self.must(h is not None, 'alloc %d KB' % kb)
            self.hs.append(h)
        r = self.x(0x0800, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        used = (1 + 1 + 2 + 4 + 7) * 16
        self.T('08 after 198 KB of blocks: AX=%d (was %d)' % (r['ax'], self.free0))
        self.must(r['ax'] == self.free0 - used, 'free memory went down by whole pages')
        r = self.x(0x0E00, dx=self.hs[4], keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        self.T('0E info 64 KB: DX=%d BL=%d' % (r['dx'], r['bx'] & 0xFF))
        self.must(r['dx'] == 64 and (r['bx'] & 0xFF) == 32 - 6, 'handle info: size and free handles')
        # lock and unlock
        self.x(0x0C00, dx=self.hs[1]); self.T('0C lock %s' % self.err())
        self.must(self.res['ax'] == 0 and self.res['bx'] & 0xFF == 0xAD, 'lock -> ADh')
        self.x(0x0D00, dx=self.hs[1]); self.T('0D unlock %s' % self.err())
        self.must(self.res['ax'] == 0 and self.res['bx'] & 0xFF == 0xAA, 'unlock -> AAh')
        self.x(0x0C00, dx=0x1234); self.T('0C lock bad handle %s' % self.err())
        # UMBs go to UMBSC
        r = self.x(0x1000, dx=0xFFFF, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        self.T('10 request UMB (too big) AX=%d BL=%02X DX=%04X' % (r['ax'], r['bx'] & 0xFF, r['dx']))
        self.must(r['ax'] == 0 and (r['bx'] & 0xFF) == 0xB0 and r['dx'] > 0, 'UMB request reached UMBSC')
        r = self.x(0x1000, dx=0x10, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        self.T('10 request UMB 16 paras AX=%d BX=%04X DX=%04X' % (r['ax'], r['bx'], r['dx']))
        self.must(r['ax'] == 1 and r['bx'] >= 0xC800, 'UMB granted by UMBSC')
        self.x(0x1300); self.T('13 not a function %s' % self.err())
        self.must(self.res['bx'] & 0xFF == 0x80, 'unknown function -> 80h')
        self.x(0x8800, keep=('si', 'di', 'bp', 'ds', 'es')); self.T('88 %s' % self.err())
        self.must((self.res['ax'] == 0 and self.res['bx'] & 0xFF == 0x80) == (self.cpu != 3), '88h only on a 386')

    def moves(self):
        """conventional <-> EMB, EMB <-> EMB, every alignment, across pages"""
        big = self.alloc(200)
        self.must(big is not None, 'alloc 200 KB')
        self.hs.append(big)
        src = CONV
        cases = [(2, 0, 0), (512, 0, 0), (1024, 1, 1), (1024, 1, 0), (1024, 0, 1), (16384, 0, 0),
                 (16386, 16383, 1), (40002, 16383, 3), (16384, 8192, 0), (65536, 100, 7),
                 (131072, 5, 5), (199 * 1024, 1024, 0)]
        ok = True
        for n, eo, co in cases:
            data = self.fill(src + co, n, n + eo)
            self.mv(n, 0, self.seg(src + co), big, eo)
            if not self.ok():
                ok = self.must(False, 'move %d c->e: %s' % (n, self.err()))
                continue
            self.ref[big][eo:eo + n] = data
            ok &= self.check_block(big, 'c->e %d at %d' % (n, eo))
            dst = CONV + 0x100 + co
            self.m.wrl(dst - 16, b'\xAB' * (n + 32))
            self.mv(n, big, eo, 0, self.seg(dst))
            got = self.m.rdl(dst - 16, n + 32)
            ok &= self.must(self.ok() and got[16:16 + n] == data and got[:16] == b'\xAB' * 16
                            and got[-16:] == b'\xAB' * 16, 'e->c %d at %d, guards intact' % (n, eo))
        self.T('moves conv<->EMB, %d shapes: %d' % (len(cases), ok))
        # EMB to EMB, between two blocks and within one
        a, b = self.hs[4], big                       # 64 KB, 200 KB
        ok = True
        for n, so, do in [(2, 0, 0), (16384, 1, 16383), (60000, 17, 100000), (65536, 0, 131072)]:
            self.mv(n, big, so, a, do % 1000) if n + do % 1000 <= 65536 else None
            if n + do % 1000 <= 65536:
                ok &= self.must(self.ok(), 'e->e %d' % n)
                self.ref[a][do % 1000:do % 1000 + n] = self.ref[big][so:so + n]
                ok &= self.check_block(a, 'e->e %d' % n)
            self.mv(n, a, 0, big, do)
            ok &= self.must(self.ok(), 'e->e back %d' % n)
            self.ref[big][do:do + n] = self.ref[a][0:n]
            ok &= self.check_block(big, 'e->e back %d' % n)
        self.T('moves EMB<->EMB: %d' % ok)
        # conventional to conventional
        d = self.fill(CONV + 0x100, 5000, 9)
        self.mv(5000, 0, self.seg(CONV + 0x100), 0, self.seg(CONV + 0x9001))
        self.must(self.ok() and self.m.rdl(CONV + 0x9001, 5000) == d, 'c->c')
        self.T('move conv->conv: %d' % self.ok())
        # length 0
        self.mv(0, big, 0, 0, self.seg(CONV))
        self.T('move length 0: AX=%d' % self.res['ax'])
        self.must(self.ok(), 'length 0 succeeds')

    def frame(self):
        """a conventional address INSIDE the page frame reads what the caller
        has mapped there, and the windows the move borrows avoid it"""
        m = self.m
        m.intcall(0x67, ax=0x4300, bx=4)
        eh = m.r('dx')
        big = self.hs[-1]
        ok = True
        for w in range(4):
            m.intcall(0x67, ax=0x4400 | w, bx=w, dx=eh)
            m.wrl(FRAME * 16 + w * 16384, bytes([0x40 + w]) * 16384)
        for w in range(4):
            for start, n in ((w * 16384, 16384), (w * 16384 + 16000, 1000), (w * 16384 + 5, 8000)):
                lin = FRAME * 16 + start
                if start + n > 65536:
                    continue
                before = m.rdl(lin, n)
                self.mv(n, 0, self.seg(lin), big, 3)
                ok &= self.must(self.ok(), 'frame->EMB')
                self.ref[big][3:3 + n] = before
                ok &= self.check_block(big, 'from the frame, window %d +%d' % (w, start % 16384))
                # and back into the frame, somewhere else in it
                dl = FRAME * 16 + (start + 7000) % (65536 - n)
                self.mv(n, big, 100, 0, self.seg(dl))
                ok &= self.must(self.ok() and m.rdl(dl, n) == bytes(self.ref[big][100:100 + n]),
                                'EMB->frame at +%X' % (dl - FRAME * 16))
        # 64 KB and more, from below the frame and into it: only the high
        # word of the length says it reaches the frame
        for n in (0x10000, 0x10100, 0x18000):
            lin = FRAME * 16 - n + 0x100
            before = m.rdl(lin, n)
            self.mv(n, 0, self.seg(lin), big, 0)
            ok &= self.must(self.ok(), 'into the frame %X' % n)
            self.ref[big][0:n] = before
            ok &= self.check_block(big, '%X bytes from below the frame into it' % n)
            m.wrl(lin, bytes(n))
            self.mv(n, big, 0, 0, self.seg(lin))
            ok &= self.must(self.ok() and m.rdl(lin, n) == bytes(self.ref[big][0:n]),
                            '%X bytes back, into the frame from below' % n)
        self.T('moves through the page frame: %d' % ok)
        m.intcall(0x67, ax=0x4500, dx=eh)

    def overlap(self):
        big = self.hs[-1]
        ok = True
        for so, do, n in ((0, 2, 40000), (2, 0, 40000), (1000, 17000, 30000), (17000, 1000, 30000),
                          (16383, 16385, 16384), (5, 5, 1000), (0, 1, 100)):
            if (do - so) % 2 and n % 2 == 0:
                pass
            self.mv(n, big, so, big, do)
            ok &= self.must(self.ok(), 'overlap %d->%d' % (so, do))
            self.ref[big][do:do + n] = bytes(self.ref[big][so:so + n])
            ok &= self.check_block(big, 'overlap %d -> %d, %d bytes' % (so, do, n))
        c = CONV + 0x30000
        for so, do, n in ((0, 2, 30000), (2, 0, 30000), (1, 20001, 30000), (20001, 1, 30000)):
            data = self.fill(c, 60000, so * 7 + do)
            self.mv(n, 0, self.seg(c + so), 0, self.seg(c + do))
            exp = bytearray(data)
            exp[do:do + n] = data[so:so + n]
            ok &= self.must(self.ok() and self.m.rdl(c, 60000) == bytes(exp), 'conv overlap %d->%d' % (so, do))
        self.T('overlapping moves, both directions: %d' % ok)

    def realloc(self):
        ok = True
        h = self.hs[2]                      # 16 KB
        for kb in (40, 17, 16, 1, 0, 0, 33, 64, 5, 200):
            old = len(self.ref[h])
            r = self.x(0x0F00, dx=h, bx=kb, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
            ok &= self.must(r['ax'] == 1 and r['bx'] == kb, 'realloc to %d KB (%s)' % (kb, self.err()))
            new = bytearray(self.read_block(h, 0, kb * 1024)) if kb else bytearray()
            keep = min(old, kb * 1024)
            ok &= self.must(new[:keep] == self.ref[h][:keep], 'realloc to %d kept the contents' % kb)
            self.ref[h] = new
            # write it all and read it back, so every page is proven mapped
            if kb:
                d = self.fill(CONV, kb * 1024, kb)
                self.mv(kb * 1024, 0, self.seg(CONV), h, 0)
                self.ref[h][:] = d
                ok &= self.check_block(h, 'after realloc to %d' % kb)
            for o in self.hs:
                if o != h and o in self.ref:
                    ok &= self.check_block(o, 'another block, after realloc to %d' % kb)
        self.T('reallocate up, down, to 0 and back: %d' % ok)

    def errors(self):
        big, small = self.hs[-1], self.hs[1]
        C = self.seg(CONV)
        for nm, args, want in (('odd length', (3, 0, C, big, 0), 0xA7),
                               ('bad source handle', (2, 0x1234, 0, big, 0), 0xA3),
                               ('freed-looking handle', (2, self.m.entry[0], 0, big, 0), 0xA3),
                               ('source offset past end', (2, small, 1025, 0, C), 0xA4),
                               ('source runs past end', (4, small, 1022, 0, C), 0xA7),
                               ('bad dest handle', (2, 0, C, 0x0001, 0), 0xA5),
                               ('dest offset past end', (2, 0, C, small, 2000), 0xA6),
                               ('dest runs past end', (1026, 0, C, small, 0), 0xA7),
                               ('length past 4 GB', (0xFFFFFFFE, big, 2, 0, C), 0xA7)):
            self.mv(*args)
            self.T('0B %-22s %s' % (nm, self.err()))
            self.must(self.res['ax'] == 0 and self.res['bx'] & 0xFF == want, nm + ' -> %02X' % want)
        self.mv(2, small, 1022, 0, C)
        self.T('0B last word of a block  AX=%d' % self.res['ax'])
        self.must(self.ok(), 'the last word moves')
        self.x(0x0A00, dx=0x1234); self.T('0A free bad handle %s' % self.err())
        self.must(self.res['bx'] & 0xFF == 0xA2, 'free bad -> A2h')
        self.x(0x0F00, dx=0x1234, bx=1); self.T('0F realloc bad handle %s' % self.err())
        self.x(0x0E00, dx=0x1234); self.T('0E info bad handle %s' % self.err())
        # run out of memory, and of handles
        r = self.x(0x0900, dx=65535, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        self.T('09 alloc 65535 KB %s' % self.err())
        self.must(r['ax'] == 0 and r['bx'] & 0xFF == 0xA0, 'too big -> A0h')
        extra = []
        while True:
            h = self.alloc(0)
            if h is None:
                break
            extra.append(h)
        self.T('09 handles run out after %d more: %s' % (len(extra), self.err()))
        self.must(self.res['bx'] & 0xFF == 0xA1, 'out of handles -> A1h')
        for h in extra:
            self.x(0x0A00, dx=h)
            del self.ref[h]
        self.x(0x0A00, dx=extra[0]); self.T('0A free twice %s' % self.err())
        self.must(self.res['bx'] & 0xFF == 0xA2, 'free twice -> A2h')

    def x386(self):
        m = self.m
        m.w('eax', 0x88000000 | 0x8800)
        r = self.x(0x8800, keep=('si', 'di', 'bp', 'ds', 'es'))
        eax, ecx, edx = m.r('eax'), m.r('ecx'), m.r('edx')
        self.T('88 EAX=%d ECX=%08X EDX=%d BL=%02X' % (eax, ecx, edx, r['bx'] & 0xFF))
        self.must(eax == edx and eax > 0, '88h free')
        m.w('edx', 0x10000)
        self.x(0x8900, dx=0, keep=('cx', 'si', 'di', 'bp', 'ds', 'es')); self.T('89 alloc 65536 KB %s' % self.err())
        self.must(self.res['bx'] & 0xFF == 0xA0, '89h > 64 MB -> A0h')
        m.w('edx', 3)
        r = self.x(0x8900, dx=3, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        h = r['dx']
        self.T('89 alloc 3 KB AX=%d' % r['ax'])
        m.w('edx', 0xFFFF0000 | h)
        r = self.x(0x8E00, dx=h, keep=('si', 'di', 'bp', 'ds', 'es'))
        self.T('8E info AX=%d BH=%d CX=%d EDX=%d' % (r['ax'], r['bx'] >> 8, r['cx'], m.r('edx')))
        self.must(r['ax'] == 1 and m.r('edx') == 3, '8Eh size in EDX')
        m.w('ebx', 0x00010000)
        self.x(0x8F00, dx=h, keep=('cx', 'si', 'di', 'bp', 'ds', 'es')); self.T('8F realloc 65536 KB %s' % self.err())
        m.w('ebx', 20)
        self.x(0x8F00, dx=h, bx=20, keep=('cx', 'si', 'di', 'bp', 'ds', 'es')); self.T('8F realloc 20 KB AX=%d' % self.res['ax'])
        self.x(0x0A00, dx=h)

    def fuzz(self):
        rng = self.rng
        hs = [h for h in self.hs if h in self.ref]
        ok = True
        n_mv = n_bad = 0
        for i in range(self.ops):
            op = rng.random()
            if op < 0.06 and len(hs) < 20:
                kb = rng.choice([0, 1, 2, 15, 16, 17, 33, 64, 90])
                h = self.alloc(kb)
                if h:
                    hs.append(h)
            elif op < 0.10 and len(hs) > 3:
                h = hs.pop(rng.randrange(len(hs)))
                self.x(0x0A00, dx=h)
                ok &= self.must(self.ok(), 'fuzz free')
                del self.ref[h]
            elif op < 0.15 and hs:
                h = rng.choice(hs)
                kb = rng.choice([0, 1, 16, 17, 40, 70, 100])
                old = len(self.ref[h])
                self.x(0x0F00, dx=h, bx=kb)
                if self.ok():
                    new = bytearray(self.read_block(h, 0, kb * 1024)) if kb else bytearray()
                    keep = min(old, kb * 1024)
                    ok &= self.must(new[:keep] == self.ref[h][:keep], 'fuzz realloc kept')
                    self.ref[h] = new
            else:
                cands = [h for h in hs if len(self.ref[h]) >= 2]
                if not cands:
                    continue
                kind = rng.choice(['ce', 'ec', 'ee', 'ee', 'cc'])
                sh = dh = 0
                if kind in ('ec', 'ee'):
                    sh = rng.choice(cands)
                if kind in ('ce', 'ee'):
                    dh = rng.choice(cands)
                lim = min([len(self.ref[h]) for h in (sh, dh) if h] + [60000])
                n = rng.randrange(1, lim // 2 + 1) * 2 if rng.random() < 0.8 else rng.choice([2, 4, 512, 1024, 2048, 16384])
                n = min(n, lim - lim % 2)
                so = rng.randrange(0, len(self.ref[sh]) - n + 1) if sh else rng.randrange(0, 0x3FFFF - n)
                do = rng.randrange(0, len(self.ref[dh]) - n + 1) if dh else rng.randrange(0, 0x3FFFF - n)
                if not sh:
                    so += CONV
                if not dh:
                    do += CONV
                # what the source holds now
                if sh:
                    data = bytes(self.ref[sh][so:so + n])
                else:
                    data = self.m.rdl(so, n)
                before = self.m.rdl(do - 8, n + 16) if not dh else None
                self.mv(n, sh, so if sh else self.seg(so), dh, do if dh else self.seg(do))
                n_mv += 1
                if not self.must(self.ok(), 'fuzz move %s %d: %s' % (kind, n, self.err())):
                    n_bad += 1
                    continue
                if dh:
                    self.ref[dh][do:do + n] = data
                    if rng.random() < 0.3:
                        ok &= self.check_block(dh, 'fuzz %s %d' % (kind, n))
                    elif not self.must(self.read_block(dh, do, n) == data, 'fuzz %s %d into the block' % (kind, n)):
                        n_bad += 1
                else:
                    got = self.m.rdl(do - 8, n + 16)
                    if not self.must(got[8:8 + n] == data and got[:8] == before[:8] and got[-8:] == before[-8:],
                                     'fuzz %s %d to conventional' % (kind, n)):
                        n_bad += 1
        for h in hs:
            ok &= self.check_block(h, 'after the fuzz')
        self.T('fuzz: %d operations, %d moves, %d failed, every block checked: %d' % (self.ops, n_mv, n_bad, ok))
        self.hs = hs

    def cleanup(self):
        if self.m.model:
            n57 = getattr(self.m.model, 'moves', 0)
            # XMSSC never calls 57h: one 57h a slice was tried in EMS-call
            # mode (2026-09-28) and measured SLOWER on the V30 than the 44h
            # path -- PMEMMSC's 57h costs more than the calls it replaces.
            # The model's 57h stays, for whoever tries it again.
            self.T('EMS 57h calls made: %s' % ('some' if n57 else 'none'))
            self.must(n57 == 0, 'XMSSC makes no 57h calls')
        for h in list(self.ref):
            self.x(0x0A00, dx=h)
            self.must(self.ok(), 'free at the end')
        r = self.x(0x0800, keep=('cx', 'si', 'di', 'bp', 'ds', 'es'))
        self.T('08 at the end AX=%d (at the start %d)' % (r['ax'], self.free0))
        self.must(r['ax'] == self.free0, 'every page given back')
        if self.com:
            # another build must refuse: one byte of its code changed
            img = bytearray(open(os.path.join(BUILD, 'XMSSC.COM'), 'rb').read())
            img[img.index(b'XMSSC1.0') + 8 + 30] ^= 0xFF
            ex = self.m.run_com(X2SEG, bytes(img), ' /U')
            out = ''.join(self.m.out).replace('\r', '').strip()
            self.m.out = []
            self.T('/U from another build: exit %s, "%s"' % (ex, out.splitlines()[-1] if out else ''))
            self.must(ex and ex[0] == 0x4C and ex[1] == 1 and 'different build' in out, 'another build refuses /U')
            ex = self.m.run_com(X2SEG, open(os.path.join(BUILD, 'XMSSC.COM'), 'rb').read(), ' /U')
            out = ''.join(self.m.out).replace('\r', '').strip()
            self.m.out = []
            self.T('/U: exit %s, "%s", freed %s' % (ex, out, getattr(self.m, 'freed', None)))
            self.must(ex and ex[0] == 0x4C and ex[1] == 0 and XSEG in self.m.freed, 'unloaded')
            self.m.intcall(0x2F, ax=0x4310)
            self.must((self.m.r('bx'), self.m.r('es')) != self.m.entry, 'INT 2Fh given back')


CONFIGS = {
    # name: (ems, cpu, generic, com)
    'pm-direct-8086': ('pmemm', 0, False, False),
    'pm-direct-386': ('pmemm', 3, False, False),
    'pm-generic-8086': ('pmemm', 0, True, False),
    'model40-direct-186': ('model40', 1, False, False),
    'model40-generic-8086': ('model40', 0, True, False),
    'model32-generic-8086': ('model32', 0, False, False),   # 3.2: never direct
    'model32-generic-386': ('model32', 3, False, False),
    'com-pm-direct-8086': ('pmemm', 0, False, True),
}

if __name__ == '__main__':
    args = sys.argv[1:]
    verbose = '-v' in args
    ops = 150 if '--quick' in args else 1500
    names = list(CONFIGS)
    if '--only' in args:
        names = [args[args.index('--only') + 1]]
    total = 0
    for i, nm in enumerate(names):
        ems, cpu, gen, com = CONFIGS[nm]
        t = Test(nm, ems, cpu, gen, com, seed=1000 + i, ops=ops, verbose=verbose)
        try:
            f = t.run()
        except Exception as e:
            import traceback
            traceback.print_exc()
            t.T('*** %s crashed: %s' % (nm, e))
            f = 1
        if not verbose:
            for s in t.lines:
                if 'FAILED' in s or s.startswith('---') or s.startswith('***') or s.startswith('  |'):
                    print(s)
        total += f
    print('=== %d configurations, %d checks failed ===' % (len(names), total))
    sys.exit(1 if total else 0)
