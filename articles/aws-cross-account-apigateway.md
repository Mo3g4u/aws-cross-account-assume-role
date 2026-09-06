---
title: "別アカウントの API Gateway を Lambda から呼ぶ方法を 2 パターン試してみた"
emoji: "👾"
type: "tech"
topics: ["aws", "lambda", "apigateway", "iam", "sam"]
published: false
---

## はじめに

マルチアカウント構成で開発していると、「アカウント A の Lambda から、アカウント B の API Gateway を呼びたい」という要件がそのうち出てきます。

で、素直に IAM ポリシーを書いて動かしてみたら、見事に 403 を踏みました。しかも A 側にちゃんと権限を付けたはずなのに消えてくれません。調べていくと、**同一アカウント内のときとは必要な条件が違う**ということがわかり、そこからようやく前に進めました。

同じところで詰まる人はけっこういそうなので、実際に 2 パターン組んで動かしてみた記録をまとめます。AWS を触り始めたばかりのメンバーにも読んでもらえるように、前提知識のおさらいも挟んでいます。

検証に使ったコードはこちらに置いてあります。`./deploy.sh` 一発で両方式とも試せるようにしてあります。

https://github.com/Mo3g4u/aws-cross-account-assume-role

### 結論から言うと

判断を決めているのは、AWS 側の仕様 2 つだけでした。

1. **クロスアカウントでは「呼ぶ側」と「呼ばれる側」の両方で明示的に許可**しないと通らない
2. **HTTP API はリソースポリシーに対応していない**

この 2 つから、使える方式が自動的に決まります。

- **REST API** で呼び出し元が固定 → **方式A（リソースポリシー）** がいちばんシンプル
- **HTTP API** → **方式B（AssumeRole）一択**。仕様上ほかに手段がないです

---

## 前提知識のおさらい

ここは知っている方は読み飛ばしてください。後半の話が全部この 3 つに乗っかっているので、先に整理しておきます。

### IAM ポリシーって何？

**「誰が・何を・どれに・どんな条件で」を書いた JSON** です。

```json
{
  "Effect": "Allow",
  "Action": "execute-api:Invoke",
  "Resource": "arn:aws:execute-api:ap-northeast-1:222222222222:abc123/prod/POST/items"
}
```

ここでいちばん大事なのが、**AWS のデフォルトは「全部拒否」**ということ。何も書かなければ何もできません。書いたものだけが許可される、という発想です。

そしてポリシーには**貼る場所が 2 種類**あります。この区別が今回の話の中心になります。

- **アイデンティティベースポリシー**: 人やロールなど「主体」側に貼る。この人は何ができるか
- **リソースベースポリシー**: S3 バケットや API など「リソース」側に貼る。このリソースは誰に使わせるか

見分け方は簡単で、**JSON に `"Principal"`（誰が）が書いてあればリソース側**です。主体側に貼るポリシーは、貼った相手自身が「誰が」にあたるので `Principal` を書きません。

### IAM ロールって何？

**一時的に借りられる権限のセット**です。

IAM ユーザーのアクセスキーには有効期限がないので、漏れたら気づいて無効化するまで悪用され続けます。一方ロールは、借りるたびに**有効期限つき（デフォルト 1 時間）の一時的な鍵**が発行されるので、漏れても時間で効果が切れます。

Lambda も例外ではなくて、**起動時に「実行ロール」を借りて動いています**。だから Lambda のコードにアクセスキーを書かなくていいわけですね。

そしてロールには、性質の違うポリシーが 2 つ付きます。ここは後半で効いてきます。

- **信頼ポリシー**: **誰が**このロールを借りられるか
- **権限ポリシー**: 借りた後に**何ができる**か

### SigV4 署名って何？

AWS への HTTP リクエストに**署名を付ける仕組み**です。

パスワードのようにシークレットキーをそのまま送るのではなく、**シークレットキーを鍵にしてリクエストの中身を計算した結果**を送ります。AWS 側が同じ計算を再現して一致すれば本人と認める、という方式です。

これで 3 つが同時に成立するのがうまくできてるなと思いました。

