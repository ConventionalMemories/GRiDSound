# How GRiDSound works

## The problem

The GRiD Compass has an 8-bit sound DAC, but no timer interrupt that a
program can use as a sample clock. The PROM's tick (IR3) runs at only
about 56 Hz, and the 80130's timers don't reach an interrupt line. To play
sampled sound you would have to write each byte in a timed loop, and the
program would stop while the sound plays.

## The sample clock: the serial chip

Channel A of the 8274 serial chip (the RS-232 port) can send in async
mode with nothing plugged in. With its transmit interrupt on, it
interrupts on IR0 each time it is ready for the next byte. Timer 2 of the
80130 clocks the serial chip, so it sets the byte rate. In x1 mode with
8N1 framing:

```
sample rate = about 517500 / timer 2 count
```

| Count | Rate |
|---|---|
| 121 | 4.28 kHz |
| 94 | 5.5 kHz (calculated) |
| 74 | 7.0 kHz |
| 61 | 8.48 kHz |
| 44 | 11.73 kHz |

Each interrupt writes one mixed sample to the DAC and a dummy byte to the
serial chip, which starts the next interrupt. This approach was found
with the SoundTest program and first used in the MusicPlay player.

## Hardware used

| Address | What |
|---|---|
| DFE4:0002 | sound DAC (8 bits) |
| DFE4:0004 | volume DAC of the DTMF chip |
| DFEC:0002 | 8255 port B: DTMF digit code + 80H, FFH = no digit |
| DFEC:0006 | 8255 control: 01H sets PC0 (voice mode), 00H clears it |
| DFF0:0000 | 8274 channel A data |
| DFF0:0004 | 8274 channel A control |
| ports 0, 2 | 80130 interrupt controller (IR0 = serial chip), specific EOI 60H |
| ports 0CH, 0EH | timer 2 (mode 0B6H) |

The DAC and the serial data register are both reached through segment
DFE4 (the serial data is at offset 0C0H), so one segment load per sample
covers both.

The 8274 is set up with: 18H (channel reset), WR4 = 04H (x1, 1 stop bit),
WR3 = 0C0H (8 bits, receiver off), WR5 = 68H (8 bits, sender on, DTR and
RTS off), and WR1 = 02H (transmit interrupt on) or 00H (off).

DTMF digit codes for 0-9, * and #: 3DH, 76H, 75H, 73H, 6EH, 6DH, 6BH, 5EH,
5DH, 5BH, 3EH, 3BH.

## Only running while something plays

The interrupt is on only while a voice plays or a timed tone counts.
When everything has ended, the routine itself turns the serial chip's
interrupt off and puts the old IR0 vector and mask bit back. A silent
program pays nothing, and a program that forgot `GsClose` only crashes
if it quits while a sound is playing. The next `GsPlay` or timed `GsTone`
starts the interrupt again with `WR1 = 2` and a first dummy byte.

IR3 (the PROM tick) is never masked, so the keyboard, the clock and the
rest of GRiD-OS keep working.

## One routine for each state

The first version (0.1.0) had one interrupt routine that checked
everything on each sample: which voices play, their volumes, looping,
the tone timer. That cost about 410 clocks per sample before any mixing,
and 8.5 kHz crashed.

Since 0.1.1 there is one routine for each state. The state has five bits:

| Bit | Value | Meaning |
|---|---|---|
| 1 | 2 | voice 0 plays |
| 2 | 4 | voice 1 plays |
| 3 | 8 | a timed tone counts down |
| 4 | 16 | voice 0 uses its volume table |
| 5 | 32 | voice 1 uses its volume table |

`isrTab` has 32 entries pointing at routines named after what they do:
`A` is voice 0 and `B` is voice 1, `f` is fast and `t` is through a
table, and a final `T` means the tone timer runs. So the routines are
`IsrAf`, `IsrAt`, `IsrBf`, `IsrBt`, `IsrAfBf`, `IsrAfBt`, `IsrAtBf`,
`IsrAtBt`, each with a `T` version, plus `IsrT` for a tone alone.

When a voice ends, a tone runs out, or a call changes what plays or a
volume, `Reselect` writes the IR0 vector for the new state, or calls
`IrqOff` when nothing plays. A routine never tests a flag it doesn't
need.

## Volume and mixing

Each voice has a volume level from 0 to 16, where 8 plays the sound as
recorded. Levels go through a 256-byte signed table per voice
(`(byte - 128) × level / 8`, clipped to -128..127), read with `XLAT`.
The two voices are added and clipped.

Level 2 (25 percent) is the start value and a fast path: two `SHR`
instructions and an add instead of the table. Two fast voices can't
overflow, so that mix needs no clip check.

The 8274 doesn't need its own end of interrupt (38H) for each sample.
That was tested on a real Compass in 0.1.2 and saves about 19 clocks.

## Timings

The CPU runs at 5 MHz. The clock counts from the 8086 book matched the
0.1.1 measurements closely, which is what the later estimates rest on.

Measured with 0.1.1 (volume tables) on a real Compass, CPU time left for
the program:

| | 4.3 kHz | 7.0 kHz | 8.5 kHz |
|---|---|---|---|
| 1 voice (~320 clocks/sample) | 71% | 53% | 43% |
| 2 voices (~425 clocks/sample) | 62% | 38% | 25% |
| timed tone (~245 clocks/sample) | 78% | 63% | 56% |

0.1.0 for comparison: 56/44/63% at 4.3 kHz, 28/10/40% at 7 kHz, and a
crash at 8.5 kHz.

Estimated for 0.1.2 through 1.0.0 (fast volume, no 8274 EOI):

| | 4.3 kHz | 5.5 kHz | 7.0 kHz | 8.5 kHz |
|---|---|---|---|---|
| 1 voice | 74% | 67% | 58% | 49% |
| 2 voices | 66% | 57% | 45% | 33% |
| timed tone | 80% | 74% | 67% | 60% |

At 11.7 kHz one voice would leave about 29%, and two voices don't fit.

## Loading and converting

`GsLoad` reads a file in 2 KB chunks and converts it to the open rate as
it reads, stepping through the source by a fixed-point (8.8) step
(`GsConv`). The length comes from the file's status record. Without
filtering, a big rate drop can sound harsh, so make files at the open
rate when you can; then the loader only copies.

## Linked sounds

`sndlink.py` puts the samples in an assembly module, in a segment of
their own (`SEGMENT PUBLIC 'DATA'`, outside CGROUP and DGROUP), with a
function that returns that segment:

```asm
SNDSEG  PROC    NEAR
        MOV     AX, SOUNDSDAT
        RET
SNDSEG  ENDP
```

The GRiD loader relocates the segment, so `MOV AX, SOUNDSDAT` gives its
address at run time. `GsLinked` fills a `GsSound` from that segment, an
offset and a length, and marks it `linked` so `GsFree` doesn't give its
memory back.

ASM86 notes for anyone writing such modules by hand: hex numbers must
start with a digit (`0A0H`), and the percent sign is the macro character
even inside comments, so it must not appear anywhere in the file.

## MAME

GRiDSound runs in MAME's GRiD Compass driver, but the DTMF chip is not
emulated (tones are silent), MAME's single DAC also catches the volume
DAC writes (so `GsOpen`, `GsClose` and `GsToneVol` click), and CPU
timings differ from real hardware.
