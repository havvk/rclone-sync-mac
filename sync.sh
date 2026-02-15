#!/bin/bash
VERSION="1.1.0"
# ==============================================================================
# Cloud Sync - rclone 双向同步引擎
# 使用 rclone bisync 执行双向同步
#
# 用法:
#   ./sync.sh --remote=onedrive       # 同步指定 remote
#   ./sync.sh --remote=onedrive --dry-run    # 预览模式
#   ./sync.sh --remote=onedrive --resync     # 强制重新初始化
#   ./sync.sh --remote=onedrive --repair     # 清缓存并重新初始化
#   ./sync.sh --remote=onedrive --force      # 忽略 max-delete 保护
# ==============================================================================

set -euo pipefail

# ---- 路径 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
FILTERS_FILE="$SCRIPT_DIR/filters.txt"

# ---- 加载配置 ----
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# 默认值
LOCAL_PATH="${LOCAL_PATH:-$HOME/CloudSync}"
CONFLICT_RESOLVE="${CONFLICT_RESOLVE:-newer}"
CONFLICT_SILENT="${CONFLICT_SILENT:-true}"
MAX_DELETE_PCT="${MAX_DELETE_PCT:-50}"
SOCKS5_PROXY="${SOCKS5_PROXY:-}"
LOG_RETAIN_DAYS="${LOG_RETAIN_DAYS:-7}"
DATA_DIR="${DATA_DIR:-$HOME/.local/share/rclone-sync-mac}"
SYNC_RULES_FILE="$DATA_DIR/sync-rules.json"

# ---- 路径设置 ----
LOG_DIR="$DATA_DIR/logs"
STATUS_FILE="$DATA_DIR/status.json"
LOCK_FILE="$DATA_DIR/sync.lock"
RCLONE="/opt/homebrew/bin/rclone"

# ---- 确保目录存在 ----
mkdir -p "$LOG_DIR"

# ---- 参数解析 ----
DRY_RUN=false
RESYNC=false
FORCE=false
REPAIR=false
SINGLE_REMOTE=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=true ;;
        --resync)      RESYNC=true ;;
        --force)       FORCE=true ;;
        --repair)      REPAIR=true; RESYNC=true ;;
        --remote=*)    SINGLE_REMOTE="${arg#--remote=}" ;;
        *)             echo "未知参数: $arg"; exit 1 ;;
    esac
done

# 必须指定 remote
if [[ -z "$SINGLE_REMOTE" ]]; then
    echo "❌ 必须指定 --remote=xxx 参数"
    exit 1
fi

# 去掉尾部冒号用作标识
REMOTE_TAG="${SINGLE_REMOTE%:}"
[[ "$SINGLE_REMOTE" != *: ]] && SINGLE_REMOTE="${SINGLE_REMOTE}:"

# ---- Per-remote 文件路径 ----
LOCK_FILE="$DATA_DIR/sync-${REMOTE_TAG}.lock"
STATUS_FILE="$DATA_DIR/status-${REMOTE_TAG}.json"
LOG_FILE="$LOG_DIR/sync_$(date +%Y%m%d_%H%M%S)_${REMOTE_TAG}.log"

# ---- 日志函数 ----
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# ---- 写状态文件 ----
write_status() {
    local status="$1"
    local message="$2"
    local files_transferred="${3:-0}"
    local errors="${4:-0}"

    cat > "$STATUS_FILE" <<EOF
{
    "status": "$status",
    "message": "$message",
    "remote": "$REMOTE_TAG",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "timestamp_local": "$(date '+%Y-%m-%d %H:%M:%S')",
    "files_transferred": $files_transferred,
    "errors": $errors,
    "dry_run": $DRY_RUN,
    "pid": $$
}
EOF
}

# ---- 锁文件机制 ----
LOCK_ACQUIRED=false

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log "⚠️  另一个同步进程正在运行 (PID: $lock_pid)，跳过"
            # 不覆盖 status.json，保留正在运行的进程的状态信息
            exit 0
        else
            log "🔓 清理过期锁文件"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED=true
}

release_lock() {
    # Only release if this process owns the lock (PID matches)
    if $LOCK_ACQUIRED; then
        local current_pid
        current_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ "$current_pid" == "$$" ]]; then
            rm -f "$LOCK_FILE"
        fi
    fi
}

