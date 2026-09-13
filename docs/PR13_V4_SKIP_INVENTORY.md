# PR #13 — V4 test skip inventory

Debug and Release both ran the same discovered test set:

```text
381 tests, 17 skipped, 0 failures
```

The skip sets are identical. These are test-environment skips, not
calibration evidence. In particular, the real LIVE discovery, real V6 plan
materialization, and actual corpus execution paths remain unexercised until a
later media phase.

| # | Test | Reason | Covered elsewhere | Required before media qualification |
| ---: | --- | --- | --- | --- |
| 1 | `CalibrationTests/testFFmpegHLGP010ReferenceDecodeIsFinite` | `HDR_CALIBRATION_DATA_TESTS=1` and the large local fixture are not enabled | synthetic P010/transfer and production-path tests | Yes |
| 2 | `CalibrationTests/testFFmpegProxyNV12ReachesHDRCoreWithoutGPUFault` | `HDR_CALIBRATION_DATA_TESTS=1` and the large local fixture are not enabled | synthetic NV12/P010 production tests | Yes |
| 3 | `CalibrationTests/testLocalLiveDiscoveryFindsBalancedHDR10Pairs` | local LIVE paired media directories are absent | no real discovery coverage | Yes |
| 4 | `CalibrationTests/testV6RealLive9PlanMaterializationMatchesPreflightExactly` | real Tune `live_9` media is unavailable | prepared-plan structural/causal tests only | Yes |
| 5 | `ExternalRealMediaRegressionTests/testExternalDevelopmentCorpusRunsWhenConfigured` | `HDR_REAL_MEDIA_ROOT` is not set | no external-media execution | Yes |
| 6 | `ExternalRealMediaRegressionTests/testExternalMediaMetadataCanBeInspected` | external root and `external-manifest.json` are not populated | metadata unit tests | Yes |
| 7 | `ExternalRealMediaRegressionTests/testExternalValidationCorpusRunsWhenConfigured` | `HDR_REAL_MEDIA_ROOT` is not set | no external-media execution | Yes |
| 8 | `RealMediaIntegrationTests/testAutomaticH264EightBitSelectsNV12AndProcesses` | `HDR_AUTOMATIC_H264_FIXTURE` is not set | decode precision resolver tests | Yes |
| 9 | `RealMediaIntegrationTests/testAutomaticHEVCEightBitSelectsNV12AndProcesses` | `HDR_AUTOMATIC_HEVC8_FIXTURE` is not set | decode precision resolver tests | Yes |
| 10 | `RealMediaIntegrationTests/testAutomaticHEVCMain10SelectsP010AndProcesses` | `HDR_AUTOMATIC_MAIN10_FIXTURE` is not set | P010 format and policy tests | Yes |
| 11 | `RealMediaIntegrationTests/testGeneratedFixtureRunsThroughProductionNearestPath` | `HDR_SELF_CONTAINED_FIXTURE` is not set | synthetic production nearest-path tests | Yes |
| 12 | `RealMediaIntegrationTests/testGeneratedFixtureRunsThroughSitingAwareCandidate` | `HDR_SELF_CONTAINED_FIXTURE` is not set | synthetic siting tests | Yes |
| 13 | `RealMediaIntegrationTests/testGeneratedP010FixtureRunsThroughProductionNearestPath` | `HDR_P010_SELF_CONTAINED_FIXTURE` is not set | synthetic P010 production tests | Yes |
| 14 | `RealMediaIntegrationTests/testGeneratedP010FixtureRunsThroughSitingAwareCandidate` | `HDR_P010_SELF_CONTAINED_FIXTURE` is not set | synthetic P010 siting tests | Yes |
| 15 | `RealMediaMultiFlightTests/testDeterministicMatrixRunsWithTwoAndThreeFlights` | `HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR` is not set | deterministic ordering and command-buffer tests | Yes |
| 16 | `RealMediaRegressionTests/testManifestDrivenRegressionMatrixRunsBothModes` | `HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR` is not set | manifest/schema and synthetic regression tests | Yes |
| 17 | `V4SemanticClosureTests/testV4SemanticOnlyRebaseDoesNotEvaluateMedia` | intentional guard: media qualification/hash/decode, Tune, Validation, Frozen evaluation and objective evaluation are disabled in this task | V4 verify-only binding and artifact regeneration | No; this skip is required by the task boundary |

The first 16 skips are expected to be revisited in the later media phase. The
17th is intentionally never enabled during this semantic-only rebase.
