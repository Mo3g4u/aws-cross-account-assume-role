"""[方式A / アカウントA] Lambda 実行ロールの認証情報で直接 SigV4 署名して呼び出す。

AssumeRole を挟まないため、アカウントB の API には
【アカウントA の Lambda 実行ロール】の identity がそのまま届く。

boto3 / botocore / urllib3 は Lambda の Python ランタイムに同梱されているため、
追加パッケージのバンドルは不要。
"""

import json
import os

import boto3
import urllib3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

API_ENDPOINT = os.environ.get("API_ENDPOINT", "")
API_REGION = os.environ.get("API_REGION") or os.environ["AWS_REGION"]
SERVICE = "execute-api"

# コンテナ再利用時に使い回す（毎回作り直す必要はない）
_http = urllib3.PoolManager()
_credentials = boto3.Session().get_credentials()


def _signed_request(method: str, url: str, body: str) -> dict:
    """SigV4 署名済みのヘッダーを組み立てて返す。

    注意: 署名はメソッド・URL・ヘッダー・ボディに対して行われる。
    署名した【あと】にこれらを書き換えると 403 になる。
    """
    request = AWSRequest(
        method=method,
        url=url,
        data=body,
        headers={"Content-Type": "application/json"},
    )
    # get_frozen_credentials() は毎回呼ぶ。
    # Lambda 実行ロールの認証情報は自動でローテーションされるため。
    SigV4Auth(_credentials.get_frozen_credentials(), SERVICE, API_REGION).add_auth(request)
    return dict(request.headers)


def handler(event, context):
    if not API_ENDPOINT:
        raise RuntimeError(
            "環境変数 API_ENDPOINT が未設定です。"
            "deploy.sh の 3 ステップ目（A スタックの再デプロイ）が完了しているか確認してください。"
        )

    body = json.dumps(
        {
            "message": event.get("message", "hello from account A"),
            "requestId": context.aws_request_id,
        },
        ensure_ascii=False,
    )

    headers = _signed_request("POST", API_ENDPOINT, body)
    response = _http.request("POST", API_ENDPOINT, body=body, headers=headers)
    text = response.data.decode("utf-8")

    print(f"status={response.status} body={text}")

    try:
        parsed = json.loads(text)
    except ValueError:
        parsed = text

    return {
        "statusCode": response.status,
        "endpoint": API_ENDPOINT,
        "response": parsed,
    }
