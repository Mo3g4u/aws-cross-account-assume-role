"""[方式B / アカウントA] AssumeRole で得た一時認証情報を使って SigV4 署名する。

流れ:
  1. sts:AssumeRole でアカウントB のロールを引き受ける
  2. 返ってきた一時認証情報で SigV4 署名する
  3. HTTP API を呼ぶ

一時認証情報はデフォルト 1 時間有効なので、Lambda のコンテナ再利用を活かして
キャッシュする。毎回 AssumeRole すると STS のレイテンシとスロットリングが
そのまま呼び出しコストに乗る。
"""

import json
import os
import time

import boto3
import urllib3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials

API_ENDPOINT = os.environ.get("API_ENDPOINT", "")
API_REGION = os.environ.get("API_REGION") or os.environ["AWS_REGION"]
ASSUME_ROLE_ARN = os.environ.get("ASSUME_ROLE_ARN", "")
EXTERNAL_ID = os.environ.get("EXTERNAL_ID", "")
SERVICE = "execute-api"

# 期限切れの何秒前に取り直すか
REFRESH_MARGIN_SECONDS = 300

_http = urllib3.PoolManager()
_sts = boto3.client("sts")
_cache = {"credentials": None, "expires_at": 0.0, "session_name": None}


def _assumed_credentials(request_id: str, function_name: str):
    """B 側ロールの一時認証情報と、キャッシュ由来かどうかを返す。"""
    if _cache["credentials"] and time.time() < _cache["expires_at"] - REFRESH_MARGIN_SECONDS:
        return _cache["credentials"], True

    # RoleSessionName は B 側の CloudTrail に記録され、
    # 「どの呼び出し元が引き受けたか」を追跡する唯一の手がかりになる。
    # 関数名（= プレフィックス付きのスタック名由来）を含めることで、
    # 同じロールを複数人が引き受けていても誰のセッションか判別できる。
    # RoleSessionName は 64 文字以内・[\w+=,.@-] のみ。
    session_name = f"{function_name}-{request_id[:8]}"[:64]

    params = {
        "RoleArn": ASSUME_ROLE_ARN,
        "RoleSessionName": session_name,
        "DurationSeconds": 3600,
    }
    if EXTERNAL_ID:
        params["ExternalId"] = EXTERNAL_ID

    response = _sts.assume_role(**params)["Credentials"]

    _cache["credentials"] = Credentials(
        access_key=response["AccessKeyId"],
        secret_key=response["SecretAccessKey"],
        token=response["SessionToken"],
    )
    _cache["expires_at"] = response["Expiration"].timestamp()
    _cache["session_name"] = session_name
    print(f"AssumeRole 実行: session={session_name} expires={response['Expiration']}")

    return _cache["credentials"], False


def handler(event, context):
    if not API_ENDPOINT or not ASSUME_ROLE_ARN:
        raise RuntimeError(
            "環境変数 API_ENDPOINT / ASSUME_ROLE_ARN が未設定です。"
            "deploy.sh の 3 ステップ目（A スタックの再デプロイ）が完了しているか確認してください。"
        )

    credentials, from_cache = _assumed_credentials(
        context.aws_request_id, context.function_name
    )

    body = json.dumps(
        {
            "message": event.get("message", "hello from account A"),
            "requestId": context.aws_request_id,
        },
        ensure_ascii=False,
    )

    request = AWSRequest(
        method="POST",
        url=API_ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json"},
    )
    # 一時認証情報にはセッショントークンが含まれるため、
    # SigV4Auth が X-Amz-Security-Token ヘッダーも自動で付与する。
    SigV4Auth(credentials, SERVICE, API_REGION).add_auth(request)

    response = _http.request("POST", API_ENDPOINT, body=body, headers=dict(request.headers))
    text = response.data.decode("utf-8")

    print(f"status={response.status} body={text}")

    try:
        parsed = json.loads(text)
    except ValueError:
        parsed = text

    return {
        "statusCode": response.status,
        "endpoint": API_ENDPOINT,
        "assumedRoleArn": ASSUME_ROLE_ARN,
        "roleSessionName": _cache["session_name"],
        "credentialsFromCache": from_cache,
        "response": parsed,
    }