- **認証**: 鍵を知っている人しか正しい署名を作れない
- **改ざん検知**: URL やボディを 1 バイト変えると署名が合わなくなる
- **リプレイ抑止**: 署名に時刻が入っていて、5 分程度のずれしか許容されない

API Gateway で「IAM 認証」を有効にするというのは、要するに**「このリクエストは SigV4 で署名されていること」を要求する設定**です。

普段 AWS CLI や SDK を使っているときは自動でやってくれているので意識しませんが、**自作の API Gateway には SDK のクライアントが存在しない**ので、今回は自分で署名を作ります。

---

## やったこと（全体像）

やりたいことはこれだけです。

```
          +----------------------+          +----------------------+
          |     アカウント A     |          |     アカウント B     |
          |                      |          |                      |
          |   +--------------+   |    ?     |  +----------------+  |
          |   |    Lambda    |---+--------->|  |  API Gateway   |  |
          |   +--------------+   |          |  +----------------+  |
          |                      |          |                      |
          +----------------------+          +----------------------+
```

一見ただの HTTPS リクエストなんですが、**アカウントの壁を越えるぶんだけルールが増える**というのが今回のテーマです。

試したのはこの 2 パターンです。

| | 方式A | 方式B |
|---|---|---|
| やり方 | IAM 認証 + リソースポリシー | AssumeRole してから呼ぶ |
| AssumeRole | 不要 | 必要 |
| 対応する API | **REST API のみ** | REST / HTTP どちらも |

---

## つまずきポイント (1): クロスアカウントは「両側」の許可が必要

最初にハマったのがこれです。**同一アカウント内かクロスアカウントかで、必要な条件が変わります。**

```
【同一アカウント】どちらか一方の許可でOK

    アイデンティティポリシー ---+
                                +---> どちらかが Allow なら通る
    リソースポリシー -----------+


【クロスアカウント】両方の許可が必要

    A側のアイデンティティポリシー ---+
                                     +---> 両方が Allow でないと拒否
    B側のリソースポリシー -----------+
```

公式ドキュメントにもはっきり書いてありました。

> If the caller and API owner are from separate accounts, both the IAM policies and the resource policy explicitly allow the caller to proceed.
> — [How API Gateway resource policies affect authorization workflow](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-authorization-flow.html)

:::message
「A 側に権限を付けたのに 403 が消えない」の原因はだいたいこれです。同一アカウントでの経験があると「片方書けば通るでしょ」と思い込みがちなんですが、クロスアカウントでは通用しません。
:::

意地悪な仕様に見えたんですが、理由を考えてみると納得でした。**2 つのアカウントの管理者が、独立に同意する必要があるから**です。

B の管理者が勝手に「A の誰でもどうぞ」と決めても、A の管理者が許可しなければ A のリソースは動きません。逆も同じです。つまりこの AND は、**片方のアカウントが単独でアカウントの壁を越えられないようにするための保証**になっているわけですね。同一アカウント内なら管理者は 1 人なので、どちらかに書けば意思表示として十分、という設計だと理解しました。

## つまずきポイント (2): HTTP API はリソースポリシーが使えない

もうひとつがこれです。API Gateway には **REST API** と **HTTP API** の 2 種類があるんですが、後者にはこういう制約があります。

> Resource policies aren't currently supported for HTTP APIs.
> — [Control access to HTTP APIs with IAM authorization](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-access-control-iam.html)

:::message
名前が紛らわしいんですが、**HTTP API は REST API の後継ではありません**。「REST API から機能を削って安く・速くしたもの」で、両者は併存しています。安いので新規は HTTP API で、というケースも多いと思います。
:::

つまずきポイント (1) と組み合わせると、詰みます。

```
HTTP API では B 側にリソースポリシーを置けない
        +
クロスアカウントには両側の許可が要る
        |
        v
呼び出し元の身元を「B アカウントの中の人」にするしかない
        |
        v
AssumeRole が必須（＝方式B）
```

というわけで、HTTP API を使っているなら方式B 一択になります。ここに気づかず REST API の記事を読みながら HTTP API でリソースポリシーを探して、しばらく無駄な時間を使いました。

