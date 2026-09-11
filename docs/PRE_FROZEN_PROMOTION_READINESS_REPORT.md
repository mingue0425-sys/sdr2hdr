# Pre-Frozen Promotion Readiness Report

Audit-only readiness record for the correctness baseline formed by PR #6
(automatic source precision), PR #7 (DV420 safe fallback), and PR #8
(real-media multi-flight correctness). This audit does not introduce a new HDR
algorithm, evaluate a quality objective, access Frozen/holdout media, or change
the validation corpus.

## Final verdict

```text
baseline: main@e8924b24399f7cec245539f1d9cfdc323da778cf
branch: pre-frozen-promotion-readiness
head: e8924b24399f7cec245539f1d9cfdc323da778cf implementation baseline

MERGED CORRECTNESS BASELINE
PR #6: a1e4a6506723da53212b2ad86fcde11f44bc4a92
PR #7: 45a88de44df9cc9a56b10a98e8bb3a83023308d6
PR #8: e8924b24399f7cec245539f1d9cfdc323da778cf

PRODUCTION DEFAULTS
tone curve: calibratedV4 / sceneRelativeV4
chroma reconstruction: nearest
automatic decode: enabled; source description 8-bit -> NV12, 10-bit -> P010; unresolved -> 8-bit/NV12 fallback
histogram: linear64, 64 bins, 16x9 causal estimator proxy
P010 normalization: current MSB code extraction and video/full-range ColorManagement coefficients
temporal: causal asynchronous one-frame-late estimator; temporalStability=0.7308984
EDR: output mode EDR; paper white=190 nits; peak=1008.6863 nits; mastering headroom=5.308875

AUTOMATIC DECODE
H264 8-bit: NV12 PASS
HEVC 8-bit: NV12 PASS
HEVC Main10: P010 PASS
precision mismatch: 0
fallback: 0 unexpected fallback; unresolved-source fallback remains explicit NV12 policy

P010
near-black: PASS; finite, non-zero, 16 input levels -> 20 output levels, ordering violations=0
code diversity: uniqueYCodes=435 in compressed integration; near-black input=16/output=20 levels
normalization: 10-bit code range 64...940 for video-range fixture; no accidental 8-bit quantization

DV420
safe fallback: PASS / SUPPORTED
NV12 parity: maxDelta=0.0
P010 parity: maxDelta=0.0
temporal parity: maxDelta=0.0
real-media coverage: 0 source, 0 fallback; no DV420 source was present in the unchanged corpus
full support: NOT_IMPLEMENTED

CHROMA CANDIDATE
nearest: production default; broadest validated path
sitingAwareBilinear: retained development candidate
promotion decision: KEEP_CANDIDATE
reason: synthetic edge evidence is positive, but external-media quality superiority is not established and the candidate remains narrower than nearest; DV420 must remain a safe nearest fallback

MULTIFLIGHT
remote portable: PASS (PR #9 macOS CI run 34584185077, job 103214442800); local required gate PASS
local native: PASS on physical Apple M2 with MTL_DEBUG_LAYER=1
depth2: PASS
depth3: PASS
NV12: PASS
P010: PASS
nearest: PASS
candidate: PASS

GENERATION
stale completion rejection: PASS
reset isolation: PASS
GPU sequence: monotonic and converges to final submission
adaptive sequence: monotonic and converges to final submission

TEXTURE LIFETIME
slots: 3 per size
max leases: 3; depth-2 and depth-3 evidence observed 2 and 3 respectively
premature reuse: none; fourth retained lease rejected
reuse after release: PASS

VMAPPLE
pure Metal: P1-P13 and BODY0-BODY5 PASS
HDR internal callbacks: H1/H3/H4 stage isolation PASS
external observer: KNOWN_NON_PRODUCTION_LIMITATION
classification: NON-BLOCKING / KNOWN_ENVIRONMENT_LIMITATION; local diagnostic did not reproduce it, and the PR #8 remote evidence remains preserved rather than hidden

EXTERNAL CORPUS
development: 12 sources; NV12=10, P010=2, fallback=0, mismatch=0, failures=0
validation: 5 manifest sources; runtime=4, metadata-only=1, NV12=4, P010=0, fallback=0, mismatch=0, failures=0

DIAGNOSTIC INSTRUMENTATION
decision: REMOVE always-on disabled-path allocation
runtime overhead: disabled path uses one renderer-owned fallback buffer; no per-command diagnostic buffer or completion handler
reason: the prior renderer allocated a writable diagnostic buffer for every presentation command even when diagnostics were disabled; opt-in diagnostics still retain per-command writable lifetime through GPU completion

KNOWN ISSUES
BLOCKERS: []
NON-BLOCKERS: VMAPPLE external test observer interaction; one validation manifest source is metadata-only outside the supported BT.709 runtime domain
DEFERRED: full DV420 reconstruction; external real-media multi-flight; display-link scheduling integration; forced command-buffer failure injection

PERFORMANCE BASELINE
1080p p50: EDR GPU 0.705 ms / p95 0.931 ms; PQ GPU 0.698 ms / p95 1.088 ms
1080p CPU: EDR p50 0.011 ms / p95 0.035 ms; PQ p50 0.011 ms / p95 0.027 ms
4K p50: EDR GPU 1.628 ms / p95 1.680 ms; PQ GPU 1.906 ms / p95 1.969 ms
4K CPU: EDR p50 0.014 ms / p95 0.023 ms; PQ p50 0.014 ms / p95 0.022 ms

PERFORMANCE_OPTIMIZATION_READY: YES

PRE_FROZEN_BASELINE_READY: YES

Virgin Frozen accessed:
NO

Objective evaluations:
0

working tree: clean after the audit commit; no unrelated source changes
```

