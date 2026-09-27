"""dkemu.py -- run DKTEST itself in the emulator, to check it before it goes
near the real machine: its report must equal hwcheck's model.  StevenC & Claude."""
import sys
from emudoskey import PC, PSP2
from hwcheck import model, keybytes

def run(dk_img, dkt_img, keys, tail=''):
    pc = PC(dk_img)
    pc.program(tail)
    pc.vector21 = True
    pc.files['T.KEY'] = bytearray(keys)
    pc.image = dkt_img
    rc = pc.program('T.KEY R.TXT', psp=PSP2)
    return rc, bytes(pc.files.get('R.TXT', b'')).decode('cp437').replace('\r\n', '\n').rstrip('\n').split('\n')

if __name__ == '__main__':
    dk = open(sys.argv[1], 'rb').read(); dkt = open(sys.argv[2], 'rb').read()
    keys = open(sys.argv[3], 'rb').read()
    rc, rep = run(dk, dkt, keys)
    mod = model(dk, keys)
    bad = sum(1 for a, b in zip(rep, mod) if a != b) + abs(len(rep) - len(mod))
    for i, (a, b) in enumerate(zip(rep, mod)):
        if a != b:
            print(i, repr(a), repr(b)); break
    print('rc', rc, 'report', len(rep), 'model', len(mod), 'differ', bad)
