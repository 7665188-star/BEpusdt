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
repo_prefix=$(python3 - "$download_dir/source.tar.gz" <<'PY'
import re
import sys
import tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    name = archive.getmembers()[0].name.split('/')[0]
if name in {'.', '..'} or not re.fullmatch(r'[A-Za-z0-9_.-]+', name):
    raise SystemExit('ERROR: Unexpected source archive prefix.')
print(name)
PY
)
# Extract deployment helpers only. Neither fork application source nor checkout
# templates are installed; application executables come from official releases.
tar --no-same-owner --strip-components=1 -xzf "$download_dir/source.tar.gz" -C "$download_dir/source" "$repo_prefix/deploy"
cd "$download_dir/source/deploy"
printf '%s  %s\n' '8e3c924840f5e95ddcff867d421327266987c538666fa945a46a5cf818879d0b' SHA256SUMS | sha256sum -c -
python3 - <<'PY'
from pathlib import Path
base = Path.cwd()
listed = {row.split('  ', 1)[1] for row in (base/'SHA256SUMS').read_text().splitlines()}
actual = set()
for path in base.rglob('*'):
    if path.is_symlink():
        raise SystemExit('ERROR: Unexpected symlink in deployment files.')
    if path.is_file():
        name = path.relative_to(base).as_posix()
        if name not in {'README.md', 'bootstrap.sh', 'SHA256SUMS'}:
            actual.add(name)
if actual != listed:
    raise SystemExit('ERROR: Downloaded file inventory differs from the pinned manifest.')
PY
sha256sum --quiet -c SHA256SUMS
cd "$download_dir"
mv -- "$download_dir/source" "$target"
echo 'PASS: deployment scripts downloaded and verified.'
echo 'Next: bash /root/shop-stack-source/deploy/install.sh'
