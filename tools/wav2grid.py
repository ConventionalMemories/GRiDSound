#!/usr/bin/env python3
"""wav2grid.py 0.2.0 - turns a .wav file into a music file for MusicPlay.

Shipped with GRiDSound 1.0.0 (by Conventional Memories (C.M._), MIT
license): the same file format is what GsLoad reads and what sndlink.py
links into a program. For GRiDSound, use the rate of the GsOpen preset:
    gsSlow --rate 4277   gsMidLow --rate 5505
    gsMid  --rate 6993   gsFast   --rate 8484
For short effects, --compress 0 keeps the punch.

The MusicPlay notes below are kept as they were.

The file is 2 bytes of sample rate (little endian), then 8-bit unsigned
samples (128 = silence). Name it Music~Data~ or MusicA~Data~ ..
MusicE~Data~ and put it next to MusicPlay (keys A-E load those).

Make each file at the rate of the mode you'll play it in, so MusicPlay
plays every byte as it is (any other rate gets skipped or doubled
bytes, which adds hash):
    mode 3  --rate 11730        mode 2  --rate 8480
    L       --rate 7977         mode 1  --rate 4280

What it does to make music sound better on the little speaker and the
8-bit DAC (each can be changed):
  --highpass HZ  cuts the deep bass (default 200). The speaker can't
                 play it, but in most music it is most of the level, so
                 it used up the DAC's range and left the instruments
                 only a few bits.
  --lowpass HZ   cuts everything above HZ, sharply, before the rate is
                 lowered (default: 0.43 x rate). Hi-hats and bright
                 synths above half the rate would otherwise fold back
                 down as noise. Lower it for a warmer, less hissy sound.
  --compress X   0 = off .. 1 = strong (default 0.6): lifts the quiet
                 parts above the DAC's own hiss.
  --start S, --seconds S   the part of the song to keep.

    python wav2grid.py song.wav --rate 11730 --out Music~Data~
    python wav2grid.py song.wav --rate 11730 --lowpass 3500 --compress 0.8

Needs numpy (pip install numpy). Input: 8/16/24/32-bit PCM wav, mono
or stereo, any rate.
"""
import argparse
import struct
import sys
import wave

import numpy as np


def read_wav(path):
    with wave.open(path, "rb") as w:
        ch = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        raw = w.readframes(w.getnframes())
    frames = len(raw) // (width * ch)
    raw = raw[:frames * width * ch]
    if width == 1:
        x = (np.frombuffer(raw, np.uint8).astype(np.float64) - 128) / 128
    elif width == 2:
        x = np.frombuffer(raw, "<i2") / 32768.0
    elif width == 3:
        b = np.frombuffer(raw, np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        x = np.where(v >= 1 << 23, v - (1 << 24), v) / 8388608.0
    elif width == 4:
        x = np.frombuffer(raw, "<i4") / 2147483648.0
    else:
        sys.exit("unsupported sample width %d" % width)
    return x.reshape(-1, ch).mean(axis=1), rate


def band(x, rate, lo, hi):
    """Keeps lo..hi Hz, with short smooth edges, in one FFT."""
    n = len(x)
    f = np.fft.rfftfreq(n, 1.0 / rate)
    spec = np.fft.rfft(x)
    mask = np.ones_like(f)
    if lo > 0:
        t = np.clip((f - lo * 0.7) / (lo * 0.3), 0, 1)
        mask *= 0.5 - 0.5 * np.cos(np.pi * t)
    t = np.clip((hi - f) / (hi * 0.06), 0, 1)
    mask *= 0.5 - 0.5 * np.cos(np.pi * t)
    return np.fft.irfft(spec * mask, n)


def compress(x, rate, amount):
    """Slow automatic gain: quiet parts up, loud parts down."""
    if amount <= 0:
        return x
    blk = max(1, rate // 200)                            # 5 ms steps
    m = len(x) // blk
    if m < 2:
        return x
    e = np.sqrt((x[:m * blk].reshape(m, blk) ** 2).mean(axis=1) + 1e-12)
    env = np.empty(m)
    a_up, a_dn = np.exp(-1 / 2.0), np.exp(-1 / 40.0)     # 10 ms up, 200 ms down
    v = e[0]
    for i in range(m):
        a = a_up if e[i] > v else a_dn
        v = a * v + (1 - a) * e[i]
        env[i] = v
    env = np.maximum(env, env.max() * 0.01)
    gain = (env / env.max()) ** (-amount)
    g = np.interp(np.arange(len(x)), np.arange(m) * blk + blk / 2, gain)
    return x * g


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("wav")
    ap.add_argument("--rate", type=int, default=11730)
    ap.add_argument("--lowpass", type=float, default=0.0)
    ap.add_argument("--highpass", type=float, default=200.0)
    ap.add_argument("--compress", type=float, default=0.6)
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--seconds", type=float, default=0.0)
    ap.add_argument("--out", default="Music~Data~")
    a = ap.parse_args()
    if not 1000 <= a.rate <= 32000:
        sys.exit("--rate must be 1000 .. 32000")
    lp = min(a.lowpass or 0.43 * a.rate, 0.45 * a.rate)

    x, src = read_wav(a.wav)
    x = x[int(a.start * src):]
    if a.seconds > 0:
        x = x[:int((a.seconds + 0.1) * src)]
    if len(x) == 0:
        sys.exit("nothing left to convert")
    x = band(x, src, a.highpass, lp)
    n = int(len(x) * a.rate / src)
    x = np.interp(np.arange(n) * src / a.rate, np.arange(len(x)), x)
    if a.seconds > 0:
        x = x[:int(a.seconds * a.rate)]
    x = compress(x, a.rate, a.compress)
    x = x / (np.percentile(np.abs(x), 99.5) or 1.0)      # a few peaks go over
    x = np.tanh(x * 1.3) / np.tanh(1.3)                  # and are rounded off
    data = np.clip(np.round(128 + x * 127), 0, 255).astype(np.uint8).tobytes()
    with open(a.out, "wb") as f:
        f.write(struct.pack("<H", a.rate))
        f.write(data)
    print("%s: %d samples at %d Hz = %.2f s (highpass %d, lowpass %d, compress %.1f)"
          % (a.out, len(data), a.rate, len(data) / a.rate, a.highpass, lp, a.compress))


if __name__ == "__main__":
    main()
