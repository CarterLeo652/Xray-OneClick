# Xray-OneClick v1.1.10

## 概要

模块化重构**修复版**：恢复 P0 拆分时遗漏的 state 管理函数，整理模块职责，**推荐所有 v1.1.8–v1.1.9 用户升级**。

## 重要修复

- **恢复 `lib/22-state.sh`**：`init_state`、`state_set_meta_action`、`state_set_cnblock` 等 5 个函数在 P0 模块化时遗失，导致协议安装、cnblock、导出等操作运行时报 `command not found`
- **修复 lib 增量下载**：`ike_ensure_lib_modules` 不再因旧 lib 目录存在而跳过新模块下载
- **模块归位**：Endpoint CLI → `40-network.sh`；`xray_service_status` → `31-service.sh`
- **bootstrap 顺序优化**：`21-config-base` → `22-state` → `40-network` → `41-safety`

## 架构

- 薄入口 `install.sh`（约 210 行）+ **33 个 `lib/` 模块**
- 单文件 `curl` 安装仍自动拉取缺失模块

## 升级

```bash
curl -fsSL -o /root/install.sh https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh
bash /root/install.sh
```

或重新运行安装流程以同步 `/usr/local/share/ike/lib/`。

## 完整变更

见 [CHANGELOG.md](../CHANGELOG.md)。
