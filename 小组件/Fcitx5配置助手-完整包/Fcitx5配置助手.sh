#!/usr/bin/env bash

# Fcitx5 配置助手
#
# 这是一个面向本机 Fcitx5 + Rime 的图形配置助手。它管理 Fcitx5 的
# 核心配置、Rime 方案、个性短语、用户词库、快捷键、主题和备份。
# 讯飞输入法的语音、云同步等服务功能不属于 Fcitx5 配置范围，助手会
# 明确提示，而不会修改讯飞的二进制用户数据。

set -u
set -o pipefail

APP_TITLE="Fcitx5 配置助手"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

FCITX_DIR="$CONFIG_HOME/fcitx5"
FCITX_CONFIG="$FCITX_DIR/config"
FCITX_PROFILE="$FCITX_DIR/profile"
FCITX_CONF_DIR="$FCITX_DIR/conf"

RIME_DIR="$DATA_HOME/fcitx5/rime"
RIME_BUILD_DIR="$RIME_DIR/build"
RIME_PHRASE_FILE="$RIME_DIR/custom_phrase.txt"
RIME_SHARED_DIR="/usr/share/rime-data"
DESKTOP_DIR="${XDG_DESKTOP_DIR:-$HOME/桌面}"
IFLYTEK_CONFIG_DIR="$CONFIG_HOME/iflytek"
IFLYTEK_PHRASE_DEFAULT="$DESKTOP_DIR/cphrase.ini"

BACKUP_DIR="$STATE_HOME/fcitx5-config-assistant/backups"
LOG_DIR="$STATE_HOME/fcitx5-config-assistant/logs"
AUTOSTART_DIR="$CONFIG_HOME/autostart"
FCITX_AUTOSTART_FILE="$AUTOSTART_DIR/fcitx5.desktop"
LAST_BACKUP=""
LAST_LOG=""
QUIET_MODE=0

FIELD_SEPARATOR=$'\t'
PHRASE_FILTER=""

ENTRY_CODES=()
ENTRY_TEXTS=()
ENTRY_POSITIONS=()

SCHEMA_IDS=()
SCHEMA_NAMES=()

PROFILE_IM_NAMES=()
PROFILE_IM_LAYOUTS=()

log_message() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%F %T')" "$1" >> "$LOG_DIR/assistant.log" 2>/dev/null || true
}

error_dialog() {
    zenity --error --title="$APP_TITLE" --width=600 --no-markup --text="$1" >/dev/null 2>&1 || true
}

info_dialog() {
    zenity --info --title="$APP_TITLE" --width=620 --no-markup --text="$1" >/dev/null 2>&1 || true
}

question_dialog() {
    zenity --question --title="$APP_TITLE" --width=620 --no-markup --text="$1" \
        --ok-label="确定" --cancel-label="取消" >/dev/null 2>&1
}

show_text() {
    local title="$1"
    local text="$2"
    printf '%s\n' "$text" | zenity --text-info --title="$title" --width=980 --height=700 \
        --no-markup --ok-label="关闭" >/dev/null 2>&1 || true
}

open_path() {
    local path="$1"
    if [[ ! -e "$path" ]]; then
        error_dialog "路径不存在：\n$path"
        return 1
    fi
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$path" >/dev/null 2>&1 &
        return 0
    fi
    error_dialog "未找到 xdg-open，无法打开：\n$path"
    return 1
}

ask_entry() {
    local label="$1"
    local default_value="${2:-}"
    zenity --entry --title="$APP_TITLE" --width=700 --no-markup \
        --text="$label" --entry-text="$default_value" \
        --ok-label="确定" --cancel-label="取消" 2>/dev/null
}

bool_label() {
    if [[ "$1" == "True" || "$1" == "true" || "$1" == "1" ]]; then
        printf '开启'
    else
        printf '关闭'
    fi
}

bool_choices() {
    if [[ "$(bool_label "$1")" == "开启" ]]; then
        printf '开启|关闭'
    else
        printf '关闭|开启'
    fi
}

bool_config_value() {
    if [[ "$1" == "开启" ]]; then
        printf 'True'
    else
        printf 'False'
    fi
}

number_choices() {
    local current="$1"
    local minimum="$2"
    local maximum="$3"
    local value
    local output="$current"

    for ((value=minimum; value<=maximum; value++)); do
        [[ "$value" == "$current" ]] && continue
        output+="|$value"
    done
    printf '%s' "$output"
}

share_state_label() {
    case "$1" in
        Program) printf '按程序共享' ;;
        All) printf '全部程序共享' ;;
        *) printf '不共享' ;;
    esac
}

share_state_choices() {
    local current
    local option
    local output
    current=$(share_state_label "$1")
    output="$current"
    for option in '不共享' '按程序共享' '全部程序共享'; do
        [[ "$option" == "$current" ]] || output+="|$option"
    done
    printf '%s' "$output"
}

share_state_config_value() {
    case "$1" in
        '按程序共享') printf 'Program' ;;
        '全部程序共享') printf 'All' ;;
        *) printf 'No' ;;
    esac
}

command_status() {
    local command_name="$1"
    if command -v "$command_name" >/dev/null 2>&1; then
        printf '已安装 (%s)' "$(command -v "$command_name")"
    else
        printf '未找到'
    fi
}

fcitx_autostart_enabled() {
    local hidden=""

    [[ -f "$FCITX_AUTOSTART_FILE" ]] || return 1
    hidden=$(awk -F= '$1 ~ /^[[:space:]]*Hidden[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print tolower($2); exit}' "$FCITX_AUTOSTART_FILE")
    [[ "$hidden" != "true" ]]
}

fcitx_autostart_status() {
    if fcitx_autostart_enabled; then
        printf '已启用'
    else
        printf '未启用'
    fi
}

set_fcitx_autostart() {
    local value="$1"
    local tmp_file
    local fcitx_bin="fcitx5"
    local hidden_value="true"
    local gnome_value="false"
    local status_label="停用"

    mkdir -p "$AUTOSTART_DIR" || return 1
    if [[ "$value" == "True" ]]; then
        fcitx_bin=$(command -v fcitx5) || {
            log_message "启用 Fcitx5 开机启动失败：未找到 fcitx5"
            return 1
        }
        hidden_value="false"
        gnome_value="true"
        status_label="启用"
    fi

    tmp_file=$(mktemp "$AUTOSTART_DIR/.fcitx5-autostart.XXXXXX") || return 1
    printf '%s\n' \
        '[Desktop Entry]' \
        'Type=Application' \
        'Name=Fcitx5' \
        'Comment=Start Fcitx5 input method' \
        "Exec=$fcitx_bin -d" \
        'Terminal=false' \
        "Hidden=$hidden_value" \
        "X-GNOME-Autostart-enabled=$gnome_value" \
        > "$tmp_file"

    if [[ -f "$FCITX_AUTOSTART_FILE" ]] && ! backup_existing_file "$FCITX_AUTOSTART_FILE"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    if ! replace_file_from_tmp "$tmp_file" "$FCITX_AUTOSTART_FILE"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    chmod 0644 "$FCITX_AUTOSTART_FILE" || return 1
    log_message "${status_label} Fcitx5 开机启动：$FCITX_AUTOSTART_FILE"
    return 0
}

current_default_im() {
    local value=""
    if [[ -f "$FCITX_PROFILE" ]]; then
        value=$(awk -F= '
            BEGIN { in_group=0 }
            /^\[Groups\/0\][[:space:]]*$/ { in_group=1; next }
            /^\[/ { if (in_group) exit; in_group=0 }
            in_group && $1 ~ /^[[:space:]]*DefaultIM[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }
        ' "$FCITX_PROFILE")
    fi
    printf '%s' "${value:-未设置}"
}

current_schema_id() {
    local value=""
    if [[ -f "$RIME_DIR/user.yaml" ]]; then
        value=$(awk -F: '/^[[:space:]]+previously_selected_schema[[:space:]]*:/{gsub(/[[:space:]]+/, "", $2); gsub(/['"'"']/, "", $2); print $2; exit}' "$RIME_DIR/user.yaml")
    fi
    printf '%s' "${value:-未记录}"
}

current_schema_name() {
    local id="$1"
    local i
    load_schemas
    for i in "${!SCHEMA_IDS[@]}"; do
        if [[ "${SCHEMA_IDS[$i]}" == "$id" ]]; then
            printf '%s' "${SCHEMA_NAMES[$i]}"
            return 0
        fi
    done
    printf '%s' "$id"
}

fcitx_state() {
    if ! command -v fcitx5-remote >/dev/null 2>&1; then
        printf '未安装 fcitx5-remote'
        return 0
    fi
    case "$(fcitx5-remote 2>/dev/null || printf '3')" in
        2) printf '运行中且已激活' ;;
        1) printf '运行中但未激活' ;;
        0) printf 'Fcitx5 未运行' ;;
        *) printf '状态未知' ;;
    esac
}

ini_get() {
    local file="$1"
    local section="$2"
    local key="$3"
    local default_value="${4:-}"
    local value=""

    if [[ -f "$file" ]]; then
        value=$(awk -F= -v target_section="$section" -v target_key="$key" '
            function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
            BEGIN { in_section=0 }
            /^\[[^]]+\][[:space:]]*$/ {
                header=$0
                sub(/^\[/, "", header); sub(/\][[:space:]]*$/, "", header)
                in_section=(header == target_section)
                next
            }
            in_section && $1 ~ "^[[:space:]]*" target_key "[[:space:]]*$" { print trim(substr($0, index($0, "=") + 1)); exit }
        ' "$file")
    fi
    printf '%s' "${value:-$default_value}"
}

root_get() {
    local file="$1"
    local key="$2"
    local default_value="${3:-}"
    local value=""
    if [[ -f "$file" ]]; then
        value=$(awk -F= -v target_key="$key" '$1 ~ "^[[:space:]]*" target_key "[[:space:]]*$" { sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit }' "$file")
    fi
    printf '%s' "${value:-$default_value}"
}

backup_existing_file() {
    local file="$1"
    local base

    LAST_BACKUP=""
    [[ -f "$file" ]] || return 0
    mkdir -p "$BACKUP_DIR" || return 1
    base=$(basename "$file")
    LAST_BACKUP="$BACKUP_DIR/${base}.bak.$(date +%Y%m%d_%H%M%S%N)"
    if ! cp -p -- "$file" "$LAST_BACKUP"; then
        LAST_BACKUP=""
        return 1
    fi
    return 0
}

replace_file_from_tmp() {
    local tmp_file="$1"
    local target_file="$2"
    local parent

    parent=$(dirname "$target_file")
    mkdir -p "$parent" || return 1
    if ! mv -f -- "$tmp_file" "$target_file"; then
        return 1
    fi
    return 0
}

set_ini_key() {
    local file="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local tmp_file

    mkdir -p "$(dirname "$file")" || return 1
    tmp_file=$(mktemp "$(dirname "$file")/.fcitx5-config.XXXXXX") || return 1

    if [[ -f "$file" ]]; then
        awk -v target_section="$section" -v target_key="$key" -v target_value="$value" '
            BEGIN { in_section=0; found_section=0; found_key=0 }
            /^\[[^]]+\][[:space:]]*$/ {
                header=$0
                sub(/^\[/, "", header); sub(/\][[:space:]]*$/, "", header)
                if (in_section && !found_key) { print target_key "=" target_value; found_key=1 }
                in_section=(header == target_section)
                if (in_section) found_section=1
            }
            {
                if (in_section && $0 ~ "^[[:space:]]*" target_key "[[:space:]]*=") {
                    print target_key "=" target_value
                    found_key=1
                } else {
                    print
                }
            }
            END {
                if (in_section && !found_key) print target_key "=" target_value
                if (!found_section) { print ""; print "[" target_section "]"; print target_key "=" target_value }
            }
        ' "$file" > "$tmp_file"
    else
        awk -v target_section="$section" -v target_key="$key" -v target_value="$value" 'BEGIN { print "[" target_section "]"; print target_key "=" target_value }' > "$tmp_file"
    fi

    if [[ -f "$file" ]] && ! backup_existing_file "$file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    if ! replace_file_from_tmp "$tmp_file" "$file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    log_message "更新 INI：$file [$section] $key=$value"
    return 0
}

