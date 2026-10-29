# Changelog

GRiD version scheme: x.y.z, where 0.x.x are test builds and 1.0.0 is
the first release.

## 1.0.0 (2026-10-29)

First release.

- Same library as 0.2.0. Version numbers, comments and docs cleaned up
  for publishing.
- New PC tool `tools/sndlink.py`: turns sound files into `sounds.asm`
  (samples in their own segment plus `SndSeg`) and the Pascal constants
  for `GsLinked`.
- `wav2grid.py` notes the GRiDSound rates.
- Docs: `README.md`, `docs/API.md`, `docs/HOW-IT-WORKS.md`.

## 0.2.0 (2026-10-27)

- `GsLinked`: sounds linked into the program's `.run` file, so a program
  needs no sound files on disk.
- `GsSound` has a new field `linked`; `GsFree` only stops a linked sound.
- Test program: key K plays a chime linked into the `.run`.

## 0.1.2 (2026-10-26)

- Volume level 2 (25 percent) is the start value and a fast path: no
  volume table, and two fast voices need no clip check.
- The 8274's own end of interrupt is no longer sent with each sample
  (tested: not needed).
- New rate preset `gsMidLow` (count 94, 5.5 kHz).
- 32 interrupt routine entries (voices, tone, table or fast volume).

## 0.1.1 (2026-10-26)

- One interrupt routine for each state instead of one routine that
  checks everything. About 25 percentage points more CPU time left at
  7 kHz, and 8.5 kHz works.

## 0.1.0 (2026-10-26)

- First test build: two mixed voices on the 8274 transmit interrupt,
  DTMF tones, volume, file loading with rate conversion, clean shutdown.
- Crashed at 8.5 kHz with one voice.