The machine-readable versions of this verdict are
`results/pre-frozen-readiness.json` and
`results/pre-frozen-production-invariants.json`. The baseline fingerprint and
hash inputs are in `results/pre-frozen-baseline-fingerprint.json`.

## Provenance and scope

The production implementation under audit starts at `main@e8924b2`. PR #6,
PR #7, and PR #8 are recorded by full merge SHA above; no abbreviated SHA is
used for the provenance fields in the JSON artifacts. The regression fixture
manifest deliberately retains its historical baseline label `db01ba7`; its
reports separately record the current candidate as
`e8924b24399f7cec245539f1d9cfdc323da778cf`. That manifest label is not treated
as the current branch provenance.

The only production-tree cleanup in this audit is in
`Sources/HDRPlayer/HDRPresentationRenderer.swift`. It removes the disabled
path's per-command diagnostic allocation. It does not alter the presentation
shader, tone mapping, temporal state, histogram, P010 normalization, automatic
decode policy, texture-pool size, or EDR mapping. The enabled diagnostic path
still allocates a private writable buffer per command and captures it until GPU
completion, preserving the PR #8 resource-lifetime fix.

Frozen/holdout media was not opened. No quality objective or candidate metric
was evaluated. Every verification path reported `Virgin Frozen accessed: NO`
and `Objective evaluations: 0`.

## Production invariant snapshot

`HDRConfiguration.calibratedV4` is unchanged: `sceneRelativeV4`, paper white
190 nits, peak 1008.6863 nits, highlight strength 0.6208221, contrast strength
0.90542316, saturation compensation 0.43140942, shadow protection 0.4755874,
temporal stability 0.7308984, EDR output, and mastering headroom 5.308875.
The runtime histogram is the explicit `linear64`/64-bin strategy over the
existing 16x9 causal proxy. The production chroma default remains nearest.

P010 follows the merged path: Metal recovers the ten valid MSBs from the
16-bit normalized texture sample, then applies the current 10-bit video-range
offset `64/1023` and scale `1023/876`; full-range remains offset 0 and scale 1.
The 10-bit chroma center is `512/1023`. No arithmetic was changed for this
audit.

The complete invariant object, including every siting decision, is committed
as `results/pre-frozen-production-invariants.json`. Its production-defaults
canonical hash is
`80d145aba197149b5caf4e72bfe420fd00f049b71761a8bb6825d96a795bd087`.

## Automatic decode and P010 evidence

The automatic-decode gate exercised all required contracts:

| source | expected decode | result |
|---|---|---|
| H.264 8-bit | NV12 | PASS |
| HEVC 8-bit | NV12 | PASS |
| HEVC Main10 | P010 | PASS |

The 12 deterministic fixture contracts passed. The AVFoundation integration
reported six frames and GPU/adaptive sequence 6 for each required codec path.
The external development corpus independently reported NV12=10, P010=2,
fallback=0, mismatch=0.

The P010 compressed integration passed for both production nearest and the
siting-aware candidate. The captured Main10 fixture used `x420`, left chroma
siting, 10 frames, 92,160 finite samples, 23,029 non-zero samples, 435 unique
luma codes, and code range 64...940. The near-black regression fixture kept
16 distinguishable input levels, 20 distinguishable output levels, 17,280
non-zero samples, zero ordering violations, zero clipping fraction, and zero
NaN/infinity/negative samples. This is a preservation gate, not an objective
quality score.