---

## 方式A: リソースポリシー方式を試す（REST API）

まずはシンプルな方から。**Lambda が自分の実行ロールのまま、直接 API を叩きます。**

```
   +----------------------+            +------------------------------+
   |     アカウント A     |            |        アカウント B          |
   |                      |            |                              |
   |  Lambda 実行ロール   |    (1)     |   REST API (IAM 認証)        |
   |  execute-api:Invoke  |----------->|     リソースポリシー         |
   |     【許可その1】    |  SigV4署名 |     Principal: A のロール    |
   |                      |            |        【許可その2】   (2)   |
   +----------------------+            +------------------------------+

              (1) と (2) の【両方】が必要
```

### B 側（API を提供する側）

```yaml:template.yaml（アカウントB）
CrossAccountApi:
  Type: AWS::Serverless::Api
  Properties:
    StageName: prod
    Auth:
      DefaultAuthorizer: AWS_IAM       # SigV4 署名を必須にする
      InvokeRole: NONE                 # ← これがないとデプロイが失敗する（後述）
      ResourcePolicy:
        CustomStatements:
          - Effect: Allow
            Principal:
              AWS: !Ref CallerRoleArn  # ← A 側のロール ARN
            Action: execute-api:Invoke
            Resource:
              - execute-api:/prod/POST/items
```

`Resource` の `execute-api:/prod/POST/items` は簡略構文で、保存時に API Gateway がリージョン・アカウント ID・API ID を補って完全な ARN に展開してくれます。地味に便利でした。

### A 側（呼び出す側）

```yaml:template.yaml（アカウントA）
Policies:
  - Statement:
      - Effect: Allow
        Action: execute-api:Invoke
        Resource: arn:aws:execute-api:ap-northeast-1:222222222222:abc123/prod/POST/items
```

:::message alert
この ARN のアカウント ID は **API を持っている B 側**です。呼び出し元の A ではありません。ここ、自分も普通に間違えました。
:::

### Lambda のコード

```python:app.py
import json, os, boto3, urllib3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

API_ENDPOINT = os.environ["API_ENDPOINT"]
API_REGION = os.environ["API_REGION"]

_http = urllib3.PoolManager()
_credentials = boto3.Session().get_credentials()

def handler(event, context):
    body = json.dumps({"message": "hello from account A"})

    request = AWSRequest(method="POST", url=API_ENDPOINT, data=body,
                         headers={"Content-Type": "application/json"})
    # サービス名は execute-api 固定。リージョンは【B側APIのリージョン】
    SigV4Auth(_credentials.get_frozen_credentials(), "execute-api", API_REGION).add_auth(request)

    resp = _http.request("POST", API_ENDPOINT, body=body, headers=dict(request.headers))
    return {"statusCode": resp.status, "response": json.loads(resp.data)}
```

`boto3` / `botocore` / `urllib3` はすべて Lambda の Python ランタイムに同梱されているので、追加パッケージのバンドルは不要でした。Lambda Layer を用意しなくていいのは楽ですね。

### 動かしてみた

B 側の Lambda で「誰が呼んできたか」を返すようにしておいたところ、こうなりました。

```json
{
  "caller": {
    "accountId": "111111111111",
    "userArn": "arn:aws:sts::111111111111:assumed-role/CallerFunctionRole-XXXX/takeuchi-xacct-a-caller-caller",
    "caller": "AROAXXXXXXXXXXXXXXXXX:takeuchi-xacct-a-caller-caller",
    "sourceIp": "203.0.113.10"
  }
}
```

**アカウント A のロールがそのまま届いています。** B 側のログを見るだけで「A のどのロールが呼んだか」がわかるので、これは方式A のけっこう大きな利点だなと思いました。

ちなみに `userArn` が `iam` ではなく `sts` の `assumed-role` 形式になっているのは、実際にリクエストを出しているのが「ロールを借りた一時的なセッション」だからです。**ポリシーに書くのは `arn:aws:iam::111111111111:role/MyRole` の方**なので、ログで見た文字列をそのままコピペすると一致せずに 403 になります。これも一度やりました。

