import json, hashlib, subprocess, sys
root = '/Volumes/game/sdr2hdr'
out_dir = root + '/data_video/open-content-v2'
def sha(p):
    h = hashlib.sha256()
    with open(root + '/' + p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''): h.update(b)
    return h.hexdigest()
def frames(p):
    return int(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-count_packets','-show_entries','stream=nb_read_packets','-of','csv=p=0',root+'/'+p]).decode().split()[0].split(',')[0])
R = 'sdr2hdr-real-media'
NOC = 'https://s3.amazonaws.com/download.opencontent.netflix.com/Nocturne/nocturne_filmgrain'
S3 = 'https://dpel-assets.aswf.io/asc-stem3/Warped-Cybercity'
def entry(pid, role, path, src, **kw):
    e = {'pairID': pid, 'role': role, 'file': path, 'sha256': sha(path), 'sourceObject': src, 'frameCount': frames(path), 'accessDate': '2026-11-06'}
    e.update(kw); return e
noc_files = []
for f in (11961, 19935, 27909):
    pid = f'netflix_nocturne_f{f:05d}'
    noc_files.append(entry(pid, 'sdr', f'{R}/netflix-opencontent/nocturne/nocturne_sdr_f{f}_120f.mov', f'{NOC}/nocturne_60fps_uhd_filmgrain_sdr.mov', excerptStartFrame=f, retaggedBT709=True))
    raw = f'{R}/netflix-opencontent/nocturne/raw/nocturne_hdr_p3_f{f}_120f.mov'
    noc_files.append(entry(pid, 'hdr', f'{R}/netflix-opencontent/nocturne/nocturne_hdr_f{f}_120f.mov', f'{NOC}/nocturne_60fps_uhd_filmgrain_hdr.mov', excerptStartFrame=f,
                           convertedFrom={'file': raw, 'sha256': sha(raw), 'primaries': 'P3-D65', 'transfer': 'ST.2084'}))
json.dump({
    'version': 1, 'collection': 'netflix-opencontent-nocturne', 'license': 'CC BY 4.0',
    'licenseURL': 'https://creativecommons.org/licenses/by/4.0/legalcode',
    'attribution': "'Nocturne' by Netflix, CC BY 4.0 (https://opencontent.netflix.com/)",
    'modifications': [
        'Excerpts of 120 frames at fixed start frames (30%/50%/70% of the 60 fps masters), chosen before any decode.',
        'SDR: stream copy; ProRes frame headers retagged BT.709 via prores_metadata (no pixel change).',
        'HDR: P3-D65 ST.2084 converted to BT.2020 primaries: Y\'CbCr (BT.709 matrix, limited range) -> 16-bit full-range RGB -> PQ EOTF -> linear 3x3 P3D65->BT.2020 -> PQ OETF (float64) -> Y\'CbCr BT.2020nc limited 4:4:4 12-bit, ProRes 4444 XQ. Matrix rows [0.753833,0.198597,0.04757],[0.045744,0.941777,0.012479],[-0.00121,0.017602,0.983609]. Round-trip error about 0.16 10-bit codes (synthetic test only; no Nocturne statistics computed).',
        'HDR: the encoder left primaries/transfer untagged, so ProRes frame headers and the container were then retagged BT.2020 / ST.2084 / BT.2020nc via prores_metadata with stream copy (no pixel change).'],
    'holdoutCustody': 'Virgin Frozen. Not viewed or measured; only container headers and frame counts were read.',
    'files': noc_files}, open(out_dir + '/provenance-netflix-nocturne.json', 'w'), indent=2)
Q = f'{R}/aswf-dpel/solemates/quick_times-sdr_hdr-v1.0.0'
zipurl = 'https://aswf-dpel-assets.s3.amazonaws.com/solemates/quicktime_media-sdr_hdr-v1.0.0.zip'
sol = [entry('nas_solemates_unh0400', 'sdr', f'{R}/aswf-dpel/solemates/solemates_sdr_unh0400_61f.mov', zipurl + '#unh0400_0010_21_2k_100nits_Rec709_ACES2_ProRes422HQ.mov', retaggedBT709=True,
             originalSHA256=sha(f'{Q}/unh0400_0010_21_2k_100nits_Rec709_ACES2_ProRes422HQ.mov')),
       entry('nas_solemates_unh0400', 'hdr', f'{R}/aswf-dpel/solemates/solemates_hdr_unh0400_61f.mov', zipurl + '#unh0400_0010_21_2k_1000nits_Rec2020_ACES2_ProRes4444XQ.mov',
             originalSHA256=sha(f'{Q}/unh0400_0010_21_2k_1000nits_Rec2020_ACES2_ProRes4444XQ.mov'))]
json.dump({
    'version': 1, 'collection': 'aswf-dpel-nas-solemates', 'license': 'ASWF Digital Assets License v1.1',
    'licenseURL': 'https://dpel.aswf.io/solemates/solemates-license',
    'copyright': 'NAS Sole Mates - HDR Production Example Copyright 2025 Netflix, Inc. All rights reserved.',
    'archiveSHA256': sha(f'{R}/aswf-dpel/solemates/zip/quicktime_media-sdr_hdr-v1.0.0.zip'),
    'modifications': 'Video stream copied out of the published QuickTimes (whole 61-frame shot); SDR ProRes frame headers retagged BT.709 via prores_metadata (no pixel change).',
    'holdoutCustody': 'Virgin Frozen. Not viewed or measured; only container headers and frame counts were read.',
    'files': sol}, open(out_dir + '/provenance-aswf-solemates.json', 'w'), indent=2)
st = []
for t in (79, 158):
    pid = f'aswf_stem3_warped_t{t:03d}'
    st.append(entry(pid, 'sdr', f'{R}/aswf-dpel/stem3-warped/warped_sdr_t{t}_120f.mov', f'{S3}/Warped_Cybercity_1920x1080_Rec709_BT1886_5.1ch.mov', excerptStartSeconds=t, retaggedBT709=True))
    st.append(entry(pid, 'hdr', f'{R}/aswf-dpel/stem3-warped/warped_hdr_t{t}_120f.mov', f'{S3}/Warped_Cybercity_3840x2160_Rec2100_ST2084_500nits_5.1ch.mov', excerptStartSeconds=t))
json.dump({
    'version': 1, 'collection': 'aswf-dpel-asc-stem3-tune', 'license': 'ASWF Digital Assets License v1.1',
    'copyright': 'StEM3 Warped : Cybercity Copyright 2026 American Society of Cinematographers. All rights reserved.',
    'modifications': 'Stream copies at 20%/40% of duration; SDR ProRes frame headers retagged BT.709 via prores_metadata (no pixel change).',
    'note': 'Tune windows. Other StEM2/StEM3 files keep their provenance in ../open-content/provenance-aswf-stem.json.',
    'files': st}, open(out_dir + '/provenance-aswf-stem3-tune.json', 'w'), indent=2)
for e in noc_files + sol + st: print(e['pairID'], e['role'], e['frameCount'], e['sha256'][:12])
