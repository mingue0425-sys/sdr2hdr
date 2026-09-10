# Real-Media Multi-Flight Concurrency Validation Report

## Baseline

~~~text
baseline:
main@45a88de44df9cc9a56b10a98e8bb3a83023308d6

branch:
real-media-multiflight-development

validated implementation head:
d025f993229f6e001b970e7b6c0c4367d3b109ea

remote isolation run:
34489118024 (head d025f993229f6e001b970e7b6c0c4367d3b109ea)
~~~

The branch is based on the current main baseline. The deterministic regression
manifest retains its historical matrix identity, but the multi-flight result
writer records the branch merge-base as the runtime baseline. The production
HDR algorithm and its tone, temporal, histogram, P010, EDR, and chroma-default
contracts were unchanged. The branch contains an isolated presentation
resource-lifetime safety fix plus test-only completion-handler and retirement
diagnostics; neither changes production arithmetic.

The current evidence is deliberately split into three claims:

~~~text
HDR CORE MULTIFLIGHT FAILURE: NOT REPRODUCED
VMAPPLE BASIC METAL MULTIFLIGHT FAILURE: DISPROVEN
TEST-OBSERVER COMPLETION-HANDLER INTERACTION: SUSPECTED
~~~

The first two labels describe the evidence boundary, not a claim that every
VMAPPLE callback path is portable. The mandatory portable remote run is now
green; the observer interaction remains an evidence-only diagnostic finding.

## Existing Serial Control

The existing serial runner remains the control path:

~~~text
decode selected frames
→ encode one HDRProcessor/presentation command buffer
→ commit
→ waitUntilCompleted
→ read back
→ release the frame lease
~~~

The serial path continues to use the shared makePendingFrame and
completePendingFrame helpers. This keeps output validity, metadata, timing, and
runtime sequence gates identical between the serial and multi-flight
experiments without changing the production processor.

The full deterministic 12-fixture serial matrix was rerun in Debug and
Release. It completed with failures=0 and skipped=0.

## Multi-Flight Path

The new path separates media acquisition from GPU scheduling:

~~~text
AVPlayerItemVideoOutput
→ decode the selected compressed frames once
→ retain the fixed CVPixelBuffer array
→ encode production-equivalent HDRProcessor and offscreen presentation work
→ submit a bounded queue at depth 2 or 3
→ commit the full configured depth before retiring the oldest command buffer
→ waitUntilCompleted on the oldest command buffer (mandatory portable path)
→ read back only after completion
→ release the HDRFrame/output lease
~~~

Each pending item retains its HDRFrame, output texture, readback buffer,
generation, submission sequence, source frame index, and presentation
timestamp until retirement. The mandatory path registers no external test
observer or async waiter: it records retirement identity/status/error and then
checks the processor's internal completion ledger. An optional native-only mode
adds the external collector and ordinal evidence. XCTest assertions run after
the runner has drained the queue.

The deterministic multi-flight subset contains seven high-information
compressed fixtures:

~~~text
H.264 NV12 motion
H.264 NV12 VFR motion
H.264 NV12 chroma edge
HEVC 8-bit NV12 chroma edge
HEVC Main10 P010 motion
HEVC Main10 P010 VFR motion
HEVC Main10 P010 near-black
~~~

The complete 12-fixture serial matrix remains the mandatory decode and output
gate. The subset is used for the concurrency path so AVPlayer acquisition
noise does not obscure GPU ordering evidence.

## Submission and Retirement Evidence

The run produced 28 multi-flight mode executions: seven fixtures, two flight
depths, and two reconstruction modes (nearest and sitingAwareBilinear).

| flight depth | mode executions | maxSubmittedBeforeRetirement | maxPending | NV12 executions | P010 executions |
|---:|---:|---:|---:|---:|---:|
| 2 | 14 | 2 for all | 2 for all | 8 | 6 |
| 3 | 14 | 3 for all | 3 for all | 8 | 6 |