# 收到终止信号时，杀掉所有子进程并退出
cleanup_and_exit() {
    log "⚠️  收到终止信号，正在清理..."
    # 只杀掉本脚本的子进程（rclone, tee, stdbuf, sed 等）
    pkill -P $$ 2>/dev/null || true
    release_lock
    exit 130
}

# 正常退出时释放锁；收到 TERM/INT 信号时杀子进程并退出
trap release_lock EXIT
trap cleanup_and_exit SIGTERM SIGINT

# ---- 清理旧日志 ----
cleanup_logs() {
    find "$LOG_DIR" -name "sync_*.log" -mtime "+${LOG_RETAIN_DAYS}" -delete 2>/dev/null || true
}

# ---- 发送 macOS 通知 ----
notify() {
    local title="$1"
    local message="$2"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

# ---- 检测是否需要 resync ----
needs_resync() {
    # 检查 bisync 工作目录是否有历史文件
    local workdir="$HOME/Library/Caches/rclone/bisync"
    if [[ ! -d "$workdir" ]] || [[ -z "$(ls -A "$workdir" 2>/dev/null)" ]]; then
        return 0  # 需要 resync
    fi
    return 1  # 不需要
}

# ---- 根据 sync-rules.json 计算指定 remote 的排除目录 ----
get_exclude_filters() {
    local remote_name="$1"
    # 去掉尾部冒号
    remote_name="${remote_name%:}"

    if [[ ! -f "$SYNC_RULES_FILE" ]]; then
        return  # 无规则文件 = 不排除任何目录
    fi

    # 需要 jq 来解析 JSON
    if ! command -v jq &>/dev/null; then
        log "⚠️  jq 未安装，跳过同步规则过滤"
        return
    fi

    local mode
    mode=$(jq -r '.mode // "auto"' "$SYNC_RULES_FILE")

    # 获取本地第一级子目录
    local all_dirs=()
    while IFS= read -r d; do
        [[ -n "$d" ]] && all_dirs+=("$d")
    done < <(find "$LOCAL_PATH" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -exec basename {} \;)

    for dir in "${all_dirs[@]}"; do
        local should_sync=true

        # 检查这个目录是否在规则文件中
        local in_rules
        in_rules=$(jq -r --arg d "$dir" '.rules | has($d)' "$SYNC_RULES_FILE")

        if [[ "$in_rules" == "true" ]]; then
            # 目录在规则中：检查是否包含当前 remote
            local has_remote
            has_remote=$(jq -r --arg d "$dir" --arg r "$remote_name" \
                '.rules[$d] | if . then map(select(. == $r)) | length > 0 else false end' \
                "$SYNC_RULES_FILE")
            if [[ "$has_remote" != "true" ]]; then
                should_sync=false
            fi
        else
            # 目录不在规则中
            if [[ "$mode" == "manual" ]]; then
                should_sync=false  # 手动模式：未列出 = 不同步
            fi
            # 自动模式：未列出 = 全部同步（默认 true）
        fi

        if ! $should_sync; then
            echo "- ${dir}/**"
        fi
    done
}

# ---- 主同步函数 ----
do_sync() {
    local current_remote="$1"
    # 确保 remote 以 : 结尾
    [[ "$current_remote" != *: ]] && current_remote="${current_remote}:"

    local tag="${current_remote%:}"

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "[$tag] 🚀 双向同步开始"
    log "[$tag]    本地: $LOCAL_PATH"
    log "[$tag]    远程: $current_remote"
    log "[$tag]    冲突策略: $CONFLICT_RESOLVE"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    write_status "syncing" "同步中... ($tag)" 0 0

    # 构建命令参数
    local cmd=("$RCLONE" "bisync" "$LOCAL_PATH" "$current_remote")

    # 静态过滤规则
    if [[ -f "$FILTERS_FILE" ]]; then
        cmd+=(--filters-file "$FILTERS_FILE")
    fi

    # 动态同步规则过滤（per-remote）
    local dynamic_excludes
    dynamic_excludes=$(get_exclude_filters "$current_remote")
    if [[ -n "$dynamic_excludes" ]]; then
        log "[$tag]    同步规则排除:"
        while IFS= read -r filter; do
            [[ -n "$filter" ]] || continue
            cmd+=(--filter "$filter")
            log "[$tag]      $filter"
        done <<< "$dynamic_excludes"
    fi

    # 冲突处理
    cmd+=(--conflict-resolve "$CONFLICT_RESOLVE")
    cmd+=(--conflict-loser "num")

    # 安全限制
    cmd+=(--max-delete "$MAX_DELETE_PCT")

    # 弹性恢复
    cmd+=(--resilient --recover)

    # 时间戳容差（避免因微小 modtime 差异导致不必要的重传）
    cmd+=(--modify-window 1s)

    # 详细输出
    cmd+=(--verbose)

    # 代理（通过命令行参数传递，环境变量作为备用）
    if [[ -n "$SOCKS5_PROXY" ]]; then
        cmd+=(--http-proxy "$SOCKS5_PROXY")
        export ALL_PROXY="$SOCKS5_PROXY"
        export all_proxy="$SOCKS5_PROXY"
        export HTTPS_PROXY="$SOCKS5_PROXY"
        export https_proxy="$SOCKS5_PROXY"
        export HTTP_PROXY="$SOCKS5_PROXY"
        export http_proxy="$SOCKS5_PROXY"
        export NO_PROXY="localhost,127.0.0.1,::1"
        export no_proxy="localhost,127.0.0.1,::1"
        log "[$tag]    代理: $SOCKS5_PROXY"
    fi

    # 可选参数
    if $DRY_RUN; then
        cmd+=(--dry-run)
        log "[$tag]    模式: 预览 (dry-run)"
    fi

    if $RESYNC; then
        cmd+=(--resync --resync-mode newer)
        log "[$tag]    ⚠️  执行 resync 初始化"
        # 清除 bisync 缓存，避免 invalidResourceId 等陈旧缓存问题
        local cachedir="$HOME/Library/Caches/rclone/bisync"
        if [[ -d "$cachedir" ]]; then
            # 只清除当前 remote 的缓存文件，避免影响其他并发同步的 remote
            local cleaned=0
            for f in "$cachedir"/*"${tag}"*; do
                [[ -e "$f" ]] || continue
                [[ "$f" == *.lck ]] && continue  # 不删除锁文件，由 rclone 自行管理
                rm -f "$f" && cleaned=$((cleaned+1))
            done
            if [[ $cleaned -gt 0 ]]; then
                if $REPAIR; then
                    log "[$tag]    🔧 已清除 $cleaned 个 $tag 缓存文件"
                else
                    log "[$tag]    🗑️  已清除 $cleaned 个 $tag 缓存文件"
                fi
            fi
        fi
    elif needs_resync; then
        log "[$tag]    ⚠️  首次运行，自动执行 resync"
        cmd+=(--resync --resync-mode newer)
    fi

    # rclone bisync 锁文件处理
    # rclone 在 bisync 开始时创建 .lck，结束时删除。
    # 重要: 只清理当前 remote 的残留锁文件！
    # 如果用 `find -name '*.lck'` 清理所有锁文件，当 onedrive 长时间同步（数小时）时，
    # gdrive 启动时会误删 onedrive 的 .lck，导致 onedrive 结束时报 "no such file" 错误。
    local rclone_cachedir="$HOME/Library/Caches/rclone/bisync"
    mkdir -p "$rclone_cachedir"

    # 只清理当前 remote 的锁文件（超过 5 分钟视为残留）
    find "$rclone_cachedir" -name "*${tag}*.lck" -mmin +5 -exec rm -f {} \; 2>/dev/null

    if $FORCE; then
        cmd+=(--force)
        log "[$tag]    ⚠️  忽略 max-delete 保护"
    fi

    # 执行同步
    log ""
    log "[$tag] 📋 执行命令: ${cmd[*]}"
    log ""

    local exit_code=0
    local output
    # 实时写入日志：使用临时文件避免 tee 污染 output 变量
    local tmpout="$(mktemp)"
    if command -v stdbuf &>/dev/null; then
        stdbuf -oL "${cmd[@]}" 2>&1 | tee "$tmpout" | sed "s/^/[$tag] /" >> "$LOG_FILE"
        exit_code=${PIPESTATUS[0]}
    else
        "${cmd[@]}" 2>&1 | tee "$tmpout" | sed "s/^/[$tag] /" >> "$LOG_FILE"
        exit_code=${PIPESTATUS[0]}
    fi
    output=$(cat "$tmpout")
    rm -f "$tmpout"

    # 解析结果
    local transferred=0
    local errors=0

    if echo "$output" | grep -q "Transferred:"; then
        transferred=$(echo "$output" | grep "Transferred:" | head -1 | grep -oE '[0-9]+' | head -1 || echo "0")
    fi

    if echo "$output" | grep -q "Errors:"; then
        errors=$(echo "$output" | grep "Errors:" | head -1 | grep -oE '[0-9]+' | head -1 || echo "0")
    fi

    # 检查是否为已完成同步后的无害错误
    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -q "100%"; then
        # 情况1: rclone bisync 完成后无法删除自己的 .lck 文件（竞争条件）
        # 这种错误不会损坏 bisync 状态，真正无害，直接忽略
        if echo "$output" | grep -q "cannot remove lockfile" && \
           ! echo "$output" | grep -q "Must run --resync"; then
            log "[$tag] ⚠️  忽略无害的锁文件清理错误（同步已完成）"
            exit_code=0
        fi

        # 情况2: OneDrive 409 eTag 竞争导致 bisync 状态损坏
        # 所有文件已传输完毕，但 rclone 已将 bisync 标记为 aborted
        # 需要自动执行 --resync 恢复 bisync 状态，否则下次正常同步会拒绝运行
        if echo "$output" | grep -q "Must run --resync to recover"; then
            log "[$tag] ⚠️  检测到 bisync 状态损坏（可能由 OneDrive eTag 竞争引起）"
            log "[$tag] 🔄 自动执行 --resync 恢复 bisync 状态..."

            # 构建 resync 命令（复用当前参数，去掉 verbose 减少输出）
            local resync_cmd=("$RCLONE" "bisync" "$LOCAL_PATH" "$current_remote"
                --resync --resync-mode newer --resilient)

            # 保留过滤规则
            if [[ -f "$FILTERS_FILE" ]]; then
                resync_cmd+=(--filters-file "$FILTERS_FILE")
            fi
            if [[ -n "$dynamic_excludes" ]]; then
                while IFS= read -r filter; do
                    [[ -n "$filter" ]] || continue
                    resync_cmd+=(--filter "$filter")
                done <<< "$dynamic_excludes"
            fi

            # 保留代理
            if [[ -n "$SOCKS5_PROXY" ]]; then
                resync_cmd+=(--http-proxy "$SOCKS5_PROXY")
            fi

            log "[$tag] 📋 恢复命令: ${resync_cmd[*]}"
            local resync_exit=0
            "${resync_cmd[@]}" >> "$LOG_FILE" 2>&1 || resync_exit=$?

            if [[ $resync_exit -eq 0 ]]; then
                log "[$tag] ✅ bisync 状态已恢复，下次同步将正常运行"
                exit_code=0
            else
                log "[$tag] ❌ bisync 状态恢复失败 (退出码: $resync_exit)"
                # exit_code 保持原始错误码
            fi
        fi
    fi

    # 写入结果
    if [[ $exit_code -eq 0 ]]; then
        log ""
        log "[$tag] ✅ 同步完成"
        write_status "success" "同步完成" "$transferred" "$errors"

        if ! $DRY_RUN && [[ "$CONFLICT_SILENT" != "true" ]] && [[ $transferred -gt 0 ]]; then
            notify "Cloud Sync" "✅ $tag 同步完成，${transferred} 个文件已处理"
        fi
    else
        log ""
        log "[$tag] ❌ 同步失败 (退出码: $exit_code)"

        local err_msg="同步失败"
        local err_status="error"
        if echo "$output" | grep -qi "max delete"; then
            log "[$tag] 💡 提示: 删除文件数超过安全限制 ($MAX_DELETE_PCT 个)"
            err_msg="删除文件数超过限制 ($MAX_DELETE_PCT)"
            err_status="max_delete"
        elif echo "$output" | grep -qi "resync"; then
            log "[$tag] 💡 提示: 可能需要执行 --resync 修复"
            err_msg="需要 resync 修复"
        fi
        write_status "$err_status" "$err_msg" "$transferred" "$errors"

        notify "Cloud Sync" "❌ $tag 同步失败，请检查日志"
    fi

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return $exit_code
}

# ---- 主流程 ----
acquire_lock
cleanup_logs

write_status "syncing" "同步中..." 0 0

log "📡 开始同步: $SINGLE_REMOTE"

do_sync "$SINGLE_REMOTE"
exit_code=$?

log ""
log "🏁 同步结束: $REMOTE_TAG (退出码: $exit_code)"
