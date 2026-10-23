# 全新部署教程：官方独角 Next＋定制 BEpusdt

适用日期：2026-10-24。本文按全新服务器编写，可自行换域名，也可连同部署包交给朋友使用。

**服务器操作统一使用 Netcatty：连接 SSH、粘贴命令，由服务器直接从 GitHub 下载并安装。无需在电脑下载或上传部署包，也无需自己编译。**域名购买、DNS/云安全组设置在服务商网页完成；商城和支付后台配置、付款验收在浏览器完成。

本次只部署商城和 USDT 收款。卡密兑换站、Session 充值、订单页跳转、商城功能精简均不包含在此教程中。商城本身仍支持正常导入和交付商品卡密。

## 快速操作：实际只做这几步

1. 准备全新 Debian 12 x86_64、两个域名；设置 DNS，放行 TCP 80、443 和自己的 SSH 端口。
2. 用 Netcatty 连接，在第 4 节复制一次下载命令。
3. 直接运行 `bash /root/shop-stack-source/deploy/install.sh`。按提示填写四项信息，生成服务器上的私有 `config.env`；再按官方向导设置商城管理员。系统准备、商城、支付、证书、付款提醒和服务检查会依次完成。
4. 按第 9、10 节在网页后台填写收款钱包、RPC 和商城支付渠道；执行第 11 节的配置检查，做一笔真实付款验收。

**正常新装按上面流程即可，不需要再逐一执行 `00-prepare.sh`、`01-mall.sh`、`02-payment.sh`。**中断后仍运行第 3 步同一条命令，已完成的阶段会跳过；不要重新下载或删除配置。

这能减少终端操作，不能省掉 DNS/安全组、管理员设置、钱包和节点信息，也不能用程序安装成功代替真实付款验收。下文保留逐项说明，便于查看字段与排错。

## 1. 这一版使用什么

| 组件 | 固定来源与版本 |
|---|---|
| 独角 Next | 官方 `dujiao-next/dujiao-next`，发行版 `v1.5.0`；程序与前端不作定制 |
| 商城安装器 | 官方提交 `41b86260dc9a60269526057eed8d915844ceb3a3`；包装脚本固定版本、增加下载重试和 ACME 双路径回读 |
| BEpusdt | `7665188-star/BEpusdt` 的 `codex/checkout-fee-notice` 分支，固定提交 `0be695f00aa38d8f961415bd4cfb5fa7f21eab42` |
| BEpusdt 主程序 | 官方 `v1.24.3-0716485`，固定发行文件并校验 SHA256；对应基线 `07164853c38ed43700d3abcaab78e832782d36fa` |
| 新装脚本 | 你的 Fork 中 `codex/ssh-deploy` 分支的 `deploy/` 目录；已包含上述提醒提交 |
| 支付定制 | 仅默认收银台的手续费、实际到账金额提醒，含中英文；不修改支付签名、回调、金额计算 |
| 服务方式 | systemd、Nginx、Let's Encrypt，SQLite；商城使用独立 Redis 实例 |

教程固定的是已经核对的版本，并不表示这些版本永远是最新版。以后更换版本，应重新构建和验收，不要直接把 `latest` 混进本文步骤。

源码：

- 官方商城：https://github.com/dujiao-next/dujiao-next
- 定制分支：https://github.com/7665188-star/BEpusdt/tree/codex/checkout-fee-notice
- 提醒改动：https://github.com/7665188-star/BEpusdt/pull/1

**提醒直接使用你 Fork 的源码。**由于修改仅涉及收银台模板，本教程采用“官方固定主程序＋Fork 收银台模板”，通过 BEpusdt 自带的外部模板机制加载，与当前线上已验证成功的方式一致。新装脚本会自动完成，不需要再执行提醒补丁，也不需要在 VPS 编译。

Fork 默认的 `main` 分支尚未合并提醒。本文下载的是包含提醒的新装分支，并核对脚本及全部收银台文件的 SHA256；不会误装成没有提醒的默认分支。

