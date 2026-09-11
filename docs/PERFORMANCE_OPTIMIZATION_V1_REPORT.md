# Performance Optimization v1 Report

## Verdict

`PERFORMANCE_V1_RESULT = PASS_CPU_SUBMISSION_IMPROVEMENT`

`PRE_FROZEN_BASELINE_PRESERVED = YES`

Blockers are empty. The retained change is P1: the zero-copy input lifetime still retains the same `CVPixelBuffer` and `CVMetalTexture` objects through GPU completion, but no longer materializes a per-frame Swift Array for those wrappers. The production preset, shader arithmetic, temporal estimator, histogram semantics, P010 normalization, EDR mapping, output pool, generation rules, and decode policy are unchanged.

Virgin Frozen was not accessed, holdout media was not opened, and objective evaluations remain `0`.

## Baseline and implementation

| Item | Value |
|---|---|
| Baseline | `main@393805254540277d65a74473b90ffdc46103ada7` |
| Branch | `performance-optimization-v1` |
| Validated implementation head | `8086c9f59097f369967f201a6dcfd43dc562ddf5` |
| Production preset | `calibrated-v4` |
| Tone curve | `sceneRelativeV4` |
| Production chroma | `nearest` |
| Candidate chroma | `siting-aware-bilinear`, retained as `KEEP_CANDIDATE` |
| Output | EDR |
| Histogram | `linear64`, 64 bins, 16x9 proxy |
| Temporal | causal asynchronous one-frame-late estimator |
| Device | Apple M2, 8 GB, macOS 26.6.2 (25G83) |
| Toolchain | Apple Swift 6.3.3, release |

The PR9 invariant and readiness artifacts remain the correctness oracle. Their canonical production-default hash is `80d145aba197149b5caf4e72bfe420fd00f049b71761a8bb6825d96a795bd087`; the production invariant artifact hash is `e2c9ca11c1d47643aff09c5f1fe524e695463bd1dd1f4894ce8c88fd03a0c3fd`.

## Profile and allocation audit

The hot path was inspected before edits. Pipelines, command queue, sampler state, CVMetalTextureCache, output texture ring, and temporal estimate buffers were already reusable. The transform and temporal estimator already share one compute encoder. The PR9 presentation cleanup already removed disabled-diagnostic per-command allocation and completion work.

| Resource/work | Before | After | Decision |
|---|---|---|---|
| Output RGBA16Float textures | Three persistent slots per size | Three persistent slots per size | Preserve contract |
| Temporal estimate buffers | One per active lease, lazy and persistent | Same | Preserve generation/lifetime behavior |
| CVMetalTexture wrappers | Two for YUV or one for BGRA per input buffer, retained through completion | Same | Required by zero-copy lifetime |
| `GPUInputLifetime` | Required completion-retained wrapper | Same wrapper semantics | Preserve |
| Retained-wrapper Swift Array | Materialized every input frame | Removed; fixed Y/UV/BGRA optional slots | P1 KEEP |
| Debug statistics buffers | Three per frame when diagnostics are enabled | Same; production disabled | Preserve |
| Presentation diagnostic fallback | Renderer-owned shared fallback when disabled | Same PR9 behavior | Preserve |

The deterministic resource evidence stayed at three output allocations for a prepared stream, one temporal buffer in serial mode, and three temporal buffers at flight depth three. The native multi-flight logs also show three simultaneous leases remain supported and are retired before reuse.

## Candidate ledger

### Kept: P1

`CVMetalInputTextures` now stores fixed optional wrapper slots. `GPUInputLifetime` copies those references directly, so the CoreVideo objects and pixel buffer remain alive until the completion handler releases the token. The compatibility array view exists only for the existing test assertion and is not used by production encoding.

Focused P010 tests passed 8/8. The full debug and release suites passed 333 tests each, with 16 expected skips and zero failures. Regression, multi-flight, native Metal, stage-isolation, and external-corpus gates also passed.

### Deferred: P2–P4

Metadata caching has no safe stable key that covers format changes, asset switches, seeks, and dynamic CoreVideo attachments. CVMetalTextureCache is already processor-lifetime state, while per-input plane wrappers cannot be reused across unrelated pixel buffers. Encoder merging is not justified because transform and estimator resource ordering is already correct and they share one encoder. Threadgroup-property lookup was not evidenced as a material cost.

### Rejected: P5

No tone-curve arithmetic, histogram binning, dispatch domain, precision, fast-math, or shader branch change was accepted. Those changes would turn this performance PR into a correctness or algorithm PR.

## Benchmark results