set_root_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp_file

    mkdir -p "$(dirname "$file")" || return 1
    tmp_file=$(mktemp "$(dirname "$file")/.fcitx5-config.XXXXXX") || return 1
    if [[ -f "$file" ]]; then
        awk -v target_key="$key" -v target_value="$value" '
            BEGIN { found=0 }
            $0 ~ "^[[:space:]]*" target_key "[[:space:]]*=" { print target_key "=" target_value; found=1; next }
            { print }
            END { if (!found) print target_key "=" target_value }
        ' "$file" > "$tmp_file"
    else
        printf '%s=%s\n' "$key" "$value" > "$tmp_file"
    fi
    if [[ -f "$file" ]] && ! backup_existing_file "$file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    if ! replace_file_from_tmp "$tmp_file" "$file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    log_message "更新根 INI：$file $key=$value"
    return 0
}

set_yaml_var() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp_file

    mkdir -p "$(dirname "$file")" || return 1
    tmp_file=$(mktemp "$(dirname "$file")/.fcitx5-config.XXXXXX") || return 1
    if [[ -f "$file" ]]; then
        awk -v target_key="$key" -v target_value="$value" '
            BEGIN { found=0 }
            $0 ~ "^[[:space:]]+" target_key "[[:space:]]*:" { print "  " target_key ": " target_value; found=1; next }
            { print }
            END { if (!found) print "  " target_key ": " target_value }
        ' "$file" > "$tmp_file"
    else
        printf 'var:\n  %s: %s\n' "$key" "$value" > "$tmp_file"
    fi
    if [[ -f "$file" ]] && ! backup_existing_file "$file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    if ! replace_file_from_tmp "$tmp_file" "$file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    log_message "更新 YAML：$file $key=$value"
    return 0
}

reload_fcitx() {
    if ! command -v fcitx5-remote >/dev/null 2>&1; then
        return 1
    fi
    fcitx5-remote -r >/dev/null 2>&1 || return 1
    log_message "重新加载 Fcitx5 配置"
    return 0
}

restart_fcitx() {
    local i
    local pid
    local remaining_pids

    if command -v fcitx5-remote >/dev/null 2>&1; then
        fcitx5-remote -e >/dev/null 2>&1 || true
        for i in $(seq 1 40); do
            pgrep -u "$UID" -x fcitx5 >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi
    if pgrep -u "$UID" -x fcitx5 >/dev/null 2>&1; then
        remaining_pids=$(pgrep -u "$UID" -x fcitx5 || true)
        for pid in $remaining_pids; do
            kill "$pid" >/dev/null 2>&1 || true
        done
        for i in $(seq 1 40); do
            pgrep -u "$UID" -x fcitx5 >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi
    if ! command -v fcitx5 >/dev/null 2>&1; then
        return 1
    fi
    nohup fcitx5 -d >/dev/null 2>&1 </dev/null &
    for i in $(seq 1 30); do
        pgrep -u "$UID" -x fcitx5 >/dev/null 2>&1 && break
        sleep 0.1
    done
    if ! pgrep -u "$UID" -x fcitx5 >/dev/null 2>&1; then
        log_message "重启 Fcitx5 失败：进程未能启动"
        return 1
    fi
    log_message "重启 Fcitx5"
    return 0
}

rime_deploy() {
    local deployer
    local log_file
    local rc

    LAST_LOG=""
    if ! command -v rime_deployer >/dev/null 2>&1; then
        log_message "未找到 rime_deployer，跳过 Rime 部署"
        return 1
    fi
    mkdir -p "$LOG_DIR" "$RIME_BUILD_DIR" || return 1
    deployer=$(command -v rime_deployer)
    log_file="$LOG_DIR/rime-deploy-$(date +%Y%m%d_%H%M%S%N).log"
    LAST_LOG="$log_file"

    if [[ -d "$RIME_SHARED_DIR" ]]; then
        timeout 120 "$deployer" --build "$RIME_DIR" "$RIME_SHARED_DIR" "$RIME_BUILD_DIR" >"$log_file" 2>&1
    else
        timeout 120 "$deployer" --build "$RIME_DIR" >"$log_file" 2>&1
    fi
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        log_message "Rime 部署失败，返回码 $rc，日志 $log_file"
        return "$rc"
    fi
    log_message "Rime 部署成功，日志 $log_file"
    return 0
}

apply_rime_changes() {
    local deploy_ok=0
    local restart_ok=0

    rime_deploy && deploy_ok=1
    restart_fcitx && restart_ok=1
    if [[ "$deploy_ok" -eq 1 && "$restart_ok" -eq 1 ]]; then
        return 0
    fi
    return 1
}

load_schemas() {
    local file
    local id
    local name

    SCHEMA_IDS=()
    SCHEMA_NAMES=()
    [[ -d "$RIME_DIR" ]] || return 0
    while IFS= read -r file; do
        id=$(basename "$file" .schema.yaml)
        name=$(awk -F: '/^[[:space:]]+name[[:space:]]*:/{sub(/^[[:space:]]+/, "", $2); gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", $2); print $2; exit}' "$file")
        SCHEMA_IDS+=("$id")
        SCHEMA_NAMES+=("${name:-$id}")
    done < <(find "$RIME_DIR" -maxdepth 1 -type f -name '*.schema.yaml' -print | sort)
}

load_profile_input_methods() {
    PROFILE_IM_NAMES=()
    PROFILE_IM_LAYOUTS=()
    [[ -f "$FCITX_PROFILE" ]] || return 0

    while IFS="$FIELD_SEPARATOR" read -r name layout; do
        [[ -n "$name" ]] || continue
        PROFILE_IM_NAMES+=("$name")
        PROFILE_IM_LAYOUTS+=("$layout")
    done < <(awk -F= '
        function flush() { if (name != "") print name "\t" layout }
        /^\[Groups\/0\/Items\/[0-9]+\][[:space:]]*$/ { flush(); name=""; layout=""; in_item=1; next }
        /^\[/ { if (in_item) flush(); in_item=0 }
        in_item && $1 == "Name" { name=$2 }
        in_item && $1 == "Layout" { layout=$2 }
        END { if (in_item) flush() }
    ' "$FCITX_PROFILE")
}

health_report() {
    local state
    local group
    local schema_id
    local schema_name
    local phrase_count=0
    local db_count=0
    local theme
    local line

    state=$(fcitx_state)
    group=$(fcitx5-remote -q 2>/dev/null || printf '无法读取')
    schema_id=$(current_schema_id)
    schema_name=$(current_schema_name "$schema_id")
    theme=$(root_get "$FCITX_CONF_DIR/classicui.conf" Theme "默认")
    [[ -f "$RIME_PHRASE_FILE" ]] && phrase_count=$(awk -F '\t' 'NF >= 2 && $1 !~ /^[[:space:]]*#/ {n++} END {print n+0}' "$RIME_PHRASE_FILE")
    [[ -d "$RIME_DIR" ]] && db_count=$(find "$RIME_DIR" -maxdepth 1 -type d -name '*.userdb' | wc -l)

    line="Fcitx5 状态：$state\n开机自启动：$(fcitx_autostart_status)\n当前分组：$group\n默认输入法：$(current_default_im)\n\n"
    line+="Rime 当前方案：$schema_name ($schema_id)\nRime 个性短语：$phrase_count 条\nRime 用户词库：$db_count 个\n经典界面主题：$theme\n\n"
    line+="配置目录：$FCITX_DIR\nRime 目录：$RIME_DIR\n备份目录：$BACKUP_DIR\n\n"
    line+="zenity：$(command_status zenity)\nfcitx5：$(command_status fcitx5)\nfcitx5-remote：$(command_status fcitx5-remote)\nrime_deployer：$(command_status rime_deployer)\nrime_dict_manager：$(command_status rime_dict_manager)\n\n"
    line+="桌面：${XDG_CURRENT_DESKTOP:-未设置}\n会话：${XDG_SESSION_TYPE:-未设置}\n显示：${DISPLAY:-未设置}\nWayland 显示：${WAYLAND_DISPLAY:-未设置}"
    printf '%b' "$line"
}

show_dashboard() {
    show_text "状态总览" "$(health_report)"
}

autostart_settings() {
    local current_value="False"
    local result
    local choice

    fcitx_autostart_enabled && current_value="True"
    result=$(zenity --forms --title="$APP_TITLE - 开机启动" --width=700 --no-markup \
        --text="控制登录桌面后是否自动启动 Fcitx5 输入法服务。" --separator='|' --show-header \
        --add-combo="登录后自动启动 Fcitx5" --combo-values="$(bool_choices "$current_value")" \
        --ok-label="保存" --cancel-label="取消" 2>/dev/null) || return 0

    IFS='|' read -r choice _ <<< "$result"
    if set_fcitx_autostart "$(bool_config_value "$choice")"; then
        info_dialog "Fcitx5 开机启动已$( [[ "$(bool_config_value "$choice")" == "True" ]] && printf '开启' || printf '关闭' )。\n下次登录桌面时生效。"
    else
        error_dialog "保存 Fcitx5 开机启动设置失败。"
        return 1
    fi
}

input_method_manager() {
    local result
    local rc
    local selected_name=""
    local selected_layout=""
    local action=""
    local action_rc
    local i
    local -a args

    while true; do
        load_profile_input_methods
        args=(
            --list
            --title="$APP_TITLE - 输入法管理"
            --width=800
            --height=520
            --text="这里管理当前 Fcitx5 分组中的输入法。添加或移除输入法需要安装/卸载系统组件，可通过 Fcitx5 配置工具完成。"
            --print-column=ALL
            --separator="$FIELD_SEPARATOR"
            --ok-label="选择"
            --extra-button="打开 Fcitx5 配置工具"
            --extra-button="刷新"
            --cancel-label="返回"
            --column="输入法"
            --column="键盘布局"
            --column="默认"
        )
        for i in "${!PROFILE_IM_NAMES[@]}"; do
            local mark=""
            [[ "${PROFILE_IM_NAMES[$i]}" == "$(current_default_im)" ]] && mark="是"
            args+=("${PROFILE_IM_NAMES[$i]}" "${PROFILE_IM_LAYOUTS[$i]}" "$mark")
        done

        result=$(zenity "${args[@]}" 2>/dev/null)
        rc=$?
        case "$result" in
            "打开 Fcitx5 配置工具")
                if command -v fcitx5-configtool >/dev/null 2>&1; then
                    fcitx5-configtool >/dev/null 2>&1 &
                else
                    error_dialog "未找到 fcitx5-configtool。"
                fi
                continue
                ;;
            刷新)
                continue
                ;;
        esac
        [[ "$rc" -eq 0 && -n "$result" ]] || return 0

        IFS="$FIELD_SEPARATOR" read -r selected_name selected_layout _ <<< "$result"
        action=$(zenity --question --title="$APP_TITLE" --width=620 --no-markup \
            --text="输入法：$selected_name\n键盘布局：${selected_layout:-默认}\n\n选择要执行的操作。" \
            --ok-label="切换当前" --extra-button="设为默认" \
            --extra-button="打开配置工具" --cancel-label="取消" 2>/dev/null)
        action_rc=$?

        if [[ "$action" == "设为默认" ]]; then
            if set_ini_key "$FCITX_PROFILE" "Groups/0" "DefaultIM" "$selected_name"; then
                if restart_fcitx; then
                    info_dialog "已将“$selected_name”设为默认输入法，并已自动重启 Fcitx5。"
                else
                    error_dialog "默认输入法已保存，但 Fcitx5 自动重启失败。"
                fi
            else
                error_dialog "设置默认输入法失败。"
            fi
        elif [[ "$action" == "打开配置工具" ]]; then
            if command -v fcitx5-configtool >/dev/null 2>&1; then
                fcitx5-configtool >/dev/null 2>&1 &
            else
                error_dialog "未找到 fcitx5-configtool。"
            fi
        elif [[ "$action_rc" -eq 0 ]]; then
            if fcitx5-remote -s "$selected_name" >/dev/null 2>&1; then
                info_dialog "已切换到：$selected_name"
            else
                error_dialog "切换失败。请确认 Fcitx5 正在运行。"
            fi
        fi
    done
}

