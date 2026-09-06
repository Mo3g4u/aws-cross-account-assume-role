# トラブルシューティング

クロスアカウント API 呼び出しで実際に遭遇しやすいものを、症状から引けるように並べる。

---

## 403: `... is not authorized to perform: execute-api:Invoke on resource: ...`

最も多い。**どちら側の Allow が欠けているか**を切り分ける。

### 方式A の場合

クロスアカウントでは A 側のアイデンティティポリシーと B 側のリソースポリシーの**両方**が明示的 Allow である必要がある。片方だけでは通らない。

```bash
# B 側リソースポリシーの現状を確認
aws apigateway get-rest-api --rest-api-id <API_ID> \
  --profile account-b --region ap-northeast-1 \
  --query 'policy' --output text | python3 -c 'import sys,json;print(json.dumps(json.loads(sys.stdin.read().encode().decode("unicode_escape")),indent=2))'

# A 側 Lambda 実行ロールのポリシーを確認
aws iam list-role-policies --role-name <ROLE_NAME> --profile account-a
```

チェック項目:

- [ ] B 側リソースポリシーの `Principal` が A の**ロール ARN**（`arn:aws:iam::...:role/...`）になっているか。`assumed-role` 形式を書いていないか
- [ ] A 側ポリシーの `Resource` ARN のアカウント ID が、**A ではなく B** になっているか
- [ ] ステージ名・メソッド・パスが両側で一致しているか（`/prod/POST/items`）
- [ ] **リソースポリシー変更後に API を再デプロイしたか**（下記）

### 方式B の場合

- [ ] `sts:AssumeRole` は成功しているか（CloudWatch Logs に `AssumeRole 実行:` の行が出ているか）
- [ ] B 側ロールの**権限ポリシー**に `execute-api:Invoke` があるか（信頼ポリシーだけでは呼べない）
- [ ] その `Resource` ARN の API ID・ステージ・メソッド・パスが合っているか

---

## デプロイ失敗: `Caller provided credentials not allowed when resource policy is set`

方式A の B 側スタックが `AWS::ApiGateway::Deployment` の作成で失敗する。

```
CREATE_FAILED  AWS::ApiGateway::Deployment  CrossAccountApiDeployment...
  Resource handler returned message: "Caller provided credentials not allowed
  when resource policy is set (Service: ApiGateway, Status Code: 400 ...)"
```

**原因**: SAM は `AWS::Serverless::Api` に `Auth` を指定すると、[ApiAuth の `InvokeRole`](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-property-api-apiauth.html) の既定値 `CALLER_CREDENTIALS` を適用し、統合設定に次を埋め込む。

```json
"x-amazon-apigateway-integration": {
  "type": "aws_proxy",
  "credentials": "arn:aws:iam::*:user/*"     // ← これ
}
```

しかし API Gateway は「リソースポリシーが設定された API で、統合に呼び出し元の認証情報を使う」ことを許可していないため、デプロイ時に弾かれる。

**対処**: `Auth` に `InvokeRole: NONE` を明示する。

```yaml
Auth:
  DefaultAuthorizer: AWS_IAM
  InvokeRole: NONE          # ← 追加
  ResourcePolicy:
    CustomStatements: [...]
```

Lambda プロキシ統合の呼び出し許可は `AWS::Lambda::Permission`（SAM が自動生成する）で付与されるため、統合側に認証情報は不要。`NONE` が意味的にも正しい。

なお **HTTP API（方式B）ではこの問題は起きない**。`AWS::Serverless::HttpApi` に `InvokeRole` 相当の設定がなく、統合に `credentials` が入らないため。

## デプロイ失敗: `Value at 'description' failed to satisfy constraint`

`AWS::IAM::Role` の作成でこう落ちる。

```
1 validation error detected: Value at 'description' failed to satisfy constraint:
Member must satisfy regular expression pattern:
[\u0009\u000A\u000D\u0020-\u007E\u00A1-\u00FF]*
```

