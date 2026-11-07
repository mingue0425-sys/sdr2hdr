"""Adds pairs kept by fetch_youtube_hlg.py to the open-content-v2 manifest.

The family and split of every entry come from the download plan, which was written from titles and uploaders
before any download. This script never changes them.

- Window: one a-priori 10 s window at the last keyframe both renditions share at or before 40% of the duration.
  Keyframes come from packet flags only (no decode). The window is stream-copied and rebased to start at 0.
- Frozen entries (split "frozen") become Virgin Frozen pairs: virginFrozen true, objectiveEvaluated false, consumed
  false. Their media is cut and hashed for provenance only: no frame is decoded, viewed or measured.
- Provenance (window and source SHA-256, itags, upload metadata) goes to provenance-youtube-hlg.json.
- `--drop-originals` deletes the full renditions, only after the manifest and provenance are written.

Pair ids: kbs_<id> for KBS Kpop uploads, yt_<id> otherwise.

Usage: python3 -I add_youtube_hlg_from_list.py REPO_ROOT RESULT.json [--drop-originals]
"""
import datetime, hashlib, json, os, subprocess, sys

root = os.path.abspath(sys.argv[1])
rows = [r for r in json.load(open(sys.argv[2])) if r.get('decision') == 'kept']
drop_originals = '--drop-originals' in sys.argv[3:]
mpath = f'{root}/data_video/open-content-v2/manifest.json'
ppath = f'{root}/data_video/open-content-v2/provenance-youtube-hlg.json'


def sh(*a):
    return subprocess.check_output(a).decode()


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''):
            h.update(b)
    return h.hexdigest()


def keys(path):
    out = sh('ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time,flags',
             '-of', 'csv=p=0', path)
    return {round(float(t), 3) for t, fl in (l.split(',')[:2] for l in out.split() if ',' in l)
            if 'K' in fl and t != 'N/A'}


m = json.load(open(mpath))
prov = []
for row in rows:
    vid, family, split = row['id'], row['family'], row['split']
    assert split in ('tune', 'validation', 'frozen'), row
    kbs = (row.get('uploader') or '') == 'KBS Kpop'
    pid = ('kbs_' if kbs else 'yt_') + vid
    src = {'hdr': f"{root}/{row['hdrFile']}", 'sdr': f"{root}/{row['sdrFile']}"}
    duration = float(sh('ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0',
                        src['hdr']).strip())
    common = sorted(t for t in keys(src['hdr']) & keys(src['sdr']) if t <= duration * 0.40)
    assert common, vid
    start = common[-1]
    d = os.path.dirname(src['hdr'])
    out = {}
    for role in ('hdr', 'sdr'):
        o = f'{d}/{vid}_{role}_w40_10s.mp4'
        subprocess.check_call(['ffmpeg', '-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-ss', str(start),
                               '-i', src[role], '-map', '0:v:0', '-c', 'copy', '-t', '10',
                               '-avoid_negative_ts', 'make_zero', '-bsf:v', 'setts=ts=TS-STARTPTS',
                               '-movflags', '+faststart', o])
        st = sh('ffprobe', '-v', 'error', '-show_entries', 'format=start_time', '-of', 'csv=p=0', o).strip()
        assert abs(float(st)) < 1e-6, (o, st)
        out[role] = o
    rel = os.path.relpath(d, f'{root}/data_video')
    frozen = split == 'frozen'
    entry = {
        'id': pid,
        'sdr': f'local:{rel}/{vid}_sdr_w40_10s.mp4',
        'hdr': f'local:{rel}/{vid}_hdr_w40_10s.mp4',
        'source': f"YouTube upload {vid} by {row.get('uploader')} ({row.get('title')})",
        'sourceURL': f'https://www.youtube.com/watch?v={vid}',
        'license': ('Standard YouTube License (KBS)' if kbs else f"YouTube upload ({row.get('license') or 'Standard YouTube License'})")
                   + '; private research copy, not redistributed',
        'licenseURL': 'https://www.youtube.com/t/terms',
        'expectedRelation': 'same-source',
        'contentCategory': ['live-action', 'youtube-hlg'] + (['broadcast-hlg'] if kbs else ['camera-hlg']),
        'contentFamily': family, 'split': split, 'virginFrozen': frozen, 'group': pid,
        'notes': (f"Added from fetch_youtube_hlg.py. HDR is YouTube's VP9 Profile 2 HLG (arib-std-b67) rendition "
                  f"(itag {row['hdrItag']}); SDR is the VP9 SDR rendition (itag {row['sdrItag']}) of the same upload at the "
                  f"same height and frame rate, i.e. YouTube's automatic conversion, so the relation is same-source. One 10 s "
                  f"window starting at the last keyframe shared by both renditions at or before 40% of the duration "
                  f"({start:.3f} s), stream-copied and rebased to start at 0. Family and split were fixed in the download "
                  f"plan from titles and uploaders, before any download."
                  + (" Virgin Frozen: no frame was decoded, viewed or measured; opening it for objective evaluation "
                     "requires separate explicit user approval." if frozen else "")),
    }
    if frozen:
        entry.update({'objectiveEvaluated': False, 'consumed': False})
    m['pairs'] = [p for p in m['pairs'] if p['id'] != pid] + [entry]
    for role in ('sdr', 'hdr'):
        prov.append({'pairID': pid, 'role': role, 'file': os.path.relpath(out[role], root), 'sha256': sha(out[role]),
                     'excerptStartSeconds': start, 'durationSeconds': 10,
                     'sourceFile': row[f'{role}File'], 'sourceSHA256': sha(src[role]),
                     'sourceObject': f"https://www.youtube.com/watch?v={vid} (itag {row[role + 'Itag']})",
                     'uploader': row.get('uploader'), 'uploadDate': row.get('uploadDate'),
                     'accessDate': datetime.date.today().isoformat()})
    print(pid, family, split, start)

order = {'tune': 0, 'validation': 1, 'frozen': 2}
m['pairs'].sort(key=lambda p: order[p['split']])
json.dump(m, open(mpath, 'w'), indent=2, ensure_ascii=False)
open(mpath, 'a').write('\n')
pdoc = json.load(open(ppath)) if os.path.exists(ppath) else {'version': 'provenance-youtube-hlg-v1', 'files': []}
added = {f['pairID'] for f in prov}
pdoc['files'] = [f for f in pdoc['files'] if f['pairID'] not in added] + prov
json.dump(pdoc, open(ppath, 'w'), indent=2, ensure_ascii=False)
# Originals go only after the manifest and provenance are written.
if drop_originals:
    for row in rows:
        for role in ('hdr', 'sdr'):
            os.remove(f"{root}/{row[role + 'File']}")