The first depth-sized batch appends test-only work to each command buffer: an
8-pass fill over a retained 32 MiB shared buffer. This keeps the first batch
observable as submitted and incomplete for tiny 64×36 fixtures without a
cross-queue event, a production wait, or any shader arithmetic change. The
runner still retires through the bounded queue and never submits beyond the
configured depth.

The mandatory local Apple M2 runner completed all 28 executions with
failures=0 under `MTL_DEBUG_LAYER=1` in three consecutive runs. The optional
`multiflight-native-observer` mode also completed all 28 executions with
failures=0 in three consecutive runs, including callback identity and ordinal
checks. The remote Apple Paravirtual run listed above also completed the
mandatory portable matrix with failures=0 for all 28 executions. Its separate
native external-observer diagnostic remains a known signal-5 failure and is
not part of the portable production gate.

`maxSubmittedBeforeRetirement` is a queue-state fact, not a claim that a
profiler observed simultaneous GPU-core execution. For depth 2 the sequence is
`commit 1 → commit 2 → wait/retire 1`; depth 3 is analogous.

## VMAPPLE Isolation Ladder

The remote run used macOS 15.7.9, Darwin 24.6.0, arm64, and an Apple
Paravirtual device. The ladder was run as separate Swift-test processes, with
the result and raw logs uploaded for both the production gate and the
observer-only diagnostics.

The remote pure-Metal ladder, with two command buffers encoded before either is
waited, was:

~~~text
P1_empty:                   PASS remote/local
P2_blit:                    PASS remote/local
P3_compute:                 PASS remote/local
P4_render:                  PASS remote/local
P5_compute_render_blit:     PASS remote/local
P6_shared_pipeline:         PASS remote/local
P7_shared_readonly_texture: PASS remote/local

classification: PURE_METAL_MULTIFLIGHT_PASS
~~~

The revision adds a separate completion-handler cardinality matrix and a
handler-body matrix. Each case is a separate Swift-test process so one crash
cannot erase later evidence:

~~~text
P8  one command buffer / one no-op handler:       PASS remote/local
P9  two command buffers / one handler each:        PASS remote/local
P10 one command buffer / two handlers:             PASS remote/local
P11 one command buffer / three handlers:           PASS remote/local
P12 two command buffers / two handlers each:       PASS remote/local
P13 two command buffers / three handlers each:     PASS remote/local

BODY0 no-op:             PASS remote/local
BODY1 status-read:       PASS remote/local
BODY2 locked-counter:    PASS remote/local
BODY3 lifetime-capture:  PASS remote/local
BODY4 semaphore:         PASS remote/local
BODY5 continuation:      PASS remote/local
~~~

The artifact records expected handler cardinality from the test source and
explicitly labels it as non-introspective. P12/P13 record both total expected
registrations and expected registrations per command buffer.

The production-stage ladder used the same two-frame, depth-two fixture and
`waitUntilCompleted`:

~~~text
H1_HDRProcessor_only:              PASS
H2_HDRProcessor_plus_raw_blit:     PASS
H3_HDRProcessor_plus_presentation: PASS
H4_full_path:                      PASS
~~~

The remote completion-handler controls isolated the remaining failure from the
production stages:

~~~text
H4 completionHandler+directWait:  SIGNAL 5 (exitCode=1)
H4 completionHandler+asyncWaiter: SIGNAL 5 (exitCode=1)

classification: VMAPPLE_TEST_OBSERVER_COMPLETION_HANDLER_INCOMPATIBILITY
~~~

The complete remote observer-control matrix was:

~~~text
H1 + no-op observer / direct wait:      SIGNAL 5
H1 + counter observer / direct wait:    SIGNAL 5
H3 + no-op observer / direct wait:      SIGNAL 5
H4 + no-op observer / direct wait:      SIGNAL 5
H4 + counter observer / direct wait:    SIGNAL 5
H4 + counter observer / async waiter:   SIGNAL 5

