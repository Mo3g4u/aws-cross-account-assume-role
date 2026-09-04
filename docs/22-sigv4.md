# SigV4 署名（AWS Signature Version 4）

**扱う用語**: SigV4 / 正規リクエスト / 署名文字列 / 認証情報スコープ / 署名キー / SignedHeaders / X-Amz-Security-Token / SigV4a

---

## 1. 何のための仕組みか

SigV4 は、AWS への HTTP リクエストに署名を付ける方式。3 つのことを同時に成立させている。

| 目的 | どう実現しているか |
|---|---|
| **認証** | シークレットアクセスキーを知っている者しか正しい署名を作れない |
| **改ざん検知** | メソッド・URL・ヘッダー・ボディが署名対象に含まれる。1 バイト変えれば署名が合わなくなる |
| **リプレイ抑止** | 署名にタイムスタンプが含まれ、AWS 側で 5 分程度のずれしか許容しない |

重要なのは、**シークレットアクセスキー自体はネットワークに流れない**こと。流れるのはそれを鍵として計算した HMAC の結果だけ。AWS 側は同じ計算を再現して一致を確認する。

API Gateway で `AWS_IAM` 認可を設定するというのは、「このリクエストは SigV4 で署名されていること」を要求する、という意味になる。

---

## 2. 署名の 4 ステップ

```
① 正規リクエスト (CanonicalRequest) を組み立てる
        ↓ SHA256
② 署名文字列 (StringToSign) を組み立てる
        ↓
③ 署名キー (SigningKey) をシークレットキーから導出する
        ↓ HMAC-SHA256(SigningKey, StringToSign)
④ 署名を Authorization ヘッダーに載せる
```

`botocore` の `SigV4Auth(...).add_auth(request)` の 1 行がこれを全部やっている。中で何が起きているかを見ていく。

### ① 正規リクエスト (CanonicalRequest)

リクエストを**曖昧さのない一意な文字列**に正規化する。クライアントと AWS が必ず同じ文字列を作れるようにするための手続き。

```
<HTTPMethod>\n
<CanonicalURI>\n
<CanonicalQueryString>\n
<CanonicalHeaders>\n
<SignedHeaders>\n
<HashedPayload>
```

今回のリクエストだと、こうなる。

```
POST
/prod/items

content-type:application/json
host:abc123.execute-api.ap-northeast-1.amazonaws.com
x-amz-date:20260904T120000Z

content-type;host;x-amz-date
a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e
```

正規化のルールで押さえておくべき点:

| 要素 | ルール |
|---|---|
| `CanonicalURI` | URI エンコード済みの絶対パス。空なら `/` |
| `CanonicalQueryString` | 各パラメータを個別にエンコードし、**エンコード後にキー名で辞書順ソート**。クエリがなければ空行 |
| `CanonicalHeaders` | ヘッダー名を**小文字化**、値の前後空白を除去、**辞書順ソート**、各行末に改行 |
| `SignedHeaders` | 署名に含めたヘッダー名を小文字・辞書順・`;` 区切りで並べたもの |
| `HashedPayload` | ボディの SHA256 を小文字 16 進で。ボディがなければ空文字列のハッシュ |

`host` ヘッダーと `x-amz-*` ヘッダーは**必須**。`Content-Type` はリクエストに含まれるなら含める必要がある。

一方、**転送中に書き換わるヘッダー（`connection`、`user-agent`、`transfer-encoding` など）は署名に含めてはいけない**。プロキシやロードバランサが変更すると署名が壊れるため。

### ② 署名文字列 (StringToSign)

```
AWS4-HMAC-SHA256\n
20260904T120000Z\n
20260904/ap-northeast-1/execute-api/aws4_request\n
<CanonicalRequest の SHA256 ハッシュ（16進小文字）>
```

3 行目が**認証情報スコープ (Credential Scope)**。

```
20260904 / ap-northeast-1 / execute-api / aws4_request
^^^^^^^^   ^^^^^^^^^^^^^^   ^^^^^^^^^^^   ^^^^^^^^^^^^
日付       リージョン       サービス       固定文字列
```

このスコープが署名文字列にも署名キーの導出にも入るため、**署名は「その日・そのリージョン・そのサービス」にしか使えない**。他リージョンや他サービスに流用できない。

