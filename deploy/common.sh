#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
STACK_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
load_config() {
  [[ $EUID -eq 0 ]] || die 'Run as root.'
  [[ -f $STACK_ROOT/config.env ]] || die 'Copy config.env.example to config.env and edit the four values first.'
  # This is the operator-owned configuration file, not a downloaded environment.
  source "$STACK_ROOT/config.env"
  export SHOP_DOMAIN PAY_DOMAIN ACME_EMAIL SERVER_IPV4
  python3 "$STACK_ROOT/config-check.py"
}
verify_bundle() { (cd "$STACK_ROOT" && sha256sum --quiet -c SHA256SUMS); }
curl_direct() { curl --noproxy '*' --proto '=https,http' --proto-redir '=https' "$@"; }
check_dns() { python3 "$STACK_ROOT/config-check.py" --dns; }
check_acme() {
  local domain=$1 webroot=$2 token file local_body public_body
  token="probe-$(openssl rand -hex 16)"
  install -d -m 0755 "$webroot" "$webroot/.well-known" "$webroot/.well-known/acme-challenge"
  file="$webroot/.well-known/acme-challenge/$token"
  printf '%s' "$token" > "$file"
  chmod 0644 "$file"
  nginx -t
  systemctl reload nginx
  for attempt in {1..30}; do
    local_body=$(curl_direct -4 -fsS --resolve "$domain:80:127.0.0.1" --connect-timeout 2 --max-time 4 "http://$domain/.well-known/acme-challenge/$token" 2>/dev/null) || local_body=''
    public_body=$(curl_direct -4 -fsS --connect-timeout 2 --max-time 4 "http://$domain/.well-known/acme-challenge/$token" 2>/dev/null) || public_body=''
    if [[ $local_body == "$token" && $public_body == "$token" ]]; then
      rm -f -- "$file"
      echo "PASS: $domain ACME file matches through localhost and DNS."
      return 0
    fi
    sleep 1
  done
  rm -f -- "$file"
  if [[ $local_body != "$token" ]]; then
    echo "ERROR: $domain local Nginx challenge failed; check server_name, root, permissions and conflicting sites." >&2
  else
    echo "ERROR: $domain DNS route failed; check A/AAAA, CDN/proxy and TCP 80 security-group/firewall access." >&2
  fi
  return 1
}
