# Changelog

## Unreleased

## 1.1.12
- OpenRC 审查修复：musl 仅用于有官方包的架构；去掉 `after firewall`；init 增加 `directory` 指向 geo 资源目录
- `prepare_system` / `ike doctor` 补 `check_os`+`detect_arch`；卸载/导出/日志路径统一 OpenRC 分支
- Alpine 仅在缺少 `rc-service` 时安装 openrc 包

## 1.1.11
- **Alpine / OpenRC**：预检、doctor、服务写入与日志路径完整支持；Alpine 自动选用 musl 版 Xray 包
- 新增 `scripts/bootstrap.sh` 一行安装（`curl ... | sudo bash`）
- OpenRC init 脚本增强：日志目录、`start_pre`、覆盖前备份

## 1.1.10
- 修复 P0 模块化遗漏：恢复 `init_state` / `state_set_meta_action` 等 5 个 state 函数至 `lib/22-state.sh`
- 修复 `ike_ensure_lib_modules` 早退导致旧 `lib/` 无法增量更新
- P1 整理：Endpoint CLI 归位 `40-network.sh`，`xray_service_status` 归位 `31-service.sh`；bootstrap 加载顺序优化

## 1.1.9
- P6 模块化：`install_shortcut` 拆至 `lib/03-installer.sh`，`install.sh` 主入口约 216 行；README 补充模块表与安装说明

## 1.1.8
- P5 模块化：系统准备与预检拆至 `lib/03-system.sh`，`env_truthy` 上移至 `02-output.sh`；主入口约 200 行
- P0–P4 模块化：`install.sh` 拆分为 31 个 `lib/` 模块；修复 P3 误删的 `run_xray_command` / `migrate_old_state` 与 `run_logs_command` 损坏；README 补充 `lib/` 架构说明
- P0–P3 模块化：基础设施、协议、Tunnel、view/menu、诊断导出；安装时同步复制 `lib/`；curl 单文件安装时自动从 GitHub 拉取全部 lib 模块
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
