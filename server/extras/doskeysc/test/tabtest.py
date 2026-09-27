"""tabtest.py -- DOSKEYSC's TAB completion, in the emulator.  StevenC & Claude.

    python tabtest.py DOSKEYSC.COM [--fuzz N]

Two kinds of test:

  directed  a keystroke string and the line it must produce, over the
            made-up disk in emudoskey.py (C:\\, C:\\DOS, C:\\AI\\SUB ...)
  fuzz      random typing, editing and TAB / SHIFT+TAB; after every line the
            screen must show exactly the prompt and the line -- nothing left
            over from a longer name, nothing missing -- with the cursor where
            the line ends.  TAB is the one part with no 6.22 behaviour to
            compare against, so this is what holds its drawing to account.
"""
import random, sys
from emudoskey import Session, K, PC

DIRECTED = [
    ('type au{TAB}{CR}', b'type autoexec.bat'),
    ('type au{TAB}{TAB}{CR}', b'type autoexec.sav'),
    ('type au{TAB}{TAB}{TAB}{CR}', b'type autoexec.bat'),
    ('type au{STAB}{CR}', b'type autoexec.sav'),
    ('type au{STAB}{STAB}{CR}', b'type autoexec.bat'),
    ('type au{TAB}{STAB}{CR}', b'type autoexec.sav'),        # wraps back
    ('TYPE AU{TAB}{CR}', b'TYPE AUTOEXEC.BAT'),
    ('cd d{TAB}{CR}', b'cd dos\\'),
    ('cd d{TAB}{TAB}{CR}', b'cd drivers\\'),
    ('cd d{TAB}{END}{TAB}{CR}', b'cd dos\\ansi.sys'),
    ('type c:\\dos\\ed{TAB}{CR}', b'type c:\\dos\\edit.com'),
    ('TYPE C:\\DOS\\ED{TAB}{CR}', b'TYPE C:\\DOS\\EDIT.COM'),
    ('dir \\ai\\s{TAB}{CR}', b'dir \\ai\\sub\\'),
    ('dir \\ai\\sub\\{TAB}{CR}', b'dir \\ai\\sub\\one.txt'),
    ('type zzz{TAB}{CR}', b'type zzz'),
    ('type zzz{TAB}{TAB}q{CR}', b'type zzzq'),
    ('type config.{TAB}{CR}', b'type config.sc0'),
    ('type config.{TAB}{TAB}{TAB}{TAB}{CR}', b'type config.sys'),
    ('type config.s{TAB}{CR}', b'type config.sc0'),
    ('type config.sy{TAB}{CR}', b'type config.sys'),
    ('type *.bat{TAB}{CR}', b'type autoexec.bat'),
    ('copy x.txt{HOME}{CRIGHT}{TAB}{CR}', b'copy agent\\x.txt'),
    ('copy autoexec.bat,con{LEFT}{LEFT}{LEFT}{LEFT}{BS}{BS}{BS}{TAB}{CR}', b'copy autoexec.bat,con'),
    ('echo x>au{TAB}{CR}', b'echo x>autoexec.bat'),
    ('a{TAB}{CR}', b'agent\\'),
    ('{TAB}{CR}', b'AGENT\\'),
    ('{TAB}{TAB}{TAB}{CR}', b'AUTOEXEC.BAT'),
    ('{STAB}{CR}', b'WORK\\'),
    ('type io{TAB}{CR}', b'type io'),                        # hidden: not offered
    ('dir ..{TAB}{CR}', b'dir ..'),
    ('cd \\dos\\..\\t{TAB}{CR}', b'cd \\dos\\..\\tools\\'),
    ('x:\\{TAB}{CR}', b'x:\\'),                              # no such drive
    ('type au{TAB}{TAB}{ESC}{CR}', b''),
    ('type au{TAB}{LEFT}{LEFT}{TAB}{CR}', b'type autoexec.bat'),  # mid-word: the whole word goes
    ('type autoexec.sav{LEFT}{LEFT}{LEFT}{BS}{TAB}{CR}', b'type autoexec.bat'),
    ('copy au x{LEFT}{LEFT}{TAB}{CR}', b'copy autoexec.bat x'),
    ('copy x.txt{HOME}{CRIGHT}{TAB}{TAB}{CR}', b'copy ai\\x.txt'),
    ('copy x.txt{HOME}{CRIGHT}{TAB}{TAB}{STAB}{CR}', b'copy agent\\x.txt'),
    ('type autoexec.sav{LEFT}{LEFT}{LEFT}{BS}{TAB}{TAB}{CR}', b'type autoexec.sav'),
    ('type au{TAB}{BS}{BS}{BS}{TAB}{CR}', b'type autoexec.bat'),
    ('x' * 110 + ' au{TAB}{CR}', b'x' * 110 + b' autoexec.bat'),
    ('x' * 116 + ' au{TAB}{CR}', b'x' * 116 + b' au'),         # 129: too long, left alone
    ('x' * 114 + ' au{TAB}{CR}', b'x' * 114 + b' autoexec.bat'),  # exactly 127
    ('x' * 113 + ' aut' + '{LEFT}{TAB}{DEL}{TAB}{CR}', b'x' * 113 + b' autoexec.bat'),  # too long, then fits
    ('type  au{LEFT}{LEFT}{LEFT}{DEL}{END}{TAB}{CR}', b'type autoexec.bat'),
    ('type au{TAB}{TAB}{UP}{CR}', None),                    # recall ends the cycle
]


