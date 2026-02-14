# ☁️ AIIA-RcloneSync

> 一个轻量级 macOS 菜单栏应用，使用 [rclone bisync](https://rclone.org/bisync/) 在后台双向同步任意云存储。
>
> A lightweight macOS menu bar app for bidirectional cloud sync powered by [rclone](https://rclone.org/bisync/).

<p align="center">
  <img src="StatusBarApp/AppIcon.png" width="128" alt="AIIA-RcloneSync Icon">
</p>

## 🌐 支持的云存储 / Supported Providers

| Provider | Type | Setup |
|----------|------|-------|
| **OneDrive** (个人版 / 商业版) | OAuth | 浏览器自动授权 |
| **Google Drive** | OAuth | 浏览器自动授权 |
| **Dropbox** | OAuth | 浏览器自动授权 |
| **Amazon S3** (及 MinIO, 阿里云 OSS 等) | Key | Access Key + Secret |
| **WebDAV** (Nextcloud, ownCloud, 坚果云) | Password | URL + 用户名密码 |
| **SFTP** (任何 SSH 服务器) | SSH | 主机 + 用户名 |
| **70+ 其他服务** | 各异 | 通过 `rclone config` |

---

## ✨ 特性 / Features

- 🔄 **双向同步** — 基于 `rclone bisync`，本地和云端双向实时同步
- ☁️ **菜单栏常驻** — 实时显示同步状态（SF Symbols 图标），自动识别云服务名称
- ⏰ **定时自动同步** — 通过 launchd 定时触发，可自定义间隔（5 分钟 ~ 2 小时）
- 🛡️ **安全保护** — 最大删除百分比限制，防止误删
- ⚔️ **冲突策略可配** — 以较新/较旧/较大/本地/远程文件为准
- 🌐 **代理支持** — SOCKS5 代理，可在 UI 中设置
- 🔐 **一键设置** — 自动安装 rclone、交互式云存储授权
- 🏗️ **源码分发** — 在用户机器上编译，无需签名证书
- 🔒 **单实例保护** — 防止重复运行

## 🚀 快速开始 / Quick Start

### 前置条件 / Prerequisites

- macOS 14.0+ (Sonoma 或更高)
- [Homebrew](https://brew.sh)（推荐，用于安装 rclone）

### 一键安装 / One-Click Install

```bash
git clone https://github.com/havvk/rclone-sync-mac.git
cd rclone-sync-mac
./install.sh
```

安装脚本会自动完成以下步骤：

1. ✅ 检查/安装 rclone
2. ✅ 交互式选择云存储服务，引导授权
3. ✅ 创建本地同步目录
4. ✅ 检查/安装 Xcode Command Line Tools
5. ✅ 编译 SwiftUI 菜单栏应用
6. ✅ 安装到 `/Applications/AIIA-RcloneSync.app`
7. ✅ 配置 launchd 定时任务（默认每 30 分钟同步一次）
8. ✅ 启动菜单栏应用

> **首次使用**：安装后点击菜单栏图标 → 「🔄 重新初始化同步」→「先预览」确认同步内容。

### 卸载 / Uninstall

```bash
./uninstall.sh          # 卸载（保留数据和日志）
./uninstall.sh --purge  # 卸载并删除所有数据
```

## ⚙️ 配置 / Configuration

编辑 `config.env` 或通过菜单栏应用的 **⚙️ 设置** 菜单直接修改：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `LOCAL_PATH` | `$HOME/OneDrive` | 本地同步目录 |
| `REMOTE` | `onedrive:` | rclone remote 名称 |
| `SYNC_INTERVAL` | `1800` | 同步间隔（秒） |
| `CONFLICT_RESOLVE` | `newer` | 冲突策略 |
| `MAX_DELETE_PCT` | `50` | 最大删除文件数保护 |
| `SOCKS5_PROXY` | *(空)* | SOCKS5 代理地址 |

### 过滤规则 `filters.txt`

默认排除 `.git/`、`node_modules/`、`__pycache__/`、`.DS_Store` 等不需要同步的目录和文件。可根据需要编辑。

### 切换云存储

只需修改 `config.env` 中的 `REMOTE` 和 `LOCAL_PATH`：

```bash
# Google Drive
REMOTE="gdrive:"
LOCAL_PATH="$HOME/GoogleDrive"

# Dropbox
REMOTE="dropbox:"
LOCAL_PATH="$HOME/Dropbox"

# Nextcloud (WebDAV)
REMOTE="webdav:"
LOCAL_PATH="$HOME/Nextcloud"

# SFTP 服务器
REMOTE="sftp:myserver"
LOCAL_PATH="$HOME/ServerSync"
```

## 🛠️ 命令行使用 / CLI Usage

```bash
./sync.sh                # 正常同步
./sync.sh --dry-run      # 预览模式
./sync.sh --resync       # 重新初始化基准线
./sync.sh --force        # 忽略 max-delete 保护
```

## 🏗️ 架构 / Architecture

```
┌──────────────────────────────────────────┐
│         AIIA-RcloneSync.app (SwiftUI)          │
│  ┌─────────┐  ┌────────┐  ┌──────────┐  │
│  │状态监控  │  │菜单控制 │  │设置管理   │  │
│  └────┬────┘  └───┬────┘  └────┬─────┘  │
│       ▼           ▼            ▼         │
│  status.json   sync.sh    config.env     │
└───────────────────┬──────────────────────┘
                    │
            ┌───────▼───────┐
            │   sync.sh     │
            │ (锁文件/日志)  │
            └───────┬───────┘
                    │
            ┌───────▼───────┐
            │ rclone bisync │◄── filters.txt
            └──┬─────────┬──┘
               │         │
         ┌─────▼──┐  ┌───▼──────┐
         │  本地   │  │ 云存储    │
         │  目录   │  │ (remote) │
         └────────┘  └──────────┘

  ⏰ launchd → 定时触发 sync.sh
```

## 📁 项目结构 / Project Structure

```
rclone-sync-mac/
├── README.md
├── LICENSE                          # MIT
├── .gitignore
├── config.env                       # 用户配置
├── filters.txt                      # rclone 过滤规则
├── sync.sh                          # 核心同步引擎
├── setup.sh                         # 环境初始化（安装 rclone + 授权云存储）
├── install.sh                       # 一键安装
├── uninstall.sh                     # 卸载脚本
├── com.rclone.sync-mac.plist   # launchd 定时任务
└── StatusBarApp/
    ├── AIIA-RcloneSyncApp.swift        # SwiftUI 菜单栏应用源码
    └── AppIcon.icns                 # 应用图标
```

## ❓ FAQ

<details>
<summary><b>首次同步报错怎么办？</b></summary>

首次同步需要建立基准线。点击菜单栏 → 「🔄 重新初始化同步」→「直接执行」。
</details>

<details>
<summary><b>为什么不需要 Apple 签名证书？</b></summary>

应用在用户本机通过 `swiftc` 编译，macOS 自动信任本地编译的二进制文件。
</details>

<details>
<summary><b>如何在新电脑上使用？</b></summary>

克隆仓库后运行 `./install.sh`，脚本会引导完成 rclone 安装和云存储授权。也可以在应用内点击「🛠️ 配置云存储连接」。
</details>

<details>
<summary><b>同步冲突如何处理？</b></summary>

默认以较新的文件为准。被覆盖的文件会带编号后缀保留（如 `file.conflict1.txt`）。可在设置中修改策略。
</details>

<details>
<summary><b>支持 OneDrive 商业版 / SharePoint 吗？</b></summary>

支持。在 `setup.sh` 授权时选择 OneDrive，登录商业账号即可，rclone 会自动识别驱动器类型。
</details>

## 📄 License

[MIT](LICENSE)

## 🙏 致谢 / Acknowledgments

- [rclone](https://rclone.org/) — 强大的云同步工具，支持 70+ 种存储服务
