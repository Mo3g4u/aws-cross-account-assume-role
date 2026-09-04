# クロスアカウント API 呼び出し方式の比較検討

**課題**: AWS アカウント A の Lambda から、アカウント B の API Gateway を呼び出したい。

| 項目 | 値 |
|---|---|
| 作成日 | 2026-09-04 |
| 対象 | Amazon API Gateway (REST API / HTTP API)、AWS Lambda、AWS IAM、AWS STS |
| 結論 | REST API なら **方式A（リソースポリシー）**、HTTP API なら **方式B（AssumeRole）** |

---

## 1. 前提となる仕様の確認

方式を選ぶ前に、AWS の仕様上の制約を 2 つ押さえておく必要がある。この 2 点が選択をほぼ決めてしまう。

### 制約1: クロスアカウントでは「両側」の明示的 Allow が必要

API Gateway の IAM 認証では、呼び出し元と API オーナーが同一アカウントか別アカウントかで評価ルールが変わる。

| 呼び出し元と API オーナー | 必要な Allow |
|---|---|
| 同一アカウント | アイデンティティポリシー **または** リソースポリシーの**どちらか**が明示的 Allow |
| **別アカウント** | アイデンティティポリシー **と** リソースポリシーの**両方**が明示的 Allow |

> If the caller and API owner are from separate accounts, both the IAM policies and the resource policy explicitly allow the caller to proceed.
> — [How API Gateway resource policies affect authorization workflow](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-authorization-flow.html)

「A 側で権限を付けたのに 403 になる」の原因はほぼこれ。片側だけでは絶対に通らない。

### 制約2: HTTP API はリソースポリシーに対応していない

> Resource policies aren't currently supported for HTTP APIs.
> — [Control access to HTTP APIs with IAM authorization in API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-access-control-iam.html)

制約1と組み合わせると、こうなる。

- HTTP API では B 側にリソースポリシーを置けない
- しかしクロスアカウントには両側の Allow が要る
- ∴ **呼び出し元の identity を「B アカウントの中の principal」にするしかない**
- ∴ **AssumeRole が必須**

これが方式B を選ぶ最大かつ現実的な理由。

---

## 2. 方式一覧

| # | 方式 | AssumeRole | 対応 API | 認証の主体 |
|---|---|---|---|---|
| **A** | IAM 認証 + リソースポリシー | 不要 | REST のみ | A アカウントの Lambda 実行ロール |
| **B** | AssumeRole + SigV4 | 必要 | REST / HTTP | B アカウントのロール（一時認証情報） |
| C | Lambda オーソライザー / API キー | 不要 | REST / HTTP | 独自トークン・共有鍵 |
| D | Private API + VPC エンドポイント | — | REST のみ | （ネットワーク層。A/B/C と併用） |

C と D は今回の主対象ではないが、判断材料として §5 で触れる。

---

## 3. 方式A: IAM 認証 + リソースポリシー

### 仕組み

```
[A: Lambda] --SigV4署名(Lambda実行ロールの認証情報)--> [B: REST API]
                                                          |
   A側: identity policy で execute-api:Invoke を Allow  ---+--- 両方の Allow が必要
   B側: resource policy で A のロールARNを Allow       ---+
```

Lambda は自分の実行ロールの認証情報でそのまま SigV4 署名する。追加の API 呼び出しは発生しない。B 側の API には「A アカウントのロール」の identity がそのまま届く。

### 評価

| 観点 | 評価 |
|---|---|
| 実装の単純さ | ◎ STS 呼び出しなし。認証情報のキャッシュ管理も不要 |
| レイテンシ | ◎ 追加のネットワークラウンドトリップなし |
| B 側での可視性 | ◎ `requestContext.identity.userArn` に **A 側の呼び出し元ロール ARN** がそのまま入る。誰が呼んだか B 側のログで直接わかる |
| 権限の管理場所 | △ A 側と B 側に分散する。両方直さないと変更が効かない |
| 呼び出し元が増えたとき | △ B 側リソースポリシーの `Principal` 配列を都度追加＋**API 再デプロイ**が必要 |
| HTTP API | ✗ 使えない |
| B 側の他リソース利用 | ✗ API 以外（S3、DynamoDB など）には使えない。個別に対応が必要 |

### 向いているケース

- REST API を使っている
- 呼び出し元アカウントが少数で固定的
- B 側のログで「A のどのロールが呼んだか」を素直に見たい

---

## 4. 方式B: AssumeRole + SigV4

### 仕組み

```
[A: Lambda] --(1) sts:AssumeRole--> [B: IAMロール]
            <-- 一時認証情報 --------┘
            --(2) SigV4署名(B のロールの一時認証情報)--> [B: HTTP API]
                                                          |
   B側: ロールの権限ポリシーで execute-api:Invoke を Allow -+
   (呼び出し元が B アカウント内の principal になるため、
    リソースポリシーは不要 = HTTP API でも成立する)
```

A の Lambda は STS で B のロールを引き受け、返ってきた一時認証情報で署名する。API から見た呼び出し元は **B アカウント内のロール**になる。

### 評価