## 2. 新服务器条件

- Debian GNU/Linux 12，`x86_64` / `amd64`。
- 建议 2 核、4 GB 内存、30 GB 以上磁盘；2 GB 可运行基础部署，但不在服务器现场编译。
- 使用全新、没有其他商城/支付网关的系统。不要在正在营业的服务器上照本文重装。
- 有 root 管理权限；知道 VPS 的真实公网 IPv4、SSH 端口和登录方式。
- 出站能访问 Debian 软件源、GitHub、Let's Encrypt，以及你使用的区块链 RPC。
- 云安全组与系统防火墙允许入站 TCP 80、443，同时保留你实际使用的 SSH 端口。
- 不对外开放 8080、8082、6380；这些是本机内部端口。
- 系统时间已通过 NTP 同步。

本教程采用 IPv4 直连。若服务器没有正确配置 IPv6，**两个域名都不要添加 AAAA 记录**。脚本会拒绝发现的 AAAA，防止浏览器或证书机构走到错误的 IPv6。

## 3. 准备域名、DNS 和钱包

可以用同一主域名的两个子域名，也可以用两个不同域名。下面名称只是示例，不要原样复制为自己的域名：

| 用途 | 示例 | DNS |
|---|---|---|
| 商城 | `shop.example.com` | A → 你的 VPS 公网 IPv4 |
| 支付 | `pay.example.com` | A → 同一 VPS 公网 IPv4 |

先采用“仅 DNS / 灰云 / 不代理”。清理同名错误 A、AAAA 及跳到别处的 CNAME。一个域名不要同时指向多台未部署相同站点的服务器。

提前准备：

1. 接收证书通知的真实邮箱；这不等于已经配置好商城发信 SMTP。
2. 至少一个实际由你控制的 USDT 收款地址，以及完全匹配的链。
3. 相应链的可用 RPC。若带 API Key，只在自己的后台填写。

先使用 USDT-BEP20 跑通本文的验收流程，再按需要加 TRC20 等网络。不要因为地址格式相似就认为不同链可以混用。

## 4. 在 Netcatty 连接服务器并下载新装脚本

只需查看这份教程、在 Netcatty 中运行命令。之前那份需要手动上传压缩包的流程已停用。

### 4.1 建立 SSH 连接

在 Netcatty 新建主机，已有正确连接也可直接使用：

| 连接字段 | 填写内容 |
|---|---|
| 名称 / Label | 自定，例如“新商城服务器” |
| 地址 / Address | VPS 的真实公网 IPv4，不填示例域名 |
| 端口 / Port | 服务商实际 SSH 端口，通常为 22 |
| 用户名 / Username | `root`，本文按 root 直接登录编写 |
| 认证 | 使用服务商提供的密码，或你自己的 SSH 密钥 |

保存并连接，打开该主机的远程终端。出现类似 `root@服务器名:~#` 的提示符后执行：

```bash
whoami
cat /etc/os-release
uname -m
```

应分别确认 `root`、Debian 12、`x86_64`。后文所有命令都在**同一台 VPS 的 Netcatty 远程 SSH 终端**中运行。

### 4.2 复制这一段到远程终端执行

```bash
bash <<'SH'
set -Eeuo pipefail
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3 util-linux
curl --noproxy '*' --proto '=https' --proto-redir '=https' -fsSL \
  --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 10 --max-time 180 \
  https://raw.githubusercontent.com/7665188-star/BEpusdt/codex/ssh-deploy/deploy/bootstrap.sh \
  -o /root/bootstrap-shop-stack.sh
BOOTSTRAP_SHA256='3e9f6724b632415adf80e0ec9dcdba34d6fc3d00844864bd2a1de4b9c55b14f5'
printf '%s  %s\n' "$BOOTSTRAP_SHA256" /root/bootstrap-shop-stack.sh | sha256sum -c -
bash /root/bootstrap-shop-stack.sh
SH
```