basic_settings() {
    local page_size
    local active_default
    local preedit_enabled
    local show_info
    local share_state
    local result
    local new_page
    local new_active
    local new_preedit
    local new_info
    local new_share

    page_size=$(ini_get "$FCITX_CONFIG" Behavior DefaultPageSize 5)
    active_default=$(ini_get "$FCITX_CONFIG" Behavior ActiveByDefault True)
    preedit_enabled=$(ini_get "$FCITX_CONFIG" Behavior PreeditEnabledByDefault True)
    show_info=$(ini_get "$FCITX_CONFIG" Behavior ShowInputMethodInformation True)
    share_state=$(ini_get "$FCITX_CONFIG" Behavior ShareInputState No)

    result=$(zenity --forms --title="$APP_TITLE - 基本设置" --width=760 --no-markup \
        --text="设置 Fcitx5 的通用行为。当前值已默认选中。" --separator='|' --show-header \
        --add-combo="候选词数量" --combo-values="$(number_choices "$page_size" 1 10)" \
        --add-combo="启动后默认启用输入法" --combo-values="$(bool_choices "$active_default")" \
        --add-combo="默认显示预编辑文本" --combo-values="$(bool_choices "$preedit_enabled")" \
        --add-combo="切换时显示输入法提示" --combo-values="$(bool_choices "$show_info")" \
        --add-combo="输入状态共享" --combo-values="$(share_state_choices "$share_state")" \
        --ok-label="保存" --cancel-label="取消" 2>/dev/null) || return 0

    IFS='|' read -r new_page new_active new_preedit new_info new_share _ <<< "$result"
    [[ "$new_page" =~ ^[1-9][0-9]*$ && "$new_page" -le 10 ]] || new_page="$page_size"
    new_active=$(bool_config_value "$new_active")
    new_preedit=$(bool_config_value "$new_preedit")
    new_info=$(bool_config_value "$new_info")
    new_share=$(share_state_config_value "$new_share")

    if ! set_ini_key "$FCITX_CONFIG" Behavior DefaultPageSize "$new_page" \
        || ! set_ini_key "$FCITX_CONFIG" Behavior ActiveByDefault "$new_active" \
        || ! set_ini_key "$FCITX_CONFIG" Behavior PreeditEnabledByDefault "$new_preedit" \
        || ! set_ini_key "$FCITX_CONFIG" Behavior ShowInputMethodInformation "$new_info" \
        || ! set_ini_key "$FCITX_CONFIG" Behavior ShareInputState "$new_share"; then
        error_dialog "保存基本设置失败。"
        return 1
    fi
    if restart_fcitx; then
        info_dialog "基本设置已保存，并已自动重启 Fcitx5。"
    else
        error_dialog "基本设置已保存，但 Fcitx5 自动重启失败。"
    fi
}

punctuation_settings() {
    local enabled
    local after_letter
    local paired
    local result
    local new_enabled
    local new_after_letter
    local new_paired

    enabled=$(root_get "$FCITX_CONF_DIR/punctuation.conf" Enabled True)
    after_letter=$(root_get "$FCITX_CONF_DIR/punctuation.conf" HalfWidthPuncAfterLetterOrNumber True)
    paired=$(root_get "$FCITX_CONF_DIR/punctuation.conf" TypePairedPunctuationsTogether False)

    result=$(zenity --forms --title="$APP_TITLE - 标点设置" --width=760 --no-markup \
        --text="设置标点引擎的行为。当前值已默认选中。" --separator='|' --show-header \
        --add-combo="启用标点引擎" --combo-values="$(bool_choices "$enabled")" \
        --add-combo="字母/数字后使用半角标点" --combo-values="$(bool_choices "$after_letter")" \
        --add-combo="自动输入成对标点" --combo-values="$(bool_choices "$paired")" \
        --ok-label="保存" --cancel-label="取消" 2>/dev/null) || return 0
    IFS='|' read -r new_enabled new_after_letter new_paired _ <<< "$result"
    new_enabled=$(bool_config_value "$new_enabled")
    new_after_letter=$(bool_config_value "$new_after_letter")
    new_paired=$(bool_config_value "$new_paired")

    if ! set_root_key "$FCITX_CONF_DIR/punctuation.conf" Enabled "$new_enabled" \
        || ! set_root_key "$FCITX_CONF_DIR/punctuation.conf" HalfWidthPuncAfterLetterOrNumber "$new_after_letter" \
        || ! set_root_key "$FCITX_CONF_DIR/punctuation.conf" TypePairedPunctuationsTogether "$new_paired"; then
        error_dialog "保存标点设置失败。"
        return 1
    fi
    if restart_fcitx; then
        info_dialog "标点设置已保存，并已自动重启 Fcitx5。"
    else
        error_dialog "标点设置已保存，但 Fcitx5 自动重启失败。"
    fi
}

rime_settings() {
    local preedit
    local cursor
    local result
    local new_preedit
    local new_cursor
    local schema_id
    local schema_name

    if [[ ! -d "$RIME_DIR" ]]; then
        error_dialog "没有找到 Rime 用户目录：\n$RIME_DIR"
        return 1
    fi

    preedit=$(root_get "$FCITX_CONF_DIR/rime.conf" PreeditInApplication False)
    cursor=$(root_get "$FCITX_CONF_DIR/rime.conf" PreeditCursorPositionAtBeginning True)
    result=$(zenity --forms --title="$APP_TITLE - Rime 设置" --width=760 --no-markup \
        --text="这里设置 Fcitx5-Rime 的预编辑显示方式。方案切换请进入“Rime 方案”。" \
        --separator='|' --show-header \
        --add-combo="在应用内显示预编辑文本" --combo-values="$(bool_choices "$preedit")" \
        --add-combo="预编辑光标固定在开头" --combo-values="$(bool_choices "$cursor")" \
        --ok-label="保存" --cancel-label="取消" 2>/dev/null) || return 0
    IFS='|' read -r new_preedit new_cursor _ <<< "$result"
    new_preedit=$(bool_config_value "$new_preedit")
    new_cursor=$(bool_config_value "$new_cursor")

    if ! set_root_key "$FCITX_CONF_DIR/rime.conf" PreeditInApplication "$new_preedit" \
        || ! set_root_key "$FCITX_CONF_DIR/rime.conf" PreeditCursorPositionAtBeginning "$new_cursor"; then
        error_dialog "保存 Rime 设置失败。"
        return 1
    fi
    if restart_fcitx; then
        info_dialog "Rime 设置已保存，并已自动重启 Fcitx5。"
    else
        error_dialog "Rime 设置已保存，但 Fcitx5 自动重启失败。"
    fi
}

set_rime_schema() {
    local schema_id="$1"
    local schema_file="$RIME_DIR/${schema_id}.schema.yaml"

    if [[ ! -f "$schema_file" ]]; then
        error_dialog "没有找到方案文件：\n$schema_file"
        return 1
    fi
    if [[ -f "$RIME_DIR/user.yaml" ]] && ! backup_existing_file "$RIME_DIR/user.yaml"; then
        error_dialog "无法备份 Rime user.yaml，已取消切换。"
        return 1
    fi

    if command -v rime_deployer >/dev/null 2>&1; then
        (cd "$RIME_DIR" && rime_deployer --set-active-schema "$schema_id") >/dev/null 2>&1 || true
    fi
    if ! set_yaml_var "$RIME_DIR/user.yaml" previously_selected_schema "$schema_id"; then
        error_dialog "写入当前 Rime 方案失败。"
        return 1
    fi
    if ! restart_fcitx; then
        error_dialog "方案已写入，但重启 Fcitx5 失败，请手动重启。"
        return 1
    fi
    schema_name=$(current_schema_name "$schema_id")
    info_dialog "已切换 Rime 方案：$schema_name\n\n方案 ID：$schema_id"
    return 0
}

rime_schema_manager() {
    local result
    local rc
    local selected_id=""
    local selected_name=""
    local action
    local action_rc
    local i
    local -a args

    while true; do
        load_schemas
        if [[ "${#SCHEMA_IDS[@]}" -eq 0 ]]; then
            error_dialog "没有找到 Rime 方案文件。"
            return 1
        fi
        args=(
            --list
            --title="$APP_TITLE - Rime 方案"
            --width=850
            --height=620
            --text="选择一个方案后点击“选择”，再执行切换或打开方案文件。当前记录方案：$(current_schema_id)"
            --print-column=ALL
            --separator="$FIELD_SEPARATOR"
            --ok-label="选择"
            --extra-button="重建词库"
            --extra-button="刷新"
            --cancel-label="返回"
            --column="方案 ID"
            --column="名称"
            --column="状态"
        )
        for i in "${!SCHEMA_IDS[@]}"; do
            local mark=""
            [[ "${SCHEMA_IDS[$i]}" == "$(current_schema_id)" ]] && mark="当前"
            args+=("${SCHEMA_IDS[$i]}" "${SCHEMA_NAMES[$i]}" "$mark")
        done
        result=$(zenity "${args[@]}" 2>/dev/null)
        rc=$?
        case "$result" in
            重建词库)
                if rime_deploy && restart_fcitx; then
                    info_dialog "Rime 词库已重建，并重新启动 Fcitx5。"
                else
                    error_dialog "Rime 词库重建失败。\n日志：${LAST_LOG:-未生成}"
                fi
                continue
                ;;
            刷新)
                continue
                ;;
        esac
        [[ "$rc" -eq 0 && -n "$result" ]] || return 0
        IFS="$FIELD_SEPARATOR" read -r selected_id selected_name _ <<< "$result"
        action=$(zenity --question --title="$APP_TITLE" --width=640 --no-markup \
            --text="方案：$selected_name\nID：$selected_id\n\n选择操作。" \
            --ok-label="切换方案" --extra-button="打开方案文件" --cancel-label="取消" 2>/dev/null)
        action_rc=$?
        if [[ "$action" == "打开方案文件" ]]; then
            open_path "$RIME_DIR/$selected_id.schema.yaml" || true
        elif [[ "$action_rc" -eq 0 ]]; then
            set_rime_schema "$selected_id"
        fi
    done
}