local observer controls: PASS
first failing control: H1_completion_handler_noop
~~~

All six controls reached `phase=committed count=2` before signal 5; the first
failing control was `H1_completion_handler_noop`. Thus the remote result does
not support a basic VMAPPLE inability to encode or complete two empty, blit,
compute, render, mixed, shared-pipeline, or shared read-only texture command
buffers, and it does not implicate the production `waitUntilCompleted` path.
It does show that adding the test external completion observer to the
production command-buffer path remains unresolved on that device. The
artifact records `observerDiagnostic.status=KNOWN_FAIL` and preserves the
observer-specific raw logs.

## VMAPPLE Minimal Diagnostic Matrix

The four diagnostic processes used fixture `h264-8-video-24-chroma-edge`,
frames=2, depth=2, nearest reconstruction, and ran on the same Apple
Paravirtual device:

The revised diagnostic mode explicitly enables the optional native external
observer, so it remains an observer-interaction probe rather than silently
turning into another portable-retirement run. Its result is evidence-only.

~~~text
case A: MTL_DEBUG_LAYER=1, scheduling work ON  (32 MiB, 8 shared blit passes): SIGNAL 5
case B: MTL_DEBUG_LAYER=0, scheduling work ON  (32 MiB, 8 shared blit passes): SIGNAL 5
case C: MTL_DEBUG_LAYER=1, scheduling work OFF (0 bytes, 0 passes):           SIGNAL 5
case D: MTL_DEBUG_LAYER=0, scheduling work OFF (0 bytes, 0 passes):           SIGNAL 5

classification:
  HDR CORE MULTIFLIGHT FAILURE NOT REPRODUCED
  VMAPPLE BASIC METAL MULTIFLIGHT FAILURE DISPROVEN
  TEST-OBSERVER COMPLETION-HANDLER INTERACTION SUSPECTED
~~~

The process-independent matrix therefore did not vary with the Metal debug
layer or the test-only scheduling work. The deep markers show both output
leases active at frame 1, output lease IDs 0 and 1, two temporal-estimator
buffers with distinct identities, and presentation audit flags for
per-command writable buffers, read-only fallback textures, and completion
lifetime retention. The observer-enabled runner then signaled during the first
retirement window. Because P1–P7 and H1–H4 with `waitUntilCompleted` passed,
this does not support an HDR-core or basic-Metal classification. It points
specifically at the test-observer completion path; the portable remote run is
the production gate and is green.

## Completion Evidence

Every mode submitted eight frames with:

~~~text
submission frame indices: 0...7
submission sequences: 1...8
submission generation: constant during the run
portable retirement identities: one event for each frame/sequence
readback identities: 0...7
~~~

The mandatory validator does not rely on an external callback ordinal. It
checks submission identity, ordered portable-retirement identity, command
buffer status/error, the processor's internal GPU/adaptive ledgers, and final
sequence convergence. The optional native observer validates callback identity
and ordinal separately; its callback order is diagnostic evidence, not a
portable production gate.

Final ledger values for all 28 mode executions were:

~~~text
GPU completed sequence: 8
adaptive committed sequence: 8
portable retirement events: 8
command buffer errors: none
~~~

## Generation Reset and Stale Completion Safety

The low-level state-store tests simulate:

~~~text
completion 3 accepted
completion 1 arrives
completion 2 arrives
~~~

The committed state remains at sequence 3, and the GPU ledger remains
monotonic. A 100-iteration stress test repeats reverse ordering together with
generation changes.

The processor-level reset test submits three old-generation frames, calls the
real clearTemporalHistory path, then completes the old commands. Their
completion callbacks produce no current-generation adaptive trace. Two new
generation frames then complete successfully and establish the new sequence.
Old completions applied to the new generation: 0.
New-generation state corrupted: NO.

## Texture Pool and Readback Lifetime

The output texture pool has three slots per size. The multi-flight artifact
reported:

~~~text
depth 2:
  maximum simultaneous leases: 2
  output texture allocations: 3
  temporal estimate buffer allocations: 2

depth 3:
  maximum simultaneous leases: 3
  output texture allocations: 3
  temporal estimate buffer allocations: 3
~~~

The focused pool test retains all three HDRFrame values after their command
buffers complete. A fourth acquisition is rejected while the leases remain
held. Releasing one frame permits reuse without increasing the allocation
count. The multi-flight runner reads each shared buffer only after its command
buffer has completed and releases the pending frame afterward.

## Temporal Causality

The same production processor, automatic temporal estimator, scene-relative
state store, and trace paths run in serial and multi-flight modes.

For every multi-flight submission:

~~~text
consumed temporal state version < submission sequence
consumed scene state version < submission sequence
~~~

For every accepted completion trace:

~~~text
GPU completion sequence
= adaptive committed sequence
= temporal state version produced
= scene state version produced
~~~

The dropped-frame test submits source indices [0, 1, 3, 4] and verifies
processor submission sequences [1, 2, 3, 4]; source frame numbering is not used
as the causal sequence. The multi-flight run also verifies monotonic
presentation timestamps and accepts VFR timestamps through the existing
timestamp contract.

## Serial Versus Multi-Flight

V4's adaptive estimator is causal, so submitting several frames before their
completion can make a later frame consume an older available snapshot than the
serial control. The contract is therefore causal-latency-aware rather than
unconditionally pixel-bit-exact.

The hard parity gates are:

~~~text
finite/non-zero output
same output and timestamp validation
no future-state consumption
monotonic GPU/adaptive ledgers
final adaptive sequence convergence
~~~

Across the 28 runs:

~~~text
final adaptive sequence match: 28/28
maximum observed absolute luminance delta: 0.0131430253
maximum observed P95 absolute luminance delta: 0.00791675597
~~~

These deltas are recorded as scheduling diagnostics. No arbitrary tolerance was
introduced to claim bit-exact equivalence.

## Output Correctness

The full serial matrix and the local multi-flight modes passed the existing
output gates:

~~~text
finite samples: PASS
NaN/Inf rejection: PASS
non-zero output: PASS
negative-value rejection: PASS
clipping/content gates: PASS
metadata/timestamp gates: PASS
~~~

Both NV12 and P010 were processed through nearest and siting-aware candidate
paths. The DV420 safe fallback contract remains owned by the existing tests.

## External Media

The existing external corpus was rerun through its serial regression path:

~~~text
development: 12 sources, failures=0
  automatic NV12: 10
  automatic P010: 2
  fallback: 0
  precision mismatch: 0

validation: 5 sources, failures=0
  automatic NV12: 4
  automatic P010: 0
  fallback: 0
  precision mismatch: 0
~~~

The multi-flight runner intentionally uses predecoded deterministic frames for
this PR. External AVPlayer window acquisition is not used as a proxy for GPU
overlap, so the previously observed acquisition flake is not silently converted
into a multi-flight result. External multi-flight coverage remains follow-up
work.

## Failure Injection

No safe production Metal command-buffer failure injection seam was available
for this test-only path. The failure path is therefore recorded as not tested,
not as a false PASS. Normal command completion failures remain surfaced as
runner errors and cannot be read back or released as successful frames.

## Tests

Executed locally:

