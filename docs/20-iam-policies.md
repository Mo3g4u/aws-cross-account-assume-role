# IAM ポリシーと権限評価

**扱う用語**: アイデンティティベースポリシー / リソースベースポリシー / 信頼ポリシー / 権限ポリシー / Principal / ARN / 明示的 Deny / 暗黙の Deny / クロスアカウントの両側 Allow

---

## 1. AWS の認可は「リクエスト単位」で決まる

AWS へのすべてのリクエストは、次の情報の組み合わせとして評価される。

| 要素 | 意味 | 今回の例 |
|---|---|---|
| **Principal** | 誰が | `arn:aws:sts::111111111111:assumed-role/CallerFunctionRole/xxx` |
| **Action** | 何をしようとしているか | `execute-api:Invoke` |
| **Resource** | どれに対して | `arn:aws:execute-api:ap-northeast-1:222222222222:abc123/prod/POST/items` |
| **Condition** | どんな文脈で | `aws:SourceIp`, `sts:ExternalId`, `aws:SourceVpce` など |

IAM は、この 4 要素に対して**適用されるすべてのポリシー**を集めて評価し、許可するかどうかを決める。「ロールに権限がある」という状態は存在せず、常に「このリクエストが許可されるか」だけが問われる。

---

## 2. ポリシーの種類

今回の検証で直接関係するのは上 3 つ。

| 種類 | どこに付くか | `Principal` 要素 | 答える問い |
|---|---|---|---|
| **アイデンティティベースポリシー** | IAM ユーザー / グループ / **ロール** | **書かない** | この主体は何ができるか |
| **リソースベースポリシー** | リソース（API、S3 バケット等） | **必須** | このリソースは誰に使わせるか |
| **信頼ポリシー** | IAM **ロール** | **必須** | このロールは誰が引き受けられるか |
| 権限境界 | IAM ユーザー / ロール | 書かない | 上限として何を超えさせないか |
| SCP（Organizations） | OU / アカウント | 書かない | 組織として何を禁止するか |
| セッションポリシー | AssumeRole 時に動的に渡す | 書かない | このセッションに限って何を許すか |

**`Principal` 要素を書くかどうか**が最大の見分け方。ポリシー単体を見て「誰が」が書いてあればリソース側、書いていなければ主体側に付くポリシーだと判断できる。

### 2.1 アイデンティティベースポリシー

主体（今回は Lambda 実行ロール）に付ける。付けた相手そのものが Principal なので、ポリシー内に `Principal` は書かない。

```yaml
# pattern-a-resource-policy/account-a-caller/template.yaml
Policies:
  - Statement:
      - Sid: InvokeCrossAccountApi
        Effect: Allow
        Action: execute-api:Invoke
        Resource: arn:aws:execute-api:ap-northeast-1:222222222222:abc123/prod/POST/items
```

付け方は 2 通りある。

- **マネージドポリシー** — 独立したリソース。複数の主体に付け替えられる。AWS 管理（`AWSLambdaBasicExecutionRole` など）と顧客管理がある
- **インラインポリシー** — 主体に埋め込む。1 対 1 で、主体を消すと一緒に消える

SAM の `Policies:` は既定でインラインポリシーとしてロールに埋め込まれる（Transform 後に `AWS::IAM::Role` の `Policies` プロパティになる）。

### 2.2 リソースベースポリシー

リソース側に付ける。「誰に使わせるか」を書くので `Principal` が必須。

リソースベースポリシーを持てるサービスは限られている。代表例:

| サービス | 名称 |
|---|---|
| API Gateway（**REST API のみ**） | リソースポリシー |
| Lambda | リソースベースポリシー（関数ポリシー） |
| S3 | バケットポリシー |
| KMS | キーポリシー |
| SQS / SNS | キューポリシー / トピックポリシー |
| IAM ロール | **信頼ポリシー**（後述） |

```yaml
# pattern-a-resource-policy/account-b-api/template.yaml
ResourcePolicy:
  CustomStatements:
    - Effect: Allow
      Principal:
        AWS: arn:aws:iam::111111111111:role/CallerFunctionRole
      Action: execute-api:Invoke
      Resource:
        - execute-api:/prod/POST/items
```

**API Gateway リソースポリシー固有の注意点**:

- **REST API 専用**。HTTP API は非対応（→ [23-apigateway-rest-vs-http.md](23-apigateway-rest-vs-http.md)）
- `Resource` に**簡略構文**が使える。`execute-api:/prod/POST/items` と書くと、保存時に API Gateway がリージョン・アカウント ID・API ID を補って完全な ARN に展開する
- **変更しただけでは効かない。ステージへの再デプロイが必要**

### 2.3 信頼ポリシー

IAM ロールに付く**リソースベースポリシーの一種**。ロールというリソースに対して「誰が引き受けられるか」を書く。

```yaml
# pattern-b-assume-role/account-b-api/template.yaml
AssumeRolePolicyDocument:
  Version: '2012-10-17'
  Statement:
    - Effect: Allow
      Principal:
        AWS: arn:aws:iam::111111111111:role/CallerFunctionRole
      Action: sts:AssumeRole
```