---

## 方式B: AssumeRole 方式を試す（HTTP API）

こちらは **「まず B のロールを借りて、B の中の人として API を叩く」** 方式です。

```
  +----------------------+          +--------------------------------------+
  |     アカウント A     |          |            アカウント B              |
  |                      |          |                                      |
  |  Lambda 実行ロール   |   (1)    |  ApiCallerRole                       |
  |  sts:AssumeRole      |--------->|    信頼ポリシー: A のロール          |
  |                      |          |    権限ポリシー: execute-api:Invoke  |
  |                      |<---------|                                      |
  |                      |   (2)    |                |                     |
  |  一時認証情報で署名  |   一時   |                v                     |
  |                      |  認証情報|  +--------------------------------+  |
  |                      |   (3)    |  |   HTTP API (IAM 認証)          |  |
  |                      |--------->|  |   ※ リソースポリシーは無し     |  |
  +----------------------+          |  +--------------------------------+  |
                                    +--------------------------------------+
```

### B 側: 借りられるロールを用意する

ロールに**性質の違う 2 つのポリシー**を付けます。ここは混同しやすかったので表にしておきます。

| ポリシー | 答える問い | 中身 |
|---|---|---|
| 信頼ポリシー | **誰が**借りられるか | A の Lambda 実行ロール |
| 権限ポリシー | 借りた後**何ができる**か | この API への `execute-api:Invoke` |

```yaml:template.yaml（アカウントB）
CrossAccountHttpApi:
  Type: AWS::Serverless::HttpApi
  Properties:
    StageName: prod
    Auth:
      EnableIamAuthorizer: true     # HTTP API ではこの 2 行がセット
      DefaultAuthorizer: AWS_IAM

ApiCallerRole:
  Type: AWS::IAM::Role
  Properties:
    # 【信頼ポリシー】誰が借りられるか
    AssumeRolePolicyDocument:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Principal:
            AWS: !Ref CallerRoleArn      # ← A 側のロール ARN
          Action: sts:AssumeRole
    # 【権限ポリシー】借りた後に何ができるか
    Policies:
      - PolicyName: InvokeHttpApi
        PolicyDocument:
          Version: '2012-10-17'
          Statement:
            - Effect: Allow
              Action: execute-api:Invoke
              Resource: !Sub "arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${CrossAccountHttpApi}/prod/POST/items"
```

SAM の `EnableIamAuthorizer: true` は最初書き忘れていて、`DefaultAuthorizer: AWS_IAM` だけだと Transform でエラーになりました。この 2 行はセットです。

### A 側: 必要な権限は 1 つだけ

```yaml:template.yaml（アカウントA）
Policies:
  - Statement:
      - Effect: Allow
        Action: sts:AssumeRole          # これだけ
        Resource: arn:aws:iam::222222222222:role/ApiCallerRole
```

方式A と違って、**A 側に API の権限を書く必要がありません**。API を呼ぶ権限は B 側のロールが持っているからですね。B 側の API が増えても A 側は触らなくていいので、運用ではこれがかなり効いてきそうです。

### Lambda のコード

```python:app.py
import time, boto3
from botocore.credentials import Credentials

_sts = boto3.client("sts")
_cache = {"credentials": None, "expires_at": 0.0}

def _assumed_credentials(request_id, function_name):
    # 一時認証情報は 1 時間有効。期限まで使い回す
    if _cache["credentials"] and time.time() < _cache["expires_at"] - 300:
        return _cache["credentials"], True

    # RoleSessionName は追跡の唯一の手がかりなので意味のある値を入れる
    session_name = f"{function_name}-{request_id[:8]}"[:64]
    r = _sts.assume_role(RoleArn=ASSUME_ROLE_ARN,
                         RoleSessionName=session_name,
                         DurationSeconds=3600)["Credentials"]

    _cache["credentials"] = Credentials(
        access_key=r["AccessKeyId"],
        secret_key=r["SecretAccessKey"],
        token=r["SessionToken"],       # 一時認証情報にはトークンが付く
    )
    _cache["expires_at"] = r["Expiration"].timestamp()
    return _cache["credentials"], False
```