~~~text
swift test -c debug --disable-index-store: PASS (333 tests, 16 skipped, 0 failures)
swift test -c release --disable-index-store: PASS (333 tests, 16 skipped, 0 failures)
swift build -c release --disable-index-store: PASS
bash -n RUN_MACOS_VERIFY.sh: PASS
./RUN_MACOS_VERIFY.sh pure-metal-multiflight: PASS (P1–P7, P8–P13, BODY0–BODY5)
./RUN_MACOS_VERIFY.sh hdr-stage-isolation: PASS (H1–H4 plus observer matrix)
./RUN_MACOS_VERIFY.sh multiflight-diagnostic: PASS (native observer not reproduced locally)
MTL_DEBUG_LAYER=1 ./RUN_MACOS_VERIFY.sh multiflight: PASS ×3 (28 mode runs each)
MTL_DEBUG_LAYER=1 ./RUN_MACOS_VERIFY.sh multiflight-native-observer: PASS ×3 (28 mode runs each)
remote CI 34489118024: PASS (all workflow steps; portable multiflight 28/28)
remote pure-metal artifact: PASS (P1–P13, BODY0–BODY5)
remote HDR stage artifact: H1–H4 PASS; observer controls KNOWN_FAIL (signal 5)
remote observer diagnostic: KNOWN_FAIL (A–D signal 5; native external observer)
git diff --check: PASS
~~~

The workflow invokes `./RUN_MACOS_VERIFY.sh multiflight` as the mandatory
portable gate. The pure-Metal cardinality/body probes and HDR observer controls
run under `if: always()` and record failures without converting them into a
production-stage failure. In remote CI run 34489118024 the portable retirement
path passed; the observer-specific failures remain visible in their separate
artifacts and do not change the production gate result.

## Presentation Resource Binding Finding

The first CI attempts terminated at the first retirement with signal 5.
Inspection of the validated presentation path found
that `presentationFragment` writes its diagnostic statistics through buffer(1),
while `HDRPresentationRenderer` shared one writable fallback diagnostic buffer
across concurrent command buffers. That allowed in-flight submissions to alias
a writable Metal resource. The earlier resource-binding work keeps the
unconditional texture, sampler, and buffer bindings valid; commit `736b84c`
removes the shared writable fallback and allocates, zeroes, binds, and retains
one diagnostic buffer per command buffer until completion. The read-only 1×1
fallback texture remains shareable. This changes no presentation arithmetic or
production HDR parameters. With the fix, the local multi-flight matrix passes
under Metal API Validation. The remote ladder showed that P1–P7 and H1–H4
also pass when completion is obtained with `waitUntilCompleted`, while the
observer controls still signal. The resource-lifetime fix remains a valid
safety fix, but it is not claimed to fix or explain the separate test-observer
interaction.

## Production Invariants

~~~text
calibratedV4 changed: NO
toneExpand arithmetic changed: NO
temporal coefficients/arithmetic changed: NO
histogram production strategy changed: NO
P010 normalization changed: NO
automatic decode changed: NO
EDR mapping changed: NO
production chroma default: nearest
DV420 safe fallback preserved: YES
~~~

The multi-flight implementation is test support. Production arithmetic changes:
NO. The production-source changes are the presentation resource-binding safety
fix above and environment-gated HDRProcessor progress/resource evidence used
only by the diagnostic runner. The markers are inactive unless explicitly
enabled and do not change HDR processor arithmetic, tone curve, temporal
coefficients, or resource-pool policy.

## Protected Evaluation Isolation

~~~text
K-Choreo accessed: NO
Virgin Frozen accessed: NO
Objective evaluations: 0
~~~

## Remaining Risks

- Natural Metal completion order on the local single queue was submission
  ordered. Reverse completion behavior is covered by deterministic state-store
  and processor tests, but a real GPU out-of-order completion was not observed.
- The overlap proof uses test-only buffer-fill work because the compressed
  fixtures are intentionally tiny. The production command encoding itself is
  unchanged.
- External multi-flight processing has not been added; external media remains
  covered by the existing serial development and validation runners.
- No safe forced command-buffer failure seam was available.
- Real playback display-link scheduling, frame dropping policy, and AVPlayer
  acquisition timing remain outside this PR.
- The Apple Paravirtual observer controls still signal even though the pure
  Metal ladder, `waitUntilCompleted` production stages, and portable
  real-media gate pass. The observer-specific runtime interaction remains a
  known diagnostic limitation.

## Recommended Next Step

