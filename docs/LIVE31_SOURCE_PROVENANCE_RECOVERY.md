# LIVE 31 Source-Master Provenance Recovery

This report recovers source identity from committed metadata and official public metadata only.
No media bytes were read, hashed, decoded, or visually inspected.

## Baseline and scope

- Correctness baseline: `bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9`
- Implementation head used for recovery: `39f8c8623f6e0c8bfef12d5148895cd02509355a`
- Search definition hash: `7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608` (`MATCH`)
- Frozen/Virgin paths were not enumerated or probed.
- Tune, Validation, objective metrics, and candidate selection were not run.

## Official identity anchors

- The official LIVE page documents 31 released open-source contents and separate HDR10/SDR folders.
- The official HDRSDR-VQA paper identifies those 31 open-source videos as sourced from AVT-VQDB-UHD-2-HDR.
- The pinned official AVT metadata snapshot is repository commit `7906224caa49cfcc538a8dacfda0469b597c1247`.
- Its 31 `metrics/DR_results/<Content>.mov.json` names are used as canonical content identities.
- The numeric count match is recorded, but count alone is not used as proof.

## Local evidence

- `results/development-corpus-inventory.json` supplies the exact 31 local inferred groups and exact candidate paths.
- `JOD_separate.csv` supplies explicit `content_name`, `video_name`, `video_format`, and `Type` identity fields.
- The local JOD identity file is tracked from commit `b2f94ca91e0fa425840e6f09394f40aa71c88ef6` (blob `54f5bd9e0501ef93a20a9aa61d8416f92bb99e40`).
- The v6 pair manifest is tracked from commit `b2f94ca91e0fa425840e6f09394f40aa71c88ef6` (blob `ffad6c7ad33e5257f8f500f49aaa3af447a5bf7e`); 4 LIVE pairs also have explicit historical `same-source` records.
- JOD score fields were ignored and are not quality evidence in this recovery.

## Mapping result

- Local LIVE inferred groups: 31
- Official canonical contents: 31
- Unique one-to-one canonical mappings: 31
- PROVEN source masters: 31
- STRONG_NOT_PROVEN: 0
- HEURISTIC: 0
- UNRESOLVED: 0
- CONFLICT: 0
- Duplicate mappings: []
- Unmapped local groups: []
- Unmapped official contents: []

Every mapping has the following combined evidence:
1. Exact local inventory filenames under the two explicit LIVE open-source roots.
2. Exact local JOD identity rows with the same content_name and both HDR10 and SDR formats.
3. Official HDRSDR-VQA paper linkage from the 31 open-source contents to AVT-VQDB-UHD-2-HDR.
4. Exact canonical-name correspondence to the pinned official AVT metric records.

## Recovered canonical source IDs

