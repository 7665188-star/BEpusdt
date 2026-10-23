#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
verify_bundle
load_config
check_dns
state=/etc/shop-stack/payment.json
work=/root/shop-stack
site=/etc/nginx/sites-available/bepusdt.conf
enabled=/etc/nginx/sites-enabled/bepusdt.conf
webroot=/var/www/bepusdt-acme
marker='# Managed by portable shop-stack BEpusdt'
cert_name="bepusdt-$(printf '%s' "$PAY_DOMAIN" | sha256sum | cut -c1-16)"
live=/etc/letsencrypt/live/$cert_name
[[ -f /etc/dujiao-next/install-state.json ]] || die 'Complete step 01 first.'
[[ $(jq -r .domain /etc/dujiao-next/install-state.json) == "$SHOP_DOMAIN" ]] || die 'Shop domain does not match.'
[[ $(jq -r .phase /etc/dujiao-next/install-state.json) == installed ]] || die 'Shop installation has not completed.'
curl_direct -fsS --connect-timeout 3 --max-time 12 "https://$SHOP_DOMAIN/health" | python3 -c 'import json,sys; assert json.load(sys.stdin).get("status")=="ok"'

if [[ -f $state ]]; then
  [[ $(jq -r .domain "$state") == "$PAY_DOMAIN" ]] || die 'Stored payment domain differs. Do not overwrite an existing deployment.'
else
  for existing in /var/lib/bepusdt/sqlite.db /etc/systemd/system/bepusdt.service /opt/bepusdt/bepusdt "$site" "$enabled"; do
    [[ ! -e $existing && ! -L $existing ]] || die "Unmanaged existing installation: $existing"
  done
  [[ -z $(ss -ltnH 'sport = :8082') ]] || die 'Port 8082 is already occupied.'
  install -d -m 0700 /etc/shop-stack
  jq -n --arg domain "$PAY_DOMAIN" '{domain:$domain,phase:"prepared",commit:"0be695f00aa38d8f961415bd4cfb5fa7f21eab42"}' > "$state"
fi
install -d -m 0700 "$work"
getent passwd bepusdt >/dev/null || useradd --system --user-group --home-dir /var/lib/bepusdt --shell /usr/sbin/nologin bepusdt
install -d -m 0700 "$work/downloads" "$work/release"
release_archive="$work/downloads/linux-amd64-BEpusdt-v1.24.3.tar.gz"
release_sha=b8c9769315282880653f5f674eb2ef33ae2a8be138d924dc4b3172f17d0d2f21
if ! printf '%s  %s\n' "$release_sha" "$release_archive" | sha256sum --status -c -; then
  curl_direct -fsSL --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 10 --max-time 600 \
    https://github.com/v03413/BEpusdt/releases/download/v1.24.3/linux-amd64-BEpusdt.tar.gz \
    -o "$release_archive.part"
  printf '%s  %s\n' "$release_sha" "$release_archive.part" | sha256sum -c -
  mv -f -- "$release_archive.part" "$release_archive"
fi
tar --no-same-owner -xzf "$release_archive" -C "$work/release" bepusdt
install -d -o root -g root -m 0755 /opt/bepusdt
if [[ -e /opt/bepusdt/bepusdt ]]; then
  cmp "$work/release/bepusdt" /opt/bepusdt/bepusdt || die 'Installed binary differs from the pinned release.'
else
  install -o root -g root -m 0755 "$work/release/bepusdt" /opt/bepusdt/bepusdt
fi
install -d -o bepusdt -g bepusdt -m 0750 /var/lib/bepusdt /var/log/bepusdt
install -d -o root -g bepusdt -m 0750 /var/lib/bepusdt/static
checkout_source="$STACK_ROOT/../static/checkout"
checkout_target=/var/lib/bepusdt/static/checkout
[[ -d $checkout_source ]] || die 'Fork checkout source is missing; download the complete repository with bootstrap.sh.'
if [[ -e $checkout_target || -L $checkout_target ]]; then
  [[ -d $checkout_target && ! -L $checkout_target ]] || die 'Unexpected checkout target.'
  diff -qr "$checkout_source" "$checkout_target" || die 'Existing checkout differs from this pinned fork; preserve it and inspect.'
else
  checkout_stage=$(mktemp -d /var/lib/bepusdt/static/.checkout-XXXXXXXX)
  cp -a "$checkout_source/." "$checkout_stage/"
  chown -R root:bepusdt "$checkout_stage"
  find "$checkout_stage" -type d -exec chmod 0750 {} +
  find "$checkout_stage" -type f -exec chmod 0640 {} +
  mv -T -- "$checkout_stage" "$checkout_target"
fi
touch /var/log/bepusdt/console.log
chown root:root /var/log/bepusdt/console.log
chmod 0600 /var/log/bepusdt/console.log
if [[ -f /etc/systemd/system/bepusdt.service ]]; then
  [[ $(head -n 1 /etc/systemd/system/bepusdt.service) == "$marker" ]] || die 'Unexpected service unit.'
