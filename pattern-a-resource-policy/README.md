# 方式A: REST API + IAM 認証 + リソースポリシー

アカウントA の Lambda が、**自分の実行ロールの認証情報のまま** SigV4 署名して、アカウントB の REST API を呼ぶ。AssumeRole は使わない。

前提の準備は [`../docs/10-prerequisites.md`](../docs/10-prerequisites.md) を先に済ませること。

---

## 1. 構成

```
┌─ アカウントA (呼び出し元) ────────┐      ┌─ アカウントB (API提供側) ──────────────┐
│                                   │      │                                        │
│  CallerFunction (Lambda)          │      │   CrossAccountApi (REST API)           │
│    実行ロール                     │      │     Auth: AWS_IAM                      │
│      └ execute-api:Invoke  ───────┼──①──┼──▶  ResourcePolicy                     │
│                                   │ SigV4│       Principal: A の実行ロール ARN ─②│
│  ※ AssumeRole なし                │      │            │                           │
│                                   │      │            ▼                           │
│                                   │      │      ItemsFunction (Lambda)            │
└───────────────────────────────────┘      └────────────────────────────────────────┘

   ① と ② の【両方】が明示的 Allow でないと 403（クロスアカウントの必須条件）
```

| ファイル | 役割 |
|---|---|
| [`account-b-api/template.yaml`](account-b-api/template.yaml) | B 側: REST API（IAM 認証 + リソースポリシー）とバックエンド Lambda |
| [`account-b-api/src/app.py`](account-b-api/src/app.py) | B 側: 呼び出し元の identity を返す |
| [`account-a-caller/template.yaml`](account-a-caller/template.yaml) | A 側: 呼び出し元 Lambda と execute-api:Invoke 権限 |
| [`account-a-caller/src/app.py`](account-a-caller/src/app.py) | A 側: SigV4 署名して HTTP リクエストを送る |

---

## 2. デプロイ

```bash
./deploy.sh
```

これで [`../docs/10-prerequisites.md`](../docs/10-prerequisites.md) §5 の 3 ステップが順に実行される。

### 手動でやる場合

> 以下のスタック名は `config.env` の `PREFIX` から組み立てられる（例は `PREFIX=takeuchi`）。
> 同じアカウントを共有している場合は自分の `PREFIX` に読み替えること。
> 実際の名前は `deploy.sh` の実行時にバナーで表示される。

**[1/3] A スタック** — まず Lambda 実行ロールを確定させる。この時点では B の API がまだ存在しないので、`execute-api:Invoke` はアカウントB 配下全体という暫定スコープになる。

```bash
cd account-a-caller
sam deploy --stack-name takeuchi-xacct-a-caller \
  --profile account-a --region ap-northeast-1 \
  --capabilities CAPABILITY_IAM --resolve-s3 --no-confirm-changeset \
  --parameter-overrides AccountBId=222222222222
```

出力された `CallerRoleArn` を控える。

**[2/3] B スタック** — 控えたロール ARN をリソースポリシーの `Principal` に渡す。

```bash
cd ../account-b-api
sam deploy --stack-name takeuchi-xacct-a-api \
  --profile account-b --region ap-northeast-1 \
  --capabilities CAPABILITY_IAM --resolve-s3 --no-confirm-changeset \
  --parameter-overrides CallerRoleArn=arn:aws:iam::111111111111:role/takeuchi-xacct-a-caller-CallerFunctionRole-XXXX
```

出力された `ApiEndpoint` と `ApiInvokeArn` を控える。

**[3/3] A スタック再デプロイ** — エンドポイントを環境変数に入れ、権限を実際の API まで絞り込む。

```bash
cd ../account-a-caller
sam deploy --stack-name takeuchi-xacct-a-caller \
  --profile account-a --region ap-northeast-1 \
  --capabilities CAPABILITY_IAM --resolve-s3 --no-confirm-changeset \
  --parameter-overrides \
    AccountBId=222222222222 \
    ApiEndpoint=https://xxxx.execute-api.ap-northeast-1.amazonaws.com/prod/items \
    ApiInvokeArn=arn:aws:execute-api:ap-northeast-1:222222222222:xxxx/prod/POST/items
```

---

## 3. 動作確認

```bash
./invoke.sh
```

成功すると、A の Lambda が B の API から受け取ったレスポンスがそのまま返る。

```json
{
  "statusCode": 200,
  "endpoint": "https://xxxx.execute-api.ap-northeast-1.amazonaws.com/prod/items",
  "response": {
    "message": "アカウントBのAPIに到達しました",
    "pattern": "A: REST API + IAM authentication + resource policy",
    "caller": {
      "accountId": "111111111111",
      "userArn": "arn:aws:sts::111111111111:assumed-role/takeuchi-xacct-a-caller-CallerFunctionRole-XXXX/takeuchi-xacct-a-caller-caller",
      "caller": "AROAXXXXXXXXXXXXXXXXX:takeuchi-xacct-a-caller-caller",
      "sourceIp": "..."
    },
    "receivedBody": { "message": "hello from account A", "requestId": "..." }
  }
}
```

