r"""keysets.py -- the key scripts DKTEST plays on the real machine.
StevenC & Claude, 2026.

    python keysets.py        writes E.KEY and T.KEY here

E  editing, recall, the template keys, F7 paging, F8, F9: everything 6.22's
   DOSKEY does, so a run is compared with the model of either DOSKEY.
T  TAB completion over the V30's own C:\ and C:\DOS (see TAB_WANT).
Both start with Alt+F7 Alt+F10 so the history and macros are empty, as
they are in the model.
"""
from hwcheck import keybytes

E = [r'{AF7}{AF10}dir c:\dos{CR}', r'echo hello world{CR}', r'type config.sys{CR}',
     r'{UP}{UP}{LEFT}{LEFT}{LEFT}XY{CR}', r'{UP}{HOME}{DEL}{DEL}{INS}ab{END}!{CR}', r'abcdefgh{CR}',
     r'{F1}{F1}{F3}{CR}', r'{F2}e{F4}g{F3}{CR}', r'{F5}zz{F3}{CR}', r'{F6}{CR}',
     r'x{^A}{^B}y{LEFT}{LEFT}{LEFT}{DEL}{CR}', 'r' * 120 + r'{HOME}{CRIGHT}{CEND}{CR}',
     'q' * 100 + r'{HOME}{INS}' + 'abc' * 5 + r'{CR}', r'{PGUP}{CR}', r'{PGDN}{CR}', r'di{F8}{CR}',
     r'{F9}3{CR}{CR}'] + [r'echo line %d{CR}' % i for i in range(30)] + \
    [r'{F7}   ', r'{AF7}{UP}{CR}', r'{F9}{CR}', r'Mixed CASE{CHOME}{CR}', r'end{CR}']

# TAB on the V30's real disk: the keys, and the line they must give
TAB_WANT = [
    (r'{AF7}{AF10}type c:\dos\ansi{TAB}{CR}', r'type c:\dos\ansi.sys'),
    (r'c:\dos\dosk{TAB}{CR}', r'c:\dos\doskey.com'),
    (r'dir c:\dr{TAB}{CR}', 'dir c:\\drivers'),
    (r'dir c:\co{TAB}{TAB}{TAB}{TAB}{TAB}{CR}', r'dir c:\config.sys'),
    (r'dir c:\co{STAB}{CR}', r'dir c:\config.tu0'),        # the tuning's backup sorts last
    (r'TYPE C:\DOS\M{TAB}{TAB}{TAB}{CR}', r'TYPE C:\DOS\MEMMAKER.HLP'),
    (r'type c:\dos\{TAB}{TAB}{TAB}{TAB}{TAB}{TAB}{TAB}{TAB}{TAB}{TAB}{CR}', r'type c:\dos\country.sys'),
    (r'type c:\dos\zzz{TAB}{CR}', r'type c:\dos\zzz'),
    (r'type q:\{TAB}{CR}', 'type q:\\'),
    (r'cd c:\dos\..\t{TAB}{CR}', 'cd c:\\dos\\..\\tape'),
    (r'copy c:\autoexec.bat x{LEFT}{LEFT}{LEFT}{LEFT}{LEFT}{LEFT}{TAB}{TAB}{CR}', r'copy c:\autoexec.dk0 x'),
    (r'type c:\a{TAB}{TAB}{TAB}{STAB}{CR}', 'type c:\\agent'),
    (r'dir c:\dos\x{TAB}{CR}', r'dir c:\dos\xcopy.exe'),
    (r'dir c:\dos\{STAB}{CR}', r'dir c:\dos\xcopy.exe'),
    (r'cd \d{TAB}{CR}', r'cd \dksc'),              # CD takes it: no backslash after
                                                    # (C:\DKSC, DKTEST's own, sorts first)
    (r'dir c:\dr{TAB}\{TAB}{CR}', r'dir c:\drivers\a'),          # into it: C:\DRIVERS\A sorts first
    (r'end{CR}', r'end'),
]
T = [k for k, _ in TAB_WANT]

if __name__ == '__main__':
    open('E.KEY', 'wb').write(b''.join(keybytes(k) for k in E))
    open('T.KEY', 'wb').write(b''.join(keybytes(k) for k in T))
    print('E.KEY %d keys, T.KEY %d lines' % (len(E), len(T)))
