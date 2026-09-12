# SDR2HDR engineering audit — 2026-09-11–12

## 1. 결론과 범위

**Verdict: EXPERIMENTAL.** 재사용 가능한 GPU 코어와 상당한 회귀 테스트 기반은 갖췄다.
그러나 현재의 calibration 점수만으로 색 재현 정확도, 독립 holdout 일반화 성능,
실제 디스플레이의 HDR 품질, 지속적인 4K 재생 안정성을 증명할 수는 없다.

기준 checkout은 `main`, `064d9a3`이며 조사 시작 시 worktree는 깨끗했다.
이 문서에 기술한 수정은 그 위의 미커밋 변경이다. commit/push는 하지 않았다.
환경은 macOS 26.6.2 (25G83), Swift 6.3.3, Metal이 보고한 GPU `Apple M2`다.
주요 runtime, player, calibration, verification, benchmark 경로를 추적하고
합성 수치·실제 압축 파일·Metal 실행으로 교차 검증했다. 모든 가능한 입력과
하드웨어를 검증한 것은 아니며, 물리 휘도/색도 계측은 수행하지 않았다.

이번 감사에서는 실제 Frozen/Virgin objective를 실행하지 않았다. 기존 결과와
실험 데이터를 덮어쓰지 않았고, one-use 테스트는 임시 디렉터리와 가짜 SHA-256
식별자만 사용했다. 새 calibration 후보를 선택하거나 production preset을 바꾸지 않았다.

## 2. 코드 기준 architecture

### Runtime / display

`HDRCore` 자체는 디코더나 비디오 exporter가 아니다. NV12 8-bit, CoreVideo
P010 10-bit MSB-aligned bi-planar, BGRA8 입력을 GPU의 RGBA16Float 텍스처로 변환한다.
primaries, transfer, YCbCr matrix는 별도로 해석한다. 현재 RGB 입력 primaries는
BT.709만 지원하며, BT.601/709/2020 YCbCr matrix 지원과 혼동하면 안 된다.
PQ/HLG 입력을 HDRCore의 SDR 입력으로 자동 처리하지 않는다.

실제 변환 순서는 YCbCr range/matrix 복원, nonlinear RGB의 nominal-range 제한,
inverse BT.709/sRGB/gamma/linear transfer, linear BT.709 luminance 분석,
tone expansion과 shadow 처리, 공통 luminance gain, highlight desaturation,
linear BT.709→BT.2020 matrix, gamut/range compression, EDR 또는 PQ 출력이다.
이는 SDR에 없는 원래 highlight 정보를 복원하는 알고리즘이 아니라,
관측된 SDR 신호를 기반으로 한 파라미터화된 tone expansion이다.

기본 preset은 `calibratedV4`, curve는 `sceneRelativeV4`다. paper white는 190 nits,
peak는 약 1008.6863 nits, content headroom은 약 5.308875다. nearest chroma가 기본이며
siting-aware bilinear와 V6/V6.2 실험 preset은 별도 선택 경로다. 16×9 sparse proxy와
64-bin histogram 기반의 causal temporal estimator를 사용한다.

`HDRPlayer`는 AVPlayer를 오디오/시간 기준으로 유지하고 VideoOutput에서 PTS에 맞는
CVPixelBuffer를 받는다. source precision resolver가 NV12/P010 요청을 결정한다.
`HDRProcessor`와 presentation은 같은 command buffer에 인코딩할 수 있다.
프레임이 없을 때의 재표시, timestamp 선택, seek 시 temporal history 초기화가 존재한다.
CAMetalDisplayLink와 display headroom 상태는 `HDRMetalView`가 관리한다.

