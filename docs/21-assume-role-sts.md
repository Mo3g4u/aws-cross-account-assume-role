# AssumeRole と STS / 一時認証情報

**扱う用語**: IAM ロール / STS / AssumeRole / 一時認証情報 / セッショントークン / RoleSessionName / ExternalId / confused deputy / ロールチェーン

前提として [20-iam-policies.md](20-iam-policies.md) の「信頼ポリシーと権限ポリシー」を読んでおくとよい。

---

## 1. そもそもなぜロールなのか

AWS の認証情報には 2 種類ある。

| | 長期認証情報 | 一時認証情報 |
|---|---|---|
| 持ち主 | IAM ユーザー | ロールを引き受けたセッション |
| 構成 | アクセスキー ID + シークレットアクセスキー | ＋ **セッショントークン** |
| アクセスキー ID の接頭辞 | `AKIA...` | `ASIA...` |
| 有効期限 | **なし**（明示的に無効化するまで） | あり（15 分〜12 時間） |
| 漏洩時の影響 | 気付いて無効化するまで悪用され続ける | 期限で自動的に無効になる |

**「有効期限のない認証情報を配らない」**のがロールの目的。アカウント A のコードにアカウント B のアクセスキーを埋め込む代わりに、A のロールから B のロールを都度引き受ける。埋め込む秘密情報がゼロになる。

Lambda 実行ロールも同じ仕組みで動いている。Lambda はロールを引き受けた一時認証情報を環境変数（`AWS_ACCESS_KEY_ID` 等）として関数に渡しており、`boto3.Session().get_credentials()` はそれを読んでいる。だから方式A のコードには**認証情報がどこにも書かれていない**。

---

## 2. AWS STS

**AWS Security Token Service (STS)** は、一時認証情報を発行する専用サービス。主な API:

| API | 用途 |
|---|---|
| `AssumeRole` | IAM の主体（ユーザー / ロール）がロールを引き受ける ← **今回使うのはこれ** |
| `AssumeRoleWithWebIdentity` | OIDC（GitHub Actions、Cognito など）からロールを引き受ける |
| `AssumeRoleWithSAML` | SAML IdP（社内 AD など）からロールを引き受ける |
| `GetCallerIdentity` | 今の自分が誰かを返す。権限不要なので疎通確認に便利 |

```bash
# 「今どのアカウントの誰として動いているか」を確認する
aws sts get-caller-identity --profile account-a
```

---

## 3. AssumeRole の流れ

```
┌─ アカウントA ─────────────┐     ┌─ アカウントB ───────────────────────┐
│                           │     │                                     │
│ Lambda (実行ロール)       │     │  ApiCallerRole                      │
│   │                       │     │    信頼ポリシー                     │
│   │ ① AssumeRole ─────────┼────▶│      Principal: A の実行ロール ─ ✔  │
│   │   RoleArn=...         │     │                                     │
│   │   RoleSessionName=... │     │    権限ポリシー                     │
│   │                       │     │      execute-api:Invoke             │
│   │ ② 一時認証情報 ◀──────┼─────┤                                     │
│   │   AccessKeyId (ASIA..)│     │                                     │
│   │   SecretAccessKey     │     │                                     │
│   │   SessionToken        │     │                                     │
│   │   Expiration          │     │                                     │
│   │                       │     │                                     │
│   └─③ SigV4 署名して呼ぶ ─┼────▶│  HTTP API (AWS_IAM)                 │
│                           │     │    ここでの Principal は            │
│                           │     │    【B の ApiCallerRole】           │
└───────────────────────────┘     └─────────────────────────────────────┘
```

### ① に必要な設定は「両側」

