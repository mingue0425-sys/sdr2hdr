"""Per-channel vs luminance HLG OOTF in the declared YouTube-HLG reconstruction (Tune broadcast pairs only).

For each Tune K-Choreo/KBS pair, 10 frames (every 60th) are area-downscaled to 128x72 R'G'B' (full range, 16-bit):
SDR via the BT.709 matrix, HDR via the BT.2020 matrix. Codes stay non-linear.

Reference: HLG display light at 1000 nits: E = invOETF(E'), Ys = BT.2020 luma of E, display = 1000 * E * Ys^0.2 (BT.2020).
Reconstructions of SDR R'G'B' (per channel through the fitted 17-knot curve, then invOETF; BT.709 primaries):
  A  per-channel:     1000 * E^1.2                       -> BT.709 to BT.2020   (current shader)
  B  luminance OOTF:  1000 * E * Ys709(E)^0.2             -> BT.709 to BT.2020
  C  luminance OOTF after gamut: E2020 = M * E;  1000 * E2020 * Ys2020(E2020)^0.2
Reported: median |log10 Y ratio| and median u'v' distance (pixels with reference Y > 1 nit), per pair and pooled.
Usage: python3 -I compare_youtube_hlg_ootf.py REPO_ROOT [tune|validation]
"""
import json, math, struct, subprocess, sys

KNOTS = [0.00000, 0.12609, 0.20355, 0.28179, 0.35523, 0.42496, 0.49100, 0.55358, 0.61006, 0.66057,
         0.70648, 0.74818, 0.78920, 0.83003, 0.87738, 0.93165, 1.00000]
M709_2020 = [[0.6274040, 0.3292820, 0.0433136], [0.0690970, 0.9195400, 0.0113612], [0.0163916, 0.0880132, 0.8955950]]
M2020_XYZ = [[0.636958, 0.144617, 0.168881], [0.262700, 0.677998, 0.059302], [0.000000, 0.028073, 1.060985]]
FAMILIES = {'K-Choreo', 'KBS Music Bank One-take'}


def curve(s):
    p = min(max(s, 0.0), 1.0) * 16
    i = min(int(p), 15)
    return KNOTS[i] + (KNOTS[i + 1] - KNOTS[i]) * (p - i)


def inv_oetf(v):
    v = min(max(v, 0.0), 1.0)
    return v * v / 3 if v <= 0.5 else (math.exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12


def mat(m, v):
    return [sum(m[r][k] * v[k] for k in range(3)) for r in range(3)]


def uv(rgb2020):
    x, y, z = mat(M2020_XYZ, rgb2020)
    d = x + 15 * y + 3 * z
    return (4 * x / d, 9 * y / d) if d > 1e-9 else (0.0, 0.0)


def frames(path, matrix):
    raw = subprocess.check_output([
        'ffmpeg', '-hide_banner', '-nostdin', '-loglevel', 'error', '-i', path, '-vf',
        f"select='not(mod(n\\,60))',scale=128:72:flags=area:in_range=tv:out_range=pc:in_color_matrix={matrix},format=rgb48le",
        '-fps_mode', 'passthrough', '-frames:v', '10', '-f', 'rawvideo', 'pipe:1'])
    values = struct.unpack('<%dH' % (len(raw) // 2), raw)
    return [tuple(v / 65535 for v in values[i:i + 3]) for i in range(0, len(values), 3)]


def resolve(root, manifest, ref):
    scheme, rest = ref.split(':', 1)
    return f"{root}/data_video/open-content-v2/{manifest['roots'][scheme]}/{rest}"


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else float('nan')


def main():
    root = sys.argv[1]
    manifest = json.load(open(f'{root}/data_video/open-content-v2/manifest.json'))
    pairs = [p for p in manifest['pairs'] if p['split'] == (sys.argv[2] if len(sys.argv) > 2 else 'tune') and p['contentFamily'] in FAMILIES]
    pooled = {k: ([], []) for k in 'ABCD'}
    print('pair                     |logY| A    B    C    D   | du\'v\' A   B      C       D')
    for pair in pairs:
        sdr = frames(resolve(root, manifest, pair['sdr']), 'bt709')
        hdr = frames(resolve(root, manifest, pair['hdr']), 'bt2020')
        stats = {k: ([], []) for k in 'ABCD'}
        for s, h in zip(sdr, hdr):
            e = [inv_oetf(c) for c in h]
            ys = 0.2627 * e[0] + 0.6780 * e[1] + 0.0593 * e[2]
            ref = [1000 * c * ys ** 0.2 for c in e]
            yref = 0.2627 * ref[0] + 0.6780 * ref[1] + 0.0593 * ref[2]
            if yref <= 1:
                continue
            uref = uv(ref)
            es = [inv_oetf(curve(c)) for c in s]
            ys709 = 0.2126 * es[0] + 0.7152 * es[1] + 0.0722 * es[2]
            e2020 = mat(M709_2020, es)
            ys2020 = 0.2627 * e2020[0] + 0.6780 * e2020[1] + 0.0593 * e2020[2]
            recon = {
                'A': mat(M709_2020, [1000 * c ** 1.2 for c in es]),
                'B': mat(M709_2020, [1000 * c * max(ys709, 0) ** 0.2 for c in es]),
                'C': [1000 * c * max(ys2020, 0) ** 0.2 for c in e2020],
            }
            a, b = recon['A'], recon['B']
            ya = 0.2627 * a[0] + 0.6780 * a[1] + 0.0593 * a[2]
            yb = 0.2627 * b[0] + 0.6780 * b[1] + 0.0593 * b[2]
            # D: A's chromaticity at B's luminance.
            recon['D'] = [c * yb / ya for c in a] if ya > 0 else b
            for k, rgb in recon.items():
                y = 0.2627 * rgb[0] + 0.6780 * rgb[1] + 0.0593 * rgb[2]
                if y <= 0:
                    continue
                u = uv(rgb)
                stats[k][0].append(abs(math.log10(y / yref)))
                stats[k][1].append(math.hypot(u[0] - uref[0], u[1] - uref[1]))
        for k in 'ABCD':
            pooled[k][0].extend(stats[k][0]); pooled[k][1].extend(stats[k][1])
        print(f"{pair['id'][:24]:24s} " + ' '.join(f'{median(stats[k][0]):.3f}' for k in 'ABCD') + ' | '
              + ' '.join(f'{median(stats[k][1]):.5f}' for k in 'ABCD'))
    print('pooled                   ' + ' '.join(f'{median(pooled[k][0]):.3f}' for k in 'ABCD') + ' | '
          + ' '.join(f'{median(pooled[k][1]):.5f}' for k in 'ABCD'))


if __name__ == '__main__':
    main()
