#!/usr/bin/env bash
# Interactive entry point; each underlying installer retains its own checks.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $EUID -eq 0 ]] || die '请使用 root 运行。'
[[ -t 0 && -t 1 ]] || die '请在 Netcatty 的远程终端直接运行本命令，不要放进管道或 here-document。'
verify_bundle
command -v flock >/dev/null || die '缺少 flock，请先按教程安装 util-linux。'
exec 9>"$STACK_ROOT/../.install.lock"
flock -n 9 || die '另一份安装正在运行，请回到原终端查看。'
progress="$STACK_ROOT/.install-progress"
current_step='读取配置'
trap 'result=$?; printf "\n安装在【%s】停止，退出码 %s。保留现有文件，修复提示的问题后运行：\nbash /root/shop-stack-source/deploy/install.sh\n" "$current_step" "$result" >&2' ERR

if [[ ! -e $progress ]]; then
  for existing in /etc/dujiao-next/install-state.json /etc/shop-stack/payment.json \
    /etc/systemd/system/dujiao-next.service /etc/systemd/system/bepusdt.service \
    /var/lib/bepusdt/sqlite.db /opt/dujiao-next/config.yml; do
    [[ ! -e $existing ]] || die "发现已有部署 $existing；此入口仅供全新部署，不能接管现有网站。"
  done
fi
if [[ ! -f $STACK_ROOT/config.env ]]; then
  [[ ! -e $progress ]] || die '安装配置 config.env 缺失，请恢复原文件后继续。'
  bash "$STACK_ROOT/configure.sh"
fi
load_config
config_sha=$(sha256sum "$STACK_ROOT/config.env" | cut -d ' ' -f 1)
phase=configured
if [[ -e $progress ]]; then
  [[ -f $progress && ! -L $progress ]] || die '安装进度文件异常，请保留文件并检查。'
  read -r saved_sha phase extra < "$progress"
  [[ -z ${extra:-} && $saved_sha == "$config_sha" ]] || die 'config.env 与开始安装时不一致，请恢复原配置后继续。'
  case "$phase" in configured|prepared|mall_installed|payment_installed) ;; *) die '安装进度无法识别，请保留文件并检查。' ;; esac
fi
save_phase() {
  local next=$1 temp
  temp=$(mktemp "$STACK_ROOT/.install-progress.XXXXXXXX")
  printf '%s %s\n' "$config_sha" "$next" > "$temp"
  chmod 0600 "$temp"
  mv -f -- "$temp" "$progress"
  phase=$next
}
[[ -e $progress ]] || save_phase configured

if [[ $phase == configured ]]; then
  current_step='1/4 系统与域名检查'
  printf '\n=== %s ===\n' "$current_step"
  bash "$STACK_ROOT/00-prepare.sh"
  save_phase prepared
fi
if [[ $phase == prepared ]]; then
  current_step='2/4 官方商城安装'
  printf '\n=== %s：按向导设置管理员，其余先用默认值；SMTP 先不配置 ===\n' "$current_step"
  bash "$STACK_ROOT/01-mall.sh"
  save_phase mall_installed
fi
if [[ $phase == mall_installed ]]; then
  current_step='3/4 支付服务与提醒安装'
  printf '\n=== %s ===\n' "$current_step"
  bash "$STACK_ROOT/02-payment.sh"
  save_phase payment_installed
fi
current_step='4/4 服务验收'
printf '\n=== %s ===\n' "$current_step"
bash "$STACK_ROOT/04-check.sh" --services-only
python3 - <<'PY'
import json
import os
from pathlib import Path
state = json.loads(Path('/etc/dujiao-next/install-state.json').read_text())
print('\n程序安装与服务检查已完成。')
print('商城：https://' + os.environ['SHOP_DOMAIN'])
print('商城后台：https://' + state['domain'] + state['admin_path'] + '/')
for line in Path('/root/shop-stack/bepusdt-credentials.txt').read_text().splitlines():
    if line.startswith('后台地址:'):
        print('支付' + line)
print('支付账号密码：/root/shop-stack/bepusdt-credentials.txt（仅自己查看）')
print('下一步：按教程在后台填写钱包、RPC 和商城支付渠道。')
print('配置完成后运行：bash /root/shop-stack-source/deploy/04-check.sh')
print('最后完成一次真实付款、回调与交付测试。')
PY