All final runs used release, `calibrated-v4`, nearest chroma, 30 warm-up frames, and 300 measured frames. The raw series, medians, and min/max spread are in [performance-v1-final.json](../results/performance-v1-final.json). The PR9 oracle values are preserved in [performance-v1-baseline.json](../results/performance-v1-baseline.json).

### Final core benchmark medians

| Path | GPU p50 ms | GPU p95 ms | CPU submission p50 ms | CPU submission p95 ms |
|---|---:|---:|---:|---:|
| 1080p EDR NV12 | 0.705 | 0.930 | 0.013 | 0.034 |
| 4K EDR NV12 | 1.659 | 1.981 | 0.015 | 0.027 |
| 1080p PQ NV12 | 0.844 | 1.508 | 0.013 | 0.035 |
| 4K PQ NV12 | 1.919 | 2.060 | 0.016 | 0.025 |
| 1080p EDR P010 | 0.823 | 1.094 | 0.013 | 0.022 |
| 4K EDR P010 | 1.937 | 1.980 | 0.015 | 0.024 |

The isolated P1 series was run before the final matrix. Its 1080p NV12 EDR CPU submission p50 was `0.010/0.010/0.011 ms`, versus the same-session pre-change comparator `0.014/0.018/0.018 ms`; median p50 improved by 44.44%. The corresponding p95 medians were `0.017 ms` versus `0.030 ms`. This is the accepted performance result. GPU p50 stayed within measurement noise, and no GPU improvement is claimed.

The final GPU p95 values show normal run-to-run variation, especially when the system clock changes. Because P1 does not touch Metal arithmetic or dispatch, those GPU differences are treated as noise rather than as an optimization result. No path crossed the investigation trigger as an attributable regression.

## Correctness evidence

- `swift test -c debug --disable-index-store`: 333 passed, 16 skipped, 0 failed.
- `swift test -c release --disable-index-store`: 333 passed, 16 skipped, 0 failed.
- Release build, shell syntax, and script-cache checks: PASS.
- Self-contained NV12/P010 and automatic-decode fixtures: PASS; H.264/HEVC 8-bit selects NV12 and HEVC Main10 selects P010.
- P010: unique Y codes `435`, code range `64...940`, finite samples `92160`; nearest and siting-aware candidate paths pass.
- Serial regression: 12/12 PASS, zero failures and zero skips in both debug and release.
- Native MTL debug-layer multi-flight: 28/28 PASS across depth 2/3, NV12/P010, nearest/candidate. The output pool remains three slots per size.
- Pure Metal probes: `PURE_METAL_MULTIFLIGHT_PASS`.
- HDR stage isolation: `HDR_STAGES_ALL_PASS` for H1–H4 and completion controls.
- External development corpus: 12 sources, 10 NV12 and 2 P010, zero failures, fallback, or precision mismatch.
- External validation corpus: 5 sources, 4 runtime NV12 passes and 1 declared metadata-only source outside the supported BT.709 runtime domain; zero failures, fallback, or mismatch.
- Generation, temporal sequence, texture lifetime, histogram, and shader parity remain covered by the existing PR9 gates; no arithmetic or shader file changed.

The refreshed gate artifact hashes and invariant fingerprint are recorded in [performance-v1-final-fingerprint.json](../results/performance-v1-final-fingerprint.json).

## Production contract status

```text
production preset: calibrated-v4
tone curve: sceneRelativeV4
production chroma: nearest
siting-aware bilinear: KEEP_CANDIDATE
DV420: safe nearest fallback; full component-specific reconstruction NOT IMPLEMENTED
automatic decode: current policy
P010 normalization: unchanged
histogram: linear64 / 16x9
temporal: causal asynchronous estimator
output: EDR
output texture pool: unchanged, 3 slots per size
generation/reset: unchanged
production arithmetic changed: NO
shader hashes changed: NO
Virgin Frozen accessed: NO
Objective evaluations: 0
```

## Remaining bottlenecks and follow-up

GPU kernel time remains dominated by the existing production transform and temporal estimator, not by the retained wrapper array. The next safe investigation would require a separate, explicitly measured metadata-key design or a GPU profile; it should not broaden this PR into a shader or scheduler rewrite. Full DV420 component-specific reconstruction, external real-media multi-flight, display-link scheduling, and forced command-buffer failure injection remain deferred as before.

## Final decision

P1 is a small, lifetime-preserving CPU submission optimization with a repeatable p50 reduction and no correctness drift. It is retained. The PR is ready for the normal remote CI and review gate under the title:

`perf(hdr): optimize production runtime without correctness drift`
