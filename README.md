# Xray-OneClick

**Xray-OneClick 1.0.0 正式版**

Xray-OneClick 是基于 **Xray-core** 的多协议一键部署脚本，适合在 Debian / Ubuntu systemd 服务器上快速安装和维护个人 Xray 节点。

脚本支持 Shadowsocks 2022、VLESS Encryption、VLESS TCP REALITY、VLESS Encryption + XHTTP + FinalMask、SOCKS5，以及 Tunnel 中转管理。默认带基础安全屏蔽、配置备份、服务诊断、配置导出、Xray-core 升级和安全卸载能力。

当前版本：`1.0.0`

状态：正式版

说明：XHTTP + FinalMask 属于高级兼容功能，客户端支持情况取决于客户端内核版本；如果客户端无法导入带 `fm=` 的链接，请优先关闭 FinalMask 或手动填写参数。

## 功能特性

- 一键安装 / 更新 Xray-core
- Shadowsocks 2022
- IPv6 + Shadowsocks 2022
- VLESS Encryption
- VLESS TCP REALITY
- VLESS Encryption + XHTTP + FinalMask
- SOCKS5 代理
- Tunnel 中转管理
- Endpoint 显示模式
- 中国大陆直连屏蔽
- 增强安全屏蔽
- 配置备份
- 诊断 / smoke / export
- `keep-config` / `purge` 卸载
- GitHub 下载镜像兜底
- Xray-core 指定版本升级和失败回滚

## 系统要求

推荐环境：

- Debian 12+
- Ubuntu 22.04+
- root 权限
- systemd
- amd64 / arm64
- curl 或 wget

脚本会自动补齐常用依赖，例如 `jq`、`unzip`、`tar`、`openssl`。端口监听检查优先使用 `ss`，没有 `ss` 时会降级处理。

安装前可先执行：

```bash
ike preflight
```

如果尚未安装 `ike`，先按下面的快速安装流程运行脚本。

## 快速安装

```bash
curl -fsSL -o /root/install.sh https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh
chmod +x /root/install.sh
bash /root/install.sh
```

安装完成后可直接运行：

```bash
ike
```

也可以使用直接命令进行维护：

```bash
ike help
ike version
ike preflight
ike view
ike doctor all
```

## 国内网络安装

如果 GitHub 访问不稳定，可设置镜像兜底。脚本仍会优先尝试原始 GitHub 地址，然后再按顺序尝试环境变量里的镜像。

```bash
export XRAY_GITHUB_MIRRORS="https://gh.llkk.cc/,https://gh.ddlc.top/,https://gh-proxy.com/,https://ghproxy.net/"
curl -fsSL -o /root/install.sh https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh
chmod +x /root/install.sh
bash /root/install.sh
```

指定 Xray-core 版本：

```bash
ike xray upgrade --version v26.3.27
```

升级到最新版本：

```bash
ike xray upgrade
```

升级后默认不重启服务，如需重启：

```bash
ike xray upgrade --restart
```

## 主菜单

```text
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
```

## 常用命令

```bash
ike view
ike view reality
ike view xhttp
ike doctor proxy
ike doctor reality
ike doctor reality-key
ike doctor xhttp
ike smoke reality
ike smoke xhttp
ike export clients --output /root/xray-clients.txt
ike export report --output /root/xray-report.txt
```

`doctor` 用于检查环境、配置和状态；`smoke` 用于服务侧快速排障。`smoke` 默认不会重启服务，只有加 `--restart` 时才会重启：

```bash
ike smoke reality --restart
ike smoke xhttp --restart
```

## Shadowsocks 2022

通过菜单安装：

```text
2. 安装 Shadowsocks 2022
```

脚本支持：

- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`

IPv6 版本可使用菜单第 3 项。服务器没有全局 IPv6 时该项会失败，这是正常保护行为。

## VLESS Encryption

通过菜单安装：

```text
4. 安装 VLESS Encryption
```

或使用：

```bash
ike view
```

脚本会调用 `xray vlessenc` 生成服务端 `decryption` 和客户端 `encryption`，并将客户端需要的字段写入 `installer-state.json`。服务端 `decryption` 属于敏感字段，默认导出报告会脱敏。

## VLESS TCP REALITY

通过菜单安装：

```text
5. 安装 VLESS TCP REALITY
```

直接命令：

```bash
ike reality install
ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com
ike reality show
ike reality remove
```

默认行为：

- 主入口端口随机范围：`20000-50000`
- defender 本地端口随机范围：`39000-49999`
- 主 inbound：`vless+tcp+reality`
- defender inbound：`reality-defender`
- defender 监听：`127.0.0.1`
- defender 目标：`SNI:443`
- Flow：`xtls-rprx-vision`
- Fingerprint：`chrome`
- 默认生成 8 个 shortId

Reality 使用 `xray x25519` 生成密钥。新版 Xray 可能输出 `PrivateKey`、`Password`、`Password (PublicKey)`、`Hash32` 等字段；脚本会将 `PrivateKey` 写入服务端配置，将 `PublicKey` / `Password` / `Password (PublicKey)` 作为客户端 `pbk`。

`privateKey` 是服务端敏感字段，不需要填到客户端；客户端需要的是 `publicKey/pbk`。

排障命令：

```bash
ike doctor reality
ike doctor reality-key
ike smoke reality
```

## VLESS Encryption + XHTTP + FinalMask

通过菜单安装：

```text
6. 安装 VLESS Encryption + XHTTP + FinalMask
```

直接命令：

```bash
ike xhttp install
ike xhttp install --port 30005 --path /api/demo --finalmask off
ike xhttp install --port 30005 --path /api/demo --finalmask on
ike xhttp show
ike xhttp remove
```

说明：

- 默认 `security=none`
- 传输层使用 `xhttp`
- 继续复用 VLESS Encryption 的 `encryption` / `decryption` 生成逻辑
- 用户指定 path 必须以 `/` 开头
- path 不允许空格、`?`、`#` 或反斜杠
- FinalMask 可通过 `--finalmask on/off` 控制