服务器会直接下载你的 Fork、核对文件并准备好安装目录。必须看到 `PASS: fork source and deployment scripts downloaded and verified` 再继续。出现下载或校验错误就停止，不要跳过校验。

这段命令只负责下载，不需要键盘输入。下一节的总安装入口必须直接在终端交互运行。下载成功后不要重复执行本节；中断后按第 12 节继续，保留原配置。

按章节逐段执行，看到本段通过再进行下一段，不要一次粘贴整篇教程。若终端显示 `(END)`，先按 **Q** 返回提示符。交互窗口使用 Tab 切换、Enter 确认；退出或断线后重新连接，进入下面的工作目录，再按第 12 节继续：

```bash
cd /root/shop-stack-source/deploy
```

## 5. 一条命令开始安装，四项信息只填一次

下载成功后，在 Netcatty 远程终端直接运行：

```bash
bash /root/shop-stack-source/deploy/install.sh
```

第一次运行会自动打开配置向导，依次输入：商城域名、支付域名、证书邮箱、VPS 公网 IPv4。域名不要带 `https://`、端口或结尾 `/`。不要把总安装命令包在 `bash <<'SH'` 或管道中；它需要读取键盘输入。

脚本会生成 **Debian 服务器上仅 root 可读写的 `config.env`**，后续全部步骤复用，不用重复输入。已有合法配置时不会重新询问。不要把正文示例域名留在里面。

随后自动依次执行四个阶段：系统与域名检查 → 官方商城安装 → 支付服务和提醒安装 → 服务验收。商城管理员账号、密码和安装确认仍按官方向导填写；后台入口、端口保持默认，SMTP 先选择不配置。

完成后终端会集中列出商城、商城后台、支付后台地址，以及支付账号密码的私有文件位置。只表示程序与 HTTPS 已安装完成；接着做第 9、10、11 节，不要提前把正式商品开放收款。

安装开始后保持 `config.env` 不变。总入口会记录阶段和配置校验值；配置被改动时会停止，避免续装到别的域名。域名迁移应另行处理。

## 6. 自动阶段一：系统与 DNS 预检（正常安装无需单独执行）

总入口会自动调用 `00-prepare.sh`。

脚本安装 Nginx、Certbot、Redis、PyYAML 等依赖，检查系统版本、时间和两个域名的解析。不会覆盖现有部署；若发现已有安装会停止。

必须看到两个域名都解析到配置中的唯一公网 IPv4，并且最后出现 `PASS: preparation complete`。

需要复查时，仍在 Netcatty 远程终端运行，无须切换到电脑上的其他终端：

```bash
cd /root/shop-stack-source/deploy
source ./config.env
getent ahostsv4 "$SHOP_DOMAIN"
getent ahostsv4 "$PAY_DOMAIN"
nginx -t
ss -ltn '( sport = :80 )'
```

同一个 IPv4 因 `STREAM`、`DGRAM`、`RAW` 重复显示是正常现象；地址应与你填写的 VPS IPv4 一致。`nginx -t` 应成功，TCP 80 应已监听。

**服务器能解析域名、Nginx 已监听，不等于公网入站已经放通。**在云服务商网页确认 TCP 80、443 入站放行；后续脚本检查本机及域名挑战文件，证书申请还必须通过 Let's Encrypt 的外部验证。任何检查失败都先排查，不跳过验证。这时浏览器访问根目录显示默认页或 404，并不能单独判断证书挑战路径是否正常。

若 NTP 暂未就绪，等待后重跑第 5 节的总安装命令。若 DNS 不符，先修 DNS，不要继续反复申请证书。

## 7. 自动阶段二：安装官方独角 Next（正常安装无需单独执行）

总入口会自动调用 `01-mall.sh`，继续在 Netcatty 中完成官方交互向导。

这是交互式安装，总入口会保留终端供向导使用。

