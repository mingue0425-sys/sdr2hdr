#!/usr/bin/env python3
"""Validate the no-hash, no-quality LIVE31 partial qualification artifact."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_PENDING = {
    "0_Balance_Forest",
    "5_Conversation_Bed",
    "8_Drawing",
    "12_Guitar_Tripod",
    "15_Knitting_Total",
    "16_Night_Biking",
    "19_Parcours",
    "22_Programming_Night",
    "25_River",
    "28_Swan",
    "30_Yoga",
}
EXPECTED_STATUS_COUNTS = {
    "QUALIFIED": 20,
    "QUALIFIED_WITH_DOCUMENTED_VARIANCE": 0,
    "NEEDS_ALIGNMENT_CHECK": 0,
    "METADATA_CONFLICT": 0,
    "STRUCTURAL_MISMATCH": 0,
    "UNSUPPORTED_FORMAT": 0,
    "CORRUPT_OR_UNREADABLE": 0,
    "NOT_QUALIFIED": 0,
}


def assert_no_local_path_leakage(value: object, path: str = "artifact") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"absolutePath", "approvedDevelopmentRoot", "inputManifest", "inputProvenanceArtifact"}:
                fail(f"absolute path field remains: {path}.{key}")
            assert_no_local_path_leakage(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_no_local_path_leakage(child, f"{path}[{index}]")
    elif isinstance(value, str):
        if value.startswith("/Volumes/"):
            fail(f"absolute local path remains: {path}")


def fail(message: str) -> None:
    raise SystemExit(f"partial qualification verification failed: {message}")


def main() -> int:
    path = Path("results/live31-partial-media-qualification-v1.json")
    artifact = json.loads(path.read_text())
    assert_no_local_path_leakage(artifact)
    if artifact["artifactKind"] != "LIVE31_PARTIAL_MEDIA_QUALIFICATION":
        fail("wrong artifact kind")
    if artifact["qualificationVersion"] != "live31-partial-media-qualification-v1":
        fail("wrong qualification version")
    if artifact["searchDefinitionHashV4"] != "bdbf705973fa43f92ab60435bfa04dc1656fdf52c4a8687070d1185b30c809fc":
        fail("V4 search identity drift")
    if artifact["searchDefinitionHashV4Status"] != "AUDIT_INVALIDATED":
        fail("V4 search identity must remain audit-invalidated")
    if artifact["searchDefinitionHashV5"] != "6ae84a8a245858c2328bfe2c80811f12cdd1375e86109ec2f83d4bd3a6cdb43e":
        fail("V5 search identity drift")
    if artifact["searchDefinitionHashV5Status"] != "CURRENT":
        fail("V5 search identity must be current")
    if artifact["qualificationDisposition"] != "READY_FOR_PARTIAL_CORPUS_SEAL":
        fail("qualification disposition")
    if artifact["exactTemporalStatus"] != "PROVEN":
        fail("exact temporal proof status")
    if artifact["historicalPrereRegistrations"]["V4"] != "AUDIT_INVALIDATED":
        fail("V4 historical status")
    if artifact["scope"] != {
        "acquisitionPending": 11,
        "canonicalContents": 31,
        "contentHashingRun": False,
        "corpusPromotionAllowed": False,
        "downloadedPairs": 20,
        "frozenEvaluationRun": False,
        "objectiveEvaluations": 0,
        "protectedDataAccessed": False,
        "qualityMetricsRun": False,
        "tuneRun": False,
        "validationRun": False,
    }:
        fail("scope is not the no-data qualification scope")

    pairs = artifact["downloadedPairs"]
    if len(pairs) != 20:
        fail("downloaded pair count")
    if len({pair["sourceMasterId"] for pair in pairs}) != 20:
        fail("sourceMasterId uniqueness")
    if artifact["summary"]["statusCounts"] != EXPECTED_STATUS_COUNTS:
        fail("status counts")
    if artifact["summary"]["exactDownloadedPairsResolved"] != 20:
        fail("exact path resolution")
    if artifact["summary"]["eligibleIndependentFamilies"] != 20:
        fail("promotion-eligible family count")
    if artifact["summary"]["exactTemporalMatches"] != 20:
        fail("exact temporal match count")
    if artifact["summary"]["structuralDecodeFailureCount"] != 0:
        fail("structural decode failure")

    for pair in pairs:
        if pair["status"] != "QUALIFIED":
            fail(f"unexpected pair status: {pair['canonicalLocalName']}")
        for role in ("sdr", "hdr10"):
            asset = pair[role]
            if not asset["regularFile"] or asset["symlink"]:
                fail(f"filesystem safety: {pair['canonicalLocalName']} {role}")
            if not asset["structuralDecode"]["allSuccessful"]:
                fail(f"decode probe: {pair['canonicalLocalName']} {role}")
            if asset["normalizedMetadata"]["width"] != 3840 or asset["normalizedMetadata"]["height"] != 2160:
                fail(f"resolution: {pair['canonicalLocalName']} {role}")
            pts = asset["ptsStructure"]
            if pts.get("presentationSequenceSource") != "EXACT_DECODED_FRAME_ORDER_WITH_ORIGINAL_SEQUENCE_RETAINED":
                fail(f"original presentation sequence source: {pair['canonicalLocalName']} {role}")
            if pts.get("originalPresentationTimestamps") != pts.get("presentationTimestamps"):
                fail(f"presentation sequence was rewritten: {pair['canonicalLocalName']} {role}")
        if pair["compatibility"]["resolution"] != "EXACT_MATCH":
            fail(f"pair resolution: {pair['canonicalLocalName']}")
        if pair["compatibility"]["fps"]["status"] != "EXACT_MATCH":
            fail(f"pair fps: {pair['canonicalLocalName']}")
        if pair["compatibility"]["pts"] != "EXACT_TEMPORAL_MATCH":
            fail(f"pair exact temporal status: {pair['canonicalLocalName']}")
        if not pair["compatibility"]["temporalEvidence"]["sameNormalizedPresentationTimeline"]:
            fail(f"pair normalized timeline: {pair['canonicalLocalName']}")
        for field in ("declaredSDRContentSHA256", "declaredHDRContentSHA256"):
            value = pair["pairProvenance"][field]
            if not isinstance(value, str) or len(value) != 64 or value != value.lower():
                fail(f"declared acquisition hash: {pair['canonicalLocalName']} {field}")
        if pair["pairProvenance"]["declaredHashVerificationStatus"] != "NOT_RECOMPUTED":
            fail(f"declared hash status: {pair['canonicalLocalName']}")

    inputs = artifact.get("inputProvenance")
    if not isinstance(inputs, dict):
        fail("qualification input provenance missing")
    for key in (
        "acquisitionManifestSHA256",
        "live31ProvenanceArtifactSHA256",
        "preregistrationArtifactSHA256",
    ):
        value = inputs.get(key)
        if not isinstance(value, str) or len(value) != 64 or value != value.lower():
            fail(f"qualification input SHA-256: {key}")
    if inputs.get("preregistrationArtifactPath") != "results/calibration-rebase-preregistration-v5.json":
        fail("qualification must bind the V5 preregistration artifact")
    if inputs.get("preregistrationArtifactStatus") != "CURRENT":
        fail("qualification input V5 status")
    encoded = json.dumps(artifact, sort_keys=True)
    # Acquisition-declared hashes are retained under explicit declared fields;
    # no computed media content hash may appear in this artifact.
    if "contentSHA256" in encoded:
        fail("computed media content hash appears in qualification artifact")

    pending = artifact["acquisitionPending"]
    if {item["canonicalLocalName"] for item in pending} != EXPECTED_PENDING:
        fail("acquisition-pending set")
    if any(item["status"] != "ACQUISITION_PENDING" for item in pending):
        fail("pending status")

    print("LIVE31 partial qualification artifact: PASS")
    print("downloaded pairs: 20")
    print("qualified evidence pairs: 20")
    print("qualification disposition: READY_FOR_PARTIAL_CORPUS_SEAL")
    print("exact temporal proof: PROVEN")
    print("promotion-eligible families: 20")
    print("acquisition pending: 11")
    print("content SHA-256 hashing: NOT RUN")
    print("quality/objective evaluation: NOT RUN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
