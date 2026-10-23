#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
load_config
systemctl is-active --no-pager dujiao-next dujiao-next-redis bepusdt nginx certbot.timer
nginx -t
curl_direct -fsS "https://$SHOP_DOMAIN/health"
printf '\n'
python3 "$STACK_ROOT/private-check.py" "$PAY_DOMAIN" --public
python3 "$STACK_ROOT/check-bep20.py"