**ここが方式A の特徴**: `caller.accountId` が **111111111111（アカウントA）**、`userArn` が **A 側の Lambda 実行ロール**になっている。B 側のログを見るだけで「どのアカウントの誰が呼んだか」がわかる。方式B ではここが B 側のロールに変わる（[比較検討ドキュメント §4](../docs/00-comparison.md#4-方式b-assumerole--sigv4) 参照）。

---

## 4. 実装のポイント

### 4.1 B 側: リソースポリシー

```yaml
Auth:
  DefaultAuthorizer: AWS_IAM
  ResourcePolicy:
    CustomStatements:
      - Effect: Allow
        Principal:
          AWS: !Ref CallerRoleArn
        Action: execute-api:Invoke
        Resource:
          - execute-api:/prod/POST/items
```

- `DefaultAuthorizer: AWS_IAM` で全メソッドが SigV4 署名必須になる
- `Resource` の `execute-api:/prod/POST/items` は**簡略構文**。保存時に API Gateway がリージョン・アカウント ID・API ID を補って完全な ARN に展開する。全体を許可するなら `execute-api:/*`
- `Principal` にはロール ARN（`arn:aws:iam::...:role/...`）を書く。届く identity は `assumed-role` 形式（`arn:aws:sts::...:assumed-role/...`）だが、ポリシーに書くのは **role ARN の方**

### 4.2 A 側: アイデンティティポリシー

```yaml
Policies:
  - Statement:
      - Effect: Allow
        Action: execute-api:Invoke
        Resource: arn:aws:execute-api:ap-northeast-1:222222222222:xxxx/prod/POST/items
```

ARN の構造は `arn:aws:execute-api:{region}:{api-owner-account}:{api-id}/{stage}/{method}/{path}`。アカウント ID は **API を持っている B 側**であって、A 側ではない。ここを間違えやすい。

### 4.3 A 側: SigV4 署名

```python
request = AWSRequest(method="POST", url=API_ENDPOINT, data=body,
                     headers={"Content-Type": "application/json"})
SigV4Auth(_credentials.get_frozen_credentials(), "execute-api", API_REGION).add_auth(request)
response = _http.request("POST", API_ENDPOINT, body=body, headers=dict(request.headers))
```

- サービス名は `execute-api` 固定
- リージョンは **B 側 API のリージョン**
- `get_frozen_credentials()` は毎回呼ぶ。Lambda 実行ロールの認証情報は自動ローテーションされるため、起動時の値を握り続けてはいけない
- 署名は「メソッド・URL・ヘッダー・ボディ」に対して行われる。**署名後にこれらを書き換えると 403**
- `boto3` / `botocore` / `urllib3` は Lambda の Python ランタイム同梱。追加パッケージは不要

---

## 5. 挙動を確かめる実験

理解を確認するために、わざと壊してみるとよい。

### 実験1: B 側リソースポリシーを外す → 403

`account-b-api/template.yaml` の `ResourcePolicy` ブロックをコメントアウトして B を再デプロイする。

```
{"Message":"User: arn:aws:sts::111111111111:assumed-role/... is not authorized to perform: execute-api:Invoke on resource: ..."}
```

A 側の権限は残っているのに 403 になる。これが「クロスアカウントは両側の Allow が必須」の実演。

### 実験2: A 側の権限を外す → 403

逆に `account-a-caller/template.yaml` の `Policies` を削って A を再デプロイしても、同じく 403 になる。

### 実験3: 同一アカウントなら片側で足りる

A と B を同じアカウントにすると、どちらか片方の Allow だけで通る。クロスアカウントとの評価ルールの違いがここに出る。

---

## 6. この方式の限界

| 限界 | 内容 |
|---|---|
| HTTP API では使えない | HTTP API はリソースポリシー非対応。[方式B](../pattern-b-assume-role/README.md) に移る必要がある |
| 呼び出し元の追加が重い | `Principal` 配列に足したうえで API の再デプロイが要る |
| API 以外に横展開できない | B 側の S3 や DynamoDB を触りたくなったら、それぞれ別途クロスアカウント設定が必要 |

---

## 7. 後片付け

```bash
./cleanup.sh
```

削除対象のスタック名を表示したうえで確認を求める。同じアカウントを共有している場合、
他の人のスタックを消さないよう `PREFIX` が自分の値になっているか確認すること。

---

## 参考

- [How API Gateway resource policies affect authorization workflow](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-authorization-flow.html)
- [API Gateway resource policy examples](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-resource-policies-examples.html)
- [Resource policy example for AWS SAM](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-controlling-access-to-apis-resource-policies.html)