native_pinyin_settings() {
    local pinyin_file="$FCITX_CONF_DIR/pinyin.conf"
    local page_size
    local spell
    local emoji
    local cloud
    local quickphrase
    local result
    local new_page
    local new_spell
    local new_emoji
    local new_cloud
    local new_quickphrase

    if [[ ! -f "$pinyin_file" ]]; then
        error_dialog "当前没有安装 Fcitx5 原生拼音配置文件。当前默认输入法是 Rime。"
        return 1
    fi
    page_size=$(root_get "$pinyin_file" PageSize 7)
    spell=$(root_get "$pinyin_file" SpellEnabled True)
    emoji=$(root_get "$pinyin_file" EmojiEnabled True)
    cloud=$(root_get "$pinyin_file" CloudPinyinEnabled False)
    quickphrase=$(root_get "$pinyin_file" VAsQuickphrase True)
    result=$(zenity --forms --title="$APP_TITLE - 原生拼音设置" --width=760 --no-markup \
        --text="这些选项只对 Fcitx5 原生拼音生效；当前默认输入法是 Rime。" --separator='|' --show-header \
        --add-combo="候选词数量" --combo-values="$(number_choices "$page_size" 1 10)" \
        --add-combo="拼写检查" --combo-values="$(bool_choices "$spell")" \
        --add-combo="Emoji" --combo-values="$(bool_choices "$emoji")" \
        --add-combo="云拼音" --combo-values="$(bool_choices "$cloud")" \
        --add-combo="V 键快速输入" --combo-values="$(bool_choices "$quickphrase")" \
        --ok-label="保存" --cancel-label="取消" 2>/dev/null) || return 0
    IFS='|' read -r new_page new_spell new_emoji new_cloud new_quickphrase _ <<< "$result"
    [[ "$new_page" =~ ^[1-9][0-9]*$ && "$new_page" -le 10 ]] || new_page="$page_size"
    new_spell=$(bool_config_value "$new_spell")
    new_emoji=$(bool_config_value "$new_emoji")
    new_cloud=$(bool_config_value "$new_cloud")
    new_quickphrase=$(bool_config_value "$new_quickphrase")

    if ! set_root_key "$pinyin_file" PageSize "$new_page" \
        || ! set_root_key "$pinyin_file" SpellEnabled "$new_spell" \
        || ! set_root_key "$pinyin_file" EmojiEnabled "$new_emoji" \
        || ! set_root_key "$pinyin_file" CloudPinyinEnabled "$new_cloud" \
        || ! set_root_key "$pinyin_file" VAsQuickphrase "$new_quickphrase"; then
        error_dialog "保存原生拼音设置失败。"
        return 1
    fi
    if restart_fcitx; then
        info_dialog "原生拼音设置已保存，并已自动重启 Fcitx5。"
    else
        error_dialog "原生拼音设置已保存，但 Fcitx5 自动重启失败。"
    fi
}

shortcut_settings() {
    local trigger
    local forward
    local backward
    local punctuation
    local traditional
    local result
    local new_trigger
    local new_forward
    local new_backward
    local new_punctuation
    local new_traditional

    trigger=$(ini_get "$FCITX_CONFIG" Hotkey/TriggerKeys 0 'Control+space')
    forward=$(ini_get "$FCITX_CONFIG" Hotkey/EnumerateForwardKeys 0 'Control+Shift_L')
    backward=$(ini_get "$FCITX_CONFIG" Hotkey/EnumerateBackwardKeys 0 'Control+Shift_R')
    punctuation=$(ini_get "$FCITX_CONF_DIR/punctuation.conf" Hotkey 0 'Control+period')
    traditional=$(ini_get "$FCITX_CONF_DIR/chttrans.conf" Hotkey 0 'Control+Shift+F')
    result=$(zenity --forms --title="$APP_TITLE - 快捷键" --width=800 --no-markup \
        --text="快捷键格式示例：Control+space、Control+Shift_L、Alt+grave。留空表示取消该快捷键。" \
        --separator='|' --show-header \
        --add-entry="启用/停用输入法" --add-entry="切换下一个输入法" --add-entry="切换上一个输入法" \
        --add-entry="标点输入开关" --add-entry="简繁转换" \
        --ok-label="保存" --cancel-label="取消" 2>/dev/null) || return 0
    IFS='|' read -r new_trigger new_forward new_backward new_punctuation new_traditional _ <<< "$result"
    [[ -n "$new_trigger" ]] || new_trigger="$trigger"
    [[ -n "$new_forward" ]] || new_forward="$forward"
    [[ -n "$new_backward" ]] || new_backward="$backward"
    [[ -n "$new_punctuation" ]] || new_punctuation="$punctuation"
    [[ -n "$new_traditional" ]] || new_traditional="$traditional"

    if ! set_ini_key "$FCITX_CONFIG" Hotkey/TriggerKeys 0 "$new_trigger" \
        || ! set_ini_key "$FCITX_CONFIG" Hotkey/EnumerateForwardKeys 0 "$new_forward" \
        || ! set_ini_key "$FCITX_CONFIG" Hotkey/EnumerateBackwardKeys 0 "$new_backward" \
        || ! set_ini_key "$FCITX_CONF_DIR/punctuation.conf" Hotkey 0 "$new_punctuation" \
        || ! set_ini_key "$FCITX_CONF_DIR/chttrans.conf" Hotkey 0 "$new_traditional"; then
        error_dialog "保存快捷键失败。"
        return 1
    fi
    if restart_fcitx; then
        info_dialog "快捷键已保存，并已自动重启 Fcitx5。"
    else
        error_dialog "快捷键已保存，但 Fcitx5 自动重启失败。"
    fi
}

