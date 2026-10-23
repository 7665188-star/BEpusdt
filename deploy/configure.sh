#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $EUID -eq 0 ]] || die 'Run as root.'
[[ ! -e /etc/dujiao-next/install-state.json && ! -e /etc/shop-stack/payment.json ]] || die 'Installation already started. Keep config.env unchanged; use the existing configuration to resume.'
read -r -p 'Shop domain (hostname only): ' SHOP_DOMAIN
read -r -p 'Payment domain (different hostname): ' PAY_DOMAIN
read -r -p 'Certificate contact email: ' ACME_EMAIL
read -r -p 'VPS public IPv4 from the provider console: ' SERVER_IPV4
SHOP_DOMAIN=${SHOP_DOMAIN,,}
PAY_DOMAIN=${PAY_DOMAIN,,}
export SHOP_DOMAIN PAY_DOMAIN ACME_EMAIL SERVER_IPV4
python3 "$STACK_ROOT/config-check.py"
printf 'SHOP_DOMAIN=%q\nPAY_DOMAIN=%q\nACME_EMAIL=%q\nSERVER_IPV4=%q\n' "$SHOP_DOMAIN" "$PAY_DOMAIN" "$ACME_EMAIL" "$SERVER_IPV4" > "$STACK_ROOT/config.env"
chmod 0600 "$STACK_ROOT/config.env"
echo 'PASS: config.env saved. Continue with 00-prepare.sh.'
