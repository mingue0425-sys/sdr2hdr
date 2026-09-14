# PR #13 — Stage A audit record frozen for Stage B remediation

This file freezes the Stage A audit state before Stage B implementation changes.
It is an audit record, not a preregistration and not corpus qualification evidence.

```text
repository = mingue0425-sys/sdr2hdr
correctness baseline = bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9
audited PR #13 head = ab6235e6e9e7f59c4aab9fe7e712229767fd41ea
starting verdict = PREREGISTRATION_REBASE_REQUIRED

BLOCKER = 4
HIGH = 6
MEDIUM = 4
LOW = 0
INFORMATIONAL = 1
TOTAL = 15

PREREGISTRATION_INVALIDATED = YES
OLD_SEARCH_DEFINITION_HASH = 7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608
OLD_HASH_ELIGIBLE_FOR_CALIBRATION = NO
```

The individual Stage A finding severities are preserved as issued. The summary
above corrects only the arithmetic; no individual finding severity is changed to
make the totals fit.

## Frozen finding index

The labels below are the Stage A remediation targets and remain immutable during
Stage B. Their pass/fail status is recorded later in the Stage B report.

```text
A01  preregistration semantic seal v2
A02  prepared-plan causal provenance
A03  non-vacuous old-plan relabel attack
A04  direct approved-root symlink protection
A05  component-wise symlink protection matrix
A06  LIVE31 mapping-array verifier
A07  LIVE31 sourceMaster uniqueness
A08  LIVE31 provenance regeneration in CI
A09  fallback diagnostic observability
A10  CPU/Metal BT.1886 domain parity
A11  real NV12/P010 production-path coverage
A12  GPU policy and edge-point parity coverage
A13  fail-closed semantic hash generation
A14  documentation evidence strength
INCIDENT  protected-area filename/path metadata exposure
```

## Protected-path incident

During the Stage A audit, recursive GitHub repository-tree metadata exposed
protected-area filename/path metadata. No protected media bytes were accessed.

```text
protected filename/path metadata exposed = YES
protected media bytes read = NO
protected media stat/probe = NO
protected media hash = NO
protected media decode = NO
objective evaluation = NO
```

No protected root is to be scanned to determine impact. Under the strict
path-enumeration policy, any already-observed audit record identifying a path in a
future Virgin/Frozen candidate set makes that candidate ineligible:

```text
VIRGIN_ELIGIBILITY = NO
```

The PR #11 guards remain unchanged and are not weakened by this remediation.

## Scope freeze

This Stage B task does not run media qualification, media hashing, v5 manifest
emission, Tune, Validation, candidate selection, Frozen evaluation, or any other
objective evaluation. Objective evaluations remain `0`.