ロールには**性質の違う 2 つのポリシー**が付く。混同しやすいので必ず区別すること。

| | 信頼ポリシー | 権限ポリシー |
|---|---|---|
| CloudFormation のプロパティ | `AssumeRolePolicyDocument` | `Policies` / `ManagedPolicyArns` |
| 答える問い | **誰が**引き受けられるか | 引き受けた後**何ができる**か |
| 分類 | リソースベース | アイデンティティベース |
| `Principal` | 必須 | 書かない |
| `Action` | `sts:AssumeRole` | `execute-api:Invoke` など |

方式B ではこの 2 つを両方書いている。片方だけでは動かない。

- 信頼ポリシーだけ → 引き受けられるが、API を呼ぶ権限がない
- 権限ポリシーだけ → そもそも引き受けられない（`AccessDenied`）

---

## 3. Principal の書き方

```json
"Principal": { "AWS": "arn:aws:iam::111111111111:role/MyRole" }   // 特定のロール
"Principal": { "AWS": "arn:aws:iam::111111111111:user/alice" }    // 特定のユーザー
"Principal": { "AWS": "arn:aws:iam::111111111111:root" }          // アカウント（後述）
"Principal": { "AWS": "111111111111" }                            // 上と同じ意味
"Principal": { "Service": "lambda.amazonaws.com" }                // AWS サービス
"Principal": "*"                                                  // 誰でも（Condition 必須）
```

### 3.1 ロール ARN と assumed-role ARN は別物

ここは実際によく間違える。

| 用途 | 形式 | 例 |
|---|---|---|
| **ポリシーに書く** | IAM のロール ARN | `arn:aws:iam::111111111111:role/MyRole` |
| **ログに現れる** | STS のセッション ARN | `arn:aws:sts::111111111111:assumed-role/MyRole/session-name` |

サービス名が `iam` と `sts` で違い、`role/` と `assumed-role/` でも違う。

**ポリシーの `Principal` には必ず前者（`iam` / `role/`）を書く**。CloudWatch Logs で見た `assumed-role` 形式をそのままコピーしてポリシーに貼ると、一致せず 403 になる。

なぜ 2 つあるのか。ロールは「引き受けられる器」であり、実際にリクエストを出すのは「そのロールを引き受けた一時的なセッション」だから。ポリシーは器を指定し、ログには実際に動いたセッションが記録される。

### 3.2 `:root` は「root ユーザー」ではない

```json
"Principal": { "AWS": "arn:aws:iam::111111111111:root" }
```

これは「アカウント 111111111111 の root ユーザーだけ」という意味では**ない**。「**アカウント 111111111111 の IAM 管理者に判断を委任する**」という意味になる。

このとき実際にアクセスできるのは、A アカウント側でアイデンティティポリシーによって明示的に許可された主体だけ。つまり「B は A アカウントを信頼する。A の中の誰に許すかは A が決める」という委任になる。

- **利点**: A 側でロールを作り直しても B 側のポリシーを直さなくてよい
- **欠点**: A 側の管理次第で、意図しない主体からもアクセスされうる

本リポジトリでは学習目的で範囲を明示するため、ロール ARN を直接指定している。

### 3.3 一意 ID 化 ── ロールを作り直すと壊れる

ポリシーの `Principal` にロール ARN を書いて保存すると、AWS は内部でロールの**一意 ID**（`AROA...` で始まる文字列）に変換して保持する。

このため、**ロールを削除して同名で作り直すと ID が変わり、既存のポリシーが壊れる**。症状として、ポリシーの JSON を表示すると `Principal` が ARN ではなく `AROAXXXXXXXXXXXXXXXXX` という生の ID で表示される。

対処は、参照している側のポリシーを保存し直すこと（本リポジトリなら B スタックの再デプロイ）。

---

## 4. ARN の構造

```
arn:partition:service:region:account-id:resource-id
```

| 部分 | 意味 | 例 |
|---|---|---|
| `partition` | 商用 / 中国 / GovCloud | `aws`, `aws-cn`, `aws-us-gov` |
| `service` | サービス名 | `execute-api`, `iam`, `sts`, `lambda` |
| `region` | リージョン | `ap-northeast-1`（IAM は空） |
| `account-id` | アカウント ID | `222222222222` |
| `resource-id` | サービスごとの形式 | `abc123/prod/POST/items` |

### 4.1 execute-api の ARN

```
arn:aws:execute-api:ap-northeast-1:222222222222:abc123/prod/POST/items
                    ^^^^^^^^^^^^^^ ^^^^^^^^^^^^ ^^^^^^ ^^^^ ^^^^ ^^^^^
                    │              │            │      │    │    └ パス
                    │              │            │      │    └───── HTTP メソッド
                    │              │            │      └────────── ステージ名
                    │              │            └───────────────── API ID
                    │              └────────────────────────────── ★ API を持つアカウント（B）
                    └───────────────────────────────────────────── API のリージョン
```

**アカウント ID は API を所有する B 側**であって、呼び出し元の A 側ではない。ここを A のアカウント ID にしてしまうのは頻出のミス。

ワイルドカードも使える。

