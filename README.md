# Oracle Cloud 無料枠インスタンス自動作成ツール

Oracle Cloudの無料枠（Always Free）ARM インスタンスを自動的に作成するためのGitHub Actionsベースのツールです。

## 概要

Oracle CloudのARM インスタンス（VM.Standard.A1.Flex）は非常に人気が高く、手動で作成しようとすると「Out of capacity」エラーが頻発します。このツールはGitHub Actionsを使って30分ごとに自動リトライを行い、空きが出た瞬間にインスタンスを作成します。

### 特徴

- **自動リトライ**: 30分ごとに自動でインスタンス作成を試行
- **段階的スペック調整**: 最大スペックで空きがない場合、自動的にスペックを下げて試行（AUTOモード）
- **通知機能**: 成功時にDiscord/Slack/GitHub Issueで通知
- **安全設計**: 成功後は自動停止、認証情報はGitHub Secretsで管理

## 重要: セキュリティについて

**このリポジトリは必ずプライベートリポジトリとして作成してください。**

パブリックリポジトリにすると、GitHub Actionsのログや設定からAPIキー情報が漏洩するリスクがあります。

---

## セットアップ手順

### 前提条件

- Oracle Cloudアカウント（作成済み）
- GitHubアカウント

---

### Step 1: Oracle Cloud APIキーの作成