- 域名与证书邮箱从 `config.env` 读取，避免重复输入错误。
- 自行设置管理员账号、密码，保存好；后台路径建议保留生成的随机值。
- 应用端口使用 8080，独立 Redis 使用 6380。全新机器如提示冲突，先停止排查，不要随意换端口。
- 第一遍建议暂不配置 SMTP。站点成功运行后再在后台配置并发送测试邮件。
- 安装器申请证书前会验证随机挑战文件：本机 Host 路由和域名路由必须都返回完全相同的内容。

商城阶段完成后，总入口会继续安装支付，不必暂停来运行下面的诊断命令。需要单独查看商城状态与后台地址时可执行：

```bash
systemctl is-active --no-pager dujiao-next dujiao-next-redis nginx
python3 - <<'PY'
import json
from pathlib import Path
s = json.loads(Path('/etc/dujiao-next/install-state.json').read_text())
print('商城: https://' + s['domain'])
print('后台: https://' + s['domain'] + s['admin_path'] + '/')
print('安装阶段:', s['phase'])
PY
```

应全部为 `active`，阶段为 `installed`。在浏览器访问商城和后台，并登录确认。

管理员密码安装后会从 bootstrap 配置中清除。请自行保存；遗忘时使用官方管理器的 `admin-reset-password`，不要指望安装后还能读出原明文密码。

## 8. 自动阶段三、四：支付安装与服务验收（正常安装无需单独执行）

总入口自动调用 `02-payment.sh`，随后调用 `04-check.sh --services-only` 检查服务、HTTPS 和提醒；这时钱包与支付渠道尚未配置，所以先不执行交易配置检查。

脚本会：

1. 服务器下载并校验固定版本的完整主程序，安装你 Fork 中的完整收银台模板。
2. 以专用 `bepusdt` 用户运行，仅监听 `127.0.0.1:8082`。
3. 在本机完成首次初始化，将凭据保存到 root 私有文件。
4. 自动将应用 URI 设置成你填写的支付域名，收银台设为“官方默认”。
5. 重启并确认首次凭据页面关闭、安装锁生效。
6. 检查支付域名 ACME 文件，申请证书，启用 HTTPS，并验证网关和提醒文案。

必须看到 `PASS: payment service is published with fork checkout notice 0be695f`。

**本节已经自动安装提醒，不再单独执行旧的 `07-update-bepusdt-notice.sh`，也不用上传旧补丁包。**主程序的版本命令仍显示 `v1.24.3-0716485` 是正常的；提醒是否加载以脚本检查和实际付款页为准。

查看后台地址、账号、密码（仅在自己的 SSH 查看）：

```bash
sed -n -e '/^后台地址:/p' -e '/^登录账号:/p' -e '/^登录密码:/p' \
  /root/shop-stack/bepusdt-credentials.txt
```

对接令牌在同一私有文件中，也可在 BEpusdt 后台 API 设置中查看。不需要把它贴到聊天、截图或教程里。

此时先登录 BEpusdt 后台，修改首次密码并妥善保存。后台安全入口、数据库和 API Token 不要对外分享。

## 9. BEpusdt 后台配置

### 9.1 API 设置

- 应用 URI：`https://你的支付域名`，脚本已设置，核对即可。
- 前台收银模板：**官方默认**。提醒只在此模板中定制。
- 对接令牌：保留，由商城支付渠道使用。
- 若添加客服链接，填你实际使用的公开客服地址。

### 9.2 钱包管理

先添加一个 USDT-BEP20 钱包：

- 名称可自定，例如 `USDT-BEP20`。
- 交易类型：`usdt.bep20`。
- 地址：你的真实 BSC 收款地址。
- 收款状态：启用。

只填收款地址，不向商城或支付网关导入钱包私钥/助记词。

### 9.3 区块节点

设置自己可用的 BSC 主网 RPC。之前出现过公共节点 HTTP 403，因此不要照抄一个未经你服务器测试的公共地址当作可用节点。

使用带 Key 的 RPC 时按服务商提供的完整 HTTPS URL 填写。至少需要：BSC 主网链 ID 56、最新区块可读、批量区块读取、Transfer 日志、交易回执读取。

