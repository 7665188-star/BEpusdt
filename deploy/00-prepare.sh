#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $EUID -eq 0 ]] || die 'Run as root.'
source /etc/os-release
[[ $ID == debian && $VERSION_ID == 12 && $(uname -m) == x86_64 ]] || die 'This bundle requires fresh Debian 12 x86_64.'
for path in /etc/systemd/system/dujiao-next.service /etc/systemd/system/bepusdt.service /var/lib/bepusdt/sqlite.db /opt/dujiao-next/config.yml; do
  [[ ! -e $path ]] || die "Existing deployment found at $path; do not run a fresh-install guide over it."
done
verify_bundle
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3 python3-yaml jq openssl nginx certbot iproute2 tar util-linux whiptail redis-server diffutils
load_config
check_dns
timedatectl set-ntp true
[[ $(timedatectl show -p NTPSynchronized --value) == yes ]] || die 'Clock synchronization is not ready. Wait and rerun this preparation step.'
printf '\n=== Resources ===\n'
free -h
df -h /
printf '\n=== Existing public listeners ===\n'
ss -ltnp '( sport = :80 or sport = :443 )'
echo 'PASS: preparation complete. Verify cloud TCP 80/443 and keep your SSH port open before continuing.'
