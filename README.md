# GRiDSound

Background sound for **GRiD Compass** programs: two sampled voices mixed
together, DTMF tones, volume, stop, "is it still playing", sounds loaded
from disk or linked into the program, and a clean shutdown. The program
keeps running while the sound plays.

Version **1.0.0**, by Conventional Memories (C.M._). MIT license.

The Compass has an 8-bit sound DAC but no sound timer interrupt that a
program can use. GRiDSound gets a sample clock from the serial chip: the
8274 sends dummy bytes on the RS-232 port and interrupts each time it can
take the next one, and each interrupt mixes one sample. See
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) for how it works.

## Features

- Two voices mixed in the background, each with its own volume (0-16)
  and an optional loop.
- Four preset rates (4.3, 5.5, 7.0 and 8.5 kHz), or any timer count.
- DTMF tones from the modem's tone chip, timed or held, which play
  alongside the samples.
- Sounds from `~Data~` files (converted to the open rate while loading),
  made in memory, or linked into the `.run` file so a game needs no sound
  files on disk.
- Costs no CPU time while silent: the interrupt switches itself off when
  nothing plays and gives IR0 back.
- PC tools: `wav2grid.py` (.wav to sound file) and `sndlink.py` (sound
  files to a linkable assembly module).

## Requirements

- A GRiD Compass (tested on the 1100 series) running GRiD-OS, with the
  internal modem board (it holds the DTMF chip and the volume DAC).
- Nothing may be plugged into or using the RS-232 port while sound
  plays, since its channel A is the sample clock.
- Pascal-86 and ASM86 on the GRiD to build, for example through a
  GRiD-MAME setup.
- Python 3 for the PC tools. `wav2grid.py` also needs NumPy.

## Files

| File | What it is |
|---|---|
| `gsasm.asm` | The hardware part: interrupt routines, mixer, DTMF chip, volume, start and shutdown |
| `gsfile.pas` | The Pascal part: file loading, made and linked sounds, `GsStart`, `GsEffect` |
| `gridsound.inc` | The declarations a program pastes in |
| `gridsound.pas` | Test program |
| `gstest.asm` | For the test program only: CPU meter and a linked test chime |
| `tools/wav2grid.py` | PC: .wav to GRiD sound file |
| `tools/sndlink.py` | PC: sound files to `sounds.asm` plus Pascal constants |
| `docs/API.md` | Every call |
| `docs/HOW-IT-WORKS.md` | Hardware, interrupt design, timings |

The assembly file is `gsasm.asm`, not `gridsound.asm`, because the test
program is `MODULE gridsound` and an assembly module of the same name
would clash at link time.

## Building the test program

Compiles and link every `.pas` and `.asm` file in the
folder. With another toolchain, compile `gridsound.pas` and `gsfile.pas`,
assemble `gsasm.asm` and `gstest.asm`, and link all four.

Test on real hardware where you can. MAME runs it, but it has no DTMF
chip and its single DAC also picks up the volume DAC writes.

### Test program keys

| Key | Does |
|---|---|
| L B P | laser, boom, beep, each on a free voice |
| 2 | laser and boom at once, one on each voice |
| T | drum loop on voice 0 (then L B P go to voice 1) |
| S | load `Sound~Data~` and play it on voice 1 |
| K | a chime linked into the `.run` (made at 6993 Hz) |
| D | a DTMF tune in the background |
| H | hold DTMF 5 on and off |
| X | stop everything |
| + - | volume of both voices (starts at 2 = 25 percent) |
| 4 5 7 8 | reopen at 4.3 / 5.5 / 7.0 / 8.5 kHz |
| C | CPU meter: time left with 1 voice, 2 voices, a timed tone, a held tone, silence |
| Q | quit |

The test program makes its own sounds at the open rate, so it needs no
files.

## Using it in your program

1. Copy `gsasm.asm`, `gsfile.pas` and `gridsound.inc` into your project
   folder. Don't copy `gstest.asm` or `gridsound.pas`.
2. Paste the contents of `gridsound.inc` into your program's `.pas` file,
   after the `$INCLUDE` lines and before `PROGRAM`. It is pasted rather
   than `$INCLUDE`d because `gridbuild` only copies `.pas` and `.asm`
   files to the GRiD. When you update to a newer GRiDSound, copy the
   three files again and paste the new `gridsound.inc` over the old copy.