署名の部分は**方式A とまったく同じコード**で動きました。渡す認証情報が違うだけです。

```python
SigV4Auth(credentials, "execute-api", API_REGION).add_auth(request)
```

一時認証情報にはセッショントークンが含まれますが、`SigV4Auth` が `X-Amz-Security-Token` ヘッダーを自動で付けてくれるので、コードを分岐させなくていいのは助かりました。

:::message alert
**毎回 AssumeRole しないように気をつけてください。** STS 呼び出しは数十〜百 ms かかるので、そのまま全リクエストの応答時間に乗ります。Lambda はコンテナを再利用するので、ハンドラ関数の**外**の変数に置いておくだけでウォームスタート間で使い回せます。

あと、期限ぎりぎりまで使うと「取得時点では有効だったのに到達時には切れていた」が起きるので、数分のマージンを引いて取り直すようにしています（上のコードの `- 300`）。
:::

### 動かしてみた

```json
{
  "assumedRoleArn": "arn:aws:iam::222222222222:role/ApiCallerRole-XXXX",
  "roleSessionName": "takeuchi-xacct-b-caller-caller-f99a253a",
  "credentialsFromCache": false,
  "caller": {
    "accountId": "222222222222",
    "userArn": "arn:aws:sts::222222222222:assumed-role/ApiCallerRole-XXXX/takeuchi-xacct-b-caller-caller-f99a253a",
    "callerId": "AROAXXXXXXXXXXXXXXXXX:takeuchi-xacct-b-caller-caller-f99a253a",
    "sourceIp": "203.0.113.20"
  }
}
```

**方式A と決定的に違うところが出ました。** `accountId` が **B** になっています。API から見た呼び出し元は B 自身のロールなんですね。

### なぜこれでリソースポリシーが要らないのか

ここが腑に落ちたポイントでした。図にするとこうです。

```
【方式A】身元がアカウントの壁を越える

    A のロール ------------(壁)------------> B の API
    → クロスアカウント判定 → 両側の許可が必要 → リソースポリシー必須


【方式B】身元は壁を越えない

    A のロール --AssumeRole--> B のロール ------> B の API
                               +--- ここから先は B 内部の話 ---+
    → 同一アカウント判定 → B 側ロールの権限だけでOK → リソースポリシー不要
```

**「壁を越える部分を `execute-api` から `sts:AssumeRole` に付け替えている」** と捉えると、一気にわかりやすくなりました。壁を越える箇所ではもちろんつまずきポイント (1) が適用されるので、AssumeRole には A 側の権限と B 側の信頼ポリシーの両方が必要です。

:::message
方式B のトレードオフとして、**API に届くのが B 側のロールになるので「A 側の誰が呼んだか」が API のログからは直接わかりません。**

追跡手段は `RoleSessionName`（`userArn` の末尾に出る）と、B アカウントの CloudTrail の `AssumeRole` イベントの 2 つだけです。なので `RoleSessionName` を `session` みたいな適当な値にすると、後で追えなくなります。上のコードで関数名を入れているのはそのためです。
:::

ちなみに HTTP API で IAM 認証を使った場合、呼び出し元の情報は **`requestContext.authorizer.iam`** に入ります。REST API の `requestContext.identity` とは場所が違うので、バックエンドのコードはそのまま流用できません。ここは公式ドキュメントのペイロード形式 2.0 のサンプルに `authorizer.jwt` の例しか載っていなくて確信が持てなかったので、`requestContext` を丸ごとログに出して実物を確認しました。

```python
# 方式A（REST API）
event["requestContext"]["identity"]["userArn"]

# 方式B（HTTP API）
event["requestContext"]["authorizer"]["iam"]["userArn"]
```

ちなみに方式A の `userArn` も `assumed-role` 形式でしたが、あれは **Lambda サービスが関数の起動時に実行ロールを借りている**からです。実際、セッション名の部分が `takeuchi-xacct-a-caller-caller` という **Lambda 関数名そのもの**になっていました。つまり両方式の違いは「AssumeRole するかどうか」ではなく、**AssumeRole を 1 回で済ませるか 2 回連ねるか**なんですね。

