#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'ERROR: Run as root.' >&2; exit 1; }
source /etc/os-release
[[ $ID == debian && $VERSION_ID == 12 && $(uname -m) == x86_64 ]] || { echo 'ERROR: Requires Debian 12 x86_64.' >&2; exit 1; }
target=/root/shop-stack-source
[[ ! -e $target && ! -L $target ]] || { echo 'ERROR: /root/shop-stack-source already exists. Keep its configuration; resume the existing installation instead of downloading again.' >&2; exit 1; }
download_dir=$(mktemp -d /root/shop-stack-download.XXXXXXXX)
curl --noproxy '*' --proto '=https' --proto-redir '=https' -fsSL \
  --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 10 --max-time 600 \
  https://codeload.github.com/7665188-star/BEpusdt/tar.gz/refs/heads/codex/ssh-deploy \
  -o "$download_dir/source.tar.gz"
mkdir "$download_dir/source"
tar --no-same-owner --strip-components=1 -xzf "$download_dir/source.tar.gz" -C "$download_dir/source"
cd "$download_dir/source/deploy"
printf '%s  %s\n' 'a58f3e2f24337317a6625722ae4df029cb8aa03643c6fe3c60f9e4c313562301' SHA256SUMS | sha256sum -c -
python3 - <<'PY'
from pathlib import Path
base = Path.cwd()
listed = {row.split('  ', 1)[1] for row in (base/'SHA256SUMS').read_text().splitlines()}
actual = set()
for folder, prefix in ((base, ''), (base.parent/'static/checkout', '../static/checkout/')):
    for path in folder.rglob('*'):
        if path.is_symlink():
            raise SystemExit('ERROR: Unexpected symlink in deployment or checkout files.')
        if path.is_file():
            name = prefix + path.relative_to(folder).as_posix()
            if prefix or name not in {'README.md', 'bootstrap.sh', 'SHA256SUMS'}:
                actual.add(name)
if actual != listed:
    raise SystemExit('ERROR: Downloaded file inventory differs from the pinned manifest.')
PY
sha256sum --quiet -c SHA256SUMS
cd "$download_dir"
mv -- "$download_dir/source" "$target"
echo 'PASS: fork source and deployment scripts downloaded and verified.'
echo 'Next: cd /root/shop-stack-source/deploy'
echo 'Then run bash configure.sh directly in your SSH terminal.'
