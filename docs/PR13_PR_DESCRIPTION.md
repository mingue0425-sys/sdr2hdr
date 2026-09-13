## PR #13 — V4 semantic closure rebase

This PR preserves the failed V1/V2/V3 audit history and introduces the V4
execution-bound semantic model. The current remote HEAD, changed-file count,
and latest CI result must be filled from the remote PR metadata immediately
after the final push; this file intentionally contains no stale HEAD claim.

### Current remote state

```text
HEAD = see PR #13 remote metadata after final push
Base = main
Unexpected files = 0
PR = OPEN / MERGE BLOCKED
```

### Preregistration lineage

```text
V1 = 7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608
V1 = RETIRED_INVALIDATED

V2 = 3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41
V2 = AUDIT_INVALIDATED

V3 = 7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889
V3 = AUDIT_INVALIDATED
```

V4 is the current semantic-only identity. Its generated artifact and
human-readable definition are committed in
`results/calibration-rebase-preregistration-v4.json` and
`docs/PR13_EXECUTION_BOUND_PREREGISTRATION_V4.md`.

### V4 identity

```text
ColorScienceDefinitionHash = ebb8093fd84a84962e1ef9d09c305eb23a4350363e637d84e617b08934daf463
PolicyDefinitionHashV4 = 91fd0ae9bd784249d74944650aedc25c57bfe5a71dae061df292c76509cdb66f
PreparationDefinitionHashV4 = b66b876f23d7caf9a87f3b6b541afafddbf781a24c0cb3f0b84529d0e799012d
MetricDefinitionHashV4 = a2b3743ed807d5e23a486a4f1e43c17cfcc188671e4dfe1b92cbe7df876e833f
GateDefinitionHash = f60288089864f6859a0fb387de104a5765ca1f1a82cdcc2b7b6975dcf7ba5844
SearchAlgorithmDefinitionHashV4 = bdd85748ded85135cd0b8ac8cd261a65cf12e73e13c5d9ad9a069a3d66309db1
RunnerDefinitionHash = 282fb562e72ff103dd2ffe67b91c624f3324a2d17601ee982437e4ffc361141a
SearchDefinitionHashV4 = bdbf705973fa43f92ab60435bfa04dc1656fdf52c4a8687070d1185b30c809fc
```

The V4 runner derives its final configuration from the sealed object, checks
the final runner identity before candidate generation, executes the two
policies with `128 global + 64 local = 192` candidates per policy, and hands
off exactly `3` validation candidates. Legacy V2/V3/V4 search entry points
are explicitly development-only and are not preregistered calibration routes.

### Bounded evidence

```text
Preparation closure = PASS
Matcher closure = PASS
Metric/color closure = PASS
Gate/ranking/failure closure = PASS
Final runner identity = PASS
Deterministic ordering/reduction = PASS
Materialization-root path safety = PASS
V4 regeneration and verify-only binding = PASS
Debug = 381 tests, 17 skipped, 0 failures
Release = 381 tests, 17 skipped, 0 failures
Release build = PASS
```

The independent static guard deliberately reports
`semantic completeness: NOT_PROVEN_BY_STATIC_SCRIPT`; semantic evidence is
the bounded call-graph inventory plus typed-owner and mutation tests.

### No data phase

```text
media qualification = NO
media hashing = NO
Tune = NO
Validation = NO
Frozen evaluation = NO
Objective evaluations = 0
CorpusDefinitionHash = NOT YET CREATED
ExperimentBindingHash = NOT YET CREATED
```

Historical Stage A incident remains recorded: protected filename/path metadata
was exposed, while protected bytes/stat/probe/hash/decode and objective
evaluation were not accessed/performed.
