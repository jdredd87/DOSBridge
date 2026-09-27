program Raycast;
{ DOS Bridge  --  StevenC & Claude }
{ A Wolfenstein-style raycaster in unchained VGA mode X, with textured walls.
  Walks itself round a 64x64 maze, or is driven -- from the keyboard, or from
  a script, which is the same thing with nobody at the machine.

  Usage:  RAYCAST              mode X, triple buffered, integer perspective
          RAYCAST INT          force the integer path even with a coprocessor
          RAYCAST FPU          force the 8087 path (refuses if none is fitted)
          RAYCAST SECS 300     run for five minutes instead of one. Up to
                               1800 -- but dosd times a job out at 120s, so
                               anything long needs --timeout raised to match
          RAYCAST SEED 7       a different maze. The world is generated, so
                               the seed is the whole description of it, and
                               it is reported back with the results
          RAYCAST KEYS         drive it from the keyboard. W/S or Up/Down to
                               move, A/D or Left/Right to turn, Q/E to
                               strafe, Shift to run, Esc to quit. Hooks INT 9
                               for key STATE -- see kbd.pas for why the BIOS
                               key buffer cannot do this job
          RAYCAST PLAY F.TXT   drive it from a file of timed events instead.
                               Same movement code, no keyboard, so the KEYS
                               path is testable from Windows where there is
                               nobody to press anything. mkwalk.py writes one
          RAYCAST HOLD         leave the mode set on exit, so VSHOT can see it
          RAYCAST NOWALL       skip the wall columns; NOBAND skips the
                               ceiling and floor. Both render nonsense on
                               purpose -- they exist to be timed against,
                               and are what split the frame into its parts.
          RAYCAST NOPIVOT      cast every column every frame instead of
                               reusing them across a turn on the spot. It
                               was suspected of drawing wrong geometry and
                               measured as not doing so -- see the note on
                               ShiftColumns -- but it is the only one-command
                               A/B available to somebody who can see the
                               screen, so it stays.
          RAYCAST PIVCHK       re-cast every column at the end and report how
                               far the frame had drifted. PIVBAD mis-shifts
                               by one column so PIVCHK can be shown to catch
                               something. NEITHER IS VALIDATED YET: read the
                               note on ShiftColumns first.
          RAYCAST NOSEEK       walk with the old least-visited rule and no
                               flood fill. Same idea: it makes the tour
                               worse on purpose, so that frontier seeking
                               can be priced on one maze in one binary.
          RAYCAST FLAT         solid-colour walls, the way it was before
                               textures. Faster, and the comparison the
                               texture work was measured against.
          RAYCAST QUIET        no music at all
          RAYCAST SPKR         PC speaker instead of the AdLib. One voice, so
                               it plays the melody and drops the harmony.
                               Also the automatic fallback with no OPL2.
          RAYCAST M13          chained mode 13h: one page, so no page flip
          RAYCAST BLOCKY       80 rays at 4px  (what mode X uses anyway)
          RAYCAST COARSE       160 rays at 2px -- implies M13
          RAYCAST FINE         320 rays at 1px -- implies M13, and is slowest

  THE MAZE IS GENERATED AND THE TOUR SEEKS FRONTIERS

  It was a 16x16 literal walked by a greedy least-visited rule, which is a
  good local rule and a hopeless global one -- it saturated at 24 cells of
  256 and tripling the run bought two more. That was fixed once by penalising
  reversal, and the fix does not scale: on 64x64 the greedy runs dry within a
  few steps of wherever it is and then wanders.

  So the tour flood fills to the nearest cell it has not seen whenever the
  greedy has nothing adjacent, and follows the route there.

  WHAT ACTUALLY BOUGHT THE COVERAGE WAS NOT THAT. Measured with NOSEEK,
  which runs the old rule in this same binary on this same maze:

      60 seconds     greedy 154 cells       seeking 154
      10 minutes     greedy 1261            seeking 1300

  Three percent. The gain from 42 cells to 154 was the step clamp in
  Advance -- the walk was overshooting the cell centre and parking the
  camera inside the wall it was about to turn away from, throwing away 48
  of 108 cell choices, and the FASTER it walked the worse that got. The
  flood fill is kept because the greedy rule cannot finish a sweep at all
  (nothing in a four-neighbour comparison can aim at a cell on the far side
  of the maze), and NOT because it covers more ground. That completion
  claim is reasoning; neither run above got near the endgame where it would
  show.

  The other thing that bit: the DDA's side-distance compare was signed,
  which was safe on a 16-cell world only because the sums could not reach
  32767 there.

  MODE X IS THE DEFAULT, AND PAGE FLIPPING IS WHY

  A chained 320x200 screen is 64000 bytes, and only one of those fits in the
  64K window at A000 -- so there is nowhere to build the next frame out of
  sight, and the viewer watches the ceiling go down, then the floor, then the
  walls over the top of both. At nine frames a second that is not a subtle
  artifact; it is most of what you see.

  Unchained, a page is 320*200/4 = 16000 bytes a plane against 65536 fitted,
  so THREE pages fit. Three rather than two on purpose: with two, the page
  drawing moves on to is the one still being displayed until the next
  retrace, so the flip has to WAIT for that retrace -- up to 14 ms out of a
  frame lasting about 90. With three it is two flips old and certainly not on
  screen, so the flip waits for nothing and costs two OUTs.

  Colour only, deliberately. A mono boot will render it as muddy greys rather
  than nothing -- the monitor sums R+G+B and two different colours can land on
  the same shade -- and that is an accepted trade here rather than a second
  palette in every demo. VIDCHK says which way the card came up.

  WHAT COSTS WHAT, AND WHY IT IS SHAPED THIS WAY

  Three numbers out of BENCH decided the whole design:

    32-bit multiply    10920/sec      REP STOSW to video   439821/sec
    32-bit divide       7280/sec      per-pixel MemW[]      58640/sec

  So: no 32-bit arithmetic in any per-column path, and no per-pixel writes
  anywhere. Both rules shape the code more than the raycasting does.

  * NO DIVIDES IN THE DDA. The textbook algorithm divides twice per column to
    get deltaDist = 1/|rayDir|. Both depend only on the ray's ANGLE, so they
    are precomputed once into a table indexed by angle and the per-column cost
    becomes a lookup. What is left in the inner loop is adds and compares.

  * Q8 FIXED POINT, NOT Q10. Q8 is worth a lot more than the extra two bits
    cost: IMUL leaves a 32-bit product in DX:AX, and a >>8 of that is a byte
    shuffle -- AL takes AH, AH takes DL. A >>10 needs a six-round shl/rcl
    chain because the 8086 has no 32-bit shift. See MulQ8.

  * ONE DIVIDE PER COLUMN SURVIVES: the perspective divide, height = k/dist.
    That is the only thing left for a coprocessor to win, and it is what the
    FPU path replaces. Everything else is identical between the two paths.

  * THE BLITTER NEVER TOUCHES A PIXEL. Columns are coalesced into runs with
    the same top, bottom and colour, and each run is drawn as rectangles of
    REP STOSW. Facing a flat wall the whole screen is a handful of rectangles.

  * TWO SCREEN PIXELS PER RAY. Halving the ray count halves the casting and
    makes every run an even number of pixels wide, which is what lets the fill
    be REP STOSW: 439821 words a second against 58640 for per-pixel writes.

    FINE casts all 320. Measured on a V30 at 8 MHz: 4.1 fps against 2.9, so
    the extra 101 ms is very close to the extra casting alone -- once ceiling
    and floor became bands, the ray count stopped affecting the fill at all.
    It looks almost identical, which is the point.

  * CEILING AND FLOOR ARE BANDS, NOT COLUMNS. The second thing measurement
    changed. Coalescing does not rescue narrow runs -- perspective makes wall
    height vary continuously across a flat surface, so 160 rays still produced
    142 runs a frame -- and painting ceiling and floor per column meant the
    whole screen was drawn two pixels at a time. They are now two full-width
    rectangles drawn first, at roughly 1.5 cycles a byte instead of 33, and
    only the wall slices pay the narrow-run price. The walls overdraw part of
    the bands; that is much cheaper than the alternative.

  ON Has186 -- AND WHY THERE IS NO GATED FAST PATH HERE

  There is nothing 186-shaped left to accelerate, and that is a consequence of
  the two decisions above rather than an oversight. The 80186/V30 extension
  that would matter is the shift by an immediate count, and BENCH puts it at
  206260/sec against 185021 through CL -- about 11%, on an operation this
  program deliberately does not perform: Q8 scaling is a byte shuffle, screen
  offsets are computed once per rectangle rather than per pixel, and the fill
  is a string instruction. CLAUDE.md's own guidance is not to gate a fast path
  on a shift alone, because the gate costs more to maintain than the win buys.

  CpuName is still reported, because knowing what it ran on is the point.

  ON THE 8087

  Gated on Cpu.HasFpu, always. An x87 instruction on a machine with no
  coprocessor does NOT fault on an 8086: the CPU decodes the ESC, runs a dummy
  bus cycle and carries on, so the code runs and quietly produces garbage.
  Worse than a crash, because nothing reports it.

  Note the Pascal here never does floating point arithmetic itself. FPC
  compiles Double operations to software routines for this target unless the
  whole program is built -Cfx87, which would make the binary refuse to run on a
  machine without a coprocessor. So the x87 work is hand-written asm and the
  Doubles below are only ever storage.

  WHERE THE FRAME ACTUALLY GOES

  Measured on this V30 with NODRAW and NOCAST, which run the loop with one
  half switched off -- the cheapest honest measurement available, and the one
  that corrected two wrong guesses:

    frame, integer path   256 ms      (3.9 fps)
      casting              93 ms
      drawing             164 ms
    frame, 8087           244 ms      (4.1 fps)

  The 8087 is worth 13 ms, about 5%. That is the whole perspective divide, 160
  of them a frame, going from a software 32-bit divide at 7280/sec to three
  x87 instructions at 34361/sec -- and it is a small share of the frame
  because everything else was already arranged to avoid 32-bit arithmetic.
  Real, measured, and honest: this is not a demo that needs a coprocessor.

  The floor is the fill itself. Two full-screen bands are 64000 pixels at
  REP STOSW, about 73 ms by BENCH and 78 measured, and no arrangement of this
  algorithm writes fewer pixels than the screen has.

  IT REPORTS WHAT IT DID

  Direct writes to A000 never make it back over the bridge, so a program that
  only draws returns an empty log. This prints its stats, the map with the
  path it walked, and an ASCII thumbnail read back out of video memory, so the
  whole run is checkable from Windows without anyone watching the screen. }

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

uses VGA, Cpu, Kbd, Mystery, About;