## DV420 and siting audit

The resolver maps a requested siting-aware candidate to nearest only for
explicit `dv420`, with reason
`dv420RequiresComponentSpecificPhase`. Explicit nearest is never marked as a
fallback. The synthetic contract is exact for both layouts and temporal
statistics:

```text
NV12 DV420 fallback max RGB delta: 0.0
P010 DV420 fallback max RGB delta: 0.0
DV420 temporal-statistics fallback max delta: 0.0
```

For `center`, `left`, `topLeft`, `top`, `bottomLeft`, `bottom`, and
`unspecified`, the candidate remains siting-aware bilinear and nearest remains
nearest. For `dv420`, nearest remains nearest and a candidate request falls
back with the explicit reason above. The external development and validation
corpora contained zero DV420 sources, so real DV420 coverage is recorded as
zero rather than promoted to PASS by inference.

Full component-specific, field-dependent DV420 reconstruction is not
implemented. Future work requires component-specific Cb/Cr phase, field or
progressive geometry, top/bottom field handling, NV12/P010 parity, synthetic
ground truth, and real-media validation.

## Siting-aware bilinear promotion audit

The candidate is retained, not promoted. Existing synthetic evidence is
material: on the known siting-aware edge fixture, mean chroma error improved
from `0.0078125` (nearest) to `0.00048828125`, and edge displacement improved
from `0.25` to `0.0` luma pixels. NV12 and P010 scalar/Metal parity passed with
maximum RGB errors `0.00012040138` and `0.000120431185` respectively. The
candidate passed nearest/candidate deterministic, P010, external, and
multi-flight execution gates.

That evidence is not sufficient for default promotion because the external
corpus has no independent chroma ground truth or measured quality superiority
gate. It demonstrates safe execution and expected candidate deltas, not a
universal real-media quality win. The existing M2 development benchmark also
showed a higher candidate p95 cost for P010. Nearest therefore remains the
production default, while the candidate remains available for a future
quality-evidence PR.

## Regression and multi-flight evidence

The full deterministic matrix passed in both Debug and Release:

| coverage | fixtures / paths | result |
|---|---:|---|
| H.264 8-bit video range | dark gradient, neutral, motion, chroma edge | PASS |
| H.264 8-bit full range | neutral color | PASS |
| HEVC 8-bit | chroma edge | PASS |
| HEVC Main10/P010 | dark gradient, chroma edge, motion, VFR, near-black | PASS |
| timing | CFR and VFR fixtures | PASS |
| regression totals | 12 fixtures, Debug + Release | failures=0, skipped=0 |

The current physical Apple M2 run used `MTL_DEBUG_LAYER=1`, exercised seven
real-media fixtures, depth 2 and depth 3, both NV12 and P010, and nearest and
siting-aware modes. It produced 28/28 PASS, zero failures, three output
texture allocations, GPU sequence 8, and adaptive sequence 8 for each run.
Retirement used the portable `waitUntilCompleted` path after the full flight
depth was committed; that path is the required cross-SDK implementation.

The ordering tests separately passed six tests, including stale completion
rejection across reset, out-of-order completion handling, 100-iteration
generation stress, and the three-slot pool contract. The output pool rejected
a premature fourth retained lease and reused a slot after retirement.

## VMAPPLE completion classification

Pure Metal P1-P13 and BODY0-BODY5 passed, including the completion-handler
probes, with the physical Apple M2 device. HDR stage isolation passed H1
through H4 and all completion controls; production internal completion paths
were therefore not conflated with the additional external test observer.

The external observer interaction remains a known non-production limitation
from PR #8's remote evidence. The local diagnostic run did not reproduce it;
that is recorded as “not reproduced,” not converted into a universal PASS.
The failing/known diagnostic is retained in the artifact history and is not
used as a required production gate.

## External corpus and acquisition flake

The unchanged external development split has 12 sources: ten automatic NV12,
two automatic P010, zero fallback, zero mismatch, and zero failures. The
validation split has five manifest sources: four runtime sources and one
metadata-only source outside HDRCore's supported BT.709 SDR runtime domain;
the split has zero failures, four automatic NV12 decisions, zero P010, zero
fallback, and zero mismatch.

No media was added, moved, or reclassified. The prior intermittent AVPlayer
acquisition issue was not reproduced and remains `FLAKE_NOT_REPRODUCED`,
`DEFERRED`, and `NON-BLOCKING`; acquisition logic was not changed.

