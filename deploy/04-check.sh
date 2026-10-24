#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $# == 0 || ( $# == 1 && $1 == --services-only ) ]] || die 'Usage: bash 04-check.sh [--services-only]'
load_config
systemctl is-active --no-pager dujiao-next dujiao-next-redis bepusdt nginx certbot.timer
nginx -t
curl_direct -fsS "https://$SHOP_DOMAIN/health"
printf '\n'
python3 "$STACK_ROOT/private-check.py" "$PAY_DOMAIN" --public
if [[ ${1:-} == --services-only ]]; then
  echo 'PASS: installed services and HTTPS verified. Wallet/RPC/channel configuration and a real payment test remain.'
  exit 0
fi
python3 "$STACK_ROOT/check-bep20.py"
