"""instrs.py -- how many instructions XMSSC executes per move, and where.
StevenC & Claude, 2026.  Public domain (the Unlicense).

    python instrs.py [DRIVER.SYS]

Runs the driver in emuxms.py's emulator (PMEMMSC, PicoMEM direct, 186
paths) and counts the instructions each move executes, besides the copy
itself -- a REP MOVSW counts once -- with a histogram by routine for a
512-byte move.  On an 8086-class CPU, where fetching the code is much of
the cost, fewer and shorter instructions are the speed; this is the
number to watch when changing the hot paths.  The routine names come from
a NASM map of XMSSC.ASM, made here.
"""
import collections, os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import emuxms as E
from unicorn import UC_HOOK_CODE

src = os.path.join(HERE, '..', 'XMSSC.ASM')
tmp = tempfile.mkdtemp()
mapf = os.path.join(tmp, 'xmssc.map')
with open(os.path.join(tmp, 'm.asm'), 'w', newline='') as f:
    f.write('[map all %s]\n' % mapf + open(src, newline='').read())
subprocess.run(['nasm', '-f', 'bin', '-o', os.path.join(tmp, 'm.sys'), os.path.join(tmp, 'm.asm')], check=True)
if len(sys.argv) > 1:
    os.environ['XMSSC_SYS'] = sys.argv[1]
else:
    os.environ['XMSSC_SYS'] = os.path.join(tmp, 'm.sys')

txt = open(mapf).read()
txt = txt[txt.index('-- Symbols'):]
syms = []
for l in txt.splitlines():
    p = l.split()
    if len(p) == 3:
        try:
            syms.append((int(p[1], 16), p[2]))
        except ValueError:
            pass
syms.sort()


def routine(off):
    best = '?'
    for a, n in syms:
        if a > off:
            break
        best = n
    return best.split('.')[0]


t = E.Test('instrs', 'pmemm', 1, False, False, 1, 0, False)
t.load()
h = t.alloc(256)
state = dict(on=False, last=None, n=0, hist=collections.Counter())


def hook(uc, addr, size, ud):
    if not state['on'] or not (E.XSEG * 16 <= addr < E.XSEG * 16 + 0x10000):
        return
    off = addr - E.XSEG * 16
    if off == state['last']:
        return                              # another REP iteration
    state['last'] = off
    state['n'] += 1
    state['hist'][routine(off)] += 1


t.m.uc.hook_add(UC_HOOK_CODE, hook)
C = t.seg(E.CONV)
for name, args in (('conv -> block 512', (512, 0, C, h, 0)), ('block -> conv 512', (512, h, 0, 0, C)),
                   ('conv -> block 512, odd', (512, 0, t.seg(E.CONV + 1), h, 0)),
                   ('conv -> block 4096', (4096, 0, C, h, 0)), ('conv -> block 16384', (16384, 0, C, h, 0)),
                   ('block -> block 16384', (16384, h, 0, h, 65536)), ('conv -> conv 512', (512, 0, C, 0, C + 0x10000))):
    state.update(on=True, last=None, n=0, hist=collections.Counter())
    t.mv(*args)
    state['on'] = False
    print('%-24s %4d instructions  (AX=%d)' % (name, state['n'], t.res['ax']))
    if name == 'conv -> block 512':
        hist512 = state['hist']
print('\nconv -> block 512, by routine:')
for n, c in hist512.most_common():
    print('  %-10s %d' % (n, c))