## Instrumentation decision

Decision: `REMOVE` the always-on disabled-path allocation, while retaining the
diagnostic feature itself. Before this audit, every presentation command
allocated a writable diagnostic buffer and registered a completion handler even
when diagnostics were disabled. The new disabled path binds one renderer-owned
zeroed fallback buffer; the shader's diagnostic branch is disabled, so the
buffer is read-only in practice and safe to share across in-flight commands.

When diagnostics are enabled, the renderer still allocates one private writable
buffer per command, captures it through the command-buffer completion handler,
and updates the diagnostic snapshot only after GPU completion. This preserves
the resource alias and lifetime guarantees while removing the production hot
path allocation and callback.

## Performance baseline

Measured on Apple M2, 8 GB, arm64, macOS 26.6.2 (25G83), Apple Swift 6.3.3,
Release build, calibrated-v4, NV12 8-bit nearest, 30 warm-up frames and 300
measured frames:

| resolution | mode | GPU p50 | GPU p95 | CPU submit p50 | CPU submit p95 |
|---|---|---:|---:|---:|---:|
| 1920x1080 | EDR | 0.705 ms | 0.931 ms | 0.011 ms | 0.035 ms |
| 3840x2160 | EDR | 1.628 ms | 1.680 ms | 0.014 ms | 0.023 ms |
| 1920x1080 | PQ | 0.698 ms | 1.088 ms | 0.011 ms | 0.027 ms |
| 3840x2160 | PQ | 1.906 ms | 1.969 ms | 0.014 ms | 0.022 ms |

These are reproducible baseline measurements, not a new optimization. The
future performance PR should investigate a result when GPU p50 regresses more
than 10% or GPU p95 more than 15% against this record, while rechecking the
production invariant and correctness fingerprints.

## Verification commands and gate hierarchy

Completed local gates:

```text
swift test -c debug --disable-index-store: PASS (333 tests, 16 skipped)
swift test -c release --disable-index-store: PASS (333 tests, 16 skipped)
swift build -c release --disable-index-store: PASS
bash -n RUN_MACOS_VERIFY.sh Tests/verify_script_cache_test.sh: PASS
bash Tests/verify_script_cache_test.sh: PASS
./RUN_MACOS_VERIFY.sh automatic-decode: PASS
./RUN_MACOS_VERIFY.sh p010: PASS
./RUN_MACOS_VERIFY.sh regression-full: PASS (Debug + Release, 12/12)
MTL_DEBUG_LAYER=1 ./RUN_MACOS_VERIFY.sh multiflight: PASS (28/28)
./RUN_MACOS_VERIFY.sh hdr-stage-isolation: PASS
HDR_REAL_MEDIA_ROOT=... ./RUN_MACOS_VERIFY.sh real-media: PASS (12 sources)
HDR_REAL_MEDIA_ROOT=... ./RUN_MACOS_VERIFY.sh real-media-validation: PASS (5 sources)
```

The required portable CI hierarchy is build, Debug tests, Release tests,
serial regression, automatic decode, and portable multi-flight. Diagnostic
evidence consists of VMAPPLE observer controls, pure Metal extended probes,
and HDR stage isolation. Local-native evidence consists of physical Apple
Silicon multi-flight and the two external corpus splits. Diagnostic tests are
kept because they detect future VM/runtime regressions and remain separate
from required production gates.

Remote CI for this branch passed in run `34584185077` / job `103214442800`;
the complete PR workflow finished successfully, including the required
portable multi-flight gate. The external observer diagnostic is allowed to
remain a known non-production limitation and must not be weakened to
manufacture a PASS.

## Blocker registry and next step

```text
BLOCKERS:
[]

NON-BLOCKERS:
- VMAPPLE external test observer interaction
- one validation manifest source is metadata-only under the existing BT.709 policy

DEFERRED:
- full DV420 component-specific reconstruction
- external real-media multi-flight
- display-link scheduling integration
- forced command-buffer failure injection
```

The production default decision is fixed at nearest, the candidate decision is
fixed at KEEP_CANDIDATE, correctness and resource-lifetime gates are passing,
and a reproducible performance baseline exists. Therefore
`PERFORMANCE_OPTIMIZATION_READY=YES` and
`PRE_FROZEN_BASELINE_READY=YES`. The next scoped work is a performance PR
that must compare before/after benchmarks while preserving the invariant,
manifest, and correctness fingerprints.
