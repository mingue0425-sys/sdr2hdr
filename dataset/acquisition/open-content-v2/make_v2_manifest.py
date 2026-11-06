import json, sys
src, dst = sys.argv[1], sys.argv[2]
m = json.load(open(src))
keep = [p for p in m['pairs'] if not p.get('consumed')]
assert len(keep) == 8, len(keep)
stem3_ref = next(p for p in m['pairs'] if p['id'] == 'aswf_stem3_warped_t118')
pairs = []
for p in keep:
    pairs.append(p)
for t in (79, 158):
    q = {k: v for k, v in stem3_ref.items() if k not in ('objectiveEvaluated', 'consumed', 'notes')}
    q.update({
        'id': f'aswf_stem3_warped_t{t:03d}',
        'sdr': f'aswf:stem3-warped/warped_sdr_t{t}_120f.mov',
        'hdr': f'aswf:stem3-warped/warped_hdr_t{t}_120f.mov',
        'split': 'tune', 'virginFrozen': False,
        'notes': (f"Tune window added in open-content-v2 to balance grading styles (SDR-matched cinema master). "
                  f"Start fixed a priori at {t}s (20%/40% duration fractions), chosen before any decode. "
                  "Same content family and group as the consumed v1 Frozen StEM3 windows (t118/t197), which are excluded from v2. "
                  "Stream-copied 120-frame excerpt of the 1080p Rec709 BT1886 ProRes 422 HQ and UHD Rec2100 ST2084 500-nit ProRes 4444 XQ deliverables; "
                  "SDR ProRes frame headers retagged BT.709 with prores_metadata (no pixel change). "
                  "StEM3 Warped : Cybercity Copyright 2026 American Society of Cinematographers."),
    })
    pairs.append(q)
frozen_note = ("Virgin Frozen candidate for open-content-v2. Window start fixed a priori before any decode; content was not viewed, sampled, or correlated, "
               "and no statistic of this pair was computed. Opening for objective evaluation requires separate explicit user approval. "
               "No hash-bound virginEvidence workflow was run; independent holdout custody is still required. ")
for f, frac in ((11961, 30), (19935, 50), (27909, 70)):
    pairs.append({
        'id': f'netflix_nocturne_f{f:05d}',
        'sdr': f'netflix:nocturne/nocturne_sdr_f{f}_120f.mov',
        'hdr': f'netflix:nocturne/nocturne_hdr_f{f}_120f.mov',
        'source': 'Netflix Open Content: Nocturne (film grain ProRes)',
        'sourceURL': 'https://opencontent.netflix.com/',
        'license': 'CC BY 4.0',
        'licenseURL': 'https://creativecommons.org/licenses/by/4.0/legalcode',
        'expectedRelation': 'same-master',
        'contentCategory': ['live-action', 'film-grain', 'low-key'],
        'contentFamily': 'Netflix Nocturne',
        'split': 'frozen', 'virginFrozen': True, 'group': 'netflix_nocturne',
        'objectiveEvaluated': False, 'consumed': False,
        'notes': frozen_note + (
            f"Start frame {f} of the 60 fps film-grain SDR and HDR masters ({frac}% of duration). "
            "SDR: stream copy, ProRes frame headers retagged BT.709 (no pixel change). "
            "HDR: the master is P3-D65 ST.2084; converted exactly to BT.2020 primaries in linear light (PQ EOTF, 3x3 matrix, PQ OETF, float64), "
            "re-encoded ProRes 4444 XQ 12-bit tagged BT.2020/ST.2084; round-trip error about 0.16 10-bit codes. "
            "See provenance-netflix-nocturne.json. Attribution: 'Nocturne' by Netflix, CC BY 4.0."),
    })
pairs.append({
    'id': 'nas_solemates_unh0400',
    'sdr': 'aswf:solemates/solemates_sdr_unh0400_61f.mov',
    'hdr': 'aswf:solemates/solemates_hdr_unh0400_61f.mov',
    'source': "NAS Sole Mates - HDR Production Example via ASWF Digital Production Example Library",
    'sourceURL': 'https://dpel.aswf.io/solemates/',
    'license': 'ASWF Digital Assets License v1.1',
    'licenseURL': 'https://dpel.aswf.io/solemates/solemates-license',
    'expectedRelation': 'same-master',
    'contentCategory': ['animation', 'cg-render'],
    'contentFamily': 'NAS Sole Mates',
    'referenceTransfer': 'bt1886',
    'referencePrimaries': 'bt709',
    'split': 'frozen', 'virginFrozen': True, 'group': 'nas_solemates',
    'objectiveEvaluated': False, 'consumed': False,
    'notes': frozen_note + (
        "The whole published 61-frame shot (unh0400_0010), so no window was chosen. Both renders come from one ACES 2.0 scene-referred composite: "
        "2K 100-nit Rec709 ProRes 422 HQ and 2K 1000-nit Rec2020 PQ ProRes 4444 XQ. Stream copies; the SDR ProRes frame headers were retagged BT.709 "
        "with prores_metadata (no pixel change); referenceTransfer/referencePrimaries record the SDR output-transform documentation. "
        "NAS Sole Mates - HDR Production Example Copyright 2025 Netflix, Inc. All rights reserved."),
})
out = {k: v for k, v in m.items() if k != 'pairs'}
out['pairs'] = pairs
json.dump(out, open(dst, 'w'), indent=2, ensure_ascii=False)
open(dst, 'a').write('\n')
for p in pairs: print(p['id'], p['split'], p['contentFamily'])
