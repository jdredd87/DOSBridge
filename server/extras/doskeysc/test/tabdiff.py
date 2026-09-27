r"""tabdiff.py -- two DOSKEYSC builds on the same long TAB sessions: the lines
they give must be the same.  StevenC & Claude, 2026.

    python tabdiff.py OLD.COM NEW.COM [sessions]

Used when the TAB search changed from "scan the directory every press" to
"scan once, remember the next eight": a directory of 54 names (C:\BIG,
added to the made-up disk here) makes the remembered eight run out, wrap,
and change direction many times over.
"""
import random, sys
import emudoskey
from tabtest import run_one

emudoskey.DISK['C:\\BIG\\'] = ([('.', 0x10), ('..', 0x10)] +
                               [('F%03d.TXT' % i, 0x20) for i in range(45)] +
                               [('D%02d' % i, 0x10) for i in range(7)])
emudoskey.DISK['C:\\'].append(('BIG', 0x10))

old = open(sys.argv[1], 'rb').read()
new = open(sys.argv[2], 'rb').read()
n = int(sys.argv[3]) if len(sys.argv) > 3 else 400
rnd = random.Random(3)
bad = 0
for k in range(n):
    keys = rnd.choice([r'type \big' + '\\', r'type \big\f0', r'cd \big\d', r'type \big\f', r'x \big\*.txt'])
    keys += ''.join(rnd.choice(['{TAB}'] * 6 + ['{STAB}'] * 3 + ['x', '{BS}', '{END}'])
                    for _ in range(rnd.randint(1, 60))) + '{CR}'
    a, _ = run_one(old, keys, check=False)
    b, err = run_one(new, keys)
    if a != b or err:
        bad += 1
        print('DIFF %r\n  old %r\n  new %r %s' % (keys, a, b, err or ''))
        if bad > 3:
            break
print('%d long TAB sessions: %d differ' % (n, bad))
sys.exit(1 if bad else 0)
