# AWS クロスアカウント API Gateway 呼び出しの検証

アカウントA の Lambda から、アカウントB の API Gateway を呼び出す方法を、比較検討したうえで 2 方式とも実際にデプロイして確認するためのリポジトリ。

---

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| **[docs/00-comparison.md](docs/00-comparison.md)** | **比較検討ドキュメント**。方式の一覧、AWS の仕様上の制約、選定フロー、結論 |
| [docs/10-prerequisites.md](docs/10-prerequisites.md) | 共通の準備（2 アカウント、プロファイル、`config.env`、**PREFIX**、デプロイ順序の考え方） |
| [docs/20-iam-policies.md](docs/20-iam-policies.md) | **用語解説**: IAM ポリシーの種類と権限評価ロジック |
| [docs/21-assume-role-sts.md](docs/21-assume-role-sts.md) | **用語解説**: AssumeRole・STS・一時認証情報 |
| [docs/22-sigv4.md](docs/22-sigv4.md) | **用語解説**: SigV4 署名の仕組み |
| [docs/23-apigateway-rest-vs-http.md](docs/23-apigateway-rest-vs-http.md) | **用語解説**: REST API と HTTP API の違い |
| [docs/90-troubleshooting.md](docs/90-troubleshooting.md) | 症状から引くトラブルシューティング |

### 用語索引

わからない用語が出てきたらここから引く。

