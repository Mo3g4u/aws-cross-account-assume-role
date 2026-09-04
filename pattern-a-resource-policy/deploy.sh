#!/usr/bin/env bash
# [方式A] 3 ステップでデプロイする。
#   1) A スタック（Lambda 実行ロールを確定させる）
#   2) B スタック（1 のロール ARN をリソースポリシーで許可）
#   3) A スタック再デプロイ（B のエンドポイントを設定し、権限を絞り込む）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN=a
# shellcheck source=../scripts/common.sh
source "$(cd "$SCRIPT_DIR/.." && pwd)/scripts/common.sh"

print_banner "方式A: REST API + リソースポリシー をデプロイ"

deploy() {
  local dir="$1" stack="$2" profile="$3"
  shift 3
  ( cd "$dir" && sam deploy \
      --stack-name "$stack" \
      --profile "$profile" \
      --region "$REGION" \
      --capabilities CAPABILITY_IAM \
      --resolve-s3 \
      --no-confirm-changeset \
      --no-fail-on-empty-changeset \
      --parameter-overrides "$@" )
}

echo "=== [1/3] アカウントA: 呼び出し元 Lambda をデプロイ ==============="
deploy "$SCRIPT_DIR/account-a-caller" "$STACK_A" "$PROFILE_A" \
  "AccountBId=$ACCOUNT_B_ID"

CALLER_ROLE_ARN="$(stack_output "$STACK_A" "$PROFILE_A" CallerRoleArn)"
echo "  Lambda 実行ロール: $CALLER_ROLE_ARN"

echo
echo "=== [2/3] アカウントB: REST API をデプロイ ========================"
deploy "$SCRIPT_DIR/account-b-api" "$STACK_B" "$PROFILE_B" \
  "CallerRoleArn=$CALLER_ROLE_ARN"

API_ENDPOINT="$(stack_output "$STACK_B" "$PROFILE_B" ApiEndpoint)"
API_INVOKE_ARN="$(stack_output "$STACK_B" "$PROFILE_B" ApiInvokeArn)"
echo "  エンドポイント: $API_ENDPOINT"
echo "  Invoke ARN    : $API_INVOKE_ARN"

echo
echo "=== [3/3] アカウントA: エンドポイントを設定して再デプロイ ========="
deploy "$SCRIPT_DIR/account-a-caller" "$STACK_A" "$PROFILE_A" \
  "AccountBId=$ACCOUNT_B_ID" \
  "ApiEndpoint=$API_ENDPOINT" \
  "ApiInvokeArn=$API_INVOKE_ARN"

echo
echo "完了。動作確認: ./invoke.sh"
