# API Gateway: REST API と HTTP API の違い

**扱う用語**: REST API / HTTP API / WebSocket API / エンドポイントタイプ / ステージ / ルート・メソッド / ペイロード形式 / 統合 / オーソライザー

---

## 1. API Gateway には 3 種類ある

| 種類 | 内部 API 名 | 位置づけ |
|---|---|---|
| **REST API** | API Gateway v1 (`apigateway`) | 最初からある高機能版。API 管理機能が揃っている |
| **HTTP API** | API Gateway v2 (`apigatewayv2`) | 2019 年登場。機能を絞って低コスト・低レイテンシに |
| WebSocket API | API Gateway v2 (`apigatewayv2`) | 双方向通信用。今回は対象外 |

**HTTP API は REST API の後継ではない**。「REST API から機能を削って安くしたもの」であり、両者は併存している。名前が紛らわしいが、REST API も HTTP API もどちらも HTTP で RESTful な API を作るためのもの。

CloudFormation / SAM でも別リソースになる。

| | REST API | HTTP API |
|---|---|---|
| SAM | `AWS::Serverless::Api` | `AWS::Serverless::HttpApi` |
| CloudFormation | `AWS::ApiGateway::RestApi` | `AWS::ApiGatewayV2::Api` |
| SAM のイベント型 | `Type: Api` / `RestApiId` | `Type: HttpApi` / `ApiId` |

---

## 2. 機能比較（公式表の抜粋）

出典: [Choose between REST APIs and HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html)

### 2.1 認可 ── 今回の検証で決定的な部分

| 認可オプション | REST API | HTTP API |
|---|---|---|
| IAM 認証 | ✅ | ✅ |
| **リソースポリシー** | ✅ | **❌** |
| Lambda オーソライザー | ✅ | ✅ |
| JWT オーソライザー | ❌ | ✅ |
| Amazon Cognito | ✅ | ✅（JWT オーソライザー経由） |

**リソースポリシーの行が今回の方式選択をほぼ決めている。** IAM 認証自体はどちらも使えるが、クロスアカウントには B 側での明示的 Allow が要り、その手段がリソースポリシーしかない。HTTP API ではそれが使えないため、AssumeRole で identity を B 側に移すしかなくなる。