theme_settings() {
    local current
    local result
    local selected_theme
    local theme_dir
    local -a themes=()
    local theme
    local -a args

    current=$(root_get "$FCITX_CONF_DIR/classicui.conf" Theme default)
    for theme_dir in "$DATA_HOME/fcitx5/themes"/* "$FCITX_DIR/themes"/* "/usr/share/fcitx5/themes"/*; do
        [[ -d "$theme_dir" ]] || continue
        theme=$(basename "$theme_dir")
        [[ " ${themes[*]} " == *" $theme "* ]] || themes+=("$theme")
    done
    if [[ "${#themes[@]}" -eq 0 ]]; then
        error_dialog "没有找到 Fcitx5 主题目录。"
        return 1
    fi
    args=(
        --list --title="$APP_TITLE - 外观主题" --width=620 --height=520
        --text="当前主题：$current\n选择主题后点击“应用”。"
        --radiolist --print-column=2 --separator="$FIELD_SEPARATOR"
        --ok-label="应用" --cancel-label="返回" --column="使用" --column="主题"
    )
    for theme in "${themes[@]}"; do
        if [[ "$theme" == "$current" ]]; then
            args+=(TRUE "$theme")
        else
            args+=(FALSE "$theme")
        fi
    done
    result=$(zenity "${args[@]}" 2>/dev/null) || return 0
    selected_theme="$result"
    if [[ -z "$selected_theme" ]]; then
        return 0
    fi
    if set_root_key "$FCITX_CONF_DIR/classicui.conf" Theme "$selected_theme"; then
        if restart_fcitx; then
            info_dialog "主题已设置为：$selected_theme，并已自动重启 Fcitx5。"
        else
            error_dialog "主题已保存，但 Fcitx5 自动重启失败。"
        fi
    else
        error_dialog "保存主题失败。"
    fi
}

ensure_phrase_file() {
    if [[ -f "$RIME_PHRASE_FILE" ]]; then
        return 0
    fi
    mkdir -p "$RIME_DIR" || return 1
    {
        printf '%s\n' '# Rime table'
        printf '%s\n' '# coding: utf-8'
        printf '%s\n' '#@/db_name	custom_phrase.txt'
        printf '%s\n' '#@/db_type	tabledb'
        printf '%s\n' '#'
        printf '%s\n' '# 自定义短语：文本<TAB>快捷键<TAB>内部排序值'
    } > "$RIME_PHRASE_FILE"
}

convert_loaded_weights_to_positions() {
    local i
    local j
    local a
    local b
    local index_a
    local index_b
    local temp_index
    local code
    local seen
    local already_seen
    local rank
    local -a indices=()
    local -a processed_codes=()

    for i in "${!ENTRY_CODES[@]}"; do
        code="${ENTRY_CODES[$i]}"
        already_seen=0
        for seen in "${processed_codes[@]}"; do
            [[ "$seen" == "$code" ]] && already_seen=1
        done
        [[ "$already_seen" -eq 1 ]] && continue
        indices=()
        for j in "${!ENTRY_CODES[@]}"; do
            [[ "${ENTRY_CODES[$j]}" == "$code" ]] && indices+=("$j")
        done
        for ((a=0; a<${#indices[@]}; a++)); do
            for ((b=a+1; b<${#indices[@]}; b++)); do
                index_a="${indices[$a]}"
                index_b="${indices[$b]}"
                if (( ENTRY_POSITIONS[index_b] > ENTRY_POSITIONS[index_a] )); then
                    temp_index="${indices[$a]}"
                    indices[$a]="${indices[$b]}"
                    indices[$b]="$temp_index"
                fi
            done
        done
        rank=1
        for j in "${indices[@]}"; do
            ENTRY_POSITIONS[$j]="$rank"
            rank=$((rank + 1))
        done
        processed_codes+=("$code")
    done
}

normalize_code_positions() {
    local target_code="$1"
    local preferred_index="${2:--1}"
    local desired_position="${3:-1}"
    local i
    local a
    local b
    local index_a
    local index_b
    local temp_index
    local slot
    local cursor=0
    local max_position
    local -a indices=()

    for i in "${!ENTRY_CODES[@]}"; do
        if [[ "${ENTRY_CODES[$i]}" == "$target_code" && "$i" -ne "$preferred_index" ]]; then
            indices+=("$i")
        fi
    done
    for ((a=0; a<${#indices[@]}; a++)); do
        for ((b=a+1; b<${#indices[@]}; b++)); do
            index_a="${indices[$a]}"
            index_b="${indices[$b]}"
            if (( ENTRY_POSITIONS[index_b] < ENTRY_POSITIONS[index_a] )); then
                temp_index="${indices[$a]}"
                indices[$a]="${indices[$b]}"
                indices[$b]="$temp_index"
            fi
        done
    done

    if [[ "$preferred_index" -ge 0 && "${ENTRY_CODES[$preferred_index]:-}" == "$target_code" ]]; then
        max_position=$((${#indices[@]} + 1))
        (( desired_position < 1 )) && desired_position=1
        (( desired_position > max_position )) && desired_position="$max_position"
        for ((slot=1; slot<=max_position; slot++)); do
            if [[ "$slot" -eq "$desired_position" ]]; then
                ENTRY_POSITIONS[$preferred_index]="$slot"
            else
                ENTRY_POSITIONS[${indices[$cursor]}]="$slot"
                cursor=$((cursor + 1))
            fi
        done
    else
        slot=1
        for i in "${indices[@]}"; do
            ENTRY_POSITIONS[$i]="$slot"
            slot=$((slot + 1))
        done
    fi
}

normalize_all_phrase_positions() {
    local i
    local code
    local seen
    local already_seen
    local -a processed_codes=()

    for i in "${!ENTRY_CODES[@]}"; do
        code="${ENTRY_CODES[$i]}"
        already_seen=0
        for seen in "${processed_codes[@]}"; do
            [[ "$seen" == "$code" ]] && already_seen=1
        done
        [[ "$already_seen" -eq 1 ]] && continue
        normalize_code_positions "$code"
        processed_codes+=("$code")
    done
}

load_phrase_entries() {
    local text
    local code
    local position
    local ignored
    local i
    local -a filtered_codes=()
    local -a filtered_texts=()
    local -a filtered_positions=()

    ENTRY_CODES=()
    ENTRY_TEXTS=()
    ENTRY_POSITIONS=()
    [[ -f "$RIME_PHRASE_FILE" ]] || return 0
    while IFS="$FIELD_SEPARATOR" read -r text code position ignored; do
        [[ -n "$text" && -n "$code" ]] || continue
        [[ "$text" == \#* ]] && continue
        [[ "$position" =~ ^[0-9]+$ ]] || position=1
        position=$((10#$position))
        ENTRY_TEXTS+=("$text")
        ENTRY_CODES+=("$code")
        ENTRY_POSITIONS+=("$position")
    done < <(awk -F '\t' 'NF >= 2 && $1 !~ /^[[:space:]]*#/ {print $0}' "$RIME_PHRASE_FILE")
    convert_loaded_weights_to_positions
    if [[ -n "$PHRASE_FILTER" ]]; then
        for i in "${!ENTRY_CODES[@]}"; do
            if [[ "${ENTRY_TEXTS[$i]}" == *"$PHRASE_FILTER"* || "${ENTRY_CODES[$i]}" == *"$PHRASE_FILTER"* ]]; then
                filtered_codes+=("${ENTRY_CODES[$i]}")
                filtered_texts+=("${ENTRY_TEXTS[$i]}")
                filtered_positions+=("${ENTRY_POSITIONS[$i]}")
            fi
        done
        ENTRY_CODES=("${filtered_codes[@]}")
        ENTRY_TEXTS=("${filtered_texts[@]}")
        ENTRY_POSITIONS=("${filtered_positions[@]}")
    fi
}

validate_phrase() {
    local code="$1"
    local text="$2"
    local position="$3"
    local duplicate_index="${4:--1}"
    local i

    [[ -n "$code" && -n "$text" ]] || { error_dialog "快捷键和文本不能为空。"; return 1; }
    if [[ "$code" == *$'\t'* || "$code" == *$'\n'* || "$code" == *$'\r'* || "$text" == *$'\t'* || "$text" == *$'\n'* || "$text" == *$'\r'* ]]; then
        error_dialog "快捷键和文本不能包含 Tab 或换行。"
        return 1
    fi
    if [[ "$code" =~ [[:space:]] ]]; then
        error_dialog "快捷键不能包含空格。"
        return 1
    fi
    if [[ ! "$position" =~ ^[1-9][0-9]*$ ]]; then
        error_dialog "位置必须是大于 0 的整数；1 表示第一个候选。"
        return 1
    fi
    for i in "${!ENTRY_CODES[@]}"; do
        if [[ "$i" -ne "$duplicate_index" && "${ENTRY_CODES[$i]}" == "$code" && "${ENTRY_TEXTS[$i]}" == "$text" ]]; then
            error_dialog "已经存在相同的快捷键和文本。"
            return 1
        fi
    done
    return 0
}

collect_phrase() {
    local old_code="${1:-}"
    local old_text="${2:-}"
    local old_position="${3:-1}"

    FORM_CODE=$(ask_entry "快捷键（例如 adc）" "$old_code") || return 1
    FORM_TEXT=$(ask_entry "文本" "$old_text") || return 1
    FORM_POSITION=$(ask_entry "候选位置（1 表示该快捷键的第一个候选）" "$old_position") || return 1
    validate_phrase "$FORM_CODE" "$FORM_TEXT" "$FORM_POSITION" "${4:--1}"
}

save_phrase_entries() {
    local tmp_file
    local i
    local internal_weight

    ensure_phrase_file || return 1
    normalize_all_phrase_positions
    tmp_file=$(mktemp "$RIME_DIR/.custom_phrase.txt.tmp.XXXXXX") || return 1
    if ! awk -F '\t' '$0 ~ /^[[:space:]]*#/ || NF < 2 || $1 == "" || $2 == "" {print}' "$RIME_PHRASE_FILE" > "$tmp_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    for i in "${!ENTRY_CODES[@]}"; do
        if [[ "${ENTRY_POSITIONS[$i]}" -ge 100000 ]]; then
            internal_weight=1
        else
            internal_weight=$((100000 - ENTRY_POSITIONS[i]))
        fi
        printf '%s\t%s\t%s\n' "${ENTRY_TEXTS[$i]}" "${ENTRY_CODES[$i]}" "$internal_weight" >> "$tmp_file" || {
            rm -f -- "$tmp_file"
            return 1
        }
    done
    if ! backup_existing_file "$RIME_PHRASE_FILE"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    if ! replace_file_from_tmp "$tmp_file" "$RIME_PHRASE_FILE"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    log_message "保存 Rime 个性短语，共 ${#ENTRY_CODES[@]} 条"
    return 0
}

phrase_after_save() {
    if apply_rime_changes; then
        info_dialog "个性短语已保存，共 ${#ENTRY_CODES[@]} 条，并已重建 Rime / 重启 Fcitx5。\n\n配置文件：$RIME_PHRASE_FILE\n备份：$LAST_BACKUP"
    else
        error_dialog "个性短语文件已保存，但 Rime 重建或 Fcitx5 重启失败。\n\n请查看日志：${LAST_LOG:-$LOG_DIR/assistant.log}"
    fi
}

add_phrase() {
    local code text position
    local old_filter="$PHRASE_FILTER"
    PHRASE_FILTER=""
    load_phrase_entries
    PHRASE_FILTER="$old_filter"
    collect_phrase || return 0
    code="$FORM_CODE"; text="$FORM_TEXT"; position="$FORM_POSITION"
    validate_phrase "$code" "$text" "$position" || return 0
    ENTRY_CODES+=("$code")
    ENTRY_TEXTS+=("$text")
    ENTRY_POSITIONS+=("$position")
    normalize_code_positions "$code" "$((${#ENTRY_CODES[@]} - 1))" "$position"
    if save_phrase_entries; then phrase_after_save; else error_dialog "保存个性短语失败。"; fi
}

find_phrase_index() {
    local code="$1"
    local text="$2"
    local position="$3"
    local i
    for i in "${!ENTRY_CODES[@]}"; do
        if [[ "${ENTRY_CODES[$i]}" == "$code" && "${ENTRY_TEXTS[$i]}" == "$text" && "${ENTRY_POSITIONS[$i]}" == "$position" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

edit_phrase() {
    local index="$1"
    local old_code="${ENTRY_CODES[$index]}"
    local old_text="${ENTRY_TEXTS[$index]}"
    local old_position="${ENTRY_POSITIONS[$index]}"

    collect_phrase "$old_code" "$old_text" "$old_position" "$index" || return 0
    if ! validate_phrase "$FORM_CODE" "$FORM_TEXT" "$FORM_POSITION" "$index"; then
        return 0
    fi
    ENTRY_CODES[$index]="$FORM_CODE"
    ENTRY_TEXTS[$index]="$FORM_TEXT"
    ENTRY_POSITIONS[$index]="$FORM_POSITION"
    if [[ "$old_code" != "$FORM_CODE" ]]; then
        normalize_code_positions "$old_code"
    fi
    normalize_code_positions "$FORM_CODE" "$index" "$FORM_POSITION"
    if save_phrase_entries; then phrase_after_save; else error_dialog "保存个性短语失败。"; fi
}

delete_phrase() {
    local index="$1"
    local i
    local code="${ENTRY_CODES[$index]}"
    local text="${ENTRY_TEXTS[$index]}"
    local -a new_codes=()
    local -a new_texts=()
    local -a new_positions=()

    if ! zenity --question --title="$APP_TITLE" --width=620 --no-markup \
        --text="确定删除这条个性短语吗？\n\n快捷键：$code\n文本：$text" \
        --ok-label="删除" --cancel-label="取消" >/dev/null 2>&1; then
        return 0
    fi
    for i in "${!ENTRY_CODES[@]}"; do
        [[ "$i" -eq "$index" ]] && continue
        new_codes+=("${ENTRY_CODES[$i]}")
        new_texts+=("${ENTRY_TEXTS[$i]}")
        new_positions+=("${ENTRY_POSITIONS[$i]}")
    done
    ENTRY_CODES=("${new_codes[@]}")
    ENTRY_TEXTS=("${new_texts[@]}")
    ENTRY_POSITIONS=("${new_positions[@]}")
    if save_phrase_entries; then phrase_after_save; else error_dialog "保存个性短语失败。"; fi
}

iflytek_decode_phrase_file() {
    local source_file="$1"
    local target_file="$2"
    local first_bytes
    local encoding

    [[ -f "$source_file" ]] || return 1
    first_bytes=$(LC_ALL=C head -c 3 "$source_file" | od -An -tx1 | tr -d ' \n')
    case "$first_bytes" in
        fffe*) encoding="UTF-16LE" ;;
        feff*) encoding="UTF-16BE" ;;
        *) encoding="UTF-8" ;;
    esac
    iconv -f "$encoding" -t UTF-8 "$source_file" > "$target_file" || return 1
    LC_ALL=C sed -i -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$target_file"
    return 0
}

import_iflytek_phrases() {
    local import_file="${1:-}"
    local decoded_file
    local line
    local code
    local text
    local ifly_position
    local position_number
    local inside_section=0
    local section_found=0
    local recognized=0
    local imported=0
    local skipped=0
    local duplicate
    local i
    local old_filter="$PHRASE_FILTER"

    if [[ -z "$import_file" ]]; then
        import_file=$(zenity --file-selection --title="$APP_TITLE - 导入讯飞个性短语" \
            --filename="$DESKTOP_DIR/" \
            --file-filter='讯飞短语文件 (*.ini) | *.ini' \
            --file-filter='全部文件 (*) | *' 2>/dev/null) || return 0
    fi
    if [[ ! -f "$import_file" ]]; then
        error_dialog "导入失败：所选文件不存在。"
        return 1
    fi
    decoded_file=$(mktemp "$RIME_DIR/.iflytek-cphrase.XXXXXX") || {
        error_dialog "无法创建讯飞短语临时文件。"
        return 1
    }
    if ! iflytek_decode_phrase_file "$import_file" "$decoded_file"; then
        rm -f -- "$decoded_file"
        error_dialog "导入失败：无法识别该文件。请确认它是讯飞导出的 cphrase.ini。"
        return 1
    fi

    PHRASE_FILTER=""
    load_phrase_entries
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        [[ "$line" == \#* ]] && continue
        if [[ "$line" == \[*\] ]]; then
            inside_section=0
            if [[ "$line" == "[iFlyIME]" ]]; then
                inside_section=1
                section_found=1
            fi
            continue
        fi
        [[ "$inside_section" -eq 1 ]] || continue
        if [[ ! "$line" =~ ^([^=[:space:]]+)=[[:space:]]*([0-9]+),(.*)$ ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        code="${BASH_REMATCH[1]}"
        ifly_position="${BASH_REMATCH[2]}"
        text="${BASH_REMATCH[3]}"
        position_number=$((10#$ifly_position))
        if [[ -z "$text" || "$position_number" -lt 1 || "$code" == *,* || "$code" =~ [[:space:]] ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        recognized=$((recognized + 1))
        duplicate=0
        for i in "${!ENTRY_CODES[@]}"; do
            if [[ "${ENTRY_CODES[$i]}" == "$code" && "${ENTRY_TEXTS[$i]}" == "$text" ]]; then
                duplicate=1
                break
            fi
        done
        if [[ "$duplicate" -eq 1 ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        ENTRY_CODES+=("$code")
        ENTRY_TEXTS+=("$text")
        ENTRY_POSITIONS+=("$position_number")
        normalize_code_positions "$code" "$((${#ENTRY_CODES[@]} - 1))" "$position_number"
        imported=$((imported + 1))
    done < "$decoded_file"
    rm -f -- "$decoded_file"
    PHRASE_FILTER="$old_filter"

    if [[ "$section_found" -eq 0 ]]; then
        error_dialog "导入失败：未识别到讯飞 cphrase.ini 的 [iFlyIME] 标记。"
        return 1
    fi
    if [[ "$recognized" -eq 0 ]]; then
        error_dialog "导入失败：文件中没有识别到有效的个性短语。"
        return 1
    fi
    if [[ "$imported" -eq 0 ]]; then
        info_dialog "文件识别成功，但所有短语都已经存在，没有新增内容。"
        return 0
    fi
    if save_phrase_entries; then
        phrase_after_save
        info_dialog "讯飞短语导入完成：新增 $imported 条，跳过 $skipped 行。"
    else
        error_dialog "讯飞短语导入后的保存失败。"
    fi
}

export_iflytek_phrases() {
    local export_file
    local utf8_file
    local group_file
    local code
    local text
    local position
    local sequence
    local i
    local j
    local seq
    local exported=0
    local skipped=0
    local seen_code
    local already_seen
    local old_filter="$PHRASE_FILTER"
    local -a processed_codes=()

    PHRASE_FILTER=""
    load_phrase_entries
    PHRASE_FILTER="$old_filter"
    if [[ "${#ENTRY_CODES[@]}" -eq 0 ]]; then
        info_dialog "当前没有可导出的个性短语。"
        return 0
    fi
    export_file=$(zenity --file-selection --save --confirm-overwrite \
        --title="$APP_TITLE - 导出讯飞个性短语" --filename="$IFLYTEK_PHRASE_DEFAULT" \
        --file-filter='讯飞短语文件 (*.ini) | *.ini' \
        --file-filter='全部文件 (*) | *' 2>/dev/null) || return 0
    [[ "$export_file" == *.ini ]] || export_file="${export_file}.ini"
    mkdir -p "$(dirname "$export_file")" || return 1
    utf8_file=$(mktemp "$RIME_DIR/.iflytek-cphrase-export.XXXXXX") || {
        error_dialog "无法创建讯飞短语临时文件。"
        return 1
    }
    printf '[iFlyIME]\r\n' > "$utf8_file"

    for i in "${!ENTRY_CODES[@]}"; do
        code="${ENTRY_CODES[$i]}"
        already_seen=0
        for seen_code in "${processed_codes[@]}"; do
            [[ "$seen_code" == "$code" ]] && already_seen=1
        done
        [[ "$already_seen" -eq 1 ]] && continue
        if [[ "$code" == *,* || "$code" == *=* || "$code" =~ [[:space:]] ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        group_file=$(mktemp "$RIME_DIR/.iflytek-cphrase-group.XXXXXX") || {
            rm -f -- "$utf8_file"
            error_dialog "无法创建讯飞短语排序临时文件。"
            return 1
        }
        seq=0
        for j in "${!ENTRY_CODES[@]}"; do
            if [[ "${ENTRY_CODES[$j]}" == "$code" ]]; then
                printf '%s\t%09d\t%s\n' "${ENTRY_POSITIONS[$j]}" "$seq" "${ENTRY_TEXTS[$j]}" >> "$group_file"
                seq=$((seq + 1))
            fi
        done
        while IFS="$FIELD_SEPARATOR" read -r position sequence text; do
            printf '%s=%s,%s\r\n' "$code" "$position" "$text" >> "$utf8_file"
            exported=$((exported + 1))
        done < <(sort -t "$FIELD_SEPARATOR" -k1,1n -k2,2n "$group_file")
        rm -f -- "$group_file"
        processed_codes+=("$code")
    done

    if [[ "$exported" -eq 0 ]]; then
        rm -f -- "$utf8_file"
        info_dialog "没有找到可导出的讯飞格式短语。跳过 $skipped 条。"
        return 0
    fi
    if { printf '\xff\xfe'; iconv -f UTF-8 -t UTF-16LE "$utf8_file"; } > "$export_file"; then
        rm -f -- "$utf8_file"
        info_dialog "已导出 $exported 条讯飞个性短语：\n$export_file\n\n跳过不兼容快捷键 $skipped 条。"
    else
        rm -f -- "$utf8_file"
        error_dialog "讯飞短语导出失败：\n$export_file"
        return 1
    fi
}

phrase_manager() {
    local result
    local rc
    local selected_code=""
    local selected_text=""
    local selected_position=""
    local selected_index=""
    local action
    local action_rc
    local filter
    local active_filter
    local i
    local -a args

    ensure_phrase_file || { error_dialog "无法创建 Rime 个性短语文件。"; return 1; }
    while true; do
        load_phrase_entries
        args=(
            --list --title="$APP_TITLE - 个性短语"
            --width=1120 --height=680
            --text="当前方案：$(current_schema_name "$(current_schema_id)")\n位置 1 表示该快捷键的第一个候选。可导入或导出讯飞 cphrase.ini。${PHRASE_FILTER:+当前筛选：$PHRASE_FILTER}"
            --print-column=ALL --separator="$FIELD_SEPARATOR"
            --ok-label="操作" --extra-button="新增" --extra-button="搜索"
            --extra-button="清除搜索" --extra-button="导入 INI" --extra-button="导出 INI"
            --extra-button="刷新" --cancel-label="返回"
            --column="快捷键" --column="文本" --column="位置" --column="操作"
        )
        for i in "${!ENTRY_CODES[@]}"; do
            args+=("${ENTRY_CODES[$i]}" "${ENTRY_TEXTS[$i]}" "${ENTRY_POSITIONS[$i]}" "修改 / 删除")
        done
        result=$(zenity "${args[@]}" 2>/dev/null)
        rc=$?
        case "$result" in
            新增) add_phrase; continue ;;
            搜索)
                filter=$(ask_entry "输入要搜索的快捷键或文本（留空显示全部）" "$PHRASE_FILTER") || continue
                PHRASE_FILTER="$filter"
                continue
                ;;
            清除搜索) PHRASE_FILTER=""; continue ;;
            "导入 INI") import_iflytek_phrases; continue ;;
            "导出 INI") export_iflytek_phrases; continue ;;
            刷新) continue ;;
        esac
        [[ "$rc" -eq 0 && -n "$result" ]] || return 0
        IFS="$FIELD_SEPARATOR" read -r selected_code selected_text selected_position _ <<< "$result"
        active_filter="$PHRASE_FILTER"
        PHRASE_FILTER=""
        load_phrase_entries
        PHRASE_FILTER="$active_filter"
        if ! selected_index=$(find_phrase_index "$selected_code" "$selected_text" "$selected_position"); then
            error_dialog "找不到选中的短语，请刷新后重试。"
            continue
        fi
        action=$(zenity --question --title="$APP_TITLE" --width=640 --no-markup \
            --text="快捷键：$selected_code\n文本：$selected_text\n候选位置：$selected_position\n\n选择操作。" \
            --ok-label="修改" --extra-button="删除" --cancel-label="取消" 2>/dev/null)
        action_rc=$?
        if [[ "$action" == "删除" ]]; then
            delete_phrase "$selected_index"
        elif [[ "$action_rc" -eq 0 ]]; then
            edit_phrase "$selected_index"
        fi
    done
}

dictionary_names() {
    local tool
    tool=$(command -v rime_dict_manager 2>/dev/null || true)
    [[ -n "$tool" && -d "$RIME_DIR" ]] || return 0
    (cd "$RIME_DIR" && "$tool" -l 2>/dev/null) | awk 'NF {print $1}'
}

user_dictionary_manager() {
    local result
    local action
    local dict_name
    local import_file
    local export_file
    local list_text
    local tool

    tool=$(command -v rime_dict_manager 2>/dev/null || true)
    if [[ -z "$tool" ]]; then
        error_dialog "未找到 rime_dict_manager，无法导入/导出用户词库。"
        return 1
    fi
    list_text=$(dictionary_names)
    [[ -n "$list_text" ]] || list_text="未检测到可管理的用户词库。\n\n当前目录：$RIME_DIR"
    while true; do
        result=$(zenity --list --title="$APP_TITLE - 用户词库" --width=850 --height=560 \
            --text="Rime 用户词库管理\n\n$list_text" --column="操作" \
            --ok-label="执行" --extra-button="刷新列表" --extra-button="打开目录" \
            --cancel-label="返回" \
            "导出用户词库" "导入用户词库" "备份当前 Rime 配置" 2>/dev/null)
        case "$result" in
            "刷新列表") list_text=$(dictionary_names); continue ;;
            "打开目录") open_path "$RIME_DIR" || true; continue ;;
            "备份当前 Rime 配置") create_backup; continue ;;
        esac
        [[ -n "$result" ]] || return 0
        dict_name=$(zenity --entry --title="$APP_TITLE" --width=620 \
            --text="输入词库名称（例如 rime_frost）" --entry-text="rime_frost" \
            --ok-label="确定" --cancel-label="取消" 2>/dev/null) || continue
        [[ -n "$dict_name" ]] || continue
        if [[ "$result" == "导出用户词库" ]]; then
            export_file=$(zenity --file-selection --save --confirm-overwrite \
                --title="$APP_TITLE - 导出用户词库" --filename="$HOME/${dict_name}.userdb.txt" 2>/dev/null) || continue
            if (cd "$RIME_DIR" && "$tool" -e "$dict_name" "$export_file") >/tmp/fcitx5-dict-export.log 2>&1; then
                info_dialog "用户词库已导出：\n$export_file"
            else
                error_dialog "用户词库导出失败。\n\n词库可能正在被 Fcitx5 占用；可先重启 Fcitx5 后再试。\n日志：/tmp/fcitx5-dict-export.log"
            fi
        elif [[ "$result" == "导入用户词库" ]]; then
            import_file=$(zenity --file-selection --title="$APP_TITLE - 导入用户词库" 2>/dev/null) || continue
            if (cd "$RIME_DIR" && "$tool" -i "$dict_name" "$import_file") >/tmp/fcitx5-dict-import.log 2>&1; then
                if rime_deploy && restart_fcitx; then
                    info_dialog "用户词库已导入，并已重建 Rime。"
                else
                    error_dialog "用户词库已导入，但重建/重启失败。"
                fi
            else
                error_dialog "用户词库导入失败。\n日志：/tmp/fcitx5-dict-import.log"
            fi
        fi
    done
}

create_backup() {
    local archive
    local -a paths=()

    mkdir -p "$BACKUP_DIR" || { error_dialog "无法创建备份目录：\n$BACKUP_DIR"; return 1; }
    archive="$BACKUP_DIR/fcitx5-config-$(date +%Y%m%d_%H%M%S%N).tar.gz"
    [[ -d "$FCITX_DIR" ]] && paths+=(".config/fcitx5")
    [[ -d "$RIME_DIR" ]] && paths+=(".local/share/fcitx5/rime")
    [[ -d "$CONFIG_HOME/iflytek" ]] && paths+=(".config/iflytek")
    if [[ "${#paths[@]}" -eq 0 ]]; then
        error_dialog "没有找到可备份的 Fcitx5/Rime 配置。"
        return 1
    fi
    if tar -czf "$archive" -C "$HOME" "${paths[@]}" >/dev/null 2>&1; then
        LAST_BACKUP="$archive"
        if [[ "$QUIET_MODE" -eq 0 ]]; then
            info_dialog "备份完成：\n$archive"
        fi
        return 0
    fi
    error_dialog "创建备份失败。"
    return 1
}

archive_is_safe() {
    local archive="$1"
    local item
    while IFS= read -r item; do
        case "$item" in
            /*|../*|*/../*|*/..)
                return 1
                ;;
        esac
    done < <(tar -tzf "$archive" 2>/dev/null)
    return 0
}