だから署名時に指定するリージョンは **B 側 API のリージョン**でなければならず、サービス名は `execute-api` 固定になる。

```python
SigV4Auth(credentials, "execute-api", API_REGION).add_auth(request)
#                       ^^^^^^^^^^^^   ^^^^^^^^^^
#                       サービス       B 側 API のリージョン
```

### ③ 署名キーの導出

シークレットアクセスキーを直接使わず、HMAC を 4 回連ねて日付・リージョン・サービスに縛られた鍵を作る。

```
DateKey              = HMAC-SHA256("AWS4" + SecretAccessKey, "20260904")
DateRegionKey        = HMAC-SHA256(DateKey,              "ap-northeast-1")
DateRegionServiceKey = HMAC-SHA256(DateRegionKey,        "execute-api")
SigningKey           = HMAC-SHA256(DateRegionServiceKey, "aws4_request")
```

この段階的な導出により、仮に `SigningKey` が漏れても**その日・そのリージョン・そのサービスにしか使えない**。被害範囲がスコープに限定される。

### ④ 署名の計算と Authorization ヘッダー

```
Signature = Hex(HMAC-SHA256(SigningKey, StringToSign))
```

最終的に付くヘッダーはこうなる。

```http
POST /prod/items HTTP/1.1
Host: abc123.execute-api.ap-northeast-1.amazonaws.com
Content-Type: application/json
X-Amz-Date: 20260904T120000Z
X-Amz-Security-Token: IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3Q...
Authorization: AWS4-HMAC-SHA256 
  Credential=ASIAXXXXXXXXXXXXXXXX/20260904/ap-northeast-1/execute-api/aws4_request, 
  SignedHeaders=content-type;host;x-amz-date, 
  Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7
```

（`Authorization` は実際には 1 行。読みやすさのため改行している）

`Credential` にアクセスキー ID とスコープが平文で入っている。**シークレットキーは含まれない**。AWS はアクセスキー ID から対応するシークレットキーを引き、同じ手順で署名を再計算して照合する。

---

## 3. 一時認証情報の場合

