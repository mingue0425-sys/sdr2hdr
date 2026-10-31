# 프로젝트 분석 및 의견 — 2026-10-31

기준: `main` 머지 커밋 `bcdb2d1` (PR #12까지 반영). 이 리뷰는 정적 분석이다.
Linux 컨테이너에서 작성했기 때문에 Metal/AVFoundation 빌드나 테스트는 실행하지 않았다.

## 1. 한 줄 요약

**코어 엔진은 작고 단단한데, 그 주변의 검증·캘리브레이션 장치가 코어보다 3배 이상 커졌다.**
지금 가장 큰 리스크는 버그가 아니다. 색 해석 규약(BT.709 OETF와 BT.1886 중 무엇을 쓰는가)이
미결인 상태로 캘리브레이션 인프라만 계속 정교해지고 있다는 점이다.

## 2. 규모와 구성

| 영역 | 줄 수(대략) | 비고 |
|---|---:|---|
| `HDRCore` (Swift + Metal) | 7.2k | 실시간 변환 코어 |
| `HDRPlayer` | 4.3k | AVPlayer + CAMetalLayer EDR 표시 |
| `HDRCalibration` | 22.3k | V1~V6.2 evaluator가 공존 |
| Tests (Swift) | 15.3k | 349 cases (감사 문서 기준) |
| Shell 스크립트 | 4.9k | `RUN_MACOS_VERIFY.sh` 1.9k, `add_virgin_hlg_pair.sh` 2.9k |
| `docs/*.md` | 4.5k | 보고서 18편 |
| `results/` (커밋됨) | 약 37k | JSON 증거물 |

## 3. 잘된 점

1. **경계가 명확한 코어 API.** `HDRProcessor`는 `CVPixelBuffer`를 받아 GPU 텍스처를 내주는 데서 멈춘다.
   디코드, 표시, 인코드는 하지 않는다. 호출자의 command buffer에 인코딩되고,
   출력 텍스처 3개를 풀로 돌려 in-flight 3개까지 할당 없이 처리한다. 실시간 경로에
   `waitUntilCompleted`가 없다는 점도 확인했다.
2. **색 메타데이터를 엄격하게 다룬다.** primaries, transfer, matrix를 따로 검사한다.
   메타데이터가 일부만 있으면 거부하고, 전부 없을 때만 fallback을 쓴다.
   P010 MSB 정렬을 복원하는 방식(`p010CodeFromUnorm`)도 정확하다.
3. **EDR 표시 정책이 옳다.** `edrMetadata`를 nil로 둬서 시스템 톤매핑이 이중으로 걸리지 않게 했다.
   reference white(1.0) 이하는 건드리지 않고 그 위만 현재 headroom으로 압축한다.
   SDR fallback 분기에서만 clamp한다. Apple 권장 방식과 일치한다.
4. **자기 비판적인 엔지니어링 문화.** README와 감사 문서가 "EXPERIMENTAL"을 명시한다.
   BT.709 OETF 문제, VFR PTS 문제, 16×9 sparse 통계의 한계를 스스로 적어 두었다.
   수치 근거도 독립적으로 붙어 있다(예: PQ 100 nits → 0.50807842).
5. **Holdout 오염 방지에 진지하다.** Frozen 세트를 한 번만 쓰게 하는 ledger,
   plan hash/sidecar, 정적 검사(`verify_no_frozen_access.py`)를 둔다.
   ML 연구에서도 드문 수준의 규율이다.
6. **CI 범위가 넓다.** macOS 15 러너에서 합성 fixture → AVFoundation → 코어 → 오프스크린 표시까지
   end-to-end로 돌린다. Metal debug layer를 켠 multi-flight 회귀도 포함한다.

## 4. 주요 우려와 제안 (우선순위 순)

### P0 — 입력 transfer 규약을 먼저 확정하자

`SDRToHDR.metal`의 `inverseBT709`는 카메라 OETF의 역함수다. 일반 SDR 콘텐츠는
BT.1886(≈ gamma 2.4) 디스플레이 기준으로 마스터링된다. 신호 0.5에서 두 해석의 결과는
0.2596과 0.1895로 약 37% 차이 난다(감사 문서 §6-1).
지금까지의 V1~V6.2 캘리브레이션 점수는 모두 이 규약 위에서 나왔다.
규약을 바꾸면 전부 다시 맞춰야 하므로 결정을 미룰수록 비용이 커진다.

- 제안: `HDRConfiguration`에 `inputInterpretation: .sceneOETF | .displayBT1886(gamma)`를
  versioned 필드로 넣는다. 기본값을 BT.1886으로 둔 후보를 Tune/Validation에서 비교한다.
  그 전까지는 새 캘리브레이션 라운드(V7 등)를 보류하자.

### P1 — 저장소 위생: `.gitignore`와 실제 커밋 내용이 어긋난다

- `.gitignore`는 `*.mp4*`와 `results/`를 제외하는데, 실제로는
  `data_video/virgin_candidates/dvb_live_linear_…/` 아래 **약 24 MB짜리 mp4 2개**가
  강제 추가돼 있고, `results/` 아래 JSON 30개(약 37k줄)도 커밋돼 있다.
  의도라면 `.gitignore`에 `!` 예외를 명시하고, 대용량 미디어는 Git LFS나
  외부 저장소 + SHA-256 lock으로 옮기는 편이 낫다. 이미 lock 체계가 있으니 비용이 크지 않다.
- 저장소 자체에 **LICENSE 파일이 없다.** 또 `LIVE Paired Comparison` DB의 JOD CSV가 커밋돼 있는데,
  `data_video/README.md`에는 `LICENSE_REVIEW_REQUIRED`라고 적혀 있다.
  공개 저장소라면 재배포 가능 여부를 먼저 확인해야 한다.

### P1 — 캘리브레이션 세대 정리

`HDRCalibration`(22k줄)에 V1, V2, V3, V4, V5 preflight, V6, V6.1, V6.2 경로가 모두 남아 있다.
그중 `V4Calibration.swift` 2.2k, `CorrectnessReview.swift` 2.3k,
`V5Preflight.swift` 1.8k가 특히 크다. 재현성 때문에 남겨 둔 것은 이해하지만,
지금 구조로는 수정 하나가 여러 세대에 퍼지고 CI 시간도 길어진다.

- 제안: 역사적 evaluator(V1~V3)는 git 태그로 고정하고 `Legacy` 타깃으로 분리하거나 삭제한다.
  현역 경로(V4 production + V6.x 실험)만 메인 타깃에 남긴다.
  preset(`calibrated-v2`, `v3-candidate`)은 JSON 파라미터 파일로 남기면 A/B 비교는 계속할 수 있다.

### P2 — 셸 스크립트를 Swift나 Python으로 옮기자

`add_virgin_hlg_pair.sh`(2.9k줄)와 `RUN_MACOS_VERIFY.sh`(1.9k줄)는 이미 일반 프로그램 수준의 복잡도다.
감사에서 실제로 발견된 결함 중 두 건(`set -e`가 if/OR 문맥에서 꺼지는 문제, cache key에서
`.metal`이 빠진 문제)이 셸에서 나왔다. 해시 계산, JSON 처리, 캐시 키 같은 로직은
`HDRCalibrate` 서브커맨드나 Python 모듈로 옮기고, 셸은 얇은 진입점으로만 남기길 권한다.

### P2 — 증거 문서와 사용자 문서를 분리하자

`docs/`의 보고서 18편과 README 후반부는 감사 로그 성격이 강하다.
라이브러리 사용자가 알아야 할 내용(API, 지원 포맷, 색 동작, preset 선택)과
연구 기록(V2~V6 경과, Frozen 프로토콜)을 나누는 편이 좋다.
예를 들어 README에는 앞의 것만 두고 나머지는 `docs/research/`로 옮기고,
`CHANGELOG.md`에 preset이 바뀐 이력을 한 줄씩 정리하면 진입 장벽이 크게 낮아진다.
언어도 README는 영어, 감사 문서는 한국어로 섞여 있으니 대상 독자를 정해 두면 좋다.

### P3 — 코어 세부 사항

- **Debug 모드의 프레임당 할당.** `HDRProcessor.process`에서 debug가 켜져 있으면 매 프레임
  `makeBuffer`를 3번 호출한다. 디버그 전용이라 치명적이진 않지만, 출력 텍스처처럼
  슬롯 단위로 재사용하면 디버그 측정 자체가 프레임 타이밍을 덜 흔든다.
- **하이라이트 채도 감쇠(`chromaReduction`).** 계수 0.35가 하드코딩돼 있다.
  `saturationCompensation`과 곱해지므로 실질적으로 같은 자유도가 둘 있는 셈이다.
  캘리브레이션 대상 파라미터로 노출하거나 상수의 근거를 주석으로 남기자.
- **16×9 sparse 통계.** 감사에서 지적했듯 작은 specular highlight를 놓칠 수 있다.
  비용이 거의 없는 대안이 있다. 이미 있는 histogram 패스에서 max나 99th percentile을
  함께 누적하는 것이다.
- **VFR 타임스탬프.** 오프라인 proxy reader가 `fps` 필터로 재표본화한 뒤
  `start + index/fps`로 PTS를 재구성한다. temporal 평가의 신뢰도에 직접 영향을 주므로
  `-vsync passthrough`/`showinfo` 등으로 원본 PTS를 보존하는 쪽이 낫다(감사 문서 §6-2).

## 5. 다음 단계 제안

1. BT.1886 입력 해석 후보를 추가하고 기존 V4와 Tune/Validation에서 비교한다.
   Frozen은 사용하지 않는다.
2. `.gitignore` 예외를 정리하고, 대용량 미디어를 LFS나 외부 저장소로 옮기고, LICENSE를 추가한다.
3. V1~V3 evaluator를 `Legacy`로 격리한다.
4. README를 사용자용과 연구용으로 나눈다.
5. 실제 EDR 디스플레이에서 휘도계로 측정해 1.0 = reference white 가정을 검증한다.
   감사 문서 §6-5의 "미측정" 항목을 해소하는 작업이다.

전반적으로 신호 처리 코어와 검증 문화는 매우 좋은 수준이다. 다만 정밀한 측정 장치가
**아직 고정되지 않은 기준 위에서** 돌고 있다. 기준(입력 규약)을 먼저 확정하고
장치를 줄이는 쪽으로 방향을 잡으면 프로젝트가 production 단계로 훨씬 빨리 갈 것이다.

## 6. 진행 현황 (후속 커밋)

### P0 1단계: 입력 해석 정책 도입 (완료, 기본 동작 변경 없음)

- `HDRSDRInputInterpretation`을 추가했다(`Sources/HDRCore/ColorManagement.swift`).
  - `.sceneReferredInverseOETF`: 기존 동작이며 production 기본값이다.
  - `.displayReferredBT1886(gamma:)`: `.bt1886`은 gamma 2.4다. BT.709 태그 입력에만 적용된다.
- `HDRConfiguration.sdrInputInterpretation` 필드를 추가했다. 기본값은 기존 동작이고,
  `validated()`가 gamma 범위 1...4와 유한성을 검사한다.
- `HDRProcessor.makeShaderParameters`에서 정책을 적용한다. 셰이더 파일은 수정하지 않았다.
  기존 `transferFunction == 2`(power-law) 경로를 재사용하므로 변환 커널과
  temporal/scene estimator가 같은 선형화를 쓴다.
- CPU 기준 구현 `HDRReference.process`에도 같은 정책을 적용해 GPU와 parity를 유지한다.
- `OfflinePixelSampler.linearLumaGrid`에 `interpretation:` 인자를 추가했다. 기본값은 기존 동작이다.
- `HDRPlayer --sdr-input scene-inverse-oetf|bt1886` 옵션으로 실제 디스플레이에서 A/B 비교를 할 수 있다.
  SDR fallback 설정도 선택한 정책을 유지한다.
- 테스트를 추가했다.
  - `Tests/HDRCoreTests/SDRInputInterpretationTests.swift`: 기본값 불변, 매핑, 검증,
    scalar 결과, Metal GPU 결과를 독립 수식과 대조한다.
  - `Tests/HDRPlayerTests/SDRInputInterpretationOptionTests.swift`: CLI 파싱과
    설정 전달, SDR fallback 유지를 확인한다.

이 커밋은 Swift 툴체인이 없는 Linux 환경에서 작성했기 때문에 컴파일과 테스트는 macOS CI에서 확인해야 한다.

### P0 2단계: 남은 작업

1. `HDRCalibration`의 Tune/Validation evaluator가 정책을 받도록 연결한다
   (`Evaluation.swift`의 `linearLumaGrid` 호출부, `HDRSceneStatistics`의 `inverseBT709` 고정 경로,
   `Decode.swift:320`). 정책 식별자는 prepared plan의 preparation configuration에 포함해야 한다.
2. `.bt1886` 기준 후보를 Tune에서 탐색하고 Validation에서 V4와 비교한다. Frozen은 사용하지 않는다.
3. 결과에 따라 production 기본값을 바꿀지 결정한다. 바꾸면 preset 이름도 새로 붙인다.
