#!/usr/bin/env bash
# [方式B] 3 ステップでデプロイする。
#   1) A スタック（Lambda 実行ロールを確定させる）
#      ※ IAM は信頼ポリシーの principal 実在性を検証するため、この順序が必須
#   2) B スタック（1 のロール ARN を信頼する IAM ロール + HTTP API）
#   3) A スタック再デプロイ（エンドポイントと AssumeRole 先を設定し、権限を絞り込む）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN=b
# shellcheck source=../scripts/common.sh
source "$(cd "$SCRIPT_DIR/.." && pwd)/scripts/common.sh"

# 任意: 第三者組織向けの confused deputy 対策。使わないなら空のまま。
EXTERNAL_ID="${EXTERNAL_ID:-}"

print_banner "方式B: HTTP API + AssumeRole をデプロイ"

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
  "AccountBId=$ACCOUNT_B_ID" \
  "ExternalId=$EXTERNAL_ID"

CALLER_ROLE_ARN="$(stack_output "$STACK_A" "$PROFILE_A" CallerRoleArn)"
echo "  Lambda 実行ロール: $CALLER_ROLE_ARN"

echo
echo "=== [2/3] アカウントB: HTTP API と AssumeRole 先ロールをデプロイ ==="
deploy "$SCRIPT_DIR/account-b-api" "$STACK_B" "$PROFILE_B" \
  "CallerRoleArn=$CALLER_ROLE_ARN" \
  "ExternalId=$EXTERNAL_ID"

API_ENDPOINT="$(stack_output "$STACK_B" "$PROFILE_B" ApiEndpoint)"
ASSUME_ROLE_ARN="$(stack_output "$STACK_B" "$PROFILE_B" ApiCallerRoleArn)"
echo "  エンドポイント     : $API_ENDPOINT"
echo "  AssumeRole 先ロール: $ASSUME_ROLE_ARN"

echo
echo "=== [3/3] アカウントA: エンドポイントとロールを設定して再デプロイ ="
deploy "$SCRIPT_DIR/account-a-caller" "$STACK_A" "$PROFILE_A" \
  "AccountBId=$ACCOUNT_B_ID" \
  "ApiEndpoint=$API_ENDPOINT" \
  "AssumeRoleArn=$ASSUME_ROLE_ARN" \
  "ExternalId=$EXTERNAL_ID"

echo
echo "完了。動作確認: ./invoke.sh"
