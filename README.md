# Xray-OneClick

> 基于 **Xray-core** 的菜单式个人服务器安装脚本，支持 **Shadowsocks 2022**、**VLESS Encryption**、**VLESS TCP REALITY**、**XHTTP + FinalMask** 和可选 **SOCKS5**。

![Core](https://img.shields.io/badge/Core-Xray-blue)
![License](https://img.shields.io/badge/License-GPLv3-orange)

> `0.2.0-beta.2` 是实机反馈修复版，仍不标记为稳定版。本版修复新版 Xray `x25519` 输出解析，并调整主菜单顺序，让 Reality / XHTTP 紧挨 VLESS Encryption。Reality 相对稳定，XHTTP + FinalMask 仍是实验功能，仍需真实 VPS 和客户端测试，不承诺所有客户端都兼容 FinalMask / `fm` 分享链接。本项目仅供学习和合法网络测试使用，请遵守所在地法律法规和服务商条款。

## 版本状态

- 当前版本：`0.2.0-beta.2`
- 定位：实机反馈修复版，不是 stable。
- Reality：默认 TCP + REALITY + Vision flow，适合进入 VPS 实机烟测。
- XHTTP + FinalMask：实验能力，客户端兼容性取决于 Xray-core / 客户端内核版本。
- 升级建议：从 alpha.1 / alpha.2 / alpha.3 / alpha.4 升级后先运行 `ike doctor all`，再运行 `ike migrate --dry-run`。
- beta.2 修复点：Xray 26.3.x 实机测试中，`xray x25519` 可能输出 `PrivateKey` / `Password` / `Hash32` 新格式；脚本现在会把 `PrivateKey` 用作服务端 `privateKey`，把 `Password` 映射为客户端 `publicKey`，忽略 `Hash32`。

## beta.2 实机反馈记录

已确认：

- Xray latest `26.3.27` 可安装。
- SS2022 可安装。
- VLESS Encryption 可安装。
- SOCKS5 可安装。
- XHTTP + FinalMask 可写入配置并成功重启 systemd。

beta.1 的 Reality 失败点是新版 `xray x25519` 输出解析，beta.2 已修复。Reality 仍需用户复测客户端连通性；XHTTP + FinalMask 虽然服务端写入成功，客户端兼容性仍需继续测试。

## 适合谁使用

本项目适合个人 Linux VPS 快速部署、测试和维护 Xray 多协议节点，尤其适合需要菜单式操作、轻量 systemd 管理和少量节点配置的场景。

它不适合复杂中转、面板化运维、多节点编排、细粒度用户管理等重场景；这类需求建议使用专门的面板或自行维护 Xray 配置。

## 功能概览

- **默认核心为 Xray**：通过 GitHub Releases 获取 `XTLS/Xray-core`，支持 latest、指定版本和 `XRAY_GITHUB_MIRRORS` 镜像兜底。
- **Shadowsocks 2022**：支持 `2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305`。
- **VLESS Encryption**：调用 `xray vlessenc` 生成服务端 `decryption` 和客户端 `encryption`，支持基础模式和高级模式。
- **VLESS TCP REALITY**：支持随机或指定入口端口、随机或指定伪装域名，自动生成 UUID、X25519 密钥、Vision flow 和 8 个 shortId。
- **VLESS Encryption + XHTTP + FinalMask**：复用现有 VLESS Encryption 生成逻辑，支持 XHTTP path 和实验性 FinalMask 模板，可关闭 FinalMask。
- **安装兼容收敛**：提供 `ike preflight`、Xray 版本检测/升级、systemd service 修复、重复安装幂等、旧 state 迁移和安全卸载。
- **诊断与烟测辅助**：提供 `ike doctor reality|xhttp|proxy|all`、`ike smoke reality|xhttp|all`、安装 `--dry-run` 和脱敏导出。
- **可选 SOCKS5**：适合临时代理或内网测试。
- **Tunnel 中转管理**：基于 Xray 官方 Tunnel（旧称 `dokodemo-door`）实现应用层 TCP/UDP 中转，支持 single、实验性 portMap、safe / relay、group 分组。
- **Endpoint 管理**：可设置用户实际连接地址，适配 NAT、小鸡端口映射、DDNS 和多公网 IP 场景。
- **菜单式维护**：支持安装/更新核心、安装协议、查看链接、切换链接显示模式、重置密钥、卸载和清理。
- **默认安全屏蔽**：默认阻断 BT/PT、私网地址、SMTP、SMB/NetBIOS 等高风险目标。
- **可选中国大陆直连屏蔽**：可在服务端通过 Xray routing 阻断发往 `geoip:cn` / `geosite:cn` 的流量。
- **systemd 管理**：生成 `/etc/systemd/system/xray.service`，配置校验通过后重启服务。

## 快速开始

### 本地未提交版本测试

如果当前代码还只是本地修改，尚未确认提交并推送到 GitHub `main` 分支，请不要使用 `raw.githubusercontent.com` 测试，否则可能拉到线上旧版本脚本。

先从本机上传当前工作区里的 `install.sh`：

```bash
scp ./install.sh root@YOUR_SERVER_IP:/root/install.sh
```

然后在 Linux VPS 上执行：

```bash
ssh root@YOUR_SERVER_IP
chmod +x /root/install.sh
bash /root/install.sh
```

Alpine 系统可先安装基础依赖：

```bash
apk update && apk add bash curl
bash /root/install.sh
```

### 已提交到 GitHub 后一键安装

只有确认当前代码已经提交并推送到 GitHub `main` 分支后，才推荐使用线上安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh -o install.sh && bash install.sh
```

## 快捷命令

安装完成后使用 `ike` 进入菜单：

```bash
ike
```

常用直接命令：

```bash
ike view
ike view ipv4
ike view ipv6
ike view doctor
ike preflight
ike doctor all
ike doctor preflight
ike doctor proxy
ike doctor reality-key
ike doctor reality
ike doctor xhttp
ike smoke reality
ike smoke xhttp --restart
ike smoke all
ike export report --output /root/xray-report.txt
ike export clients --output /root/xray-clients.txt
ike help
ike version
ike update
ike xray version
ike xray upgrade
ike xray upgrade --version v25.1.1
ike xray upgrade --dry-run
ike backup
ike bootstrap
ike endpoint show
ike endpoint set
ike endpoint clear
ike endpoint detect
ike config path
ike config test
ike config edit
ike service status
ike service install
ike service restart
ike service logs
ike service repair
ike logs
ike migrate --dry-run
ike migrate
ike uninstall --dry-run
ike uninstall --keep-config
ike uninstall --purge --yes
ike cnblock
ike cnblock basic
ike cnblock enhanced
ike cnblock off
ike safety enhanced on
ike safety enhanced off
ike reality install
ike reality install --dry-run
ike reality install --port 30004
ike reality install --defender-port 40004
ike reality install --sni www.abmindustriesgroup.com
ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com
ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com --dry-run
ike reality show
ike reality remove
ike xhttp install
ike xhttp install --dry-run
ike xhttp install --port 30005 --path /api/test --finalmask on
ike xhttp install --port 30005 --path /api/test --finalmask off
ike xhttp install --port 30005 --path /api/test --finalmask on --dry-run
ike xhttp show
ike xhttp remove
ike view reality
ike view xhttp
ike tunnel list
ike tunnel add
ike tunnel add safe
ike tunnel add relay
ike tunnel add map
ike tunnel enable
ike tunnel disable
ike tunnel edit
ike tunnel test
ike tunnel doctor
ike tunnel group list
ike tunnel group doctor
ike tunnel template
ike tunnel ports
ike tunnel export
ike tunnel import
ike tunnel import /path/to/tunnels.json --yes
ike tunnel bundle export
ike tunnel bundle import /path/to/tunnels.json --yes
ike tunnel generate-script
ike tunnel generate-relay-script
ike tunnel generate-client-script
ike tunnel del
```

`ike view` 是快速模式，主要用于查看节点链接、安全屏蔽状态和最近变更；`ike view doctor` 会额外执行公网 IP 探测、Xray 配置校验和服务状态检查。直接命令执行完会返回 shell，不进入菜单。

`ike forward ...` 仍作为兼容别名保留，内部复用 Tunnel 逻辑；新用户建议使用 `ike tunnel ...`。

命令用途区分：

- `ike`：安装器和菜单命令，用于安装、查看、重置、卸载和维护配置。
- `xray`：Xray-core 二进制本体，用于 `xray version`、`xray vlessenc`、`xray run -test` 等核心命令。
- `sb`：旧版兼容入口，只提示命令已更名为 `ike` 并转发，不推荐继续使用。

## 菜单功能

1. 安装/更新 Xray 核心
2. 安装 Shadowsocks 2022
3. 安装 IPv6 + Shadowsocks 2022
4. 安装 VLESS Encryption
5. 安装 VLESS TCP REALITY
6. 安装 VLESS Encryption + XHTTP + FinalMask
7. 安装 SOCKS5 代理
8. 查看当前配置链接
9. 设置链接显示模式 (IPv4/IPv6/双栈)
10. 重置密钥/密码（端口不变）
11. 卸载/清理
12. 开启/关闭中国大陆直连屏蔽
13. 开启/关闭增强安全屏蔽
14. 导出当前配置备份
15. Tunnel 中转管理
16. 退出

## 本地开发与测试

本项目的测试不依赖真实 Xray 服务，也不会启动 systemd；主要用于检查 shell 语法、脚本风格、空白错误，以及 Tunnel / Reality / XHTTP-FinalMask 在临时目录中的静态结构和配置读写行为。真实 VPS 连通性、客户端导入兼容性和最新 Xray-core 行为仍需要在实机环境另测。

建议准备以下工具：

- Git Bash / bash
- shellcheck
- shfmt
- jq
- netcat-openbsd / nc
- ss / iproute2
- git

Windows 可先在 PowerShell 中安装常用工具：

```powershell
winget install --id Git.Git -e
winget install --id koalaman.shellcheck -e
winget install --id mvdan.shfmt -e
winget install --id jqlang.jq -e
```

然后在 Git Bash 中运行：

```bash
bash scripts/test.sh
```

Debian / Ubuntu 可安装基础测试工具：

```bash
apt-get update
apt-get install -y bash curl wget git jq shellcheck netcat-openbsd iproute2 procps
```

如果发行版软件源未包含 `shfmt`，请通过包管理器、GitHub Release 或 Go 工具链额外安装 `shfmt`。安装完成后运行：

```bash
bash scripts/test.sh
```

测试脚本会执行：

```bash
bash -n install.sh
shellcheck install.sh
shfmt -d -i 4 -ci install.sh
git diff --check -- install.sh README.md scripts/test.sh tests/test_reality_xhttp.sh tests/test_install_compat.sh
bash tests/test_forward.sh
bash tests/test_reality_xhttp.sh
bash tests/test_install_compat.sh
```

## 发布前验收

发布到 GitHub Release 或更新 `main` 分支前，建议在真实 Linux VPS 上按 [发布前 Smoke Test](docs/smoke-test.md) 完整验收一次。该清单覆盖基础安装、协议配置、Reality Vision flow、Tunnel 中转、安全规则和卸载流程。

## VPS 安装与测试流程

本轮本地测试仍是静态、结构和脚本测试；真实连通性、客户端导入和最新 Xray-core 行为需要在 VPS 上另行烟测。建议主推 Debian 12 / Ubuntu 22.04+，其它 systemd Linux 可尝试，但遇到问题先运行 `ike preflight`。

### 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh -o install.sh
bash install.sh
ike preflight
ike doctor all
```

重复执行基础安装时，脚本会保留已有配置并在写入前备份；同协议重复部署会覆盖同 tag 配置，不同协议互不影响。

### 国内网络安装

GitHub 访问不稳定时，可通过环境变量补充镜像，原始 GitHub URL 仍会优先尝试：

```bash
export XRAY_GITHUB_MIRRORS="https://gh.llkk.cc/,https://gh.ddlc.top/,https://gh-proxy.com/,https://ghproxy.net/"
bash install.sh
```

下载失败时脚本会显示当前尝试 URL、继续尝试下一个镜像，并在全部失败后给出手动下载建议。不要把镜像地址当作唯一可信来源，生产环境仍建议核对 Xray-core 来源。

### 指定 Xray-core 版本

```bash
ike xray upgrade --version v25.1.1
ike xray upgrade --version v25.1.1 --dry-run
ike xray upgrade --version v25.1.1 --restart
```

指定版本会直接拼接 GitHub Releases 资源 URL，不依赖 latest API；如果指定版本下载失败，脚本不会静默切换到 latest。当前脚本做基础包校验：文件非空、`unzip -t`、解压后 `xray version` 和配置测试，完整 sha256 校验后续再增强。

### 系统预检

```bash
ike preflight
ike doctor preflight
```

预检会检查 root 权限、Debian/Ubuntu 信息、systemd、amd64/arm64 架构、根分区剩余空间、curl/wget、jq、unzip、tar、openssl、ss/netstat、systemctl、journalctl、awk/sed/grep。空间不足 200MB 或缺少关键依赖时应先修复，不建议继续安装。

### Reality 部署和 smoke

Reality 对外入口端口默认随机范围为 `20000-50000`，也可用 `--port` 指定；defender 默认随机范围为 `39000-49999`，始终通过 `127.0.0.1` 转发到 SNI 的 `443`。SNI 只写域名，不要带 `https://`、路径或端口。

```bash
ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com
ike reality show
ike doctor reality
ike smoke reality
ike smoke reality --restart
xray run -test -c /etc/xray/config.json
journalctl -u xray -n 80 --no-pager
```

### XHTTP FinalMask off 部署和 smoke

```bash
ike xhttp install --port 30005 --path /api/test --finalmask off
ike xhttp show
ike doctor xhttp
ike smoke xhttp
ike smoke xhttp --restart
```

`api/test` 这类 path 不会自动补斜杠，请使用 `/api/test`；path 不允许空格、`?`、`#` 或反斜杠。

### XHTTP FinalMask on 部署和 smoke

```bash
ike xhttp install --port 30005 --path /api/test --finalmask on
ike xhttp show
ike doctor xhttp
ike smoke xhttp
```

XHTTP + FinalMask 是实验功能，FinalMask 客户端兼容性取决于客户端内核版本；`fm=` 分享链接可能很长，部分客户端可能需要手动填写参数。如果 FinalMask 校验失败或客户端无法导入，先使用 `ike xhttp install --finalmask off`。

### 导出客户端配置

```bash
ike export clients
ike export clients --output /root/xray-clients.txt
```

`export clients` 只输出客户端需要的链接和参数，不输出 Reality `privateKey` 或 VLESS Encryption 服务端 `decryption`。导出的文件会尝试设置为 `600` 权限。

### 诊断报告导出

```bash
ike export report
ike export report --output /root/xray-report.txt
```

`export report` 会包含版本、已安装协议、inbound tag、监听端口、配置测试和最近日志摘要，并脱敏 private key、decryption、password、secret、token 等字段。

### 升级 Xray-core

```bash
ike xray version
ike xray upgrade
ike xray upgrade --dry-run
ike xray upgrade --restart
```

升级前会备份当前二进制；升级后先运行 `xray version` 和 `xray run -test -c /etc/xray/config.json`。配置测试失败时会回滚二进制；默认不自动重启，只有加 `--restart` 才会重启服务。

### systemd service 管理

```bash
ike service install
ike service status
ike service restart
ike service logs
ike service repair
```

`service install` / `service repair` 会写入 `/etc/systemd/system/xray.service`，`ExecStart` 指向当前 `xray` 二进制和 `/etc/xray/config.json`。旧 service 会先备份；如果旧 service 不是本项目生成，脚本不会静默覆盖，非交互场景需要显式 `--yes`。`service restart` 会先 `daemon-reload`，失败时输出最近 `journalctl -u xray -n 80 --no-pager` 摘要。

### doctor / smoke

```bash
ike doctor preflight
ike doctor proxy
ike doctor reality-key
ike doctor reality
ike doctor xhttp
ike doctor all
ike smoke reality
ike smoke reality --restart
ike smoke xhttp
ike smoke xhttp --restart
ike smoke all
```

`doctor all` 会包含 preflight、proxy、Reality 和 XHTTP 检查；协议未安装时显示“未安装，跳过”，不会当作整体失败。`smoke` 默认不重启服务，只有加 `--restart` 才执行 restart；FinalMask on 且校验失败时优先尝试 `ike xhttp install --finalmask off`。

### 迁移旧配置

从 alpha.1 / alpha.2 / alpha.3 / alpha.4 升级到 beta.1 建议先检查再迁移：

```bash
ike doctor all
ike migrate --dry-run
ike migrate
ike doctor all
```

迁移只补齐可推导的 state 字段，例如 Reality `flow` / `link`、XHTTP `finalmask_enabled` / `link`。推导不了时会给 warning，不会伪造字段，也不会删除用户协议。

### 卸载/保留配置/彻底清理

```bash
ike uninstall --dry-run
ike uninstall --keep-config
ike uninstall --purge --yes
```

`--keep-config` 删除二进制、快捷命令和 service，但保留 `/etc/xray/config.json` 与 `installer-state.json`；`--purge` 会先创建最终备份包，再删除配置、state、日志、service、二进制和快捷命令。非交互 purge 必须显式加 `--yes`，脚本不会静默删除非本项目 service。

### 实机测试推荐顺序

```bash
ike preflight
ike xray version
ike service status
ike doctor all
ike reality install --dry-run
ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com
ike reality show
ike smoke reality
ike xhttp install --port 30005 --path /api/test --finalmask off
ike xhttp show
ike smoke xhttp
ike export clients --output /root/xray-clients.txt
ike export report --output /root/xray-report.txt
```

确认 Reality 可用后，再按需测试 `--finalmask on`。如果客户端无法导入带 `fm=` 的链接，请先使用 FinalMask off，并手动填写 path/encryption/finalmask 参数排查。

### 常见问题

**Q: FinalMask on 失败怎么办？**
A: 先使用 `ike xhttp install --finalmask off`，并运行 `ike doctor xhttp` / `ike smoke xhttp`。FinalMask 需要较新 Xray-core 和客户端核心，不承诺所有客户端可直接导入。

**Q: Reality 能随机端口吗？**
A: 可以，默认随机 `20000-50000`，也可用 `--port` 指定。

**Q: SNI 可以写 `https://domain/path` 吗？**
A: 不可以，只写域名，不要带协议、路径、端口或空格。

**Q: privateKey 要填客户端吗？**
A: 不要。Reality `privateKey` 是服务端敏感字段，客户端填写 `publicKey`。

**Q: 重复执行 install 会怎样？**
A: 同协议 tag 覆盖，不同协议互不影响，写入前自动备份，不会故意清空已有配置。

**Q: 国内 GitHub 下载失败怎么办？**
A: 使用 `XRAY_GITHUB_MIRRORS` 补充镜像，或用 `ike xray upgrade --version vX.Y.Z` 指定版本。

## 支持协议

### Shadowsocks 2022

脚本会生成 Xray `shadowsocks` 入站。默认监听 IPv4；选择 IPv6 + SS2022 时会先检测系统 IPv6 状态，再生成 IPv6 监听配置。

支持方法：

- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`

### VLESS Encryption

脚本会生成 Xray `vless` 入站，并通过 `xray vlessenc` 生成匹配的服务端 `decryption` 和客户端 `encryption`。

当前脚本面向专线落地场景，VLESS Encryption 默认使用 `tcp` + `security=none`，不写入 `flow`，也不使用 `xtls-rprx-vision`。生成的分享链接只包含 `type=tcp`、`security=none` 和 `encryption` 等必要参数。

基础模式适合大多数用户，保留最少交互：

- 认证方式：`X25519` 或 `ML-KEM-768`
- 外观混淆：`native`
- 客户端握手：`0rtt`
- 服务端 ticket 有效期：`600s`

高级模式会开放当前脚本已经实现的 VLESS Encryption 字符串选项：

- 外观混淆：`native` / `xorpub` / `random`
- 客户端握手：`0rtt` / `1rtt`
- 服务端 ticket 有效期：`600s` / `300s` / 自定义，如 `100-500s` 或 `900s`
- 认证方式：`X25519` / `ML-KEM-768`

注意事项：

- 当前 `xray vlessenc` 命令本身不提供可直接指定这些选项的命令行参数；脚本会先生成匹配参数，再按 VLESS Encryption 字符串结构同步重写服务端和客户端字段。
- 高级模式下，尤其选择 `ML-KEM-768` 时，生成的 `encryption` 和 `vless://` 分享链接可能非常长。部分客户端兼容性可能较差，必要时需要手动填写参数。
- reverse、relay、多级 relay 等协议层能力当前脚本暂未开放，避免误导用户以为已经完整支持；需要这些能力时请手动维护 Xray 配置。

### VLESS TCP REALITY

`ike reality install` 会写入两个入站：

- `vless+tcp+reality`：对外监听的 VLESS TCP REALITY 入口，端口可随机或通过 `--port` 指定。
- `reality-defender`：仅监听 `127.0.0.1` 的 defender，默认转发到伪装域名的 `443`，端口可随机或通过 `--defender-port` 指定。

伪装域名可以通过 `--sni DOMAIN` 指定，不指定时会从内置候选中随机选择，候选包含 `www.abmindustriesgroup.com`。SNI 只填写域名本身，不建议也不允许写成 `https://example.com`、`example.com:443` 或带路径的格式。脚本会尽量用 `openssl s_client -servername DOMAIN -connect DOMAIN:443` 检测目标 TLS 可达性；检测失败时交互模式默认取消，确认后才继续，非交互模式可用 `--yes` 或 `XRAY_ONECLICK_YES=1` 明确继续。若 TLS 探测失败，建议优先更换伪装域名。

Reality target/dest 的实际出口默认是 `SNI:443`，经本机 `127.0.0.1` defender 转发；入口端口只用于客户端连接，可以随机或指定，不需要固定为 443。默认客户端和服务端 client 都使用 `xtls-rprx-vision`，分享链接会包含 `type=tcp`、`security=reality`、`pbk`、`sni`、`sid`、`flow=xtls-rprx-vision`、`spx` 等参数。

`privateKey` 是服务端敏感字段，脚本会保存到 `installer-state.json` 并设置权限为 `600`，默认输出不会展示其值；`publicKey` 是客户端连接字段，可在 `ike reality show` 或 `ike view reality` 中查看。

常用命令：

```bash
ike reality install
ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com
ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com --dry-run
ike reality show
ike doctor reality
ike smoke reality
ike reality remove
ike view reality
```

### VLESS Encryption + XHTTP + FinalMask

`ike xhttp install` 会继续调用现有 `xray vlessenc` 流程生成服务端 `decryption` 和客户端 `encryption`，并沿用 X25519 / ML-KEM-768、`native` / `xorpub` / `random`、`0rtt` / `1rtt`、ticket 有效期等选项。

该模式默认生成 `security=none` + VLESS Encryption + `network=xhttp`，不写 TLS 证书逻辑，也不写 `xtls-rprx-vision` flow。`path` 可随机生成，也可通过 `--path /api/test` 指定；用户指定的 path 必须以 `/` 开头，长度不超过 128，不能包含空格、`?`、`#` 或反斜杠。`api/test` 不会自动修正为 `/api/test`，请直接写完整路径。

FinalMask 属于实验能力，默认开启保守模板，但可以通过 `--finalmask off` 关闭。最终是否可用以 `xray run -test` 校验结果为准；如果 FinalMask 模板导致校验失败，脚本会触发回滚，可优先使用 `--finalmask off` 重试。分享链接里的 `fm` 会 URL 编码整个 FinalMask JSON，链接可能很长，不承诺所有客户端都能直接导入，客户端兼容性取决于客户端内核版本，必要时请手动填写参数。

常用命令：

```bash
ike xhttp install
ike xhttp install --port 30005 --path /api/test --finalmask on
ike xhttp install --port 30005 --path /api/test --finalmask off
ike xhttp install --port 30005 --path /api/test --finalmask on --dry-run
ike xhttp show
ike doctor xhttp
ike smoke xhttp
ike xhttp remove
ike view xhttp
```

兼容性说明：

- Reality TCP 相对稳定，但仍建议确认客户端内核支持 REALITY 和 `xtls-rprx-vision`。
- XHTTP + FinalMask 是实验功能，FinalMask 需要较新的客户端内核；如果服务端校验失败或客户端不兼容，优先使用 `--finalmask off`。
- 带 `fm` 的分享链接可能较长，部分客户端可能需要手动填写 FinalMask 参数。

### SOCKS5

SOCKS5 为可选入站，适合临时代理、内网访问或简单连通性测试。是否允许认证、监听地址和端口以脚本交互为准。

## Endpoint 管理

Endpoint 表示用户实际连接这个节点时应该使用的地址。普通公网 VPS 可以依赖自动探测；NAT 小鸡、DDNS、端口映射、负载均衡或多公网 IP 场景，建议手动设置。

```bash
ike endpoint detect
ike endpoint set
ike endpoint show
ike endpoint clear
```

`ike endpoint detect` 会从多个来源探测公网地址：

- `https://api.ipify.org`
- `https://ipinfo.io/ip`
- `https://ifconfig.me`
- `https://icanhazip.com`
- `https://ipecho.net/plain`

`ike endpoint set` 会把自定义连接地址写入 `/etc/xray/installer-state.json`：

```json
{
  "endpoint": {
    "custom": "example.com",
    "updated_at": "2026-04-27T00:00:00Z"
  }
}
```

可填写 `1.2.3.4`、`example.com` 或 `domain.com:外部端口`。如果 endpoint 已包含端口，Tunnel 列表会提示这是全局自定义地址，不会再盲目拼接本地监听端口；NAT 映射端口需要用户自行确认。

Endpoint 不改变 SS2022、VLESS Encryption、SOCKS5 或 Tunnel 的配置生成逻辑，只用于 `ike view`、`ike tunnel list`、`ike tunnel doctor` 的连接入口提示。

## Tunnel 中转管理

Tunnel 是 Xray 官方入站协议，旧称 `dokodemo-door`。本脚本使用应用层 Tunnel 做轻量中转，不依赖 iptables、nftables、Realm、WebUI、sysctl 或内核转发，也不默认启用 `followRedirect`；透明代理 / TProxy 不在本功能范围内。

基本模型：

```text
本机监听地址:本机监听端口 -> 目标地址:目标端口
```

示例配置会写入 `/etc/xray/config.json` 的 `inbounds`。脚本会在 VPS 上探测当前 Xray 是否支持新协议名 `tunnel`；如果不确定或不支持，会使用兼容名 `dokodemo-door`：

```json
{
  "tag": "tunnel-30000-443",
  "listen": "0.0.0.0",
  "port": 30000,
  "protocol": "dokodemo-door",
  "settings": {
    "address": "1.2.3.4",
    "port": 443,
    "network": "tcp,udp"
  }
}
```

支持网络类型：`tcp`、`udp`、`tcp,udp`。

菜单 `13) Tunnel 中转管理` 提供场景化入口：

1. 单端口落地中转（`relay/tcp,udp`）
2. 多端口落地组（`portMap` 实验，失败自动 fallback 为多条 `single`）
3. 普通公网转发（`safe/tcp`）
4. 内网服务暴露（`relay/tcp`）
5. UDP 游戏/语音转发（可选 `safe` / `relay`，网络为 `udp` 或 `tcp,udp`）
6. 自定义 Tunnel

直接命令：

```bash
ike tunnel list
ike tunnel add
ike tunnel add safe
ike tunnel add relay
ike tunnel add map
ike tunnel enable
ike tunnel disable
ike tunnel edit
ike tunnel test
ike tunnel doctor
ike tunnel group list
ike tunnel group doctor
ike tunnel template
ike tunnel ports
ike tunnel export
ike tunnel import
ike tunnel bundle export
ike tunnel bundle import
ike tunnel generate-script
ike tunnel generate-relay-script
ike tunnel generate-client-script
ike tunnel del
```

`ike forward ...` 是兼容别名，仍可读取、诊断和删除旧 `forward-` tag；新建规则默认使用 `tunnel-` tag。

### safe / relay

`safe` 是默认模式，`ike tunnel add` 等同于 `ike tunnel add safe`，直接命令默认网络类型为 `tcp`。该模式不新增专用 routing 放行规则，默认遵守现有安全屏蔽、中国大陆直连屏蔽和增强安全屏蔽，适合普通公网端口转发。

`relay` 适合代理中转、落地转发和可信固定目标。`ike tunnel add relay` 与兼容命令 `ike forward add relay` 默认网络类型为 `tcp,udp`，更适合 SS2022、游戏、语音、QUIC/HY2/TUIC 等中转场景。添加规则时，脚本会额外写入只绑定该 Tunnel inbound 的专用路由：

```json
{
  "type": "field",
  "inboundTag": ["tunnel-30000-443"],
  "outboundTag": "direct"
}
```

这条规则会放在默认安全屏蔽规则之前，只对该 Tunnel inbound 生效，不影响 SS2022、VLESS Encryption、SOCKS5 或其它 Tunnel。它可能绕过默认安全规则，所以只建议用于可信固定目标；启用 relay 时会提示确认，支持 `y`、`Y`、`yes`、`YES`、`Yes`，直接回车默认取消。

### single / portMap / group

`single` 是默认规则类型，一条 inbound 对应一条本地端口到目标端口的映射。

`portMap` 是实验性批量映射功能：`ike tunnel add map` 会尝试生成一个包含 `settings.portMap` 的 Tunnel inbound；如果 Xray 配置校验或服务重启失败，脚本会触发现有回滚流程，并自动 fallback 为多条独立 `single` Tunnel。

添加规则时可填写 `group`，用于把同一组落地端口聚合显示。`ike tunnel group list` 按 group 统计数量，`ike tunnel group doctor` 按 group 汇总启用、停用和异常数量。group 可为空，不强制使用。

状态摘要会保存到 `/etc/xray/installer-state.json` 的 `tunnels` 数组；为兼容旧版本，也会保留 `forwards` 镜像。`config.json` 是实际生效来源，state 只用于备注、group、停用恢复和导入导出。即使 state 丢失，`ike tunnel list` 仍可从 `config.json` 解析 `tunnel-` / `forward-` 入站。

### 规则管理

`ike tunnel list` 合并 `config.json` 和 state 输出：

```text
状态  模式   类型      分组           规则
启用  relay  single    landing-us     tunnel-30000-443: 0.0.0.0:30000 -> 1.2.3.4:443/tcp,udp 备注
       连接入口: example.com:30000
停用  safe   single    未分组         tunnel-40000-8443: 0.0.0.0:40000 -> example.com:8443/tcp
       连接入口: example.com:40000
```

`ike tunnel disable [tag]` 会从 `config.json` 移除对应 Tunnel inbound；如果是 relay 模式，也会移除对应 `inboundTag -> direct` 规则，但保留 state 摘要并写入 `enabled: false`。

`ike tunnel enable [tag]` 会根据 state 摘要重新写入 inbound；如果模式为 relay，会重新写入对应专用路由。

`ike tunnel edit [tag]` 可修改 single 规则的监听地址、监听端口、目标地址、目标端口、网络类型、模式、group 和备注；备注为空时显示为 `无`，不会与启用状态混淆。`portMap` 规则建议通过 export/import 修改。

`ike tunnel test [tag]` 面向单条规则排查，显示本地监听、目标解析、TCP 连通性、UDP 说明、relay 路由和安全规则影响。

`ike tunnel doctor [tag]` 不带 tag 时扫描全部规则，并标出 `config-only`、`state-only`、relay 路由缺失等状态；带 tag 时诊断单条规则。

`ike tunnel template` 会生成可导入模板：

```text
/root/xray-tunnels-template.json
```

`ike tunnel ports` 只读取 `/etc/xray/config.json`，汇总脚本管理的监听端口，包括 SS2022、VLESS Encryption、SOCKS5 和 Tunnel 规则。

`ike tunnel export` 默认导出到：

```text
/root/xray-tunnels-YYYYmmddHHMMSS.json
```

导出格式带版本：

```json
{
  "version": 1,
  "type": "xray-oneclick-tunnels",
  "tunnels": []
}
```

`ike tunnel import` 支持新 `tunnels[]` 格式，也兼容旧 `{ "forwards": [] }`。遇到 tag 冲突时可选择跳过、覆盖或自动改名；导入不会覆盖非 Tunnel 协议入站。

非交互导入：

```bash
ike tunnel import /path/to/tunnels.json --yes
```

传入文件路径时不会再询问路径；加 `--yes` 时，遇到 tag 冲突默认自动改名，适合自动化部署。也可用 `XRAY_ONECLICK_YES=1` 或 `XRAY_ONECLICK_TUNNEL_IMPORT_YES=1` 取得同样效果。兼容别名 `ike forward import /path/to/tunnels.json --yes` 仍可使用。

### Tunnel 部署包

`ike tunnel bundle export` 会导出一个部署包目录：

```text
/root/xray-tunnel-bundle-YYYYmmddHHMMSS/
```

包含：

- `tunnels.json`: 当前 Tunnel 规则，使用 `version/type/tunnels` 新格式。
- `README.txt`: 在另一台机器导入的最小命令。
- `install-tunnels.sh`: 可选辅助脚本，只负责下载/调用 Xray-OneClick 并导入 `tunnels.json`。

部署包用于“落地机生成线路机导入配置”的轻量工作流，不会写死用户敏感信息到命令行，也不新增协议逻辑。

这些命令都是 `ike tunnel bundle export` 的易懂别名：

```bash
ike tunnel generate-script
ike tunnel generate-relay-script
ike tunnel generate-client-script
```

导入部署包时可以传入 `tunnels.json`，也可以直接传入部署包目录；目录模式会自动读取其中的 `tunnels.json`：

```bash
ike tunnel bundle import /root/xray-tunnel-bundle-YYYYmmddHHMMSS --yes
ike tunnel bundle import /root/xray-tunnel-bundle-YYYYmmddHHMMSS/tunnels.json --yes
```

## 自动化部署 / 无人值守

基础自动化入口：

```bash
XRAY_ONECLICK_ENDPOINT=example.com \
XRAY_ONECLICK_TUNNEL_IMPORT=/root/tunnels.json \
XRAY_ONECLICK_YES=1 \
ike bootstrap
```

`ike bootstrap` 会安装/更新 Xray，按需写入 endpoint，导入 `XRAY_ONECLICK_TUNNEL_IMPORT` 指定的 Tunnel 规则，应用并校验配置，最后输出 `ike version`、Tunnel 列表和 `ike view doctor`。

支持的环境变量：

| 变量 | 作用 |
| --- | --- |
| `XRAY_ONECLICK_ENDPOINT` | 当 state 尚未设置自定义 endpoint 时写入连接入口；已有 endpoint 不会被覆盖 |
| `XRAY_ONECLICK_TUNNEL_IMPORT` | `ike bootstrap` 要导入的 `tunnels.json` 路径，也可指向部署包目录 |
| `XRAY_ONECLICK_YES=1` | 对明确支持自动确认的流程启用自动确认，例如 Tunnel 导入冲突自动改名 |
| `XRAY_ONECLICK_TUNNEL_IMPORT_YES=1` | 仅用于 Tunnel 导入自动确认 |

说明：

- `XRAY_ONECLICK_YES=1` 不会绕过完整卸载这类危险确认。
- Tunnel tag 冲突时自动改名，不覆盖、不删除原规则。
- `XRAY_ONECLICK_ENDPOINT` 只在未设置自定义 endpoint 时生效；需要覆盖时请显式运行 `ike endpoint set`。

## 默认安全屏蔽

脚本会默认写入一组服务端防滥用基线规则，适合大多数个人 VPS 场景。该规则不需要手动开启，新安装协议、更新核心、重置配置或应用 routing 设置时都会自动补齐。

默认会补齐 `BLOCK` 出站：

```json
{ "tag": "BLOCK", "protocol": "blackhole" }
```

并在 `routing.rules` 前部加入：

```json
{ "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
{ "type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK" }
{ "type": "field", "port": "25,135,137,138,139,445,465,587", "outboundTag": "BLOCK" }
```

这些规则用于阻断 BT/PT 流量、访问私网地址、SMTP 发信滥用，以及 Windows / NetBIOS / SMB 相关高风险端口。默认规则只移除和重建脚本自己生成的精确规则，不会删除用户已有自定义 routing。

如果 `/usr/local/share/xray/geoip.dat` 存在，私网阻断使用 `geoip:private`；如果该资源不存在，脚本会自动退化为 CIDR fallback，不会因此中断协议安装或配置应用。fallback 会阻断：

```text
127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
169.254.0.0/16, 100.64.0.0/10, ::1/128, fc00::/7, fe80::/10
```

菜单中的 `11) 开启/关闭增强安全屏蔽` 可额外阻断：

```text
69,161,162,389,636,1900,5353,5355,11211
```

增强模式默认关闭，因为这些端口可能影响少量 DNS-SD/mDNS、LDAP、SNMP、TFTP、Memcached 或内网发现类场景。需要更严格出口限制时再开启。

`ike view` 会显示“默认安全屏蔽”“默认私网规则”和“增强安全屏蔽”的当前状态。也可以直接使用 `ike safety enhanced on` 或 `ike safety enhanced off` 开启/关闭增强安全屏蔽。

## 可选路由：屏蔽中国大陆直连

菜单中的 `10) 开启/关闭中国大陆直连屏蔽` 用于控制服务端是否阻断发往中国大陆的直连流量。该功能适合专线落地、出口限制、避免节点访问中国大陆站点或 IP 的场景。

开启后，脚本会补齐 `BLOCK` 出站：

```json
{ "tag": "BLOCK", "protocol": "blackhole" }
```

该功能分为两档：

- 基础模式：只阻断 `geoip:cn` IP，依赖 `geoip.dat`。
- 增强模式：在基础模式之外额外阻断 `geosite:cn` 域名，依赖 `geoip.dat` 和 `geosite.dat`。

对应规则为：

```json
{ "type": "field", "ip": ["geoip:cn"], "outboundTag": "BLOCK" }
{ "type": "field", "domain": ["geosite:cn"], "outboundTag": "BLOCK" }
```

关闭时只移除上述中国大陆屏蔽规则，不删除已有的 private、BT、端口屏蔽等其它 routing 规则。开启后，使用这些入站协议的客户端将无法访问匹配规则的站点或 IP。缺少 `geosite.dat` 时不能启用增强模式，但仍可使用基础模式；缺少 `geoip.dat` 时请先执行 `ike update` 或菜单中的 `1) 安装/更新 Xray 核心`。

`ike view` 会显示中国大陆直连屏蔽状态：`未启用`、`基础模式` 或 `增强模式`。也可以直接使用 `ike cnblock basic`、`ike cnblock enhanced`、`ike cnblock off` 设置，或用 `ike cnblock` 查看当前状态。

## 诊断与备份

`ike view` 默认使用快速模式，显示节点链接、Tunnel 中转数量、默认安全屏蔽、增强安全屏蔽、中国大陆直连屏蔽、默认私网规则模式，以及 `installer-state.json` 中记录的最近变更和最近更新时间。快速模式不会主动执行 `xray run -test -c`、服务状态检查或公网 IP 探测。

需要排障时使用：

```bash
ike view doctor
```

诊断模式会额外输出：

- `geoip.dat`: 存在 / 不存在
- `geosite.dat`: 存在 / 不存在
- `Xray 配置校验`: 通过 / 失败 / 未检测到 xray
- `Xray 服务状态`: 运行中 / 未运行 / 未检测到 systemd/openrc
- 公网 IPv4 / IPv6
- Tunnel 中转详情

菜单中的 `12) 导出当前配置备份` 或直接命令 `ike backup` 会把当前配置导出到：

```text
/root/xray-config-backup-YYYYmmddHHMMSS.json
/root/xray-state-backup-YYYYmmddHHMMSS.json
```

状态文件不存在时会跳过状态备份，不影响配置备份导出。脚本内部应用配置前仍会保留 `config.json.bak.*` 备份；如果配置校验或服务重启失败，`apply_config()` 会尝试恢复最近一次内部备份并重新校验。

## 配置、服务与日志

常用直达命令：

```bash
ike config path
ike config test
ike config edit
ike service status
ike service restart
ike logs
```

- `ike config path` 输出当前配置路径 `/etc/xray/config.json`。
- `ike config test` 执行 `xray run -test -c /etc/xray/config.json`。
- `ike config edit` 使用 `$EDITOR`、`nano` 或 `vi` 打开配置，保存后先校验，校验通过才询问是否重启。
- `ike service status` / `ike service restart` 按当前 init system 调用 systemd 或 OpenRC。
- `ike logs` 在 systemd 下调用 `journalctl -u xray -n 80 --no-pager`；OpenRC 下尝试读取 `/var/log/xray/access.log` 和 `/var/log/xray/error.log`。

## 常用验证

检查 Xray 配置是否可被核心加载：

```bash
xray run -test -c /etc/xray/config.json
```

查看服务状态：

```bash
systemctl status xray --no-pager
```

查看监听端口：

```bash
ss -tulpn | grep xray
```

Tunnel 中转验证：

```bash
ike tunnel add
ike tunnel list
xray run -test -c /etc/xray/config.json
systemctl status xray --no-pager
ss -tulpn | grep xray
ike view doctor
```

查看脚本生成的节点信息：

```bash
ike view
```

## systemd 常用命令

```bash
systemctl status xray --no-pager
systemctl restart xray
systemctl stop xray
journalctl -u xray -n 80 --no-pager
```

## 文件路径

| 用途 | 路径 |
| --- | --- |
| 配置目录 | `/etc/xray` |
| 配置文件 | `/etc/xray/config.json` |
| 安装器状态 | `/etc/xray/installer-state.json` |
| Xray 二进制 | `/usr/local/bin/xray` |
| Xray 资源目录 | `/usr/local/share/xray` |
| 安装器副本 | `/usr/local/share/ike/install.sh` |
| systemd 服务 | `/etc/systemd/system/xray.service` |
| 主快捷命令 | `/usr/local/bin/ike` |
| 兼容快捷命令 | `/usr/local/bin/sb` |

`installer-state.json` 用于保存 VLESS Encryption 的客户端 `encryption` 字段、Tunnel 中转摘要 `tunnels`（兼容镜像 `forwards`），以及 `meta.last_action`、`meta.last_updated_at` 等最近变更信息。Xray 服务端配置只需要 `decryption`，但生成分享链接时需要客户端字段，所以该状态文件应像配置文件一样保护。

## 卸载与清理

执行 `ike` 后进入 `11) 卸载/清理` 子菜单，可删除单项协议配置、卸载全部 Xray 实现，或清理旧版 sing-box 残留。

旧 sing-box 清理只面向迁移前遗留内容，包括：

- `/etc/sing-box`
- `/usr/local/bin/sing-box`
- `sing-box.service` 或 OpenRC 服务

清理前脚本会再次询问确认。卸载全部 Xray 后如果当前 shell 仍缓存旧命令路径，可执行 `hash -r` 后再检查 `ike` 是否已移除。

## 免责声明

本脚本仅供学习交流与网络技术研究使用。请勿用于任何违反当地法律法规的用途。使用本脚本产生的任何后果由使用者自行承担。
