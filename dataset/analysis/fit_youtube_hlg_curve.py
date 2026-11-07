"""Fits the SDR→HLG code curve of YouTube's automatic SDR rendition of HLG uploads.

Only Tune pairs of the broadcast families are read, so Validation stays out of the fit. Frozen pairs are never read.

- Each pair's two renditions come from the same upload and start at the same keyframe, so frame n of the SDR and HDR
  files show the same moment. Ten frames per pair (every 60th) are area-downscaled to 128x68 luma.
- SDR luma is BT.709 narrow-range 8-bit; HLG luma is BT.2020 narrow-range 10-bit. Both are normalised to [0, 1].
- The curve is the per-bin median HLG code over 32 SDR bins, made monotone by pool-adjacent-violators, then sampled at
  17 uniform knots.

Usage: python3 -I fit_youtube_hlg_curve.py REPO_ROOT OUTPUT_JSON
"""
import json
import struct
import subprocess
import sys

FAMILIES = {'K-Choreo', 'KBS Music Bank One-take'}
BINS = 32
KNOTS = 17


def luma_samples(path, depth):
    raw = subprocess.check_output([
        'ffmpeg', '-hide_banner', '-nostdin', '-loglevel', 'error', '-i', path,
        '-vf', "select='not(mod(n\\,60))',scale=128:68:flags=area,format=gray16le",
        '-fps_mode', 'passthrough', '-frames:v', '10', '-f', 'rawvideo', 'pipe:1'])
    values = struct.unpack('<%dH' % (len(raw) // 2), raw)
    if depth == 8:
        return [((v / 65535 * 255) - 16) / 219 for v in values]
    return [((v / 65535 * 1023) - 64) / 876 for v in values]


def resolve(root, manifest, ref):
    scheme, rest = ref.split(':', 1)
    base = manifest['roots'][scheme]
    return f'{root}/data_video/open-content-v2/{base}/{rest}'


def monotone(values, weights):
    blocks = [[v, w, 1] for v, w in zip(values, weights)]
    merged = []
    for block in blocks:
        merged.append(block)
        while len(merged) > 1 and merged[-2][0] > merged[-1][0]:
            v2, w2, n2 = merged.pop()
            v1, w1, n1 = merged.pop()
            merged.append([(v1 * w1 + v2 * w2) / (w1 + w2), w1 + w2, n1 + n2])
    out = []
    for v, _, n in merged:
        out.extend([v] * n)
    return out


def main():
    root, output = sys.argv[1], sys.argv[2]
    manifest = json.load(open(f'{root}/data_video/open-content-v2/manifest.json'))
    pairs = [p for p in manifest['pairs'] if p['split'] == 'tune' and p['contentFamily'] in FAMILIES]
    bins = [[] for _ in range(BINS)]
    for pair in pairs:
        sdr = luma_samples(resolve(root, manifest, pair['sdr']), 8)
        hdr = luma_samples(resolve(root, manifest, pair['hdr']), 10)
        for s, h in zip(sdr, hdr):
            bins[min(max(int(s * BINS), 0), BINS - 1)].append(h)
    centres, medians, counts = [], [], []
    for index, values in enumerate(bins):
        if len(values) < 20:
            continue
        values.sort()
        centres.append((index + 0.5) / BINS)
        medians.append(values[len(values) // 2])
        counts.append(len(values))
    medians = monotone(medians, counts)

    def interpolate(x):
        if x <= centres[0]:
            slope = (medians[1] - medians[0]) / (centres[1] - centres[0])
            return medians[0] + (x - centres[0]) * slope
        if x >= centres[-1]:
            slope = (medians[-1] - medians[-2]) / (centres[-1] - centres[-2])
            return medians[-1] + (x - centres[-1]) * slope
        for i in range(1, len(centres)):
            if x <= centres[i]:
                t = (x - centres[i - 1]) / (centres[i] - centres[i - 1])
                return medians[i - 1] + t * (medians[i] - medians[i - 1])

    knots = [min(max(interpolate(i / (KNOTS - 1)), 0.0), 1.0) for i in range(KNOTS)]
    knots[0] = 0.0
    for i in range(1, KNOTS):
        knots[i] = max(knots[i], knots[i - 1])
    doc = {
        'version': 'youtube-hlg-sdr-inverse-v1',
        'fitPairs': [p['id'] for p in pairs],
        'fitSplit': 'tune',
        'families': sorted(FAMILIES),
        'domain': 'normalised narrow-range luma code: SDR BT.709 8-bit -> HLG BT.2020 10-bit',
        'knots': [round(k, 5) for k in knots],
        'binCentres': centres,
        'binMedians': medians,
        'binCounts': counts,
    }
    json.dump(doc, open(output, 'w'), indent=2)
    print(len(pairs), 'Tune pairs;', 'knots', ', '.join('%.5f' % k for k in knots))


if __name__ == '__main__':
    main()
