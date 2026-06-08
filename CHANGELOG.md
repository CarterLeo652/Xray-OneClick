# Changelog

## Unreleased
- P0–P2 模块化：`install.sh` 拆分为 19 个 `lib/` 模块（基础设施、协议、诊断导出），主脚本约 5.6k 行；安装时同步复制 `lib/`；curl 单文件安装时自动从 GitHub 拉取全部 lib 模块
- CI 增加全量 lib 完整性检查、shellcheck、`install.sh version` 冒烟测试
- 修复交互式卸载 SS2022 / VLESS Encryption / SOCKS5 时未备份、先删 state 导致 config/state 不一致的问题
- 修复 Tunnel 部署包 `install-tunnels.sh` 误进入交互菜单，改为非交互 bootstrap
- `ike config edit` 编辑前自动备份 config.json
- 新增 GitHub Actions CI，运行离线配置生成测试

## 1.1.7
- 新增 Xray stable/prerelease 通道
- REALITY 生成字段迁移为 `target`，旧配置仍兼容读取
- 高级 Reality 组合增加 `fallback-limit` 与 target 风险提示
- FinalMask 默认策略收紧为更保守的 off，开启后默认 balanced
- 新增离线配置生成测试，覆盖 Reality、XHTTP、FinalMask、高级组合和 fallback-limit
- 更新 README 与诊断输出
