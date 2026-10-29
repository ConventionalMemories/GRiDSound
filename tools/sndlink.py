#!/usr/bin/env python3
"""sndlink.py - GRiDSound 1.0.0: links sounds into a GRiD Compass program.

Turns sound files into an ASM-86 module that holds the samples in a
segment of their own, plus the Pascal lines that tell the program where
each sound is. The program then plays them with GsLinked, without any
sound files on disk.

Input files are wav2grid.py's output (2 bytes of sample rate, low byte
first, then 8-bit unsigned samples, 128 = silence), named NAME=FILE, or
just FILE (the name is then made from the file name). All sounds must be
at the rate the program opens GRiDSound with: nothing is converted on
the GRiD.

    python wav2grid.py boom.wav --rate 4277 --out Boom~Data~
    python wav2grid.py laser.wav --rate 4277 --out Laser~Data~
    python sndlink.py --rate 4277 Boom=Boom~Data~ Laser=Laser~Data~

writes sounds.asm (put it in the program's project folder: gridbuild
assembles and links every .asm file there) and sounds.txt (paste it into
the program's .pas file before PROGRAM, next to gridsound.inc). Then:

    GsLinked (SndSeg, sndBoomOff, sndBoomLen, sndRate, boom);

Options: --rate HZ (required; files at another rate are an error unless
--any-rate), --asm FILE, --pas FILE, --module NAME (default SOUNDS; the
Pascal PUBLIC name and the asm NAME; another name also renames the
constants, e.g. --module FX gives FxSeg, fxRate, fx<Name>Off), --raw (input files have no 2-byte
rate header).
"""

import argparse
import os
import re
import sys

VERSION = '1.0.0'
MAX_SOUND = 32767       # GsLinked takes an INTEGER length
MAX_SEGMENT = 65520     # one 8086 segment


def pascal_name(text):
    """A Pascal identifier part: letters and digits, first letter upper."""
    words = re.findall(r'[A-Za-z0-9]+', text)
    name = ''.join(w[:1].upper() + w[1:] for w in words)
    if not name or not name[0].isalpha():
        name = 'S' + name
    return name


def hexbyte(b):
    """ASM-86 hex: a number must start with a digit (0A0H, not A0H)."""
    s = '%02XH' % b
    return '0' + s if s[0] in 'ABCDEF' else s