```
方式A: Lambdaサービス --借用--> A の実行ロール ------> B の API
方式B: Lambdaサービス --借用--> A の実行ロール --借用--> B のロール --> B の API
                                                +-- ここを足しただけ --+
```

この見方をすると、方式B で一時認証情報の有効期間が最大 1 時間に制限される理由（ロールを連ねる「ロールチェーン」の制約）も自然に理解できました。

---

## その他につまずいたところ

上の 2 つ以外にも地味に時間を溶かしたポイントがあったので、まとめておきます。

### つまずき: そもそもデプロイが通らない（`Caller provided credentials not allowed`）

方式A を最初にデプロイしたとき、`AWS::ApiGateway::Deployment` の作成でいきなり落ちました。

```
CREATE_FAILED  AWS::ApiGateway::Deployment  CrossAccountApiDeployment...
  Resource handler returned message: "Caller provided credentials not allowed
  when resource policy is set (Service: ApiGateway, Status Code: 400 ...)"
```

メッセージだけ見ても何のことかわからなかったので、SAM が生成した CloudFormation テンプレートを覗いてみたところ、統合設定にこんなものが入っていました。

```json
"x-amazon-apigateway-integration": {
  "type": "aws_proxy",
  "credentials": "arn:aws:iam::*:user/*"     // ← これ
}
```

調べてみると、SAM は `AWS::Serverless::Api` に `Auth` を指定すると、`InvokeRole` の既定値 `CALLER_CREDENTIALS` を統合に適用する仕様でした。一方 API Gateway 側は「リソースポリシーがある API で、統合に呼び出し元の認証情報を使う」ことを許可していないので、この 2 つが噛み合わずに落ちていたわけです。

対処は `InvokeRole: NONE` を明示するだけでした。

```yaml
Auth:
  DefaultAuthorizer: AWS_IAM
  InvokeRole: NONE          # ← 追加
  ResourcePolicy:
    CustomStatements: [...]
```

Lambda プロキシ統合の呼び出し許可は `AWS::Lambda::Permission`（SAM が自動で作ってくれる）の側で付くので、統合に認証情報は要りません。`NONE` が意味的にも正しいですね。

ちなみに **HTTP API（方式B）ではこの問題は起きません**。`AWS::Serverless::HttpApi` には `InvokeRole` 相当の設定がないので、統合に `credentials` が入らないためです。

### つまずき: IAM ロールの説明に日本語を書いたら怒られた

方式B のデプロイで、`AWS::IAM::Role` の作成がこれで落ちました。

```
1 validation error detected: Value at 'description' failed to satisfy constraint:
Member must satisfy regular expression pattern:
[\u0009\u000A\u000D\u0020-\u007E\u00A1-\u00FF]*
```

正規表現をよく見ると、許されているのはタブ・改行・復帰と `\u0020-\u007E`（印字可能 ASCII）、`\u00A1-\u00FF`（Latin-1 補助）だけでした。つまり **IAM の `Description` に日本語は入れられない**ということですね。

```yaml
ApiCallerRole:
  Type: AWS::IAM::Role
  Properties:
    Description: アカウントA の Lambda が引き受けるためのロール   # ← これがダメ
```

説明は英語にして、日本語は YAML のコメントに逃がすことで解決しました。

ちなみに同じ `Description:` でも、**AWS リソースのプロパティなのか CloudFormation のメタデータなのか**で扱いが違います。ここを整理できていなかったのが敗因でした。

| 場所 | 日本語 |
|---|---|
| `Resources.*.Properties.Description`（IAM ロール等） | ❌ サービス側の文字種制約を受ける |
| テンプレート冒頭 / `Parameters` / `Outputs` の `Description` | ✅ CloudFormation のメタデータなので OK |

なお `Outputs` の `Description` は CloudFormation 上は日本語で通るんですが、**SAM CLI がデプロイ後に表示する表で文字化けします**。

