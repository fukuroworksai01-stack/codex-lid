# Codex Lid

[English README](README.en.md)

[![CI](https://github.com/fukuroworksai01-stack/codex-lid/actions/workflows/ci.yml/badge.svg)](https://github.com/fukuroworksai01-stack/codex-lid/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

MacBookの蓋を閉じたあとも、ローカルで実行中のCodexタスクやビルドを**指定時間だけ**継続させるmacOSメニューバーアプリです。

OpenAI/Codexの非公式コミュニティツールです。Codex API、Remoteの通信、Codexの操作自体には関与しません。

> [!WARNING]
> 実験的なアルファ版です。CodexだけでなくMac全体のスリープを一時的に無効化します。閉じたMacをバッグ、ケース、布団など放熱できない場所へ入れないでください。

> [!IMPORTANT]
> **Codex LidだけではCodex Remoteの接続は維持できません。** [OpenAIのRemote接続ガイド](https://learn.chatgpt.com/docs/remote-connections)では、MacBookの蓋を閉じてRemoteを使う場合、電源に加えて外部ディスプレイの接続も必要と案内されています。外部ディスプレイがない場合は、蓋を開けたまま画面だけを消してください。

## Codex Remoteで使う場合

Codex Lidが担当するのはmacOSのスリープ禁止だけです。ChatGPT Desktopの認証済み接続、ネットワーク、再接続は制御しません。

- ChatGPT Desktopを最新版にし、Remote設定の「Keep this Mac awake」を有効にする
- Macを電源と安定したネットワークへ接続する
- 外部ディスプレイなし：蓋を開けたまま、Codex Lidの「Remote向け：蓋を開けたまま画面を消す」を使う
- 蓋を閉じる：上記に加えて、外部ディスプレイを接続する

アプリは内蔵画面以外のアクティブなディスプレイを開始前に補助検出します。ディスプレイの種類や公式条件への適合、Remote接続の成功は保証しません。

## 特徴

- 初回確認用の5分テストと、30分・1時間・2時間の上限
- 標準では電源アダプタ接続中のみ動作
- バッテリー動作を明示的に許可した場合も25%で停止
- 低電力モード、深刻な高温、電源切断、タイマー終了で自動停止
- 電源状態またはバッテリー残量を安全に読めない場合も停止
- GUIとは独立した時間制限付きroot監視と、監視異常終了時に復旧するfailsafe
- アプリ本体とworkerをroot所有の`/Library/Application Support/Codex Lid`へ導入し、ユーザーが書き換えられるコードは管理者権限で起動しない
- 永続的なsudoers設定、常駐デーモン、カーネル拡張、ネットワーク通信、分析機能なし
- 他のツールがすでにスリープ禁止を有効にしている場合は開始を拒否

## 必要環境

- macOS 13以降
- Apple SiliconまたはIntel Mac
- Xcode Command Line Tools（`xcrun swiftc`）
- セッション開始時に管理者認証できるアカウント

配布用の署名・公証済みバイナリはまだ提供していません。現時点ではソースからローカルビルドしてください。

## ビルドとインストール

```bash
git clone https://github.com/fukuroworksai01-stack/codex-lid.git
cd codex-lid
./scripts/test.sh
./scripts/install.sh
```

アプリは最初に`dist/Codex Lid.app`へ作成されます。インストーラは検証済みbundle全体をroot所有の`/Library/Application Support/Codex Lid/Codex Lid.app`へ配置し、`/Applications/Codex Lid.app`から起動できるようにします。この処理では管理者パスワードを求めます。既存版を置き換える場合は、Codex Lidを終了してから次を実行します。

```bash
./scripts/install.sh --replace
```

## 使い方

1. `/Applications/Codex Lid.app`を起動します。
2. 電源アダプタを接続し、Macを硬く平らな場所へ置きます。
3. メニューバーの月アイコンから、初回は「5分テスト」を選びます。
4. 内容を確認してmacOSの管理者認証を行います。
5. ローカル処理の蓋閉じテストをする場合だけ、画面を消して蓋を閉じます。Remoteで外部ディスプレイがない場合は、蓋を開けたままにします。
6. テスト後に、作業結果と通常スリープへの復旧を確認します。

アプリを終了しても独立監視は指定時間まで残ります。早く戻す場合は「停止して通常スリープへ戻す」を選びます。

## 状態確認と緊急復旧

インストール済みの版、実行場所、電源、スリープ、外部ディスプレイの状態は、読み取り専用の診断スクリプトで確認できます。ネットワーク通信や統合ログの収集は行いません。

```bash
./scripts/diagnose.sh
```

```bash
pmset -g | grep SleepDisabled
```

`SleepDisabled 1`のまま戻らない場合は、次のコマンドで通常へ戻せます。保護されたworkerを経由するため、進行中の設定変更があれば、その完了後に解除します。この操作は他のスリープ防止ツールの設定も解除します。

```bash
sudo "/Library/Application Support/Codex Lid/Codex Lid.app/Contents/Resources/CodexLidWorker" --set-sleep 0
```

保護されたworkerを実行できない場合の最終手段は`sudo pmset -a disablesleep 0`です。

## 重要な制限

- `pmset disablesleep`は`pmset(1)`に掲載されていないmacOSの非公開設定です。OS更新後は必ず5分テストから始めてください。
- Codex LidはRemoteのWebSocket、認証、ネットワーク、再接続を操作しません。Macが起きていてもRemoteが切断される場合があります。
- 外部ディスプレイを接続せずにMacBookの蓋を閉じるRemote運用は、OpenAIの公式条件外です。
- Codexが確認・承認待ち、ネットワーク待ち、入力待ちになれば処理はそこで止まります。
- MacBook Airはファンレスです。閉じた状態で高負荷レンダリングを続ける用途には向きません。
- コンパイル、自己テスト、アプリ起動はM1 MacBook Airで確認しています。機種とOSの組み合わせごとに、実作業前の短時間テストが必要です。
- Codex Cloudで完結する作業では、Macを起こし続けるよりCloudの利用を検討してください。

## セキュリティと設計

管理者権限を使う範囲、監視・復旧フロー、既知のトレードオフは[アーキテクチャ文書](docs/ARCHITECTURE.md)に記載しています。脆弱性の報告方法は[SECURITY.md](SECURITY.md)を参照してください。

## アンインストール

動作中のセッションとCodex Lidを終了してから、次を実行します。保護領域のアプリ本体と`/Applications`の起動リンクが削除されます。旧版が`~/Applications`にある場合は、正しいCodex Lid bundleだけをゴミ箱へ移します。

```bash
./scripts/uninstall.sh
```

sudoers設定や常駐デーモンは残りません。アンインストール完了後、診断情報が不要なら`/private/tmp/codex-lid-$(id -u)`も削除できます。

## 開発

変更前後に次を実行してください。

```bash
./scripts/test.sh
```

貢献方法は[CONTRIBUTING.md](CONTRIBUTING.md)、変更履歴は[CHANGELOG.md](CHANGELOG.md)を参照してください。

## License

[MIT License](LICENSE)