fi
cat > /etc/systemd/system/bepusdt.service <<'UNIT'
# Managed by portable shop-stack BEpusdt
[Unit]
Description=BEpusdt v1.24.3 with fork checkout 0be695f
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=bepusdt
Group=bepusdt
WorkingDirectory=/var/lib/bepusdt
ExecStart=/opt/bepusdt/bepusdt start --listen 127.0.0.1:8082 --sqlite /var/lib/bepusdt/sqlite.db --log /var/log/bepusdt
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/bepusdt /var/log/bepusdt
StandardOutput=append:/var/log/bepusdt/console.log
StandardError=inherit
[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 /etc/systemd/system/bepusdt.service
systemctl daemon-reload
systemctl enable --now bepusdt
ready=0
for attempt in {1..60}; do
  if curl_direct -fsS --connect-timeout 1 --max-time 2 http://127.0.0.1:8082/ -o "$work/payment-local.html" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[[ $ready == 1 ]] || die 'Local payment service is not ready. Keep it private and inspect its service status.'

if [[ $(jq -r .phase "$state") == prepared ]]; then
  systemctl stop bepusdt
  # On any initialization error, keep the service private. Re-running resumes the same DB.
  python3 - "$PAY_DOMAIN" "$work/bepusdt-credentials.txt" <<'PY'
from pathlib import Path
from contextlib import closing
import re, sqlite3, sys
log = Path('/var/log/bepusdt/console.log').read_text(encoding='utf-8', errors='replace')
values = {}
for key in ('登录账号','登录密码','安全入口','对接令牌'):
    matches = re.findall(re.escape(key)+r':\s*(\S+)', log)
    if len(matches) != 1:
        raise SystemExit('Initial credentials could not be identified; payment site remains private.')
    values[key] = matches[0]
if not re.fullmatch(r'/[a-f0-9]{10}', values['安全入口']):
    raise SystemExit('Unexpected admin path; payment site remains private.')
with closing(sqlite3.connect('/var/lib/bepusdt/sqlite.db')) as db:
    if db.execute("SELECT v FROM bep_conf WHERE k='system_install_lock'").fetchone() != ('1',):
        raise SystemExit('Installation lock is missing; payment site remains private.')
    db.execute("UPDATE bep_conf SET v=? WHERE k='api_app_uri'", ('https://'+sys.argv[1],))
    db.execute("UPDATE bep_conf SET v='official' WHERE k='payment_checkout'")
    db.commit()
target = Path(sys.argv[2])
target.write_text('后台地址: https://'+sys.argv[1]+values['安全入口']+'\n'+'\n'.join(k+': '+v for k,v in values.items())+'\n', encoding='utf-8')
target.chmod(0o600)
print('PASS: credentials saved privately and application URI configured.')
PY
  systemctl start bepusdt
fi
python3 "$STACK_ROOT/private-check.py" "$PAY_DOMAIN"
jq '.phase="initialized"' "$state" > "$state.next" && mv -f "$state.next" "$state"

if [[ -f $site ]]; then
  [[ $(head -n 1 "$site") == "$marker" ]] || die 'Unmanaged payment Nginx site exists.'
fi
if [[ -e $enabled || -L $enabled ]]; then
  [[ -L $enabled && $(readlink "$enabled") == "$site" ]] || die 'Unmanaged enabled payment Nginx site exists.'
fi
cat > "$work/payment-acme.conf" <<EOF
$marker
server {
    listen 80;
    server_name $PAY_DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $webroot;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOF
install -m 0644 "$work/payment-acme.conf" "$site"
ln -sfn "$site" "$enabled"
check_acme "$PAY_DOMAIN" "$webroot"
if [[ ! -s $live/fullchain.pem || ! -s $live/privkey.pem ]]; then
  certbot certonly --webroot -w "$webroot" -d "$PAY_DOMAIN" --cert-name "$cert_name" --email "$ACME_EMAIL" --agree-tos --no-eff-email --non-interactive
fi
openssl x509 -in "$live/fullchain.pem" -noout -checkhost "$PAY_DOMAIN" >/dev/null
cat > "$work/payment-https.conf" <<EOF
$marker
server {
    listen 80;
    server_name $PAY_DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $webroot;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name $PAY_DOMAIN;
    ssl_certificate $live/fullchain.pem;
    ssl_certificate_key $live/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 10m;
    location / {
        proxy_pass http://127.0.0.1:8082;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 10s;
        proxy_read_timeout 120s;
    }
}
EOF
install -m 0644 "$work/payment-https.conf" "$site"
nginx -t
systemctl reload nginx
if ! python3 "$STACK_ROOT/private-check.py" "$PAY_DOMAIN" --public; then
  install -m 0644 "$work/payment-acme.conf" "$site"
  nginx -t && systemctl reload nginx
  die 'HTTPS verification failed; payment app is no longer published. Fix the reported issue and rerun this step.'
fi
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/shop-stack-nginx <<'HOOK'
#!/bin/sh
set -eu
nginx -t
systemctl reload nginx
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/shop-stack-nginx
systemctl enable --now certbot.timer
jq '.phase="published"' "$state" > "$state.next" && mv -f "$state.next" "$state"
echo 'PASS: payment service is published with fork checkout notice 0be695f.'
echo 'Private credentials: /root/shop-stack/bepusdt-credentials.txt'
echo 'Next: configure receiving wallets, RPC and mall payment channels; complete a real payment test.'