Keep the serial regression path as the production-equivalent control and use
this multi-flight harness for future pool, lease, and causal-state changes.
Treat the portable gate as the remote production criterion and retain the
pure-Metal/HDR observer matrices as evidence-only diagnostics. Any production
scheduler change should first add a separate playback integration seam so
decode acquisition, frame dropping, and GPU overlap can be measured
independently.

## Git State

~~~text
diagnostic implementation head: d025f993229f6e001b970e7b6c0c4367d3b109ea
production resource-lifetime fix: 736b84c
remote isolation run: 34489118024 (PASS; portable gate 28/28)
remote observer diagnostics: KNOWN_FAIL (signal 5; artifacts retained)
docs commit: docs(hdr): finalize multi-flight merge verdict
main was not modified or pushed from this work
~~~

## Final Verdict

~~~text
baseline: main@45a88de44df9cc9a56b10a98e8bb3a83023308d6
branch: real-media-multiflight-development
head: d025f993229f6e001b970e7b6c0c4367d3b109ea (validated implementation)

PURE METAL:
P1-P7: PASS remote/local
P8: PASS remote/local
P9: PASS remote/local
P10: PASS remote/local
P11: PASS remote/local
P12: PASS remote/local
P13: PASS remote/local

first failing completion-handler probe:
pure Metal: none
HDR observer controls: H1_completion_handler_noop (remote signal 5)

HANDLER BODY:
no-op: PASS remote/local
status-read: PASS remote/local
locked-counter: PASS remote/local
lifetime-capture: PASS remote/local
semaphore: PASS remote/local
continuation: PASS remote/local

HDR HANDLER MATRIX:
H1 internal-only: PASS remote/local
H1 + no-op observer: remote SIGNAL 5; local PASS
H1 + counter observer: remote SIGNAL 5; local PASS
H3 internal-only: PASS remote/local
H3 + no-op observer: remote SIGNAL 5; local PASS
H4 internal-only: PASS remote/local
H4 + no-op observer: remote SIGNAL 5; local PASS
H4 + counter: remote SIGNAL 5; local PASS
H4 + async waiter: remote SIGNAL 5; local PASS

classification:
HDR CORE MULTIFLIGHT FAILURE NOT REPRODUCED
VMAPPLE BASIC METAL MULTIFLIGHT FAILURE DISPROVEN
TEST-OBSERVER COMPLETION-HANDLER INTERACTION SUSPECTED

PORTABLE MULTIFLIGHT:
remote: PASS (28/28)
local: PASS ×3 (28/28 each)
depth2: PASS
depth3: PASS
NV12: PASS
P010: PASS

LOCAL NATIVE OBSERVER:
result: PASS
repetitions: ×3 (28/28 each)

GENERATION:
PASS

TEXTURE LIFETIME:
PASS

REMOTE CI:
PASS (34489118024; all workflow steps green)

VMAPPLE observer diagnostic:
KNOWN_FAIL
reason: native external test observer completion-handler interaction; diagnostic-only

production arithmetic changed:
NO

renderer safety fix:
PRESERVED
reason: per-command writable diagnostic buffer and GPU-completion lifetime retained

diagnostic HDRProcessor instrumentation:
RETAINED
reason: environment-gated, test-only progress/resource evidence; arithmetic inert

Virgin Frozen:
NO

Objective evaluations:
0

PR #8 merge recommendation:
YES

Rationale:
- remote portable multi-flight passes 28/28
- physical Apple Silicon native multi-flight passes three consecutive runs
- pure Metal completion-handler probes P8-P13 and BODY0-BODY5 pass remotely
- production HDR internal completion-handler paths pass remotely
- the remaining VMAPPLE SIGTRAP is isolated to an additional test-only external
  completion observer and is not required by the production runtime
- the failing observer diagnostic remains preserved as a known environment-specific
  limitation rather than being hidden or converted into a false PASS

working tree:
clean after docs commit
~~~
