#!/bin/bash
# ==============================================================================
# Cloud Sync - 环境初始化脚本
# 支持 rclone 所有云存储服务: OneDrive, Google Drive, Dropbox, S3 等
#
# 用法:
#   ./setup.sh              # 完整设置流程
#   ./setup.sh --check      # 仅检查环境
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# ---- 颜色 ----
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}✅${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠️${NC}  $1"; }
err()   { echo -e "${RED}❌${NC} $1"; }
info()  { echo -e "${CYAN}ℹ️${NC}  $1"; }

# ---- 读取当前配置 ----
get_config_value() {
    local key="$1"
    local default="$2"
    if [[ -f "$CONFIG_FILE" ]]; then
        local val
        val=$(grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | sed 's/#.*//' | xargs)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

# ---- 检查 rclone ----
check_rclone() {
    if command -v rclone &>/dev/null; then
        log "rclone 已安装: $(rclone version | head -1)"
        return 0
    fi
    return 1
}

install_rclone() {
    echo ""
    info "rclone 未安装，开始安装..."
    if command -v brew &>/dev/null; then
        echo "   使用 Homebrew 安装..."
        brew install rclone
    else
        echo "   使用官方安装脚本..."
        curl -fsSL https://rclone.org/install.sh | sudo bash
    fi
    if command -v rclone &>/dev/null; then
        log "rclone 安装成功: $(rclone version | head -1)"
    else
        err "rclone 安装失败"
        exit 1
    fi
}

# ---- 检查已配置的 remote ----
check_remote() {
    local remote
    remote=$(get_config_value "REMOTE" "")
    remote="${remote%:}"  # Remove trailing colon

    if [[ -z "$remote" ]]; then
        return 1
    fi

    if rclone listremotes 2>/dev/null | grep -q "^${remote}:$"; then
        log "云存储 remote 已配置: ${remote}:"
        return 0
    fi
    return 1
}

# ---- 支持的云存储列表 ----
show_providers() {
    echo ""
    echo -e "${BOLD}支持的云存储服务:${NC}"
    echo ""
    echo "   1) OneDrive           (个人版 / 商业版 / SharePoint)"
    echo "   2) Google Drive       (个人版 / Workspace)"
    echo "   3) Dropbox"
    echo "   4) Amazon S3          (及兼容服务: MinIO, 阿里云 OSS 等)"
    echo "   5) WebDAV             (Nextcloud, ownCloud, 坚果云等)"
    echo "   6) SFTP               (任何 SSH 服务器)"
    echo "   7) 其他               (rclone 支持 70+ 种服务)"
    echo ""
}

# ---- 设置云存储 ----
setup_remote() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔐 云存储配置"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 检查是否有现成的 remote
    local existing
    existing=$(rclone listremotes 2>/dev/null | head -10)
    if [[ -n "$existing" ]]; then
        echo ""
        info "检测到已配置的 remote:"
        echo "$existing" | while read -r r; do
            echo "     • $r"
        done
        echo ""
        read -p "是否使用已配置的 remote? (输入名称，或按 Enter 创建新的): " use_existing
        if [[ -n "$use_existing" ]]; then
            use_existing="${use_existing%:}"  # Remove trailing colon
            if rclone listremotes 2>/dev/null | grep -q "^${use_existing}:$"; then
                update_config_remote "$use_existing"
                log "已选择: ${use_existing}:"
                return
            else
                warn "remote '${use_existing}' 不存在"
            fi
        fi
    fi

    show_providers
    read -p "请选择 (1-7): " choice

    local backend=""
    local remote_name=""

    case "$choice" in
        1)
            backend="onedrive"
            remote_name="onedrive"
            setup_oauth_remote "$remote_name" "$backend"
            ;;
        2)
            backend="drive"
            remote_name="gdrive"
            setup_oauth_remote "$remote_name" "$backend"
            ;;
        3)
            backend="dropbox"
            remote_name="dropbox"
            setup_oauth_remote "$remote_name" "$backend"
            ;;
        4)
            remote_name="s3"
            setup_s3_remote
            ;;
        5)
            remote_name="webdav"
            setup_webdav_remote
            ;;
        6)
            remote_name="sftp"
            setup_sftp_remote
            ;;
        7)
            setup_custom_remote
            return
            ;;
        *)
            err "无效选择"
            exit 1
            ;;
    esac
}

