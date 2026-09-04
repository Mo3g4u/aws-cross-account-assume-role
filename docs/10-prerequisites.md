# 共通の前提と準備

方式A・方式B のどちらを試す場合も、先にここを済ませておく。

## 1. 必要なもの

| 項目 | 要件 |
|---|---|
| AWS アカウント | **2 つ**（A: 呼び出し元 / B: API 提供側）。同一 Organizations 配下である必要はない |
| AWS CLI | v2 |
| AWS SAM CLI | v1.100 以上を推奨（`sam --version` で確認） |
| Python | 3.12（Lambda ランタイムに合わせる。ローカル実行しないならバージョン差は問題にならない） |
| 権限 | 各アカウントで IAM ロール・API Gateway・Lambda・CloudFormation を作成できる権限 |

AWS SAM CLI が未導入の場合:

```bash
brew install aws-sam-cli
```

## 2. AWS CLI プロファイルの用意

本リポジトリのスクリプトは、A / B それぞれのプロファイル名を前提にしている。

```bash
aws configure --profile account-a
aws configure --profile account-b
```

SSO を使っている場合は `aws configure sso --profile account-a` でもよい。

設定できたら、**それぞれが意図したアカウントを指しているか必ず確認する**。ここを取り違えたまま進めると、原因のわかりにくい 403 に延々と悩まされる。

```bash
aws sts get-caller-identity --profile account-a
aws sts get-caller-identity --profile account-b
```

## 3. config.env の作成

各パターンのディレクトリで共通に読み込む設定ファイルを、リポジトリ直下に作る。

```bash
cp config.env.example config.env
```

`config.env` を自分の環境に合わせて編集する。

```bash
PREFIX=takeuchi                # リソース名のプレフィックス（後述）
ACCOUNT_A_ID=111111111111      # 呼び出し元（Lambda を置く方）
ACCOUNT_B_ID=222222222222      # API 提供側
PROFILE_A=account-a
PROFILE_B=account-b
REGION=ap-northeast-1
```

> `config.env` は `.gitignore` 済み。アカウント ID を含むのでコミットしないこと。

## 4. PREFIX ── 複数人で同じアカウントを使う場合

**同じ AWS アカウントを複数人で共有して検証する場合、`PREFIX` を各自で変える。** これを変えるだけで、作成されるリソース名がすべて衝突しなくなる。

### 何が変わるか

`PREFIX` はスタック名に入り、スタック名から他のリソース名が派生する。

```
PREFIX=takeuchi
   │
   ├─ スタック名        takeuchi-xacct-a-caller / takeuchi-xacct-a-api
   │     │
   │     ├─ Lambda 関数名   takeuchi-xacct-a-caller-caller
   │     │                  takeuchi-xacct-a-api-items
   │     ├─ API 名          takeuchi-xacct-a-api
   │     ├─ IAM ロール名    takeuchi-xacct-a-caller-CallerFunctionRole-XXXX
   │     │                  （CloudFormation が自動生成）
   │     └─ ロググループ    /aws/lambda/takeuchi-xacct-a-caller-caller
   │
   └─ RoleSessionName    takeuchi-xacct-b-caller-caller-1a2b3c4d （方式B）
```

スタック名の命名は `<PREFIX>-xacct-<方式>-<役割>`。

| 部分 | 値 | 意味 |
|---|---|---|
| `<方式>` | `a` / `b` | 方式A（リソースポリシー）/ 方式B（AssumeRole） |
| `<役割>` | `caller` / `api` | アカウントA 側 / アカウントB 側 |

方式B の `RoleSessionName` にも関数名が入るため、**同じロールを複数人が引き受けても、B 側の CloudTrail で誰のセッションか判別できる**。

### 設定ルール

| 項目 | 内容 |
|---|---|
| 制約 | 英字で始まり、英数字とハイフンのみ、**12 文字以内** |
| 正規化 | 大文字は小文字に、記号（`.` `_` `@` など）はハイフンに自動変換される |
| 未設定時 | `$USER` から自動生成する |

`K.Takeuchi` → `k-takeuchi`、`yamada_taro` → `yamada-taro` のように自動で整形される。数字始まり（CloudFormation のスタック名として不正）や、正規化した結果が空になる場合はエラーで停止する。

12 文字の上限は、CloudFormation が自動生成する IAM ロール名（64 文字上限）に収めるための制約。

### 確認方法

デプロイ前に、これから何を作るのかがバナーで表示される。

```
-----------------------------------------------------------
 方式A: REST API + リソースポリシー をデプロイ
-----------------------------------------------------------
  PREFIX          : takeuchi
  アカウントA     : 111111111111 (profile: account-a)
  アカウントB     : 222222222222 (profile: account-b)
  リージョン      : ap-northeast-1
  スタック (A側)  : takeuchi-xacct-a-caller
  スタック (B側)  : takeuchi-xacct-a-api
```

他の人が作ったスタックを消してしまわないよう、`cleanup.sh` は削除対象を表示したうえで確認を求める。

## 5. デプロイ順序の考え方（重要）

クロスアカウント構成には**循環参照**がある。

- B 側のポリシーは「A のロール ARN」を知る必要がある
- A 側の Lambda は「B の API エンドポイント」を知る必要がある

このため、どちらのパターンも **3 ステップ**でデプロイする。

```
[1] A スタックをデプロイ        → A の Lambda 実行ロール ARN が確定
                                   （この時点では B の権限はアカウント単位の広めの指定）
[2] B スタックをデプロイ        → [1] のロール ARN を信頼／許可した API が確定
[3] A スタックを再デプロイ      → B のエンドポイントを環境変数に設定し、
                                   権限を実際の API / ロール ARN まで絞り込む
```

各パターンの `deploy.sh` がこの 3 ステップを自動で実行する。手順を 1 つずつ理解したい場合は、各 README の「手動デプロイ」節を参照。

### なぜ [1] を先にやるのか

方式B では B 側 IAM ロールの**信頼ポリシー**に A のロール ARN を書く。IAM は信頼ポリシーの principal が**実在するか検証する**ため、A のロールが存在しない状態で B をデプロイすると次のエラーになる。

```
MalformedPolicyDocument: Invalid principal in policy
```

方式A のリソースポリシーではこの検証は走らないが、手順を揃えるため同じ順序にしている。

## 6. 後片付け

課金対象は微々たるものだが（Lambda・API Gateway とも従量課金）、検証後は消しておくとよい。

```bash
./cleanup.sh   # 各パターンのディレクトリで実行
```

## 7. 参考

- [AWS SAM CLI のインストール](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html)
- [名前付きプロファイル](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-profiles.html)
