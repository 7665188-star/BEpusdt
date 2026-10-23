#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
verify_bundle
load_config
check_dns
install -d -m 0700 /root/shop-stack
python3 "$STACK_ROOT/patch-manager.py" "$STACK_ROOT/vendor/dujiao-next-manager.upstream.sh" /root/shop-stack/dujiao-next-manager.sh
bash -n /root/shop-stack/dujiao-next-manager.sh
if [[ -f /etc/dujiao-next/install-state.json ]]; then
  [[ $(jq -r .domain /etc/dujiao-next/install-state.json) == "$SHOP_DOMAIN" ]] || die 'Stored shop domain differs from config.env. Preserve the installation.'
fi
export SHOP_DOMAIN ACME_EMAIL
exec bash /root/shop-stack/dujiao-next-manager.sh install