**原因**: IAM の `Description` は **ASCII / Latin-1 しか受け付けない**。正規表現が示す許容範囲はタブ・改行・復帰と `\u0020-\u007E`（印字可能 ASCII）、`\u00A1-\u00FF`（Latin-1 補助）のみで、**日本語は範囲外**。

**対処**: 説明は英語（ASCII）で書き、日本語は YAML コメントに置く。

```yaml
ApiCallerRole:
  Type: AWS::IAM::Role
  Properties:
    # 日本語の説明はコメントに置く
    Description: Role assumed by the Lambda in account A to invoke this HTTP API
```

### どの Description が制約を受けるか

同じ `Description:` でも、**AWS リソースのプロパティか、CloudFormation のメタデータか**で扱いが違う。

| 場所 | 日本語 | 備考 |
|---|---|---|
| `Resources.*.Properties.Description`（IAM ロール等） | **✗ 不可** | サービス側の文字種制約を受ける |
| テンプレート冒頭の `Description` | ✓ | CloudFormation のメタデータ |
| `Parameters.*.Description` | ✓ | 同上 |
| `Outputs.*.Description` | ✓（ただし後述） | 同上 |

`Outputs` の `Description` は CloudFormation 上は日本語で問題ないが、**SAM CLI がデプロイ後に表示する表で文字化けする**（`B ????? CallerRoleArn ???????? ARN` のようになる）。デプロイ結果を読む場所なので、本リポジトリでは ASCII にしてある。

## スタックが ROLLBACK_COMPLETE のまま再デプロイできない

CREATE に失敗したスタックは `ROLLBACK_COMPLETE` で残り、**そのままでは作り直せない**（CloudFormation の仕様）。再実行すると次のエラーになる。

```
Stack ... is in ROLLBACK_COMPLETE state and can not be updated.
```

削除してから作り直す。

```bash
aws cloudformation delete-stack --stack-name takeuchi-xacct-a-api \
  --profile account-b --region ap-northeast-1
aws cloudformation wait stack-delete-complete --stack-name takeuchi-xacct-a-api \
  --profile account-b --region ap-northeast-1
```

`deploy.sh` はこの状態を検出して自動で削除してから進むため、通常は手動対応は不要。

## 403 が消えない: リソースポリシーの再デプロイ忘れ（方式A）

REST API のリソースポリシーは、**変更しただけでは反映されない**。ステージへのデプロイが必要。

マネジメントコンソールで直接編集した場合は特に忘れやすい。

```bash
aws apigateway create-deployment \
  --rest-api-id <API_ID> --stage-name prod \
  --profile account-b --region ap-northeast-1
```

SAM/CloudFormation 経由なら通常は自動でデプロイが作られるが、期待どおり反映されたか不安なときは上記を手で叩けばよい。

---

## `{"message":"Missing Authentication Token"}`

**認証情報がない、という意味ではない**。ほとんどの場合、**そのパス/メソッドのルートが存在しない**。

- URL のパスが間違っている（`/items` のつもりが `/item`）
- ステージ名が抜けている（`.../items` ではなく `.../prod/items`）
- メソッドが違う（POST のルートに GET している）

まず URL を疑う。

---

## `{"message":"Not Found"}`（HTTP API）

HTTP API でルートにもステージにも一致しなかった場合はこのメッセージになる。REST API の `Missing Authentication Token` に相当する。やはりパス・ステージ・メソッドを確認する。

> If no routes match a request, API Gateway returns `{"message":"Not Found"}` to the client.
> — [Create routes for HTTP APIs in API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-routes.html)

なお HTTP API の `{"message":"Forbidden"}` は**認可の失敗**（IAM 認証で権限が足りない、実行 API エンドポイントが無効化されている等）で返るもので、ルート不一致とは別物。

---

## `MalformedPolicyDocument: Invalid principal in policy`

IAM ロールの**信頼ポリシー**に、実在しない principal ARN を書いている。

