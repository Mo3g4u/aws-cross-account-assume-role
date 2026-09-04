"""[方式B / アカウントB] HTTP API のバックエンド。

HTTP API で IAM 認証を使うと、呼び出し元の情報は
requestContext.authorizer.iam に入る（ペイロード形式 2.0）。

方式Bでは AssumeRole を経由するため、ここに現れるのは
【アカウントB の ApiCallerRole】であって、アカウントA のロールではない。
「実際に誰が引き受けたか」は RoleSessionName と
CloudTrail の AssumeRole イベントを突き合わせて追跡する。
"""

import json


def handler(event, context):
    request_context = event.get("requestContext", {})
    iam = request_context.get("authorizer", {}).get("iam", {})

    # 実際のイベント構造を CloudWatch Logs で確認できるようにしておく
    print(json.dumps({"requestContext": request_context}, default=str, ensure_ascii=False))

    raw_body = event.get("body")
    try:
        received = json.loads(raw_body) if raw_body else None
    except (TypeError, ValueError):
        received = raw_body

    result = {
        "message": "アカウントBのAPIに到達しました",
        "pattern": "B: HTTP API + IAM authentication via AssumeRole",
        "caller": {
            "accountId": iam.get("accountId"),
            "userArn": iam.get("userArn"),
            "callerId": iam.get("callerId"),
            "sourceIp": request_context.get("http", {}).get("sourceIp"),
        },
        "receivedBody": received,
    }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(result, ensure_ascii=False),
    }
