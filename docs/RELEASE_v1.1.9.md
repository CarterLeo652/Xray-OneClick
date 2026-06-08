# Xray-OneClick v1.1.9

## 概要

模块化重构收尾版本：`install.sh` 瘦身为约 **216 行**薄入口，全部逻辑分布于 **32 个 `lib/` 模块**。单文件 `curl` 安装时仍会自动从 GitHub 拉取缺失模块。

## 新特性与改进

### 模块化架构（P0–P6）

- **薄入口** `install.sh`：模块下载、`main()` CLI 路由
- **`03-installer`**：`ike` / `sb` 快捷命令与 `lib/` 自部署
- **`03-system`**：依赖安装、BBR、系统预检、端口与 UUID 工具
- **协议 / Tunnel / 诊断 / CLI**：按职责拆分为独立 `lib/*.sh`，由 `00-bootstrap.sh` 按依赖顺序加载
- 安装时同步复制 `lib/` 至 `/usr/local/share/ike/lib/`

### 文档

- README 新增完整模块职责表、单文件安装说明、开发者入口流程

## 升级

已安装用户可重新运行安装脚本或执行 `ike update` 获取最新 Xray-core；安装器本身在下次 `bash install.sh` 或菜单安装流程中会自动更新。

```bash
curl -fsSL -o /root/install.sh https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh
bash /root/install.sh
```

## 完整变更

见 [CHANGELOG.md](../CHANGELOG.md)。
