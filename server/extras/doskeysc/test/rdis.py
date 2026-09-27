# rdis.py -- recursive-descent 8086 disassembler for a .COM file, used to study
# MS-DOS 6.22 DOSKEY.COM (python rdis.py FILE.COM 100 [more entry points]).
# StevenC & Claude, 2026.  Writes FILE.COM.lst -- keep those out of the repo.
import sys
from capstone import *
d=open(sys.argv[1],'rb').read()
BASE=0x100
entries=[int(x,16) for x in sys.argv[2:]]
md=Cs(CS_ARCH_X86,CS_MODE_16)
code={}   # addr -> insn
todo=list(entries)
labels=set(entries)
while todo:
    a=todo.pop()
    while True:
        if a in code or a<BASE or a>=BASE+len(d): break
        ins=next(md.disasm(d[a-BASE:a-BASE+16],a),None)
        if ins is None: break
        code[a]=ins
        m=ins.mnemonic
        if m.startswith('j') or m=='call' or m=='loop' or m.startswith('loop') or m=='jcxz':
            try:
                t=int(ins.op_str,16); labels.add(t); todo.append(t)
            except: pass
        if m in ('jmp','ret','retf','iret','int3') or (m=='jmp'):
            break
        a+=ins.size
out=[]
a=BASE
while a<BASE+len(d):
    if a in code:
        ins=code[a]
        lab='L%04x:'%a if a in labels else ''
        out.append('%-7s %04x: %-14s %s %s'%(lab,a,ins.bytes.hex(),ins.mnemonic,ins.op_str))
        a+=ins.size
    else:
        s=a
        while a<BASE+len(d) and a not in code and a-s<16: a+=1
        bs=d[s-BASE:a-BASE]
        out.append('        %04x: db %s  |%s|'%(s,bs.hex(' '),''.join(chr(c) if 32<=c<127 else '.' for c in bs)))
open(sys.argv[1]+'.lst','w').write('\n'.join(out))
print(len(code),'insns')
