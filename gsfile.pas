$COMPACT SS(32)
MODULE GsFile;
{ ------------------------------------------------------------------
  gsfile.pas - GRiDSound 1.0.0: the Pascal part of the GRiDSound
  library, by Conventional Memories (C.M._), MIT license (LICENSE)
  library (keep the version the same as in gsasm.asm and
  gridsound.inc). Copy this file, gsasm.asm and gridsound.inc into a
  program's project folder: gridbuild compiles this file as its own
  module and links it in.

  Loads sound files: 2 bytes of sample rate (low byte first), then
  8-bit unsigned samples, 128 = silence. That is MusicPlay's format,
  made on the PC with wav2grid.py. GsLoad converts the file to the
  rate GsOpen set, so every sound plays one byte a sample interrupt.
  ------------------------------------------------------------------ }
$NOLIST
$INCLUDE (``INCS`Common.Inc~text~)
$INCLUDE (``INCS`OsPasTypes.Inc~text~)
$INCLUDE (``INCS`OsPasProcs.Inc~text~)
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

PRIVATE GsFile;

CONST
	gsChunk = 2048;          { the file is read this much at a time }

{ A sound of len bytes of silence at the open rate, to fill yourself
  (snd.ptr.b^[k] := level). 0, gsErrEmpty (len not 1..gsMaxLen) or
  gsErrMemory. }
FUNCTION GsMake (len: INTEGER; VAR snd: GsSound): INTEGER;
VAR err: WORD;
	k: INTEGER;
BEGIN
snd.len := 0;
snd.rate := GsRate;
snd.cut := FALSE;
snd.linked := FALSE;
IF (len < 1) OR (len > gsMaxLen) THEN
	GsMake := gsErrEmpty
ELSE
	BEGIN
	snd.ptr.p := OsAllocate (WRD (len), err);
	IF err <> okCode THEN
		GsMake := gsErrMemory
	ELSE
		BEGIN
		FOR k := 0 TO len - 1 DO
			snd.ptr.b^[k] := 128;
		snd.len := len;
		GsMake := 0;
		END;
	END;
END;

{ Loads a sound file (name with its length in front: GsSetName) and
  converts it to the open rate. 0 = loaded; gsErrClosed, gsErrEmpty,
  gsErrMemory, or the OS error (> 0) of opening or reading it. Up to
  gsMaxLen bytes after conversion, or what memory holds (down to 1 KB):
  snd.cut says the rest of the file was left out. }
FUNCTION GsLoad (VAR name: GsName; VAR snd: GsSound): INTEGER;
VAR conn, err, n, reserved: WORD;
	st: PACKED ARRAY [0..15] OF BYTE;
	hdr: ARRAY [0..1] OF CHAR;
	chunk, dst: GsPtr;
	rate, fileRate, step, want, outLen, got, made, res: INTEGER;
	known, more: BOOLEAN;
	x: REAL;
BEGIN
snd.len := 0;
snd.rate := 0;
snd.cut := FALSE;
snd.linked := FALSE;
rate := GsRate;
IF rate = 0 THEN
	res := gsErrClosed
ELSE
	BEGIN
	reserved := 0;
	conn := OsAttach (name, oldFileMode, reserved, readAccess, err);
	IF err <> okCode THEN
		res := ORD (err)
	ELSE
		BEGIN
		OsOpen (conn, 1, err);
		res := 0;
		n := OsRead (conn, hdr, 2, err);
		IF (err <> okCode) OR (ORD (n) < 2) THEN
			res := gsErrEmpty
		ELSE
			BEGIN
			fileRate := ORD (hdr[0]) + 256 * ORD (hdr[1]);
			IF (fileRate < 1000) OR (fileRate > 32000) THEN fileRate := 8000;
			{ the step through the file, 8.8: 256 = every byte }
			x := fileRate / rate * 256.0;
			IF x < 1.0 THEN x := 1.0;
			IF x > 32000.0 THEN x := 32000.0;
			step := ROUND (x);
			{ the file's length is in its status record, bytes 7-10
			  (OS reference 7-34); with it the sound gets just the
			  memory it needs }
			known := FALSE;
			OsGetStatus (conn, st, 11, err);
			IF (err = okCode) AND (st[0] <> 0) AND (st[9] = 0) AND (st[10] = 0) THEN
				BEGIN
				known := TRUE;
				x := (ORD (st[7]) + 256.0 * ORD (st[8]) - 2.0) * 256.0 / step;
				END;
			IF known AND (x < gsMaxLen - 2.0) THEN
				want := TRUNC (x) + 2
			ELSE
				want := gsMaxLen;
			IF want < 2 THEN want := 2;
			{ as much memory as it needs, or as there is (down to 1 KB) }
			outLen := want;
			dst.p := OsAllocate (WRD (outLen), err);
			WHILE (err <> okCode) AND (outLen > 1024) DO
				BEGIN
				outLen := outLen DIV 2;
				dst.p := OsAllocate (WRD (outLen), err);
				END;
			IF err <> okCode THEN
				res := gsErrMemory
			ELSE
				BEGIN
				chunk.p := OsAllocate (WRD (gsChunk), err);
				IF err <> okCode THEN
					BEGIN
					OsFree (dst.p, err);
					res := gsErrMemory;
					END
				ELSE
					BEGIN
					GsConvInit;
					made := 0;
					more := TRUE;
					WHILE more DO
						BEGIN
						n := OsRead (conn, chunk.b^[0], WRD (gsChunk), err);
						got := ORD (n);
						IF got <= 0 THEN
							more := FALSE
						ELSE
							BEGIN
							made := GsConv (chunk.w[1], chunk.w[0], got,
								dst.w[1], dst.w[0], outLen, step);
							IF made >= outLen THEN more := FALSE;
							END;
						END;
					OsFree (chunk.p, err);
					IF made <= 0 THEN
						BEGIN
						OsFree (dst.p, err);
						res := gsErrEmpty;
						END
					ELSE
						BEGIN
						snd.ptr := dst;
						snd.len := made;
						snd.rate := fileRate;
						{ a known length leaves 2 bytes spare, so a full
						  sound means the file didn't fit }
						snd.cut := made >= outLen;
						END;
					END;
				END;
			END;
		reserved := 0;
		OsClose (conn, reserved);
		reserved := 0;
		OsDetach (conn, reserved);
		END;
	END;
GsLoad := res;
END;

{ A sound that is linked into the program (bytes in an assembly
  module, made at the open rate: nothing is converted). bSeg:bOff is
  where it starts, len its bytes (1..32767), rate the rate it was made
  at (only kept in snd.rate). GsFree on it just stops it. }
PROCEDURE GsLinked (bSeg, bOff, len, rate: INTEGER; VAR snd: GsSound);
BEGIN
snd.ptr.w[0] := bOff;
snd.ptr.w[1] := bSeg;
IF len < 0 THEN len := 0;
snd.len := len;
snd.rate := rate;
snd.cut := FALSE;
snd.linked := TRUE;
END;

{ Stops a sound if a voice plays it, and gives its memory back (not
  for a linked sound: that memory is part of the program). }
PROCEDURE GsFree (VAR snd: GsSound);
VAR err: WORD;
BEGIN
IF snd.len > 0 THEN
	BEGIN
	GsStopSound (snd.ptr.w[1], snd.ptr.w[0]);
	IF NOT snd.linked THEN OsFree (snd.ptr.p, err);
	snd.len := 0;
	END;
END;

{ Plays a sound on voice 0 or 1, once or (loop) over and over. }
PROCEDURE GsStart (voice: INTEGER; VAR snd: GsSound; loop: BOOLEAN);
BEGIN
IF snd.len > 0 THEN
	GsPlay (voice, snd.ptr.w[1], snd.ptr.w[0], snd.len, ORD (loop));
END;

{ Plays a sound once on voice 0 if it is free, else on voice 1 (which
  then stops what it played). Keep voice 0 for music to have effects
  always take voice 1. }
PROCEDURE GsEffect (VAR snd: GsSound);
BEGIN
IF GsPlaying (0) = 0 THEN
	GsStart (0, snd, FALSE)
ELSE
	GsStart (1, snd, FALSE);
END;

.
