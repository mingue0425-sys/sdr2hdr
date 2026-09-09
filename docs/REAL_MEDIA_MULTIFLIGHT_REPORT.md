# Real-Media Multi-Flight Concurrency Validation Report

## Baseline

~~~text
baseline:
main@45a88de44df9cc9a56b10a98e8bb3a83023308d6

branch:
real-media-multiflight-development

validated functional head:
9f2168e
~~~

The branch is based on the current main baseline. The deterministic regression
manifest retains its historical matrix identity, but the multi-flight result
writer records the branch merge-base as the runtime baseline. No production HDR
source was changed.

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
→ retire the oldest command buffer
→ read back only after completion
→ release the HDRFrame/output lease
~~~

Each pending item retains its HDRFrame, output texture, readback buffer,
generation, submission sequence, source frame index, and presentation
timestamp until retirement. Completion handlers write immutable evidence
through a locked collector; XCTest assertions run after the runner has drained
the queue.

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

## Actual Overlap

The run produced 28 multi-flight mode executions: seven fixtures, two flight
depths, and two reconstruction modes (nearest and sitingAwareBilinear).

| flight depth | mode executions | maxObservedInFlight | maxPending | NV12 executions | P010 executions |
|---:|---:|---:|---:|---:|---:|
| 2 | 14 | 2 for all | 2 for all | 8 | 6 |
| 3 | 14 | 3 for all | 3 for all | 8 | 6 |

The first depth-sized batch uses a test-only MTLSharedEvent wait. The event is
attached after the real HDR and presentation work has been encoded, and is
signaled only after all depth command buffers have been committed. This makes
the overlap evidence deterministic for tiny 64×36 fixtures without adding a
production wait or changing shader arithmetic. The runner still retires
through the bounded queue and never submits beyond the configured depth.

## Completion Evidence

Every mode submitted eight frames with:

~~~text
submission frame indices: 0...7
submission sequences: 1...8
submission generation: constant during the run
completion identities: one event for each frame/sequence
readback identities: 0...7
~~~

The observed Metal completion sequence in this run was 1...8 for every mode.
The validator does not rely on that order; completion events are bound to
generation and submission sequence and are checked as an unordered identity
set. The completion collector records ordinal, status, error, GPU start/end
times, and completion wall-clock time.

Final ledger values for all 28 mode executions were:

~~~text
GPU completed sequence: 8
adaptive committed sequence: 8
completion events: 8
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

The full serial matrix and all multi-flight modes passed the existing output
gates:

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
swift test -c debug --disable-index-store: PASS
swift test -c release --disable-index-store: PASS
swift build -c release --disable-index-store: PASS
swift test -c debug --disable-index-store --filter HDRMultiFlightOrderingTests: PASS
bash Tests/verify_script_cache_test.sh: PASS
./RUN_MACOS_VERIFY.sh self-contained: PASS
./RUN_MACOS_VERIFY.sh p010: PASS
./RUN_MACOS_VERIFY.sh automatic-decode: PASS
./RUN_MACOS_VERIFY.sh regression: PASS (12/12, skipped=0, failures=0)
./RUN_MACOS_VERIFY.sh regression-full: PASS (Debug and Release serial matrix)
./RUN_MACOS_VERIFY.sh multiflight: PASS (28 mode runs, failures=0)
HDR_REAL_MEDIA_ROOT=/Volumes/game/sdr2hdr-v4-release/sdr2hdr-real-media ./RUN_MACOS_VERIFY.sh real-media: PASS
HDR_REAL_MEDIA_ROOT=/Volumes/game/sdr2hdr-v4-release/sdr2hdr-real-media ./RUN_MACOS_VERIFY.sh real-media-validation: PASS
git diff --check: PASS
~~~

The workflow now invokes ./RUN_MACOS_VERIFY.sh multiflight on macOS pull
requests. Remote CI status is pending until this branch is pushed.

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

Only test-support visibility, regression execution, and the verification
workflow changed. The production HDR processor, shaders, tone curve, temporal
coefficients, and resource-pool implementation were not modified.

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
- The overlap proof uses a test-only shared-event gate because the compressed
  fixtures are intentionally tiny. The production command encoding itself is
  unchanged.
- External multi-flight processing has not been added; external media remains
  covered by the existing serial development and validation runners.
- No safe forced command-buffer failure seam was available.
- Real playback display-link scheduling, frame dropping policy, and AVPlayer
  acquisition timing remain outside this PR.

## Recommended Next Step

Keep the serial regression path as the production-equivalent control and use
this multi-flight harness for future pool, lease, and causal-state changes. Any
production scheduler change should first add a separate playback integration
seam so decode acquisition, frame dropping, and GPU overlap can be measured
independently.

## Git State

~~~text
functional implementation head: 9f2168e
docs commit: pending
main was not modified or pushed from this work
~~~
