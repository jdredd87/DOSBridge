# projects/

One folder per project. **This is where your own work goes** — `starter/` is
reserved for the bridge's own tools and worked examples, and it gets copied
into the installer kits.

    python ..\dosctl.py new mandel      (or: dosnew mandel)

creates `mandel/` with a build script, a test script, a starting `.pas` and a
README, plus the `build/` directory its output goes to.

## Why projects exist

Staging used to be a single flat `files/` directory keyed on the filename
alone, so two projects that both produced a `HELLO.EXE` silently overwrote each
other — last writer won, with no warning. DOS 8.3 names leave only eight
characters, far too few to prefix a project name into, so the separation has to
be by directory.

A file under `projects/NAME/` now stages as `NAME/FILE.EXE`. One under
`starter/` stages as `starter/FILE.EXE`, and anything else lands in `local/`.
Asking for a bare name that exists in more than one project is an error that
names the candidates rather than a coin flip.

On the DOS side nothing changed: `C:\WORK` is flat and every job deletes its
target before fetching, so a same-named binary from another project can never
be the one that runs.

## Anywhere but here

Do **not** put sources in `C:\DosBridgeInstaller\`. That entire tree is a
build output — `makeinst.cmd` regenerates it from scratch, and anything
authored there is destroyed without warning. (`installer-src\` in the dev tree
holds the authored installer scripts; that one is real source.)

## Compilers

The bridge only ever needs a path to a `.EXE`, so it does not care what
produced one. The scaffold uses FPC cross-compiling to `i8086-msdos` because
that is what is set up here, but a project is free to use anything that emits a
real-mode DOS binary — Open Watcom on the Windows side, or `TPC`/`TASM` running
natively on the DOS machine itself. Point `build.cmd` at whichever you want and
the rest of the bridge is unchanged.
