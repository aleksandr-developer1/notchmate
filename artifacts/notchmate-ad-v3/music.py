"""Background track for the reel: soft synth-pop loop, drums drop in when the notch comes alive."""
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt

SR, DUR, BPM = 48000, 27.0, 105
beat = 60 / BPM
bar = 4 * beat
n = int(SR * DUR)
t = np.arange(n) / SR
rng = np.random.default_rng(7)

def note(m):
    return 440 * 2 ** ((m - 69) / 12)

CHORDS = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]  # Am F C G
BASS = [45, 41, 36, 43]

def lp(x, f):
    return sosfilt(butter(2, f, "low", fs=SR, output="sos"), x)

def hp(x, f):
    return sosfilt(butter(2, f, "high", fs=SR, output="sos"), x)

def saw(f, tt):
    return 2 * ((tt * f) % 1) - 1

pad = np.zeros(n)
bass = np.zeros(n)
arp = np.zeros(n)
for b in range(int(DUR / bar) + 1):
    c = CHORDS[b % 4]
    s0, s1 = int(b * bar * SR), min(n, int((b + 1) * bar * SR))
    if s0 >= n:
        break
    tt = t[s0:s1] - b * bar
    env = np.minimum(1, tt / 0.25) * np.minimum(1, (bar - tt) / 0.2 + 0.0)
    for m in c:
        for det in (-0.12, 0.0, 0.12):
            pad[s0:s1] += saw(note(m + 12) * 2 ** (det / 12), tt) * env * 0.05
    # bass on eighths
    for k in range(8):
        e0 = s0 + int(k * beat / 2 * SR)
        if e0 >= n: break
        e1 = min(n, e0 + int(beat / 2 * SR))
        te = t[e0:e1] - t[e0]
        bass[e0:e1] += np.sin(2 * np.pi * note(BASS[b % 4]) * te) * np.exp(-te * 6) * 0.35
    # arpeggio on sixteenths
    seq = [c[0] + 24, c[1] + 24, c[2] + 24, c[1] + 24]
    for k in range(16):
        e0 = s0 + int(k * beat / 4 * SR)
        if e0 >= n: break
        e1 = min(n, e0 + int(0.3 * SR))
        te = t[e0:e1] - t[e0]
        f = note(seq[k % 4])
        arp[e0:e1] += (np.sin(2 * np.pi * f * te) + 0.3 * np.sin(4 * np.pi * f * te)) * np.exp(-te * 14) * 0.12

pad = lp(pad, 1600)
DROP = 3.1  # drums start when the notch comes alive

kick = np.zeros(n)
hat = np.zeros(n)
pump = np.ones(n)
for k in range(int(DUR / beat) + 1):
    bt = k * beat
    if bt < DROP - 0.01 or bt > DUR - 1.2:
        continue
    s0 = int(bt * SR)
    L = min(n - s0, int(0.35 * SR))
    te = np.arange(L) / SR
    ph = 2 * np.pi * np.cumsum(45 + 90 * np.exp(-te * 30)) / SR
    kick[s0:s0 + L] += np.sin(ph) * np.exp(-te * 9) * 0.8
    pl = min(n - s0, int(0.25 * SR))
    pump[s0:s0 + pl] = np.minimum(pump[s0:s0 + pl], 0.35 + 0.65 * np.arange(pl) / pl)
    h0 = int((bt + beat / 2) * SR)
    if bt >= 5.6 and h0 < n:
        L = min(n - h0, int(0.06 * SR))
        hat[h0:h0 + L] += rng.standard_normal(L) * np.exp(-np.arange(L) / SR * 60) * 0.18
hat = hp(hat, 7000)

# riser into the drop and whooshes on every scene change
fx = np.zeros(n)
def whoosh(at, length, gain, up=True):
    s0 = int(max(0, at - length) * SR)
    L = int(length * SR)
    x = rng.standard_normal(L)
    env = np.linspace(0, 1, L) ** 2 if up else np.linspace(1, 0, L) ** 2
    seg = hp(lp(x, 5000), 600) * env * gain
    fx[s0:s0 + L] += seg[: n - s0]
whoosh(DROP, 2.2, 0.25)
for at in (5.6, 8.5, 11.7, 14.8, 17.6, 22.5):
    whoosh(at + 0.05, 0.35, 0.18)
# pop when the panel opens
p0 = int(4.0 * SR)
te = np.arange(int(0.15 * SR)) / SR
fx[p0:p0 + len(te)] += np.sin(2 * np.pi * (600 + 900 * te / 0.15) * te) * np.exp(-te * 30) * 0.3

music = (pad + bass * (t >= DROP)) * pump + arp * np.clip((t - 1.0) / 2, 0, 1) + kick + hat
music += fx
fade = np.clip((DUR - t) / 1.5, 0, 1)
music *= fade
music = np.tanh(music * 1.2) * 0.6
# simple stereo: arp/hat delay to the right
right = music.copy()
d = int(0.012 * SR)
right[d:] = music[:-d]
sf.write("out/music.wav", np.stack([music, right], 1), SR)