# ---- OAuth 类云存储设置 (OneDrive, Google Drive, Dropbox) ----
setup_oauth_remote() {
    local name="$1"
    local backend="$2"

    echo ""
    info "即将打开浏览器进行授权..."
    info "请在浏览器中登录并授权 rclone 访问。"
    echo ""
    read -p "按 Enter 继续..." _

    echo ""
    info "正在启动授权流程（浏览器将自动打开）..."
    echo ""

    TOKEN_OUTPUT=$(rclone authorize "$backend" 2>&1) || {
        err "授权失败，尝试使用 rclone config 交互式配置..."
        rclone config
        # After interactive config, find the remote created
        local new_remotes
        new_remotes=$(rclone listremotes 2>/dev/null)
        if [[ -n "$new_remotes" ]]; then
            info "可用 remote:"
            echo "$new_remotes"
            read -p "请输入要使用的 remote 名称: " name
            name="${name%:}"
            update_config_remote "$name"
        fi
        return
    }

    # Extract token JSON
    TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '\{"access_token":[^}]+\}' | tail -1)

    if [[ -z "$TOKEN" ]]; then
        warn "无法自动提取令牌，切换到交互式配置..."
        rclone config
        local new_remotes
        new_remotes=$(rclone listremotes 2>/dev/null)
        if [[ -n "$new_remotes" ]]; then
            read -p "请输入要使用的 remote 名称: " name
            name="${name%:}"
            update_config_remote "$name"
        fi
        return
    fi

    log "授权令牌获取成功"

    # Create remote
    info "正在创建 remote: ${name}..."

    local extra_args=()
    if [[ "$backend" == "onedrive" ]]; then
        extra_args=(drive_type=personal)
    fi

    rclone config create "$name" "$backend" token="$TOKEN" ${extra_args[@]+"${extra_args[@]}"} 2>/dev/null

    # For OneDrive: detect drive_id
    if [[ "$backend" == "onedrive" ]]; then
        DRIVE_INFO=$(rclone backend drives "${name}:" 2>/dev/null || echo "")
        if [[ -n "$DRIVE_INFO" ]]; then
            DRIVE_ID=$(echo "$DRIVE_INFO" | python3 -c "
import json, sys
try:
    drives = json.load(sys.stdin)
    for d in drives:
        if d.get('driveType') == 'personal':
            print(d['id']); break
    else:
        if drives: print(drives[0]['id'])
except: pass" 2>/dev/null || echo "")
            if [[ -n "$DRIVE_ID" ]]; then
                rclone config update "$name" drive_id="$DRIVE_ID" 2>/dev/null
            fi
        fi
    fi

    # Verify
    info "验证连接..."
    if rclone lsd "${name}:" --max-depth 0 &>/dev/null; then
        log "${name}: 连接成功！"
        update_config_remote "$name"
    else
        warn "连接验证失败，可能需要检查: rclone config show ${name}"
        update_config_remote "$name"
    fi
}

# ---- S3 设置 ----
setup_s3_remote() {
    echo ""
    info "S3 兼容存储配置"
    read -p "Provider (AWS/Minio/Alibaba/Other) [AWS]: " provider
    provider="${provider:-AWS}"
    read -p "Access Key ID: " access_key
    read -sp "Secret Access Key: " secret_key
    echo ""
    read -p "Region [us-east-1]: " region
    region="${region:-us-east-1}"
    read -p "Endpoint (留空使用 AWS 默认): " endpoint

    local args=(provider="$provider" access_key_id="$access_key" secret_access_key="$secret_key" region="$region")
    [[ -n "$endpoint" ]] && args+=(endpoint="$endpoint")

    rclone config create s3 s3 "${args[@]}" 2>/dev/null
    log "S3 remote 已创建"
    update_config_remote "s3"
}

# ---- WebDAV 设置 ----
setup_webdav_remote() {
    echo ""
    info "WebDAV 配置 (Nextcloud, ownCloud, 坚果云等)"
    read -p "WebDAV URL: " url
    read -p "用户名: " user
    read -sp "密码: " pass
    echo ""
    read -p "Vendor (nextcloud/owncloud/other) [other]: " vendor
    vendor="${vendor:-other}"

    rclone config create webdav webdav url="$url" user="$user" pass="$(rclone obscure "$pass")" vendor="$vendor" 2>/dev/null
    log "WebDAV remote 已创建"
    update_config_remote "webdav"
}

# ---- SFTP 设置 ----
setup_sftp_remote() {
    echo ""
    info "SFTP 配置"
    read -p "主机地址: " host
    read -p "端口 [22]: " port
    port="${port:-22}"
    read -p "用户名: " user
    read -p "远程路径 [/home/$user]: " path
    path="${path:-/home/$user}"

    rclone config create sftp sftp host="$host" port="$port" user="$user" 2>/dev/null
    log "SFTP remote 已创建"
    update_config_remote "sftp"
}

# ---- 自定义 (rclone config 交互式) ----
setup_custom_remote() {
    echo ""
    info "启动 rclone 交互式配置..."
    info "完成后输入你创建的 remote 名称。"
    echo ""
    rclone config
    echo ""
    read -p "请输入要使用的 remote 名称: " name
    name="${name%:}"
    if rclone listremotes 2>/dev/null | grep -q "^${name}:$"; then
        update_config_remote "$name"
        log "已选择: ${name}:"
    else
        err "remote '${name}' 未找到"
        exit 1
    fi
}