3. Use it:

```pascal
VAR nm: GsName; boom: GsSound; res: INTEGER;

GsOpen (gsMid);                    { once, at the start: about 7 kHz }
GsSetName ('Boom~Data~', 10, nm);  { file name, length in front }
res := GsLoad (nm, boom);          { 0 = ok }
...
GsEffect (boom);                   { plays it, the program goes on }
GsTone (5, 200);                   { DTMF 5 for 0.2 s }
...
GsClose;                           { ALWAYS, before the program ends }
```

**Call `GsClose` on every way out** (quit, errors, Code-Esc handling).
The interrupt routine lives in your program's memory. While nothing
plays the interrupt is already off, so a program that forgets `GsClose`
only crashes if it quits in the middle of a sound.

See [docs/API.md](docs/API.md) for every call.

## Making sounds

Convert a .wav on the PC at the rate your program opens:

```
python tools/wav2grid.py boom.wav --rate 6993 --compress 0 --out Boom~Data~
```

| Preset | Count | Rate (`--rate`) |
|---|---|---|
| `gsSlow` | 121 | 4277 |
| `gsMidLow` | 94 | 5505 |
| `gsMid` | 74 | 6993 |
| `gsFast` | 61 | 8484 |

A file at the open rate is only copied while loading. Other rates are
converted on the GRiD (simple, no filtering). `wav2grid` defaults suit
music (it cuts below 200 Hz and evens out the level); `--compress 0`
keeps the punch of short effects. Copy the file to the GRiD disk next to
your program.

### Sounds linked into the .run

With linked sounds, a game needs no `~Data~` files, can't miss one, and
doesn't read the disk for sound. The `.run` grows by the sound bytes, and
a changed sound means a rebuild.

```
python tools/wav2grid.py boom.wav  --rate 4277 --compress 0 --out Boom~Data~
python tools/wav2grid.py laser.wav --rate 4277 --compress 0 --out Laser~Data~
python tools/sndlink.py --rate 4277 Boom=Boom~Data~ Laser=Laser~Data~
```

This writes two files:

- `sounds.asm`: put it in your project folder (`gridbuild` assembles
  it). It holds the samples in a segment of their own and a function
  `SndSeg` that returns that segment.
- `sounds.txt`: paste it into your `.pas` file before `PROGRAM`, next to
  the GRiDSound declarations. It declares `SndSeg` and the constants
  `sndRate`, `sndBoomOff`, `sndBoomLen` and so on.

Then, after `GsOpen (gsSlow)`:

```pascal
GsLinked (SndSeg, sndBoomOff, sndBoomLen, sndRate, boom);
GsEffect (boom);
```

Nothing is converted, so make the sounds at exactly the rate you open.
One segment holds up to 65520 bytes. For more, run `sndlink.py` again
with `--module FX --asm fx.asm --pas fx.txt`, which gives `FxSeg`,
`fxRate` and `fx<Name>Off`/`fx<Name>Len`.

## CPU time

This is the CPU time left for your program while sound plays. Silence
and a held tone (`GsTone (d, 0)`) leave 100%.

These are estimates for 1.0.0 with the voices at volume 2. They come
from clock counts that matched the 0.1.1 measurements on a real Compass
(see [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)):

| | 4.3 kHz | 5.5 kHz | 7.0 kHz | 8.5 kHz |
|---|---|---|---|---|
| 1 voice | 74% | 67% | 58% | 49% |
| 2 voices | 66% | 57% | 45% | 33% |
| timed tone | 80% | 74% | 67% | 60% |

Linked and loaded sounds cost the same. Volume levels other than 2 cost
a little more. At 11.7 kHz one voice would leave about 29% and two
voices don't fit. Press C in the test program to measure your own
machine.

## Limits

- 8-bit unsigned samples, 128 = silence, at most 32000 bytes for a
  loaded sound and 32767 for a linked one.
- One byte per voice per sample, so there is no pitch change.
- Uses the RS-232 port (channel A of the 8274) and IR0 while sound
  plays.

## Status

Tested on real hardware through 0.1.2: two voices mix, the interrupt
switches off and restarts cleanly, DTMF plays alongside samples, no
clicks, quitting in the middle of a sound is safe. Linked sounds were
added in 0.2.0. See [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Conventional Memories
(C.M._).