const
  { THE WORLD IS 64x64, AND 64 IS A CEILING RATHER THAN A ROUND NUMBER.

    Positions are Q8 -- 256 units to a cell -- and they are held in an
    Integer on purpose: a LongInt camera position put a 32-bit shift and a
    32-bit AND into every column of every frame, and on an 8086 both are
    software routines. 64 * 256 = 16384, so the far corner still sits
    comfortably inside an Integer. 128 cells would be 32768 and would not.

    Three other things are tied to this number and will not notice on their
    own if it changes: the DDA's Y-step shift, which is unrolled and has a
    compile-time guard in front of CastColumn that refuses to build, MAXSTEP
    below, and DD_MAX below that. }
  MAPW    = 64;
  MAPH    = 64;
  MAPSHIFT = 6;               { MAPW = 1 shl MAPSHIFT }

  { The DDA's step budget, and the only thing bounding its loop -- there is
    no bounds check in there, by design. It has to exceed the longest walk a
    ray can make across the world, which is MAPW + MAPH steps corner to
    corner; a ray that gave up early would report a hit on whatever cell it
    happened to stop at, and that draws as a wall hanging in mid-air. 128 is
    that diagonal exactly, so this is it with margin. }
  MAXSTEP = 192;
  ANGLES  = 1024;             { full circle; a power of two so wrap is AND }
  QUART   = ANGLES div 4;
  { 160 and not 170, so that FOV/NRays is a whole number of angle units at
    80 and at 160 rays. That is what lets a pure rotation be a SHIFT of the
    column arrays instead of a re-cast -- see the pivot cache below. It costs
    about four degrees of view, which nothing can see. }
  FOV     = 160;
  { Sixteen times the area needs more than sixteen seconds. SECS raises it
    as far as 1800; anything much over a hundred needs dosrun --timeout
    raised to match, because dosd gives up at 120s by default. }
  RUNSECS = 60;

  { Rays cast, and how many screen pixels each one paints. Their product is
    always SCR_W. See the note above: 160x2 is roughly three times the frame
    rate of 320x1 and the picture is hard to tell apart. }
  RAYS_BLOCKY = 80;           { 4 px a ray }
  RAYS_COARSE = 160;          { 2 px a ray -- the default }
  RAYS_FINE   = 320;          { 1 px a ray }

  { Q8 everywhere: 256 units to one map cell. }
  ONE     = 256;

  { --- what the camera can be asked to do ----------------------------- }
  A_FWD    = 0;
  A_BACK   = 1;
  A_LEFT   = 2;
  A_RIGHT  = 3;
  A_SLEFT  = 4;
  A_SRIGHT = 5;
  A_RUN    = 6;
  A_QUIT   = 7;
  NACT     = 8;            { entries in Held[] }

  { A HEADING, NOT A KEY, AND IT EXISTS BECAUSE OF THE FRAME RATE.

    A script says when things happen, so the obvious way to turn a corner in
    one is to hold RIGHT for as long as a right angle takes. That cannot be
    made to work here. A turn is applied once a FRAME, this renders at about
    ten frames a second, and TURNSEC puts 70 angle units in each of them --
    so a 256-unit right angle is 3.66 frames and lands anywhere up to 25
    degrees past where it was aimed. Over the six cells after the corner
    that is most of a cell of drift, and the camera grinds along the wall.

    So a script asks for an absolute heading and the code turns to it, the
    same short-way-round arithmetic the automatic tour uses. Written +EAST,
    +SOUTH, +WEST, +NORTH. Movement is suppressed while the swing is still
    wide, for the reason Advance pivots: turning while moving cuts the
    corner, and cutting the corner puts the camera in the wall. }
  A_FACE   = 8;            { A_FACE + 0..3 are E, S, W, N }
  NNAMED   = 12;           { how many things a script can name }
  MAXEV    = 400;          { events a script may hold }
  { How much room the camera needs around itself, Q8. A corridor is 256
    wide, so 80 leaves 96 units of play -- enough to be steerable, tight
    enough that a diagonal cannot slip through a doorpost. }
  PAD      = 80;

  { The compass. Up here rather than beside the walk, because the maze
    generator steps in cells too and it runs long before the walk does. }
  DirDX : array[0 .. 3] of Integer = (1, 0, -1, 0);   { E, S, W, N }
  DirDY : array[0 .. 3] of Integer = (0, 1, 0, -1);

  { deltaDist is clamped rather than allowed to overflow. A ray running
    almost exactly along an axis has a near-infinite step on the other one,
    and the clamp only has to be big enough that the ray leaves the world
    before that axis could ever step again: 24000 in Q8 is 93 cells, against
    a 90-cell diagonal.

    IT CAME DOWN FROM 32000 WHEN THE MAP GREW, AND ITS PAIRING WITH THE
    UNSIGNED COMPARE IN THE DDA IS THE POINT. Side distances accumulate in a
    16-bit register, and the worst case is a ray that crosses the whole
    world -- 90 cells, 23040 -- and then takes one step on the clamped axis:
    23040 + 24000 = 47040. That fits a Word and does NOT fit an Integer,
    which is why the DDA compares them with `jae` and not `jge`. On the old
    16x16 map the sum could not reach 32767 whatever the maze looked like,
    so the signed compare there was safe by accident of the size rather than
    by anything the code said.

    The hit distance itself is never one of the big values: the DDA always
    steps the SMALLER side, so the axis that terminates is bounded by the
    ray length, and that is the one the tail reads back. }
  DD_MAX  = 24000;

  { Closest the wall may be before the perspective divide. 32 in Q8 is an
    eighth of a cell and gives a height of 1600 -- comfortably inside an
    Integer, which is what FISTP needs it to be. }
  PERP_MIN = 32;

  { --- the maze ------------------------------------------------------- }

  { GENERATED, NOT WRITTEN OUT. 64x64 as a literal is 4096 characters
    nobody can check by eye, and a generator gives SEED for free -- a
    different world out of the same binary, which is what makes a
    performance number reproducible AND lets a bad case be re-run.

    Cells live on the ODD coordinates and the wall between two of them is
    the even cell they straddle, so a 64-wide map holds 31 cells across:
    1, 3 .. 61, with 62 and 63 left as border. Nothing ever carves the outer
    ring, and that is what makes the DDA's missing bounds check safe. }
  CELLW = (MAPW - 2) div 2;
  CELLH = (MAPH - 2) div 2;

  { How many interior walls to knock back out after carving, in 256ths.

    A recursive backtracker produces a PERFECT maze -- exactly one route
    between any two cells -- and that is the wrong shape for something whose
    whole job is to be walked and looked at. Every junction is a fork into a
    dead end, so a tour spends most of its time retracing corridors it has
    already seen, and the view is a wall two cells away in every direction.
    Knocking a fraction of the walls out makes loops, which give the walk
    somewhere to go and the camera something to look down. }
  { 64/256 and not 40. More than loops: a braided wall is also a STRAIGHT
    run, and the walk pays 256/TURNSEC of pivot at every corner it does not
    get. At 16% the carve's own twistiness dominated the tour. }
  BRAID = 64;                 { 64/256, a quarter }

  { Palette indices. Ordered by brightness on purpose: the ASCII thumbnail
    ranks by this order, and a picture ranked by anything else reads as noise
    rather than a picture. }
  C_CEIL  = 1;
  C_FLOOR = 2;
  C_DARK  = 4;      { wall types 1..3, shaded side, at 4..6 }
  C_LIT   = 8;      { wall types 1..3, lit side,    at 8..10 }

  { --- textures ------------------------------------------------------- }

  { 64x64, and STORED COLUMN-MAJOR -- texel (X,Y) lives at X*TEXH + Y.

    That transpose is the whole reason a textured column is affordable. A
    wall slice reads one texture COLUMN top to bottom, so column-major makes
    those 64 texels contiguous and the inner loop indexes them with a single
    byte: BL walks 0..63 while SI holds the column base, and `mov al,[bx+si]`
    is one instruction. Row-major would need a multiply or a 64-byte stride
    per texel, in the hottest loop in the program.

    Four textures rather than two: the lit and shaded copies of each wall
    type are baked separately so the inner loop does no shading arithmetic
    at all. It costs 8 KB of a machine with 545 KB free, and buys an add per
    pixel. }
  TEXW    = 64;
  TEXH    = 64;
  TEXSZ   = TEXW * TEXH;
  { A bank is padded by TEXH so the blitter's deliberate one-texel overrun
    stays inside it -- see XTexCol. }
  BANKSZ  = TEXSZ + TEXH;
  { (2 wall types) x (4 shades). The four shades are DISTANCE bands, with
    the wall's facing folded in as one extra step of darkening -- so a far
    wall and a side-on near wall can land on the same bank and the whole
    thing costs one bank index per column and nothing per pixel.

    Fog is the cheapest depth cue available here. Textured floors and
    ceilings are the expensive one: they need a 2D texture coordinate, so
    the inner loop carries two accumulators and builds the index out of both
    high bytes -- about 24 bytes a pixel against 7.25 for a wall, over twice
    as many pixels. That is roughly 400 ms a frame on this box, which is why
    Wolfenstein had flat floors and Doom did not. }
  NTEX    = 8;
  NSHADE  = 4;              { distance bands per wall type }

  { Palette region for textures: 16 levels each, 64..127. Kept above the
    flat-colour entries so FLAT and TEX can share one palette and be compared
    without a reload. }
  TEXBASE = 64;
  TEXLVL  = 16;

  { Above the wall banks: 16 levels of ceiling and 16 of floor, so the bands
    can be shaded by row. 64 + 8*16 = 192, and 192 + 32 = 224, which leaves
    the DAC's last 32 entries spare. }
  CEILBASE = TEXBASE + NTEX * TEXLVL;
  FLOORBASE = CEILBASE + TEXLVL;

type
  TQ8 = Integer;
  { A scripted input event: when, which intention, and pressed or released. }
  TEvent = record
    T   : Integer;       { tenths of a second from the first frame }
    Act : Byte;
    Dn  : Boolean;
  end;
  { Flood-fill scratch, one entry per map cell. On the heap and not in the
    data segment: three of these is 16 KB on top of the ~40 KB of angle and
    texture tables already in DGROUP, and the heap has half a megabyte. }
  TIdxArr  = array[0 .. MAPW * MAPH - 1] of Word;
  TCellArr = array[0 .. MAPW * MAPH - 1] of Byte;

var
  { --- per-angle tables, built once ---------------------------------- }
  SinT  : array[0 .. ANGLES - 1] of Integer;   { Q14 }
  DDX   : array[0 .. ANGLES - 1] of Integer;   { Q8, 1/|cos| }
  DDY   : array[0 .. ANGLES - 1] of Integer;   { Q8, 1/|sin| }
  StpX  : array[0 .. ANGLES - 1] of Integer;   { +1 / -1 }
  StpY  : array[0 .. ANGLES - 1] of Integer;
  { The ray direction in Q8, for working out WHERE on the wall a ray landed.
    SinT/CosT are Q14, and shifting them down per column would be a shift by
    CL of 6 -- about 32 cycles on an 8086 -- so the shifted copy is a table
    like everything else here. }
  DirX8 : array[0 .. ANGLES - 1] of Integer;
  DirY8 : array[0 .. ANGLES - 1] of Integer;
  { Whether the texture runs backwards on the face this ray hits. It depends
    only on which way the ray steps, so it is a property of the angle -- and
    holding it as a MASK rather than a flag makes the flip branchless:
    255 - U and U xor 255 are the same thing for a byte. }
  FlipY : array[0 .. ANGLES - 1] of Word;      { for an x-side hit }
  FlipX : array[0 .. ANGLES - 1] of Word;      { for a y-side hit }

  { --- per-ray tables, built once ------------------------------------ }
  NRays  : Integer;                            { 160, or 320 with FINE }
  RayStep : Integer;        { angle units between neighbouring rays }
  CanShift: Boolean;        { ...and it divides exactly, so a turn can shift }
  Moved   : Boolean;        { the camera changed POSITION this step }
  AngDelta: Integer;        { and how far it turned }
  PxW    : Integer;                            { screen pixels per ray }
  ColAng : array[0 .. SCR_W - 1] of Integer;   { offset from the view angle }
  ColCos : array[0 .. SCR_W - 1] of Integer;   { Q8, the fisheye correction }

  { Camera cell and fractional position. Computed ONCE a frame, not once a
    column: they depend only on where the camera is, and every ray in the
    frame starts from the same place. They were inside CastColumn, which meant
    two shifts, a multiply and two ANDs repeated 160 times a frame for an
    answer that never changed. }
  CamMX, CamMY : Integer;
  CamIdx       : Integer;
  FracX, FracY : Integer;      { position within the cell, 0..255 }
  RestX, RestY : Integer;      { 256 - Frac, i.e. distance to the next line }

  { --- the frame being assembled ------------------------------------- }
  ColTop : array[0 .. SCR_W - 1] of Integer;
  ColBot : array[0 .. SCR_W - 1] of Integer;
  ColCol : array[0 .. SCR_W - 1] of Byte;
  { --- per-column texture state, filled by the cast, read by the blitter -- }
  { ONE offset, not a bank index plus a column index.

    These arrays are the most expensive thing the cast does -- measured, the
    texture setup costs 10.5 ms a frame, 131 us a column, and most of it is
    these stores plus the reads the draw loop then does to put the pieces
    back together. Baking the bank offset and the column offset into a single
    Word at cast time removes one store here and three array reads plus an
    add from every column of the draw loop. }
  ColOfs : array[0 .. SCR_W - 1] of Word;    { offset of the texture column }
  ColV0  : array[0 .. SCR_W - 1] of Word;    { first texel row, Q8 }
  ColVs  : array[0 .. SCR_W - 1] of Word;    { texel rows per screen row, Q8 }

  { The texture bank. Column-major, holding FINAL palette indices -- see the
    note by TEXW. }
  { TEXSZ + TEXH, not TEXSZ: the blitter deliberately does not mask the
    texel index (see XTexCol), so the bottom row of a slice can read up to
    TEXH bytes past its column. Inside the bank that lands on the next
    column and is one invisible pixel; off the end of the LAST column it
    would be somebody else's memory. 256 bytes of padding settles it. }
  { The pattern, as brightness LEVELS 0..15, one per wall type. The banks
    below are baked from it. }
  Pat    : array[0 .. 1] of array[0 .. BANKSZ - 1] of Byte;

  { All eight banks in ONE heap block, so they share a segment and a column
    is reachable by offset alone.

    33 KB would not fit in the data segment beside ~40 KB of tables, and the
    blitter has always taken a segment and an offset rather than a Pascal
    pointer, so heap allocation costs nothing here. One block rather than
    eight is what lets ColOfs above be a single number. }
  TexBlk : Pointer;
  Textured : Boolean;                        { TEX, or FLAT for the old look }
  { Resolved once, because Seg()/Ofs() per column would be per-pixel work
    moved into the frame for no reason. }
  TexSegG  : Word;      { segment of the whole bank block }
  TexOfs0  : Word;      { offset of bank 0 within it, after normalising }
  { Offset of each bank, precomputed. BANKSZ is 4160 and NOT a power of two,
    so `bank * BANKSZ` in the cast is a real 16-bit multiply -- about 17 us,
    which measured WORSE than the array store it was meant to replace. A
    lookup makes it an add. }
  BankOfs  : array[0 .. NTEX - 1] of Word;

  { Row -> shade level for the floor and ceiling bands. A row below the
    horizon is a constant distance from the camera, so this depends only on
    the geometry and is built once. }
  RowShade : array[0 .. SCR_H - 1] of Byte;

  { --- camera --------------------------------------------------------- }
  { Q8, and Integer rather than LongInt on purpose. The world is 16 cells, so
    4096 units, nowhere near Integer's range -- and a LongInt here put a
    32-bit shift and a 32-bit AND in every column of every frame, which on an
    8086 are software routines. }
  PosX, PosY : Integer;
  Ang        : Integer;        { 0 .. ANGLES-1 }
  { The map as flat bytes. Indexing an array of ShortString meant a multiply
    and a function call per DDA step; this is one byte fetch. }
  Grid       : array[0 .. MAPW * MAPH - 1] of Byte;
  OpenCells  : Integer;        { how many of them the carve left walkable }

  { --- maze generator scratch ----------------------------------------- }
  MazeSeed : Word;
  { The seed AS GIVEN. MazeSeed is the live LCG state and BuildGrid runs it
    a few thousand times, so by the time anything reports it it is a
    different number -- and a reported seed that does not reproduce the maze
    is worse than not reporting one. }
  MazeSeed0 : Word;
  MzSeen   : array[0 .. CELLW * CELLH - 1] of Byte;
  MzStack  : array[0 .. CELLW * CELLH - 1] of Word;

  { --- options and results -------------------------------------------- }
  UseFpu   : Boolean;
  Hold     : Boolean;
  { Phase isolation, for finding out where the frame time actually goes.
    Guessing produced two wrong answers about the SVGA demo and two more here;
    running the loop with one half switched off is the cheapest honest
    measurement available and needs no profiler. }
  NoDraw   : Boolean;
  NoCast   : Boolean;
  Quiet    : Boolean;
  WantSpk  : Boolean;          { force the PC speaker over any OPL2 }
  WantX    : Boolean;          { asked for unchained mode X }
  XFail    : Integer;          { which readback check refused, 0 = none }
  XSeen    : array[1 .. 4] of Byte;   { what each one actually read }
  UseX     : Boolean;          { ...and the card actually unchained }
  Budget   : LongInt;          { ticks }
  Frames   : LongInt;
  ColsCast : LongInt;
  RectsHit : LongInt;
  StepsDDA : LongInt;
  Reused   : LongInt;      { columns a pivot got for free }
  { --- temporary instrumentation ------------------------------------- }
  NoWall   : Boolean;      { skip the wall columns, keep everything else }
  NoBand   : Boolean;      { skip the ceiling/floor bands }
  { Turn the flood fill off and leave the greedy rule on its own, so that
    the two can be compared in ONE binary on ONE maze. Without it the
    frontier work would be a claim backed by a run of a different build on
    a different maze, which is exactly the comparison this file keeps
    having to retract. }
  NoSeek   : Boolean;
  { The pivot cache, ON as it always was. NOPIVOT disables it -- which is
    worth having whether or not it is ever at fault, because it is the only
    one-command A/B available to somebody who can actually see the screen. }
  UsePivot : Boolean;
  { Print the column arrays at the end of the run. The ASCII thumbnail is a
    16x64 downsample through a ten-level shade ramp, which is far too blunt
    to answer a question about a few percent of wall height -- it showed the
    cached and the freshly cast frame as byte-identical. Numbers do not. }
  DumpCol  : Boolean;
  { Re-cast every column at the end of the run and report how far the frame
    on screen had drifted from what a fresh cast produces. Comparing two
    RUNS cannot answer this -- they end at slightly different angles and the
    ASCII thumbnail is far too coarse -- but comparing a frame against a
    re-cast of ITSELF has no confound in it at all. }
  PivChk   : Boolean;
  { Shift the cache by ONE COLUMN TOO MANY, on purpose. A null result from
    PIVCHK is only worth having if PIVCHK can fail, and this is what proves
    it can: a deliberately mis-shifted cache must show up as a non-zero
    drift, or the check is measuring nothing. }
  PivBad   : Boolean;
  RowsBy1  : LongInt;      { wall rows drawn by each sampling path }
  RowsBy2  : LongInt;
  RowsBy4  : LongInt;
  Blocked  : LongInt;
  OldMode  : Byte;
  Visited  : array[0 .. MAPH - 1, 0 .. MAPW - 1] of Byte;   { visit counts }
  TgtX     : Integer;      { cell being walked to }
  TgtY     : Integer;
  Dir      : Integer;      { 0..3, indexes DirDX/DirDY }
  HaveTgt  : Boolean;
  Turns    : LongInt;      { cells chosen }

  { --- being driven, rather than walking itself ----------------------- }
  { ONE SET OF INTENTIONS, TWO THINGS THAT CAN SUPPLY THEM. The keyboard
    fills this in from held keys; a script fills exactly the same array
    from a file of timed events. Steer below cannot tell which, and that is
    the point: the movement code gets tested over the bridge, where there
    is nobody at the keyboard, by the same path a person drives. A camera
    control nobody can test from Windows is a camera control that is
    verified by hope. }
  Held     : array[0 .. NACT - 1] of Boolean;
  Driven   : Boolean;      { KEYS or PLAY: do not walk the maze by itself }
  Playing  : Boolean;      { ...and the input is a script, not a keyboard }
  Hooked   : Boolean;      { the INT 9 vector is ours }
  ScrName  : ShortString;
  Ev       : array[0 .. MAXEV - 1] of TEvent;
  NEv      : Integer;
  EvPtr    : Integer;
  FaceGoal : Integer;      { 0..3, or -1 for "no heading asked for" }
  Quitting : Boolean;

  { --- exploration ---------------------------------------------------- }
  { Visited holds the SWEEP NUMBER a cell was last walked in, not a count,
    and 0 still means never. A cell is stale when its number is below Gen,
    so finishing the maze is one increment of Gen rather than a pass that
    clears 4096 bytes -- which matters because the coverage report wants to
    know what was EVER reached, and clearing would throw exactly that away. }
  Gen      : Integer;
  Sweeps   : LongInt;      { complete coverages }
  SweepTix : LongInt;      { ticks to the first one, 0 = never finished }
  Seeks    : LongInt;      { flood fills run }
  SeekMiss : LongInt;      { ...that found nothing, i.e. sweeps completed }
  { How MANY times each cell was walked. Visited holds the sweep number, so
    it cannot answer this -- and the old greedy rule graded on the count,
    which is the whole reason it did not simply oscillate. Keeping it means
    NOSEEK compares against the rule as it really was rather than against a
    version of it with its gradient removed. One increment per cell
    arrival, which is three times a second. }
  VisitN   : ^TCellArr;
  BfsQ     : ^TIdxArr;     { the frontier queue }
  BfsFrom  : ^TCellArr;    { 0 = unreached, 5 = the start, else 1 + dir }
  Path     : ^TCellArr;    { directions to the goal, LAST one first }
  PathLen  : Integer;
  OnPath   : Boolean;      { this step came off Path and not off the greedy }
  RunStart : LongInt;

  { --- 8087 storage. All storage, no Pascal arithmetic. ---------------- }
  FPerpI   : Integer;
  FHeightI : Integer;

const
  { SCR_H * 256: height = (SCR_H * 256) / perpDist, with perpDist in Q8. }
  F_NUM : Double = 51200.0;

{ ---------------------------------------------------------------------- }
{  Fixed point                                                            }
{ ---------------------------------------------------------------------- }

{ (A * B) >> 8, with the 32-bit product never leaving DX:AX.

  The >>8 is the reason this suite uses Q8. IMUL puts the product in DX:AX,
  and taking bits 8..23 is two register moves. The Pascal it replaces,
  Integer((LongInt(A) * B) div 256), calls FPC's software 32-bit multiply and
  divide -- 10920 and 7280 a second against 58640 for the 16-bit IMUL. }
{ Kept for callers outside the cast loop. Inside it the three uses are
  written out by hand -- see CastColumn for the measurement that forced
  that, and for why `inline` here does nothing. }
function MulQ8(A, B: TQ8): TQ8; assembler;
asm
  mov ax, A
  imul word ptr B
  mov al, ah
  mov ah, dl
end;

{ ---------------------------------------------------------------------- }
{  Tables                                                                 }
{ ---------------------------------------------------------------------- }

{ sin, one quarter turn of it, by Taylor series in Q16.

  Four terms is accurate to about 1e-6 over 0..pi/2, which is far finer than
  the Q14 it is stored in. This runs 257 times at startup and never again, so
  it is the one place LongInt arithmetic is not worth avoiding. }
procedure BuildSin;
var
  I            : Integer;
  T, T2, T3, S : LongInt;
  Q            : array[0 .. QUART] of Integer;
begin
  for I := 0 to QUART do
  begin
    { t = i * (pi/2) / QUART, in Q16. pi/2 is 102944 in Q16. }
    T  := (LongInt(I) * 102944) div QUART;
    T2 := (T * T) shr 16;
    T3 := (T2 * T) shr 16;
    S  := T - T3 div 6;
    T3 := (T3 * T2) shr 16;          { t^5 }
    S  := S + T3 div 120;
    T3 := (T3 * T2) shr 16;          { t^7 }
    S  := S - T3 div 5040;
    if S > 65536 then S := 65536;
    Q[I] := S shr 2;                 { Q16 -> Q14 }
  end;

  for I := 0 to ANGLES - 1 do
  begin
    if I <= QUART then
      SinT[I] := Q[I]
    else if I <= 2 * QUART then
      SinT[I] := Q[2 * QUART - I]
    else if I <= 3 * QUART then
      SinT[I] := -Q[I - 2 * QUART]
    else
      SinT[I] := -Q[ANGLES - I];
  end;
end;

function CosT(A: Integer): Integer;
begin
  CosT := SinT[(A + QUART) and (ANGLES - 1)];
end;

{ deltaDist for every angle: how far along the ray one whole cell of X (or Y)
  costs. This is the divide the textbook algorithm does twice per column, done
  once per angle instead -- 1024 divides at startup against 640 per frame. }
procedure BuildRays;
var
  I, C, S : Integer;
  V       : LongInt;
begin
  for I := 0 to ANGLES - 1 do
  begin
    C := CosT(I);
    S := SinT[I];

    if C >= 0 then StpX[I] := 1 else StpX[I] := -1;
    if S >= 0 then StpY[I] := 1 else StpY[I] := -1;
    DirX8[I] := C div 64;        { Q14 -> Q8, and div so it rounds toward }
    DirY8[I] := S div 64;        { zero on negatives rather than away }
    if StpX[I] > 0 then FlipY[I] := 255 else FlipY[I] := 0;
    if StpY[I] < 0 then FlipX[I] := 255 else FlipX[I] := 0;

    if C = 0 then DDX[I] := DD_MAX
    else
    begin
      V := (LongInt(ONE) * 16384) div Abs(C);
      if V > DD_MAX then V := DD_MAX;
      DDX[I] := V;
    end;

    if S = 0 then DDY[I] := DD_MAX
    else
    begin
      V := (LongInt(ONE) * 16384) div Abs(S);
      if V > DD_MAX then V := DD_MAX;
      DDY[I] := V;
    end;
  end;
end;

{ Per-column ray offset, and the cosine that undoes the fisheye.

  Casting a ray per screen column at evenly spaced ANGLES gives Euclidean
  distance, and drawing a wall from that bows it towards the viewer. The fix
  is one multiply by cos(offset), and the offset is fixed per column, so the
  cosine is a table too. }
procedure BuildColumns;
var
  X : Integer;
begin
  PxW := SCR_W div NRays;
  RayStep  := FOV div NRays;
  CanShift := (RayStep >= 1) and (RayStep * NRays = FOV);
  for X := 0 to NRays - 1 do
  begin
    ColAng[X] := (X - (NRays div 2)) * RayStep;
    ColCos[X] := CosT(ColAng[X] and (ANGLES - 1)) shr 6;   { Q14 -> Q8 }
    if ColCos[X] < 1 then ColCos[X] := 1;
  end;
end;

{ ---------------------------------------------------------------------- }
{  The perspective divide -- the only place the two paths differ          }
{ ---------------------------------------------------------------------- }

function HeightInt(Perp: TQ8): Integer;
begin
  HeightInt := Integer((LongInt(SCR_H) * ONE) div Perp);
end;

{ The same sum on the 8087. FILD converts the Q8 distance on the coprocessor,
  so no integer-to-float conversion happens in Pascal and no soft-float
  routine is linked.

  Ordinary WAIT-prefixed forms, which is correct here: each waits for the
  coprocessor to go idle before issuing, so back-to-back operations
  synchronise. That is the opposite of the detection code in cpu.pas, which
  must use the FN forms precisely because it cannot assume anything answers. }
function HeightFpu(Perp: TQ8): Integer;
begin
  FPerpI := Perp;
  asm
    fild  FPerpI
    fdivr F_NUM
    fistp FHeightI
    fwait
  end;
  HeightFpu := FHeightI;
end;

{ ---------------------------------------------------------------------- }
{  The blitter                                                            }
{ ---------------------------------------------------------------------- }

{ A filled rectangle, one REP STOSW per row.

  Words, not bytes, and the width is guaranteed even because every run is a
  whole number of rays and each ray is PxW pixels wide. That halves the REP
  iterations, and BENCH puts REP STOSW at 439821 a second against 58640 for
  per-pixel MemW[] -- the same lesson that doubled the bouncing-ball frame
  rate, applied to the one routine that touches every pixel on the screen.

  W arrives in PIXELS and is halved here, so callers never have to remember.
  The screen offset arrives already computed, so there is no multiply and no
  shift in the row loop at all. }
procedure FillRect(Ofs, W, H: Word; Col: Byte); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  dx, H
  mov  bx, W
  shr  bx, 1                 { pixels -> words }
  mov  al, Col
  mov  ah, al                { one word paints two pixels }
  cld
@row:
  or   dx, dx
  jz   @done
  mov  cx, bx
  push di
  rep  stosw
  pop  di
  add  di, SCR_W
  dec  dx
  jmp  @row
@done:
  pop  di
  pop  es
end;

{ ---------------------------------------------------------------------- }
{  Unchained mode X, 320x200                                              }
{                                                                         }
{  Why this is not in modex.pas: that unit is built for the scroller and  }
{  hardwires a 1024-pixel virtual screen (VW, VWB, PGSZ, and a CRTC       }
{  Offset of 128). Parameterising it would put the scroller's verified    }
{  70 fps at the mercy of edits made for this demo, so the four registers }
{  are set here instead. They are four registers.                         }
{                                                                         }
{  What it buys: with the map mask at $0F one byte write paints FOUR      }
{  horizontal pixels, so clearing the screen is 16000 writes instead of   }
{  64000 -- and the band clear was measured as the floor of the mode 13h  }
{  version at 78 ms. What it costs: columns must be four pixels wide to   }
{  stay plane-aligned, so 80 rays, and VSHOT cannot photograph an         }
{  unchained mode -- the thumbnail has to read back through Read Map      }
{  Select the way scroller.pas does.                                      }
{ ---------------------------------------------------------------------- }

const
  XW    = SCR_W div 4;         { 80 bytes a row, one per four pixels }
  HALF  = SCR_H div 2;         { the horizon }

  { Unchained, a page is 320*200/4 = 16000 bytes a plane and the card has
    65536, so THREE pages fit with room to spare. Two would do for double
    buffering, but then the page we start drawing is the one still on screen
    until the next retrace -- so the flip would have to WAIT for that retrace,
    up to 14 ms out of a frame lasting about 90. With three, the page we move
    on to is two flips old and certainly not being displayed, so the flip
    costs nothing and waits for nothing. The third page is memory that was
    sitting idle anyway. }
  PAGE_SZ = XW * SCR_H;
  NPAGES  = 3;
  SC_IX = $3C4;  SC_DA = $3C5;
  GC_IX = $3CE;  GC_DA = $3CF;
  CR_IX = $3D4;  CR_DA = $3D5;

{ Break the chain. Read every register back rather than trusting the write:
  a card that ignores one leaves a picture that is skewed rather than absent,
  which is a confusing way to spend an afternoon. }
function XEnter: Boolean;
var
  V: Byte;
begin
  XEnter := False;
  SetMode(MODE13);

  OutB(SC_IX, 4); OutB(SC_DA, $06);          { chain-4 off }
  OutB(SC_IX, 4); V := InB(SC_DA);
  XSeen[1] := V;
  if (V and $08) <> 0 then begin XFail := 1; Exit; end;

  OutB(CR_IX, $14); OutB(CR_DA, 0);          { doubleword off }
  OutB(CR_IX, $14); V := InB(CR_DA);
  XSeen[2] := V;
  if (V and $40) <> 0 then begin XFail := 2; Exit; end;

  OutB(CR_IX, $17); V := InB(CR_DA);
  OutB(CR_DA, V or $40);                     { byte mode on }
  OutB(CR_IX, $17); V := InB(CR_DA);
  XSeen[3] := V;
  if (V and $40) = 0 then begin XFail := 3; Exit; end;

  OutB(CR_IX, $13); OutB(CR_DA, SCR_W div 8);
  OutB(CR_IX, $13); V := InB(CR_DA);
  XSeen[4] := V;
  if V <> (SCR_W div 8) then begin XFail := 4; Exit; end;

  XFail := 0;
  XEnter := True;
end;

procedure MapMask(M: Byte);
begin
  OutB(SC_IX, 2); OutB(SC_DA, M);
end;

var
  DrawBase : Word;                          { page being drawn into }
  ShowBase : Word;                          { page last handed to the CRTC }
  CurPage  : Integer;
  { Rows this page's previous frame put walls into. Everything outside that
    band is still the right ceiling or floor colour from two frames ago. }
  PgTop    : array[0 .. NPAGES - 1] of Integer;
  PgBot    : array[0 .. NPAGES - 1] of Integer;
  FlipWait : LongInt;                       { times the display guard ran out }

{ Show a page. The start address is in the units modex.pas uses for the
  scroller -- one address is one byte a plane, which is four pixels, and is
  why ShowAt there does PixX shr 2. A page offset is already in those units.

  Both halves are written inside active display so the CRTC cannot latch a
  start address that is half old and half new. There is deliberately NO wait
  for the retrace afterwards: it latches there by itself, and with three
  pages nothing we are about to draw is on screen. }
procedure XSetStart(Addr: Word);
var
  Guard : Word;
begin
  Guard := 0;
  while ((InB($3DA) and 1) <> 0) and (Guard < 60000) do Inc(Guard);
  if Guard >= 60000 then Inc(FlipWait);
  OutB(CR_IX, $0C); OutB(CR_DA, Hi(Addr));
  OutB(CR_IX, $0D); OutB(CR_DA, Lo(Addr));
end;

{ A full-width band. Rows are 80 bytes and the stride is 80, so a full-width
  rectangle is one UNBROKEN block -- no row loop at all, one REP STOSW for
  the lot. BENCH puts REP STOSW at 439821 a second against 58640 for
  per-element stores, and this is the one fill that can use it properly. }
procedure XFillFull(Ofs, Rows: Word; Col: Byte); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  ax, Rows
  mov  bx, XW / 2
  mul  bx                      { rows * 40 words }
  mov  cx, ax
  mov  al, Col
  mov  ah, al
  cld
  jcxz @done
  rep  stosw
@done:
  pop  di
  pop  es
end;

{ Full-width rows, each taking its colour from RowShade. This is what turns
  the flat ceiling and floor into a distance gradient, and it is very nearly
  free: rows are 80 bytes and the stride is 80, so DI walks straight on and
  `REP STOSW` never restarts -- the only per-row cost is the table lookup and
  a fresh CX. One call does the whole band, because 200 Pascal calls a frame
  at ~30 us each would cost more than the gradient.

  Note BP is never touched here, so the parameters stay reachable throughout
  -- unlike XTexCol, which has to read all six before it can use BP. }
procedure XFillRows(Ofs, Y0, Rows, Base: Word); assembler;
asm
  push es
  push di
  push si
  push bp
  mov  dx, Rows
  or   dx, dx
  jnz  @@go
  jmp  @@done
@@go:
  mov  di, Ofs
  mov  si, Y0
  mov  bx, Base                { BL is the ramp base; BH is scratch below }
  mov  ax, VGA_SEG
  mov  es, ax
  mov  bp, dx                  { BP counts rows down; DX is needed by MUL }
  cld
  { RUNS OF EQUAL SHADE, NOT ONE REP PER ROW.

    RowShade has 16 levels spread over 100 rows, so about six consecutive
    rows share a colour -- and rows are 80 bytes with an 80-byte stride, so
    those six are one unbroken block. Restarting REP STOSW per row was
    costing about 21 us a row in setup for no reason; this pays it once per
    run instead, roughly a sixth as often. The gradient is unchanged: this
    is the same bytes, written in longer pieces. }
@@run:
  mov  bh, RowShade[si]
  xor  cx, cx
@@count:
  inc  cx
  inc  si
  dec  bp
  jz   @@emit
  cmp  bh, RowShade[si]
  je   @@count
@@emit:
  mov  ax, cx
  mov  dx, XW / 2
  mul  dx                      { rows * 40 words; under 8000, so DX comes back 0 }
  mov  cx, ax
  mov  al, bh
  add  al, bl
  mov  ah, al
  rep  stosw
  or   bp, bp
  jnz  @@run
@@done:
  pop  bp
  pop  si
  pop  di
  pop  es
end;

{ One byte a row, strided: a four-pixel-wide wall slice, which is what nearly
  every run actually is.

  No REP, and that is the whole reason this exists apart from the rectangle
  fill. REP STOSB for a SINGLE byte pays the string setup -- about 20 cycles
  -- to move one byte, and the general rectangle fill was doing exactly that
  once per row for every wall on the screen. A plain store plus a stride is
  about half the cost, and unrolling by two amortises the loop over two
  rows. }
procedure XFillCol1(Ofs, Rows: Word; Col: Byte); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  dx, Rows
  mov  al, Col
  or   dx, dx
  jz   @done
  test dx, 1
  jz   @pairs
  mov  byte ptr es:[di], al
  add  di, XW
  dec  dx
  jz   @done
@pairs:
  mov  byte ptr es:[di], al
  mov  byte ptr es:[di + XW], al
  add  di, XW * 2
  sub  dx, 2
  jnz  @pairs
@done:
  pop  di
  pop  es
end;

{ Two bytes a row: eight pixels, and one 16-bit store covers both. Runs two
  rays wide happen constantly on a flat wall. }
procedure XFillCol2(Ofs, Rows: Word; ColW: Word); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  dx, Rows
  mov  ax, ColW
  or   dx, dx
  jz   @done
  test dx, 1
  jz   @pairs
  mov  word ptr es:[di], ax
  add  di, XW
  dec  dx
  jz   @done
@pairs:
  mov  word ptr es:[di], ax
  mov  word ptr es:[di + XW], ax
  add  di, XW * 2
  sub  dx, 2
  jnz  @pairs
@done:
  pop  di
  pop  es
end;

{ A rectangle three or more bytes wide, all four planes at once. Ofs is an
  absolute byte offset -- the caller adds the page base, because with three
  pages in play the routine has no business guessing which one. BW is bytes a
  row; one byte is four pixels. Anything narrower goes to XFillCol1/2, which
  is where the wall slices actually end up. }
procedure XFillRect(Ofs, BW, Rows: Word; Col: Byte); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  dx, Rows
  mov  bx, BW
  mov  al, Col
  cld
@row:
  or   dx, dx
  jz   @done
  mov  cx, bx
  push di
  rep  stosb
  pop  di
  add  di, XW
  dec  dx
  jmp  @row
@done:
  pop  di
  pop  es
end;

{ ONE TEXTURED WALL COLUMN, mode X: one byte a row, four pixels wide.

    Ofs     screen byte offset of the top row
    Rows    how many rows to draw
    TSeg    segment of the texture bank
    TOfs    offset of THIS column within it -- already col*TEXH
    V       texture coordinate, Q8: DH is the texel row
    VStep   texels per screen row, Q8

  Two things make this as cheap as a textured column gets on an 8086.

  The texture is column-major, so the 64 texels this slice needs are
  contiguous and `mov al,[bx+si]` reaches any of them with BL alone -- no
  multiply, no stride. And DS is pointed at the texture bank for the duration
  so the load needs no segment override, while the screen write uses ES. That
  is why DS is saved and restored here rather than the caller passing a
  pointer: with -WmLarge the bank is far data and the load would otherwise
  cost an override byte on every pixel.

  `and bl,63` is the safety on V overrunning the column. VStep is derived
  from the wall height so the arithmetic should land exactly on 64 at the
  bottom row, but rounding can put it one over, and reading past the column
  would show the neighbouring texture's top pixel. Four cycles a row to not
  have to reason about that. }
procedure XTexCol(Ofs, Rows, TSeg, TOfs, V, VStep: Word); assembler;
asm
  push ds
  push es
  push di
  push si
  push bp
  mov  cx, Rows
  or   cx, cx
  jnz  @go
  jmp  @done
@go:
  { EVERY parameter is read before BP is touched. FPC addresses parameters
    through BP, so loading the step into it first -- which is what the first
    version did -- silently reads TOfs and TSeg from the wrong place, and
    that is what wedged the machine the first time this ran. }
  mov  di, Ofs
  mov  dx, V
  mov  si, TOfs
  mov  ax, TSeg
  mov  bx, VStep
  mov  bp, bx                { no parameter may be named after this line }
  { VIDEO in DS, TEXTURE in ES, which is the way round that costs least.

    A segment override is one byte, and on an 8086 one byte of instruction
    fetch is one bus cycle, so the question is only which operand appears
    more often. In the four-rows-a-texel path there are FOUR stores and ONE
    lookup, so paying the override on the lookup instead of on every store
    takes the bulk loop from 29 bytes per four pixels to 26.

    `mov [di],al` with no prefix is DS:[DI]; only the string instructions
    default to ES. }
  mov  es, ax                { the texture bank }
  mov  ax, VGA_SEG
  mov  ds, ax                { the screen }
  mov  bx, si                { XLAT reads ES:[BX + AL] }

  { Odd rows first, one at a time, so all three bulk loops below can assume a
    multiple of four and share this remainder. }
  mov  si, cx
  and  si, 3
  jz   @bulk
@rem:
  mov  al, dh
  xlat es:[bx]
  mov  [di], al
  add  di, XW
  add  dx, bp
  dec  si
  jnz  @rem
@bulk:
  shr  cx, 1
  shr  cx, 1
  or   cx, cx
  jnz  @pick
  jmp  @done

  { HOW OFTEN THE TEXTURE IS ACTUALLY SAMPLED

    A wall slice is TEXH texels stretched over Rows screen rows, so when the
    wall is tall each texel already covers several rows and sampling once per
    row is repeated work. VStep is texels-per-row in Q8, so it says directly
    how magnified this slice is:

      VStep <= 64    at least 4 rows a texel   sample once per 4 rows
      VStep <= 128   at least 2 rows a texel   sample once per 2 rows
      otherwise      sample every row

    The stores cannot be avoided -- one byte per row, 80 apart -- but the
    lookup and the accumulate can be shared, and on an 8086 those are three
    fetched bytes each. Skipping them takes the bulk loop from 11.5 bytes a
    pixel to 8.5 and then 7.25.

    Sampling at the top of a group rather than the middle can put the texel
    boundary at most one row early. At 2x magnification or more that is not
    visible, and it is what nearest-neighbour would mostly have produced
    anyway. }
@pick:
  cmp  bp, 64
  jbe  @by4
  cmp  bp, 128
  jbe  @by2

  { --- one lookup per row ------------------------------------------- }
@by1:
  mov  al, dh
  xlat es:[bx]
  mov  [di], al
  add  dx, bp
  mov  al, dh
  xlat es:[bx]
  mov  [di + XW], al
  add  dx, bp
  mov  al, dh
  xlat es:[bx]
  mov  [di + XW * 2], al
  add  dx, bp
  mov  al, dh
  xlat es:[bx]
  mov  [di + XW * 3], al
  add  dx, bp
  add  di, XW * 4
  dec  cx
  jnz  @by1
  jmp  @done

  { --- one lookup per two rows -------------------------------------- }
@by2:
  mov  si, bp
  shl  si, 1
@by2l:
  mov  al, dh
  xlat es:[bx]
  mov  [di], al
  mov  [di + XW], al
  add  dx, si
  mov  al, dh
  xlat es:[bx]
  mov  [di + XW * 2], al
  mov  [di + XW * 3], al
  add  dx, si
  add  di, XW * 4
  dec  cx
  jnz  @by2l
  jmp  @done

  { --- one lookup per four rows ------------------------------------- }
@by4:
  mov  si, bp
  shl  si, 1
  shl  si, 1
@by4l:
  mov  al, dh
  xlat es:[bx]
  mov  [di], al
  mov  [di + XW], al
  mov  [di + XW * 2], al
  mov  [di + XW * 3], al
  add  dx, si
  add  di, XW * 4
  dec  cx
  jnz  @by4l
@done:
  pop  bp
  pop  si
  pop  di
  pop  es
  pop  ds
end;

{ One pixel back out of an unchained screen, for the thumbnail. Read Map
  Select picks the plane; the byte holds four pixels and the plane says which.
  Slow, and only ever used once per run. }
function XPeek(X, Y: Word): Byte;
begin
  OutB(GC_IX, 4); OutB(GC_DA, X and 3);
  { ShowBase, not DrawBase: the thumbnail has to photograph the page the
    monitor is showing, which with triple buffering is two pages behind the
    one drawing would leave us pointing at. }
  XPeek := Mem[VGA_SEG : ShowBase + Y * XW + (X shr 2)];
end;

{ One two-pixel-wide vertical run: a single word store per row.

  This exists because the coalescing does NOT save the day, and measuring said
  so. Perspective makes wall height vary continuously across a flat surface --
  only a wall exactly perpendicular to the view gives a constant height -- so
  160 rays produced 142 runs a frame. Nearly every run is one ray wide.

  For a run that narrow the row loop in FillRect is almost all overhead: it
  sets up a REP for a single word, roughly 67 cycles to paint two pixels. This
  drops the setup and stores the word directly, about 37. Same picture, and it
  is the shape the wall slices actually have. }
procedure FillCol2(Ofs, H: Word; ColW: Word); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  dx, H
  mov  ax, ColW
  or   dx, dx
  jz   @done
  { Odd row first, then pairs. Unrolling the row loop by two amortises the
    add/dec/jnz over two stores: about 37 cycles for two pixels becomes about
    56 for four. Worth doing because this is the only routine left that pays
    per row rather than per string instruction. }
  test dx, 1
  jz   @pairs
  mov  word ptr es:[di], ax
  add  di, SCR_W
  dec  dx
  jz   @done
@pairs:
  mov  word ptr es:[di], ax
  mov  word ptr es:[di + SCR_W], ax
  add  di, SCR_W * 2
  sub  dx, 2
  jnz  @pairs
@done:
  pop  di
  pop  es
end;

{ Four pixels wide: two word stores a row, same unrolling. Used when a run is
  two rays across, which happens constantly on a flat wall. }
procedure FillCol4(Ofs, H: Word; ColW: Word); assembler;
asm
  push es
  push di
  mov  ax, VGA_SEG
  mov  es, ax
  mov  di, Ofs
  mov  dx, H
  mov  ax, ColW
  or   dx, dx
  jz   @done
  test dx, 1
  jz   @pairs
  mov  word ptr es:[di], ax
  mov  word ptr es:[di + 2], ax
  add  di, SCR_W
  dec  dx
  jz   @done
@pairs:
  mov  word ptr es:[di], ax
  mov  word ptr es:[di + 2], ax
  mov  word ptr es:[di + SCR_W], ax
  mov  word ptr es:[di + SCR_W + 2], ax
  add  di, SCR_W * 2
  sub  dx, 2
  jnz  @pairs
@done:
  pop  di
  pop  es
end;

{ ---------------------------------------------------------------------- }
{  Casting                                                                }
{ ---------------------------------------------------------------------- }

{ Procedural, so the demo stays one self-contained EXE with no art to ship
  or find at run time -- the same reason the maze is a const.

  Both patterns are courses of blocks with a half-block offset on alternate
  rows, which is what reads as masonry rather than as a grid. The noise is a
  plain 16-bit LCG: it only has to look unrepeating across 64 pixels. }
var
  TexSeed : Word;

function TRnd: Word;
begin
  TexSeed := TexSeed * 25173 + 13849;
  TRnd := TexSeed;
end;

{ Copy one pattern into a bank, adding the palette base. Runs 8 x 4160 times
  at startup, which is about half a second on this box and happens once. }
procedure BakeBank(Dst: Pointer; Which, Base: Integer);
var
  I : Integer;
  D : ^Byte;
begin
  D := Dst;
  for I := 0 to BANKSZ - 1 do
  begin
    D^ := Base + Pat[Which][I];
    Inc(D);
  end;
end;

procedure BuildTextures;
var
  { Band and not InC: Pascal is case-insensitive, so THAT name is the
    built-in Inc, and Inc(L, 2) below stops compiling. }
  X, Y, L, Course, Band, XX, Ix : Integer;
begin
  TexSeed := 1;
  for X := 0 to TEXW - 1 do
    for Y := 0 to TEXH - 1 do
    begin
      Ix := X * TEXH + Y;          { column-major: see the note by TEXW }

      { --- type 1: brick. Eight-row courses, half-brick offset. --- }
      Course := Y shr 3;
      Band    := Y and 7;
      XX     := X;
      if Odd(Course) then XX := (X + 16) and (TEXW - 1);
      if (Band = 0) or ((XX and 31) = 0) then
        L := 2                                   { mortar }
      else
      begin
        L := 10 + Integer(TRnd shr 14);          { 10..13 }
        if Band = 1 then Inc(L, 2);               { lip under the joint }
        if Band = 7 then Dec(L, 3);               { shadow above it }
      end;
      if L < 0  then L := 0;
      if L > 15 then L := 15;
      Pat[0][Ix] := L;

      { --- type 2: stone. Bigger blocks, rougher face. --- }
      Course := Y shr 4;
      Band    := Y and 15;
      XX     := X;
      if Odd(Course) then XX := (X + 8) and (TEXW - 1);
      if (Band = 0) or ((XX and 15) = 0) then
        L := 3
      else
        L := 8 + Integer(TRnd shr 13);           { 8..15 }
      if L < 0  then L := 0;
      if L > 15 then L := 15;
      Pat[1][Ix] := L;
    end;

  { One block for all eight banks. Bake one per (type, shade): each is the
    same pattern pointed at a different 16-entry palette ramp, so the blitter
    never does any shading arithmetic -- it just reads a different bank. }
  GetMem(TexBlk, NTEX * BANKSZ);
  if TexBlk = nil then
  begin
    WriteLn('  out of memory for the texture banks');
    Halt(1);
  end;
  { NORMALISE the pointer -- fold the offset into the segment so every
    bank+column offset is small. GetMem makes no promise about the offset it
    returns, and 8 banks span 33280 bytes: an offset near the top of a
    segment plus that span would wrap, and the wrap would read whatever
    happened to be at the bottom of the segment. }
  TexSegG := Seg(TexBlk^) + (Ofs(TexBlk^) shr 4);
  TexOfs0 := Ofs(TexBlk^) and 15;
  for Ix := 0 to NTEX - 1 do
  begin
    BankOfs[Ix] := TexOfs0 + Word(Ix) * BANKSZ;
    BakeBank(Ptr(TexSegG, BankOfs[Ix]), Ix div NSHADE,
             TEXBASE + Ix * TEXLVL);
  end;

  { Floor and ceiling shading by row. Row 100 is the horizon and infinitely
    far; row 199 is directly underfoot. Distance goes as 1/(Y-100), so the
    level is taken from that rather than from Y -- linear in Y would put all
    the visible change in the last few rows. }
  for Ix := 0 to SCR_H - 1 do
  begin
    X := Ix - HALF;
    if X < 0 then X := HALF - 1 - Ix;        { mirror above the horizon }
    if X < 1 then X := 1;
    { 1/(distance), scaled: near the horizon this is small (dark), }
    { underfoot it is large (bright). }
    L := (X * TEXLVL) div HALF;
    if L > TEXLVL - 1 then L := TEXLVL - 1;
    RowShade[Ix] := L;
  end;
end;

{ --- the maze generator ------------------------------------------------ }

{ A plain 16-bit LCG, seeded from the SEED argument. It only has to make a
  different maze for a different seed, not a good one; the same generator
  draws the wall textures a few hundred lines up. }
function MRnd(N: Word): Word;
begin
  MazeSeed := MazeSeed * 25173 + 13849;
  { The low bits of an LCG are its worst ones and MRnd(2) and MRnd(4) below
    would read exactly those, so take from the middle instead. With the low
    bits the carve came out with a visible diagonal grain. }
  MRnd := (MazeSeed shr 5) mod N;
end;

procedure BuildGrid;
var
  Sp, I, D, NCand : Integer;
  CX, CY, NX, NY  : Integer;
  MX, MY, Cur     : Integer;
  Cand            : array[0 .. 3] of Integer;
begin
  { Solid first; the carve opens it up. The outer ring is never reached by
    anything below, which is the invariant the DDA depends on. }
  for I := 0 to MAPW * MAPH - 1 do Grid[I] := 2;
  FillChar(MzSeen, SizeOf(MzSeen), 0);
  if MazeSeed = 0 then MazeSeed := 1;
  MazeSeed0 := MazeSeed;

  { --- carve: an iterative recursive backtracker --------------------- }
  { Iterative and not recursive, with the stack held explicitly. 961 cells
    of Pascal recursion is 961 stack frames, and DOS has no stack guard at
    all -- a recursive directory walker overflowing one is what put the
    watermark into the Prof unit. An array says what it costs. }
  Cur           := 0;                  { cell (0,0) = map (1,1) }
  MzSeen[Cur]   := 1;
  Grid[MAPW + 1] := 0;
  Sp            := 0;
  MzStack[0]    := Cur;

  while Sp >= 0 do
  begin
    Cur := MzStack[Sp];
    CX  := Cur mod CELLW;
    CY  := Cur div CELLW;

    NCand := 0;
    for D := 0 to 3 do
    begin
      NX := CX + DirDX[D];
      NY := CY + DirDY[D];
      if (NX < 0) or (NX >= CELLW) or (NY < 0) or (NY >= CELLH) then Continue;
      if MzSeen[NY * CELLW + NX] <> 0 then Continue;
      Cand[NCand] := D;
      Inc(NCand);
    end;

    if NCand = 0 then
    begin
      Dec(Sp);                         { dead end: back up }
      Continue;
    end;

    D  := Cand[MRnd(NCand)];
    NX := CX + DirDX[D];
    NY := CY + DirDY[D];
    { Two cells to open: the wall between, and the cell beyond it. }
    MX := 1 + CX * 2 + DirDX[D];
    MY := 1 + CY * 2 + DirDY[D];
    Grid[MY * MAPW + MX] := 0;
    Grid[(1 + NY * 2) * MAPW + (1 + NX * 2)] := 0;
    MzSeen[NY * CELLW + NX] := 1;
    Inc(Sp);
    MzStack[Sp] := NY * CELLW + NX;
  end;

  { --- braid: knock some of the walls back out ----------------------- }
  { Written as two loops over cell PAIRS rather than one scan for walls
    with an odd/even test, because the pair form cannot address the border:
    the largest column either loop can touch is 2*CELLW - 2 = 60, and the
    ring at 62 and 63 is unreachable by construction rather than by a test
    somebody has to get right. }
  for CY := 0 to CELLH - 1 do
    for CX := 0 to CELLW - 2 do
      if MRnd(256) < BRAID then
        Grid[(1 + CY * 2) * MAPW + (2 + CX * 2)] := 0;
  for CY := 0 to CELLH - 2 do
    for CX := 0 to CELLW - 1 do
      if MRnd(256) < BRAID then
        Grid[(2 + CY * 2) * MAPW + (1 + CX * 2)] := 0;

  { --- wall types ---------------------------------------------------- }
  { Two, because the texture bank holds two -- CastColumn clamps Cell to 2
    before it picks a bank. Districts of 16 cells rather than a coin flip
    per wall: alternating textures at every wall reads as noise, whereas a
    district boundary reads as somewhere else, and being able to tell one
    part of the maze from another is the only landmark a world this size
    offers. The border is always type 2 so the edge of the world is a
    consistent surface. }
  for MY := 0 to MAPH - 1 do
    for MX := 0 to MAPW - 1 do
      if Grid[MY * MAPW + MX] <> 0 then
      begin
        if (MX = 0) or (MY = 0) or (MX = MAPW - 1) or (MY = MAPH - 1) then
          Grid[MY * MAPW + MX] := 2
        else if (((MX shr 4) + (MY shr 4)) and 1) = 0 then
          Grid[MY * MAPW + MX] := 1
        else
          Grid[MY * MAPW + MX] := 2;
      end;

  { The camera starts here, so it had better be open. It is the first cell
    the carve visits, but saying so costs one store. }
  Grid[MAPW + 1] := 0;

  OpenCells := 0;
  for I := 0 to MAPW * MAPH - 1 do
    if Grid[I] = 0 then Inc(OpenCells);
end;

function CellAt(MX, MY: Integer): Byte;
begin
  if (MX < 0) or (MY < 0) or (MX >= MAPW) or (MY >= MAPH) then
    CellAt := 2
  else
    CellAt := Grid[MY * MAPW + MX];
end;

{ Everything about the camera position that every ray in the frame shares.
  Call once per frame, before the ray loop. }
{ THE PIVOT CACHE

  The walk turns on the spot -- Advance refuses to move while the turn is
  still wide -- so on those frames the camera's POSITION is unchanged and a
  cast result is still valid for whatever absolute angle it was taken at.
  Ray X's absolute angle is Ang + (X - NRays/2)*RayStep, so turning by
  K*RayStep makes ray X's new angle equal old ray X+K's. The whole frame is
  then a shift of the column arrays plus |K| newly exposed columns.

  This is why FOV was changed to 160: the mapping is only exact when RayStep
  is a whole number of angle units, and Advance snaps the turn to a multiple
  of it. Snapping costs at most one ray of turn per frame, which is under
  half a degree.

  Six arrays move rather than one because everything the blitter reads is
  per-column. Move() is memmove, so the overlap is safe in both directions. }
{ A SUSPECTED FAULT HERE WAS INVESTIGATED AND NOT FOUND. Read this before
  suspecting it again, because the argument for the fault is a good one and
  will occur to the next person too.

  THE ARGUMENT. The cache shifts six arrays, and they do not hold rays --
  they hold heights, extents, texture offsets and texel steps, every one of
  which comes through `Perp = RayD * ColCos[X]`. ColCos is indexed by SCREEN
  COLUMN: it is the fisheye correction for how far that column sits off the
  centre of view, and it runs 256 in the middle down to 225 at the edges
  (Q8, cosine of 28 degrees). The world ray really does move from column
  X+K to column X, and its offset from the middle of the screen changes when
  it does. So a cached column looks like it should be carrying a height
  computed with ColCos[X+K] into a place where ColCos[X] applies -- up to
  12% wrong, on half the screen, whenever the camera turns on the spot.

  THE MEASUREMENT SAYS NO. On the V30, camera turned 90 degrees on the spot
  in a corridor and then held still, so that every column on screen came out
  of the cache and none was re-cast:

      ColTop and ColBot, cached against freshly cast:  IDENTICAL, all 80

  (ColOfs differed by a constant 8 in every column, which is the texture
  heap block landing at a different offset within its paragraph between two
  runs, not a rendering difference. The thumbnails were byte-identical too.)

  So the argument above is wrong somewhere and the flaw has not been found.
  It is recorded rather than deleted precisely because it is persuasive.

  PIVCHK is the instrument built to settle it: it re-casts every column from
  the camera state the run ended in and reports how far the frame had
  drifted. PIVBAD deliberately shifts one column too many so that PIVCHK can
  be shown to catch something. **Neither has been validated**, because every
  scripted viewpoint tried ended with the camera close to a wall, where
  every column clips at row 0 and no difference can show -- PIVCHK read zero
  for PIVBAD too, which means the reading was saturated and not that the
  cache is sound. If this is picked up again, the first job is a viewpoint
  looking down a long corridor at an oblique angle, and PIVBAD reading
  non-zero there BEFORE any weight is put on PIVOT reading zero. }
procedure ShiftColumns(K: Integer);
var
  Cnt : Integer;
begin
  if K > 0 then
  begin
    Cnt := NRays - K;
    Move(ColTop[K], ColTop[0], Cnt * SizeOf(Integer));
    Move(ColBot[K], ColBot[0], Cnt * SizeOf(Integer));
    Move(ColOfs[K], ColOfs[0], Cnt * SizeOf(Word));
    Move(ColV0[K],  ColV0[0],  Cnt * SizeOf(Word));
    Move(ColVs[K],  ColVs[0],  Cnt * SizeOf(Word));
    Move(ColCol[K], ColCol[0], Cnt);
  end
  else
  begin
    Cnt := NRays + K;
    Move(ColTop[0], ColTop[-K], Cnt * SizeOf(Integer));
    Move(ColBot[0], ColBot[-K], Cnt * SizeOf(Integer));
    Move(ColOfs[0], ColOfs[-K], Cnt * SizeOf(Word));
    Move(ColV0[0],  ColV0[-K],  Cnt * SizeOf(Word));
    Move(ColVs[0],  ColVs[-K],  Cnt * SizeOf(Word));
    Move(ColCol[0], ColCol[-K], Cnt);
  end;
end;

procedure CamPrepare;
begin
  CamMX  := PosX shr 8;
  CamMY  := PosY shr 8;
  CamIdx := CamMY * MAPW + CamMX;
  FracX  := PosX and 255;
  FracY  := PosY and 255;
  RestX  := ONE - FracX;
  RestY  := ONE - FracY;
end;

{ One column. Leaves its slice in ColTop/ColBot/ColCol. }
{ The Y-step stride in the DDA below is unrolled as MAPSHIFT one-bit
  shifts, which no compiler can check for us. Change MAPW and this refuses
  to build rather than quietly casting rays through the wrong rows. }
{$IF (MAPSHIFT <> 6) or (MAPW <> 64)}
{$ERROR MAPW changed - the DDA Y-step shift is unrolled for MAPSHIFT=6}
{$ENDIF}

procedure CastColumn(X: Integer);
var
  RA, SX       : Integer;
  { RdX/RdY and not DX/DY: a local called DX cannot be reached from an asm
    block at all, because the assembler resolves the name as the register.
    Nothing warns about it -- it just assembles against the wrong thing. }
  RdX, RdY     : Integer;
  RayD         : Integer;      { distance along the ray, pre-fisheye }
  SIy          : Integer;      { SY * MAPW, hoisted out of the DDA }
  TopRaw       : Integer;      { top row before clipping, for the texture }
  U, VS, Db    : Integer;
  Fm           : Word;         { 0 or 255: mirror this face, or not }      { and not DdX/DdY -- Pascal is
                                 case-insensitive, so those ARE the DDX/DDY
                                 tables and shadow them into an Integer }
  TA, CC       : Integer;      { operands staged for the inline multiplies }
  Idx          : Integer;
  SdX, SdY     : TQ8;
  Cell, Side   : Integer;
  Perp, Hgt    : Integer;
  Guard        : Integer;
  Top, Bot     : Integer;
begin
  { THE WHOLE WALK, IN ONE ASSEMBLER BLOCK

    Angle lookup, both initial side distances and the DDA, without going back
    through memory in between. In Pascal each of those steps stored its
    result and the next one loaded it again; here SdX and SdY reach the loop
    already in AX and BX and the grid index is in SI throughout.

    IMUL leaves the product in DX:AX, and the >>8 is two register moves --
    AL takes AH, AH takes DL -- rather than the six-round shl/rcl chain a
    Q10 format would need on an 8086. That is why the whole demo is Q8.

    SdX is parked on the stack across the second IMUL because IMUL owns DX
    and there is no spare register; the push/pop nests inside the SI/DI pair
    so the block is still balanced on every path. }
  asm
  push si
  push di

  { --- per-angle tables ------------------------------------------- }
  mov  si, X
  shl  si, 1
  mov  ax, Ang
  add  ax, ColAng[si]
  and  ax, ANGLES - 1
  mov  RA, ax                    { the texture setup still wants it }
  shl  ax, 1
  mov  si, ax
  mov  cx, StpX[si]
  mov  SX, cx
  mov  ax, DDX[si]
  mov  RdX, ax
  mov  ax, DDY[si]
  mov  RdY, ax
  { The grid step for a Y move. MAPW is 64, so this is six shifts, and the
    sign of it is also the sign of StpY -- which is all the Y side distance
    below needs, so StpY itself never has to be kept.

    Unrolled rather than `mov cl,MAPSHIFT / shl ax,cl`: a shift by CL is
    about 8 + 4 per bit on an 8086, so six of those is 32 cycles against 12
    for six one-bit shifts, and the two extra bytes of fetch do not come
    close to paying that back. The conditional-compilation guard in front of
    this procedure is what stops the pair drifting apart. }
  mov  ax, StpY[si]
  shl  ax, 1
  shl  ax, 1
  shl  ax, 1
  shl  ax, 1
  shl  ax, 1
  shl  ax, 1
  mov  SIy, ax

  { --- distance to the first grid line on each axis ---------------- }
  or   cx, cx                    { CX is still StpX }
  jg   @@restx
  mov  ax, FracX
  jmp  @@mulx
@@restx:
  mov  ax, RestX
@@mulx:
  imul word ptr RdX
  mov  al, ah
  mov  ah, dl
  push ax                        { park SdX: IMUL below owns DX }

  mov  cx, SIy
  or   cx, cx
  jg   @@resty
  mov  ax, FracY
  jmp  @@muly
@@resty:
  mov  ax, RestY
@@muly:
  imul word ptr RdY
  mov  al, ah
  mov  ah, dl
  mov  bx, ax                    { BX = SdY }
  pop  ax                        { AX = SdX }
  mov  si, CamIdx

  { --- the DDA ----------------------------------------------------- }
  { CX counts DOWN from MAXSTEP so the guard and the loop counter are the
    same register. Steps taken is MAXSTEP - CX, and the decrement sits
    before the cell test so a wall found on the first step counts as one
    step, not none.

    There is no bounds check: the generator never carves the outer ring, so
    every edge cell is a wall and the loop always ends on Cell <> 0. CX is
    what makes that safe rather than merely likely, and nothing here writes
    through SI.

    THE COMPARE IS UNSIGNED, AND HAS TO BE. A side distance can reach
    47040 on a 64-cell world -- see DD_MAX -- which is a positive Word and a
    negative Integer, and `jge` on that steps the wrong axis for the rest of
    the ray. It read `jge` while the map was 16x16, where the sum could not
    get there; growing the map is what made the distinction real. }
  mov  cx, MAXSTEP
  xor  dx, dx                    { DL is Cell, and DH must stay 0 }
  xor  di, di                    { DI is Side }
@@step:
  cmp  ax, bx
  jae  @@ystep
  add  ax, RdX
  add  si, SX
  xor  di, di
  jmp  @@cell
@@ystep:
  add  bx, RdY
  add  si, SIy
  mov  di, 1
@@cell:
  dec  cx
  mov  dl, Grid[si]
  or   dl, dl
  jnz  @@hit
  or   cx, cx
  jnz  @@step
@@hit:
  mov  SdX, ax
  mov  SdY, bx
  mov  Cell, dx
  mov  Side, di
  mov  ax, MAXSTEP
  sub  ax, cx
  mov  Guard, ax
  pop  di
  pop  si
  end;
  Inc(StepsDDA, Guard);

  { THE TAIL: fisheye, the perspective divide, and the column extents.

    THE INTEGER PATH WAS DOING A 32-BIT DIVIDE FOR NO REASON. It read
    `Integer((LongInt(SCR_H) * ONE) div Perp)`, and FPC calls a software
    routine for that -- BENCH puts a 32-bit divide at 7280/sec, 137 us. But
    the numerator is 200*256 = 51200, which fits in a WORD, and Perp is
    positive and at least PERP_MIN, so a plain 16-bit DIV does it in about
    30 cycles. That matters far more than it does here: this box has an 8087
    and takes the other branch, but most 8086-class machines have no
    coprocessor at all and were paying 137 us a column for it.

    The 8087 branch is still gated on UseFpu and is the only thing here that
    executes an ESC opcode -- with no coprocessor fitted an 8086 does not
    fault on one, it runs a dummy bus cycle and quietly returns garbage. }
  asm
  push si
  push di
  mov  si, X
  shl  si, 1

  { --- distance along the ray, before the fisheye correction -------- }
  mov  ax, Side
  or   ax, ax
  jnz  @@perpy
  mov  ax, SdX
  sub  ax, RdX
  jmp  @@perph
@@perpy:
  mov  ax, SdY
  sub  ax, RdY
@@perph:
  { The texture coordinate wants THIS one and not the corrected one: it is
    the hit point only while Dir is a unit vector and the distance is
    measured along the ray. }
  mov  RayD, ax

  { --- fisheye correction ------------------------------------------- }
  imul word ptr ColCos[si]
  mov  al, ah
  mov  ah, dl
  cmp  ax, PERP_MIN
  jge  @@perpok
  mov  ax, PERP_MIN
@@perpok:
  mov  Perp, ax

  { --- height ------------------------------------------------------- }
  cmp  byte ptr UseFpu, 0
  je   @@intdiv
  mov  FPerpI, ax
  fild  FPerpI
  fdivr F_NUM
  fistp FHeightI
  fwait
  mov  ax, FHeightI
  jmp  @@haveh
@@intdiv:
  mov  bx, ax
  mov  ax, SCR_H * ONE           { 51200, and it fits in a word }
  xor  dx, dx
  div  bx
@@haveh:

  { --- top and bottom, clipped -------------------------------------- }
  mov  bx, ax                    { BX = height }
  shr  ax, 1
  mov  cx, SCR_H / 2
  sub  cx, ax                    { CX = unclipped top }
  mov  TopRaw, cx                { the texture setup needs it unclipped }
  mov  ax, cx
  add  ax, bx
  dec  ax                        { AX = bottom }
  or   cx, cx
  jns  @@topok
  xor  cx, cx
@@topok:
  cmp  ax, SCR_H - 1
  jle  @@botok
  mov  ax, SCR_H - 1
@@botok:
  mov  ColTop[si], cx
  mov  ColBot[si], ax

  { --- the flat-path colour, and Cell clamped for the texture bank --- }
  mov  ax, Cell
  cmp  ax, 1
  jge  @@cmin
  mov  ax, 1
@@cmin:
  cmp  ax, 3
  jle  @@cmax
  mov  ax, 3
@@cmax:
  mov  Cell, ax
  dec  ax
  mov  bx, Side
  or   bx, bx
  jz   @@lit
  add  ax, C_DARK
  jmp  @@colput
@@lit:
  add  ax, C_LIT
@@colput:
  mov  di, X
  mov  ColCol[di], al

  pop  di
  pop  si
  end;

  if not Textured then Exit;

  { THE TEXTURE SETUP, IN ONE ASSEMBLER BLOCK

    Measured as 9.9 ms a frame in Pascal -- 124 us a column, the largest
    single item left in the cast. Nothing in it is hard; the cost is that
    every local is BP-relative memory, so each step stores its result and the
    next one loads it back. In registers the whole thing is straight-line.

    Three things it computes, and why each is cheap:

      U   where along the wall the ray landed. (U shr 2) * TEXH is the byte
          offset of the texture column, and since U is a byte that is
          `and 0FCh` then four shifts -- no multiply.
      VS  texels per screen row. TEXH*256/Hgt with Hgt = SCR_H*ONE/Perp
          cancels to Perp * 0.32, so one IMUL and not a second divide.
      Db  the fog band, by compare rather than by shifting Perp: a shift by
          CL is ~44 cycles on an 8086.

    Register budget is the reason Side is read from memory three times
    instead of being held: CX carries the column offset across both IMULs,
    and IMUL clobbers DX. }
  asm
  push si
  push di
  mov  si, RA
  shl  si, 1                     { word index into the per-angle tables }
  mov  di, X
  shl  di, 1                     { word index into the per-column arrays }

  { --- direction and mirror mask for the face this ray hit ---------- }
  mov  ax, Side
  or   ax, ax
  jnz  @@yside
  mov  cx, DirY8[si]
  mov  bx, FlipY[si]
  jmp  @@havedir
@@yside:
  mov  cx, DirX8[si]
  mov  bx, FlipX[si]
@@havedir:

  { --- U, and straight on into the texture column offset ------------ }
  mov  ax, RayD
  imul cx                        { DX:AX = RayD * dir, Q8 in the middle }
  mov  al, ah
  mov  ah, dl                    { >>8 as a byte shuffle }
  mov  cx, Side
  or   cx, cx
  jnz  @@upx
  add  ax, PosY
  jmp  @@uhave
@@upx:
  add  ax, PosX
@@uhave:
  xor  ax, bx                    { mirror: 255-U is U xor 255 for a byte }
  and  ax, 00FCh                 { (and 255) and (shr 2 shl 2) in one }
  shl  ax, 1
  shl  ax, 1
  shl  ax, 1
  shl  ax, 1                     { x16, so overall (U shr 2) * TEXH }
  mov  cx, ax                    { CX holds it through both IMULs below }

  { --- VS, texels per row ------------------------------------------- }
  mov  ax, Perp
  mov  bx, 82                    { 0.32 in Q8, near enough }
  imul bx
  mov  al, ah
  mov  ah, dl
  or   ax, ax
  jnz  @@vsok
  mov  ax, 1                     { a zero step would never leave texel 0 }
@@vsok:
  mov  ColVs[di], ax
  mov  bx, ax

  { --- V0: a wall taller than the screen starts part-way down ------- }
  mov  ax, TopRaw
  or   ax, ax
  jns  @@v0zero
  neg  ax
  imul bx
  mov  ColV0[di], ax
  jmp  @@v0done
@@v0zero:
  mov  word ptr ColV0[di], 0
@@v0done:

  { --- fog band, plus one step for a side-on face ------------------- }
  mov  ax, Perp
  cmp  ax, 640
  jl   @@db0
  cmp  ax, 1280
  jl   @@db1
  mov  bx, 2
  jmp  @@dbside
@@db0:
  xor  bx, bx
  jmp  @@dbside
@@db1:
  mov  bx, 1
@@dbside:
  add  bx, Side
  cmp  bx, 3
  jle  @@dbok
  mov  bx, 3
@@dbok:

  { --- bank, and the offset the blitter actually wants -------------- }
  mov  ax, Cell
  cmp  ax, 2
  jle  @@cellok
  mov  ax, 2
@@cellok:
  dec  ax
  shl  ax, 1
  shl  ax, 1                     { * NSHADE }
  add  ax, bx
  shl  ax, 1                     { word index }
  mov  si, ax
  mov  ax, BankOfs[si]
  add  ax, cx
  mov  ColOfs[di], ax

  pop  di
  pop  si
  end;
end;

{ ---------------------------------------------------------------------- }
{  Drawing                                                                }
{ ---------------------------------------------------------------------- }

{ Coalesce adjacent columns that came out identical, then draw each run as
  three rectangles. Facing a wall square-on this collapses the entire screen
  into a handful of REP STOSB rectangles; at an angle the runs are narrow and
  it degrades gracefully to something close to per-column fills. }
procedure DrawFrame;
var
  X, X2, W : Integer;
  P0       : Integer;
  CW       : Word;
  T, B     : Integer;
  BW, O    : Word;
  CT, CB   : Integer;
  CY       : Integer;
  MinT     : Integer;
  MaxB     : Integer;
begin
  { Ceiling and floor, and in mode X only over the rows that need it.

    This is the difference between 2 fps and something worth watching, and the
    reason is entirely about run width. A full-width REP STOSW moves a byte in
    about 1.5 cycles; a two-pixel-wide one costs about 33 a byte, because the
    REP setup and the row loop are paid for every two pixels. Painting the
    ceiling and floor per column meant 64000 pixels at the bad rate.

    Done this way the bands cost 64000 pixels at the GOOD rate -- around a
    hundredth of a second -- and the wall slices, which genuinely have to be
    per column, are the only thing left paying the narrow-run price. The walls
    overwrite part of the bands, and that overdraw is far cheaper than the
    alternative.

    In mode X there is a second saving on top, and it is the reason the pages
    carry a dirty band with them. Only the rows where THIS page's previous
    frame drew walls can be stale; everything above and below still holds the
    ceiling or floor colour it was given two frames ago. So the clear is not
    the whole screen, it is that band. A corridor fills most of the screen
    with wall and saves little; an open room leaves a thin band and saves
    nearly all of it. }
  if UseX then
  begin
    CT := PgTop[CurPage];
    CB := PgBot[CurPage];
    if CT <= CB then
    begin
      if CT < HALF then
      begin
        if CB < HALF - 1 then CY := CB else CY := HALF - 1;
        if NoBand then
        else if Textured then
          XFillRows(DrawBase + Word(CT) * XW, CT, CY - CT + 1, CEILBASE)
        else
          XFillFull(DrawBase + Word(CT) * XW, CY - CT + 1, C_CEIL);
        Inc(RectsHit);
      end;
      if CB >= HALF then
      begin
        if CT > HALF then CY := CT else CY := HALF;
        if NoBand then
        else if Textured then
          XFillRows(DrawBase + Word(CY) * XW, CY, CB - CY + 1, FLOORBASE)
        else
          XFillFull(DrawBase + Word(CY) * XW, CB - CY + 1, C_FLOOR);
        Inc(RectsHit);
      end;
    end;
  end
  else
  begin
    FillRect(0, SCR_W, SCR_H div 2, C_CEIL);
    FillRect(Word(SCR_H div 2) * SCR_W, SCR_W, SCR_H div 2, C_FLOOR);
    Inc(RectsHit, 2);
  end;

  MinT := SCR_H;
  MaxB := -1;

  { --- textured walls -------------------------------------------------- }
  { No run coalescing here, and there cannot be: adjacent columns sample
    different texture columns, so every run is one ray wide by definition.
    That is the cost of texturing, and it is why the coalescing below is
    still worth having on the FLAT path. }
  if Textured then
  begin
    for X := 0 to NRays - 1 do
    begin
      T := ColTop[X];
      B := ColBot[X];
      if T < MinT then MinT := T;
      if B > MaxB then MaxB := B;
      if not NoWall then
        XTexCol(DrawBase + Word(T) * XW + Word(X), B - T + 1,
                TexSegG, ColOfs[X], ColV0[X], ColVs[X]);
    end;
    Inc(RectsHit, NRays);
    PgTop[CurPage] := MinT;
    PgBot[CurPage] := MaxB;
    XSetStart(DrawBase);
    ShowBase := DrawBase;
    Inc(CurPage);
    if CurPage >= NPAGES then CurPage := 0;
    DrawBase := Word(CurPage) * PAGE_SZ;
    Exit;
  end;

  X := 0;
  while X < NRays do
  begin
    T  := ColTop[X];
    B  := ColBot[X];
    X2 := X + 1;
    while (X2 < NRays) and (ColTop[X2] = T) and (ColBot[X2] = B)
          and (ColCol[X2] = ColCol[X]) do
      Inc(X2);
    { Rays to pixels. Both are even multiples of PxW, so the fill stays
      word-aligned and the width stays even. }
    W  := (X2 - X) * PxW;
    P0 := X * PxW;
    Inc(RectsHit, 1);

    { Narrow runs dominate -- perspective makes wall height vary continuously,
      so most runs are one or two rays wide. Those get the dedicated column
      fills; anything wider is better off in the REP STOSW rectangle. }
    CW := Word(ColCol[X]) * 256 + ColCol[X];
    if T < MinT then MinT := T;
    if B > MaxB then MaxB := B;
    if UseX then
    begin
      BW := W shr 2;                          { pixels to bytes }
      O  := DrawBase + Word(T) * XW + Word(P0 shr 2);
      if BW = 1 then XFillCol1(O, B - T + 1, ColCol[X])
      else if BW = 2 then XFillCol2(O, B - T + 1, CW)
      else XFillRect(O, BW, B - T + 1, ColCol[X]);
    end
    else if W = 2 then
      FillCol2(Word(T) * SCR_W + P0, B - T + 1, CW)
    else if W = 4 then
      FillCol4(Word(T) * SCR_W + P0, B - T + 1, CW)
    else
      FillRect(Word(T) * SCR_W + P0, W, B - T + 1, ColCol[X]);

    X := X2;
  end;

  { Hand the finished page to the CRTC and move on to the next one. Nothing
    waits: the start address latches at the retrace by itself, and the page
    we step to is two flips old. }
  if UseX then
  begin
    PgTop[CurPage] := MinT;
    PgBot[CurPage] := MaxB;
    XSetStart(DrawBase);
    ShowBase := DrawBase;
    Inc(CurPage);
    if CurPage >= NPAGES then CurPage := 0;
    DrawBase := Word(CurPage) * PAGE_SZ;
  end;
end;

{ Sixteen DAC entries running from one colour to another. }
procedure TexRamp(Base, R0, G0, B0, R1, G1, B1: Integer);
var
  I : Integer;
begin
  for I := 0 to TEXLVL - 1 do
  begin
    DacSeek(Base + I);
    DacRGB(R0 + ((R1 - R0) * I) div (TEXLVL - 1),
           G0 + ((G1 - G0) * I) div (TEXLVL - 1),
           B0 + ((B1 - B0) * I) div (TEXLVL - 1));
  end;
end;

procedure LoadPalette;
var
  I, Sh, Sc : Integer;
begin
  DacSeek(0);
  DacRGB(0, 0, 0);
  DacSeek(C_CEIL);  DacRGB(10, 12, 20);          { dusk }
  DacSeek(C_FLOOR); DacRGB(22, 18, 12);          { boards }
  { Three wall types, each shaded and lit. The lit entries are strictly
    brighter than the dark ones so the thumbnail ramp below stays monotonic. }
  for I := 0 to 2 do
  begin
    DacSeek(C_DARK + I);
    case I of
      0: DacRGB(26, 10, 10);
      1: DacRGB(10, 26, 12);
      2: DacRGB(12, 14, 30);
    end;
    DacSeek(C_LIT + I);
    case I of
      0: DacRGB(58, 26, 24);
      1: DacRGB(26, 58, 30);
      2: DacRGB(30, 34, 62);
    end;
  end;

  { Sixteen-level ramps for the textures, at 64..127. Loaded whether or not
    TEX is on, so FLAT and TEX share one palette and can be compared without
    a reload. The shaded ramp is the lit one at roughly 55%, which is what
    makes the two faces of a corner read as one wall in two lights rather
    than as two different materials. }
  { Four distance bands per wall type, each the same hue at a lower
    brightness. Scaling both ends of the ramp rather than just the top keeps
    the mortar dark at every distance -- fading only the highlights makes a
    far wall look washed out instead of dim. }
  for Sh := 0 to NSHADE - 1 do
  begin
    Sc := 100 - Sh * 26;                    { 100, 74, 48, 22 }
    TexRamp(TEXBASE + Sh * TEXLVL,
            14 * Sc div 100,  6 * Sc div 100,  5 * Sc div 100,
            58 * Sc div 100, 28 * Sc div 100, 22 * Sc div 100);
    TexRamp(TEXBASE + (NSHADE + Sh) * TEXLVL,
             8 * Sc div 100,  9 * Sc div 100, 14 * Sc div 100,
            44 * Sc div 100, 48 * Sc div 100, 60 * Sc div 100);
  end;

  { The bands. Level 0 is the horizon and darkest; level 15 is underfoot or
    directly overhead. }
  TexRamp(CEILBASE,  3, 4,  7,  14, 17, 28);
  TexRamp(FLOORBASE, 6, 5,  3,  30, 25, 17);
end;

{ ---------------------------------------------------------------------- }
{  Movement                                                               }
{ ---------------------------------------------------------------------- }

{ THE AUTOPILOT, AND WHY IT IS NOT THE OBVIOUS ONE

  There is nobody at the keyboard over the bridge, so the tour has to drive
  itself, and it has to be the same on every run for one build to be
  comparable with another.

  The first version went straight until a wall stopped it, then turned right
  until something was open. That is not a wall follower and it does not
  explore -- measured on hardware, it reached 22 cells of 256 in twelve
  seconds and 24 in thirty, because it settles into a loop and then runs that
  loop forever. Making the demo three times longer bought two cells.

  This one walks cell to cell and picks the open neighbour it has visited
  LEAST. That cannot settle: arriving somewhere raises its count, which makes
  it the least attractive way back, so the walk is always pushed towards the
  part of the maze it knows worst. It is greedy rather than a search -- no
  queue, no stack, four comparisons per cell -- and on a maze with loops in
  it that is enough.

  Reversing carries a penalty on top. In a corridor the way back is always
  open and always scores as well as going on, so without it the walk
  oscillates between two cells and gets nowhere. }

function Walkable(WX, WY: Integer): Boolean;
begin
  Walkable := CellAt(WX shr 8, WY shr 8) = 0;
end;

{ THE NEAREST CELL THIS SWEEP HAS NOT SEEN, AND THE WAY TO IT.

  The greedy rule below is a good LOCAL rule and a hopeless global one. It
  picks an unseen neighbour, which clears a fresh pocket perfectly well and
  then, the moment everything within one step has been walked, has nothing
  left to say -- every direction scores the same and the camera wanders back
  over ground it has already covered. On 16x16 that barely showed, because
  the whole world was within a few steps of wherever it was. On 64x64 it is
  the difference between touring the maze and touring one corner of it.

  So this runs when the greedy has nothing: a breadth-first flood fill out
  from the camera's own cell, stopping at the first cell of this sweep it
  has not been to, and the walk then follows the route there. BFS and not a
  distance heuristic because the maze has walls -- the nearest cell as the
  crow flies is routinely on the far side of one, and a heuristic that
  ignores that walks into it and re-chooses.

  MEASURED AGAINST THE GREEDY RULE ALONE (NOSEEK) IT IS WORTH 3%: 1300
  cells against 1261 over ten minutes, and nothing at all over one. The
  paragraph above is a fair description of the greedy rule's weakness and a
  poor prediction of how much that weakness costs -- the visit-count
  gradient keeps pushing at whatever the walk knows worst, which turns out
  to be a decent global heuristic by itself.

  It stays because it is the only thing here that can FINISH. When the last
  unseen cell is across the maze there is nothing in a four-neighbour
  comparison that can aim at it, so a NOSEEK run can never complete a sweep
  and its report can only say so. That is reasoning rather than a
  measurement: both runs above stopped near 58%, well short of the endgame
  where it would have to show.

  IT IS NOT RUN EVERY CELL, AND THAT IS A COST DECISION. A full fill is
  ~2000 open cells at four neighbours each, and BENCH puts a Pascal loop
  iteration at 11 us -- call it 80 ms, which is one whole frame. Cheap at
  the few times a minute the greedy actually runs dry; ruinous at the three
  times a second the walk chooses a cell. }
function SeekFrontier: Boolean;
var
  Head, Tail, Cur, Nxt : Integer;
  D, CX, CY, NX, NY    : Integer;
  Goal                 : Integer;
begin
  FillChar(BfsFrom^, SizeOf(TCellArr), 0);
  Cur  := (PosY shr 8) * MAPW + (PosX shr 8);
  BfsQ^[0]      := Cur;
  BfsFrom^[Cur] := 5;              { reached, but by no direction: the root }
  Head := 0;
  Tail := 1;
  Goal := -1;

  while (Head < Tail) and (Goal < 0) do
  begin
    Cur := BfsQ^[Head];
    Inc(Head);
    CX := Cur and (MAPW - 1);      { MAPW is a power of two, so this is }
    CY := Cur shr MAPSHIFT;        { an AND and a shift, not a divide }
    for D := 0 to 3 do
    begin
      NX := CX + DirDX[D];
      NY := CY + DirDY[D];
      { No range test: the outer ring is solid wall, the camera is always in
        an open cell, so a neighbour is always inside the array. }
      Nxt := NY * MAPW + NX;
      if Grid[Nxt] <> 0 then Continue;
      if BfsFrom^[Nxt] <> 0 then Continue;
      BfsFrom^[Nxt] := D + 1;
      BfsQ^[Tail]   := Nxt;
      Inc(Tail);
      if Visited[NY, NX] < Gen then
      begin
        Goal := Nxt;
        Break;
      end;
    end;
  end;

  Inc(Seeks);
  if Goal < 0 then
  begin
    Inc(SeekMiss);
    SeekFrontier := False;
    Exit;
  end;

  { Walk the parents back to the root, pushing each direction as we go. That
    comes out REVERSED, which is exactly the order to consume it in --
    Path[PathLen-1] is the first step to take. }
  PathLen := 0;
  Cur     := Goal;
  while BfsFrom^[Cur] <> 5 do
  begin
    D := BfsFrom^[Cur] - 1;
    Path^[PathLen] := D;
    Inc(PathLen);
    Cur := Cur - DirDY[D] * MAPW - DirDX[D];
  end;
  SeekFrontier := PathLen > 0;
end;

{ THE RULE THIS DEMO USED WHEN THE MAP WAS 16x16, kept intact so that
  NOSEEK compares against what was really there.

  Least-visited open neighbour, with a penalty on reversing. The penalty is
  what stops it oscillating: in a corridor the way back is always open and
  always scores as well as going on, so without it the walk bounces between
  two cells and gets nowhere. It is a good LOCAL rule and a hopeless global
  one, which is what the bigger map exposed -- see SeekFrontier above. }
function LeastVisited: Integer;
var
  D, ND, Best, BestScore, Score : Integer;
  NX, NY : Integer;
begin
  Best      := -1;
  BestScore := 0;
  for D := 0 to 3 do
  begin
    ND := (Dir + D) and 3;
    NX := (PosX shr 8) + DirDX[ND];
    NY := (PosY shr 8) + DirDY[ND];
    if CellAt(NX, NY) <> 0 then Continue;
    Score := Integer(VisitN^[NY * MAPW + NX]) * 4;
    if ND = ((Dir + 2) and 3) then Inc(Score, 3);
    if (Best < 0) or (Score < BestScore) then
    begin
      Best      := ND;
      BestScore := Score;
    end;
  end;
  LeastVisited := Best;
end;

procedure ChooseTarget;
var
  D, ND, Best, Attempt : Integer;
  NX, NY : Integer;
begin
  OnPath := False;
  Best   := -1;

  { Twice round at most: the second pass only happens after the sweep
    counter has been bumped, which makes every cell stale again, so the
    first test below cannot fail twice. }
  for Attempt := 0 to 1 do
  begin
    { 1. Somewhere unseen one step away.

         Straight ahead is tried first, so a tie breaks towards carrying on
         rather than towards whichever direction happens to be numbered
         lowest. A tie-break that ignores the heading makes the camera jink
         for no reason a viewer can see. }
    for D := 0 to 3 do
    begin
      ND := (Dir + D) and 3;
      NX := (PosX shr 8) + DirDX[ND];
      NY := (PosY shr 8) + DirDY[ND];
      if CellAt(NX, NY) <> 0 then Continue;
      if Visited[NY, NX] >= Gen then Continue;
      Best := ND;
      Break;
    end;
    if Best >= 0 then
    begin
      { Something unseen is adjacent, so whatever long route was in flight
        is no longer the best thing to be doing. Drop it. }
      PathLen := 0;
      Break;
    end;

    { 2. A route already in flight to somewhere further off.

         PEEK, DO NOT POP. Advance can refuse a step -- it probes ahead of
         where it would land, and a camera still cutting a corner fails that
         probe -- and it re-chooses from the same cell when it does. Popping
         here would silently skip a leg of the route every time that
         happened. It is popped on arrival instead. }
    if PathLen > 0 then
    begin
      Best   := Path^[PathLen - 1];
      OnPath := True;
      Break;
    end;

    { 3. Nothing near and nothing in flight: flood fill for the nearest
         unseen cell, and start following the way there.

         NOSEEK takes the old least-visited rule instead. That rule always
         answers, so under NOSEEK the sweep counter below is never reached
         and a NOSEEK run never completes a sweep -- which is the point of
         it, not a limitation. }
    if NoSeek then
    begin
      Best := LeastVisited;
      if Best >= 0 then Break;
    end
    else if SeekFrontier then
    begin
      Best   := Path^[PathLen - 1];
      OnPath := True;
      Break;
    end;

    { 4. Every open cell has been walked. Start another sweep rather than
         stopping -- a tour that reaches the last cell and then stands still
         looks exactly like a tour that crashed, and over the bridge nobody
         can see which. }
    if Gen >= 250 then Break;
    if SweepTix = 0 then SweepTix := Ticks - RunStart;
    Inc(Gen);
    Inc(Sweeps);
  end;

  { Walled in on every side. Cannot happen in a maze whose cells are all
    connected, but a wrong turn here is a camera inside a wall, which
    renders as a screen of solid colour and reads as a crash. }
  if Best < 0 then Best := (Dir + 2) and 3;

  Dir     := Best;
  TgtX    := (PosX shr 8) + DirDX[Dir];
  TgtY    := (PosY shr 8) + DirDY[Dir];
  HaveTgt := True;
  Inc(Turns);
end;

{ Step the camera, by however much wall-clock time has passed.

  Paced by the BIOS tick and NOT by the frame count. Same rule the music in
  scroller.pas has to follow, and for the same reason: a fixed step per frame
  makes the tour's speed a function of the frame rate, so anything that
  changes rendering cost silently changes how far it walks -- and then a
  slower build looks like a broken maze rather than a slower one. }
procedure Advance(DTicks: Integer);
const
  { THESE TWO ARE THE COVERAGE, AND THE ARITHMETIC SAYS SO BEFORE A RUN
    DOES. A cell costs 256/PERSEC seconds to cross, plus 256/TURNSEC to
    turn through a right angle if it is a corner -- and in a generated maze
    almost every cell is a corner. At the old 700/640 that was 0.37s plus
    0.40s, measured at 0.69s a cell over a 60-second run, which is 87 cells
    on a map with 2091 of them. Locomotion, not the choosing.

    So both went up together. 1150 is about 4.5 cells a second, which is
    roughly a Wolfenstein run; 1400 is a right angle in 0.18s, two frames
    at the rate this renders. }
  PERSEC  = 1150;
  TURNSEC = 1400;
var
  CtrX, CtrY : Integer;
  Want, Raw  : Integer;
  Turn, Slip : Integer;
  MaxTurn    : Integer;
  Step, Rem  : Integer;
  NX, NY     : Integer;
  C, S       : Integer;
  Arrived    : Boolean;
begin
  Moved    := False;
  AngDelta := 0;
  { NO TICK, NO MOVEMENT -- and this used to round UP to one, which made
    the camera's speed a function of the frame rate after all.

    The BIOS tick is 18.2 a second. Below that every frame spans at least
    one and the clamp never fired, which is why it survived: this renders at
    about ten. Above it, `Now - Last` is frequently 0, the clamp turned that
    into a whole tick, and the tour walked at the frame rate instead of at
    PERSEC. Measured over the same 60 seconds on the same maze: 398 cells
    with NODRAW against 154 with the drawing left in -- and NODRAW is a
    MEASUREMENT mode, so the one place the bug showed was the one place its
    numbers were going to be compared against something.

    Returning instead means motion happens on 18.2 frames a second however
    many are drawn, which is the definition of tick-paced. It changes
    nothing at ten frames a second, where the gap is 1 or 2 ticks and never
    zero. }
  if DTicks < 1 then Exit;
  if DTicks > 18 then DTicks := 18;      { a stall must not teleport it }
  Step    := (PERSEC * DTicks) div 18;
  MaxTurn := (TURNSEC * DTicks) div 18;
  if Step < 4 then Step := 4;
  if MaxTurn < 2 then MaxTurn := 2;

  if not HaveTgt then ChooseTarget;
  CtrX := TgtX * 256 + 128;
  CtrY := TgtY * 256 + 128;

  { Turn towards the heading, the short way round. Adding half a circle
    before the mask and taking it off after folds the difference into
    -512..511, so there is no case analysis about which way is shorter. }
  Want := (Dir * QUART) and (ANGLES - 1);
  Raw  := (((Want - Ang) + ANGLES + (ANGLES div 2)) and (ANGLES - 1))
          - (ANGLES div 2);
  Turn := Raw;
  if Turn > MaxTurn then Turn := MaxTurn
  else if Turn < -MaxTurn then Turn := -MaxTurn;
  { Snap to a whole number of rays so a pure rotation is exactly a shift of
    the column arrays. At this turn rate that discards at most one ray per
    frame -- under half a degree, and it is given back on the next one. }
  if CanShift then Turn := (Turn div RayStep) * RayStep;
  Ang := (Ang + Turn) and (ANGLES - 1);
  AngDelta := Turn;

  { Turn on the spot until the turn is essentially finished, then crawl,
    then walk.

    Moving through a turn cuts the corner, and cutting the corner puts the
    camera into the wall probe below -- measured on the old map, 44 of 85
    cell choices were being thrown away and re-made for exactly that
    reason, and pivoting through the wide part of the turn dropped it to 9.

    THE THRESHOLD CAME IN FROM 160 TO 48 WHEN THE MAZE STOPPED BEING
    HAND-DRAWN. A carved maze turns at nearly every cell where the old
    literal had long straight corridors, so the residual corner-cutting the
    old threshold left went from 12% of cell choices to 28%. Pivoting until
    the heading is within 17 degrees costs one more frame at each corner
    and is paid for several times over by not re-choosing. }
  if (Raw > 48) or (Raw < -48) then Exit;
  if (Raw > 20) or (Raw < -20) then Step := Step div 3;
  if Step < 2 then Step := 2;

  { NEVER STEP PAST THE CENTRE OF THE CELL BEING WALKED TO.

    Arrival is tested as "at or past the centre", so without this the camera
    lands up to a whole step BEYOND it -- and a step is 0.45 of a cell at
    this speed and this frame rate. If the next move is a turn, that leaves
    the camera sitting a third of the way into the wall it is turning away
    from, the probe below refuses to move, and the cell is chosen again from
    a position it can never leave.

    Measured, 60-second runs on the same maze: 24 of 87 cell choices thrown
    away at PERSEC 700, then 48 of 108 at 1150 -- the faster it walked the
    worse it got, which is the signature of a per-step overshoot rather than
    of the speed itself. Clamping the step to the distance remaining makes
    arrival land exactly on the centre at any speed. }
  case Dir of
    0: Rem := CtrX - PosX;
    1: Rem := CtrY - PosY;
    2: Rem := PosX - CtrX;
  else
    Rem := PosY - CtrY;
  end;
  if (Rem > 0) and (Step > Rem) then Step := Rem;

  C := CosT(Ang);
  S := SinT[Ang];
  { A Q14 direction times a Q8 step: >>14 lands back in Q8. Both operands are
    16-bit and MulQ8 is not usable here because the shift is 14, so the one
    LongInt in the movement path stays -- it runs once a frame, not once a
    column. }
  NX := PosX + Integer((LongInt(C) * Step) div 16384);
  NY := PosY + Integer((LongInt(S) * Step) div 16384);

  { Probe ahead of where we would land, so the camera never ends up inside a
    wall -- which renders as a screen of solid colour and looks exactly like
    a crash. }
  if Walkable(NX + Integer((LongInt(C) * 110) div 16384),
              NY + Integer((LongInt(S) * 110) div 16384)) then
  begin
    PosX  := NX;
    PosY  := NY;
    Moved := True;
  end
  else
  begin
    { Something is in the way that the cell map said was clear, which happens
      when a turn is still in progress and the camera is cutting the corner.
      Choose again from where we actually are. }
    HaveTgt := False;
    Inc(Blocked);
    Exit;
  end;

  { Pull back onto the centre line. The camera turns WHILE moving, so it
    drifts off axis; left alone the drift accumulates and it eventually
    clips a doorway it should have gone straight through. }
  Slip := Step div 2;
  if Slip < 1 then Slip := 1;
  if (Dir = 0) or (Dir = 2) then
  begin
    Turn := CtrY - PosY;
    if Turn > Slip then Turn := Slip else if Turn < -Slip then Turn := -Slip;
    if Turn <> 0 then Moved := True;
    Inc(PosY, Turn);
  end
  else
  begin
    Turn := CtrX - PosX;
    if Turn > Slip then Turn := Slip else if Turn < -Slip then Turn := -Slip;
    if Turn <> 0 then Moved := True;
    Inc(PosX, Turn);
  end;

  { Arrival is "at or past the centre along the way we are going", not a
    distance test: at 600 units a second a frame moves up to 47 units, which
    is enough to jump clean over any threshold small enough to be useful. }
  case Dir of
    0: Arrived := PosX >= CtrX;
    1: Arrived := PosY >= CtrY;
    2: Arrived := PosX <= CtrX;
  else
    Arrived := PosY <= CtrY;
  end;
  if Arrived then
  begin
    Visited[TgtY, TgtX] := Gen;
    if VisitN^[TgtY * MAPW + TgtX] < 250 then
      Inc(VisitN^[TgtY * MAPW + TgtX]);
    { The pop that ChooseTarget deliberately does not do. Only when the step
      actually came off the route -- a greedy step that happened while a
      route was in flight has already thrown the route away. }
    if OnPath and (PathLen > 0) then Dec(PathLen);
    HaveTgt := False;
  end;
end;

{ ---------------------------------------------------------------------- }
{  Being driven: the keyboard, and the script that stands in for it        }
{ ---------------------------------------------------------------------- }

{ Is there ROOM for the camera at this point, rather than merely: is the
  point itself outside a wall?

  The automatic tour gets away with a single probe because it only ever
  moves along an axis and only ever between cell centres. A person pushing
  diagonally into a corridor does not, and a single-point test lets the
  camera's near edge into the wall before its centre notices. Four corners
  of a box, so eight CellAt calls a frame -- against 80 columns of casting
  that is nothing. }
function RoomAt(WX, WY: Integer): Boolean;
begin
  RoomAt := (CellAt((WX - PAD) shr 8, (WY - PAD) shr 8) = 0) and
            (CellAt((WX + PAD) shr 8, (WY - PAD) shr 8) = 0) and
            (CellAt((WX - PAD) shr 8, (WY + PAD) shr 8) = 0) and
            (CellAt((WX + PAD) shr 8, (WY + PAD) shr 8) = 0);
end;

{ Move the camera from Held[], by however much wall-clock time has passed.

  Paced by the BIOS tick like Advance is, and for the same reason: a fixed
  step per frame makes the camera's speed a function of the frame rate, so
  facing a wall (cheap to draw) would move you faster than facing down a
  corridor (dear). }
procedure Steer(DTicks: Integer);
const
  MOVESEC = 1000;      { Q8 a second: about 3.9 cells, 7.8 holding RUN }
  TURNSEC = 700;       { about 246 degrees a second }
var
  Step, Turn : Integer;
  C, S       : Integer;
  DX, DY     : Integer;
  FX, FY     : Integer;
  Want, Raw  : Integer;
  TurnKey    : Integer;
  Swinging   : Boolean;
begin
  Moved    := False;
  AngDelta := 0;
  { Same rule as Advance, and it matters more here: somebody at the keyboard
    facing a blank wall renders far faster than somebody in a corridor, and
    a camera that speeds up when there is less to look at is unusable. }
  if DTicks < 1 then Exit;
  if DTicks > 18 then DTicks := 18;
  Step := (MOVESEC * DTicks) div 18;
  if Held[A_RUN] then Step := Step * 2;
  Turn := (TURNSEC * DTicks) div 18;

  { --- turn ---------------------------------------------------------- }
  { A turn key always wins, and cancels any heading a script asked for --
    otherwise a script that ends with a heading would fight a person who
    then picked up the keyboard, and the camera would spin. }
  Swinging := False;
  { Any turn key cancels a heading a script asked for -- including both at
    once, which is a person deciding to steer by hand and getting no turn.
    Without that, a script that ends on a heading fights whoever picks up
    the keyboard next and the camera spins. }
  if Held[A_LEFT] or Held[A_RIGHT] then FaceGoal := -1;
  TurnKey := 0;
  if Held[A_LEFT]  and (not Held[A_RIGHT]) then TurnKey := -1;
  if Held[A_RIGHT] and (not Held[A_LEFT])  then TurnKey := 1;

  if TurnKey <> 0 then
    Turn := Turn * TurnKey
  else if FaceGoal >= 0 then
  begin
    { Adding half a circle before the mask and taking it off after folds
      the difference into -512..511, so there is no case analysis about
      which way round is shorter. Same trick as Advance. }
    Want := (FaceGoal * QUART) and (ANGLES - 1);
    Raw  := (((Want - Ang) + ANGLES + (ANGLES div 2)) and (ANGLES - 1))
            - (ANGLES div 2);
    if Raw > Turn then Swinging := True
    else if Raw < -Turn then begin Turn := -Turn; Swinging := True; end
    else
    begin
      Turn     := Raw;
      FaceGoal := -1;          { arrived, to the unit }
    end;
    if Swinging and ((Raw < 48) and (Raw > -48)) then Swinging := False;
  end
  else Turn := 0;
  { Snapped to a whole number of rays, exactly as the tour's turn is: that
    is what lets a pure rotation be a shift of the column arrays instead of
    a re-cast. Turning is most of what somebody at the keyboard does, so
    the pivot cache earns more here than it does on the tour. }
  if CanShift then Turn := (Turn div RayStep) * RayStep;
  if Turn <> 0 then
  begin
    Ang      := (Ang + Turn) and (ANGLES - 1);
    AngDelta := Turn;
  end;

  { --- where we would like to go -------------------------------------- }
  C  := CosT(Ang);
  S  := SinT[Ang];
  FX := Integer((LongInt(C) * Step) div 16384);
  FY := Integer((LongInt(S) * Step) div 16384);
  DX := 0;
  DY := 0;
  if Held[A_FWD]  then begin Inc(DX, FX); Inc(DY, FY); end;
  if Held[A_BACK] then begin Dec(DX, FX); Dec(DY, FY); end;
  { Strafe is the facing turned a quarter circle. Map Y grows DOWNWARD, so
    the viewer's right is (-sin, +cos) and not (+sin, -cos). Getting that
    backwards swaps the two strafe keys, which reviews perfectly well and
    is obvious within one second of actually playing it. }
  if Held[A_SRIGHT] then begin Dec(DX, FY); Inc(DY, FX); end;
  if Held[A_SLEFT]  then begin Inc(DX, FY); Dec(DY, FX); end;
  { Still swinging round to an asked-for heading: pivot on the spot. }
  if Swinging then
  begin
    DX := 0;
    DY := 0;
  end;

  { --- move, one axis at a time, so the camera SLIDES ----------------- }
  { All-or-nothing is right for the tour, which only ever moves along an
    axis. Somebody pushing diagonally at a corridor wall would just stop
    dead, which feels like the program has locked up. Testing each axis on
    its own drops the blocked component and keeps the other. }
  if (DX <> 0) and RoomAt(PosX + DX, PosY) then
  begin
    Inc(PosX, DX);
    Moved := True;
  end;
  if (DY <> 0) and RoomAt(PosX, PosY + DY) then
  begin
    Inc(PosY, DY);
    Moved := True;
  end;

  { Worth stamping either way: the map report is then a record of where
    somebody actually went, which is the only trace a session leaves. }
  if Moved then Visited[PosY shr 8, PosX shr 8] := Gen;
end;

{ --- the keyboard ---------------------------------------------------- }
procedure PollKeys;
begin
  Held[A_FWD]    := KbdDown(SC_UP)     or KbdDown(SC_W);
  Held[A_BACK]   := KbdDown(SC_DOWN)   or KbdDown(SC_S);
  Held[A_LEFT]   := KbdDown(SC_LEFT)   or KbdDown(SC_A);
  Held[A_RIGHT]  := KbdDown(SC_RIGHT)  or KbdDown(SC_D);
  Held[A_SLEFT]  := KbdDown(SC_Q);
  Held[A_SRIGHT] := KbdDown(SC_E);
  Held[A_RUN]    := KbdDown(SC_LSHIFT) or KbdDown(SC_RSHIFT);
  Held[A_QUIT]   := KbdDown(SC_ESC);
  { Chaining means the BIOS is still queueing every one of these. Sixteen
    entries in it beeps on every further repeat, and for a held key that is
    continuous. }
  KbdDrain;
end;

{ --- the script ------------------------------------------------------ }

function ActNamed(const Nm: ShortString; var A: Byte): Boolean;
begin
  ActNamed := True;
  if      Nm = 'FWD'    then A := A_FWD
  else if Nm = 'BACK'   then A := A_BACK
  else if Nm = 'LEFT'   then A := A_LEFT
  else if Nm = 'RIGHT'  then A := A_RIGHT
  else if Nm = 'SLEFT'  then A := A_SLEFT
  else if Nm = 'SRIGHT' then A := A_SRIGHT
  else if Nm = 'RUN'    then A := A_RUN
  else if Nm = 'QUIT'   then A := A_QUIT
  else if Nm = 'EAST'   then A := A_FACE + 0
  else if Nm = 'SOUTH'  then A := A_FACE + 1
  else if Nm = 'WEST'   then A := A_FACE + 2
  else if Nm = 'NORTH'  then A := A_FACE + 3
  else ActNamed := False;
end;

{ A script is plain text, one event a line:

      # a comment
      0  +SOUTH        turn to face south, pivoting on the spot
      5  +FWD          press forward at half a second
      31 -FWD          let go at 3.1 seconds
      31 +EAST         turn to face east
      45 +QUIT         and stop

  Held keys are FWD BACK LEFT RIGHT SLEFT SRIGHT RUN QUIT, pressed with +
  and released with -. Headings are EAST SOUTH WEST NORTH and take effect
  once, so the - form does nothing.

  Times are TENTHS OF A SECOND from the first frame, and they must not go
  backwards: events are applied in file order against a rising clock, so an
  out-of-order line is applied late rather than ignored, which is the more
  confusing of the two ways to get it wrong.

  This is the whole reason KEYS is testable from Windows. Generate a script
  in Python, deploy it, run PLAY, and the same Steer that a person drives
  gets exercised with nobody at the machine. }
function LoadScript(const FN: ShortString): Boolean;
var
  F    : Text;
  L, W : ShortString;
  I, P, Code, V : Integer;
  A    : Byte;
  Dn   : Boolean;
begin
  LoadScript := False;
  NEv   := 0;
  EvPtr := 0;
  Assign(F, FN);
  {$I-} Reset(F); {$I+}
  if IOResult <> 0 then
  begin
    WriteLn('  script         : cannot open ', FN);
    Exit;
  end;
  while (not Eof(F)) and (NEv < MAXEV) do
  begin
    {$I-} ReadLn(F, L); {$I+}
    if IOResult <> 0 then Break;
    { Comment off, tabs to spaces, both ends trimmed, then split on the
      first space. No SysUtils: it links a great deal of dead weight into a
      real-mode binary for what is four lines of Pos and Copy. }
    P := Pos('#', L);
    if P > 0 then L := Copy(L, 1, P - 1);
    for I := 1 to Length(L) do
      if L[I] = #9 then L[I] := ' ';
    while (Length(L) > 0) and (L[1] = ' ') do Delete(L, 1, 1);
    while (Length(L) > 0) and (L[Length(L)] = ' ') do
      Delete(L, Length(L), 1);
    if L = '' then Continue;

    P := Pos(' ', L);
    if P = 0 then Continue;
    W := Copy(L, 1, P - 1);
    Val(W, V, Code);
    if Code <> 0 then Continue;
    L := Copy(L, P + 1, Length(L));
    while (Length(L) > 0) and (L[1] = ' ') do Delete(L, 1, 1);
    if L = '' then Continue;

    Dn := True;
    if L[1] = '+' then Delete(L, 1, 1)
    else if L[1] = '-' then begin Dn := False; Delete(L, 1, 1); end;
    for I := 1 to Length(L) do
      if (L[I] >= 'a') and (L[I] <= 'z') then
        L[I] := Chr(Ord(L[I]) - 32);
    if not ActNamed(L, A) then Continue;

    Ev[NEv].T   := V;
    Ev[NEv].Act := A;
    Ev[NEv].Dn  := Dn;
    Inc(NEv);
  end;
  Close(F);
  LoadScript := NEv > 0;
end;

procedure PlayScript(Tenths: Integer);
var
  A : Byte;
begin
  while (EvPtr < NEv) and (Ev[EvPtr].T <= Tenths) do
  begin
    A := Ev[EvPtr].Act;
    { A heading is a one-shot instruction and not a held key, so it never
      goes into Held[] -- which is also why Held[] is still NACT long and
      indexing it with one of these would be off the end of it. }
    if A >= A_FACE then
    begin
      if Ev[EvPtr].Dn then FaceGoal := A - A_FACE;
    end
    else
      Held[A] := Ev[EvPtr].Dn;
    Inc(EvPtr);
  end;
end;

{ ---------------------------------------------------------------------- }
{  Reporting                                                              }
{ ---------------------------------------------------------------------- }

{ Read the picture back out of video memory as text.

  Ranked by the palette's own brightness order, not by luminance: the palette
  is chosen for hue, and ranking a hue-chosen palette by brightness turns a
  legible picture into noise. }
function Shade(V: Byte): Char;
const
  RAMP = ' .:-=+*#%@';
var
  I, B : Integer;
begin
  { Texture entries first: they are a brightness ramp WITHIN each texture,
    so ranking them by level is right, but the lit and shaded banks are kept
    in separate output ranges so a lit wall still reads brighter than a
    shaded one. Ranking the whole palette by luminance instead would turn
    the picture into noise -- the note in SCROLLER.md applies here too. }
  if (V >= TEXBASE) and (V < TEXBASE + NTEX * TEXLVL) then
  begin
    B := ((V - TEXBASE) shr 4) mod NSHADE;     { distance band, 0 = nearest }
    I := (V - TEXBASE) and (TEXLVL - 1);
    I := 4 + (NSHADE - 1 - B) + (I * 2) div (TEXLVL - 1);
    if I > 9 then I := 9;
    Shade := RAMP[I + 1];
    Exit;
  end;
  { THE THREE SURFACES GET THREE NON-OVERLAPPING SLICES OF THE RAMP.

    Once the bands became gradients they had 16 levels each, and mapping all
    three surfaces by brightness put walls, floor and ceiling on the same
    characters -- the picture came back as a field of noise with no readable
    geometry, which is the failure SCROLLER.md warns about in these words.
    Ranking has to be by DEPTH ORDER first: ceiling darkest, then floor,
    then walls, with each surface's own gradient inside its slice. }
  if (V >= CEILBASE) and (V < CEILBASE + TEXLVL) then
  begin
    Shade := RAMP[1 + (V - CEILBASE) div (TEXLVL - 1)];        { 0..1 }
    Exit;
  end;
  if (V >= FLOORBASE) and (V < FLOORBASE + TEXLVL) then
  begin
    Shade := RAMP[3 + (V - FLOORBASE) div (TEXLVL - 1)];       { 2..3 }
    Exit;
  end;
  case V of
    0        : I := 0;
    C_CEIL   : I := 1;
    C_FLOOR  : I := 3;
    C_DARK   : I := 5;
    C_DARK+1 : I := 5;
    C_DARK+2 : I := 6;
    C_LIT    : I := 8;
    C_LIT+1  : I := 8;
    C_LIT+2  : I := 9;
  else
    I := 2;
  end;
  Shade := RAMP[I + 1];
end;

procedure Thumbnail;
var
  R, C : Integer;
  L    : ShortString;
begin
  WriteLn('  final frame, read back from A000:');
  for R := 0 to 15 do
  begin
    L := '    ';
    for C := 0 to 63 do
      if UseX then
        L := L + Shade(XPeek(C * 5, R * 12 + 4))
      else
        L := L + Shade(Mem[VGA_SEG : (R * 12 + 4) * SCR_W + C * 5]);
    WriteLn(L);
  end;
end;

procedure ShowMap;
var
  R, C : Integer;
  L    : ShortString;
begin
  WriteLn('  maze, and the cells it walked (o):');
  for R := 0 to MAPH - 1 do
  begin
    L := '    ';
    for C := 0 to MAPW - 1 do
      if Visited[R, C] > 0 then L := L + 'o'
      else if Grid[R * MAPW + C] = 0 then L := L + '.'
      else L := L + '#';
    WriteLn(L);
  end;
end;

{ ---------------------------------------------------------------------- }
{  Main                                                                   }
{ ---------------------------------------------------------------------- }

var
  I, Code   : Integer;
  Arg       : ShortString;
  Want      : Integer;        { 0 auto, 1 force FPU, 2 force integer }
  StartTick : LongInt;
  LastTick  : LongInt;
  Now_      : LongInt;
  Elapsed   : LongInt;
  X         : Integer;
  Secs10    : LongInt;
  Cells     : Integer;
  SeedArg   : LongInt;
  GaveSecs  : Boolean;
  Tenths    : LongInt;
  PivMax, PivWas, PivD : Integer;
  R, C      : Integer;
  K         : Integer;      { columns the pivot cache had to cast }

begin
  Want   := 0;
  Hold   := False;
  NoDraw := False;
  NoCast := False;
  Quiet   := False;
  WantSpk := False;
  Textured := True;
  NoWall   := False;
  NoBand   := False;
  NoSeek   := False;
  UsePivot := True;
  DumpCol  := False;
  PivChk   := False;
  PivBad   := False;
  { Mode X by default. It is faster, and more to the point it is the only
    path that can page flip -- a chained 320x200 screen is 64000 bytes and
    only one of those fits in the 64K window, so there is nowhere to build
    the next frame out of sight. Without that the machine draws the ceiling,
    then the floor, then the walls over the top, and at nine frames a second
    you watch it happen. M13 goes back to the old behaviour. }
  WantX  := True;
  UseX   := False;
  NRays  := RAYS_COARSE;
  Budget := RUNSECS * 182 div 10;
  Driven   := False;
  Playing  := False;
  Hooked   := False;
  Quitting := False;
  ScrName  := '';
  NEv      := 0;
  EvPtr    := 0;
  FaceGoal := -1;
  GaveSecs := False;
  FillChar(Held, SizeOf(Held), 0);

  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    for Code := 1 to Length(Arg) do
      if (Arg[Code] >= 'a') and (Arg[Code] <= 'z') then
        Arg[Code] := Chr(Ord(Arg[Code]) - 32);
    if Arg = 'FPU' then Want := 1
    else if Arg = 'INT' then Want := 2
    else if Arg = 'HOLD' then Hold := True
    else if Arg = 'QUIET' then Quiet := True
    else if Arg = 'SPKR' then WantSpk := True
    else if Arg = 'TEX' then Textured := True
    else if Arg = 'FLAT' then Textured := False
    else if Arg = 'NOSEEK' then NoSeek := True
    else if Arg = 'NOPIVOT' then UsePivot := False
    else if Arg = 'DUMPCOL' then DumpCol := True
    else if Arg = 'PIVCHK' then PivChk := True
    else if Arg = 'PIVBAD' then PivBad := True
    else if Arg = 'NOWALL' then NoWall := True
    else if Arg = 'NOBAND' then NoBand := True
    else if Arg = 'NODRAW' then NoDraw := True
    else if Arg = 'NOCAST' then NoCast := True
    { Both of these ask for columns narrower than four pixels, which mode X
      cannot align to a byte, so each implies the chained mode. }
    else if Arg = 'FINE' then begin NRays := RAYS_FINE; WantX := False; end
    else if Arg = 'COARSE' then begin NRays := RAYS_COARSE; WantX := False; end
    else if Arg = 'BLOCKY' then NRays := RAYS_BLOCKY
    else if Arg = 'MODEX' then
    begin
      { Four-pixel columns are a REQUIREMENT of mode X here, not a
        preference: one byte is four pixels, so a narrower run does not
        start on a byte boundary. Forced at parse time because NRays is
        consumed by BuildColumns, which runs long before the card has
        been asked whether it will unchain. Deciding it later left the
        demo drawing 2px columns through a 4px blitter. }
      WantX := True;
      NRays := RAYS_BLOCKY;
    end
    else if Arg = 'M13' then WantX := False
    { KEYS drives it from the keyboard; PLAY drives it from a file of timed
      events. Both stop the maze walking itself, and both feed the same
      Held[] array -- which is what makes the keyboard path testable from
      Windows, where there is nobody to press anything. }
    else if Arg = 'KEYS' then Driven := True
    else if Arg = 'PLAY' then
    begin
      Inc(I);
      if I <= ParamCount then
      begin
        ScrName := ParamStr(I);
        Driven  := True;
        Playing := True;
      end;
    end
    else if Arg = 'SECS' then
    begin
      Inc(I);
      if I <= ParamCount then
      begin
        Val(ParamStr(I), Budget, Code);
        if (Code <> 0) or (Budget < 1) then Budget := RUNSECS;
        GaveSecs := True;
        { 1800 and not 60. The tour is linear in time now and the map is
          sixteen times the area, so a long run genuinely sees more.

          Two things bound it rather than taste. The BIOS tick counter wraps
          at midnight, so a run that straddles it reports nonsense -- half an
          hour makes that unlikely rather than impossible. And dosd times a
          job out at 120s, so anything past about a hundred seconds needs
          dosrun --timeout raising to match or the job is scored as a hang. }
        if Budget > 1800 then Budget := 1800;
        Budget := Budget * 182 div 10;
      end;
    end
    else if Arg = 'SEED' then
    begin
      Inc(I);
      if I <= ParamCount then
      begin
        Val(ParamStr(I), SeedArg, Code);
        if (Code = 0) and (SeedArg > 0) then MazeSeed := Word(SeedArg);
      end;
    end;
    Inc(I);
  end;

  { Mode X cannot draw a column narrower than four pixels: one byte is four
    pixels, so a narrower run would not start on a byte boundary. Applied
    after the WHOLE command line has been read, so the order of arguments
    cannot change the answer -- and before BuildColumns, which consumes
    NRays. Getting that ordering wrong once already had the demo drawing
    two-pixel columns through a four-pixel blitter. }
  if WantX and (NRays > RAYS_BLOCKY) then NRays := RAYS_BLOCKY;

  { A person at the keyboard should not be thrown out after a minute, and
    over the bridge nothing can ask them whether they are finished. Five
    minutes with ESC to quit, unless SECS said otherwise -- bounded rather
    than endless, because an unattended box left in mode X with the INT 9
    vector hooked is a box somebody has to walk to. }
  if Driven and (not GaveSecs) then Budget := 300 * 182 div 10;

  WriteLn('=== raycast ===');
  WriteLn('  CPU            : ', CpuName);
  if HasFpu then
    WriteLn('  coprocessor    : ', FpuName)
  else
    WriteLn('  coprocessor    : none');

  { THE 8087 IS NO LONGER WORTH USING HERE, AND THAT IS A REVERSAL.

    The old advice -- in CLAUDE.md, and measured honestly at the time -- was
    that the coprocessor was worth about 5% of the frame. It was compared
    against a 32-BIT software divide, which BENCH puts at 7280/sec, 137 us.

    The numerator is SCR_H*ONE = 51200, which fits in a word, and Perp is
    clamped positive, so the divide was never 32-bit work in the first
    place. As a 16-bit DIV it is about 90 cycles, and the x87 round trip --
    FILD, FDIVR, FISTP, FWAIT, through memory both ways -- is around 300.

    Measured after that change, same maze, same 30 seconds:

        cast only    FPU 38.8 fps     INT 43.6 fps
        whole frame  FPU 10.1 fps     INT 10.5 fps

    So the integer path is now faster and is the default. FPU still forces
    the coprocessor, because the comparison is the point. }
  UseFpu := (Want = 1);
  if (Want = 1) and (not HasFpu) then
  begin
    WriteLn('  FPU was asked for and there is no coprocessor fitted.');
    WriteLn('  Refusing: x87 arithmetic carries WAIT prefixes, and WAIT with');
    WriteLn('  nothing answering hangs the machine until someone resets it.');
    Halt(1);
  end;

  if UseFpu then
    WriteLn('  perspective    : 8087 (FILD/FDIVR/FISTP) -- slower, see FPU')
  else
    WriteLn('  perspective    : 16-bit DIV per column');
  WriteLn('  rays           : ', NRays, ' at ', SCR_W div NRays,
          ' pixel(s) wide');

  if Quiet then
    WriteLn('  music          : off (QUIET)')
  else if MusicStart(WantSpk) then
  begin
    if MusicDev = mdOpl2 then
      WriteLn('  music          : AdLib/OPL2 at 388h, three voices')
    else
      WriteLn('  music          : PC speaker, one voice -- the melody only');
  end
  else
    WriteLn('  music          : nothing answered, running silent');

  if Driven then
  begin
    if Playing then
    begin
      if not LoadScript(ScrName) then
      begin
        WriteLn('  no usable events in the script; nothing would happen.');
        Halt(4);
      end;
      WriteLn('  driven by      : ', ScrName, ', ', NEv, ' event(s)');
    end
    else
    begin
      { Printed before the mode is set, so it is in the captured output as
        well as on the screen for the half second before the maze appears. }
      WriteLn('  driven by      : the keyboard');
      WriteLn('    move         : W/S or Up/Down       turn : A/D or Left/Right');
      WriteLn('    strafe       : Q/E                  run  : Shift');
      WriteLn('    quit         : Esc');
      { The vector is NOT taken here. It is taken immediately before the
        frame loop -- see below. Between this point and there are the table
        builds, half a second of baking textures, the palette load and the
        mode set, and there is no reason at all for an interrupt handler of
        ours to be live across any of it. A hook is a liability for exactly
        as long as it is installed. }
    end;
  end
  else
    WriteLn('  driven by      : itself, exploring the maze');

  { FLUSH BEFORE ANYTHING THAT COULD HANG.

    FPC buffers Output, so a program that wedges loses whatever has not been
    written yet and the screen's last line is not where it stopped -- it is
    wherever the buffer last happened to fill. KEYS froze once and the only
    thing on screen was the attribution banner, which told us nothing at all
    about where it froze, because everything after it was still in the
    buffer. vmodes.pas already flushes every line for this exact reason.

    From here on the last line on screen is the last thing that ran. }
  Flush(Output);

  BuildSin;
  BuildRays;
  BuildColumns;
  BuildGrid;
  BuildTextures;
  { Informative, and it is also the last thing printed before the screen
    goes graphical -- so if the machine stops with this line showing, it
    stopped in the palette load, the unchain, or taking the INT 9 vector,
    and if the screen is graphical instead it reached the frame loop. }
  WriteLn('  maze built     : ', OpenCells, ' cells open, seed ', MazeSeed0);
  Flush(Output);

  { NODRAW EXISTS TO PRICE THE CAST, AND THE PIVOT CACHE NOW DEFEATS IT.

    Once the walk was properly tick-paced, the camera moves 18.2 times a
    second however many frames are drawn -- and with the drawing gone this
    loops at over 2000 frames a second, so on 99% of them nothing has moved
    and the cache hands back the previous frame's columns for nothing. The
    honest reading of that is 2083 fps casting NOTHING, which is not what
    anybody reaches for NODRAW to find out.

    So NODRAW turns the cache off and casts every frame. That is also what
    the figure meant historically, back when the tick clamp was moving the
    camera on every frame by accident. }
  if NoDraw then CanShift := False;
  { CanShift gates the cache AND the turn snapping that exists only to make
    the cache exact, so clearing it turns off both. }
  if not UsePivot then CanShift := False;

  { Start in the open corner, facing along +x. Cell (1,1) is the first one
    the carve visits, so it is always open. }
  PosX := 1 * 256 + 128;
  PosY := 1 * 256 + 128;
  Ang  := 0;
  FillChar(Visited, SizeOf(Visited), 0);
  Gen           := 1;
  Visited[1, 1] := Gen;
  Dir      := 0;
  HaveTgt  := False;
  Turns    := 0;
  Sweeps   := 0;
  SweepTix := 0;
  Seeks    := 0;
  SeekMiss := 0;
  PathLen  := 0;
  OnPath   := False;
  GetMem(BfsQ,    SizeOf(TIdxArr));
  GetMem(BfsFrom, SizeOf(TCellArr));
  GetMem(Path,    SizeOf(TCellArr));
  GetMem(VisitN,  SizeOf(TCellArr));
  if (VisitN <> nil) then FillChar(VisitN^, SizeOf(TCellArr), 0);
  if (BfsQ = nil) or (BfsFrom = nil) or (Path = nil) or (VisitN = nil) then
  begin
    WriteLn('  out of heap for the flood fill (', 
            SizeOf(TIdxArr) + 3 * SizeOf(TCellArr), ' bytes)');
    Halt(3);
  end;

  Frames   := 0;
  ColsCast := 0;
  RectsHit := 0;
  StepsDDA := 0;
  Reused   := 0;
  RowsBy1  := 0;
  RowsBy2  := 0;
  RowsBy4  := 0;
  Blocked  := 0;

  OldMode := GetMode;
  if WantX then
  begin
    { XEnter reads every register back. A card that ignores one leaves a
      skewed picture rather than no picture, which is much harder to spot. }
    UseX := XEnter;
    if UseX then
    begin
      MapMask($0F);            { one write paints all four planes }
      { Start drawing into page 1 while page 0 -- which the mode set has just
        cleared to black -- is on screen, so the very first frame is not
        assembled in front of the viewer. Every page starts with a full-screen
        dirty band, so its first frame clears the junk left in the two pages
        the mode set never reached. }
      for Code := 0 to NPAGES - 1 do
      begin
        PgTop[Code] := 0;
        PgBot[Code] := SCR_H - 1;
      end;
      ShowBase := 0;
      CurPage  := 1;
      DrawBase := PAGE_SZ;
      XSetStart(0);
    end
    else
      SetMode(MODE13);         { it refused to unchain; carry on chained }
  end
  else
    SetMode(MODE13);
  { Textures are a mode X path only: the blitter writes one byte for four
    pixels, which is what an unchained screen with the map mask at $0F does
    and what a chained one does not. Cleared HERE rather than at parse time
    because UseX is not known until the card has been asked -- getting that
    ordering wrong is what once had the demo drawing two-pixel columns
    through a four-pixel blitter. }
  if not UseX then Textured := False;
  LoadPalette;

  { THE VECTOR IS TAKEN HERE, one statement before the loop that needs it,
    and given back one statement after. It used to be taken before the table
    builds, which left our handler live across half a second of texture
    baking and the mode set for no benefit whatsoever.

    This is narrowing a window rather than fixing a known fault: KEYS froze
    the machine once at the keyboard, hard enough to need a reboot, and it
    has not been reproduced. The handler is the suspect because it is the
    one path in this program that CANNOT be exercised over the bridge --
    nobody is there to press a key, so every run from Windows installs the
    hook and then never executes it. }
  if Driven and (not Playing) then
  begin
    Hooked := KbdInstall;
    if not Hooked then
    begin
      SetMode(OldMode);
      WriteLn('  could not hook INT 9; refusing rather than reading a');
      WriteLn('  keyboard that will not answer.');
      Halt(5);
    end;
  end;

  StartTick := Ticks;
  RunStart  := StartTick;
  LastTick  := StartTick;
  while (Ticks - StartTick) < Budget do
  begin
    if not NoCast then
    begin
      CamPrepare;
      K := NRays;                        { how many columns really get cast }
      if CanShift and (not Moved) and (Frames > 0) then
      begin
        K := AngDelta div RayStep;
        if (K >= NRays) or (K <= -NRays) then
          K := NRays                     { turned further than the screen }
        else
        begin
          if PivBad then Inc(K);        { deliberately wrong, see PivBad }
          if K <> 0 then ShiftColumns(K);
          if K > 0 then
            for X := NRays - K to NRays - 1 do CastColumn(X)
          else
            for X := 0 to -K - 1 do CastColumn(X);
          Inc(ColsCast, Abs(K));
          Inc(Reused, NRays - Abs(K));
          K := -1;                       { done }
        end;
      end;
      if K = NRays then
      begin
        for X := 0 to NRays - 1 do
          CastColumn(X);
        Inc(ColsCast, NRays);
      end;
    end;
    if not NoDraw then DrawFrame;
    Inc(Frames);
    Now_ := Ticks;
    MusicTick(Now_ - StartTick);
    if Driven then
    begin
      if Playing then
      begin
        { Tenths, from the same clock everything else here is paced by. }
        Tenths := ((Now_ - StartTick) * 100) div 182;
        PlayScript(Integer(Tenths));
      end
      else
        PollKeys;
      if Held[A_QUIT] then
      begin
        Quitting := True;
        Break;
      end;
      Steer(Integer(Now_ - LastTick));
    end
    else
      Advance(Integer(Now_ - LastTick));
    LastTick := Now_;
  end;
  { Every exit below this point is after the loop, so one call covers them
    all -- including the two Halts at the end. A voice left ringing is a
    machine droning with nobody able to hear from Windows that it happened. }
  MusicStop;
  { Before the report, before the mode restore, before the Halts at the
    bottom. KbdRemove is idempotent and the unit also hooks ExitProc, so a
    runtime error between here and the end still gives the vector back --
    but the vector should not be ours for a second longer than the frame
    loop needs it. }
  if Hooked then
  begin
    KbdRemove;
    Hooked := False;
  end;
  Elapsed := Ticks - StartTick;
  if Elapsed < 1 then Elapsed := 1;

  { DOES THE PIVOT CACHE ACTUALLY DRIFT? Re-cast every column from the
    camera state the run ended in and see how far the cached frame was out.
    Nothing has moved since the last frame, so a correct cache gives zero.

    No storage needed: CastColumn(X) depends only on X and the camera, so
    the old value can be read one column at a time just before it is
    overwritten. }
  if PivChk then
  begin
    CamPrepare;
    PivMax := 0;
    for X := 0 to NRays - 1 do
    begin
      PivWas := ColTop[X];
      CastColumn(X);
      PivD := ColTop[X] - PivWas;
      if PivD < 0 then PivD := -PivD;
      if PivD > PivMax then PivMax := PivD;
    end;
    WriteLn('  pivot check    : worst column top moved ', PivMax,
            ' row(s) on a fresh cast');
    Write('  per column     :');
    for X := 0 to NRays - 1 do
      if (X and 7) = 0 then Write(' ', ColTop[X]);
    WriteLn;
  end;

  { The column arrays as the last frame left them. Printed before the mode
    is restored only so it sits next to the thumbnail; nothing here touches
    video memory. }
  if DumpCol then
  begin
    WriteLn('  final columns  : X, top, bottom, texture offset');
    for X := 0 to NRays - 1 do
      if (X and 3) = 0 then
        WriteLn('    ', X:3, ' ', ColTop[X]:5, ' ', ColBot[X]:5, ' ',
                ColOfs[X]:6);
  end;

  { The thumbnail has to be read BEFORE the mode is restored: setting a video
    mode clears video memory, so a program that tidies up first leaves nothing
    to photograph. }
  if not Hold then
  begin
    Thumbnail;
    SetMode(OldMode);
  end;

  { Tenths of a second. The BIOS tick is 18.2/sec, so tenths are
    elapsed*10/18.2 = elapsed*100/182 -- NOT elapsed*10/182, which is what
    this said at first and reported a five-second run as 0.5s. }
  Secs10 := (Elapsed * 100) div 182;
  Cells  := 0;
  for R := 0 to MAPH - 1 do
    for C := 0 to MAPW - 1 do
      if Visited[R, C] > 0 then Inc(Cells);

  WriteLn;
  WriteLn('  frames         : ', Frames, ' in ', Secs10 div 10, '.',
          Secs10 mod 10, 's');
  if Secs10 > 0 then
    WriteLn('  frame rate     : ', (Frames * 100) div Secs10, ' centi-fps  (',
            (Frames * 10) div Secs10, '.', ((Frames * 100) div Secs10) mod 10,
            ' fps)')
  else
    WriteLn('  frame rate     : n/a');
  if UsePivot then
    WriteLn('  columns cast   : ', ColsCast, ', ', Reused,
            ' reused by the pivot cache')
  else
    WriteLn('  columns cast   : ', ColsCast,
            ', every column every frame (NOPIVOT)');
  WriteLn('  DDA steps      : ', StepsDDA);
  WriteLn('  fill rects     : ', RectsHit);
  if Driven then
  begin
    if Playing then
      WriteLn('  driven by      : ', ScrName, ', ', EvPtr, ' of ', NEv,
              ' event(s) reached')
    else
      WriteLn('  driven by      : the keyboard');
    if Quitting then
      WriteLn('  ended          : quit was pressed')
    else
      WriteLn('  ended          : the time ran out');
  end
  else
    WriteLn('  cells chosen   : ', Turns, ', ', Blocked,
            ' re-chosen at a wall');
  WriteLn('  maze           : ', MAPW, 'x', MAPH, ', seed ', MazeSeed0,
          ', ', OpenCells, ' cells open');
  if OpenCells > 0 then
    WriteLn('  cells walked   : ', Cells, ' of ', OpenCells, ' open  (',
            (LongInt(Cells) * 100) div OpenCells, '%)')
  else
    WriteLn('  cells walked   : ', Cells, ' -- THE CARVE OPENED NOTHING');
  { A driven run explores whatever it was told to, so neither of these
    means anything there -- and "full sweep: not completed" would read as a
    fault rather than as not applicable. }
  if not Driven then
  begin
    WriteLn('  flood fills    : ', Seeks, ', ', SeekMiss,
            ' found nothing left');
    if SweepTix > 0 then
      WriteLn('  full sweep     : ', (SweepTix * 100) div 182 div 10, '.',
              ((SweepTix * 100) div 182) mod 10, 's, then ', Sweeps,
              ' sweep(s) total')
    else
      WriteLn('  full sweep     : not completed in this run');
  end;
  WriteLn('  retrace giveups: ', RetraceTimeouts);
  { Reported here, not in the header: the header prints before the mode is
    chosen, so the first version asked the question before anything had
    answered it and printed zeroes. }
  if Textured then
    WriteLn('  walls          : textured ', TEXW, 'x', TEXH, ', ', NTEX,
            ' banks, ', NSHADE, ' fog bands')
  else
    WriteLn('  walls          : flat colour (FLAT)');
  if UseX then
    WriteLn('  video          : mode X, unchained, ', NPAGES,
            ' pages, ', FlipWait, ' flip waits')
  else if WantX then
  begin
    WriteLn('  video          : mode 13h -- unchain refused at check ', XFail);
    WriteLn('    readbacks    : SC04=', XSeen[1], ' CR14=', XSeen[2],
            ' CR17=', XSeen[3], ' CR13=', XSeen[4]);
  end
  else
    WriteLn('  video          : mode 13h, chained');
  if MusicNotes > 0 then
    WriteLn('  notes played   : ', MusicNotes, ' over ', MusicLoops + 1,
            ' pass(es) of the theme')
  else
    WriteLn('  notes played   : none (no OPL2, or QUIET)');
  WriteLn;

  if Hold then
  begin
    WriteLn('  HOLD: mode 13h left set. Run VSHOT to photograph it,');
    WriteLn('  then MODE CO80 at the keyboard to get the text screen back.');
  end
  else
    ShowMap;

  WriteLn;
  if Frames < 1 then
  begin
    WriteLn('  --- FAILED: no frames rendered ---');
    Halt(1);
  end;
  { Only the automatic tour is asserted on. A script is allowed to sit
    still and look at a wall, and a person at the keyboard is allowed to do
    whatever they like -- failing those would be asserting on the input and
    not on the program. }
  if (not Driven) and (Cells < 4) then
  begin
    WriteLn('  --- FAILED: never left the starting area ---');
    Halt(2);
  end;
  WriteLn('  --- ok ---');
  Halt(0);
end.
