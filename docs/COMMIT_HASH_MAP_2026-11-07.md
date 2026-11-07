# Commit hash map after the 2026-11-07 history rewrite

GitHub rejects files over 100 MB. Before the first push of `sdr-input-policy-and-pts-fidelity`, its 73 unpushed commits were rewritten with `git filter-branch`.

- Every blob over 100 MB (14 full-candidate `data-video-v4-final.json` reports) is stored as `<path>.xz` (xz -6) instead. Decompressing gives byte-identical files.
- Nothing else changed, so the trees differ only in those 14 paths.
- Commit hashes changed. Docs, commit messages and artifacts written earlier (for example `gitCommit` in freeze artifacts) cite the old hashes.
- Source hashes (`sourceHash`) are unaffected, because sources did not change.

| old | new | subject |
|---|---|---|
| 3e9d534 | 3e9d534 | feat(hdr): add versioned SDR transfer interpretation policy |
| d4f3e8e | d4f3e8e | fix(calibration): preserve source PTS in the FFmpeg proxy |
| f56aff4 | f56aff4 | docs(hdr): record SDR input policy and proxy PTS fidelity |
| 2e2d0f1 | 2e2d0f1 | fix(hdr): load default.metallib emitted with the Metal Toolchain |
| 6ad39a6 | 6ad39a6 | feat(calibration): require PTS agreement for paired window frames |
| 1916139 | 1916139 | data(calibration): add Netflix Sol Levante SDR/HDR10 tune pairs |
| 3e36306 | 3e36306 | data(calibration): reach DATASET_V4_READY with open-content pairs |
| 63efc7e | 63efc7e | feat(calibration): preregister coverage protocols per manifest |
| a1ec542 | a1ec542 | feat(calibration): run-level SDR transfer policy for v4-run |
| 25963bf | 25963bf | feat(core): opt-in noise-gated gain guidance |
| 7734b35 | 7734b35 | feat(calibration): robustness study on degraded SDR input |
| 35557b7 | 35557b7 | data(calibration): add Netflix Sparks virgin Frozen pairs |
| 058708c | 058708c | fix(calibration): HLG virgin-holdout gate follows the coverage protocol |
| 031f1fb | 031f1fb | feat(calibration): v4-run --stop-before-frozen for policy comparison |
| 8803f9b | 8803f9b | feat(calibration): prepare-frozen-plan builds the admitted Frozen plan |
| ea3363e | ea3363e | fix(calibration): gate black crush a candidate adds over V2 |
| 725b0bc | 725b0bc | fix(calibration): v4-run Frozen coverage uses audited HDR transfer |
| a6bd711 | a6bd711 | perf(core): dedicated guided kernels and gather-based guidance window |
| b8f98d3 | b8f98d3 | fix(calibration): verify Frozen bytes before plan preparation |
| c30cfa5 | c30cfa5 | feat(calibration): noise-adaptive guidance candidates in robustness study |
| a431979 | a431979 | docs(calibration): record open-content V4 Virgin Frozen result |
| 9010264 | 9010264 | docs(robustness): noise-adaptive tolerance result and guidance cost |
| 7ce995b | 7ce995b | data(calibration): mark the open-content Virgin Frozen pairs consumed |
| 458c98e | 458c98e | feat(calibration): artifact-aware guidance tolerance candidate |
| d09eed1 | d09eed1 | fix(benchmark): reject unknown --gain-guidance values |
| 2d2b7ee | 2d2b7ee | docs(calibration): masters graded in opposite directions explain the small gain |
| fc50743 | fc50743 | docs: improvement research notes and artifact-aware guidance result |
| 49957d5 | 49957d5 | docs: SDR-statistics predictor fails across families inside Tune |
| 05ab731 | 05ab731 | data: open-content-v2 dataset with new unexposed Virgin Frozen holdout |
| 11a521f | 11a521f | docs: open-content v2 dataset and development roadmap from three reviews |
| 205f154 | 205f154 | feat(calibration): family-maximin-lofo-v1 decision protocol |
| d812deb | d812deb | feat(calibration): shape-only scoring with one gain per content family |
| 0f1a580 | 0f1a580 | feat(core): toe-preserving BT.709/BT.1886 midtone blend SDR policy |
| 98f5458 | 98f5458 | data: Sparks Validation windows and family-maximin-lofo-v1 protocol for open-content-v2 |
| 9b94dee | 9b94dee | fix(calibration): split sizes are minimums under a decision protocol |
| 2f0d072 | 2f0d072 | feat(calibration): v4-run-batch reuses one materialization across variants |
| 3a47708 | d0d6f2e | docs: open-content v2 policy comparison; Virgin Frozen stays sealed |
| a63f230 | 1a04420 | data: 11 broadcast-HLG KBS pairs join open-content-v2 Tune/Validation |
| a5ba8e6 | 1cf0787 | perf(calibration): cut V4 peak memory and parallelize sealed materialization |
| e28eb6e | c53ecb0 | perf(calibration): mix VideoToolbox and software VP9 decode; parallel prepare |
| 1b98091 | 2165cf5 | fix(calibration): released prepared pairs keep scene bounds and decoded counts |
| 610d7ec | bb35784 | fix(calibration): stream media hashes without keeping every chunk alive |
| b68af78 | 4407fd2 | results: open-content-v2 round-2 correctness review and Tune/Validation plan |
| 95d7e17 | 51f95f1 | docs: open-content v2 round 2 passes the LOFO readiness gate (shape-oetf) |
| e80fb07 | b422920 | docs: improvement research from the round-2 candidate pool |
| aa4c4cf | eb7cb47 | data: 8 more KBS K-Choreo HLG pairs join open-content-v2 Tune/Validation |
| 77e892f | 185cffe | results: open-content-v2 round-3 correctness review and Tune/Validation plan |
| 2667f6f | 18cd61a | feat: source-declared YouTube-HLG SDR reconstruction (opt-in) |
| cafb295 | 899ea7b | results: open-content-v2 round 3, six policy variants on 31 Tune/Validation pairs |
| e1b283b | 3b0bf4b | tools: find and add KBS K-Choreo HDR uploads from YouTube |
| 2f523f2 | f1150a6 | tools: find_kchoreo_hdr skips uploads already downloaded but not yet added |
| 3d7a93b | 2d54b95 | tools: a downloaded-but-unadded upload still reserves its song |
| 0e317cd | 78be133 | feat: v4 report lists the selected candidate's worst pairs (reported, not gating) |
| 217cf8f | e78d18d | data: six found K-Choreo HLG uploads join open-content-v2 (Tune 19 / Validation 18) |
| 2b131f9 | b1fa66f | results: open-content-v2 round-4 correctness review and Tune/Validation plan |
| 32c9034 | c0a102a | results: open-content-v2 round 4, shape-oetf and declared YouTube-HLG on 37 pairs |
| ee41baa | cefa03c | fix: add_kchoreo_from_list deletes originals only after the manifest is written |
| 08a04bc | 90f04f6 | fix: code-review findings on the round-3 changes |
| 3bcf66a | 189d5c1 | data: four more found K-Choreo HLG uploads (Tune 21 / Validation 20); round-4 docs |
| 6be5ffd | f24f24e | docs: preregister the one-shot open-content-v2 Virgin Frozen evaluation |
| 3b2106c | cb2ee56 | results: open-content-v2 Tune/Validation plan for the Frozen run (41 pairs) |
| 442c7c1 | 801860a | results: open-content-v2 Virgin Frozen plan admitted (CORRECTNESS_READY_FOR_V6) |
| 9ce1e50 | a518e38 | results: open-content-v2 Virgin Frozen evaluation, PROMOTE_CALIBRATED_V4 |
| 3f55758 | 1cc8b05 | feat: opt-in HDRPlayer preset open-v2-candidate (round-4 local_020, not promoted) |
| dd51061 | 34416db | feat: accept BT.601 (SMPTE C, EBU 3213) SDR primaries |
| 7e18349 | 14cf9bd | feat: youtube-hlg-v2 declared reconstruction (per-channel chroma, luminance-OOTF luminance |
| b12dea7 | 4da3f03 | feat: promote open-content v2 local_020 as calibrated-v5, the production default |
| 1e22fb8 | 45c9373 | results: round 6, declared YouTube-HLG reconstruction v2 beats v1 by 8-10% |
| 093d59c | faaf508 | tools: fetch and add same-upload YouTube HLG/SDR pairs from any uploader |
| 7c983da | d99f903 | tools: fetch_youtube_hlg downloads DASH fragments 8 at a time and resumes |
| 6973828 | 8e3a2f7 | data: YouTube HLG fancam pairs (Tune/Validation) and a new sealed Virgin Frozen set |
| bc0c506 | c4bdbfa | feat: experimental texture-adaptive gain-guidance gate |
| 3eb0c2e | 787f7fd | results: texture-adaptive gain-guidance study (texture-v1) |
