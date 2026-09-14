## PR #13 — V5 invalidation enforcement + V6 corpus-contract execution binding

This PR preserves the failed preregistration history and creates the current
V6 semantic identity. The V6 corpus contract is a typed immutable object used
by the final runner and by the pre-objective corpus gate. This PR does not
hash media, create a corpus seal, run Tune, run Validation, open Frozen data,
or evaluate an objective.

### Current remote state

```text
HEAD = update from PR #13 remote metadata after the final push
Base = main
Unexpected files = 0
PR = OPEN / MERGE BLOCKED
Latest CI = update after the final push
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

V5 = 6ae84a8a245858c2328bfe2c80811f12cdd1375e86109ec2f83d4bd3a6cdb43e
V5 = AUDIT_INVALIDATED_BY_REAUDIT

V4 initially accepted
→ later audit found the final policy-runtime seal missing
→ V4 executable paths disabled
→ V5 remediation was independently invalidated because corpus semantics were hash-only
→ V5 executable paths disabled
→ V6 corpus contract is bound to the actual runner
```

V1–V5 remain available for historical inspection only. Their hashes are not
eligible for Tune or Validation.

### V6 semantic identity

```text
ColorScienceDefinitionHashV6 = 08b7bf442d5aa261df981d49c8fc464cd79709a6aafc20ff4f893c49cf3d6ab7
PolicyDefinitionHashV6 = 063ffbb862922b6893682945bdf56b6f6751b284836752821be9d45d1de8f846
PreparationDefinitionHashV6 = 0b7985f71ff08784db87648e934bb9c5dc82de6568ac32b5edeb6d61eec021d8
MetricDefinitionHashV6 = cab02e9c7da8355b01ae744e8f0a7c3c649f92f02981e0be8c44e8b8e98548bb
GateDefinitionHashV6 = 8038b78c0d650546164d5292ff3b82995d77d4a76870c4666d71a9417b8876b3
SearchAlgorithmDefinitionHashV6 = 2855a026b9cf18dcba7ea3d5a328ace98d6127407fa29d865857af4215135257
RunnerDefinitionHashV6 = e750ec2491428ca75c7012d6930e0d39fa44737be57bce6f83f07a3384ffe6d3
BT709FinalRunnerSemanticHashV6 = 048c58845e12df5ba7c815250ddcf2618e6d0cd660873aebd7b58021658fdb54
BT1886FinalRunnerSemanticHashV6 = 7c02ed29bf1cedab080cdd8fcb79261651a38ebea81d417ae0a69d01abc3b2cc
SearchDefinitionHashV6 = 45e6ff97c31d0c3ee8597434b7901e81e05f7bcf3db250ee0caec9ff9d9d94f8
```

The final runner derives both policies from the V6 artifact and compares the
actual policy-specific adapter identity with the sealed value before search.
The typed corpus contract is also installed on that runner. It enforces
`Tune >= 5`, `Validation >= 6`, `AT_LEAST` comparison semantics, `LIVE` family
coverage, and family-disjoint source-master roles. Candidate shortlist `3` is
separate from dataset cardinality.

### Qualification evidence

The partial qualification artifact is now bound to the canonical V6 artifact
and independently rechecks repository-resident input SHA-256 values. It
records exact rational SDR/HDR presentation timeline comparison, root
containment checks, fixed structural decode probes, and acquisition-declared
media hashes as `NOT_RECOMPUTED`. It contains no computed media content
SHA-256.

```text
Downloaded pairs = 20 / 20
QUALIFIED = 20
EXACT_TEMPORAL_MATCH = 20
ACQUISITION_PENDING = 11
Content hash / split / corpus seal = NOT RUN
```

### Verification boundary

```text
V5 historical invalidation tests = PASS
V6 canonical regeneration and runtime binding = PASS
V6 corpus cardinality/family/disjoint/coverage tests = PASS
V6 runtime override and fake-artifact rejection = PASS
Approved-root containment and synthetic protected-root matrix = PASS
Exact rational temporal synthetic matrix = PASS
Qualification artifact/provenance verifier = PASS
Frozen media accessed = NO
New protected-path exposure = NO
Objective evaluations = 0
Tune = NO
Validation = NO
```

The next step is an independent V6 re-audit. This PR does not claim corpus
sealing, calibration success, a policy winner, or production readiness.
