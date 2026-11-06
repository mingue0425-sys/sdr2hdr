"""Adds the Sparks Validation windows and the decision protocol to the v2 manifest; writes provenance."""
import hashlib, json, subprocess, sys
root = sys.argv[1]
mpath = root + '/data_video/open-content-v2/manifest.json'
m = json.load(open(mpath))
m['decisionProtocol'] = 'family-maximin-lofo-v1'
B = 'https://s3.amazonaws.com/download.opencontent.netflix.com/sparks'
def sha(p):
    h = hashlib.sha256()
    with open(root + '/' + p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''): h.update(b)
    return h.hexdigest()
def frames(p):
    out = subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-count_packets',
                                   '-show_entries', 'stream=nb_read_packets', '-of', 'csv=p=0', root + '/' + p]).decode()
    return int(out.split()[0].split(',')[0])
files = []
for start, frac in ((2067, 15), (6200, 45)):
    pid = f'netflix_sparks_f{start:05d}'
    m['pairs'] = [p for p in m['pairs'] if p['id'] != pid]
    m['pairs'].append({
        'id': pid,
        'sdr': f'netflix:sparks/sparks_sdr_f{start:05d}_96f.mov',
        'hdr': f'netflix:sparks/sparks_hdr10_f{start:05d}_96f.mov',
        'source': 'Netflix Open Content: Sparks', 'sourceURL': 'https://opencontent.netflix.com/',
        'license': 'CC BY 4.0', 'licenseURL': 'https://creativecommons.org/licenses/by/4.0/legalcode',
        'expectedRelation': 'same-master',
        'contentCategory': ['live-action', 'fire', 'highlight-rich', 'low-key'],
        'contentFamily': 'Netflix Sparks', 'split': 'validation', 'virginFrozen': False, 'group': 'netflix_sparks',
        'notes': (f"Validation window added in open-content-v2 (holdout ladder: a consumed Frozen family moves down to Validation). "
                  f"96 frames from source frame {start} ({frac}% of 13777), fixed a priori and away from the consumed f04133/f08266 windows, which are excluded. "
                  "SDR: stream copy of the BT.709 ProRes 422 HQ 59.94 fps deliverable. HDR: HDR10 TIFF sequence assembled into ProRes 4444 XQ "
                  "(lossy RGB to Y'CbCr, per-TIFF SHA-256 in provenance-netflix-sparks-validation.json). Attribution: 'Sparks' by Netflix, CC BY 4.0."),
    })
    sdr = f'sdr2hdr-real-media/netflix-opencontent/sparks/sparks_sdr_f{start:05d}_96f.mov'
    hdr = f'sdr2hdr-real-media/netflix-opencontent/sparks/sparks_hdr10_f{start:05d}_96f.mov'
    tif = json.load(open(f'{root}/.build/tmp/sparks/tif-sha256-{start}.json'))
    assert len(tif) == 96, len(tif)
    files.append({'pairID': pid, 'role': 'sdr', 'file': sdr, 'sha256': sha(sdr), 'startFrame': start, 'frameCount': frames(sdr),
                  'sourceObject': f'{B}/sdr/Sparks_SDR_UHD_4096x2160_5994fps.mov', 'accessDate': '2026-11-06'})
    files.append({'pairID': pid, 'role': 'hdr', 'file': hdr, 'sha256': sha(hdr), 'startFrame': start, 'frameCount': frames(hdr),
                  'sourceObject': f'{B}/HDR10_1000nit_PQ_2020_image_sequence/', 'sourceTIFFSHA256': tif, 'accessDate': '2026-11-06'})
order = {'tune': 0, 'validation': 1, 'frozen': 2}
m['pairs'].sort(key=lambda p: order[p['split']])
json.dump(m, open(mpath, 'w'), indent=2, ensure_ascii=False); open(mpath, 'a').write('\n')
json.dump({
    'version': 1, 'collection': 'netflix-opencontent-sparks-validation', 'license': 'CC BY 4.0',
    'licenseURL': 'https://creativecommons.org/licenses/by/4.0/legalcode',
    'attribution': "'Sparks' by Netflix, licensed under CC BY 4.0.",
    'modifications': ("SDR: stream copy. HDR: 16-bit RGB TIFF HDR10 frames (BT.2020, ST 2084) converted to Y'CbCr 4:4:4 10-bit BT.2020nc narrow range, "
                      "ProRes 4444 XQ (prores_ks), tagged BT.2020/ST 2084 at encode. Script: dataset/acquisition/open-content-v2/get_sparks_validation.sh."),
    'selection': 'Starts fixed a priori at 15% and 45% of 13777 frames, away from the consumed Frozen windows f04133 and f08266.',
    'files': files}, open(root + '/data_video/open-content-v2/provenance-netflix-sparks-validation.json', 'w'), indent=2)
for f in files: print(f['pairID'], f['role'], f['frameCount'], f['sha256'][:12])
for p in m['pairs']: print(p['split'], p['id'])
