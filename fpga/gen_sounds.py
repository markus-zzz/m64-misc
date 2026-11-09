#!/usr/bin/env python3
"""Generate sound1.bin / sound2.bin: 48 kHz, 16-bit mono, each sample stored
as a big-endian 32-bit word (SPI loader shifts MSB-first) (16-bit signed sample replicated in both halves).
Max 65536 samples (size of audio_array in top.sv)."""
import math, struct

RATE = 48000
MAXN = 0x10000

def write(name, samples):
    samples = samples[:MAXN]
    nreal = len(samples)
    samples = samples + [0] * (MAXN - nreal)  # zero-pad to full memory
    with open(name, "wb") as f:
        for s in samples:
            v = max(-32768, min(32767, int(round(s))))
            f.write(struct.pack(">I", ((v & 0xFFFF) << 16) | (v & 0xFFFF)))  # replicate in both halves
    print(f"{name}: {nreal} sound samples + {MAXN-nreal} zeros = {len(samples)} samples, {len(samples)*4} bytes")

# sound1: "boing" - decaying sine with wobbling pitch sweep (~1.3 s)
n = MAXN
ph = 0.0
s1 = []
for i in range(n):
    t = i / RATE
    f = 180 + 500 * math.exp(-t * 3) * (1 + 0.5 * math.sin(2 * math.pi * 9 * t))
    ph += 2 * math.pi * f / RATE
    env = math.exp(-t * 2.5) * min(1.0, t * 500)
    s1.append(20000 * env * (math.sin(ph) + 0.3 * math.sin(2 * ph)) / 1.3)
write("sound1.bin", s1)

# sound2: two-note chime (C6 then G6), each a decaying bell tone
s2 = [0.0] * 40000
def bell(f, start, length):
    for i in range(length):
        t = i / RATE
        env = math.exp(-t * 6) * min(1.0, t * 800)
        v = (math.sin(2*math.pi*f*t) + 0.4*math.sin(2*math.pi*2.01*f*t)
             + 0.2*math.sin(2*math.pi*3.02*f*t)) / 1.6
        if start + i < len(s2):
            s2[start + i] += 16000 * env * v
bell(1046.5, 0, 30000)
bell(1568.0, 12000, 28000)
write("sound2.bin", s2)
