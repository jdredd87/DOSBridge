"""hwcheck.py -- the emulator's side of DKTEST: the same key script, the same
report, so a run on the real machine can be compared with the model byte
for byte.  StevenC & Claude, 2026.

    python hwcheck.py keys  NAME 'keystrokes'...   write NAME.KEY
    python hwcheck.py model DOSKEY.COM NAME.KEY [tail]   print the report
    python hwcheck.py diff  REPORT.TXT DOSKEY.COM NAME.KEY [tail]

The model starts where DKTEST does: a clear screen, cursor home, shape
0607h, insert off, an empty template.
"""
import sys
from emudoskey import PC, K, OutOfKeys


def keybytes(s):
    out = bytearray()
    for k in K(s):
        if k >= 0x100: out += bytes([0, k & 0xFF])
        else: out.append(k)
    return bytes(out)


class EndPC(PC):
    """Keys run out -> Enter, as DKTEST does."""
    ended = False

    def int21(self):
        from unicorn.x86_const import UC_X86_REG_AX
        ax = self.reg(UC_X86_REG_AX)
        ah = ax >> 8
        if ah == 0x0B:
            self.setreg(UC_X86_REG_AX, (ax & 0xFF00) | 0xFF); return
        if ah == 0x08:
            if self.rawkeys:
                self.setreg(UC_X86_REG_AX, (ax & 0xFF00) | self.rawkeys.pop(0))
            else:
                self.ended = True
                self.setreg(UC_X86_REG_AX, (ax & 0xFF00) | 13)
            return
        return PC.int21(self)


def model(img, keys, tail='', ansi=True):
    pc = EndPC(img, ansi=ansi)
    pc.program(tail)
    pc.uc.mem_write(0xB8000, b'\x20\x07' * 2000); pc.setcur(0, 0)
    pc.w16(0x460, 0x0607); pc.w8(0x417, 0)
    pc.rawkeys = list(keys)
    template = b''
    out = []
    for _ in range(200):
        pc.prompt('C:\\>')
        line = pc.readline(template)
        if line is None:
            out.append('DECLINED'); break
        template = line
        r, c = pc.getcur()
        sh = pc.r16(0x460)
        out.append('L:' + line.decode('cp437'))
        out.append('%02X%02X%02X%02X%02X' % (r, c, sh >> 8, sh & 0xFF, pc.r8(0x417) & 0x80))
        raw = bytes(pc.uc.mem_read(0xB8000, 4000))[0::2]
        for i in range(25):
            out.append('R:' + raw[i * 80:(i + 1) * 80].rstrip(b' ').decode('cp437'))
        pc.teletype(13); pc.teletype(10)
        if pc.ended: break
    return out


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'keys':
        open(sys.argv[2] + '.KEY', 'wb').write(b''.join(keybytes(a) for a in sys.argv[3:]))
    elif cmd == 'model':
        tail = sys.argv[4] if len(sys.argv) > 4 else ''
        print('\n'.join(model(open(sys.argv[2], 'rb').read(), open(sys.argv[3], 'rb').read(), tail)))
    elif cmd == 'diff':
        rep = open(sys.argv[2], 'rb').read().decode('cp437').replace('\r\n', '\n').rstrip('\n').split('\n')
        tail = sys.argv[5] if len(sys.argv) > 5 else ''
        mod = model(open(sys.argv[3], 'rb').read(), open(sys.argv[4], 'rb').read(), tail)
        bad = 0
        for i, (a, b) in enumerate(zip(rep, mod)):
            if a != b:
                bad += 1
                if bad <= 10: print('line %d\n  real : %r\n  model: %r' % (i, a, b))
        if len(rep) != len(mod):
            print('lengths: real %d model %d' % (len(rep), len(mod))); bad += 1
        print('%d report lines, %d differ' % (len(rep), bad))
        sys.exit(1 if bad else 0)
