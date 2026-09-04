#!/usr/bin/env bash
# [方式B] 両アカウントのスタックを削除する。
# B 側ロールの信頼ポリシーが A のロール ARN を参照しているため、B から先に消す。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN=b
# shellcheck source=../scripts/common.sh
source "$(cd "$SCRIPT_DIR/.." && pwd)/scripts/common.sh"

print_banner "方式B: スタックを削除"
read -r -p "上記 2 スタックを削除します。よろしいですか? [y/N] " ans
case "$ans" in
  [yY]|[yY][eE][sS]) ;;
  *) echo "中止しました。"; exit 0 ;;
esac

echo "アカウントB のスタック ($STACK_B) を削除中..."
sam delete --stack-name "$STACK_B" --profile "$PROFILE_B" --region "$REGION" --no-prompts

echo "アカウントA のスタック ($STACK_A) を削除中..."
sam delete --stack-name "$STACK_A" --profile "$PROFILE_A" --region "$REGION" --no-prompts

echo "完了。"