仅添加钱包并显示“启用”不代表节点能正常监听。后面的检查脚本会读你已配置的真实节点验证上述能力。

## 10. 独角后台配置 BEpusdt 渠道

进入独角后台 → 支付管理 → 支付渠道，新增：

| 字段 | 内容 |
|---|---|
| 名称 | `USDT支付（BEP20）` |
| 渠道类型 | BEpusdt |
| 订单接口模式 | 指定交易类型 |
| 支付币种 / 交易类型 | `usdt.bep20` |
| 法币类型 | CNY |
| 支付网关 | `https://你的支付域名` |
| 对接令牌 | BEpusdt 的 API Token |
| 异步通知地址 | `https://你的商城域名/api/v1/payments/callback` |
| 同步回跳地址 | `https://你的商城域名/pay` |
| 交互方式 | 跳转 |
| 百分比、固定手续费 | 先都填 0 |
| 付款类型限制 | 留空，或包含“订单支付” |
| 付款角色限制 | 留空，或包含“游客”及你要支持的其他角色 |
| 状态 | 启用 |

先保持“向用户加收渠道手续费（兼容模式）”关闭，商家承担。关闭时前台不显示两行零手续费属于正常行为。若确实要显示，先确认全部渠道费率和固定费均为 0，再开启该策略；非零值会影响新支付的实付金额。

这两行是商城渠道手续费，与 BEpusdt 提醒中的交易所提币费、链上网络费并不是同一种费用。

如在商品中设置了“允许的支付渠道”，记得选择此渠道；留空表示不限制。后来新增渠道却前台不显示时，先检查商品允许范围、游客限制、订单类型及金额区间，再重新进入购物车结算。

## 11. 上架、检查与真实交易验收

先建一个仅供自己测试的商品：自动交付，导入一条普通测试内容，例如 `PAYMENT-TEST-OK`。用你愿意承担的测试金额标价，并确认转换后的 USDT 金额满足交易所最低提币额以及 BEpusdt 最小金额。

配置完成后：

```bash
cd /root/shop-stack-source/deploy
bash 04-check.sh
```

应确认服务、HTTPS、安装锁、应用 URI、提醒、BEP20 钱包、商城支付渠道、Token 匹配与 BSC RPC 均通过。脚本不打印 Token、钱包地址或完整 RPC URL。

出现 `READY` 只代表静态配置与只读节点检查通过；**尚不等于真实支付/回调已验证**。

随后做一笔真实交易：

1. 在前台选择测试商品；游客购买时自行填写邮箱和订单密码。
2. 选择 USDT-BEP20，提交订单，跳入你的支付域名。
3. 检查应付币种、网络、地址和醒目的手续费提醒。若是旧浏览器缓存，Ctrl＋F5 刷新。
4. 在钱包/交易所选择完全相同的网络，确保实际到账金额与页面显示一致。手续费从转出金额扣除时，按付款平台提示补足差额，不要把它理解成固定多付 0.01。
5. 支付网关确认成功，回到商城，核对订单已付款、交付完成且显示测试内容。
6. 同时核对钱包实际到账。三者一致后才上架正式商品。

整个过程中没有人需要你把真实银行卡、钱包私钥、Token、订单查询密码发出来。

### 增加 TRC20 或其他网络

每新增一条链，都要配置相应钱包、可用节点/服务商凭证，并在独角新增独立渠道。例如 TRC20 为 `usdt.trc20`，X Layer 为 `usdt.xlayer`。保持 CNY、支付网关和商城回调地址一致，渠道名称写清币种与网络。

`04-check.sh` 的节点深度检查只覆盖 BEP20，不代表 TRC20/X Layer 也通过。新链需独立完成真实付款、回调与交付测试；本文不假定它们共享 BSC RPC。

## 12. 404 排查：分清发生在哪一步

此次遇到过的情况是：安装时挑战回读先出现 404，稍后本机与域名访问都恢复 200。没有足够证据把它认定为单一原因。本版通过双路径、随机文件、Nginx 重载后重试来处理瞬时状态，并在持续失败时给出定位方向。