restore_backup() {
    local archive
    if ! command -v tar >/dev/null 2>&1; then
        error_dialog "未找到 tar。"
        return 1
    fi
    archive=$(zenity --file-selection --title="$APP_TITLE - 恢复备份" \
        --file-filter='Fcitx5 备份 | *.tar.gz' --file-filter='全部文件 | *' 2>/dev/null) || return 0
    [[ -f "$archive" ]] || return 0
    if ! archive_is_safe "$archive"; then
        error_dialog "备份文件包含不安全路径，已拒绝恢复。"
        return 1
    fi
    if ! question_dialog "恢复前会自动备份当前配置，然后覆盖备份中包含的 Fcitx5/Rime 文件。\n\n确定继续吗？"; then
        return 0
    fi
    create_backup || return 1
    if tar -xzf "$archive" -C "$HOME" >/dev/null 2>&1; then
        restart_fcitx || true
        info_dialog "恢复完成，并已尝试重启 Fcitx5。"
    else
        error_dialog "恢复备份失败。"
    fi
}

backup_manager() {
    local result
    while true; do
        result=$(zenity --list --title="$APP_TITLE - 备份与恢复" --width=850 --height=560 \
            --text="备份目录：$BACKUP_DIR" --column="操作" \
            --ok-label="执行" --cancel-label="返回" \
            "创建完整备份" "恢复备份" "打开备份目录" 2>/dev/null) || return 0
        case "$result" in
            "创建完整备份") create_backup ;;
            "恢复备份") restore_backup ;;
            "打开备份目录") mkdir -p "$BACKUP_DIR" && open_path "$BACKUP_DIR" || true ;;
        esac
    done
}

