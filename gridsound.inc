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