| 现象 | 优先检查 |
|---|---|
| ACME 阶段访问根目录 `/` 是 404 | 可能是脚本刻意关闭商城/支付应用；应检查随机挑战文件，而不是根目录 |
| 随机挑战文件在本机 Host 请求也失败 | Nginx `server_name`、挑战 `root`、目录权限、重复站点或配置尚未加载 |
| 本机成功，按域名失败 | A/AAAA、CDN/代理、云安全组、TCP 80 或 DNS 未生效 |
| HTTPS 的商城 `/health` 失败 | 商城进程、代理端口、证书或站点配置 |
| 只有某条链收不到付款 | 钱包类型、RPC、金额和链上交易；不属于 ACME 404 |

使用总入口安装时，失败后保留所有文件，修复提示的问题，再运行同一条命令：

```bash
bash /root/shop-stack-source/deploy/install.sh
```

总入口会从已记录的阶段继续；商城和支付内部也保留各自的断点状态。若服务验收失败，修复对应服务后重跑，总入口会重新验收。它不重置管理员、钱包或 Token，也不是升级/修复数据库的工具。

只有明确按分步脚本安装或定向排错时，才单独运行对应的 `00-prepare.sh`、`01-mall.sh`、`02-payment.sh`；不要把整篇教程中的诊断命令也当成必做步骤。

不要删数据库、安装状态、证书目录，也不要反复换域名碰运气。脚本若提示“unmanaged/existing/differs”，先停止核对，不能通过删文件绕过去。

诊断命令：

```bash
nginx -t
systemctl --no-pager --full status dujiao-next dujiao-next-redis bepusdt nginx
ss -ltn '( sport = :80 or sport = :443 or sport = :8080 or sport = :8082 or sport = :6380 )'
```

日志可能包含私密初始化信息；只在自己服务器查看，分享前不要带账号密码、Token、RPC Key 或完整配置。

## 13. 证书续期、备份与日常维护

```bash
systemctl is-active --no-pager certbot.timer
systemctl list-timers --no-pager certbot.timer
certbot renew --dry-run
```

Nginx 保留了 HTTP 的 ACME 路径，续期后有部署钩子重载 Nginx。以后换 DNS/CDN/防火墙，也要保持证书验证路径可用。

需要备份的内容：

- 商城：`/opt/dujiao-next/` 的配置、数据库、上传目录；`/etc/dujiao-next/` 的安装状态和 Redis 配置。
- 支付：`/var/lib/bepusdt/`、`/root/shop-stack/bepusdt-credentials.txt`、`/etc/shop-stack/`。
- 系统：相应 systemd unit、Nginx 站点、`/etc/letsencrypt/` 证书及续期配置。
- `/root/shop-stack-source/` 中的安装脚本、你的 `deploy/config.env`、`deploy/.install-progress`、SHA256SUMS、SOURCE.json。

复制正在写入的 SQLite 单文件可能遗漏 WAL。需要做数据库备份时，使用 SQLite backup API，或在维护窗口停止对应服务后完整备份其数据目录；不要只复制一个正在使用的 `.db` 文件当作可靠备份。

本教程是**新装教程，不是通用升级/卸载脚本**。升级时应保留数据库、钱包与 Token，先备份，再针对新版本制作包和验证；不要直接重跑新装流程覆盖营业系统。

## 14. 交付验证范围

服务器直接从 GitHub 下载，入口脚本、安装文件、Fork 收银台和主程序发行文件均有 SHA256 校验。主程序使用完整官方发行版，收银台取自你 Fork 的固定提醒提交。脚本会在实际服务器逐步验收配置、证书、初始化保护和服务健康。

本地脚本/构建测试通过不代表每一台新 VPS 已做真实部署或真实转账。域名注册状态、DNS 传播、安全组、软件源/RPC 可达性与最终付款，需要按本文在目标环境确认。教程以“检查通过再继续”减少错误，不作任何环境都必然一次成功的承诺。