def render(prompt, line):
    """What the screen shows for the prompt and the line: ^X for control
    characters, tabs to the next stop."""
    out = prompt
    for b in line:
        if b == 9:
            out += ' ' * (8 - (len(out) % 80) % 8)
        elif b < 0x20 and b not in (0x14, 0x15):
            out += '^' + chr(b + 64)
        else:
            out += bytes([b]).decode('cp437')
    return out


def fresh(img, tail):
    return Session(img, tail)


def run_one(img, keys, tail='', check=True):
    s = fresh(img, tail)
    pc = s.pc
    # clear the screen so the whole line is visible from row 0
    pc.uc.mem_write(0xB8000, b'\x20\x07' * 2000); pc.setcur(0, 0)
    pc.keys = list(K(keys))
    pc.prompt('C:\\>')
    line = pc.readline(s.template)
    if check:
        want = render('C:\\>', line)
        rows = pc.screen()
        text = ''.join(rows)
        r, c = pc.getcur()
        # DOSKEY echoes CR at the end, so the cursor is at column 0 of the
        # line's last row: everything from the start to that row's end
        span = text[:(r + 1) * 80]
        if span.rstrip() != want.rstrip() or text[(r + 1) * 80:].strip():
            return line, 'screen: %r\nwant  : %r' % (span.rstrip(), want)
    return line, None


def fuzz(img, n, seed=1):
    rnd = random.Random(seed)
    pieces = ['type ', 'cd ', 'au', 'c:\\dos\\', 'D', 'e', '\\ai\\', 'sub\\', 'x', ' ', '..\\', 'config.',
              '{TAB}', '{TAB}', '{TAB}', '{STAB}', '{LEFT}', '{RIGHT}', '{BS}', '{DEL}', '{HOME}',
              '{END}', '{INS}', '{CLEFT}', '{CRIGHT}', '{^A}', '{x09}', 'zz', 'long' * 5]
    bad = 0
    for k in range(n):
        keys = ''.join(rnd.choice(pieces) for _ in range(rnd.randint(1, 30)))
        keys += '{CR}'
        tail = rnd.choice(['', '/INSERT'])
        try:
            line, err = run_one(img, keys, tail)
        except Exception as e:
            err = 'EXCEPTION %s' % e
        if err:
            bad += 1
            print('FUZZ %d tail %r keys %r\n%s' % (k, tail, keys, err))
            if bad > 3: break
    print('fuzz: %d runs, %d bad' % (n, bad))
    return bad


if __name__ == '__main__':
    img = open(sys.argv[1], 'rb').read()
    n = int(sys.argv[sys.argv.index('--fuzz') + 1]) if '--fuzz' in sys.argv else 500
    bad = 0
    for keys, want in DIRECTED:
        for tail in ('', '/INSERT'):
            line, err = run_one(img, keys, tail)
            if want is not None and line != want:
                err = (err or '') + ' got %r want %r' % (line, want)
            if err:
                bad += 1
                print('FAIL %r tail %r: %s' % (keys, tail, err))
    print('directed: %d cases, %d failed' % (len(DIRECTED) * 2, bad))
    # /NOTAB: TAB is a character again
    line, err = run_one(img, 'a{TAB}b{CR}', '/NOTAB')
    if line != b'a\tb':
        bad += 1; print('FAIL /NOTAB: %r' % line)
    bad += fuzz(img, n)
    sys.exit(1 if bad else 0)