- `live:0_balance_forest` -> `AVT-VQDB-UHD-2-HDR/Balance_Forest` (`PROVEN`, local `0_Balance_Forest`)
- `live:1_basketball_afternoon` -> `AVT-VQDB-UHD-2-HDR/Basketball_Afternoon` (`PROVEN`, local `1_Basketball_Afternoon`)
- `live:2_basketball_evening` -> `AVT-VQDB-UHD-2-HDR/Basketball_Evening` (`PROVEN`, local `2_Basketball_Evening`)
- `live:3_cafe` -> `AVT-VQDB-UHD-2-HDR/Cafe` (`PROVEN`, local `3_Cafe`)
- `live:4_campfire` -> `AVT-VQDB-UHD-2-HDR/Campfire` (`PROVEN`, local `4_Campfire`)
- `live:5_conversation_bed` -> `AVT-VQDB-UHD-2-HDR/Conversation_Bed` (`PROVEN`, local `5_Conversation_Bed`)
- `live:6_conversation_standing` -> `AVT-VQDB-UHD-2-HDR/Conversation_Standing` (`PROVEN`, local `6_Conversation_Standing`)
- `live:7_dancing` -> `AVT-VQDB-UHD-2-HDR/Dancing` (`PROVEN`, local `7_Dancing`)
- `live:8_drawing` -> `AVT-VQDB-UHD-2-HDR/Drawing` (`PROVEN`, local `8_Drawing`)
- `live:9_face_close` -> `AVT-VQDB-UHD-2-HDR/Face_Close` (`PROVEN`, local `9_Face_Close`)
- `live:10_fountain` -> `AVT-VQDB-UHD-2-HDR/Fountain` (`PROVEN`, local `10_Fountain`)
- `live:11_guitar_handheld` -> `AVT-VQDB-UHD-2-HDR/Guitar_Handheld` (`PROVEN`, local `11_Guitar_Handheld`)
- `live:12_guitar_tripod` -> `AVT-VQDB-UHD-2-HDR/Guitar_Tripod` (`PROVEN`, local `12_Guitar_Tripod`)
- `live:13_interview` -> `AVT-VQDB-UHD-2-HDR/Interview` (`PROVEN`, local `13_Interview`)
- `live:14_knitting_close` -> `AVT-VQDB-UHD-2-HDR/Knitting_Close` (`PROVEN`, local `14_Knitting_Close`)
- `live:15_knitting_total` -> `AVT-VQDB-UHD-2-HDR/Knitting_Total` (`PROVEN`, local `15_Knitting_Total`)
- `live:16_night_biking` -> `AVT-VQDB-UHD-2-HDR/Night_Biking` (`PROVEN`, local `16_Night_Biking`)
- `live:17_onion_1` -> `AVT-VQDB-UHD-2-HDR/Onion_1` (`PROVEN`, local `17_Onion_1`)
- `live:18_onion_2` -> `AVT-VQDB-UHD-2-HDR/Onion_2` (`PROVEN`, local `18_Onion_2`)
- `live:19_parcours` -> `AVT-VQDB-UHD-2-HDR/Parcours` (`PROVEN`, local `19_Parcours`)
- `live:20_phone_call` -> `AVT-VQDB-UHD-2-HDR/Phone_Call` (`PROVEN`, local `20_Phone_Call`)
- `live:21_power_pole_sky` -> `AVT-VQDB-UHD-2-HDR/Power_Pole_Sky` (`PROVEN`, local `21_Power_Pole_Sky`)
- `live:22_programming_night` -> `AVT-VQDB-UHD-2-HDR/Programming_Night` (`PROVEN`, local `22_Programming_Night`)
- `live:23_reading_bench` -> `AVT-VQDB-UHD-2-HDR/Reading_Bench` (`PROVEN`, local `23_Reading_Bench`)
- `live:24_reading_stairs` -> `AVT-VQDB-UHD-2-HDR/Reading_Stairs` (`PROVEN`, local `24_Reading_Stairs`)
- `live:25_river` -> `AVT-VQDB-UHD-2-HDR/River` (`PROVEN`, local `25_River`)
- `live:26_sitting` -> `AVT-VQDB-UHD-2-HDR/Sitting` (`PROVEN`, local `26_Sitting`)
- `live:27_skateboarding` -> `AVT-VQDB-UHD-2-HDR/Skateboarding` (`PROVEN`, local `27_Skateboarding`)
- `live:28_swan` -> `AVT-VQDB-UHD-2-HDR/Swan` (`PROVEN`, local `28_Swan`)
- `live:29_walking_forest` -> `AVT-VQDB-UHD-2-HDR/Walking_Forest` (`PROVEN`, local `29_Walking_Forest`)
- `live:30_yoga` -> `AVT-VQDB-UHD-2-HDR/Yoga` (`PROVEN`, local `30_Yoga`)

## Decision

- LOCAL CORPUS PROVENANCE: `SUFFICIENT`
- PROVEN paired source masters: `31`
- EXTERNAL DATASET REQUIRED: `NO`
- Cross-source alias registry: `UNKNOWN`; the result proves unique canonical identities within the official AVT set.
- Media hashed: `NO`
- Media decoded: `NO`
- Objective evaluations: `0`

The next permitted phase is exact metadata qualification and selected-file byte hashing.
This recovery does not emit a v5 manifest and does not start calibration.
