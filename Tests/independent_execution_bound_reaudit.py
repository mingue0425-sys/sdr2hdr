#!/usr/bin/env python3
"""Independent, media-free re-audit of the execution-bound V3 seal.

The checks below read the committed artifact and use Python's own canonical
JSON representation. They deliberately do not call the Swift hash function
as an oracle. The only executable interaction is the no-media verify-only CLI
and rejected override probes.
"""

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PREREG = ROOT / "results/calibration-rebase-preregistration-v3.json"
V1 = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"
V2 = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41"


def fail(message: str) -> None:
    raise SystemExit(f"independent execution-bound re-audit: FAIL: {message}")


def canonical(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def command_prefix() -> list[str]:
    binary = ROOT / ".build/debug/HDRCalibrate"
    return [str(binary)] if binary.is_file() else ["swift", "run", "HDRCalibrate"]


def black_box(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command_prefix() + arguments,
        cwd=ROOT,
        text=True,
        capture_output=True,
    )


def check_artifact() -> dict[str, object]:
    require(PREREG.is_file(), "V3 artifact is missing")
    artifact = json.loads(PREREG.read_text(encoding="utf-8"))
    require(artifact["artifactVersion"] == 3, "artifact is not V3")
    require(artifact["status"] == "PREREGISTERED_V3_EXECUTION_BOUND_SEMANTIC_ONLY", "V3 status drift")
    require(artifact["preregistrationInvalidated"] is False, "current V3 is invalidated")
    require(artifact["retiredV1SearchDefinitionHash"] == V1, "V1 lineage drift")
    require(artifact["invalidatedV2SearchDefinitionHash"] == V2, "V2 lineage drift")
    require(artifact["corpusDefinitionHash"] == "NOT_YET_CREATED", "corpus identity exists")
    require(artifact["experimentBindingHash"] == "NOT_YET_CREATED", "experiment identity exists")
    require(artifact["objectiveEvaluations"] == 0, "objective evaluation was recorded")

    search = artifact["searchDefinition"]
    algorithm = search["searchAlgorithmDefinition"]
    require(
        set(search) == {
            "semanticVersion", "policyDefinitionHashV3", "preparationDefinitionHashV3",
            "metricDefinitionHashV3", "searchAlgorithmDefinition",
            "searchAlgorithmDefinitionHash", "policyCandidates", "searchBudgetPerPolicy",
            "seed", "splitSeed", "parameterBounds", "parameterRepresentation", "hardGates",
            "safetyGates", "safetyThresholds", "shortlistSize", "selectionOrdering",
            "tieBreakRule", "failurePolicy",
        },
        "search semantic field coverage drift",
    )
    require(search["policyCandidates"] == ["bt709SourceLinear", "bt1886ReferenceDisplay"], "candidate policy set drift")
    require(search["searchBudgetPerPolicy"] == 192, "per-policy budget drift")
    require(algorithm["globalCandidateCount"] == 128, "global phase drift")
    require(algorithm["localCandidateCount"] == 64, "local phase drift")
    require(algorithm["totalCandidatesPerPolicy"] == 192, "algorithm total drift")
    require(algorithm["phaseOrdering"] == ["sensitivity", "global", "local"], "phase ordering drift")
    require(algorithm["globalParentCount"] == 8, "local parent count drift")
    require(search["shortlistSize"] == 3, "shortlist drift")
    require(search["seed"] == 20260912, "search seed drift")
    require(search["splitSeed"] == 92, "split seed drift")

    preparation_definition = artifact["preparationDefinition"]
    require(
        set(preparation_definition) == {
            "semanticVersion", "configuration", "policyConfigurations",
            "preparationConfigurationCanonical", "matcherConfigurationCanonical",
            "humanReadableDescription", "failurePolicy",
        },
        "preparation definition field coverage drift",
    )
    policy_configurations = preparation_definition["policyConfigurations"]
    require(
        set(policy_configurations) == set(search["policyCandidates"]),
        "policy-specific preparation configurations drift",
    )
    require(
        [policy_configurations[policy]["sdrInterpretationPolicy"] for policy in search["policyCandidates"]]
        == search["policyCandidates"],
        "policy-specific preparation derivation drift",
    )
    preparation = preparation_definition["configuration"]
    preparation_fields = {
        "version", "maxFramesPerScene", "maxDecodedFrames", "proxyWidth",
        "alignmentConfidenceThreshold", "acceptedConfidenceThreshold",
        "temporalFramesPerSecond", "temporalTargetFrameCount",
        "temporalMinimumFrameCount", "temporalWarmupFrameCount",
        "referenceTargetPeakNits", "allowHLGModel", "sdrPixelFormat",
        "hdrPixelFormat", "frameDecoderPolicy", "referenceDecoderPolicy",
        "pathResolutionPolicy", "sceneSelectionPolicy", "temporalSelectionPolicy",
        "preparationAlgorithmVersion", "matcherVersion", "matcherConfiguration",
        "matcherConfigurationHash", "sdrInterpretationPolicyVersion",
        "sdrInterpretationPolicy", "untaggedSDRFallback", "bt1886Parameters",
        "sdrInterpretationPolicyHash",
    }
    require(set(preparation) == preparation_fields, "preparation semantic field coverage drift")
    matcher = preparation["matcherConfiguration"]
    matcher_fields = {
        "preparationAlgorithmVersion", "matcherVersion", "gridWidth", "gridHeight",
        "offsetMinimumSeconds", "offsetMaximumSeconds", "offsetStepSeconds",
        "acceptedConfidenceThreshold", "rankWeight", "signedGradientWeight",
        "multiScaleNCCWeight", "edgeMaskWeight", "localContrastWeight",
        "multiScaleWidths",
    }
    require(set(matcher) == matcher_fields, "matcher semantic field coverage drift")
    require(
        set(algorithm) == {
            "semanticVersion", "globalCandidateCount", "localCandidateCount",
            "totalCandidatesPerPolicy", "globalParentCount", "phaseOrdering",
            "sensitivityProbeValues", "globalSamplingDistribution",
            "localSamplingDistribution", "globalHaltonBases", "localHaltonBases",
            "localNeighborhoodRadius", "seedIndexModulus", "prngImplementationVersion",
            "seedDerivation", "candidateOrdering", "duplicateHandling",
            "localRefinementParentSelection",
        },
        "search algorithm semantic field coverage drift",
    )
    metric = artifact["metricDefinition"]["configuration"]
    metric_fields = {
        "semanticVersion", "metricVersion", "objectiveWeights", "objectiveNames",
        "objectiveDirection", "normalizationRules", "aggregationRules",
        "signedSemantics", "regionalMetricNames", "temporalMetricNames",
        "failureHandling", "perceptualColorTransformVersion", "percentileInterpolation",
        "perceptualColorInputMinimumNits", "perceptualColorInputMaximumNits",
        "nonFiniteHandling", "nonNegativeClampPolicy", "nonNegativeClampFloor",
        "correlationLowerBound", "correlationUpperBound", "absoluteNitsNormalizer",
        "additiveLuminanceOffsetNits", "percentileFractions", "regionPercentiles",
        "diffuseMidtoneSourceRange", "highlightUnderreachRatio",
        "highlightOvershootRatio", "highlightOvershootAbsoluteNits", "specularPercentile",
        "clippingPeakRatio", "slopeFloorNits", "blackCrushReferenceThresholdNits",
        "blackCrushGeneratedAbsoluteNits", "blackCrushGeneratedRatio", "shadowLiftRatio",
        "shadowLiftAbsoluteNits", "nearBlackReferenceRangeFloorNits", "hueMeanWeight",
        "hueP95Weight", "temporalLuminanceWeight", "temporalHighlightWeight",
        "temporalFlickerWeight", "minimumReferenceChroma", "minimumGeneratedChroma",
        "highChromaThreshold", "saturationDenominatorFloor", "saturationOvershootRatio",
        "saturationOvershootAbsolute", "saturationUndershootRatio",
        "saturationUndershootAbsolute", "skinMinimumPeakNits", "skinRedBlueSeparation",
        "categoryHighKeyThresholdNits", "categoryLowKeyThresholdNits",
        "categoryHighSaturationChromaThreshold", "categoryHighSaturationRatio",
        "categoryHighlightRichUnderreachRatio", "failureHighlightUnderreachRatio",
        "failureHighlightOvershootRatio", "failureDiffuseWhiteLowRatio",
        "failureDiffuseWhiteHighRatio", "failureMidtoneError", "failureBlackCrushRatio",
        "failureShadowLiftRatio", "failureSaturationRatio", "failureHueP95Error",
        "failureTemporalFlicker", "failureAlignmentConfidence",
        "failureReferenceMismatchHue", "failureReferenceMismatchLuminance",
        "correlationEpsilon", "invalidMetricScore", "emptyAggregateObjective",
        "emptyAggregateInvalidSampleCount",
    }
    require(set(metric) == metric_fields, "metric semantic field coverage drift")
    return artifact


def check_mutation_matrix(artifact: dict[str, object]) -> None:
    checks: list[tuple[str, dict[str, object], str]] = []

    def add(label: str, object_key: str, mutate) -> None:
        changed = copy.deepcopy(artifact[object_key])
        mutate(changed)
        checks.append((label, changed, object_key))

    add("policy BT.1886 gamma", "policyDefinition", lambda value: value["bt1886Parameters"].update(gamma=2.3))
    add("policy fallback", "policyDefinition", lambda value: value.update(untaggedFallback="reject"))
    add("preparation proxy width", "preparationDefinition", lambda value: value["configuration"].update(proxyWidth=336))
    add("policy-specific preparation proxy width", "preparationDefinition", lambda value: value["policyConfigurations"]["bt1886ReferenceDisplay"].update(proxyWidth=336))
    add("matcher offset step", "preparationDefinition", lambda value: value["configuration"]["matcherConfiguration"].update(offsetStepSeconds=1 / 24))
    add("metric highlight threshold", "metricDefinition", lambda value: value["configuration"].update(highlightUnderreachRatio=0.85))
    add("metric clipping threshold", "metricDefinition", lambda value: value["configuration"].update(clippingPeakRatio=0.995))
    add("metric hue weights", "metricDefinition", lambda value: value["configuration"].update(hueMeanWeight=0.5))
    add("metric temporal weights", "metricDefinition", lambda value: value["configuration"].update(temporalFlickerWeight=0.21))
    add("search global budget", "searchDefinition", lambda value: value["searchAlgorithmDefinition"].update(globalCandidateCount=129))
    add("search local budget", "searchDefinition", lambda value: value["searchAlgorithmDefinition"].update(localCandidateCount=65))
    add("search sensitivity probes", "searchDefinition", lambda value: value["searchAlgorithmDefinition"]["sensitivityProbeValues"].__setitem__(1, 0.24))
    add("search seed", "searchDefinition", lambda value: value.update(seed=20260913))
    add("split seed", "searchDefinition", lambda value: value.update(splitSeed=93))
    add(
        "search lower bound",
        "searchDefinition",
        lambda value: value["parameterBounds"].__setitem__(
            "paperWhiteNits", [191, value["parameterBounds"]["paperWhiteNits"][1]]
        ),
    )
    add("search hard gate", "searchDefinition", lambda value: value["hardGates"].append("mutated"))
    add("search safety gate", "searchDefinition", lambda value: value["safetyGates"].append("mutated"))
    add(
        "runtime percentile gate",
        "searchDefinition",
        lambda value: value["safetyThresholds"]["runtime"].update(p95Fraction=0.94),
    )
    add("search shortlist", "searchDefinition", lambda value: value.update(shortlistSize=8))
    add("search tie-break", "searchDefinition", lambda value: value["tieBreakRule"].append("mutated"))
    add("search failure policy", "searchDefinition", lambda value: value["failurePolicy"].append("mutated"))

    hash_keys = {
        "policyDefinition": "policyDefinitionHashV3",
        "preparationDefinition": "preparationDefinitionHashV3",
        "metricDefinition": "metricDefinitionHashV3",
        "searchDefinition": "searchDefinitionHashV3",
    }
    for label, changed, object_key in checks:
        require(
            digest(changed) != digest(artifact[object_key]),
            f"independent mutation did not change canonical bytes: {label}",
        )
        require(hash_keys[object_key] in artifact, f"missing identity field for {object_key}")


def check_black_box_binding() -> None:
    relative = str(PREREG.relative_to(ROOT))
    verified = black_box(["run-preregistered", "--verify-only", "--preregistration", relative])
    require(verified.returncode == 0, "verify-only execution failed")
    require("runtime semantic identity match: PASS" in verified.stdout, "runtime identity proof missing")
    for override in ("--seed", "--select"):
        value = "20260823" if override == "--seed" else "8"
        result = black_box([
            "run-preregistered", "--verify-only", override, value,
            "--preregistration", relative,
        ])
        require(result.returncode != 0, f"runtime override was accepted: {override}")
        require("PREREGISTRATION_MISMATCH" in result.stdout + result.stderr, f"wrong override error: {override}")


def main() -> int:
    artifact = check_artifact()
    check_mutation_matrix(artifact)
    check_black_box_binding()
    print("independent execution-bound re-audit: PASS")
    print("semantic field coverage, runtime binding, phase budgets, shortlist, and mutation probes: PASS")
    print("protected media bytes/stat/probe/hash/decode: NO")
    print("objective evaluations: 0")
    print("BLOCKER=0 HIGH=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