EDR 활성 시 layer는 extended-linear BT.2020, rgba16Float, 직접 tone mapping을 사용한다.
현재 display headroom으로 highlight를 압축하고 `edrMetadata`는 nil로 둔다.
SDR fallback은 neutral expansion과 BT.2020→linear sRGB 변환을 사용한다.
EDR의 1.0은 시스템의 reference white에 대한 상대값이므로, configuration의
`paperWhiteNits=190`이 실제 화면의 190 cd/m² 측정을 의미하지 않는다.
[Apple EDR 설명](https://developer.apple.com/videos/play/wwdc2021/10161/),
[직접 tone mapping 정책](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping).

### Calibration

manifest/lock과 source 식별, metadata probe, pairing/alignment를 거쳐 proxy frame과
scene/temporal window를 준비한다. nonlinear matching descriptor는 64×36이고,
objective/reference grid는 보통 32×18이다. HDR reference는 PQ absolute nits 또는
HLG inverse OETF + luminance-coupled OOTF로 해석한다. HLG는 지정 peak를 사용하는 모델이며
원본 mastering 환경의 실측 복원이 아니다.

V4/V6 경로는 Tune search, Validation shortlist 선택, pre-Frozen gates,
candidate freeze, Frozen materialization/evaluation 순서다. PreparedEvaluationPlan은
입력 hash, 순서, frame/PTS 선택, preparation configuration과 자체 digest를 묶는다.
수정 후 materialization 전에 repository-local consumption ledger를 추가했다.
V1/V2/V3 등 역사적 evaluator도 여전히 별도로 존재한다.

## 3. 확인된 결함과 수정

| 중요도 | 확인된 문제 | 근거 / 변경 |
|---|---|---|
| High | calibration source grid의 domain 불일치 | `PreparedMatch`/temporal frame에 encoded Y′를 넣었지만 diffuse-midtone gate는 linear 0.15…0.45를 가정했다. `Evaluation.swift` 네 준비 경로를 metadata-aware linear luminance로 통일했다. |
| High | offline sampler가 항상 inverse BT.709 사용 | sRGB code 128의 기대 luminance 0.2158605 대신 0.2614815가 나왔다. `OfflinePixelSampler.linearLumaGrid`가 HDRCore와 같은 metadata resolver를 사용한다. |
| High | FFmpeg raw proxy의 transfer/matrix/range 손실 | 기존 코드가 모든 SDR을 709, 모든 P010을 HLG로 표기했다. 원본 색 태그를 보존하고 실제 swscale output을 video-range로 정규화했다. 없는 태그는 임의로 만들지 않는다. |
| High | signed calibration 진단값의 음수 제거 | reference=100, generated=50인 midtone의 log error는 ln(51/101)=-0.683294884인데 0이 됐다. `V2Metrics`의 region diagnostic은 부호를 보존한다. objective의 비음수 error 처리는 유지했다. |
| High | Frozen one-use guard의 process-local 수명 | 기존 `V4FrozenAccessGuard`만으로는 재실행/다른 output 경로를 막지 못한다. V4/V6 진입부에 durable per-asset exclusive claim을 추가했다. 아래 한계 때문에 전역 one-use 보장은 아니다. |
| High | Metal 수정에도 verification cache 재사용 | cache fingerprint가 `.swift`만 포함했다. fake shader 변경으로 동일 key가 나오는 실패를 재현하고 `.metal`도 포함시켰다. |
| High | cache hit이 현재 media bytes 검증을 생략 | 코드/control-file key는 영상 내용의 불변성을 증명하지 못한다. fast/prime에서도 Tune/Validation digest preflight를 실행한다. 실패하는 validator를 cache hit으로 우회하는 테스트를 추가했다. |
| High | shell validator 실패가 후속 성공으로 은폐 | Swift plan verifier가 exit 42여도 PASS 모양 JSON이 있으면 함수가 성공할 수 있었다. `set -e`가 비활성화되는 if/OR 문맥까지 명시적 오류 전파와 회귀 테스트로 보강했다. |
| Medium | core의 near-black 이중 감쇠 | gamma=4, BGRA code=4의 독립 계산은 6.054515e-8. 기존 scalar는 3.665713e-9, GPU는 0이 됐다. gain denominator의 1e-6 floor를 exact-black guard로 바꿨다. GPU는 표현 가능한 half 값 5.9604645e-8을 보존한다. |
| Medium | presentation에서도 near-black 절단 | EDR shader가 luminance≤1e-6을 0으로 만들었다. 1.1920929e-7과 9.536743e-7 두 neutral half 샘플로 재현했다. 이제 exact black만 나눗셈에서 제외한다. |
| Medium | resolution 변경 시 temporal buffer 누적 | 20회 해상도 변경 후 output texture는 3개인데 estimator buffer는 20개였다. 별도 lease-ID dictionary를 제거하고 buffer 수명을 output slot에 묶었다. |
| Medium | metadata Double→Float 변환 검증 부족 | 유한한 양수 Double gamma가 Float에서 infinity 또는 0이 될 수 있었다. 변환 후 재검증한다. plain CVPixelBuffer에서 재현했다. IOSurface gamma의 별도 제한과 구분해야 한다. |
| Medium | benchmark가 wall-clock을 GPU 시간으로 대체 | GPU timestamp가 없으면 실패하도록 바꿨다. CPU submission에 command 생성/commit을 포함하고 wait는 제외한다. GPU worst와 측정 범위를 출력하며 encoder/input 초기화 실패도 정상 결과로 보고하지 않는다. |

주요 수정 위치: [HDRProcessor](../Sources/HDRCore/HDRProcessor.swift),
[색 metadata](../Sources/HDRCore/ColorManagement.swift),
[core shader](../Sources/HDRCore/Shaders/SDRToHDR.metal),
[presentation shader](../Sources/HDRPlayer/Shaders/Presentation.metal),
[FrameIO](../Sources/HDRCalibration/FrameIO.swift),
[Evaluation](../Sources/HDRCalibration/Evaluation.swift),
[V2Metrics](../Sources/HDRCalibration/V2Metrics.swift),
[ledger](../Sources/HDRCalibration/FrozenConsumptionLedger.swift),
[verification script](../RUN_MACOS_VERIFY.sh).

FFmpeg 수정은 metadata label만 바꾼 것이 아니다. 명시적인 input/output matrix와
output video range를 scale filter에 전달한다. 이는 FFmpeg가 구분하는 sample-range
변환과 일치한다. [FFmpeg scale 문서](https://ffmpeg.org/ffmpeg-filters.html#scale-1).
CoreMedia metadata가 부족하면 기존 V4 ffprobe 경로에서 명시적인 태그를 얻는다.
gamma를 포함한 SDR metadata는 최종적으로 HDRCore의 엄격한 policy로 검증한다.
홀수 proxy width와 잘못된 raw frame 크기/plane/lock도 거부한다.

재현 fixture도 검사했다. 이 환경에서는 FFmpeg 출력 색 옵션만 설정한 초기 fixture에
primaries/transfer가 빠졌다. 최종 테스트는 `setparams`와 ffprobe assertion으로
실제 sRGB/PQ/HLG·full-range 표기를 확인한다. 검증된 fixture에 이전 range/tag 동작만
되돌리는 controlled mutation에서 sRGB transfer 오표기, PQ→HLG label,
중간 회색 0.5019608→0.5114155 오해석을 확인했다. 이 임시 mutation은 제거했다.
초기 fixture에서 관찰한 0.5205479를 최종 tagged-fixture 수치와 혼용하지 않는다.

## 4. 호환성 및 실험 의미의 변경

production preset의 수치는 바꾸지 않았다. 다만 source luminance domain 수정은
signed 진단뿐 아니라 source/generated correlation을 사용하는 structure objective에도
영향을 준다. proxy range/transfer 수정도 reference와 temporal 평가를 바꿀 수 있다.
따라서 기존 점수와 새 점수를 같은 척도의 결과처럼 직접 비교하면 안 된다.

preparation version은 `v6-prepared-evaluation-plan-v5-linear-source-luminance`로 올렸다.
자료구조 schema는 기존 v4를 유지하지만, 이전 preparation policy의 plan은 새 hash와
sidecar를 붙여도 거부한다. 이를 검사하는 기존 loader regression을 확장했다.
기존 artifact를 새 코드의 PASS 증거로 재포장하거나 preset을 재조정하지 않았다.

## 5. 검증 결과와 증거 수준

최종 검증 기록은 아래와 같다. 모든 PASS는 실행 범위 안에서만 의미가 있다.

| 실행 | 결과 / 범위 |
|---|---|
| `swift build -c release` | 성공. 최종 calibration proxy 변경까지 포함한 재빌드. |
| `swift test` | 349 cases, 16 explicit skips, 0 failures. skip을 제외한 333 cases 실행. |
| `swift test -c release` | 349 cases, 16 explicit skips, 0 failures. |
| `python3 Tests/verify_no_frozen_access.py` | PASS, allowlist-only guard. |
| `python3 Tests/verify_no_frozen_access_test.py` | PASS. |
| `bash Tests/verify_script_cache_test.sh` | PASS, shader/content invalidation 및 조건부 호출의 실패 전파 포함. |
| `bash RUN_MACOS_VERIFY.sh self-contained` | PASS, 합성 8-bit/P010 압축 파일의 AVFoundation→core→offscreen presentation 네 경로. |
| 압축 fixture contract | 12종 생성/ffprobe 검증 PASS. CFR/VFR, 24/30/60 fps, full/video range, near-black/chroma/motion 포함. |
| real-media regression matrix | 12종 각각 nearest 및 bilinear, failures=0, skipped=0. |
| multi-flight matrix | 7종×2 modes×depth 2/3 = 28 runs PASS. Metal debug layer 및 native completion observer 활성. |
| automatic decode integration | H.264 8-bit, HEVC 8-bit, HEVC Main10의 선택 및 GPU 처리 3 cases PASS. |
| 새 proxy color integration | 명시적으로 표기된 합성 sRGB/PQ/HLG를 temporal FFmpeg reader로 실행, transfer/range 검사 PASS. |

기본 suite의 16 skips 중 9개 미디어 경로는 별도 fixture 실행으로 보완했다.
나머지는 대형 local calibration fixture, LIVE/Tune 원본, external development/validation
corpus의 부재 또는 미설정에 해당한다. 따라서 외부 실영상의 품질 검증을 완료했다고
주장하지 않는다. `full`/`fast`의 기존 calibration evidence 재생성·승인도 수행하지 않았다.

중간 재실행에서 P010 전용 precision test에 dark-gradient matrix fixture를 대신 넣어
두 assertion이 실패했다(12 levels, 요구 >32). 테스트의 전용 생성 스크립트로 만든
P010 fixture로 다시 실행했다. 이를 runtime precision regression으로 분류하거나
threshold를 낮춰 통과시키지 않았다. 당시 로그는
`/tmp/sdr2hdr-audit-media-fixture-mismatch.log`에 별도로 보존했다.

새 회귀 테스트는 [core](../Tests/HDRCoreTests/AuditRegressionTests.swift),
[presentation](../Tests/HDRPlayerTests/AuditPresentationTests.swift),
[calibration integrity](../Tests/HDRCalibrationTests/AuditIntegrityTests.swift),
[proxy color](../Tests/HDRCalibrationTests/AuditProxyColorTests.swift)에 있다.
PQ에는 encode/decode가 같은 오류를 공유해도 통과할 수 있는 round-trip 외에
100 nits→0.50807842, 1000 nits→0.75182710의 독립 absolute anchors를 추가했다.
이는 PQ가 절대 휘도 기준이라는 BT.2100 정의와 대조한 검사다.
[ITU-R BT.2100](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2100-2-201807-S!!PDF-E.pdf).

로컬 재현 로그: `/tmp/sdr2hdr-audit-final-debug.log`, `-final-release.log`,
`-final-build.log`, `-final-media.log`, `-shell-final.log`, `-proxy-controlled-repro.log`,
`-benchmark-nv12-edr.log`, `-benchmark-p010-edr.log`, `-benchmark-p010-pq.log`,
`-benchmark-presentation.log` (뒤의 각 이름에도 `/tmp/sdr2hdr-audit` 접두사가 붙는다).
미디어 JSON은 `/tmp/sdr2hdr-audit-regression.json`, `/tmp/sdr2hdr-audit-multiflight.json`이다.
이 파일들은 임시 로컬 증거이지 signed/build-attested release artifact가 아니다.

테스트 한계도 확인했다. regression report의 `baseline=db01ba7`은 manifest label이다.
이 실행이 그 revision의 바이너리를 별도로 빌드해서 비교했다는 뜻은 아니다.
nearest와 bilinear는 현재 구현의 두 경로다. 일부 clipping gate는 25–75%까지
허용하는 broad safety gate이고, hard-coded near-black 배열 검사도 있다.
이를 전반적인 화질이나 색 정확도 PASS로 해석해서는 안 된다.

## 6. 색과학 및 runtime에 남은 위험

1. **High — BT.709 input domain 정의.** 현재 inverse camera OETF를 적용한다.
   black=0인 이상적 BT.1886 display EOTF와 다르다. signal 0.5에서 각각 약
   0.2595894와 0.1894646으로, expansion 전부터 약 37% 차이가 난다.
   이것만으로 scene-linear 연구 모델이 틀렸다고 단정하지는 않지만,
   display-mastered SDR의 faithful reproduction과 neutral SDR fallback을 보장하지 못한다.
   input interpretation을 versioned policy로 분리하고 다시 calibration해야 한다.
   [ITU-R BT.1886](https://www.itu.int/dms_pubrec/itu-r/rec/bt/r-rec-bt.1886-0-201103-i!!pdf-e.pdf).
2. **High — proxy temporal fidelity.** FFmpeg reader는 `fps` filter로 재표본화하고
   `start + index/outputFPS`로 timestamp 및 nominal-rate 기반 source index를 만든다.
   이 값은 특히 VFR에서 원본 packet/frame PTS와 동일하다는 증거가 아니다.
   plan 재현성이 원본 시간축의 정확성을 자동 보장하지 않는다. 실제 PTS 보존과
   duplicate/drop provenance가 필요하다.
3. **Medium — sparse statistics와 scheduling 차이.** 고정 16×9 표본은 작은 highlight를
   놓칠 수 있다. offline의 매-frame wait와 실제 여러 in-flight command에서 사용하는
   최신 완료 estimator 상태가 모든 workload에서 같은 지연을 갖는 것은 아니다.
   현재 burst/resource tests는 통과했지만 장시간 장면 전환 품질까지 증명하지 않는다.
4. **Medium — 색/참조 범위.** input RGB 및 HDR reference가 nominal range로 제한된다.
   superwhite/negative RGB 보존을 일반적으로 지원한다고 볼 수 없다. HLG peak와
   viewing environment 모델, proxy scaling/chroma sampling, gamut compression은
   실제 mastering 의도와의 오차를 추가할 수 있다.
5. **미측정 — 물리 presentation.** display 이동, 밝기 조절, ambient light,
   EDR headroom 변화 중의 장시간 frame pacing과 실제 luminance/chromaticity를
   계측하지 않았다. 현재 headroom과 potential headroom을 구분하고 별도로 smoothing하는
   구조는 타당하지만, 코드 검사와 offscreen 값만으로 패널의 출력을 보증할 수 없다.

좋은 기반도 확인했다. CVPixelBuffer/CVMetalTexture와 output lease는 GPU 완료 및
HDRFrame 보유 수명에 연결돼 있다. pool과 temporal state에는 lock, generation,
sequence guard가 있으며 stale completion과 reset을 분리한다. multi-flight 검사에서
depth 2/3의 실제 제출, sequence 진행, 세 output allocation 유지가 확인됐다.
반면 이런 검사는 모든 cancellation, driver, 다른 GPU에서의 무결함 증명은 아니다.

## 7. 성능

release, Apple M2, 3840×2160, 기본 calibrated-v4, warmup 30, measured 300.
아래 네 workload는 서로 동시에 실행하지 않았다. 값의 단위는 ms다.

| workload | GPU p50 | p95 | p99 | worst | CPU submission p50 / p95 / p99 |
|---|---:|---:|---:|---:|---:|
| NV12 → EDR | 1.625 | 1.811 | 1.931 | 2.130 | 0.018 / 0.029 / 0.043 |
| P010 → EDR | 1.920 | 1.994 | 2.211 | 2.449 | 0.028 / 0.085 / 0.106 |
| P010 → PQ | 2.178 | 2.274 | 2.453 | 2.563 | 0.042 / 0.103 / 0.132 |
| offscreen presentation test pattern | 0.616 | 0.744 | 0.849 | 0.914 | 0.014 / 0.034 / 0.045 |

명령은 `./.build/release/HDRBenchmark --width 3840 --height 2160 --frames 300 --warmup 30`에
각각 기본 옵션, `--precision p010`, `--precision p010 --mode PQ`,
`--presentation-only`를 적용했다. 측정 이후의 변경은 calibration-only proxy 및 검증 코드다.

이는 one-command-in-flight의 synthetic workload다. decode, source IO, audio sync,
실제 drawable 대기, display pacing을 포함하지 않는다. presentation-only는 source texture
sampling도 하지 않는다. 따라서 역수를 실제 재생 FPS로 보고하거나 네 값들을 단순 합산해
player latency로 주장하면 안 된다.

수정 전 NV12 GPU p50/p95/p99는 1.652/1.684/1.913 ms였다. 한 번씩의 측정이고
tail 값은 개선되지 않았으므로 유의한 속도 향상을 주장하지 않는다.
CPU 측정 정의도 commit 포함으로 바뀌어 전후 수치를 직접 비교하지 않는다.

4K RGBA16Float output 세 장의 logical memory는 199,065,600 bytes, 약 189.8 MiB다.
입력/출력 bandwidth, full-resolution transform 및 presentation, transfer의 pow 연산이
후속 profiling 대상이다. 그러나 counter/Instruments 측정 없이 GPU가 memory-bound인지
ALU-bound인지 단정할 근거는 없다. 현재 확인된 개선은 해상도 변경 시 buffer 누적 제거와
측정 신뢰성 강화이지, throughput 최적화의 입증이 아니다.

## 8. Calibration / holdout 신뢰성 판단

**현재 calibration은 개발 방향을 잡는 실험 증거로만 제한적으로 신뢰한다.**
명시적인 split, input hash, sealed plan, selected candidate freeze, sequential temporal
평가 등은 유용하다. HLG/PQ를 구분하고 실패한 artifact를 그대로 PASS로 취급하지 않도록
상당한 방어 코드도 있다. 그러나 이번에 source domain과 signed metric의 실제 오류를
확인했으므로 기존 점수는 수정된 구현의 generalization 근거가 아니다.

Validation을 shortlist 선택에 쓰는 것은 설계된 모델 선택이지 그 자체로 leakage는 아니다.
다만 그 Validation은 최종 독립 test set이 아니다. 같은 Validation을 보며 반복적으로
설계·parameter·metric을 바꾼 결과에 대해서는 추가적인 독립 평가가 필요하다.
다른 파일/hash여도 같은 source/scene/alternate encode일 수 있으므로 family-level
독립성을 bytes만으로 증명할 수 없다.

새 `.hdr-frozen-consumption/` ledger는 SHA-256별 `O_EXCL` claim, symlink 거부,
file/directory fsync, partial receipt의 fail-closed 처리를 사용한다.
같은 asset을 다른 역할/plan/candidate로 재사용하거나 여러 프로세스가 경쟁하는
일상적인 실수를 막는다. 8개의 concurrent claim에서 정확히 한 번만 성공하는 테스트,
재실행/빈 receipt/invalid identity 테스트가 통과했다.

그러나 사용자가 ledger를 지우거나 다른 checkout을 쓰거나 재인코딩하거나
역사적 evaluator를 직접 호출하면 우회할 수 있다. 전역적/적대적 one-use boundary나
별도 데이터 custody가 아니다. ledger를 보존해야 하며 실패했다고 지우고 재시도하면 안 된다.

**High residual: source↔binary build provenance.** `V4CodeIdentityPolicy.status`는
실행 파일 hash 존재와 clean worktree를 검사한다. source hash와 executable hash를
각각 기록하는 것은 오래된 binary가 현재 source에서 빌드됐음을 증명하지 못한다.
기존 artifact의 mtime/semantic gate를 통한 prime도 causality를 증명하지 못한다.
OS/toolchain/GPU, build inputs, executable과 bundled Metal resources를 묶는
신뢰 가능한 build/run attestation이 있어야 promotion 근거가 강해진다.

## 9. 다음 개선 순서

1. release candidate의 source/binary/resource provenance를 고정하고 legacy evaluator와
   holdout 접근을 단일 경계로 통합한다. untouched holdout은 별도 custody에서 관리한다.
2. BT.709 scene-linear와 BT.1886 display-referred input 정책을 명시적으로 분리한다.
   SDR fallback, Core/reference/calibration/player까지 같은 policy를 사용하게 한다.
3. 새 metric/preparation version으로 Tune/Validation을 재평가한다. 기존 결과와 섞지 않는다.
   metric/후보/승인 기준을 고정한 뒤에만, 독립성이 확인된 새로운 holdout 절차를 수행한다.
4. 원본 PTS 기반 temporal window와 duplicate/drop 정보를 보존한다. VFR, seek, scene cut,
   decode backpressure, 2/3 in-flight 차이를 포함한 장시간 영상 테스트를 추가한다.
5. 실제 HDR 패널과 SDR 패널에서 계측 patch 및 reference player와 비교한다.
   headroom 변화, display 이동, 밝기 변화의 frame pacing p95/p99/worst를 측정한다.
6. Instruments/Metal counters로 decode/CPU submission/GPU/bandwidth를 분리 측정한다.
   그 결과를 바탕으로 proxy sampling, transfer 연산, texture bandwidth를 최적화한다.

## 10. 최종 verdict

**EXPERIMENTAL — 유망하고 테스트 가능한 GPU tone-expansion 시스템이나,
현재 증거로 production-grade HDR 재현 정확도와 독립 calibration 신뢰성을 승인할 수 없다.**

이번 작업은 확인된 수치/색-domain 오류, resource 누적, verification 실패 은폐를 고치고
독립 anchor와 regression을 남겼다. 좋은 GPU 구조를 유지하면서도, 기존 PASS/점수의
증명 범위를 넘어서 production-ready라고 평가하지 않는 것이 타당하다.
