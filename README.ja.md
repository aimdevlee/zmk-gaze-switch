# zmk-gaze-switch

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md)

見ている画面のほうへ、キーボードの出力が切り替わります。

- MacBook の画面を見る → **USB 出力(この Mac)**
- もう一台のコンピュータのほうを見る → **BLE プロファイル n(もう一台)**

このリポジトリには二つのものが入っています。

| パス | 内容 |
|---|---|
| `/`(リポジトリのルート) | ZMK モジュール。ホストが USB シリアル経由で出力を切り替えられる `host-output-switch` スニペット |
| `app/` | **GazeSwitch**。MacBook のカメラで視線を判定し、上のコマンドを送るメニューバーアプリ |

```
MacBook のカメラ → GazeSwitch ──USB シリアル──▶ キーボード(central)
                                                 ├─ USB  → この Mac
                                                 └─ BLE  → もう一台(プロファイル n)
```

キーボード(分割型なら central 側)を Mac に **USB で接続した状態**で動作します。
モジュールはアプリなしでも使えます。プロトコルが単純なので、ほかのスクリプトからも出力を切り替えられます。

> 確認したのは ZMK v0.3(Zephyr 3.5)ベースの nRF52840 ボード 1 種類(E24 ZEN)だけです。

## 1. ファームウェアにモジュールを追加する

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

`build.yaml` で、USB につなぐ側(分割型なら central)にスニペットを追加します。

```yaml
include:
  - board: nice_nano_v2
    shield: my_keyboard
    snippet: host-output-switch
```

ZMK Studio も併用する場合は、`studio-rpc-usb-uart` を**先に**書いてください。

```yaml
    snippet: "studio-rpc-usb-uart host-output-switch"
```

### 注意点

- スニペットは `&zephyr_udc0` に CDC ACM ポートをもう一つ追加します。ボードに `zephyr_udc0` ラベルが必要です。
- CDC ACM ポートが一つだけだと想定している機能(例: 1200 baud のブートローダートリガー)がある場合は、
  どのポートを監視するかを自分のオーバーレイで指定してください。
- もう一台のコンピュータは、あらかじめ BLE プロファイルの一つにペアリングしておきます(例: `&bt BT_SEL 1`)。

## 2. アプリなしで先に確認する

```bash
ls /dev/cu.usbmodem*
```

```bash
screen /dev/cu.usbmodemXXXX 115200
```

`?` と Enter を入力し、`ZMK-HOS 1 U 1 1` のように返ってくれば切り替え用のポートです。
`B1` で BLE プロファイル 1 に、`U` で USB に切り替わることを確認してください。
(`screen` の終了: `Ctrl-A` のあと `K`、`y`)

## 3. GazeSwitch のインストール

[最新のリリース](https://github.com/aimdevlee/zmk-gaze-switch/releases/latest)から `GazeSwitch-x.y.z.dmg` をダウンロードして開き、`GazeSwitch` を
アプリケーションフォルダにドラッグして、そこから開きます。macOS 13 以降が必要で、Apple シリコンと Intel のどちらの Mac でも動きます。
署名と公証を済ませたアプリなので、警告なしで開けます。

### 自分でビルドする

Xcode コマンドラインツールが必要です。

```bash
cd app && ./bundle.sh
```

```bash
open app/GazeSwitch.app
```

初回起動時にカメラの許可を求められます。アプリはシステムの言語(日本語・英語・韓国語)に合わせて表示され、
メニューの**言語**から選ぶこともできます。メニューバーのアイコンから:

- **もう一台の BLE プロファイル**: ペアリングしたプロファイル番号を選びます。
- **キャリブレーション開始**(必須、約 1 分): MacBook の画面全体に案内が表示され、各ステップは音声でも読み上げられます
  (もう一台を見ている間はこの画面が見えないためです)。「ティン」という音で記録が始まり、「ポッ」という音で終わります。Esc でキャンセル。
  - MacBook を見る: 普段どおり → 頭を動かさず目だけ → 頭はもう一台のほう、目だけ MacBook
  - もう一台を見る: 普段どおり → 画面の両端 → 頭は MacBook の正面、目だけ → 頭を完全に向けて
- **今すぐこの Mac へ / 今すぐもう一台へ**: 手動切り替え。

## 判定の仕組み

- フレームごとに六つの信号を読みます: 頭の左右・上下(Vision)、瞳の左右・上下(Vision のランドマーク)、
  虹彩の左右・上下(目の輪郭の内側にある暗いピクセルの中心)。
- キャリブレーションのデータから各信号の平均と**信号どうしの相関**を求め(LDA)、二つの画面を最もよく分ける組み合わせを探します。
  頭と目を別々に見るとあいまいでも、「頭の角度 + 目の角度」ははっきりしているためです。
- スコアは Mac 側を −0.5、もう一台側を +0.5 にそろえ、**±0.08 を超えた状態が 0.4 秒**続いたときだけ切り替えます。
- 顔が見えないときは現在の出力を保ちます。
- **マスクを着けていると**目の輪郭を正しく検出できないため、頭の向きだけで判定します。

## プライバシー

映像は保存も送信もしません。キャリブレーションの数値(数字のみ)は
`~/Library/Application Support/GazeSwitch/` に残り、この Mac の外には出ません。

目の検出がおかしいときの診断用に、キャリブレーション中の目の部分の画像を同じフォルダの `eyes/` に残すこともできます(既定はオフ)。

```bash
defaults write io.github.aimdevlee.GazeSwitch debugEyeImages -bool true
```

## プロトコル

115200 baud、行単位(`\n` または `\r`)。ポートを開いた側が DTR を立てている間だけ応答します。

| コマンド | 動作 |
|---|---|
| `U` | USB 出力を選択 |
| `B` | BLE 出力を選択(現在のプロファイルのまま) |
| `B<n>` | BLE プロファイル n を選択してから BLE 出力 |
| `?` | 状態だけ応答 |

応答: `ZMK-HOS 1 <U|B> <プロファイル> <BLE 接続 0|1>`、失敗時は `ZMK-HOS 1 ERR`。

BLE プロファイルが未接続のときに `B` を送ると、ZMK は USB を使い続け、接続された時点で BLE に切り替わります。

## ライセンス

MIT