`AssumeRole` で得た認証情報にはセッショントークンが含まれる（→ [21-assume-role-sts.md §4](21-assume-role-sts.md#4-一時認証情報の中身)）。この場合、`X-Amz-Security-Token` ヘッダーを追加する必要がある。

```python
# 方式A: Lambda 実行ロールの認証情報（これも一時認証情報）
SigV4Auth(_credentials.get_frozen_credentials(), "execute-api", API_REGION).add_auth(request)

# 方式B: AssumeRole で得た認証情報
SigV4Auth(credentials, "execute-api", API_REGION).add_auth(request)
```

**コードは同一**。`SigV4Auth` は渡された `Credentials` に `token` が含まれていれば、`X-Amz-Security-Token` ヘッダーを自動で追加し、正規ヘッダーにも含める。

方式A と方式B で違うのは「どの認証情報を渡すか」だけで、署名処理そのものは変わらない ── この点は、両パターンの `src/app.py` を並べて見ると確認できる。

---

## 4. なぜ「署名後に書き換えると壊れる」のか

§2 ① で見たとおり、正規リクエストにはメソッド・パス・クエリ・ヘッダー・ボディのハッシュがすべて含まれている。署名はその文字列に対する HMAC なので、**署名後に何か 1 つでも変えれば AWS 側の再計算結果と一致しなくなる**。

実務で踏みやすいパターン:

| やってしまうこと | 結果 |
|---|---|
| 署名してからクエリパラメータを足す | 署名不一致 |
| 署名してから `Content-Type` を変える | 署名不一致（`Content-Type` は署名対象） |
| 署名してからボディを整形し直す（JSON の空白変更など） | ペイロードハッシュが変わり不一致 |
| HTTP クライアントのリダイレクト自動追従 | 転送先の `host` が変わり不一致 |
| カスタムドメインを使うのに実行 API のホスト名で署名 | `host` が違い不一致 |

本リポジトリのコードで、署名に使うボディと送信するボディを同じ変数にしているのはこのため。

```python
body = json.dumps({...})           # ← この文字列を
request = AWSRequest(..., data=body, ...)
SigV4Auth(...).add_auth(request)   # ← 署名し
_http.request("POST", API_ENDPOINT, body=body, headers=dict(request.headers))
#                                        ^^^^   そのまま送る
```

`json.dumps` を 2 回呼んで別々の文字列を使う、といった実装にすると（キーの順序が同じでも空白が違えば）壊れる。

### カスタムドメインを使う場合

`host` ヘッダーが署名対象なので、**アクセスする URL のホスト名で署名する**必要がある。一方、IAM ポリシーの `Resource` に書く ARN は API ID ベースのまま（`abc123/prod/POST/items`）。署名対象とポリシーの対象がずれるので混乱しやすい。

---

## 5. 時刻ずれ

署名文字列にはタイムスタンプ（`X-Amz-Date`）が含まれ、AWS 側は**おおむね 5 分**のずれしか許容しない。それを超えると署名エラーになる。

Lambda では基盤側で時刻が同期されているため問題にならないが、オンプレミスや自前 EC2 から署名する場合は NTP の設定を確認すること。「昨日まで動いていたのに急に署名エラーになった」場合、時刻ずれを疑う価値がある。

---

## 6. 署名を自分で書くべきか

**基本的に書かない。** AWS SDK / CLI を使えば署名は自動で行われる。

今回自分で署名しているのは、**API Gateway が公開する自作 API は AWS SDK のクライアントが存在しない**ため。SDK が知らないエンドポイントに対して、SDK の署名機構（`botocore.auth.SigV4Auth`）だけを借りている、という構図になる。

```python
from botocore.auth import SigV4Auth      # 署名アルゴリズムの実装
from botocore.awsrequest import AWSRequest  # 署名対象を表すリクエストオブジェクト
```

`boto3` / `botocore` / `urllib3` はいずれも Lambda の Python ランタイムに同梱されているため、追加パッケージなしで使える。

他の言語でも同様の低レベル署名 API が用意されている（Java の `Aws4Signer`、JavaScript の `@aws-sdk/signature-v4` など）。ゼロから実装する必要はまずない。

---

## 7. SigV4a（参考）

**SigV4a** は複数リージョンにまたがって有効な署名を作れる派生方式。

| | SigV4 | SigV4a |
|---|---|---|
| アルゴリズム | `AWS4-HMAC-SHA256`（対称鍵 HMAC） | `AWS4-ECDSA-P256-SHA256`（楕円曲線署名） |
| リージョン | 認証情報スコープに含む | スコープに含まず `X-Amz-Region-Set` ヘッダーで指定 |
| 主な用途 | 通常のリクエスト | S3 マルチリージョンアクセスポイントなど |

API Gateway のリソースポリシーは SigV4 と SigV4a の両方に対応しているが、今回の構成では SigV4 だけを使う。

---

## 8. デバッグの手がかり

| 症状 | 確認すること |
|---|---|
| `SignatureDoesNotMatch` / `InvalidSignatureException` | 署名後にリクエストを変更していないか。リージョン・サービス名は正しいか。カスタムドメインの `host` |
| 署名は通るが 403 | 署名は成功している。**認可**の問題なので IAM ポリシー側を見る（→ [20-iam-policies.md](20-iam-policies.md)） |
| `Missing Authentication Token` | 署名の問題ではない。**そのパス/メソッドのルートが存在しない**（→ [90-troubleshooting.md](90-troubleshooting.md)） |
| 時々だけ失敗する | 時刻ずれ、または一時認証情報の期限切れ |

**403 が返ったとき、まず「署名の失敗」と「認可の失敗」を切り分ける**こと。メッセージに `is not authorized to perform: execute-api:Invoke` と出ていれば署名は成功しており、問題はポリシー側にある。

署名の中身を確認したい場合は、botocore のデバッグログを有効にすると正規リクエストと署名文字列がそのまま出力される。

```python
import logging
logging.getLogger("botocore.auth").setLevel(logging.DEBUG)
```

---

## 参考

- [Create a signed AWS API request](https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html)
- [Elements of an AWS API request signature](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-signing-elements.html)
- [Request signature examples](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-examples.html)
- [AWS signing protocols reference](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html)
