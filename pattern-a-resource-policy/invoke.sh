#!/usr/bin/env bash
# [方式A] アカウントA の Lambda を実行して、クロスアカウント呼び出しの結果を見る。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN=a
# shellcheck source=../scripts/common.sh
source "$(cd "$SCRIPT_DIR/.." && pwd)/scripts/common.sh"

FUNCTION_NAME="$(stack_output "$STACK_A" "$PROFILE_A" CallerFunctionName)"
echo "invoke: $FUNCTION_NAME" >&2

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --profile "$PROFILE_A" \
  --region "$REGION" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"message":"hello from account A"}' \
  "$OUT" >/dev/null

if command -v jq >/dev/null 2>&1; then
  jq . "$OUT"
else
  cat "$OUT"; echo
fi