| 用語 | 解説場所 |
|---|---|
| アイデンティティベースポリシー / 権限ポリシー | [20 §2.1](docs/20-iam-policies.md#21-アイデンティティベースポリシー) |
| リソースベースポリシー / リソースポリシー | [20 §2.2](docs/20-iam-policies.md#22-リソースベースポリシー) |
| 信頼ポリシー（`AssumeRolePolicyDocument`） | [20 §2.3](docs/20-iam-policies.md#23-信頼ポリシー) |
| Principal / `:root` / assumed-role ARN | [20 §3](docs/20-iam-policies.md#3-principal-の書き方) |
| ARN の構造 / `execute-api` ARN | [20 §4](docs/20-iam-policies.md#4-arn-の構造) |
| 明示的 Deny / 暗黙の Deny / 権限評価 | [20 §5](docs/20-iam-policies.md#5-権限評価ロジック) |
| **クロスアカウントの「両側 Allow」** | [20 §5.2](docs/20-iam-policies.md#52-同一アカウント-vs-クロスアカウント) |
| IAM ロール / 長期 vs 一時認証情報 | [21 §1](docs/21-assume-role-sts.md#1-そもそもなぜロールなのか) |
| STS / `GetCallerIdentity` | [21 §2](docs/21-assume-role-sts.md#2-aws-sts) |
| **AssumeRole** | [21 §3](docs/21-assume-role-sts.md#3-assumerole-の流れ) |
| セッショントークン / `Expiration` / `DurationSeconds` | [21 §4](docs/21-assume-role-sts.md#4-一時認証情報の中身) |
| `RoleSessionName` / CloudTrail での追跡 | [21 §5](docs/21-assume-role-sts.md#5-rolesessionname-と追跡) |
| `ExternalId` / confused deputy | [21 §6](docs/21-assume-role-sts.md#6-externalid-と-confused-deputy) |
| 認証情報のキャッシュ / ロールチェーン | [21 §7](docs/21-assume-role-sts.md#7-一時認証情報のキャッシュ), [§8](docs/21-assume-role-sts.md#8-lambda-実行ロールも-assumerole-されている) |
| **SigV4 署名** | [22 §2](docs/22-sigv4.md#2-署名の-4-ステップ) |
| 正規リクエスト / 署名文字列 / 認証情報スコープ | [22 §2](docs/22-sigv4.md#2-署名の-4-ステップ) |
| `X-Amz-Security-Token` | [22 §3](docs/22-sigv4.md#3-一時認証情報の場合) |
| 署名後の書き換えで壊れる理由 | [22 §4](docs/22-sigv4.md#4-なぜ署名後に書き換えると壊れるのか) |
| **REST API と HTTP API の違い** | [23 §2](docs/23-apigateway-rest-vs-http.md#2-機能比較公式表の抜粋) |
| エンドポイントタイプ / Private API | [23 §2.2](docs/23-apigateway-rest-vs-http.md#22-エンドポイントタイプ) |
| ステージ / 自動デプロイ | [23 §2.4](docs/23-apigateway-rest-vs-http.md#24-開発デプロイ) |
| ペイロード形式 1.0 / 2.0 | [23 §4](docs/23-apigateway-rest-vs-http.md#4-lambda-に渡るイベントの違い) |

## 実装

| ディレクトリ | 方式 | API 種別 | AssumeRole |
|---|---|---|---|
| **[pattern-a-resource-policy/](pattern-a-resource-policy/README.md)** | IAM 認証 + リソースポリシー | REST API | 不要 |
| **[pattern-b-assume-role/](pattern-b-assume-role/README.md)** | AssumeRole + SigV4 | HTTP API | 必要 |

各ディレクトリの README に、構成図・デプロイ手順（自動／手動）・実装のポイント・確認用の実験を記載している。

---

## 結論（先に読む場合）

判断を決めているのは AWS 側の仕様 2 つ。

1. **クロスアカウントでは、呼び出し元のアイデンティティポリシーと API 側のリソースポリシーの「両方」が明示的 Allow でないと通らない**
   （[docs](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-authorization-flow.html)）
2. **HTTP API はリソースポリシーに対応していない**
   （[docs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-access-control-iam.html)）

したがって:

- **REST API** で呼び出し元が固定なら → **方式A**（構成要素が最小。B 側ログに A のロール ARN がそのまま届く）
- **HTTP API** なら → **方式B** 一択（1 と 2 の帰結として、他に手段がない）
- REST API でも、呼び出し元が増減する／B 側の API 以外のリソースも使う → **方式B**

詳細は [比較検討ドキュメント](docs/00-comparison.md)。

---

## クイックスタート

AWS アカウントが 2 つ必要。詳細は [docs/10-prerequisites.md](docs/10-prerequisites.md)。

> **同じアカウントを他の人と共有している場合**は、`config.env` の `PREFIX` を自分用の値にすること。
> スタック名・Lambda 関数名・API 名・ロググループがすべてこの値から派生するため、
> 各自が別の値にしていれば同時に検証してもリソースが衝突しない（[詳細](docs/10-prerequisites.md#4-prefix--複数人で同じアカウントを使う場合)）。

```bash
# 1. 設定
cp config.env.example config.env
$EDITOR config.env          # PREFIX・アカウントID・プロファイル名・リージョンを設定

# 2. プロファイルが正しいアカウントを指しているか確認（取り違え防止）
aws sts get-caller-identity --profile account-a
aws sts get-caller-identity --profile account-b

# 3. 方式A を試す
cd pattern-a-resource-policy
./deploy.sh                 # 3 ステップのデプロイを自動実行
./invoke.sh                 # 呼び出し結果を表示
./cleanup.sh                # 後片付け

# 4. 方式B を試す
cd ../pattern-b-assume-role
./deploy.sh
./invoke.sh
./cleanup.sh
```

### 両方を試すと見える違い

`invoke.sh` のレスポンスに含まれる `caller.accountId` を見比べる。

| | `caller.accountId` | `caller.userArn` |
|---|---|---|
| 方式A | **111111111111**（アカウントA） | A の Lambda 実行ロール |
| 方式B | **222222222222**（アカウントB） | B の `ApiCallerRole` + `RoleSessionName` |

方式B では identity がアカウント境界を越えない。これがリソースポリシー不要（＝ HTTP API で成立する）理由そのものであり、同時に「誰が呼んだかを追うには CloudTrail が要る」というデメリットの理由でもある。

---

## ディレクトリ構成

```
.
├── README.md
├── config.env.example
├── docs/
│   ├── 00-comparison.md              # 比較検討
│   ├── 10-prerequisites.md           # 共通の準備
│   ├── 20-iam-policies.md            # 用語解説: IAM ポリシーと権限評価
│   ├── 21-assume-role-sts.md         # 用語解説: AssumeRole と STS
│   ├── 22-sigv4.md                   # 用語解説: SigV4 署名
│   ├── 23-apigateway-rest-vs-http.md # 用語解説: REST API と HTTP API
│   └── 90-troubleshooting.md         # トラブルシューティング
├── articles/
│   └── aws-cross-account-apigateway.md   # Zenn 記事の下書き
├── scripts/
│   └── common.sh                 # 設定読み込み・PREFIX 解決・スタック名の組み立て
├── pattern-a-resource-policy/    # 方式A: REST API + リソースポリシー
│   ├── README.md
│   ├── account-b-api/            # B側: REST API + バックエンド Lambda
│   ├── account-a-caller/         # A側: 呼び出し元 Lambda
│   ├── deploy.sh / invoke.sh / cleanup.sh
└── pattern-b-assume-role/        # 方式B: AssumeRole + HTTP API
    ├── README.md
    ├── account-b-api/            # B側: HTTP API + AssumeRole 先ロール
    ├── account-a-caller/         # A側: 呼び出し元 Lambda
    └── deploy.sh / invoke.sh / cleanup.sh
```

## 使用技術

- AWS SAM（IaC）
- Python 3.12 / boto3・botocore・urllib3（すべて Lambda ランタイム同梱。追加パッケージなし）

## 解説記事

この検証内容を、AWS を触り始めた方向けに解説した記事の下書きを
[`articles/aws-cross-account-apigateway.md`](articles/aws-cross-account-apigateway.md) に置いています。

## ライセンス

[MIT License](LICENSE)
