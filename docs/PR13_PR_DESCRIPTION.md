## PR #13 — V4 invalidation enforcement + V5 qualification hardening

This PR preserves the failed preregistration history and creates a new V5
execution-bound semantic identity. It does not qualify a corpus for Tune and
does not run Tune, Validation, Frozen evaluation, or objective evaluation.

### Current remote state

```text
HEAD = see PR #13 remote metadata after the final push
Base = main
Unexpected files = 0
PR = OPEN / MERGE BLOCKED
```

### Honest preregistration lineage

```text
V1 = 7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608
V1 = RETIRED_INVALIDATED

V2 = 3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41
V2 = AUDIT_INVALIDATED

V3 = 7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889
V3 = AUDIT_INVALIDATED

V4 = bdbf705973fa43f92ab60435bfa04dc1656fdf52c4a8687070d1185b30c809fc
V4 = AUDIT_INVALIDATED

V4 initially accepted
→ later audit found the final policy-runtime seal missing
→ V4 audit-invalidated
→ V4 executable paths disabled
→ prior qualification temporal/root evidence invalidated
→ V5 remediation created
```

V4 remains available for historical inspection only. Its artifact declares
`status = AUDIT_INVALIDATED` and `preregistrationInvalidated = true`; V4
calibration and verify-only execution reject it.

### V5 semantic identity

```text
ColorScienceDefinitionHashV5 = 057db1bf0d85ab954fee1a65ecbd331c471304cbb7a2209178155e604d724895
PolicyDefinitionHashV5 = b6e7317ea0f388b0da550e159f502550231d67183c1bbb3edfd6b5232f1985a4
PreparationDefinitionHashV5 = bd22964e304b9b586404458c866e5365644bddae3da61510a1ed18149a8c8eb2
MetricDefinitionHashV5 = e91298bf754ddbd2729e0e0179ae7b8a93fc53e078769246788d685f920a40ea
GateDefinitionHashV5 = eff07a7558d8d35a1a16def158721c9303bb74632029b6e6d7d394eae36f62e9
SearchAlgorithmDefinitionHashV5 = 64c00c0155a3f43c1bde3b5ec0374b69655c367580e85dc6c610d3ba6863c064
RunnerDefinitionHashV5 = 72146bab5ae31605ca2ddfdb00752195fdacbbd7a29dc395acf37a9b2d02d494
BT709FinalRunnerSemanticHash = bd7e4dcc95ac5db393278c2ee7aadef134dc8b8304c509a5e7c841755dbfe6d0
BT1886FinalRunnerSemanticHash = ef9c88acb91ac0d42ee27b806007591f93de5f3231a80de276248b45761471a2
SearchDefinitionHashV5 = 6ae84a8a245858c2328bfe2c80811f12cdd1375e86109ec2f83d4bd3a6cdb43e
```

The V5 runtime derives the final runner configuration for each policy, hashes
that actual adapted configuration, and compares it to the sealed
policy-specific identity before candidate generation. Candidate shortlist
size is `3`; validation corpus minimum cardinality is a separate semantic
value of `6`. No corpus identity is created in this PR.

### Qualification evidence

The partial qualification artifact is bound to the current V5 artifact using
non-media input SHA-256 values. It records exact rational SDR/HDR presentation
timeline comparison, root-containment checks, fixed structural decode probes,
and acquisition-declared media hashes as `NOT_RECOMPUTED`. It contains no
computed media content SHA-256.

```text
Downloaded pairs = 20 / 20
QUALIFIED = 20
EXACT_TEMPORAL_MATCH = 20
ACQUISITION_PENDING = 11
Content hash / split / corpus seal = NOT RUN
```

### Verification boundary

```text
V4 historical invalidation tests = PASS
V5 semantic/mutation/conformance tests = PASS
Approved-root containment and synthetic symlink matrix = PASS
Exact rational temporal synthetic matrix = PASS
Qualification artifact/provenance verifier = PASS
Frozen media accessed = NO
New protected-path exposure = NO
Objective evaluations = 0
Tune = NO
Validation = NO
```

The next step is an independent V5 re-audit. This PR does not claim media
qualification acceptance, calibration success, a policy winner, or production
readiness.