方式B で B スタックを先にデプロイしようとすると必ずこれになる。A スタック（＝ Lambda 実行ロール）を先に作ること。詳細は [10-prerequisites.md §5](10-prerequisites.md#5-デプロイ順序の考え方重要)。

A 側のロールを**作り直した**場合も同じエラーになりうる。B 側のポリシーを新しい ARN で更新する。

---

## ロールを再作成したら急に 403 になった

IAM ポリシーに書いたロール ARN は、保存時に内部の一意 ID（`AROA...`）に変換されて保持される。**ロールを削除して同名で作り直すと ID が変わる**ため、既存のポリシーが壊れる。

症状として、ポリシーの JSON を見ると `Principal` が ARN ではなく `AROAXXXXXXXXXXXXXXXXX` のような生の ID で表示される。

対処: 参照している側のポリシー（B 側のリソースポリシー／信頼ポリシー）を保存し直す。本リポジトリなら B スタックを再デプロイすればよい。

---

## `SignatureDoesNotMatch` / 署名エラー

- **署名した後にメソッド・URL・ヘッダー・ボディを書き換えていないか**。署名対象を変えると必ず失敗する
- 署名時のリージョンが **B 側 API のリージョン**になっているか（A 側のリージョンではない）
- サービス名が `execute-api` になっているか
- カスタムドメインを使っている場合、**そのドメイン名で署名**する必要がある（`Host` ヘッダーが署名対象のため）
- リダイレクトを自動追従していないか。追従先で署名が無効になる

---

## `ExpiredToken` / `The security token included in the request is expired`（方式B）

一時認証情報のキャッシュが期限切れのまま使われている。

- `DurationSeconds` と、キャッシュ判定のマージンを確認する。本リポジトリは 3600 秒に対して 300 秒のマージンを取っている
- ロールの最大セッション時間（`MaxSessionDuration`、デフォルト 1 時間）を超える `DurationSeconds` を指定していないか

---

## `AccessDenied: User ... is not authorized to perform: sts:AssumeRole`（方式B）

- A 側 Lambda 実行ロールに `sts:AssumeRole` があるか
- B 側ロールの**信頼ポリシー**に A のロール ARN があるか（**両方必要**）
- `ExternalId` を B 側で必須にしているのに、A 側で渡していない（またはその逆）

---

## 呼び出し元が誰なのか追跡できない（方式B）

方式B では API に届く identity が B 側のロールになるため、A 側の情報は直接見えない。追跡は次の 2 つで行う。

1. **`RoleSessionName`** — `userArn` の末尾に現れる。呼び出し元を識別できる値を入れておく
2. **CloudTrail の `AssumeRole` イベント** — B アカウントの CloudTrail に記録される。`requestParameters.roleSessionName` と `userIdentity` を突き合わせれば、どの A 側 principal が引き受けたかがわかる

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --profile account-b --region ap-northeast-1 --max-results 10
```

この追跡コストが、方式B の運用上の主なデメリット。

---

## デプロイ関連

### `sam deploy` が S3 バケットで失敗する

`--resolve-s3` を付けているか確認する。SAM が管理バケットを自動作成する。

### プロファイルを取り違えている

原因のわかりにくい 403 の温床。デプロイ前に確認する。

```bash
aws sts get-caller-identity --profile account-a
aws sts get-caller-identity --profile account-b
```

### スタック削除が失敗する

方式B では B 側ロールの信頼ポリシーが A のロールを参照しているため、**B から先に削除**する。`cleanup.sh` はこの順序になっている。

---

## ログの見方

```bash
# A 側（呼び出し元）
aws logs tail /aws/lambda/takeuchi-xacct-a-caller-caller \
  --follow --profile account-a --region ap-northeast-1

# B 側（API バックエンド）— requestContext 全体が出力されている
aws logs tail /aws/lambda/takeuchi-xacct-a-api-items \
  --follow --profile account-b --region ap-northeast-1
```

B 側のログには `requestContext` をそのまま出しているので、**実際にどんな identity が届いているか**を目で確認できる。403 の切り分けでも、まずここを見るのが早い。