diagnostic_menu() {
    local result
    while true; do
        result=$(zenity --list --title="$APP_TITLE - 诊断与重载" --width=820 --height=560 \
            --text="用于排查输入法配置不生效、词库未更新等问题。" --column="操作" \
            --ok-label="执行" --cancel-label="返回" \
            "运行健康检查" "重新加载 Fcitx5 配置" "重建 Rime 词库并重启" \
            "查看最近日志" "打开 Fcitx5 配置目录" "打开 Rime 配置目录" 2>/dev/null) || return 0
        case "$result" in
            "运行健康检查") show_dashboard ;;
            "重新加载 Fcitx5 配置")
                if reload_fcitx; then info_dialog "Fcitx5 配置已重新加载。"; else error_dialog "重新加载失败。"; fi
                ;;
            "重建 Rime 词库并重启")
                if rime_deploy && restart_fcitx; then info_dialog "Rime 词库已重建，Fcitx5 已重启。"; else error_dialog "操作失败。日志：${LAST_LOG:-$LOG_DIR/assistant.log}"; fi
                ;;
            "查看最近日志")
                if [[ -f "$LOG_DIR/assistant.log" ]]; then show_text "最近日志" "$(tail -120 "$LOG_DIR/assistant.log")"; else info_dialog "暂时没有日志。"; fi
                ;;
            "打开 Fcitx5 配置目录") mkdir -p "$FCITX_DIR" && open_path "$FCITX_DIR" || true ;;
            "打开 Rime 配置目录") mkdir -p "$RIME_DIR" && open_path "$RIME_DIR" || true ;;
        esac
    done
}

gtk_frontend() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$0" <<'PY'
import configparser
import os
import subprocess
import sys

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, GLib
except Exception:
    raise SystemExit(2)

script = sys.argv[1]
config_home = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
fcitx_dir = os.path.join(config_home, "fcitx5")

switches = {
    "输入法": [
        ("开机自动启动 Fcitx5", "登录桌面后自动启动输入法服务", "fcitx-autostart", False),
        ("启动后默认启用输入法", "打开会话后直接进入输入状态", "active-default", True),
        ("切换时显示输入法提示", "切换输入法时显示名称提示", "show-im-info", True),
    ],
    "Rime": [
        ("采用预编辑", "决定启动和重启后是否默认启用预编辑", "preedit-default", True),
        ("锁定预编辑（禁用 Ctrl+Alt+P）", "开启后快捷键不再切换预编辑；关闭后立即恢复 Ctrl+Alt+P", "lock-preedit", False),
    ],
    "输入体验": [
        ("启用标点引擎", "启用 Fcitx5 标点转换", "punctuation-enabled", True),
        ("字母或数字后使用半角标点", "英文和数字之后优先输入半角标点", "halfwidth-after-letter", True),
        ("自动输入成对标点", "一次输入左右两个配对标点", "paired-punctuation", False),
        ("原生拼音拼写检查", "仅对 Fcitx5 原生拼音生效", "pinyin-spell", True),
        ("原生拼音 Emoji", "在原生拼音候选中提供 Emoji", "pinyin-emoji", True),
        ("原生拼音云候选", "允许原生拼音使用云拼音候选", "pinyin-cloud", False),
        ("V 键快速输入", "将 V 键用作原生拼音快速输入入口", "pinyin-quickphrase", True),
    ],
}

option_sources = {
    "active-default": (os.path.join(fcitx_dir, "config"), "Behavior", "ActiveByDefault"),
    "preedit-default": (os.path.join(fcitx_dir, "config"), "Behavior", "PreeditEnabledByDefault"),
    "lock-preedit": (os.path.join(fcitx_dir, "config"), "Hotkey/TogglePreedit", "0"),
    "show-im-info": (os.path.join(fcitx_dir, "config"), "Behavior", "ShowInputMethodInformation"),
    "rime-preedit": (os.path.join(fcitx_dir, "conf/rime.conf"), None, "PreeditInApplication"),
    "rime-cursor-begin": (os.path.join(fcitx_dir, "conf/rime.conf"), None, "PreeditCursorPositionAtBeginning"),
    "punctuation-enabled": (os.path.join(fcitx_dir, "conf/punctuation.conf"), None, "Enabled"),
    "halfwidth-after-letter": (os.path.join(fcitx_dir, "conf/punctuation.conf"), None, "HalfWidthPuncAfterLetterOrNumber"),
    "paired-punctuation": (os.path.join(fcitx_dir, "conf/punctuation.conf"), None, "TypePairedPunctuationsTogether"),
    "pinyin-spell": (os.path.join(fcitx_dir, "conf/pinyin.conf"), None, "SpellEnabled"),
    "pinyin-emoji": (os.path.join(fcitx_dir, "conf/pinyin.conf"), None, "EmojiEnabled"),
    "pinyin-cloud": (os.path.join(fcitx_dir, "conf/pinyin.conf"), None, "CloudPinyinEnabled"),
    "pinyin-quickphrase": (os.path.join(fcitx_dir, "conf/pinyin.conf"), None, "VAsQuickphrase"),
}

def read_bool(option, fallback):
    if option == "fcitx-autostart":
        path = os.path.join(config_home, "autostart", "fcitx5.desktop")
        try:
            parser = configparser.ConfigParser(interpolation=None, strict=False)
            parser.optionxform = str
            parser.read(path, encoding="utf-8")
            value = parser.get("Desktop Entry", "Hidden", fallback="true")
            return os.path.isfile(path) and value.strip().lower() not in ("true", "1", "yes", "on")
        except Exception:
            return False

    path, section, key = option_sources[option]
    try:
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        parser.optionxform = str
        if section is None:
            with open(path, encoding="utf-8") as handle:
                parser.read_string("[root]\n" + handle.read())
            value = parser.get("root", key, fallback=str(fallback))
        else:
            parser.read(path, encoding="utf-8")
            value = parser.get(section, key, fallback=str(fallback))
        if option == "lock-preedit":
            return value.strip() == "Control+Alt+Shift+Super+F24"
        return value.strip().lower() in ("true", "1", "yes", "on")
    except Exception:
        return fallback

sections = [
    ("总览", "输入法配置概况", [
        ("状态总览", "查看 Fcitx5、Rime、词库、主题和依赖状态", "dashboard"),
        ("诊断与重载", "健康检查、重新加载配置、部署词库和查看日志", "diagnostic"),
    ]),
    ("输入法", "输入法与通用行为", [
        ("输入法管理", "切换当前输入法、设置默认输入法", "input-methods"),
        ("基本设置", "候选数量、预编辑、启动状态和状态共享", "basic"),
        ("快捷键", "输入法切换、标点及简繁转换快捷键", "shortcuts"),
    ]),
    ("Rime", "Rime 输入方案", [
        ("方案管理", "切换方案、打开方案文件或重新部署", "schemas"),
        ("Rime 设置", "应用内预编辑和光标行为", "rime"),
        ("个性短语", "新增、修改、搜索及导入导出讯飞短语", "phrases"),
        ("用户词库", "导入、导出和备份 Rime 用户词库", "dictionaries"),
    ]),
    ("输入体验", "文字输入与显示", [
        ("标点设置", "中文标点、半角标点和成对标点", "punctuation"),
        ("原生拼音", "拼写检查、Emoji、云拼音和快速输入", "native-pinyin"),
        ("外观主题", "选择 Fcitx5 ClassicUI 主题", "themes"),
    ]),
    ("维护", "备份与故障排查", [
        ("备份与恢复", "创建完整备份、恢复配置或打开备份目录", "backup"),
        ("诊断与重载", "重新加载 Fcitx5、重建 Rime、查看日志", "diagnostic"),
    ]),
]

class Window(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Fcitx5 配置助手")
        self.set_default_size(980, 680)
        self.set_size_request(760, 520)

        header = Gtk.HeaderBar(title="Fcitx5 配置助手", subtitle="Fcitx5 · Rime")
        header.set_show_close_button(True)
        self.set_titlebar(header)

        css = Gtk.CssProvider()
        css.load_from_data(b"switch:checked { background-color: #e95420; border-color: #e95420; } switch:checked slider { border-color: #d94816; }")
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), css,
                                                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        root = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.add(root)

        sidebar_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        sidebar_box.set_size_request(210, -1)
        sidebar_box.get_style_context().add_class("sidebar")
        root.pack_start(sidebar_box, False, False, 0)

        brand = Gtk.Label()
        brand.set_markup("<b>设置分类</b>")
        brand.set_xalign(0)
        brand.set_margin_start(20); brand.set_margin_top(20); brand.set_margin_bottom(10)
        sidebar_box.pack_start(brand, False, False, 0)

        self.listbox = Gtk.ListBox()
        self.listbox.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.listbox.connect("row-selected", self.on_selected)
        sidebar_box.pack_start(self.listbox, True, True, 0)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE,
                               transition_duration=160)
        root.pack_start(self.stack, True, True, 0)

        for index, (name, subtitle, items) in enumerate(sections):
            row = Gtk.ListBoxRow()
            label = Gtk.Label(label=name, xalign=0)
            label.set_margin_start(20); label.set_margin_end(16)
            label.set_margin_top(13); label.set_margin_bottom(13)
            row.add(label)
            row.page_name = str(index)
            self.listbox.add(row)
            self.stack.add_named(self.make_page(name, subtitle, items), str(index))

        self.listbox.select_row(self.listbox.get_row_at_index(0))

    def make_page(self, title, subtitle, items):
        outer = Gtk.ScrolledWindow()
        outer.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_margin_start(36); box.set_margin_end(36)
        box.set_margin_top(30); box.set_margin_bottom(30)
        outer.add(box)

        heading = Gtk.Label(xalign=0)
        heading.set_markup(f'<span size="xx-large" weight="bold">{GLib.markup_escape_text(title)}</span>')
        box.pack_start(heading, False, False, 0)
        sub = Gtk.Label(label=subtitle, xalign=0)
        sub.get_style_context().add_class("dim-label")
        sub.set_margin_bottom(10)
        box.pack_start(sub, False, False, 0)

        for setting_title, description, option, fallback in switches.get(title, []):
            frame = Gtk.Frame()
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=18)
            row.set_margin_start(18); row.set_margin_end(18)
            row.set_margin_top(13); row.set_margin_bottom(13)
            text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            name = Gtk.Label(xalign=0)
            name.set_markup(f'<b>{GLib.markup_escape_text(setting_title)}</b>')
            detail = Gtk.Label(label=description, xalign=0)
            detail.set_line_wrap(True)
            detail.get_style_context().add_class("dim-label")
            text.pack_start(name, False, False, 0)
            text.pack_start(detail, False, False, 0)
            toggle = Gtk.Switch()
            toggle.set_valign(Gtk.Align.CENTER)
            toggle.set_active(read_bool(option, fallback))
            toggle.connect("notify::active", self.toggle_option, option)
            row.pack_start(text, True, True, 0)
            row.pack_end(toggle, False, False, 0)
            frame.add(row)
            box.pack_start(frame, False, False, 0)

        for item_title, description, module in items:
            frame = Gtk.Frame()
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=18)
            row.set_margin_start(18); row.set_margin_end(18)
            row.set_margin_top(15); row.set_margin_bottom(15)
            text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            name = Gtk.Label(xalign=0)
            name.set_markup(f'<b>{GLib.markup_escape_text(item_title)}</b>')
            detail = Gtk.Label(label=description, xalign=0)
            detail.set_line_wrap(True)
            detail.get_style_context().add_class("dim-label")
            text.pack_start(name, False, False, 0)
            text.pack_start(detail, False, False, 0)
            button = Gtk.Button(label="打开")
            button.set_valign(Gtk.Align.CENTER)
            button.connect("clicked", self.open_module, module)
            row.pack_start(text, True, True, 0)
            row.pack_end(button, False, False, 0)
            frame.add(row)
            box.pack_start(frame, False, False, 0)
        return outer

    def on_selected(self, _listbox, row):
        if row is not None:
            self.stack.set_visible_child_name(row.page_name)

    def open_module(self, _button, module):
        subprocess.Popen([script, "--module", module])

    def toggle_option(self, toggle, _param, option):
        value = "True" if toggle.get_active() else "False"
        command = "--set-autostart" if option == "fcitx-autostart" else "--set-option"
        subprocess.Popen([script, command, option, value] if command == "--set-option" else [script, command, value])