FinalMask 属于高级兼容功能。开启后分享链接会包含 URL 编码后的 `fm=` 参数，链接可能较长；部分客户端可能需要手动填写 path、encryption、finalmask 参数。如果服务端配置应用失败或客户端导入异常，请优先使用：

```bash
ike xhttp install --finalmask off
```

排障命令：

```bash
ike doctor xhttp
ike smoke xhttp
```

## SOCKS5

通过菜单安装：

```text
7. 安装 SOCKS5 代理
```

SOCKS5 适合临时代理或内网调试。安装后可通过 `ike view` 查看连接参数。

## Tunnel 中转管理

通过菜单进入：

```text
15. Tunnel 中转管理
```

常用命令：

```bash
ike tunnel list
ike tunnel add
ike tunnel add safe
ike tunnel add relay
ike tunnel add map
ike tunnel edit
ike tunnel enable
ike tunnel disable
ike tunnel del
ike tunnel doctor
ike tunnel ports
ike tunnel export
ike tunnel import /path/to/tunnels.json --yes
```

兼容旧命令：

```bash
ike forward list
ike forward add
```

新用户建议使用 `ike tunnel ...`。

## Endpoint 与显示模式

Endpoint 用于控制分享链接里的地址，适合 NAT、DDNS、小鸡端口映射和多公网 IP 场景。

```bash
ike endpoint show
ike endpoint set
ike endpoint clear
ike endpoint detect
```

显示模式可在菜单第 9 项切换，也可通过：

```bash
ike view ipv4
ike view ipv6
ike view dual
```

## 安全屏蔽

脚本默认写入基础安全屏蔽规则，用于阻断 BT/PT、私网地址、SMTP、SMB/NetBIOS 等高风险目标。

中国大陆直连屏蔽：

```bash
ike cnblock
ike cnblock basic
ike cnblock enhanced
ike cnblock off
```

增强安全屏蔽：

```bash
ike safety enhanced on
ike safety enhanced off
```

增强安全屏蔽会额外限制部分常见高风险端口。开启前请确认不会影响你的业务场景。

## 诊断与导出

诊断：

```bash
ike preflight
ike doctor all
ike doctor proxy
ike doctor reality
ike doctor reality-key
ike doctor xhttp
```

服务侧检查：

```bash
ike smoke reality
ike smoke xhttp
ike smoke all
```

导出客户端配置：

```bash
ike export clients --output /root/xray-clients.txt
```

导出脱敏诊断报告：

```bash
ike export report --output /root/xray-report.txt
```

导出文件会尝试设置为 `600` 权限。`export report` 会脱敏 `privateKey`、`decryption`、password、token、secret 等敏感字段；`export clients` 只输出客户端需要的链接和参数。

## Xray-core 管理

查看版本：

```bash
ike xray version
```

升级到最新版本：

```bash
ike xray upgrade
```

指定版本：

```bash
ike xray upgrade --version v26.3.27
```

升级成功后默认不重启服务。需要重启时：

```bash
ike xray upgrade --restart
```

升级失败时脚本会尝试回滚旧二进制，不会自动修改现有协议配置。

## systemd 服务管理

```bash
ike service install
ike service status
ike service restart
ike service logs
ike service repair
```

服务文件路径：

```text
/etc/systemd/system/xray.service
```

`service repair` 会重新写入本项目的 service 文件，不会删除协议配置或 state。

## 配置路径

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

`installer-state.json` 保存客户端链接所需字段和最近变更信息，应像配置文件一样保护。

## 备份与迁移

导出当前配置备份：

```bash
ike backup
```

迁移旧配置：

```bash
ike migrate --dry-run
ike migrate
```

同协议重复部署会覆盖同 tag 配置，不同协议互不影响。写入配置前脚本会自动备份，配置应用失败时会尝试回滚。

## 卸载与清理

保留配置卸载：

```bash
ike uninstall --keep-config
```

仅预览将删除的内容：

```bash
ike uninstall --dry-run
```

彻底清理：

```bash
ike uninstall --purge --yes
```

区别：

- `--keep-config`：删除二进制、快捷命令和 service，保留 `/etc/xray/config.json` 与 `installer-state.json`
- `--purge`：先创建最终备份包，再删除配置、state、日志、service、二进制和快捷命令

卸载后如果当前 shell 仍缓存旧命令路径，可执行：

```bash
hash -r
```

## 常见问题

**Reality 的 SNI 可以写 `https://domain/path` 吗？**
不可以，只写域名，例如 `www.example.com`，不要带协议、路径、端口或空格。

**Reality 的 privateKey 要填到客户端吗？**
不要。`privateKey` 是服务端字段，客户端填写 `publicKey/pbk`。

**FinalMask 导入失败怎么办？**
先关闭 FinalMask：

```bash
ike xhttp install --finalmask off
```

然后重新查看 `ike xhttp show` 输出。FinalMask 的客户端兼容性取决于客户端内核版本。

**国内 GitHub 下载失败怎么办？**
设置 `XRAY_GITHUB_MIRRORS`，或使用 `ike xray upgrade --version vX.Y.Z` 指定版本。

**重复安装会怎样？**
同协议 tag 会被覆盖，不同协议互不影响，写入前自动备份。

## 安全声明

本项目仅供学习、研究和合法网络用途。请遵守所在地法律法规、服务商条款和网络使用规范。使用本脚本产生的任何后果由使用者自行承担。
