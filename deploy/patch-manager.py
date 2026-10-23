"""Pin the official installer and strengthen its ACME readback; app is unmodified."""
from pathlib import Path
import hashlib
import sys

EXPECTED = '7b30683a41b5e5150e667dae32e04aa441418398fb9da4351e27d677ab6826fb'
PIN = '41b86260dc9a60269526057eed8d915844ceb3a3'

def patch(raw):
    if hashlib.sha256(raw).hexdigest() != EXPECTED:
        raise ValueError('Official manager checksum differs; stopped.')
    text = raw.decode()
    for old, new, count in [
        ('/releases/latest"','/releases/tags/v1.5.0"',1),
        ('${GITHUB_REPOSITORY}/main/scripts/', '${GITHUB_REPOSITORY}/'+PIN+'/scripts/',1),
        ('curl --fail --silent --show-error --location', "curl --noproxy '*' --retry 3 --retry-all-errors --retry-delay 2 --fail --silent --show-error --location",3),
    ]:
        if text.count(old) != count:
            raise ValueError('Installer shape differs: '+old)
        text = text.replace(old,new)
    start = text.index('verify_acme_reachability() {\n')
    end = text.index('\nissue_certificate() {', start)
    replacement = '''verify_acme_reachability() {
  local domain=$1 token challenge_dir response local_response attempt
  token=$(openssl rand -hex 16)
  challenge_dir="${ACME_ROOT}/.well-known/acme-challenge"
  mkdir -p -- "$challenge_dir"
  chmod 0755 "$ACME_ROOT" "${ACME_ROOT}/.well-known" "$challenge_dir"
  printf '%s' "$token" > "${challenge_dir}/${token}"
  chmod 0644 "${challenge_dir}/${token}"
  nginx -t || return 1
  systemctl reload nginx || return 1
  for attempt in {1..30}; do
    local_response=$(curl --noproxy '*' -4 -fsS --resolve "${domain}:80:127.0.0.1" --connect-timeout 2 --max-time 4 "http://${domain}/.well-known/acme-challenge/${token}" 2>/dev/null) || local_response=''
    response=$(curl --noproxy '*' -4 -fsS --connect-timeout 2 --max-time 4 "http://${domain}/.well-known/acme-challenge/${token}" 2>/dev/null) || response=''
    if [[ "$local_response" == "$token" && "$response" == "$token" ]]; then
      rm -f -- "${challenge_dir}/${token}"
      return 0
    fi
    sleep 1
  done
  rm -f -- "${challenge_dir}/${token}"
  if [[ "$local_response" != "$token" ]]; then
    log_error "Local Nginx ACME failed: check server_name, root, permissions and conflicting sites."
  else
    log_error "DNS ACME failed: check A/AAAA, CDN/proxy and TCP 80 firewall/security group."
  fi
  return 1
}
'''
    text = text[:start] + replacement + text[end:]
    # Prevent domain/email retyping mistakes while retaining the official admin/password prompts.
    old = '  DOMAIN=$(prompt_validated validate_domain "商城域名" "请输入已解析到本服务器的单个域名（不含 https:// 和路径）" "")'
    old_email = '  ACME_EMAIL=$(prompt_validated validate_email "证书邮箱" "用于 Lets Encrypt 到期通知" "")'
    if text.count(old) != 1 or text.count(old_email) != 1:
        raise ValueError('Domain prompt differs.')
    text = text.replace(old, '  DOMAIN=${SHOP_DOMAIN:?Missing SHOP_DOMAIN}')
    text = text.replace(old_email, '  ACME_EMAIL=${ACME_EMAIL:?Missing ACME_EMAIL}')
    return text

if __name__ == '__main__':
    Path(sys.argv[2]).write_text(patch(Path(sys.argv[1]).read_bytes()), encoding='utf-8', newline='\n')