```
Key                 CallerRoleArn
Description         B ????? CallerRoleArn ???????? ARN     ← 読めない
```

デプロイ結果の値を読む場所なので、ここも ASCII に統一しました。

### つまずき: 失敗したスタックが消せずに再デプロイできない

上のエラーでスタックが `ROLLBACK_COMPLETE` になったあと、そのまま再実行したら今度はこう言われました。

```
Stack ... is in ROLLBACK_COMPLETE state and can not be updated.
```

**CREATE に失敗したスタックはそのままでは作り直せない**という CloudFormation の仕様でした。いったん削除してから作り直す必要があります。

```bash
aws cloudformation delete-stack --stack-name <スタック名> --profile <profile>
aws cloudformation wait stack-delete-complete --stack-name <スタック名> --profile <profile>
```

検証を何度も回すことになるので、`deploy.sh` の側でこの状態を検出して自動で削除してから進むようにしました。

### つまずき: リソースポリシーを変えたのに 403 のまま

**REST API のリソースポリシーは、変更しただけでは反映されません。** ステージへのデプロイが必要です。マネコンで直接編集したときに特にハマりました。

```bash
aws apigateway create-deployment --rest-api-id <API_ID> --stage-name prod
```

ちなみに **HTTP API は自動デプロイ**なので、この問題自体が起きません。地味にうれしい差だなと思いました。

### つまずき: `Missing Authentication Token` が出る

これ、**認証情報がないという意味ではありません**。ほとんどの場合、**そのパス/メソッドのルートが存在しない**だけです。メッセージに引っ張られて IAM を見直し続けていたんですが、ステージ名を付け忘れていただけでした。まず URL を疑うのが正解です。

HTTP API の場合は、同じ状況で `{"message":"Forbidden"}` が返ります。

### つまずき: `MalformedPolicyDocument: Invalid principal in policy`

IAM ロールの**信頼ポリシーに、実在しないロール ARN を書いている**と出ます。IAM は信頼ポリシーの principal が実在するかを検証しているんですね。

方式B で「B のスタックから先に作ろう」とすると必ずこれになります。**A 側（＝ Lambda 実行ロール）を先に作る必要があります。**

そもそもクロスアカウント構成には循環参照があって、B 側のポリシーは「A のロール ARN」を知りたいし、A 側の Lambda は「B のエンドポイント」を知りたい、という状態になります。今回は `A → B → A（再デプロイ）` の 3 ステップに分けるスクリプトを用意して解決しました。

### つまずき: ロールを作り直したら急に 403 になった

ポリシーに書いたロール ARN は、保存時に内部の一意 ID（`AROA...`）に変換されて保持されるそうです。なので**同名で作り直すと ID が変わって、参照している側のポリシーが壊れます**。

ポリシーの JSON を見て `Principal` が ARN ではなく `AROAXXXX...` になっていたらこれです。参照側のポリシーを保存し直せば直ります。

### 切り分けのコツ: 署名の失敗か、認可の失敗か

403 が返ったとき、**まずこの 2 つを切り分ける**と早いです。

- `SignatureDoesNotMatch` → **署名の失敗**。リージョンやホスト名を疑う
- `is not authorized to perform: execute-api:Invoke` → **署名は成功している**。問題は IAM ポリシー側

署名エラーでよくある原因はこのあたりでした。

- 署名した**後**に URL・ヘッダー・ボディを変更した（全部署名対象なので壊れる）
- 署名時のリージョンを A 側にしていた（正しくは **B 側 API のリージョン**）
- HTTP クライアントがリダイレクトを自動追従した（転送先でホスト名が変わる）

---

## 結局どっちを使う？

| 観点 | 方式A（リソースポリシー） | 方式B（AssumeRole） |
|---|---|---|
| REST API | ✅ | ✅ |
| **HTTP API** | ❌ **使えない** | ✅ |
| 実装の単純さ | ✅ STS 呼び出し不要 | 　 キャッシュ処理が要る |
| レイテンシ | ✅ | 　 キャッシュすれば同等 |
| 権限の管理場所 | 　 両アカウントに分散 | ✅ B 側に集約できる |
| 呼び出し元の追跡 | ✅ A のロールが届く | 　 CloudTrail との突合が必要 |
| 呼び出し元の追加 | 　 ポリシー変更＋API 再デプロイ | ✅ 信頼ポリシー変更のみ |
| API 以外への横展開 | ❌ | ✅ 同じロールに権限を足すだけ |

