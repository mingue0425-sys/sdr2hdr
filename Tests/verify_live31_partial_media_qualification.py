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


def fail(message: str) -> None:
    raise SystemExit(f"partial qualification verification failed: {message}")


def main() -> int:
    path = Path("results/live31-partial-media-qualification-v1.json")
    artifact = json.loads(path.read_text())
    if artifact["artifactKind"] != "LIVE31_PARTIAL_MEDIA_QUALIFICATION":
        fail("wrong artifact kind")
    if artifact["qualificationVersion"] != "live31-partial-media-qualification-v1":
        fail("wrong qualification version")
    if artifact["searchDefinitionHashV4"] != "bdbf705973fa43f92ab60435bfa04dc1656fdf52c4a8687070d1185b30c809fc":
        fail("V4 search identity drift")
    if artifact["searchDefinitionHashV4Status"] != "AUDIT_INVALIDATED":
        fail("V4 search identity must remain audit-invalidated")
    if artifact["qualificationDisposition"] != "REGENERATE_REQUIRED":
        fail("qualification disposition")
    if artifact["exactTemporalStatus"] != "NOT_PROVEN":
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
    if artifact["summary"]["eligibleIndependentFamilies"] != 0:
        fail("promotion-eligible family count")
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
        if pair["compatibility"]["resolution"] != "EXACT_MATCH":
            fail(f"pair resolution: {pair['canonicalLocalName']}")
        if pair["compatibility"]["fps"]["status"] != "EXACT_MATCH":
            fail(f"pair fps: {pair['canonicalLocalName']}")
        if pair["compatibility"]["pts"] != "NOT_PROVEN":
            fail(f"pair exact temporal status: {pair['canonicalLocalName']}")

    pending = artifact["acquisitionPending"]
    if {item["canonicalLocalName"] for item in pending} != EXPECTED_PENDING:
        fail("acquisition-pending set")
    if any(item["status"] != "ACQUISITION_PENDING" for item in pending):
        fail("pending status")

    print("LIVE31 partial qualification artifact: PASS")
    print("downloaded pairs: 20")
    print("qualified evidence pairs: 20")
    print("qualification disposition: REGENERATE_REQUIRED")
    print("exact temporal proof: NOT_PROVEN")
    print("promotion-eligible families: 0")
    print("acquisition pending: 11")
    print("content SHA-256 hashing: NOT RUN")
    print("quality/objective evaluation: NOT RUN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