| 観点 | 評価 |
|---|---|
| 実装の単純さ | △ STS 呼び出し＋一時認証情報のキャッシュ処理が要る |
| レイテンシ | △ 初回に STS 分（数十〜百 ms）が乗る。キャッシュすれば 2 回目以降は方式Aと同等 |
| B 側での可視性 | △ API に届くのは **B 側のロール ARN**。誰が引き受けたかは `RoleSessionName` と CloudTrail の `AssumeRole` イベントを突き合わせて追う |
| 権限の管理場所 | ◎ B 側のロール定義にほぼ集約できる。A 側は `sts:AssumeRole` 1 個だけ |
| 呼び出し元が増えたとき | ◎ B 側ロールの信頼ポリシーに追加するだけ。API の再デプロイ不要 |
| HTTP API | ◎ 使える（というより **これしかない**） |
| B 側の他リソース利用 | ◎ 同じロールに権限を足せば S3・DynamoDB なども同じ経路で呼べる |

### 向いているケース

- HTTP API を使っている（**必然的にこれ**）
- 呼び出し元が増減する / 複数アカウントから呼ばれる
- API 以外の B 側リソースにもアクセスする予定がある
- 第三者組織にアクセスを開放する（`ExternalId` による confused deputy 対策が使える）

---

## 5. 補助的な選択肢

### 方式C: Lambda オーソライザー / API キー

IAM を使わず、Bearer トークンや API キーで認証する。

- **利点**: アカウント境界を意識しなくてよい。AWS 外のクライアントとも同じ仕組みで扱える
- **欠点**: 鍵・トークンのローテーションと保管（Secrets Manager 等）が自前の運用負債になる。IAM の監査経路（CloudTrail、IAM Access Analyzer）から外れる
- **注意**: API キーは**認証の仕組みではない**。使用量プランのための識別子であり、単体を認可に使うのは誤用

AWS 内部同士の通信なら、IAM を使える場面でわざわざ選ぶ理由は薄い。

### 方式D: Private API + VPC エンドポイント

REST API を `PRIVATE` エンドポイントにし、VPC エンドポイント経由でのみ到達可能にする。

- これは**認証**ではなく**ネットワーク到達性**の話。方式A・B と排他ではなく**併用する**もの
- インターネットに API を露出させたくない要件があるなら追加する
- Private API はリソースポリシーが**必須**（付けないとデプロイできない）
- `aws:SourceVpce` / `aws:VpcSourceIp` 条件で絞り込む
- 代償: A 側 Lambda を VPC に配置する必要があり、NAT やコールドスタートの考慮が増える

---

## 6. 比較サマリ

| 観点 | 方式A（リソースポリシー） | 方式B（AssumeRole） |
|---|---|---|
| REST API | ◎ | ◎ |
| HTTP API | ✗ **不可** | ◎ |
| 実装の単純さ | ◎ | △ |
| レイテンシ | ◎ | △（キャッシュすれば ◎） |
| 権限の集約 | △ 両アカウントに分散 | ◎ B 側に集約 |
| 呼び出し元の追跡 | ◎ API に A のロール ARN が届く | △ CloudTrail との突合が必要 |
| 呼び出し元の追加 | △ リソースポリシー変更＋再デプロイ | ◎ 信頼ポリシー変更のみ |
| API 以外への横展開 | ✗ | ◎ |
| 追加の AWS API 呼び出し | なし | `sts:AssumeRole` |

---

## 7. 選定フロー

```
HTTP API を使う？
├─ はい ──────────────────────────────► 方式B（AssumeRole）※他に選択肢なし
└─ いいえ（REST API）
   │
   ├─ B 側の API 以外のリソースにもアクセスする？
   │  └─ はい ───────────────────────► 方式B
   │
   ├─ 呼び出し元アカウントが今後増える見込み？
   │  └─ はい ───────────────────────► 方式B
   │
   └─ いずれも いいえ ────────────────► 方式A（最小構成）

  ＋ インターネットに露出させたくない → 方式D（Private API）を併用
```

---

## 8. 結論と本リポジトリの方針

- **REST API + 呼び出し元が固定** なら方式A。構成要素が最も少なく、B 側ログでの追跡性も良い
- **HTTP API** なら方式B 一択。仕様上ほかに手段がない
- 迷ったら方式B。運用面（呼び出し元の増減、横展開）で効いてくるうえ、レイテンシの不利はキャッシュでほぼ消える

本リポジトリでは両方を実際にデプロイして挙動を確認できるようにする。

| ディレクトリ | 方式 | API 種別 |
|---|---|---|
| [`pattern-a-resource-policy/`](../pattern-a-resource-policy/README.md) | 方式A | REST API |
| [`pattern-b-assume-role/`](../pattern-b-assume-role/README.md) | 方式B | HTTP API |

方式B を HTTP API で組むのは、§1 の制約2 が「AssumeRole を選ぶ理由」そのものであり、両方を一度に確認できるため。方式B を REST API に対して行う場合の差分は [`pattern-b-assume-role/README.md`](../pattern-b-assume-role/README.md) の付録に記載する。

---

## 参考資料

- [How API Gateway resource policies affect authorization workflow](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-authorization-flow.html) — 制約1（両側 Allow）の根拠
- [Control access to HTTP APIs with IAM authorization in API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-access-control-iam.html) — 制約2（リソースポリシー非対応）の根拠
- [API Gateway resource policy examples](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-resource-policies-examples.html) — クロスアカウントのポリシー例
- [Creating a private API in Amazon API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-private-apis.html) — 方式D