詳細は [00-comparison.md §1](00-comparison.md#1-前提となる仕様の確認) と [20-iam-policies.md §5.4](20-iam-policies.md#54-方式bではなぜリソースポリシーが要らないのか)。

### 2.2 エンドポイントタイプ

| | REST API | HTTP API |
|---|---|---|
| エッジ最適化（CloudFront 経由） | ✅ | ❌ |
| リージョナル | ✅ | ✅ |
| **プライベート**（VPC エンドポイント経由） | ✅ | ❌ |

**Private API を作れるのは REST API だけ**。「インターネットに露出させない」要件がある場合、HTTP API では実現できない（[00-comparison.md](00-comparison.md) の方式D）。

なお、**バックエンドへのプライベート統合**（VPC 内の NLB / ALB / Cloud Map に繋ぐ）は両方できる。「API の入口が private か」と「API の出口が private か」は別の話なので混同しないこと。

### 2.3 API 管理

| | REST API | HTTP API |
|---|---|---|
| API キー | ✅ | ❌ |
| 使用量プラン / クライアント別レート制限 | ✅ | ❌ |
| カスタムドメイン | ✅ | ✅ |

API キーと使用量プランは REST API 専用。ただし**API キーは認証の仕組みではない**（使用量の識別子）ので、認可の代替としては使えない。

### 2.4 開発・デプロイ

| | REST API | HTTP API |
|---|---|---|
| ユーザー主導のデプロイ | ✅ | ✅ |
| **自動デプロイ** | ❌ | ✅ |
| キャッシュ | ✅ | ❌ |
| リクエスト検証 | ✅ | ❌ |
| リクエストボディの変換（マッピングテンプレート） | ✅ | ❌ |
| リクエストパラメータの変換 | ✅ | ✅ |
| カナリアリリース | ✅ | ❌ |
| カスタムゲートウェイレスポンス | ✅ | ❌ |
| コンソールからのテスト実行 | ✅ | ❌ |

**「自動デプロイ」の行は運用上効いてくる**。REST API は設定変更後にステージへデプロイしないと反映されないが、HTTP API は既定で自動デプロイされる。

これが「REST API のリソースポリシーを変えたのに反映されない」というハマりどころの原因（→ [90-troubleshooting.md](90-troubleshooting.md)）。

### 2.5 セキュリティ・監視

| | REST API | HTTP API |
|---|---|---|
| AWS WAF | ✅ | ❌ |
| mTLS（相互 TLS） | ✅ | ✅ |
| CloudWatch メトリクス / アクセスログ | ✅ | ✅ |
| **実行ログ** | ✅ | ❌ |
| X-Ray トレーシング | ✅ | ❌ |

実行ログ（execution log）は、API Gateway 内部の処理ステップを詳細に記録するもの。認可の失敗理由を追うときに有用だが、**HTTP API にはない**。HTTP API のトラブルシュートはアクセスログとバックエンド側のログが頼りになる。

本リポジトリで B 側の Lambda に `requestContext` を丸ごと出力させているのは、この差を埋めるため。

### 2.6 コスト

HTTP API は REST API より大幅に安い（リクエスト単価でおおむね数分の 1）。ただし正確な金額はリージョンと時期で変わるため、[API Gateway の料金ページ](https://aws.amazon.com/api-gateway/pricing/)で確認すること。

---

## 3. 構造の違い

### 3.1 REST API: リソース + メソッド

```
REST API
└── リソース /items          （パスの階層構造を持つ）
    ├── メソッド POST        （メソッドごとに設定）
    │   ├── メソッドリクエスト   （認可・検証）
    │   ├── 統合リクエスト       （バックエンドへの変換）
    │   ├── 統合レスポンス
    │   └── メソッドレスポンス
    └── メソッド GET
```

リクエスト・レスポンスの各段で変換を挟める。柔軟だが設定項目が多い。

### 3.2 HTTP API: ルート

```
HTTP API
└── ルート "POST /items"     （メソッド + パスで 1 つの単位）
    └── 統合                  （バックエンド）
```

「ルート」という 1 つの単位にまとまっており、シンプル。`$default` ルート（どれにも一致しないリクエストの受け皿）も使える。

SAM のテンプレートでこの差が表れる。

```yaml
# REST API
Events:
  PostItems:
    Type: Api
    Properties:
      RestApiId: !Ref CrossAccountApi
      Path: /items
      Method: post          # 小文字

# HTTP API
Events:
  PostItems:
    Type: HttpApi
    Properties:
      ApiId: !Ref CrossAccountHttpApi
      Path: /items
      Method: POST          # 大文字
```

---

## 4. Lambda に渡るイベントの違い

**同じ Lambda コードがそのまま動くとは限らない。** ここは実装で直接影響する。

| | REST API | HTTP API |
|---|---|---|
| ペイロード形式 | 1.0 のみ | 2.0（既定）または 1.0 |
| HTTP メソッド | `event["httpMethod"]` | `event["requestContext"]["http"]["method"]` |
| パス | `event["path"]` | `event["rawPath"]` |
| **IAM 認証の呼び出し元情報** | `event["requestContext"]["identity"]` | `event["requestContext"]["authorizer"]["iam"]` |
| ソース IP | `requestContext.identity.sourceIp` | `requestContext.http.sourceIp` |
| Cookie | `headers` に含まれる | `cookies` 配列 |
| 重複ヘッダー | `multiValueHeaders` | `headers` にカンマ区切りで結合 |
| レスポンス | `statusCode` 必須 | 省略時は 200 + JSON として推測 |

本リポジトリの B 側ハンドラが方式A と方式B で違うのは、主にこの行の差による。

```python
# 方式A（REST API）
identity = event["requestContext"]["identity"]
identity.get("userArn")     # arn:aws:sts::111111111111:assumed-role/...

# 方式B（HTTP API）
iam = event["requestContext"]["authorizer"]["iam"]
iam.get("userArn")          # arn:aws:sts::222222222222:assumed-role/...
```

両方のハンドラで `requestContext` を丸ごとログ出力しているので、実際の構造は CloudWatch Logs で確認できる。

```bash
aws logs tail /aws/lambda/takeuchi-xacct-b-api-items --follow \
  --profile account-b --region ap-northeast-1
```

---

## 5. SAM での IAM 認証の書き方の違い

```yaml
# REST API
Auth:
  DefaultAuthorizer: AWS_IAM
  ResourcePolicy:                 # ← HTTP API では書けない
    CustomStatements: [...]

# HTTP API
Auth:
  EnableIamAuthorizer: true       # ← これを true にしないと
  DefaultAuthorizer: AWS_IAM      #    AWS_IAM を指定できない
```

HTTP API では `EnableIamAuthorizer: true` と `DefaultAuthorizer: AWS_IAM` を**セットで**指定する。前者が無いと SAM の Transform でエラーになる。

Transform 後はどちらも OpenAPI 定義の中で同じ形になる。

```json
"securitySchemes": {
  "AWS_IAM": {
    "type": "apiKey",
    "name": "Authorization",
    "in": "header",
    "x-amazon-apigateway-authtype": "awsSigv4"
  }
}
```

`x-amazon-apigateway-authtype: awsSigv4` が「SigV4 署名を要求する」という宣言（→ [22-sigv4.md](22-sigv4.md)）。認可の仕組み自体は REST API も HTTP API も同じで、**違うのは「誰を許すか」を書く場所があるかどうか**だけ。

---

## 6. どちらを選ぶか

```
以下のいずれかが必要？
├─ リソースポリシー（クロスアカウントを B 側で制御したい）
├─ Private エンドポイント（インターネットに出したくない）
├─ API キー / 使用量プラン
├─ AWS WAF
├─ リクエスト検証・ボディ変換（マッピングテンプレート）
├─ キャッシュ / カナリアリリース
└─ X-Ray / 実行ログ
   │
   ├─ はい 1 つでも ──▶ REST API
   └─ いいえ ─────────▶ HTTP API（安く・速く・設定が少ない）
```

公式ガイドの表現もこれに沿っている。

> Choose REST APIs if you need features such as API keys, per-client throttling, request validation, AWS WAF integration, or private API endpoints. Choose HTTP APIs if you don't need the features included with REST APIs.

### 今回の検証への当てはめ

- 方式A は「B 側で呼び出し元を制御する」＝リソースポリシーを使うので、**REST API でしか成立しない**
- 方式B は identity を B 側に移すので、**どちらでも成立する**。本リポジトリでは HTTP API を選んだ理由を示すため HTTP API を使っている（REST API 版の差分は [pattern-b-assume-role/README.md §5](../pattern-b-assume-role/README.md) に記載）

---

## 参考

- [Choose between REST APIs and HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html)
- [Working with AWS Lambda proxy integrations for HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html)
- [Control access to HTTP APIs with IAM authorization](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-access-control-iam.html)
- [API endpoint types for REST APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-api-endpoint-types.html)
