#!/usr/bin/env python3
"""Rebuild the short, generated (non-copyrighted) audio regression fixtures.
Requires ffmpeg on PATH. No network or third-party media is used.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1] / 'VocalSeparatorTests' / 'Fixtures'
root.mkdir(parents=True, exist_ok=True)
formats = [
    ('tone.wav', 'pcm_s16le'), ('tone.aiff', 'pcm_s16be'),
    ('tone.caf', 'pcm_f32le'), ('tone.flac', 'flac'),
    ('tone.mp3', 'libmp3lame'), ('tone.aac', 'aac'),
    ('tone.m4a', 'aac'), ('alac.m4a', 'alac'),
    ('tone.mov', 'pcm_s16le'), ('tone.au', 'pcm_mulaw'),
]
for name, codec in formats:
    subprocess.run([
        'ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i',
        'aevalsrc=0.2*sin(2*PI*440*t)+0.1*sin(2*PI*660*t):s=48000:d=2',
        '-ac', '1', '-c:a', codec, str(root / name),
    ], check=True)
