# GRiDSound 1.0.0 API

All declarations are in `gridsound.inc`, which you paste into your
program before `PROGRAM`. The assembly calls are in `gsasm.asm` (module
`GsAsm`) and the Pascal calls in `gsfile.pas` (module `GsFile`).

A **voice** is 0 or 1. Where a call says "any other number", that
includes `gsBoth` (2).

## Starting and stopping

### `PROCEDURE GsOpen (count: INTEGER)`
Gets the sound ready. Timer 2 is set to `count`, so the sample rate is
about 517500 / count. The serial chip, the volume tables and the DTMF
chip are set up, and the DAC is ramped to the middle (silence). Nothing
plays and no interrupt runs until `GsPlay` or a timed `GsTone`. Does
nothing if GRiDSound is already open; call `GsClose` first to change the
rate.

| Constant | Count | Rate |
|---|---|---|
| `gsSlow` | 121 | 4277 Hz |
| `gsMidLow` | 94 | 5505 Hz |
| `gsMid` | 74 | 6993 Hz (a good start) |
| `gsFast` | 61 | 8484 Hz |

Any count from 20 up works.

### `PROCEDURE GsClose`
Stops the voices, the tone and the interrupt. It puts the IR0 vector and
mask back as they were before `GsOpen`, resets the serial chip, ramps the
DAC down, and leaves the sound hardware as the PROM does. Call it before
your program ends, on every way it can end. It is safe to call more than
once.

### `FUNCTION GsRate: INTEGER`
The open sample rate in Hz, or 0 when GRiDSound is closed.

### `FUNCTION GsRunning: INTEGER`
1 while the sample interrupt is on, 0 otherwise.

### `FUNCTION GsVersion: INTEGER`
major × 10000 + minor × 100 + fix, so 10000 = 1.0.0.

## Sounds

```pascal
GsSound = RECORD
    ptr: GsPtr;        { the samples: 8 bits, 128 = silence }
    len: INTEGER;      { how many; 0 = nothing loaded }
    rate: INTEGER;     { the file's own rate (Hz) }
    cut: BOOLEAN;      { the file didn't fit: only its start }
    linked: BOOLEAN;   { linked into the program (GsLinked) }
END;
```

`GsPtr` is a variant record: `p` (a `Pointer`), `w[0]`/`w[1]`
(offset, segment), or `b` (`^GsBytes`, for `snd.ptr.b^[i]`).

### `FUNCTION GsLoad (VAR name: GsName; VAR snd: GsSound): INTEGER`
Loads a sound file and converts it to the open rate, so call it after
`GsOpen`, and again after reopening at another rate. The file format is
2 bytes of sample rate (low byte first), then 8-bit unsigned samples.
Make the name with `GsSetName`.

It loads up to `gsMaxLen` (32000) bytes after conversion, or as much as
memory holds (down to 1 KB). `snd.cut` is TRUE when the rest of the file
was left out.

Returns 0 when loaded, `gsErrClosed` (-1) when `GsOpen` wasn't called,
`gsErrEmpty` (-2) when the file has no samples, `gsErrMemory` (-3) when
not even 1 KB is free, or the OS error (> 0) from opening or reading the
file.

### `FUNCTION GsMake (len: INTEGER; VAR snd: GsSound): INTEGER`
A sound of `len` bytes of silence (128) at the open rate, for you to fill
with `snd.ptr.b^[k] := level`. Returns 0, `gsErrEmpty` when `len` is
not 1..`gsMaxLen`, or `gsErrMemory`.

### `PROCEDURE GsLinked (bSeg, bOff, len, rate: INTEGER; VAR snd: GsSound)`
A sound that is part of your program: `len` bytes (1..32767) at
`bSeg:bOff`, made at `rate`. Nothing is converted and `rate` is only
kept in `snd.rate`, so make the bytes at the rate you open. It works
before or after `GsOpen`, and the offset needs no alignment.
`tools/sndlink.py` writes the module and constants for it:

```pascal
GsLinked (SndSeg, sndBoomOff, sndBoomLen, sndRate, boom);
```

### `PROCEDURE GsFree (VAR snd: GsSound)`
Stops the sound if a voice plays it and gives its memory back. A linked
sound is only stopped, since its memory is part of the program. Sets
`snd.len` to 0.

### `PROCEDURE GsSetName (VAR s: BYTES; n: INTEGER; VAR name: BYTES)`
`name` gets the `n` characters of `s` with a length byte in front, the
way `OsAttach` wants a path:

```pascal
GsSetName ('Boom~Data~', 10, nm);    { nm: GsName }
```

## Playing

### `PROCEDURE GsStart (voice: INTEGER; VAR snd: GsSound; loop: BOOLEAN)`
Plays `snd` on a voice from the start, once, or over and over when
`loop` is TRUE. Whatever that voice played before stops. Does nothing
for an empty sound.

### `PROCEDURE GsEffect (VAR snd: GsSound)`
Plays `snd` once on voice 0 if it is free, otherwise on voice 1 (which
then stops what it played). If you keep looping music on voice 0, every
effect goes to voice 1.

### `PROCEDURE GsPlay (voice, bSeg, bOff, len, loop: INTEGER)`
The raw call under `GsStart`: plays `len` bytes from `bSeg:bOff` on
voice 0 or 1 (any other number means voice 1), looping when `loop` <> 0.
The bytes must stay where they are while they play.

### `PROCEDURE GsStop (voice: INTEGER)`
Stops voice 0 or 1. Any other number (`gsBoth`) stops both.

### `PROCEDURE GsStopSound (bSeg, bOff: INTEGER)`
Stops any voice that plays the sound starting at `bSeg:bOff`. `GsFree`
calls it.

### `FUNCTION GsPlaying (voice: INTEGER): INTEGER`
1 while voice 0 or 1 plays. For any other number, 1 if either plays.

### `PROCEDURE GsVolume (voice, level: INTEGER)`
The volume of voice 0 or 1 (any other number: both). 0 is silent, 8
plays the sound as recorded, and up to 16 is twice as loud (with
clipping). The volume is kept across `GsClose` and `GsOpen`. It starts at
`gsVolFast` (2, 25 percent), which is the fastest level. Every other
level goes through a table and costs a little more CPU time.

## DTMF tones

The tones come from the modem board's tone chip, separate from the DAC,
so they play alongside the samples.

### `PROCEDURE GsTone (digit, ms: INTEGER)`
Digit 0-9, `gsStar` (10) or `gsHash` (11). Any other number turns the
tone off. With `ms` > 0 the tone stops by itself after that many
milliseconds; the sample interrupt counts the time, so it runs for the
tone. With `ms` = 0 the tone plays until `GsToneOff` or the next
`GsTone` and costs no CPU time.

### `PROCEDURE GsToneOff`
Stops the tone.

### `FUNCTION GsToneBusy: INTEGER`
1 while a timed tone plays.

### `PROCEDURE GsToneVol (level: INTEGER)`
The tone chip's volume DAC, 0-255. It is 255 after `GsOpen`.

## Internal calls

`GsConvInit` and `GsConv (sSeg, sOff, sLen, dSeg, dOff, dLen, step)` do
the rate conversion for `GsLoad`, one chunk at a time, stepping through
the source by step / 256 per byte. You don't need them.

## Constants

| Name | Value | Use |
|---|---|---|
| `gsSlow`, `gsMidLow`, `gsMid`, `gsFast` | 121, 94, 74, 61 | `GsOpen` counts |
| `gsVolFast` | 2 | the fast volume level |
| `gsBoth` | 2 | both voices |
| `gsStar`, `gsHash` | 10, 11 | DTMF * and # |
| `gsMaxLen` | 32000 | most bytes in a loaded or made sound |
| `gsErrClosed`, `gsErrEmpty`, `gsErrMemory` | -1, -2, -3 | `GsLoad` / `GsMake` results |