class App(Gtk.Application):
    def do_activate(self):
        win = Window(self)
        win.show_all()

App(application_id="local.fcitx5.configassistant").run(None)
PY
}

self_test() {
    local report=""
    local test_dir
    local test_ini
    local test_phrase
    local rime_rc=0
    local backup_rc=0

    report+="[依赖]\n"
    for command_name in zenity fcitx5 fcitx5-remote rime_deployer rime_dict_manager iconv tar awk; do
        report+="$command_name：$(command_status "$command_name")\n"
    done
    report+="\n[配置读取]\n"
    report+="Fcitx5 profile：$([[ -f "$FCITX_PROFILE" ]] && printf '通过' || printf '缺失')\n"
    report+="Fcitx5 默认输入法：$(current_default_im)\n"
    report+="Rime 目录：$([[ -d "$RIME_DIR" ]] && printf '通过' || printf '缺失')\n"
    report+="Rime 方案数：$(load_schemas; printf '%s' "${#SCHEMA_IDS[@]}")\n"
    ensure_phrase_file
    load_phrase_entries
    report+="个性短语解析：通过（${#ENTRY_CODES[@]} 条）\n"

    test_dir=$(mktemp -d)
    test_ini="$test_dir/test.conf"
    printf '[Behavior]\nDefaultPageSize=5\n' > "$test_ini"
    if set_ini_key "$test_ini" Behavior DefaultPageSize 8 && [[ "$(ini_get "$test_ini" Behavior DefaultPageSize 0)" == "8" ]]; then
        report+="INI 原子写入：通过\n"
    else
        report+="INI 原子写入：失败\n"
    fi
    test_phrase="$test_dir/phrase.txt"
    printf '文本\tcode\t1\n' > "$test_phrase"
    if [[ "$(awk -F '\t' 'NF >= 2 {n++} END {print n+0}' "$test_phrase")" == "1" ]]; then
        report+="个性短语格式校验：通过\n"
    else
        report+="个性短语格式校验：失败\n"
    fi
    rm -rf -- "$test_dir"

    if command -v rime_deployer >/dev/null 2>&1 && [[ -d "$RIME_DIR" ]]; then
        rime_deploy || rime_rc=$?
        if [[ "$rime_rc" -eq 0 ]]; then report+="Rime 词库部署：通过\n"; else report+="Rime 词库部署：失败（$rime_rc）\n"; fi
    else
        report+="Rime 词库部署：跳过（缺少工具或目录）\n"
    fi
    QUIET_MODE=1
    if create_backup >/dev/null 2>&1; then
        report+="完整备份创建：通过\n"
    else
        backup_rc=$?
        report+="完整备份创建：失败（$backup_rc）\n"
    fi
    QUIET_MODE=0
    report+="\n[当前状态]\n$(health_report)\n"
    report+="\n说明：GUI 按钮需要用户交互，已通过打开主窗口、列表加载和后端写入测试；删除/恢复等有破坏性的操作不会在自测中自动执行。"
    printf '%b\n' "$report"
    return 0
}

main_menu() {
    local result
    local default_im
    local schema

    default_im=$(current_default_im)
    schema=$(current_schema_name "$(current_schema_id)")
    while true; do
        result=$(zenity --list --title="$APP_TITLE" --width=900 --height=690 \
            --text="当前默认输入法：$default_im\n当前 Rime 方案：$schema\n选择一个功能模块。" \
            --column="模块" --column="说明" --print-column=1 \
            --ok-label="打开" --cancel-label="退出" \
            "状态总览" "查看 Fcitx5、Rime、主题、词库和依赖状态" \
            "输入法管理" "切换输入法、设置默认输入法、打开 Fcitx5 配置工具" \
            "开机启动" "设置登录桌面后自动启动 Fcitx5" \
            "基本设置" "候选数量、预编辑、状态共享、默认启用" \
            "标点设置" "中文标点、半角标点、成对标点" \
            "Rime 方案" "切换全拼、双拼、五笔、九键等方案" \
            "Rime 设置" "预编辑显示和光标行为" \
            "个性短语" "新增、修改、删除、搜索、导入/导出讯飞 cphrase.ini" \
            "用户词库" "导入、导出、列出和备份 Rime 用户词库" \
            "原生拼音设置" "配置 Fcitx5 原生拼音（不影响 Rime）" \
            "快捷键" "统一设置输入法、标点、简繁转换快捷键" \
            "外观主题" "选择 Fcitx5 ClassicUI 主题" \
            "备份与恢复" "完整备份、恢复和打开备份目录" \
            "诊断与重载" "重新加载、重建词库、查看日志、打开配置目录" 2>/dev/null) || return 0
        case "$result" in
            "状态总览") show_dashboard ;;
            "输入法管理") input_method_manager ;;
            "开机启动") autostart_settings ;;
            "基本设置") basic_settings ;;
            "标点设置") punctuation_settings ;;
            "Rime 方案") rime_schema_manager ;;
            "Rime 设置") rime_settings ;;
            "个性短语") phrase_manager ;;
            "用户词库") user_dictionary_manager ;;
            "原生拼音设置") native_pinyin_settings ;;
            "快捷键") shortcut_settings ;;
            "外观主题") theme_settings ;;
            "备份与恢复") backup_manager ;;
            "诊断与重载") diagnostic_menu ;;
        esac
        default_im=$(current_default_im)
        schema=$(current_schema_name "$(current_schema_id)")
    done
}

usage() {
    printf '%s\n' \
        "用法：$0 [选项]" \
        "" \
        "  无参数       打开 Fcitx5 配置助手" \
        "  --self-test  执行后端和配置自测，不打开 GUI" \
        "  --phrases    直接打开个性短语管理" \
        "  --help       显示帮助"
}

main() {
    case "${1:-}" in
        --self-test)
            self_test
            return 0
            ;;
        --phrases)
            command -v zenity >/dev/null 2>&1 || { printf '%s\n' '未找到 zenity。' >&2; return 1; }
            phrase_manager
            return $?
            ;;
        --module)
            command -v zenity >/dev/null 2>&1 || { printf '%s\n' '未找到 zenity。' >&2; return 1; }
            case "${2:-}" in
                dashboard) show_dashboard ;;
                diagnostic) diagnostic_menu ;;
                input-methods) input_method_manager ;;
                autostart) autostart_settings ;;
                basic) basic_settings ;;
                shortcuts) shortcut_settings ;;
                schemas) rime_schema_manager ;;
                rime) rime_settings ;;
                phrases) phrase_manager ;;
                dictionaries) user_dictionary_manager ;;
                punctuation) punctuation_settings ;;
                native-pinyin) native_pinyin_settings ;;
                themes) theme_settings ;;
                backup) backup_manager ;;
                *) printf '%s\n' "未知模块：${2:-}" >&2; return 2 ;;
            esac
            return $?
            ;;
        --set-option)
            local option="${2:-}"
            local value="${3:-}"
            [[ "$value" == "True" || "$value" == "False" ]] || return 2
            case "$option" in
                active-default) set_ini_key "$FCITX_CONFIG" Behavior ActiveByDefault "$value" ;;
                preedit-default)
                    # Rime 必须允许应用内预编辑，否则 Ctrl+Alt+P 虽会提示切换，视觉上却没有变化。
                    set_root_key "$FCITX_CONF_DIR/rime.conf" PreeditInApplication True \
                        && set_ini_key "$FCITX_CONFIG" Behavior PreeditEnabledByDefault "$value"
                    ;;
                lock-preedit)
                    if [[ "$value" == "True" ]]; then
                        # 空热键会被 Fcitx5 当作使用默认值，必须改绑到专用哨兵键。
                        set_ini_key "$FCITX_CONFIG" Hotkey/TogglePreedit 0 "Control+Alt+Shift+Super+F24"
                    else
                        set_ini_key "$FCITX_CONFIG" Hotkey/TogglePreedit 0 "Control+Alt+P"
                    fi
                    ;;
                show-im-info) set_ini_key "$FCITX_CONFIG" Behavior ShowInputMethodInformation "$value" ;;
                rime-preedit) set_root_key "$FCITX_CONF_DIR/rime.conf" PreeditInApplication "$value" ;;
                rime-cursor-begin) set_root_key "$FCITX_CONF_DIR/rime.conf" PreeditCursorPositionAtBeginning "$value" ;;
                punctuation-enabled) set_root_key "$FCITX_CONF_DIR/punctuation.conf" Enabled "$value" ;;
                halfwidth-after-letter) set_root_key "$FCITX_CONF_DIR/punctuation.conf" HalfWidthPuncAfterLetterOrNumber "$value" ;;
                paired-punctuation) set_root_key "$FCITX_CONF_DIR/punctuation.conf" TypePairedPunctuationsTogether "$value" ;;
                pinyin-spell) set_root_key "$FCITX_CONF_DIR/pinyin.conf" SpellEnabled "$value" ;;
                pinyin-emoji) set_root_key "$FCITX_CONF_DIR/pinyin.conf" EmojiEnabled "$value" ;;
                pinyin-cloud) set_root_key "$FCITX_CONF_DIR/pinyin.conf" CloudPinyinEnabled "$value" ;;
                pinyin-quickphrase) set_root_key "$FCITX_CONF_DIR/pinyin.conf" VAsQuickphrase "$value" ;;
                *) return 2 ;;
            esac || return 1
            restart_fcitx
            return $?
            ;;
        --set-autostart)
            local autostart_value="${2:-}"
            [[ "$autostart_value" == "True" || "$autostart_value" == "False" ]] || return 2
            set_fcitx_autostart "$autostart_value"
            return $?
            ;;
        --help|-h)
            usage
            return 0
            ;;
    esac

    if ! command -v zenity >/dev/null 2>&1; then
        printf '%s\n' '未找到 zenity，请先安装：sudo apt install zenity' >&2
        return 1
    fi
    if gtk_frontend; then
        return 0
    fi
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
