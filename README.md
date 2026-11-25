# zmk-gaze-switch

보고 있는 화면 쪽으로 키보드 출력이 따라가게 합니다.

- 맥북 화면을 보면 **USB 출력(이 맥)**
- 다른 컴퓨터 쪽을 보면 **BLE 프로필 n(다른 컴퓨터)**

이 저장소에는 두 가지가 들어 있습니다.

| 경로 | 내용 |
|---|---|
| `/` (저장소 루트) | ZMK 모듈. 호스트가 USB 시리얼로 출력을 바꿀 수 있게 하는 `host-output-switch` 스니펫 |
| `app/` | **GazeSwitch**. 맥북 카메라로 시선을 판단해 위 명령을 보내는 메뉴바 앱 |

```
맥북 카메라 → GazeSwitch ──USB 시리얼──▶ 키보드(central)
                                          ├─ USB  → 이 맥
                                          └─ BLE  → 다른 컴퓨터 (프로필 n)
```

키보드(분리형이면 central 쪽)를 맥에 **USB로 꽂아 둔 상태**에서 동작합니다.
모듈은 앱 없이도 쓸 수 있습니다. 프로토콜이 단순해서 다른 스크립트로도 출력을 바꿀 수 있어요.

> ZMK v0.3(Zephyr 3.5) 기반 nRF52840 보드 한 종류(E24 ZEN)에서만 확인했습니다.

## 1. 펌웨어에 모듈 넣기

`config/west.yml`:

```yaml
manifest:
  remotes:
    - name: aimdevlee
      url-base: https://github.com/aimdevlee
  projects:
    - name: zmk-gaze-switch
      remote: aimdevlee
      revision: v0.1.0
```

`build.yaml`에서 USB에 꽂을 쪽(분리형이면 central)에 스니펫을 추가합니다.

```yaml
include:
  - board: nice_nano_v2
    shield: my_keyboard
    snippet: host-output-switch
```

ZMK Studio도 같이 쓴다면 `studio-rpc-usb-uart`를 **앞에** 적으세요.

```yaml
    snippet: "studio-rpc-usb-uart host-output-switch"
```

### 알아 둘 점

- 스니펫은 `&zephyr_udc0`에 CDC ACM 포트를 하나 더 만듭니다. 보드에 `zephyr_udc0` 라벨이 있어야 합니다.
- CDC ACM 포트가 하나라고 가정하는 기능(예: 1200 baud 부트로더 트리거)이 있으면,
  그 기능이 어느 포트를 볼지 직접 오버레이에서 지정해 주세요.
- 다른 컴퓨터는 미리 BLE 프로필 하나에 페어링해 둡니다(예: `&bt BT_SEL 1`).

## 2. 앱 없이 먼저 확인하기

```bash
ls /dev/cu.usbmodem*
```

```bash
screen /dev/cu.usbmodemXXXX 115200
```

`?` 엔터 → `ZMK-HOS 1 U 1 1`처럼 응답하면 전환용 포트입니다.
`B1` 엔터로 BLE 프로필 1, `U` 엔터로 USB로 바뀌는지 확인하세요.
(`screen` 종료: `Ctrl-A` 다음 `K`, `y`)

## 3. GazeSwitch 빌드와 실행

macOS 13 이상, Xcode 명령줄 도구가 필요합니다.

```bash
cd app && ./bundle.sh
```

```bash
open app/GazeSwitch.app
```

처음 실행하면 카메라 권한을 묻습니다. 메뉴바 아이콘 메뉴에서:

- **다른 컴퓨터의 BLE 프로필**: 페어링해 둔 프로필 번호를 고릅니다.
- **보정 시작 (필수, 약 1분)**: 맥북 화면 전체에 안내가 뜨고 각 단계를 음성으로도 읽어 줍니다
  (다른 컴퓨터를 보는 동안에는 이 화면을 못 보니까요). "띵" 소리에 기록을 시작하고 "톡" 소리에 끝납니다. Esc로 취소.
  - 맥북 보기: 평소처럼 → 고개 고정하고 눈만 → 고개는 다른 컴퓨터 쪽, 눈만 맥북
  - 다른 컴퓨터 보기: 평소처럼 → 화면 양 끝 → 고개는 맥북 정면, 눈만 → 고개를 완전히 돌려서
- **지금 이 맥으로 / 지금 다른 컴퓨터로**: 수동 전환.

## 판단 방식

- 프레임마다 여섯 신호를 읽습니다: 고개 좌우·상하(Vision), 눈동자 좌우·상하(Vision 랜드마크),
  홍채 좌우·상하(눈 윤곽 안의 어두운 픽셀 중심).
- 보정 데이터에서 신호들의 평균과 **서로 간의 상관관계**를 구해(LDA), 두 화면을 가장 잘 가르는 조합을 찾습니다.
  고개와 눈을 따로 보면 애매해도 "고개 각도 + 눈 각도"의 합은 분명하기 때문입니다.
- 점수는 맥 쪽 −0.5, 다른 컴퓨터 쪽 +0.5로 맞추고, **±0.08을 넘은 채 0.4초** 유지해야 전환합니다.
- 얼굴이 안 보이면 현재 상태를 유지합니다.
- **마스크를 쓰면** 눈 윤곽이 제대로 잡히지 않아서 고개 방향만으로 판단합니다.

## 개인정보

영상은 저장하거나 전송하지 않습니다. 보정 수치(숫자만)는
`~/Library/Application Support/GazeSwitch/`에 남고, 이 맥 밖으로 나가지 않습니다.

눈 인식이 이상할 때 진단용으로, 보정 중의 눈 부분 사진을 같은 폴더의 `eyes/`에 남기게 할 수 있습니다(기본은 꺼짐).

```bash
defaults write io.github.aimdevlee.GazeSwitch debugEyeImages -bool true
```

## 프로토콜

115200 baud, 줄 단위(`\n` 또는 `\r`). 포트를 연 쪽이 DTR을 올려야 응답합니다.

| 명령 | 동작 |
|---|---|
| `U` | USB 출력 선택 |
| `B` | BLE 출력 선택 (현재 프로필 유지) |
| `B<n>` | BLE 프로필 n 선택 후 BLE 출력 |
| `?` | 상태만 응답 |

응답: `ZMK-HOS 1 <U|B> <프로필> <BLE 연결 0|1>`, 실패하면 `ZMK-HOS 1 ERR`.

BLE 프로필이 연결되지 않은 상태에서 `B`를 보내면 ZMK가 USB를 계속 쓰다가, 연결되는 순간 BLE로 넘어갑니다.

## 라이선스

MIT
