# 方式B: AssumeRole + SigV4（HTTP API）

アカウントA の Lambda が、まずアカウントB の IAM ロールを **AssumeRole** し、返ってきた一時認証情報で SigV4 署名して HTTP API を呼ぶ。

HTTP API は**リソースポリシーに対応していない**ため、クロスアカウントで IAM 認証を使うにはこの方式しかない。詳細は [比較検討ドキュメント §1](../docs/00-comparison.md#1-前提となる仕様の確認)。

前提の準備は [`../docs/10-prerequisites.md`](../docs/10-prerequisites.md) を先に済ませること。

---

## 1. 構成

```
┌─ アカウントA (呼び出し元) ────────┐   ┌─ アカウントB (API提供側) ─────────────────┐
│                                   │   │                                           │
│  CallerFunction (Lambda)          │   │   ApiCallerRole (IAM Role)                │
│    実行ロール                     │   │     信頼ポリシー: A の実行ロール ARN ──①  │
│      └ sts:AssumeRole ────────────┼─①┼──▶  権限ポリシー: execute-api:Invoke ──②  │
│                                   │   │            │                              │
│    一時認証情報で SigV4 署名 ─────┼─②┼────────────▼                              │
│                                   │   │   CrossAccountHttpApi (HTTP API)          │
│                                   │   │     Auth: AWS_IAM                         │
│                                   │   │     ※リソースポリシーは設定できない       │
│                                   │   │            │                              │
│                                   │   │            ▼                              │
│                                   │   │      ItemsFunction (Lambda)               │
└───────────────────────────────────┘   └───────────────────────────────────────────┘

  API から見た呼び出し元は【B アカウント内の ApiCallerRole】。
  identity がアカウント境界を越えないので、リソースポリシーが不要になる。
```

| ファイル | 役割 |
|---|---|
| [`account-b-api/template.yaml`](account-b-api/template.yaml) | B 側: HTTP API（IAM 認証）と AssumeRole 先の IAM ロール |
| [`account-b-api/src/app.py`](account-b-api/src/app.py) | B 側: 呼び出し元の identity を返す |
| [`account-a-caller/template.yaml`](account-a-caller/template.yaml) | A 側: 呼び出し元 Lambda と `sts:AssumeRole` 権限 |
| [`account-a-caller/src/app.py`](account-a-caller/src/app.py) | A 側: AssumeRole → キャッシュ → SigV4 署名 |

---

## 2. デプロイ

```bash
./deploy.sh
```

`ExternalId` を使う場合は環境変数で渡す。

```bash
EXTERNAL_ID=my-external-id ./deploy.sh
```

### デプロイ順序が固定な理由

方式B では **[1] A スタックを先に作らなければならない**。B 側ロールの信頼ポリシーに A のロール ARN を書くが、IAM は信頼ポリシーの principal が実在するかを検証するため、A のロールが存在しない状態で B をデプロイすると失敗する。

```
MalformedPolicyDocument: Invalid principal in policy
```

### 手動でやる場合

> 以下のスタック名は `config.env` の `PREFIX` から組み立てられる（例は `PREFIX=takeuchi`）。
> 同じアカウントを共有している場合は自分の `PREFIX` に読み替えること。
> 実際の名前は `deploy.sh` の実行時にバナーで表示される。

**[1/3] A スタック**

```bash
cd account-a-caller
sam deploy --stack-name takeuchi-xacct-b-caller \
  --profile account-a --region ap-northeast-1 \
  --capabilities CAPABILITY_IAM --resolve-s3 --no-confirm-changeset \
  --parameter-overrides AccountBId=222222222222
```

出力された `CallerRoleArn` を控える。

**[2/3] B スタック**

```bash
cd ../account-b-api
sam deploy --stack-name takeuchi-xacct-b-api \
  --profile account-b --region ap-northeast-1 \
  --capabilities CAPABILITY_IAM --resolve-s3 --no-confirm-changeset \
  --parameter-overrides CallerRoleArn=arn:aws:iam::111111111111:role/takeuchi-xacct-b-caller-CallerFunctionRole-XXXX
```

出力された `ApiEndpoint` と `ApiCallerRoleArn` を控える。

**[3/3] A スタック再デプロイ**

```bash
cd ../account-a-caller
sam deploy --stack-name takeuchi-xacct-b-caller \
  --profile account-a --region ap-northeast-1 \
  --capabilities CAPABILITY_IAM --resolve-s3 --no-confirm-changeset \
  --parameter-overrides \
    AccountBId=222222222222 \
    ApiEndpoint=https://xxxx.execute-api.ap-northeast-1.amazonaws.com/prod/items \
    AssumeRoleArn=arn:aws:iam::222222222222:role/takeuchi-xacct-b-api-ApiCallerRole-XXXX
```

---

## 3. 動作確認

```bash
./invoke.sh
```

```json
{
  "statusCode": 200,
  "endpoint": "https://xxxx.execute-api.ap-northeast-1.amazonaws.com/prod/items",
  "assumedRoleArn": "arn:aws:iam::222222222222:role/takeuchi-xacct-b-api-ApiCallerRole-XXXX",
  "roleSessionName": "takeuchi-xacct-b-caller-caller-1a2b3c4d",
  "credentialsFromCache": false,
  "response": {
    "message": "アカウントBのAPIに到達しました",
    "pattern": "B: HTTP API + IAM authentication via AssumeRole",
    "caller": {
      "accountId": "222222222222",
      "userArn": "arn:aws:sts::222222222222:assumed-role/takeuchi-xacct-b-api-ApiCallerRole-XXXX/takeuchi-xacct-b-caller-caller-1a2b3c4d",
      "callerId": "AROAYYYYYYYYYYYYYYYYY:takeuchi-xacct-b-caller-caller-1a2b3c4d"
    },
    "receivedBody": { "message": "hello from account A", "requestId": "..." }
  }
}
```

**方式A との決定的な違いがここに出る**。`caller.accountId` が **222222222222（アカウントB）** になっている。API から見た呼び出し元は B 自身のロールであり、アカウントA の情報は直接は現れない。

代わりに `userArn` の末尾にある **`RoleSessionName`（`takeuchi-xacct-b-caller-caller-1a2b3c4d`）**が、誰が引き受けたかを辿る唯一の手がかりになる。だからセッション名には意味のある値を入れる必要がある。

### 実験: 認証情報のキャッシュを確認する

続けてもう一度実行する。

```bash
./invoke.sh
```

同じ Lambda 実行環境が再利用されていれば `credentialsFromCache` が `true` になり、STS の呼び出しがスキップされているのがわかる。CloudWatch Logs にも `AssumeRole 実行:` の行が出なくなる。

---

## 4. 実装のポイント

### 4.1 B 側: HTTP API の IAM 認証

```yaml
CrossAccountHttpApi:
  Type: AWS::Serverless::HttpApi
  Properties:
    StageName: prod
    Auth:
      EnableIamAuthorizer: true
      DefaultAuthorizer: AWS_IAM
```

`EnableIamAuthorizer: true` と `DefaultAuthorizer: AWS_IAM` は**セットで指定する**。SAM は `EnableIamAuthorizer` が `true` でないと `DefaultAuthorizer: AWS_IAM` を受け付けない。

REST API 用の `Auth.ResourcePolicy` は、ここでは書いても効かない（HTTP API 非対応）。

### 4.2 B 側: 信頼ポリシーと権限ポリシー

ロールには 2 つのポリシーがあり、役割が違う。混同しやすいので整理しておく。

| ポリシー | 答える問い | 今回の中身 |
|---|---|---|
| 信頼ポリシー (`AssumeRolePolicyDocument`) | **誰が**このロールを引き受けられるか | A の Lambda 実行ロール ARN |
| 権限ポリシー (`Policies`) | 引き受けた後に**何ができる**か | この HTTP API への `execute-api:Invoke` |

```yaml
AssumeRolePolicyDocument:
  Version: '2012-10-17'
  Statement:
    - Effect: Allow
      Principal:
        AWS: !Ref CallerRoleArn
      Action: sts:AssumeRole
```

### 4.3 ExternalId（第三者に貸す場合）

自社内のアカウント間なら不要。**外部組織**にロールを引き受けさせる場合は付ける。

第三者（例: SaaS ベンダー）が複数の顧客のロールを引き受けている状況で、顧客 ID を知っただけの攻撃者がベンダーを騙して別顧客のロールを引き受けさせる、という混乱した代理人（confused deputy）攻撃を防ぐ。ベンダー側が顧客ごとに異なる `ExternalId` を提示しないと引き受けられなくなる。

```yaml
Condition:
  StringEquals:
    sts:ExternalId: !Ref ExternalId
```

### 4.4 A 側: 権限は sts:AssumeRole だけ

```yaml
Policies:
  - Statement:
      - Effect: Allow
        Action: sts:AssumeRole
        Resource: arn:aws:iam::222222222222:role/takeuchi-xacct-b-api-ApiCallerRole-XXXX
```

方式A と違い、A 側に `execute-api:Invoke` を書く必要はない。API を呼ぶ権限は **B 側のロールが持っている**。B 側の API が増えても A 側のポリシーは変えなくてよい ── これが「権限が B に集約される」ということ。

### 4.5 A 側: 一時認証情報のキャッシュ

```python
if _cache["credentials"] and time.time() < _cache["expires_at"] - REFRESH_MARGIN_SECONDS:
    return _cache["credentials"], True
```

- 一時認証情報はデフォルト 1 時間有効（`DurationSeconds=3600`）
- 毎回 `AssumeRole` すると STS のレイテンシ（数十〜百 ms）が全リクエストに乗り、STS のスロットリングにも当たりうる
- Lambda はコンテナを再利用するので、モジュールスコープの変数に持たせるだけでウォームスタート間で使い回せる
- 期限ぎりぎりで使うと実行中に切れるので、**マージン（ここでは 300 秒）を引いて**判定する

### 4.6 A 側: SigV4 署名

```python
SigV4Auth(credentials, "execute-api", API_REGION).add_auth(request)
```

一時認証情報にはセッショントークンが含まれるため、`SigV4Auth` が `X-Amz-Security-Token` ヘッダーを自動で付ける。方式A のコードとの差分は「どの認証情報を渡すか」だけで、署名処理そのものは同一。

---

## 5. 付録: 方式B を REST API に対して行う場合

REST API でも AssumeRole 方式は使える。呼び出し元が B アカウント内の principal になるため、この場合 **B 側のリソースポリシーは不要**（同一アカウント扱いになり、アイデンティティポリシーだけで通る）。

`account-b-api/template.yaml` の変更点:

```yaml
  # HTTP API を REST API に差し替える
  CrossAccountApi:
    Type: AWS::Serverless::Api
    Properties:
      StageName: prod
      EndpointConfiguration: REGIONAL
      Auth:
        DefaultAuthorizer: AWS_IAM
        # ResourcePolicy は不要（呼び出し元が同一アカウントの principal になるため）

  ApiCallerRole:
    Type: AWS::IAM::Role
    Properties:
      # 信頼ポリシーは変更なし
      Policies:
        - PolicyName: InvokeRestApi
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: execute-api:Invoke
                # ステージ/メソッド/パスの区切りが REST API の形式になる
                Resource: !Sub "arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${CrossAccountApi}/prod/POST/items"

  ItemsFunction:
    Properties:
      Events:
        PostItems:
          Type: Api          # HttpApi → Api
          Properties:
            RestApiId: !Ref CrossAccountApi   # ApiId → RestApiId
            Path: /items
            Method: post     # POST → post
```

`Outputs.ApiEndpoint` は `https://${CrossAccountApi}.execute-api.${AWS::Region}.amazonaws.com/prod/items` になる（HTTP API と同じ形）。

A 側のコードは**一切変更不要**。バックエンドの `src/app.py` だけ、identity の取得先が `requestContext.authorizer.iam` から `requestContext.identity` に変わる（[`../pattern-a-resource-policy/account-b-api/src/app.py`](../pattern-a-resource-policy/account-b-api/src/app.py) と同じ形）。

---

## 6. 後片付け

```bash
./cleanup.sh
```

削除対象のスタック名を表示したうえで確認を求める。同じアカウントを共有している場合、
他の人のスタックを消さないよう `PREFIX` が自分の値になっているか確認すること。

---

## 参考

- [Control access to HTTP APIs with IAM authorization in API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-access-control-iam.html)
- [HttpApiAuth (AWS SAM)](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-property-httpapi-httpapiauth.html)
- [How to use an external ID when granting access to your AWS resources to a third party](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html)
- [Working with payload format versions (HTTP API)](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html)
