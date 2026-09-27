"""stage.py -- pack an ANSI.SYS source tree for building on the DOS machine.
StevenC & Claude, 2026.

    python stage.py ms40|src OUT.ZIP

Collects the four ANSI sources and their includes (from SRC, then
ms40\\INC), the message file, the MS-DOS 4.0 build tools and BLD.BAT
into one flat ZIP, converting text to CRLF on the way: Microsoft's
repository stores LF, and MASM 5 and BUILDMSG expect DOS text.
"""
import os, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
MS = os.path.join(HERE, 'ms40')
TEXT = ('.ASM', '.INC', '.SKL', '.LNK', '.MSG', '.BAT')

BLD = r"""@ECHO OFF
REM  Build ANSI.SYS from the MS-DOS 4.0 source with the MS-DOS 4.0 tools.
IF EXIST ANSI.SYS DEL ANSI.SYS
IF EXIST ANSI.EXE DEL ANSI.EXE
IF EXIST *.OBJ DEL *.OBJ
BUILDIDX USA-MS.MSG
BUILDMSG USA-MS ANSI.SKL
MASM -Mx -I. ANSI.ASM,ANSI.OBJ;
MASM -Mx -I. IOCTL.ASM,IOCTL.OBJ;
MASM -Mx -I. ANSIINIT.ASM,ANSIINIT.OBJ;
MASM -Mx -I. PARSER.ASM,PARSER.OBJ;
LINK @ANSI.LNK
EXE2BIN ANSI.EXE ANSI.SYS
IF EXIST ANSI.SYS ECHO ##BUILT
"""


def add(z, path, name=None):
    name = (name or os.path.basename(path)).upper()
    data = open(path, 'rb').read()
    if name.endswith(TEXT):
        data = data.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
    z.writestr(name, data)


def main():
    which, out = sys.argv[1], sys.argv[2]
    src = os.path.join(HERE, which)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for f in ('ANSI.ASM', 'ANSI.INC', 'ANSIINIT.ASM', 'ANSIVID.INC', 'IOCTL.ASM',
                  'PARSER.ASM', 'ANSI.SKL', 'ANSI.LNK'):
            add(z, os.path.join(src, f))
        for d in ('INC', 'TOOLS', 'MESSAGES'):
            for f in sorted(os.listdir(os.path.join(MS, d))):
                own = os.path.join(src, f)          # a file in src\ overrides
                add(z, own if os.path.exists(own) else os.path.join(MS, d, f))
        z.writestr('BLD.BAT', BLD.replace('\n', '\r\n'))
    print('staged', which, '->', out)


if __name__ == '__main__':
    main()