1. [Oracle Cloud Console](https://cloud.oracle.com/) にログイン

2. 右上のプロフィールアイコンをクリック → **「ユーザー設定」** を選択

3. 左メニューの **「APIキー」** をクリック

4. **「APIキーの追加」** ボタンをクリック

5. **「APIキー・ペアの生成」** を選択し、**「秘密キーのダウンロード」** をクリック
   - ダウンロードした `*.pem` ファイルは安全な場所に保存
   - このファイルの内容は後でGitHub Secretsに設定します

6. **「追加」** ボタンをクリック

7. 表示される **「構成ファイルのプレビュー」** の内容をメモ帳などにコピー
   - `user`、`fingerprint`、`tenancy`、`region` の値が必要です

---

### Step 2: 必要なOCIDの確認

#### ユーザーOCID
1. Oracle Cloud Console → 右上プロフィール → **「ユーザー設定」**
2. **「ユーザー情報」** タブの **「OCID」** をコピー
   - 形式: `ocid1.user.oc1..xxxxx`

#### テナンシーOCID
1. Oracle Cloud Console → 右上プロフィール → **「テナンシ」**
2. **「テナンシ情報」** の **「OCID」** をコピー
   - 形式: `ocid1.tenancy.oc1..xxxxx`

#### コンパートメントOCID
1. Oracle Cloud Console → ハンバーガーメニュー → **「アイデンティティとセキュリティ」** → **「コンパートメント」**
2. 使用するコンパートメントをクリック（通常はルートまたは作成済みのもの）
3. **「OCID」** をコピー
   - 形式: `ocid1.compartment.oc1..xxxxx`
   - ルートコンパートメントを使う場合はテナンシーOCIDと同じ

---

### Step 3: VCN（仮想クラウドネットワーク）の作成

インスタンスを配置するネットワークが必要です。既に作成済みの場合はスキップしてください。

1. Oracle Cloud Console → ハンバーガーメニュー → **「ネットワーキング」** → **「仮想クラウド・ネットワーク」**

2. **「VCNウィザードの起動」** をクリック

3. **「インターネット接続性を持つVCNの作成」** を選択 → **「VCNウィザードの起動」**

4. 設定:
   - VCN名: 任意（例: `free-tier-vcn`）
   - コンパートメント: Step 2で確認したもの
   - その他はデフォルトでOK

5. **「次」** → **「作成」** をクリック

6. 作成完了後、**「パブリック・サブネット」** をクリック

7. サブネットの **「OCID」** をコピー
   - 形式: `ocid1.subnet.oc1.ap-tokyo-1.xxxxx`

---

### Step 4: セキュリティ・リストの設定（SSH接続用）

SSHで接続できるようにするため、セキュリティ・リストを設定します。

1. VCNの詳細画面 → **「セキュリティ・リスト」** → デフォルトのセキュリティ・リストをクリック

2. **「イングレス・ルールの追加」** をクリック

3. 設定:
   - ソースCIDR: `0.0.0.0/0`（任意の場所から）または自分のIPアドレス
   - IPプロトコル: TCP
   - 宛先ポート範囲: `22`

4. **「イングレス・ルールの追加」** をクリック

---

### Step 5: 可用性ドメインの確認

1. Oracle Cloud Console → ハンバーガーメニュー → **「コンピュート」** → **「インスタンス」**

2. **「インスタンスの作成」** をクリック（実際には作成しません）

3. **「配置」** セクションの **「可用性ドメイン」** のドロップダウンを確認
   - 形式: `xxxx:AP-TOKYO-1-AD-1`
   - この値をメモしておく

4. **「キャンセル」** でウィザードを閉じる

---

### Step 6: OSイメージOCIDの確認

1. 同じくインスタンス作成ウィザードを開く

2. **「イメージとシェイプ」** セクション → **「イメージの変更」** をクリック

3. 使用したいOS（推奨: **Ubuntu 24.04** または **Oracle Linux 9**）を選択

4. **「イメージの選択」** をクリック

5. 選択後、**「イメージの詳細」** リンクをクリック（または別タブで確認）

6. イメージの **「OCID」** をコピー
   - 形式: `ocid1.image.oc1.ap-tokyo-1.xxxxx`

7. **「キャンセル」** でウィザードを閉じる

**※ イメージOCIDはリージョンごとに異なります。必ず使用するリージョンのOCIDを取得してください。**

---

### Step 7: SSH公開鍵の準備（オプションだが推奨）

インスタンスにSSHで接続するための公開鍵を準備します。

#### 既存のSSH鍵がある場合

```bash
cat ~/.ssh/id_rsa.pub
# または
cat ~/.ssh/id_ed25519.pub
```

#### 新しく作成する場合

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
cat ~/.ssh/id_ed25519.pub
```

出力された公開鍵（`ssh-ed25519 AAAA... your_email@example.com`）をコピーしておきます。

---

### Step 8: GitHubリポジトリの作成

1. [GitHub](https://github.com/) にログイン

2. 右上の **「+」** → **「New repository」** をクリック

3. 設定:
   - Repository name: 任意（例: `oracle-instance-creator`）
   - **Private** を選択（重要！）
   - 「Add a README file」は**チェックしない**

4. **「Create repository」** をクリック

5. ローカルでこのツールのファイルをリポジトリにプッシュ:

```bash
cd /path/to/oracle  # このツールのディレクトリ
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/oracle-instance-creator.git
git push -u origin main
```

---

### Step 9: GitHub Secretsの設定

1. GitHubリポジトリ → **「Settings」** タブ

2. 左メニュー **「Secrets and variables」** → **「Actions」**

3. **「New repository secret」** をクリックして以下を順次追加:

| Secret名 | 値 | 例 |
|---------|---|---|
| `OCI_USER_OCID` | ユーザーOCID | `ocid1.user.oc1..xxxxx` |
| `OCI_TENANCY_OCID` | テナンシーOCID | `ocid1.tenancy.oc1..xxxxx` |
| `OCI_FINGERPRINT` | APIキーのフィンガープリント | `aa:bb:cc:dd:ee:ff:00:11:...` |
| `OCI_PRIVATE_KEY` | 秘密鍵の内容（※下記参照） | `-----BEGIN PRIVATE KEY-----...` |
| `OCI_REGION` | リージョン識別子 | `ap-tokyo-1` |
| `OCI_COMPARTMENT_ID` | コンパートメントOCID | `ocid1.compartment.oc1..xxxxx` |
| `OCI_SUBNET_ID` | サブネットOCID | `ocid1.subnet.oc1.ap-tokyo-1.xxxxx` |
| `OCI_IMAGE_ID` | OSイメージOCID | `ocid1.image.oc1.ap-tokyo-1.xxxxx` |
| `OCI_AVAILABILITY_DOMAIN` | 可用性ドメイン | `xxxx:AP-TOKYO-1-AD-1` |
| `OCI_SSH_PUBLIC_KEY` | SSH公開鍵（オプション） | `ssh-ed25519 AAAA...` |
| `DISCORD_WEBHOOK_URL` | Discord通知URL（オプション） | `https://discord.com/api/webhooks/...` |

#### OCI_PRIVATE_KEY の設定方法

ダウンロードした秘密鍵ファイル（`.pem`）の内容をそのままコピー＆ペーストします:

```
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASC...
...（中略）...
...BKhQKPvI2TU=
-----END PRIVATE KEY-----
```

**改行を含めて全体をコピーしてください。**

---

### Step 10: Discord Webhook URLの取得（オプション）

成功時にDiscordで通知を受け取りたい場合:

1. Discord → 通知を送りたいチャンネルの設定（歯車アイコン）

2. **「連携サービス」** → **「ウェブフック」**

3. **「新しいウェブフック」** をクリック

4. 名前を設定（例: `Oracle Instance Bot`）

5. **「ウェブフックURLをコピー」** をクリック

6. コピーしたURLをGitHub Secretsの `DISCORD_WEBHOOK_URL` に設定

---

### Step 11: ワークフローの有効化

1. GitHubリポジトリ → **「Actions」** タブ

2. 「I understand my workflows, go ahead and enable them」をクリック（初回のみ）

3. 左側の **「Oracle Cloud Instance Creator」** をクリック

4. **「Run workflow」** → **「Run workflow」** で手動実行してテスト

---

## 使い方

### 自動実行

設定完了後、ワークフローは30分ごとに自動で実行されます。

### 手動実行

1. **「Actions」** タブ → **「Oracle Cloud Instance Creator」**
2. **「Run workflow」** をクリック
3. オプションを選択:
   - **Instance Size**: `AUTO`（推奨）、`MAX`、`MID`、`MIN`
   - **Force Run**: 成功フラグを無視して強制実行

### インスタンスサイズの説明

| サイズ | OCPU | メモリ | ストレージ | 説明 |
|-------|------|--------|-----------|------|
| `MAX` | 4 | 24GB | 200GB | 無料枠最大（確保困難） |
| `MID` | 2 | 12GB | 100GB | バランス型 |
| `MIN` | 1 | 6GB | 50GB | 最小（確保しやすい） |
| `AUTO` | - | - | - | MAX→MID→MINの順で試行（推奨） |

---

## 成功後の確認

### インスタンスの確認

1. Oracle Cloud Console → **「コンピュート」** → **「インスタンス」**
2. 作成されたインスタンスが「実行中」になっていることを確認
3. パブリックIPアドレスをメモ

### SSH接続

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<パブリックIPアドレス>
# Oracle Linuxの場合
ssh -i ~/.ssh/id_ed25519 opc@<パブリックIPアドレス>
```

### ワークフローの無効化（任意）

成功後にこれ以上リトライが不要な場合:

1. **「Actions」** タブ → **「Oracle Cloud Instance Creator」**
2. 右上の **「...」** → **「Disable workflow」**

または、リポジトリ内の `.instance-created` ファイルが自動的にコミットされ、以降の実行はスキップされます。

---

## トラブルシューティング

### 「Out of capacity」エラーが続く

- これは正常な動作です。Oracle Cloudのリソースに空きがないため待機しています。
- 数時間〜数日で空きが出ることが多いです。
- `AUTO` モードを使用すると、自動的にスペックを下げて試行します。

### 認証エラー

- `OCI_PRIVATE_KEY` が正しくコピーされているか確認
  - 改行を含めて全体をコピー
  - `-----BEGIN PRIVATE KEY-----` から `-----END PRIVATE KEY-----` まで
- `OCI_FINGERPRINT` がAPIキー作成時に表示されたものと一致しているか確認
- APIキーが削除されていないか確認

### サブネット/イメージが見つからないエラー

- `OCI_REGION` と他のOCID（サブネット、イメージ）のリージョンが一致しているか確認
- イメージOCIDはリージョンごとに異なります

### ワークフローが実行されない

- リポジトリの **「Actions」** タブでワークフローが有効になっているか確認
- `.github/workflows/create-instance.yml` ファイルが正しくプッシュされているか確認

---

## リージョン一覧（アジア太平洋）

| リージョン | 識別子 |
|-----------|--------|
| 東京 | `ap-tokyo-1` |
| 大阪 | `ap-osaka-1` |
| ソウル | `ap-seoul-1` |
| シンガポール | `ap-singapore-1` |
| ムンバイ | `ap-mumbai-1` |
| シドニー | `ap-sydney-1` |

---

## ライセンス

MIT License

---

## 免責事項

- このツールはOracle Cloudの利用規約に従って使用してください
- 過度なAPIコールはアカウント制限の原因となる可能性があります
- 作成したインスタンスの管理は利用者の責任で行ってください
