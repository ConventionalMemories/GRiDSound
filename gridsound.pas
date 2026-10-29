$COMPACT SS(32)
MODULE gridsound;
{ ------------------------------------------------------------------
  GRiDSound 1.0.0 test, by Conventional Memories (C.M._), MIT license.
  Tries every part of the GRiDSound library on the GRiD Compass
  speaker. The library is gsasm.asm (the hardware), gsfile.pas
  (sounds from files or linked in) and gridsound.inc (declarations,
  pasted below). gstest.asm is only for this program: its CPU meter
  and a linked test chime.
  It makes its own test sounds, so no files are needed; S also loads
  Sound~Data~ (made with wav2grid.py) from the same subject, and K
  plays a chime linked into the program (gstest.asm, GsLinked).
  ------------------------------------------------------------------ }
$NOLIST
$INCLUDE (``INCS`Common.Inc~text~)
$INCLUDE (``INCS`OsPasTypes.Inc~text~)
$INCLUDE (``INCS`OsPasProcs.Inc~text~)
$INCLUDE (``INCS`ConPas.Inc~text~)
$INCLUDE (``INCS`Keys.Inc~text~)
$INCLUDE (``INCS`WindowTypes.Inc~text~)
$INCLUDE (``INCS`WindowProcs.Inc~text~)
$LIST

{ ---------- copied from gridsound.inc 1.0.0 ---------- }
{ ------------------------------------------------------------------
  gridsound.inc - GRiDSound 1.0.0: what a program needs to declare.
  By Conventional Memories (C.M._), MIT license (see LICENSE).
  (Version 1.0.0: keep it the same as in gsasm.asm and gsfile.pas.)

  Paste all of this into your program's .pas file, after the $INCLUDE
  lines and before PROGRAM. (gridbuild only copies .pas and .asm files
  to the GRiD, so an $INCLUDE of this file wouldn't be found there.)
  gsfile.pas holds a copy of it too.

  Quick start:
    GsOpen (gsMid);                     sound on, about 7 kHz
    GsSetName ('Boom~Data~', 10, nm);   a file name, length in front
    IF GsLoad (nm, boom) = 0 THEN ...   load it (converted to 7 kHz)
    GsEffect (boom);                    play it on a free voice
    GsLinked (SndSeg, sndBoomOff, sndBoomLen, sndRate, boom);
                                        or: a sound linked into the
                                        .run (bytes made at the open
                                        rate, made by tools/sndlink.py)
    GsStart (0, music, TRUE);           loop a sound on voice 0
    GsTone (5, 200);                    DTMF 5 for 0.2 s
    GsClose;                            ALWAYS, before the program ends
  ------------------------------------------------------------------ }

{ the assembly part (gsasm.asm) }
PUBLIC GsAsm;
	PROCEDURE GsOpen (count: INTEGER);
	PROCEDURE GsClose;
	FUNCTION GsRate: INTEGER;
	FUNCTION GsRunning: INTEGER;
	FUNCTION GsVersion: INTEGER;
	PROCEDURE GsPlay (voice, bSeg, bOff, len, loop: INTEGER);
	PROCEDURE GsStop (voice: INTEGER);
	PROCEDURE GsStopSound (bSeg, bOff: INTEGER);
	FUNCTION GsPlaying (voice: INTEGER): INTEGER;
	PROCEDURE GsVolume (voice, level: INTEGER);
	PROCEDURE GsTone (digit, ms: INTEGER);
	PROCEDURE GsToneOff;
	FUNCTION GsToneBusy: INTEGER;
	PROCEDURE GsToneVol (level: INTEGER);
	PROCEDURE GsSetName (VAR s: BYTES; n: INTEGER; VAR name: BYTES);
	PROCEDURE GsConvInit;
	FUNCTION GsConv (sSeg, sOff, sLen, dSeg, dOff, dLen, step: INTEGER): INTEGER;

{ the Pascal part (gsfile.pas) }
PUBLIC GsFile;

CONST
	{ GsOpen rates: timer 2 counts. More samples a second sound
	  brighter but leave the program less CPU time while sound plays
	  (none is used while it is silent). }
	gsSlow = 121;          { 4277 Hz }
	gsMidLow = 94;         { 5505 Hz }
	gsMid  = 74;           { 6993 Hz: the one to start with }
	gsFast = 61;           { 8484 Hz: two voices leave little CPU }
	{ GsVolume levels: 0 silent, 8 = as recorded, up to 16. The start
	  value is gsVolFast (2 = 25 percent): it plays fastest, the others
	  go through a table and cost a little more CPU time. }
	gsVolFast = 2;
	gsBoth = 2;            { GsStop, GsVolume, GsPlaying: both voices }
	gsStar = 10;           { GsTone digits besides 0-9 }
	gsHash = 11;
	gsMaxLen = 32000;      { bytes in one sound, at the open rate }
	{ GsLoad and GsMake results besides 0 (ok) and OS errors (> 0) }
	gsErrClosed = -1;      { GsOpen wasn't called }
	gsErrEmpty  = -2;      { the file has no samples }
	gsErrMemory = -3;      { not even 1 KB of memory free }

TYPE
	GsBytes = PACKED ARRAY [0..32767] OF BYTE;
	GsPtr = RECORD
		CASE INTEGER OF
			1: (p: Pointer);
			2: (w: ARRAY [0..1] OF INTEGER);   { offset, segment }
			3: (b: ^GsBytes);
		END;
	GsName = PACKED ARRAY [0..63] OF CHAR;     { [0] = length }
	GsSound = RECORD
		ptr: GsPtr;          { the samples: 8 bits, 128 = silence }
		len: INTEGER;        { how many; 0 = nothing loaded }
		rate: INTEGER;       { the file's own rate (Hz) }
		cut: BOOLEAN;        { the file didn't fit: only its start }
		linked: BOOLEAN;     { linked into the program (GsLinked):
		                       GsFree doesn't give it back }
		END;

	FUNCTION GsLoad (VAR name: GsName; VAR snd: GsSound): INTEGER;
	FUNCTION GsMake (len: INTEGER; VAR snd: GsSound): INTEGER;
	PROCEDURE GsLinked (bSeg, bOff, len, rate: INTEGER; VAR snd: GsSound);
	PROCEDURE GsFree (VAR snd: GsSound);
	PROCEDURE GsStart (voice: INTEGER; VAR snd: GsSound; loop: BOOLEAN);
	PROCEDURE GsEffect (VAR snd: GsSound);

{ ---------- end of the gridsound.inc copy ---------- }

{ only for the CPU meter (gstest.asm) }
PUBLIC GsTest;
	FUNCTION TickSetup: INTEGER;
	FUNCTION SpinFor (refreshes: INTEGER): INTEGER;
	FUNCTION TstSndSeg: INTEGER;   { the test chime linked into the .run }
	FUNCTION TstSndOff: INTEGER;
	FUNCTION TstSndLen: INTEGER;

PROGRAM gridsound;

CONST
	maxVol = 16;             { GsVolume: 8 = as the sound is, 2 = fast }
	statusRow = 15;
	msgRow = 17;
	tuneLen = 9;

VAR
	laser, boom, beep, drum, fileSnd, chime: GsSound;
	count: INTEGER;          { the GsOpen rate: gsSlow .. gsFast }
	vol: INTEGER;
	keyCode, res, alive, tunePos, gapLeft, seed: INTEGER;
	tune: ARRAY [0..8] OF INTEGER;
	drumOn, holdOn, quit, tickOk: BOOLEAN;
	nm: GsName;

{ ---------- text ---------- }

PROCEDURE PutNum (v: INTEGER);
VAR digits: ARRAY [0..11] OF CHAR;
	j: INTEGER;
BEGIN
IF v < 0 THEN
	BEGIN
	ConCharOut ('-');
	v := -v;
	END;
j := 0;
REPEAT
	digits[j] := CHR (ORD ('0') + v MOD 10);
	v := v DIV 10;
	j := j + 1;
UNTIL v = 0;
WHILE j > 0 DO
	BEGIN
	j := j - 1;
	ConCharOut (digits[j]);
	END;
END;

{ a version number like 10000 as 1.0.0 }
PROCEDURE PutVersion (v: INTEGER);
BEGIN
PutNum (v DIV 10000);
ConCharOut ('.');
PutNum ((v DIV 100) MOD 100);
ConCharOut ('.');
PutNum (v MOD 100);
END;

{ clears a line and puts the cursor at its start }
PROCEDURE ClearLine (r: INTEGER);
BEGIN
ConMoveCsr (0, r);
ConLineOut ('                                                     ', 53);
ConMoveCsr (0, r);
END;

PROCEDURE ClearMessages;
VAR r: INTEGER;
BEGIN
FOR r := msgRow TO msgRow + 4 DO
	ClearLine (r);
ConMoveCsr (0, msgRow);
END;

{ ---------- the test sounds, made at the open rate ---------- }

{ 0 .. 1023 }
FUNCTION Rnd: INTEGER;
BEGIN
seed := (seed * 25 + 13) MOD 1024;
Rnd := seed;
END;

PROCEDURE FreeSounds;
BEGIN
GsFree (laser);
GsFree (boom);
GsFree (beep);
GsFree (drum);
GsFree (fileSnd);
END;

PROCEDURE MakeSounds;
VAR rate, len, j, p, c, s, a, v, slope, kick: INTEGER;
BEGIN
rate := GsRate;
{ laser: 0.4 s of square wave, falling in pitch, fading }
len := (rate DIV 10) * 4;
IF GsMake (len, laser) = 0 THEN
	BEGIN
	c := 0;
	s := 1;
	slope := len DIV 14 + 1;
	FOR j := 0 TO len - 1 DO
		BEGIN
		p := rate DIV 3000 + j DIV slope;   { half a wave, in samples }
		IF p < 1 THEN p := 1;
		c := c + 1;
		IF c >= p THEN
			BEGIN
			c := 0;
			s := -s;
			END;
		a := 100 - j DIV (len DIV 70 + 1);
		laser.ptr.b^[j] := 128 + s * a;
		END;
	END;
{ boom: 0.8 s of noise, getting duller and fading out }
len := (rate DIV 10) * 8;
IF GsMake (len, boom) = 0 THEN
	BEGIN
	c := 0;
	v := 0;
	FOR j := 0 TO len - 1 DO
		BEGIN
		c := c - 1;
		IF c <= 0 THEN
			BEGIN
			v := Rnd DIV 4 - 128;
			c := 1 + j DIV (len DIV 6 + 1);
			END;
		a := 120 - j DIV (len DIV 120 + 1);
		IF a < 0 THEN a := 0;
		boom.ptr.b^[j] := 128 + (v * a) DIV 128;
		END;
	END;
{ beep: 0.25 s at about 1 kHz }
len := rate DIV 4;
IF GsMake (len, beep) = 0 THEN
	BEGIN
	p := rate DIV 2000;
	IF p < 1 THEN p := 1;
	c := 0;
	s := 1;
	FOR j := 0 TO len - 1 DO
		BEGIN
		c := c + 1;
		IF c >= p THEN
			BEGIN
			c := 0;
			s := -s;
			END;
		beep.ptr.b^[j] := 128 + s * 70;
		END;
	END;
{ drum: half a second to loop (120 a minute): a falling kick for the
  first 1/12 s, a short noise tick in the middle, silence otherwise }
len := rate DIV 2;
IF GsMake (len, drum) = 0 THEN
	BEGIN
	kick := rate DIV 12;
	c := 0;
	s := 1;
	FOR j := 0 TO kick - 1 DO
		BEGIN
		p := rate DIV 500 + j DIV (kick DIV 5 + 1);
		c := c + 1;
		IF c >= p THEN
			BEGIN
			c := 0;
			s := -s;
			END;
		a := 110 - j DIV (kick DIV 110 + 1);
		IF a < 0 THEN a := 0;
		drum.ptr.b^[j] := 128 + s * a;
		END;
	FOR j := 0 TO rate DIV 40 DO
		drum.ptr.b^[len DIV 2 + j] := 128 + ((Rnd DIV 4 - 128) * (60 - j DIV (rate DIV 2400 + 1))) DIV 128;
	END;
END;

{ ---------- the screen ---------- }

PROCEDURE DrawMenu;
BEGIN
WinEraseWindow;
ConMoveCsr (0, 0);
ConLineOut ('GRiDSound 1.0.0 test: background sound', 38);
ConMoveCsr (0, 1);
ConLineOut ('library ', 8);
PutVersion (GsVersion);
ConLineOut (', rate ', 7);
PutNum (GsRate);
ConLineOut (' Hz (timer 2 count ', 19);
PutNum (count);
ConCharOut (')');
ConMoveCsr (0, 3);
ConLineOut ('L laser   B boom   P beep    (each on a free voice)', 51);
ConMoveCsr (0, 4);
ConLineOut ('2  laser and boom at once (both voices)', 39);
ConMoveCsr (0, 5);
ConLineOut ('T  drum loop on/off on voice 0', 30);
ConMoveCsr (0, 6);
ConLineOut ('S  load Sound~Data~ and play it (voice 1)', 41);
ConMoveCsr (0, 7);
ConLineOut ('D  DTMF tune in the background', 30);
ConMoveCsr (0, 8);
ConLineOut ('H  hold DTMF 5 on/off (costs no CPU time)', 41);
ConMoveCsr (0, 9);
ConLineOut ('X  stop everything   K  linked chime (7 kHz)', 44);
ConMoveCsr (0, 10);
ConLineOut ('+ -  volume (2 = 25 percent, the fast one)', 42);
ConMoveCsr (0, 11);
ConLineOut ('4 5 7 8  rate 4.3 / 5.5 / 7.0 / 8.5 kHz', 39);
ConMoveCsr (0, 12);
ConLineOut ('C  CPU meter: how much time the sound leaves', 44);
ConMoveCsr (0, 13);
ConLineOut ('Q  quit          by Conventional Memories (C.M._)', 49);
IF laser.len + boom.len + beep.len + drum.len = 0 THEN
	BEGIN
	ConMoveCsr (0, msgRow);
	ConLineOut ('Out of memory: no test sounds.', 30);
	END;
END;

{ what plays, and a counter that shows the program keeps running }
PROCEDURE PutStatus;
BEGIN
ConMoveCsr (0, statusRow);
ConLineOut ('v0 ', 3);
IF GsPlaying (0) = 1 THEN ConLineOut ('on ', 3) ELSE ConLineOut ('-  ', 3);
ConLineOut (' v1 ', 4);
IF GsPlaying (1) = 1 THEN ConLineOut ('on ', 3) ELSE ConLineOut ('-  ', 3);
ConLineOut (' tone ', 6);
IF GsToneBusy = 1 THEN ConLineOut ('timed', 5)
ELSE IF holdOn THEN ConLineOut ('held ', 5)
ELSE ConLineOut ('-    ', 5);
ConLineOut (' int ', 5);
IF GsRunning = 1 THEN ConLineOut ('on ', 3) ELSE ConLineOut ('off', 3);
ConLineOut (' vol ', 5);
PutNum (vol);
ConLineOut ('  ', 2);
ConMoveCsr (44, statusRow);
PutNum (alive);
ConLineOut ('    ', 4);
END;

{ ---------- the tests ---------- }

PROCEDURE StopAll;
BEGIN
GsStop (gsBoth);
GsToneOff;
tunePos := -1;
drumOn := FALSE;
holdOn := FALSE;
END;

PROCEDURE ChangeRate (c: INTEGER);
BEGIN
StopAll;
FreeSounds;
GsClose;
count := c;
GsOpen (count);
MakeSounds;
DrawMenu;
END;

PROCEDURE LoadFile;
BEGIN
ClearMessages;
ConLineOut ('loading Sound~Data~ ...', 23);
GsFree (fileSnd);
GsSetName ('Sound~Data~', 11, nm);
res := GsLoad (nm, fileSnd);
ClearMessages;
IF res = 0 THEN
	BEGIN
	ConLineOut ('Sound~Data~ loaded: ', 20);
	PutNum (fileSnd.rate);
	ConLineOut (' Hz in the file,', 16);
	ConMoveCsr (0, msgRow + 1);
	PutNum (fileSnd.len);
	ConLineOut (' bytes at ', 10);
	PutNum (GsRate);
	ConLineOut (' Hz, playing on voice 1', 23);
	IF fileSnd.cut THEN
		BEGIN
		ConMoveCsr (0, msgRow + 2);
		ConLineOut ('(cut: longer than 32000 bytes or memory full)', 45);
		END;
	GsStart (1, fileSnd, FALSE);
	END
ELSE
	BEGIN
	ConLineOut ('Sound~Data~ did not load: ', 26);
	IF res = gsErrEmpty THEN ConLineOut ('no samples', 10)
	ELSE IF res = gsErrMemory THEN ConLineOut ('out of memory', 13)
	ELSE IF res = gsErrClosed THEN ConLineOut ('sound not open', 14)
	ELSE
		BEGIN
		ConLineOut ('error ', 6);
		PutNum (res);
		END;
	ConMoveCsr (0, msgRow + 1);
	ConLineOut ('Make it on the PC: python wav2grid.py x.wav', 43);
	ConMoveCsr (0, msgRow + 2);
	ConLineOut ('  --rate 6993 --out Sound~Data~', 31);
	END;
END;

{ "CPU left" for one measurement, against the silent count }
PROCEDURE PutLeft (base: INTEGER);
VAR s: INTEGER;
BEGIN
s := SpinFor (8);
IF base > 0 THEN PutNum (ROUND (100.0 * s / base)) ELSE ConCharOut ('?');
ConLineOut ('%  ', 3);
END;

PROCEDURE CpuMeter;
VAR base: INTEGER;
BEGIN
StopAll;
ClearMessages;
IF NOT tickOk THEN
	ConLineOut ('The refresh counter was not found in the PROM.', 46)
ELSE
	BEGIN
	ConLineOut ('CPU time left for the program at ', 33);
	PutNum (GsRate);
	ConLineOut (' Hz:', 4);
	ConMoveCsr (0, msgRow + 1);
	base := SpinFor (8);       { silent: the interrupt is off }
	ConLineOut ('1 voice ', 8);
	GsStart (0, drum, TRUE);
	PutLeft (base);
	ConLineOut ('2 voices ', 9);
	GsStart (1, laser, TRUE);
	PutLeft (base);
	GsStop (gsBoth);
	ConMoveCsr (0, msgRow + 2);
	ConLineOut ('timed tone ', 11);
	GsTone (5, 2000);
	PutLeft (base);
	ConLineOut ('held tone ', 10);
	GsTone (5, 0);
	PutLeft (base);
	ConLineOut ('silent ', 7);
	GsToneOff;
	PutLeft (base);
	END;
END;

PROCEDURE DoKey;
BEGIN
IF (keyCode >= ORD ('a')) AND (keyCode <= ORD ('z')) THEN keyCode := keyCode - 32;
IF (keyCode = ORD ('Q')) OR (keyCode = cancelKey) THEN
	quit := TRUE
ELSE IF keyCode = ORD ('L') THEN
	GsEffect (laser)
ELSE IF keyCode = ORD ('B') THEN
	GsEffect (boom)
ELSE IF keyCode = ORD ('P') THEN
	GsEffect (beep)
ELSE IF keyCode = ORD ('2') THEN
	BEGIN
	drumOn := FALSE;
	GsStart (0, laser, FALSE);
	GsStart (1, boom, FALSE);
	END
ELSE IF keyCode = ORD ('T') THEN
	BEGIN
	IF drumOn THEN GsStop (0) ELSE GsStart (0, drum, TRUE);
	drumOn := NOT drumOn;
	END
ELSE IF keyCode = ORD ('S') THEN
	LoadFile
ELSE IF keyCode = ORD ('D') THEN
	BEGIN
	holdOn := FALSE;
	tunePos := 0;
	gapLeft := 0;
	END
ELSE IF keyCode = ORD ('H') THEN
	BEGIN
	tunePos := -1;
	IF holdOn THEN GsToneOff ELSE GsTone (5, 0);
	holdOn := NOT holdOn;
	END
ELSE IF keyCode = ORD ('X') THEN
	StopAll
ELSE IF keyCode = ORD ('K') THEN
	GsEffect (chime)
ELSE IF ((keyCode = ORD ('+')) OR (keyCode = ORD ('='))) AND (vol < maxVol) THEN
	BEGIN
	vol := vol + 1;
	GsVolume (gsBoth, vol);
	END
ELSE IF ((keyCode = ORD ('-')) OR (keyCode = ORD ('_'))) AND (vol > 0) THEN
	BEGIN
	vol := vol - 1;
	GsVolume (gsBoth, vol);
	END
ELSE IF keyCode = ORD ('4') THEN
	ChangeRate (gsSlow)
ELSE IF keyCode = ORD ('5') THEN
	ChangeRate (gsMidLow)
ELSE IF keyCode = ORD ('7') THEN
	ChangeRate (gsMid)
ELSE IF keyCode = ORD ('8') THEN
	ChangeRate (gsFast)
ELSE IF keyCode = ORD ('C') THEN
	CpuMeter;
END;

{ the DTMF tune: the next digit once the last one and a short gap
  have passed (each loop of the program is about 20 ms) }
PROCEDURE TuneStep;
BEGIN
IF (tunePos >= 0) AND (GsToneBusy = 0) THEN
	BEGIN
	IF gapLeft > 0 THEN
		gapLeft := gapLeft - 1
	ELSE IF tunePos < tuneLen THEN
		BEGIN
		GsTone (tune[tunePos], 160);
		tunePos := tunePos + 1;
		gapLeft := 2;
		END
	ELSE
		tunePos := -1;
	END;
END;

BEGIN
WinInitDefaultWindow;
WinEraseWindow;
ConDefCsr (FALSE);
laser.len := 0;
boom.len := 0;
beep.len := 0;
drum.len := 0;
fileSnd.len := 0;
{ the chime is in gstest.asm, made at 6993 Hz: right pitch at gsMid }
GsLinked (TstSndSeg, TstSndOff, TstSndLen, 6993, chime);
seed := 1;
alive := 0;
tunePos := -1;
gapLeft := 0;
drumOn := FALSE;
holdOn := FALSE;
quit := FALSE;
{ 1 2 3 2 1 * 0 # 9 }
tune[0] := 1; tune[1] := 2; tune[2] := 3; tune[3] := 2; tune[4] := 1;
tune[5] := gsStar; tune[6] := 0; tune[7] := gsHash; tune[8] := 9;
tickOk := TickSetup = 1;
ConLineOut ('GRiDSound 1.0.0 test: making the test sounds ...', 48);
count := gsMid;
vol := gsVolFast;
GsOpen (count);
GsVolume (gsBoth, vol);
MakeSounds;
DrawMenu;
WHILE NOT quit DO
	BEGIN
	TuneStep;
	alive := (alive + 1) MOD 10000;
	PutStatus;
	IF ConKeyPressed THEN
		BEGIN
		keyCode := ORD (ConCharIn);
		DoKey;
		END
	ELSE
		OsDelay (20);
	END;
StopAll;
GsClose;
FreeSounds;
WinEraseWindow;
ConDefCsr (TRUE);
END.
