"""[方式A / アカウントB] REST API のバックエンド。

呼び出し元の IAM identity をそのまま返すことで、
「どのアカウントのどのロールとして到達したか」を目視で確認できるようにする。
方式Aでは requestContext.identity.userArn に
【アカウントA の Lambda 実行ロール】の ARN が入る。
"""

import json


def handler(event, context):
    request_context = event.get("requestContext", {})
    identity = request_context.get("identity", {})

    # 実際のイベント構造を CloudWatch Logs で確認できるようにしておく
    print(json.dumps({"requestContext": request_context}, default=str, ensure_ascii=False))

    raw_body = event.get("body")
    try:
        received = json.loads(raw_body) if raw_body else None
    except (TypeError, ValueError):
        received = raw_body

    result = {
        "message": "アカウントBのAPIに到達しました",
        "pattern": "A: REST API + IAM authentication + resource policy",
        "caller": {
            "accountId": identity.get("accountId"),
            "userArn": identity.get("userArn"),
            "caller": identity.get("caller"),
            "sourceIp": identity.get("sourceIp"),
        },
        "receivedBody": received,
    }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(result, ensure_ascii=False),
    }
