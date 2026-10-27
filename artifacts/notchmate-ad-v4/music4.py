"""Upbeat 120 BPM bed synced to the reel timeline: hits on cuts, a filtered dip before the music reveal."""
import json
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt

TL = json.load(open("timeline.json"))
SR, DUR, BPM = 48000, TL["total"], 120
beat = 60 / BPM
n = int(SR * DUR)
t = np.arange(n) / SR
rng = np.random.default_rng(3)

def note(m):
    return 440 * 2 ** ((m - 69) / 12)

def lp(x, f):
    return sosfilt(butter(2, f, "low", fs=SR, output="sos"), x)

def hp(x, f):
    return sosfilt(butter(2, f, "high", fs=SR, output="sos"), x)

def saw(f, tt):
    return 2 * ((tt * f) % 1) - 1

CHORDS = [[57, 60, 64, 67], [53, 57, 60, 64], [48, 52, 55, 59], [55, 59, 62, 66]]  # Am7 Fmaj7 Cmaj7 G
BASS = [45, 41, 48, 43]
bar = 4 * beat

pad, bass, arp = np.zeros(n), np.zeros(n), np.zeros(n)
for b in range(int(DUR / bar) + 1):
    c = CHORDS[b % 4]
    s0, s1 = int(b * bar * SR), min(n, int((b + 1) * bar * SR))
    if s0 >= n:
        break
    tt = t[s0:s1] - b * bar
    env = np.minimum(1, tt / 0.05) * np.minimum(1, (bar - tt) / 0.1)
    for m in c:
        for det in (-0.1, 0.1):
            pad[s0:s1] += saw(note(m + 12) * 2 ** (det / 12), tt) * env * 0.035
    for k in range(8):  # driving eighth-note bass, octave jumps on offbeats
        e0 = s0 + int(k * beat / 2 * SR)
        if e0 >= n:
            break
        e1 = min(n, e0 + int(beat / 2 * SR))
        te = t[e0:e1] - t[e0]
        f = note(BASS[b % 4] + (12 if k % 2 else 0) - 12)
        bass[e0:e1] += (saw(f, te) * 0.5 + np.sin(2 * np.pi * f * te)) * np.exp(-te * 7) * 0.3
    seq = [c[0] + 24, c[2] + 24, c[1] + 24, c[3] + 24, c[2] + 24, c[0] + 36, c[3] + 24, c[1] + 24]
    for k in range(16):
        e0 = s0 + int(k * beat / 4 * SR)
        if e0 >= n:
            break
        e1 = min(n, e0 + int(0.25 * SR))
        te = t[e0:e1] - t[e0]
        f = note(seq[k % 8])
        arp[e0:e1] += (np.sign(np.sin(2 * np.pi * f * te)) * 0.3 + np.sin(2 * np.pi * f * te)) * np.exp(-te * 18) * 0.09

pad = lp(pad, 2200)
bass = lp(bass, 900)
arp = lp(arp, 4500)

kick, clap, hat, pump = np.zeros(n), np.zeros(n), np.zeros(n), np.ones(n)
for k in range(int(DUR / beat) + 1):
    bt = k * beat
    s0 = int(bt * SR)
    if s0 >= n:
        break
    L = min(n - s0, int(0.3 * SR))
    te = np.arange(L) / SR
    ph = 2 * np.pi * np.cumsum(48 + 110 * np.exp(-te * 35)) / SR
    kick[s0:s0 + L] += np.sin(ph) * np.exp(-te * 10) * 0.9
    pl = min(n - s0, int(0.22 * SR))
    pump[s0:s0 + pl] = np.minimum(pump[s0:s0 + pl], 0.3 + 0.7 * (np.arange(pl) / pl) ** 0.7)
    if k % 2 == 1:
        L = min(n - s0, int(0.18 * SR))
        clap[s0:s0 + L] += rng.standard_normal(L) * np.exp(-np.arange(L) / SR * 22) * 0.35
    for off in (0.25, 0.5, 0.75):
        h0 = int((bt + off * beat) * SR)
        if h0 < n:
            L = min(n - h0, int(0.045 * SR))
            hat[h0:h0 + L] += rng.standard_normal(L) * np.exp(-np.arange(L) / SR * 70) * (0.2 if off == 0.5 else 0.1)
clap = hp(lp(clap, 6000), 900)
hat = hp(hat, 8000)

music = (pad + bass + arp * 0.9) * pump + kick + clap + hat

# tension dip: when the notch closes for "Наводишь курсор" the track goes muffled until the music panel opens
dip0, dip1 = TL["cuts"][1], TL["flashes"][5]
k = np.clip((t - dip0) / 0.15, 0, 1) * np.clip((dip1 - t) / 0.05, 0, 1)
muffled = lp(music, 500) * 0.7
music = music * (1 - k) + muffled * k

fx = np.zeros(n)
def whoosh(at, length, gain):
    s0 = int(max(0, at - length) * SR)
    L = min(int(length * SR), n - s0)
    seg = hp(lp(rng.standard_normal(L), 6000), 800) * np.linspace(0, 1, L) ** 2 * gain
    fx[s0:s0 + L] += seg
def hit(at, gain):
    s0 = int(at * SR)
    L = min(int(0.9 * SR), n - s0)
    te = np.arange(L) / SR
    fx[s0:s0 + L] += (hp(rng.standard_normal(L), 3000) * np.exp(-te * 5) * 0.5 +
                      np.sin(2 * np.pi * 50 * te) * np.exp(-te * 8)) * gain
# riser into the dip end and big hit on the music reveal
whoosh(dip1, 1.4, 0.35)
hit(dip1, 0.5)
hit(TL["flashes"][0], 0.6)
for f in TL["flashes"]:
    whoosh(f + 0.02, 0.22, 0.2)

music = music * 0.8 + fx
fade = np.clip((DUR - t) / 0.6, 0, 1) * np.clip(t / 0.02, 0, 1)
music = np.tanh(music * 1.1 * fade) * 0.7
right = music.copy()
d = int(0.01 * SR)
right[d:] = music[:-d]
sf.write("music.wav", np.stack([music, right], 1), SR)
