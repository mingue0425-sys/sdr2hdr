# Pre-Frozen Protocol Recovery

## Incident

The previous pre-Frozen seal attempt was aborted after a broad repository file
listing included the previously virgin candidate root under `data_video`.
Under the strict protocol, path enumeration itself is a secrecy violation.
The incident is recorded in
[`results/frozen-protocol-incident.json`](../results/frozen-protocol-incident.json).

The exposed information was limited to path names. No media content was read,
no metadata was probed, no video was decoded, no frames were extracted, no
metrics were run, and no objective evaluation was performed. The objective
evaluation counter remains `0`.

## Status of the previous set

```text
PREVIOUS_FROZEN = CONTAMINATED_BY_PATH_ENUMERATION
VIRGIN_STATUS = INVALIDATED
OLD_FROZEN_EVALUATION_ELIGIBLE = NO
OBJECTIVE_EVALUATIONS = 0
```

The previous set is quarantined. This recovery change does not enumerate,
delete, hash, decode, or otherwise inspect it. It is not reused as development,
validation, or future Frozen evaluation data.

## Recovery policy

The recovery branch is based on the merged production baseline:

```text
baselineMain = d7fb59e8ca8b085264dfe1fca92aa6b98efd3cf6
```

No production source, shader, arithmetic, configuration default, manifest
meaning, or runtime behavior is changed. The recovery adds only an incident
record, an allowlist scope, a static broad-enumeration guard, and CI validation
of those controls.

The new Frozen set is not prepared or exposed in this change. When it is later
prepared by a separate trusted process, the development agent may receive
only an opaque identifier and an attestation that it was previously untouched.
The agent must not receive its names, count, formats, sizes, durations,
metadata, or binary hashes.

## Allowlist-only seal scope

[`config/pre-frozen-seal-scope.json`](../config/pre-frozen-seal-scope.json) is
the committed scope definition. It contains explicit production roots,
shader files, exact manifest/artifact files, and verification files. It does
not configure a Frozen root. Seal code must access only those explicit paths;
it must never scan the repository and then subtract a Frozen directory.

The development/validation external manifest is listed as one explicit file.
The parent `data_video` directory is not a seal root. Broad commands such as
`rg --files data_video`, `find data_video`, recursive repository walks, and
runtime Frozen-root injection are prohibited.

Scope hardening is category-specific: any `data_video/**` path is forbidden in
production roots, shaders, result files, verification files, and planned
verification files. A media path is accepted only as an exact file present in
both `exactFiles` and `approvedExplicitMediaFiles`; directory roots and glob
syntax are rejected. `Tests/verify_pre_frozen_seal.py` is a planned future
file, not a current verification target and is not opened by this recovery
change.

## Guard

[`Tests/verify_no_frozen_access.py`](../Tests/verify_no_frozen_access.py) reads
only the scope file and explicit target files supplied by its caller. It does
not discover files from the repository root or walk any media directory. It
validates path traversal, glob syntax, symlink use, scope mode, and static
patterns for broad media enumeration and Frozen path injection.

The recovery CI runs the guard against the committed scope and workflow. The
scope itself is the primary verification-file list. It scans the current
`RUN_MACOS_VERIFY.sh`, the workflow, and the guard path only; the guard source
is validated for path/symlink policy but excluded from its own broad-command
text scan so that its regex definitions cannot self-trigger. The existing
`RUN_MACOS_VERIFY.sh` optional `V6_FROZEN_PLAN` hook is locked to its recorded
baseline hash and cannot change under this scope. The future seal verifier is
declared separately as planned and must be added to current verification only
when it exists and remains allowlist-only.

`Tests/verify_no_frozen_access_test.py` exercises positive allowlist cases and
negative media-root, traversal, broad-shell-scan, recursive-walk, and symlink-
safe target cases using temporary non-media fixtures. It never inspects the
previous contaminated set or any new Frozen root.

## Exactly-once protocol

The next seal may be created only after a trusted process attests that a new
opaque Frozen set is non-empty, previously unused for development, and still
unexposed to this agent. The set itself must not be enumerated or hashed during
seal creation. The next objective-evaluation protocol remains separate:

```text
newFrozenAccessState = UNTOUCHED
objectiveEvaluations = 0
evaluation begins only after an atomic 0 -> 1 receipt
any evaluation-start failure consumes the exactly-once attempt
```

No evaluator is run by this recovery change, and no Frozen path is injected in
CI.

## Recovery verdict

```text
PROTOCOL RECOVERY = PASS
PREVIOUS_FROZEN = CONTAMINATED_BY_PATH_ENUMERATION
PREVIOUS_PATH_ENUMERATION = YES
PREVIOUS_MEDIA_CONTENT_READ = NO
PREVIOUS_VIDEO_DECODE = NO
PREVIOUS_METRICS = NO
OBJECTIVE_EVALUATIONS = 0
OLD_FROZEN_EVALUATION_ELIGIBLE = NO
NEW_FROZEN_PREPARED = NO
NEW_FROZEN_EXPOSED = NO
NEW_FROZEN_ACCESS_STATE = NOT_AVAILABLE
SEAL_SCOPE = ALLOWLIST_ONLY
BROAD_MEDIA_ENUMERATION = BLOCKED
DATA_VIDEO_DIRECTORY_ROOTS = FORBIDDEN
APPROVED_EXPLICIT_MEDIA_FILES = ENFORCED
VERIFICATION_FILES_STATIC_SCAN = PASS
BROAD_REPOSITORY_ENUMERATION = BLOCKED_FOR_SEAL_VERIFICATION
PRODUCTION_SOURCE_CHANGED = NO
SHADER_CHANGED = NO
PRODUCTION_BEHAVIOR_CHANGED = NO
READY_FOR_NEW_PRE_FROZEN_SEAL = NO
```

`READY_FOR_NEW_PRE_FROZEN_SEAL` remains `NO` until the separate trusted
preparation process provides the opaque untouched-set attestation. This PR is
therefore recovery/guard work only; it is not the pre-Frozen seal and does not
declare `PRE_FROZEN_SEAL = PASS`.