def main():
    ap = argparse.ArgumentParser(description='Link sounds into a GRiD Compass program (GRiDSound %s).' % VERSION)
    ap.add_argument('sounds', nargs='+', help='NAME=FILE or FILE (wav2grid output)')
    ap.add_argument('--rate', type=int, required=True, help='the rate the program opens GRiDSound at, e.g. 4277')
    ap.add_argument('--any-rate', action='store_true', help='allow files at another rate (they play at the wrong pitch)')
    ap.add_argument('--raw', action='store_true', help='files are bare samples, no 2-byte rate header')
    ap.add_argument('--asm', default='sounds.asm', help='assembly module to write (default sounds.asm)')
    ap.add_argument('--pas', default='sounds.txt', help='Pascal lines to write (default sounds.txt)')
    ap.add_argument('--module', default='SOUNDS', help='module name (default SOUNDS)')
    a = ap.parse_args()

    module = re.sub(r'[^A-Za-z0-9]', '', a.module).upper()
    if not module or not module[0].isalpha():
        sys.exit('--module needs letters and digits, starting with a letter')

    sounds = []
    names = set()
    for arg in a.sounds:
        if '=' in arg:
            name, path = arg.split('=', 1)
        else:
            path = arg
            name = os.path.basename(arg).split('~')[0].split('.')[0]
        name = pascal_name(name)
        if name.lower() in names:
            sys.exit('two sounds are called %s' % name)
        names.add(name.lower())
        with open(path, 'rb') as f:
            data = f.read()
        if not a.raw:
            if len(data) < 2:
                sys.exit('%s: too short for a sound file' % path)
            rate = data[0] + 256 * data[1]
            data = data[2:]
            if rate != a.rate and not a.any_rate:
                sys.exit('%s is at %d Hz, not %d Hz: make it with wav2grid.py --rate %d '
                         '(or use --any-rate)' % (path, rate, a.rate, a.rate))
        if not data:
            sys.exit('%s has no samples' % path)
        if len(data) > MAX_SOUND:
            sys.exit('%s has %d samples, at most %d fit one sound' % (path, len(data), MAX_SOUND))
        sounds.append((name, path, data))

    total = sum(len(d) for _, _, d in sounds)
    if total > MAX_SEGMENT:
        sys.exit('%d bytes in all: one segment holds at most %d. Split the sounds over two runs '
                 'with different --module names (and --asm / --pas files).' % (total, MAX_SEGMENT))

    seg = module[:6] + 'DAT'          # the data segment's name
    if module == 'SOUNDS':
        func, pre = 'SndSeg', 'snd'
    else:
        func = pascal_name(module.lower()) + 'Seg'
        pre = func[0].lower() + func[1:-3]
    asm = []
    w = asm.append
    w('; %s - written by sndlink.py %s (GRiDSound): %d sound(s), %d bytes,' %
      (os.path.basename(a.asm), VERSION, len(sounds), total))
    w('; %d Hz, 8-bit unsigned, 128 = silence. Made by a tool: make it again' % a.rate)
    w('; rather than edit it.')
    w('')
    w('\t\tNAME\t%s' % module)
    w('')
    w('%s\t\tSEGMENT\tPUBLIC \'DATA\'' % seg)
    offset = 0
    places = []
    for name, path, data in sounds:
        w('; %s: %s, %d bytes at offset %d' % (name, os.path.basename(path), len(data), offset))
        w('%s%s\t\tLABEL\tBYTE' % (pre, name))
        for k in range(0, len(data), 12):
            w('\t\tDB\t' + ', '.join(hexbyte(b) for b in data[k:k + 12]))
        places.append((name, offset, len(data)))
        offset += len(data)
    w('%s\t\tENDS' % seg)
    w('')
    w('CGROUP\t\tGROUP\tCODE')
    w('')
    w('CODE\t\tSEGMENT\tPUBLIC \'CODE\'')
    w('\t\tASSUME\tCS:CGROUP, DS:NOTHING, ES:NOTHING')
    w('\t\tPUBLIC\t%s' % func.upper())
    w('')
    w('; FUNCTION %s: INTEGER   the segment the sounds are in' % func)
    w('%s\t\tPROC\tNEAR' % func.upper())
    w('\t\tMOV\tAX, %s' % seg)
    w('\t\tRET')
    w('%s\t\tENDP' % func.upper())
    w('')
    w('CODE\t\tENDS')
    w('\t\tEND')
    text = '\n'.join(asm) + '\n'
    assert '%' not in text            # ASM-86 reads it as a macro call
    with open(a.asm, 'w', newline='\r\n') as f:
        f.write(text)

    pas = []
    p = pas.append
    p('{ %s - written by sndlink.py %s (GRiDSound): paste it into the' % (os.path.basename(a.pas), VERSION))
    p('  program before PROGRAM. %d sound(s) at %d Hz, %d bytes, in %s. }' %
      (len(sounds), a.rate, total, os.path.basename(a.asm)))
    p('PUBLIC %s;' % module.capitalize())
    p('\tFUNCTION %s: INTEGER;' % func)
    p('CONST')
    p('\t%sRate = %d;' % (pre, a.rate))
    for name, off, n in places:
        p('\t%s%sOff = %d; %s%sLen = %d;' % (pre, name, off, pre, name, n))
    p('{ for each: GsLinked (%s, %s<Name>Off, %s<Name>Len, %sRate, sound); }' % (func, pre, pre, pre))
    with open(a.pas, 'w', newline='\r\n') as f:
        f.write('\n'.join(pas) + '\n')

    print('%s: %d sound(s), %d bytes (%.1f s at %d Hz)' % (a.asm, len(sounds), total, total / a.rate, a.rate))
    print('%s: paste before PROGRAM' % a.pas)


if __name__ == '__main__':
    main()