```
arn:aws:execute-api:ap-northeast-1:222222222222:*/*/*/*        # B の全 API
arn:aws:execute-api:ap-northeast-1:222222222222:abc123/prod/*  # prod ステージの全メソッド・全パス
```

本リポジトリの A 側テンプレートは、B がまだ存在しない 1 ステップ目では前者の広い指定を使い、3 ステップ目で実際の API ARN に絞り込んでいる。

### 4.2 IAM と STS の ARN

```
arn:aws:iam::111111111111:role/MyRole                        # ロール本体（リージョンなし）
arn:aws:sts::111111111111:assumed-role/MyRole/session-name   # 引き受けた後のセッション
```

IAM はグローバルサービスなので、ARN の region 部分が**空**になる（`::` と 2 つ続く）。

---

## 5. 権限評価ロジック

### 5.1 基本原則

```
1. 明示的な Deny があるか？        → あれば 拒否（何があっても覆らない）
2. 明示的な Allow があるか？       → あれば 許可
3. どちらもない                    → 拒否（暗黙の Deny）
```

**デフォルトは拒否**。何も書かなければ何もできない。そして `Deny` は常に `Allow` に優先する。

### 5.2 同一アカウント vs クロスアカウント

ここが今回の検証の核心。**同じ「IAM 認証」でも、アカウントをまたぐかどうかで必要な条件が変わる**。

```
【同一アカウント】 どちらか一方の明示的 Allow で足りる（OR）

   アイデンティティポリシー ─┐
                             ├─→ どちらかが Allow なら許可
   リソースポリシー ─────────┘


【クロスアカウント】 両方の明示的 Allow が必要（AND）

   A 側のアイデンティティポリシー ─┐
                                   ├─→ 両方が Allow でないと拒否
   B 側のリソースポリシー ─────────┘
```

> If the caller and API owner are from separate accounts, both the IAM policies and the resource policy explicitly allow the caller to proceed.
> — [How API Gateway resource policies affect authorization workflow](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-authorization-flow.html)

### 5.3 なぜクロスアカウントは AND なのか

**2 つのアカウントの管理者が、独立に同意する必要があるから**。

- B の管理者が勝手に「A の誰でも呼んでいい」と決めても、A の管理者が許可していなければ A のリソースは動かない
- A の管理者が勝手に「B の API を呼ぶ」と書いても、B の管理者が許可していなければ通らない

つまり **AND は「片方のアカウントが単独で境界を越えられない」という保証**になっている。同一アカウント内なら管理者は 1 人なので、どちらか一方に書けば意思表示として十分、という設計。

この非対称性を知らないと、「A 側に権限を付けたのに 403 が消えない」という状態で延々と詰まる。

### 5.4 方式B ではなぜリソースポリシーが要らないのか

方式B では、A の Lambda が B のロールを AssumeRole する。その結果、**API から見た Principal は B アカウント内のロール**になる。

```
【方式A】 identity がアカウント境界を越える
   A のロール ────────────────(境界)───────────▶ B の API
   → クロスアカウント評価 → 両側の Allow が必要 → リソースポリシー必須

【方式B】 identity は境界を越えない
   A のロール ──AssumeRole──▶ B のロール ──▶ B の API
                              └─ ここから先は B 内部の話 ─┘
   → 同一アカウント評価 → B 側ロールの権限ポリシーだけで足りる → リソースポリシー不要
```

**リソースポリシーを持てない HTTP API でもクロスアカウント IAM 認証が成立する理由がこれ**。境界を越える部分を `execute-api` から `sts:AssumeRole` に付け替えている、と理解するとわかりやすい。

そして AssumeRole の部分は当然クロスアカウントなので、そこでは AND のルールが適用される（A 側の `sts:AssumeRole` 権限 と B 側の信頼ポリシーの両方が必要）。詳細は [21-assume-role-sts.md](21-assume-role-sts.md)。

---

## 6. 本リポジトリとの対応

| ポリシー | 種類 | ファイル |
|---|---|---|
| A 側 Lambda の `execute-api:Invoke` | アイデンティティベース | [pattern-a.../account-a-caller/template.yaml](../pattern-a-resource-policy/account-a-caller/template.yaml) |
| B 側 REST API のリソースポリシー | リソースベース | [pattern-a.../account-b-api/template.yaml](../pattern-a-resource-policy/account-b-api/template.yaml) |
| A 側 Lambda の `sts:AssumeRole` | アイデンティティベース | [pattern-b.../account-a-caller/template.yaml](../pattern-b-assume-role/account-a-caller/template.yaml) |
| B 側ロールの `AssumeRolePolicyDocument` | 信頼ポリシー（リソースベース） | [pattern-b.../account-b-api/template.yaml](../pattern-b-assume-role/account-b-api/template.yaml) |
| B 側ロールの `Policies` | 権限ポリシー（アイデンティティベース） | 同上 |

---

## 参考

- [Policies and permissions in IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html)
- [Policy evaluation logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)
- [AWS JSON policy elements: Principal](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_principal.html)
- [How API Gateway resource policies affect authorization workflow](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-authorization-flow.html)
