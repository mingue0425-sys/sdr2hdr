"""Adds downloaded KBS K-Choreo HDR uploads (find_kchoreo_hdr.py --emit-list) to the open-content-v2 manifest.

Same procedure as add_kchoreo_v2/v3.py:
- one a-priori 10 s window at the last keyframe both renditions share at or before 40% of the duration;
- stream copy, rebased to start at 0, no re-encode;
- provenance entries are merged into provenance-kbs-youtube.json.

Splits are fixed in list order, before any decode: each pair goes to whichever of Tune/Validation currently holds
fewer K-Choreo pairs, and a tie goes to Validation.

`--drop-originals` deletes each upload's full renditions after its window is cut and hashed. Provenance keeps their
SHA-256, so the window can be re-derived if the upload is fetched again.

Usage: python3 -I add_kchoreo_from_list.py REPO_ROOT LIST.json [--drop-originals]
"""
import hashlib, json, os, re, subprocess, sys
root = sys.argv[1]
listed = json.load(open(sys.argv[2]))
drop_originals = '--drop-originals' in sys.argv[3:]
mpath = root + '/data_video/open-content-v2/manifest.json'
# (id, series, title) in the user's list order.
def label(title):
    match = re.search(r"['‘]([^'’]+)['’]", title or '')
    artist = re.search(r'\((.+?) Choreography\)', title or '')
    return f"{artist.group(1) if artist else 'KBS'} '{match.group(1) if match else title}'"
videos = [(item['id'], 'K-Choreo', label(item.get('title'))) for item in listed]
counters = {}
def sh(*a): return subprocess.check_output(a).decode()
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''): h.update(b)
    return h.hexdigest()
m = json.load(open(mpath))
prov = []
for vid, series, title in videos:
    d = f'{root}/data_video/kchoreo-v2/{vid}'
    src = {k: f'{d}/{vid}.f{k}.mp4' for k in ('642', '628')}
    dur = float(sh('ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', src['642']).strip())
    target = dur * 0.40
    # Stream copy starts at a keyframe. The two renditions are encoded separately, so start at the last
    # keyframe present in both at or before the 40% target (decided from packet flags only, no decode).
    def keys(path):
        out = sh('ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time,flags', '-of', 'csv=p=0', path)
        return {round(float(t), 3) for t, fl in (l.split(',')[:2] for l in out.split() if ',' in l) if 'K' in fl and t != 'N/A'}
    common = sorted(t for t in keys(src['642']) & keys(src['628']) if t <= target)
    assert common, vid
    start = common[-1]
    out = {}
    for k, role in (('642', 'hdr'), ('628', 'sdr')):
        o = f'{d}/{vid}_{role}_w40_10s.mp4'
        subprocess.check_call(['ffmpeg', '-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-ss', str(start), '-i', src[k],
                               '-map', '0:v:0', '-c', 'copy', '-t', '10', '-avoid_negative_ts', 'make_zero', '-bsf:v', 'setts=ts=TS-STARTPTS',
                               '-movflags', '+faststart', o])
        st = sh('ffprobe', '-v', 'error', '-show_entries', 'format=start_time', '-of', 'csv=p=0', o).strip()
        assert abs(float(st)) < 1e-6, (o, st)
        out[role] = o
    tune = sum(1 for p in m['pairs'] if p['contentFamily'] == series and p['split'] == 'tune')
    validation = sum(1 for p in m['pairs'] if p['contentFamily'] == series and p['split'] == 'validation')
    split = 'tune' if tune < validation else 'validation'
    pid = f'kbs_{vid}'
    m['pairs'] = [p for p in m['pairs'] if p['id'] != pid]
    m['pairs'].append({
        'id': pid,
        'sdr': f'local:kchoreo-v2/{vid}/{vid}_sdr_w40_10s.mp4',
        'hdr': f'local:kchoreo-v2/{vid}/{vid}_hdr_w40_10s.mp4',
        'source': f'KBS Kpop YouTube upload {vid} ({title})', 'sourceURL': f'https://www.youtube.com/watch?v={vid}',
        'license': 'Standard YouTube License (KBS); user-provided for private research',
        'licenseURL': 'https://www.youtube.com/t/terms',
        'expectedRelation': 'same-source',
        'contentCategory': ['live-action', 'dance', 'stage', 'broadcast-hlg'],
        'contentFamily': series, 'split': split, 'virginFrozen': False, 'group': f'kbs_{vid}',
        'notes': (f"Added in open-content-v2 from find_kchoreo_hdr.py discovery to widen the K-Choreo broadcast-HLG family. HDR is the platform BT.2020 HLG "
                  f"(arib-std-b67) VP9 Profile 2 rendition (itag 642); SDR is the platform BT.709 VP9 rendition (itag 628) of the same upload, "
                  f"so the SDR is YouTube's automatic conversion and the relation is same-source. One 10 s window starting at the last keyframe shared by both renditions at or before 40% of the duration "
                  f"({start:.3f} s), stream-copied and rebased to start at 0; window, split (balancing Tune/Validation in list order) and family "
                  f"(by series) were fixed before any decode. All {series} pairs share the KBS production pipeline."),
    })
    for role in ('sdr', 'hdr'):
        prov.append({'pairID': pid, 'role': role, 'file': out[role].replace(root + '/', ''), 'sha256': sha(out[role]),
                     'excerptStartSeconds': start, 'durationSeconds': 10,
                     'sourceFile': src['628' if role == 'sdr' else '642'].replace(root + '/', ''),
                     'sourceSHA256': sha(src['628' if role == 'sdr' else '642']),
                     'sourceObject': f"https://www.youtube.com/watch?v={vid} (itag {'628' if role == 'sdr' else '642'})",
                     'accessDate': '2026-11-07'})
    print(pid, series, split, start)
    if drop_originals:
        for path in src.values():
            os.remove(path)
order = {'tune': 0, 'validation': 1, 'frozen': 2}
m['pairs'].sort(key=lambda p: order[p['split']])
json.dump(m, open(mpath, 'w'), indent=2, ensure_ascii=False); open(mpath, 'a').write('\n')
ppath = root + '/data_video/open-content-v2/provenance-kbs-youtube.json'
pdoc = json.load(open(ppath))
added = {f['pairID'] for f in prov}
pdoc['files'] = [f for f in pdoc['files'] if f['pairID'] not in added] + prov
json.dump(pdoc, open(ppath, 'w'), indent=2, ensure_ascii=False)