# ---- 更新 config.env 中的 REMOTE ----
update_config_remote() {
    local name="$1"
    if [[ ! -f "$CONFIG_FILE" ]]; then return; fi

    # 读取当前 REMOTE
    local current_remote
    current_remote=$(grep "^REMOTE=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | sed 's/:.*//')

    if [[ -z "$current_remote" || "$current_remote" == "$name" ]]; then
        # 首次设置 or 相同 remote — 直接写
        sed -i '' "s|^REMOTE=.*|REMOTE=\"${name}:\"|" "$CONFIG_FILE"
    else
        # 已有不同的 remote — 追加到 REMOTES
        local current_remotes
        current_remotes=$(grep "^REMOTES=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

        if [[ -z "$current_remotes" ]]; then
            # REMOTES 为空，设为 "旧remote: 新remote:"
            local new_remotes="${current_remote}: ${name}:"
            sed -i '' "s|^REMOTES=.*|REMOTES=\"${new_remotes}\"|" "$CONFIG_FILE"
        elif ! echo "$current_remotes" | grep -q "${name}:"; then
            # 新 remote 不在 REMOTES 中，追加
            local new_remotes="${current_remotes} ${name}:"
            sed -i '' "s|^REMOTES=.*|REMOTES=\"${new_remotes}\"|" "$CONFIG_FILE"
        fi
        # REMOTE 保持不变（主 remote）
        info "已将 ${name}: 添加到多 remote 同步列表"
    fi
}

# ---- 创建本地同步目录 ----
setup_local_dir() {
    local sync_dir
    sync_dir=$(get_config_value "LOCAL_PATH" "\$HOME/CloudSync")
    sync_dir="${sync_dir/\$HOME/$HOME}"

    if [[ -d "$sync_dir" ]]; then
        log "本地同步目录已存在: $sync_dir"
    else
        echo ""
        read -p "本地同步目录 [$sync_dir]: " custom_dir
        if [[ -n "$custom_dir" ]]; then
            sync_dir="$custom_dir"
            # Update config
            if [[ -f "$CONFIG_FILE" ]] && grep -q "^LOCAL_PATH=" "$CONFIG_FILE"; then
                sed -i '' "s|^LOCAL_PATH=.*|LOCAL_PATH=\"$sync_dir\"|" "$CONFIG_FILE"
            fi
        fi
        mkdir -p "$sync_dir"
        log "本地同步目录已创建: $sync_dir"
    fi
}

# ---- 检查 Xcode CLI ----
check_xcode_cli() {
    if command -v swiftc &>/dev/null; then
        log "Xcode Command Line Tools 已安装"
        return 0
    fi
    return 1
}

install_xcode_cli() {
    echo ""
    info "正在安装 Xcode Command Line Tools..."
    xcode-select --install 2>/dev/null || true
    echo ""
    warn "请在弹出的对话框中点击「安装」，安装完成后重新运行此脚本。"
    exit 0
}

# ---- 主流程 ----
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "☁️  Cloud Sync - 环境设置"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

# Step 1: rclone
echo "📋 Step 1/4: 检查 rclone..."
if ! check_rclone; then
    if $CHECK_ONLY; then
        err "rclone 未安装"
    else
        install_rclone
    fi
fi

# Step 2: Cloud remote
echo ""
echo "📋 Step 2/4: 云存储配置..."
existing_remotes=$(rclone listremotes 2>/dev/null)
if [[ -n "$existing_remotes" ]]; then
    echo ""
    info "已配置的云存储:"
    echo "$existing_remotes" | while read -r r; do
        echo -e "     ${GREEN}•${NC} $r"
    done
    echo ""
    if ! $CHECK_ONLY; then
        read -p "是否添加新的云存储? (y/N): " add_new
        if [[ "$add_new" =~ ^[Yy] ]]; then
            show_providers
            read -p "请选择 (1-7): " choice
            case "$choice" in
                1) setup_oauth_remote "onedrive" "onedrive" ;;
                2) setup_oauth_remote "gdrive" "drive" ;;
                3) setup_oauth_remote "dropbox" "dropbox" ;;
                4) setup_s3_remote ;;
                5) setup_webdav_remote ;;
                6) setup_sftp_remote ;;
                7) setup_custom_remote ;;
                *) warn "跳过" ;;
            esac
        fi
    fi
else
    if $CHECK_ONLY; then
        err "云存储 remote 未配置"
    else
        info "未检测到任何云存储配置"
        setup_remote
    fi
fi

# Step 3: Local directory
echo ""
echo "📋 Step 3/4: 检查本地目录..."
setup_local_dir

# Step 4: Xcode CLI
echo ""
echo "📋 Step 4/4: 检查编译工具..."
if ! check_xcode_cli; then
    if $CHECK_ONLY; then
        err "Xcode Command Line Tools 未安装"
    else
        install_xcode_cli
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "环境检查完成！可以运行 ./install.sh 安装应用。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
