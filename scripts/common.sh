# 全スクリプト共通の初期化処理。
#
# 呼び出し側で PATTERN=a または PATTERN=b を設定してから source する:
#   PATTERN=a
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/common.sh"
#
# 提供するもの:
#   REPO_ROOT  リポジトリのルート
#   PREFIX     正規化済みのリソース名プレフィックス
#   STACK_A    アカウントA 側のスタック名
#   STACK_B    アカウントB 側のスタック名
#   config.env の各変数（ACCOUNT_A_ID / ACCOUNT_B_ID / PROFILE_A / PROFILE_B / REGION）

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- config.env の読み込み -------------------------------------------------
CONFIG="$REPO_ROOT/config.env"
if [ ! -f "$CONFIG" ]; then
  echo "ERROR: $CONFIG がありません。" >&2
  echo "       cp config.env.example config.env して編集してください。" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${ACCOUNT_A_ID:?config.env に ACCOUNT_A_ID を設定してください}"
: "${ACCOUNT_B_ID:?config.env に ACCOUNT_B_ID を設定してください}"
: "${PROFILE_A:?config.env に PROFILE_A を設定してください}"
: "${PROFILE_B:?config.env に PROFILE_B を設定してください}"
: "${REGION:?config.env に REGION を設定してください}"

: "${PATTERN:?common.sh を source する前に PATTERN=a または PATTERN=b を設定してください}"

# ---- PREFIX の解決 ---------------------------------------------------------
# 同じ AWS アカウントを複数人で共有していても、リソース名が衝突しないようにする。
# config.env で未設定なら $USER から自動生成する。
PREFIX="${PREFIX:-${USER:-}}"

# 正規化: 小文字化 → 英数字とハイフン以外をハイフンに → 連続ハイフンを 1 つに
#         → 前後のハイフン除去 → 12 文字に切り詰め → 末尾ハイフン再除去
PREFIX="$(printf '%s' "$PREFIX" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-*//; s/-*$//' \
  | cut -c1-12 \
  | sed 's/-*$//')"

if [ -z "$PREFIX" ]; then
  echo "ERROR: PREFIX を決定できませんでした。" >&2
  echo "       config.env に PREFIX=<あなたの識別子> を設定してください。" >&2
  exit 1
fi

# CloudFormation のスタック名は英字始まりでなければならない
if ! printf '%s' "$PREFIX" | grep -Eq '^[a-z][a-z0-9-]*$'; then
  echo "ERROR: PREFIX '$PREFIX' は使用できません。" >&2
  echo "       英字で始まり、英数字とハイフンのみ、12 文字以内にしてください。" >&2
  exit 1
fi

# ---- スタック名 ------------------------------------------------------------
# 命名: <PREFIX>-xacct-<方式>-<役割>
#   方式  a = リソースポリシー方式 / b = AssumeRole 方式
#   役割  caller = アカウントA 側  / api = アカウントB 側
#
# Lambda 関数名・API 名はテンプレート内で ${AWS::StackName} から派生させているため、
# ここを変えるだけで全リソース名にプレフィックスが行き渡る。
STACK_A="${PREFIX}-xacct-${PATTERN}-caller"
STACK_B="${PREFIX}-xacct-${PATTERN}-api"

# ---- 補助関数 --------------------------------------------------------------

# stack_output <スタック名> <プロファイル> <出力キー>
stack_output() {
  aws cloudformation describe-stacks \
    --stack-name "$1" --profile "$2" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$3'].OutputValue" \
    --output text
}

# print_banner <タイトル>  これから操作する対象を明示する
print_banner() {
  echo "-----------------------------------------------------------"
  echo " $1"
  echo "-----------------------------------------------------------"
  echo "  PREFIX          : $PREFIX"
  echo "  アカウントA     : $ACCOUNT_A_ID (profile: $PROFILE_A)"
  echo "  アカウントB     : $ACCOUNT_B_ID (profile: $PROFILE_B)"
  echo "  リージョン      : $REGION"
  echo "  スタック (A側)  : $STACK_A"
  echo "  スタック (B側)  : $STACK_B"
  echo
}