AssumeRole 自体がクロスアカウント操作なので、[20-iam-policies.md §5.2](20-iam-policies.md#52-同一アカウント-vs-クロスアカウント) の AND ルールが適用される。

| どちら側 | 何を書くか |
|---|---|
| **A 側** | Lambda 実行ロールのアイデンティティポリシーに `sts:AssumeRole`（`Resource` は B のロール ARN） |
| **B 側** | ロールの信頼ポリシーに A の実行ロール ARN（`Action: sts:AssumeRole`） |

片方だけだと `AccessDenied: User ... is not authorized to perform: sts:AssumeRole` になる。

### ③ の Principal が変わることが重要

一時認証情報で署名すると、API から見た呼び出し元は **B の `ApiCallerRole`** になる。identity がアカウント境界を越えないため、API 側は同一アカウントの評価ルールで済む ── これが「HTTP API でもクロスアカウント呼び出しが成立する」理由。

---

## 4. 一時認証情報の中身

`AssumeRole` のレスポンス:

```json
{
  "Credentials": {
    "AccessKeyId": "ASIAXXXXXXXXXXXXXXXX",
    "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "SessionToken": "IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3Q...",
    "Expiration": "2026-09-04T13:00:00Z"
  },
  "AssumedRoleUser": {
    "AssumedRoleId": "AROAXXXXXXXXXXXXXXXXX:my-session",
    "Arn": "arn:aws:sts::222222222222:assumed-role/ApiCallerRole/my-session"
  }
}
```

### SessionToken が必要な理由

長期認証情報は「アクセスキー ID → シークレットキー」の対応を AWS が持っているだけで検証できる。一方、一時認証情報は STS がその場で発行するもので、**セッションの内容（どのロールか、いつまで有効か、どんなセッションポリシーか）を AWS 側に伝える必要がある**。それを担うのが `SessionToken`。

そのため、一時認証情報でリクエストを送るときは `X-Amz-Security-Token` ヘッダーに `SessionToken` を載せる必要がある。`SigV4Auth` は渡された認証情報にトークンが含まれていれば**自動でこのヘッダーを付ける**ので、方式A と方式B でコードの署名部分は同一になる（→ [22-sigv4.md](22-sigv4.md)）。

### 有効期間

| 設定 | 意味 | 既定値 |
|---|---|---|
| `DurationSeconds`（リクエスト側） | 何秒有効な認証情報が欲しいか | 3600 秒 |
| `MaxSessionDuration`（ロール側） | ロールが許す最大値 | 3600 秒（最大 43200 秒 = 12 時間） |

`DurationSeconds` が `MaxSessionDuration` を超えるとエラーになる。長くしたい場合はロール側の設定も上げる。

**ロールチェーン**（ロールで別のロールを引き受ける）の場合は、`DurationSeconds` の上限が **1 時間**に制限される。Lambda 実行ロール（すでにロール）から B のロールを引き受ける本リポジトリの構成はロールチェーンに該当するため、3600 秒を超える指定はできない。

---

## 5. RoleSessionName と追跡

```python
session_name = f"account-a-caller-{request_id[:8]}"
sts.assume_role(RoleArn=..., RoleSessionName=session_name, DurationSeconds=3600)
```

`RoleSessionName` はセッション ARN の末尾に現れる。

```
arn:aws:sts::222222222222:assumed-role/ApiCallerRole/takeuchi-xacct-b-caller-caller-1a2b3c4d
                                                     ^^^^^^^^^^^^^^^^^^^^^^^^^
                                                     RoleSessionName
```

**方式B の運用上いちばん重要な設定**がこれ。方式B では API に届く identity が B 側のロールになるため、「A 側の誰が呼んだか」は API のログからは直接わからない。追跡経路は 2 つしかない。

1. **`RoleSessionName`** — API のログに現れる。意味のある値を入れておく
2. **CloudTrail の `AssumeRole` イベント** — B アカウントに記録される。`requestParameters.roleSessionName` と `userIdentity` を突き合わせると、どの A 側 principal が引き受けたかがわかる

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --profile account-b --region ap-northeast-1 --max-results 10
```

セッション名を `session` や `tmp` のような無意味な値にすると、この追跡が実質不可能になる。**呼び出し元アプリ名 + リクエスト ID** のような組み合わせにしておく。

なお、セッション名は IAM ポリシーの Condition でも使える（`aws:userid` など）。

---

## 6. ExternalId と confused deputy

### 何を防ぐのか

**混乱した代理人（confused deputy）** 問題は、「権限を持つ第三者を騙して、本来アクセスできないリソースにアクセスさせる」攻撃。

具体的にはこういう状況で起きる。

```
SaaS ベンダー V が、顧客 X と 顧客 Y のロールを引き受けて監視サービスを提供している。

X のアカウント: MonitorRole  信頼ポリシー → Principal: V のロール
Y のアカウント: MonitorRole  信頼ポリシー → Principal: V のロール
                                            ^^^^^^^^^^^^^^^^^^^^^
                                            どちらも「V なら OK」としか書いていない

攻撃者が V のサービスに「私は顧客 Y です、Y のロール ARN はこれです」と申告すると、
V は素直に Y のロールを引き受けてしまい、攻撃者に Y のデータを見せてしまう。
V は権限を持つ「代理人」だが、誰の代理なのかを取り違えている（＝混乱している）。
```

### 対策

顧客ごとに異なる `ExternalId` を発行し、信頼ポリシーの条件にする。

```yaml
AssumeRolePolicyDocument:
  Statement:
    - Effect: Allow
      Principal:
        AWS: arn:aws:iam::999999999999:role/VendorRole
      Action: sts:AssumeRole
      Condition:
        StringEquals:
          sts:ExternalId: "customer-y-secret-value"
```

こうすると、攻撃者が Y のロール ARN を知っていても、**Y にしか通知されていない `ExternalId` を V に提示させることができない**ため、AssumeRole が失敗する。

### 使うべき場面

| 状況 | ExternalId |
|---|---|
| 自社内のアカウント間（同じ組織が両方を管理） | **不要**。両側を自分で管理しているため、この攻撃モデルが成立しない |
| 第三者組織にロールを貸す / 借りる | **必須と考えてよい** |

本リポジトリでは任意パラメータとして実装してあり、既定では無効。

```bash
EXTERNAL_ID=my-external-id ./deploy.sh
```

**なお `ExternalId` は秘密情報ではなく識別子**。パスワードのように扱う必要はないが、推測されにくい値（顧客ごとに一意な UUID など）にする。

---

## 7. 一時認証情報のキャッシュ

```python
REFRESH_MARGIN_SECONDS = 300
_cache = {"credentials": None, "expires_at": 0.0}

def _assumed_credentials(request_id):
    if _cache["credentials"] and time.time() < _cache["expires_at"] - REFRESH_MARGIN_SECONDS:
        return _cache["credentials"], True
    ...
```

### なぜキャッシュするのか

- **レイテンシ** — `AssumeRole` は数十〜百 ms かかる。毎リクエストで呼ぶとそのまま応答時間に乗る
- **スロットリング** — STS にもレート上限がある。高頻度の呼び出しでは実際に当たりうる
- **CloudTrail のノイズ** — 全リクエスト分の `AssumeRole` イベントが記録され、追跡がしづらくなる

### なぜモジュールスコープの変数で足りるのか

Lambda は実行環境（コンテナ）を再利用する。ハンドラ関数の外で定義した変数は、同じ実行環境が使われる間は保持される。ウォームスタートではこの値がそのまま残るため、追加のキャッシュ基盤なしにセッションを使い回せる。

`invoke.sh` を 2 回続けて実行すると `credentialsFromCache` が `false` → `true` に変わるのはこの挙動。

### なぜマージンを引くのか

```python
time.time() < _cache["expires_at"] - REFRESH_MARGIN_SECONDS
```

期限ぎりぎりまで使うと、「取得時点では有効だったが、リクエストが AWS に届いた時点では切れていた」という競合が起きる。数分のマージンを引いて早めに取り直すことでこれを避ける。

なお `boto3` の `RefreshableCredentials` を使えば自動更新も実装できるが、本リポジトリでは仕組みが見えるように手書きしている。

---

## 8. Lambda 実行ロールも AssumeRole されている

方式A のレスポンスに出る `userArn` をよく見ると、こうなっている。

```
arn:aws:sts::111111111111:assumed-role/CallerFunctionRole/takeuchi-xacct-a-caller-caller
^^^^^^^^^^^^^^^                       ^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
sts                                    ロール名            RoleSessionName（= 関数名）
```

方式A では明示的な `AssumeRole` を書いていないのに `assumed-role` 形式になっている。これは **Lambda サービスが関数の起動時に実行ロールを引き受けている**ため。`RoleSessionName` には関数名が自動で入る。

つまり方式A と方式B の違いは「AssumeRole するかどうか」ではなく、「**AssumeRole を 1 回で済ませるか、2 回連ねるか（ロールチェーン）**」と言える。

```
方式A: Lambda サービス ──AssumeRole──▶ A の実行ロール ──▶ B の API
方式B: Lambda サービス ──AssumeRole──▶ A の実行ロール ──AssumeRole──▶ B のロール ──▶ B の API
                                                        ^^^^^^^^^^^^^ ここを足しただけ
```

この見方をすると、方式B で `DurationSeconds` が 1 時間に制限される理由（ロールチェーンの制約）も自然に理解できる。

---

## 9. よくあるエラー

| エラー | 原因 |
|---|---|
| `AccessDenied: not authorized to perform: sts:AssumeRole` | A 側の `sts:AssumeRole` 権限、または B 側の信頼ポリシーが欠けている（両方必要） |
| `MalformedPolicyDocument: Invalid principal in policy` | 信頼ポリシーに実在しないロール ARN を書いた。IAM は principal の実在性を検証する |
| `ExpiredToken` | キャッシュした認証情報の期限切れ。マージンを見直す |
| `The requested DurationSeconds exceeds the MaxSessionDuration` | ロール側の上限を超えた。ロールチェーンなら上限は 1 時間 |
| `AccessDenied` かつ ExternalId 設定時 | A 側で `ExternalId` を渡していない、または値が不一致 |

---

## 参考

- [IAM roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
- [AssumeRole (STS API Reference)](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html)
- [How to use an external ID when granting access to your AWS resources to a third party](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html)
- [The confused deputy problem](https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html)
- [Roles terms and concepts: role chaining](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_terms-and-concepts.html)
