"""directed.py -- DOSKEYSC against MS-DOS 6.22's DOSKEY on sessions chosen to
reach what random typing seldom does.  StevenC & Claude, 2026.

    python directed.py DOSKEY.COM DOSKEYSC.COM

Each session runs on both, with and without a console driver that answers
the generic IOCTL (F7's page length comes from it), and everything is
compared after every line: the line handed back, the screen, the cursor.
Then the two DOSKEYs are made to work on each other's resident copy.
"""
import sys
from emudoskey import compare, Session, K, PSP2

many = [('type', 'echo line %d{CR}' % i) for i in range(1, 60)]

SESSIONS = {
    'f7 paging': many + [('type', '{F7}' + 'x' * 5)],
    'f7 paging, small buffer': [('type', 'c%d{CR}' % i) for i in range(80)] + [('type', '{F7}xyz')],
    'f9': many + [('type', '{F9}7{CR}{CR}'), ('type', '{F9}{CR}{CR}'), ('type', '{F9}99{CR}{CR}'),
                  ('type', '{F9}0{CR}{CR}'), ('type', '{F9}123456{CR}{CR}'), ('type', '{F9}12{BS}{BS}{BS}3{CR}{CR}'),
                  ('type', '{F9}5{ESC}{CR}'), ('type', '{F9}{UP}a4{CR}{CR}'), ('type', '{F9}65535{CR}{CR}')],
    'f8': [('type', 'dir a{CR}'), ('type', 'DIR b{CR}'), ('type', 'copy{CR}'), ('type', 'di{F8}{CR}'),
           ('type', 'di{F8}{F8}{CR}'), ('type', 'di{F8}{F8}{F8}{F8}{CR}'), ('type', '{F8}{F8}{CR}'),
           ('type', 'zz{F8}{CR}'), ('type', 'Di{F8}{LEFT}{F8}{CR}')],
    'recall': many[:10] + [('type', '{UP}{UP}{DOWN}{CR}'), ('type', '{PGUP}{CR}'), ('type', '{PGDN}{CR}'),
                           ('type', '{UP}{ESC}{DOWN}{CR}'), ('type', '{DOWN}{DOWN}{CR}'), ('type', '{AF7}{UP}{CR}'),
                           ('type', '{UP}{DOWN}{PGUP}{F7}')],
    'bufsize 257': [('run', '/REINSTALL /BUFSIZE=1')] + [('type', ('x' * (i % 90)) + '{CR}') for i in range(40)]
                   + [('type', '{F7}q'), ('run', '/H')],
    'macros eat history': [('type', 'w' * 100 + '{CR}') for _ in range(5)] +
                          [('run', 'm%d=%s' % (i, 'e' * min(20 * i, 110))) for i in range(1, 12)] +
                          [('run', '/M'), ('run', '/H'), ('type', '{UP}{UP}{UP}{CR}'), ('type', '{F7}q')],
    'macro overflow': [('run', 'big=' + 'a' * 50 + '$t' + 'b' * 55 + ' $* $*'),
                       ('type', 'big ' + 'c' * 60 + '{CR}'), ('run', 'p=$1-$2-$3-$9 $* $$ $g $l $b $q'),
                       ('type', 'p one two{^T}three four{CR}'), ('type', 'p   a   b   {CR}'),
                       ('type', 'p ' + 'z' * 120 + '{CR}'), ('run', '/M')],
    'ctrl-t lines': [('type', 'a{^T}b{^T}{^T}c{CR}'), ('type', 'x' * 60 + '{^T}' + 'y' * 60 + '{CR}'),
                     ('run', 'b=BEE $*'), ('type', 'b 1{^T}b 2{^T}b{CR}'), ('type', '{^T}{CR}')],
    'bottom row': [('type', 'echo %d{CR}' % i) for i in range(30)] +
                  [('type', 'q' * 70 + '{HOME}' + '{INS}' + 'abc' * 5 + '{DEL}{DEL}{END}{BS}' + '{CR}'),
                   ('type', 'r' * 120 + '{HOME}{CRIGHT}' + '{x09}' * 3 + '{CEND}{CR}'),
                   ('type', '{UP}{UP}{CHOME}{CR}'), ('type', 'x{^A}{^B}{x09}y{LEFT}{LEFT}{LEFT}{DEL}{CR}')],
    'template': [('type', 'abcdefgh{CR}'), ('type', '{F1}{F1}{F3}{CR}'), ('type', '{F2}e{F4}g{F3}{CR}'),
                 ('type', 'X{F3}{CR}'), ('type', '{INS}YY{F3}{CR}'), ('type', '{F5}zz{F3}{CR}'),
                 ('type', '{F6}{F3}{CR}'), ('type', '{F2}{UP}{F4}{DOWN}{F3}{CR}'), ('type', '{DEL}{DEL}{F3}{CR}')],
    'insert default': [('run', '/INSERT'), ('type', 'abc{HOME}xy{INS}z{CR}'), ('run', '/OVERSTRIKE'),
                       ('type', 'abc{HOME}xy{INS}z{CR}'), ('run', '/INSERT /OVERSTRIKE'), ('type', 'q{CR}')],
    'switches': [('run', '/h /m'), ('run', '/HISTORYX'), ('run', '/MX'), ('run', '/bufsize=600'),
                 ('run', '/BUFSIZE 600'), ('run', 'noequals'), ('run', '=x'), ('run', 'a = b'), ('run', '  a=  b  '),
                 ('run', 'a='), ('run', '/M'), ('run', '/REINSTALL'), ('run', '/M'), ('type', 'dir{CR}'), ('run', '/H')],
}


def interop(ms, sc):
    """Each DOSKEY's command line on the other's resident copy."""
    bad = 0
    for res, tra, name in ((ms, sc, 'DOSKEYSC on 6.22 resident'), (sc, ms, '6.22 on DOSKEYSC resident')):
        ref = Session(res, '')
        mix = Session(res, '')
        for s in (ref, mix):
            s.type(K('one{CR}two{CR}three{CR}'))
        for st in ('m=dir $1', 'q=echo $*$tver', '/M', '/H', '/INSERT', 'm=', '/M'):
            ref.run(st)
            mix.pc.image, keep = tra, mix.pc.image
            mix.run(st)
            mix.pc.image = keep
        for s in (ref, mix):
            s.type(K('q a b{CR}abc{HOME}x{CR}'))
        if ref.log != mix.log:
            bad += 1
            print('INTEROP %s differs' % name)
            for a, b in zip(ref.log, mix.log):
                if a != b:
                    print(' ref ', a[:-1]); print(' mix ', b[:-1])
                    print('\n'.join(r.rstrip() for r in b[-1][0] if r.strip()))
                    break
    return bad


if __name__ == '__main__':
    ms = open(sys.argv[1], 'rb').read()
    sc = open(sys.argv[2], 'rb').read()
    bad = 0
    for name, steps in SESSIONS.items():
        for ansi in (True, False):
            r = compare(ms, sc, steps, ansi=ansi)
            if r:
                bad += 1
                print('SESSION %r ansi=%s DIFFERS\n%s' % (name, ansi, r))
    bad += interop(ms, sc)
    print('%d sessions x 2, interop x 2: %d differ' % (len(SESSIONS), bad))
    sys.exit(1 if bad else 0)
