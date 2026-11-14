import array
import math
import sys
import wave

with wave.open(sys.argv[1], 'rb') as source:
    assert (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getnframes()) == (1, 2, 48000, 48000)
    samples = array.array('h', source.readframes(source.getnframes()))
if sys.byteorder != 'little':
    samples.byteswap()
assert max(abs(v) for v in samples) == 819
assert abs(sum(samples)) <= 1
rms = math.sqrt(sum(v * v for v in samples) / len(samples)) / 32768
assert abs(rms - 819 / 32768 / math.sqrt(2)) < 0.00003
assert sum(a <= 0 < b for a, b in zip(samples, samples[1:])) == 440
assert abs(samples[-1] - samples[0]) <= 48
assert max(abs(a - b) for a, b in zip(samples, samples[1:])) <= 48
print('PASS native reference WAV: 48 kHz mono PCM, 440 Hz, -32 dBFS peak, zero DC and continuous loop')