選び方はこんな感じかなと思っています。

```
  HTTP API を使う？
    +-- はい ---------------------------> 方式B（他に選択肢なし）
    |
    +-- いいえ（REST API）
          |
          +-- B 側の API 以外のリソースも使う？ --- はい --> 方式B
          |
          +-- 呼び出し元アカウントが今後増える？ --- はい --> 方式B
          |
          +-- どちらもいいえ -----------------------------> 方式A（最小構成）
```

個人的には**迷ったら方式B** でいいと思いました。運用面（呼び出し元の増減、API 以外への横展開）で効いてきますし、レイテンシの不利はキャッシュでほぼ消えるので。

ただ、REST API で呼び出し元が完全に固定なら、方式A の構成要素の少なさと追跡のしやすさは捨てがたいです。

---

## 今回の検証の前提と留意点

あくまで仕組みの確認が目的なので、実運用に向けては他にも見るところがありそうです。思いつくところだと以下です。

- **Private API は試していない**: インターネットに出したくない要件がある場合、REST API の Private エンドポイント + VPC エンドポイントを併用することになります。ただし Lambda を VPC に置く必要が出てくるので、NAT やコールドスタートの考慮が別途必要です
- **エラーハンドリングは最小限**: 検証コードは正常系だけ通しています。実際にはリトライやタイムアウトの設計が要ります
- **`ExternalId` は任意扱い**: 自社内アカウント間なら不要ですが、第三者組織にロールを貸す場合は confused deputy 対策として必須と考えていいと思います。検証コードではパラメータで有効化できるようにしてあります
- **CloudFormation の自動生成名の切り詰め**: プレフィックスを長くすると IAM ロール名が 64 文字を超えて切り詰められるはずですが、そこまでは実測していません

## まとめ

- クロスアカウントでは **呼ぶ側と呼ばれる側の両方**で明示的に許可が要る。403 が消えない原因はだいたいこれ
- **HTTP API はリソースポリシー非対応**。なのでクロスアカウントでは AssumeRole が必須になる
- **方式A** は身元がそのまま届くので追跡が楽。**方式B** は権限を B 側に集約できて横展開が効く
- 迷ったら方式B。ただし `RoleSessionName` は必ず意味のある値にしておく

検証に使ったコードは GitHub に置いてあるので、よかったら手元でも試してみてください。両方デプロイして `invoke.sh` の結果を見比べると、`caller.accountId` が A になるか B になるかで違いが一発でわかると思います。

https://github.com/Mo3g4u/aws-cross-account-assume-role

```bash
cp config.env.example config.env
$EDITOR config.env       # PREFIX・アカウントID・プロファイルを設定

cd pattern-a-resource-policy
./deploy.sh              # 3 ステップのデプロイを自動実行
./invoke.sh              # 呼び出し結果を表示
./cleanup.sh             # 後片付け
```

複数人で同じ検証アカウントを使う場合は、`config.env` の `PREFIX` を各自で変えてください。スタック名・Lambda 関数名・API 名・ロググループがすべてこの値から派生するので、同時に検証してもリソースが衝突しません。

リポジトリには記事で触れなかった内容（IAM の権限評価ロジック、SigV4 署名の中身、REST API と HTTP API の機能比較）もドキュメントとして置いてあります。

「なんとなく IAM を書いて動かない」状態から抜けるには、**今どちら側の許可が足りないのかを切り分けられること**が一番効くなというのが今回の学びでした。参考になれば幸いです！

## 参考リンク

- [How API Gateway resource policies affect authorization workflow](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-authorization-flow.html)
- [Control access to HTTP APIs with IAM authorization](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-access-control-iam.html)
- [Choose between REST APIs and HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html)
- [Create a signed AWS API request](https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html)
