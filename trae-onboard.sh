#!/bin/bash

# Compatible with the Bash 3.2 shipped with macOS.
CONSOLE='https://console.enterprise.trae.cn'
MAIL_API='https://api.mail.tm'
API='/trae/gtm/tob/api/v1'
PLUGIN='@magpie-community/opencode-trae-auth'
WORK='' LOCK='' MAGPIE_LOCK='' LOGIN_PID='' SETTINGS_CHANGED=0
OLD_LINK_SETTING='' MAGPIE_AUTH='' HTTP_STATUS='' HTTP_ERROR=''
ACCOUNTS='' ADMIN_FILE='' COMMAND='' COUNT=0 DRY_RUN=0 FORCE_LOGIN=0
MAIL_TIMEOUT=300 LOGIN_TIMEOUT=600 POLL_INTERVAL=3 DEPARTMENT=''
TENANT='' ROOT_DEPARTMENT='' FREE_SEATS=0 OCCUPIED=0 TOTAL_SEATS=0 PENDING=0
QUERY_VALUE='' DECODED='' COMPLETED=0 NEW_EMAIL='' RANDOM_HEX=''
REQUEST_DEADLINE=0 HTTP_UNSENT=0 RETRY_UNSUBMITTED='' LOGIN_CHANGED=0 AUX_PID=''

log() { printf '%s\n' "$*" >&2; }
die() { log "错误：$*"; exit 1; }

usage() {
    cat <<'HELP'
用法：bash trae-onboard.sh <activate|login|all> [选项]

  activate                 创建临时邮箱，邀请并注册到现有 Full 席位
  login                    将已激活的邮箱密码逐个导入 Magpie
  all                      激活后导入 Magpie

  --accounts FILE          账号/断点文件（默认脚本目录/data/accounts.json）
  --admin-file FILE        管理员 JSON：{"email":"...","password":"..."}
                           文件须由当前用户持有，且仅当前用户可读写
                           不指定时通过终端安全输入，不读取 HAR 中的凭据
  --count N                本次最多激活/登录 N 个账号（默认填充可用 Full 席位）
  --department-id ID       新成员所属部门（默认企业根部门）
  --mail-timeout SECONDS   等待邀请邮件的总时限（默认 300）
  --login-timeout SECONDS  单次 Magpie 授权总时限（默认 600）
  --poll-interval SECONDS  邮件轮询间隔（默认 3）
  --magpie-auth-file FILE  非标准/便携安装的实际 plugin-auth.json 路径
  --force-login            对已经导入的账号重新授权
  --retry-unsubmitted EMAIL 已停用；未完成账号会按远端状态清理
  --dry-run                仅离线预览；不联网、不写文件、不安装软件
  -h, --help               显示帮助

login 支持原生状态文件，也支持 JSON 数组：
  [{"email":"user@example.com","password":"TRAE 登录密码"}]
输入文件会转换为带 version/accounts 的原生状态格式，并限制为 600 权限。
每次激活会检查所有非 active 记录（包括 abandoned）；远端不存在时删除本地记录。
远端为 Full 待邀请成员时会请求移除并重新确认，确认不存在后才删除本地记录；
已激活、其他类型或未知状态会停止。清理完成后按可用配额创建新邮箱。

依赖：Bash 3.2+、curl、jq 1.6+、openssl 及系统工具。
login/all 可安装 Magpie、TRAE 插件及其 Bun 运行时；不会安装 Python/Node。
临时邮箱由 https://mail.tm 提供，不保证长期保留；账号文件为敏感明文。
导入成功只表示目标 UID 已写入 Magpie，不代表模型调用或长期续期已验证。
建议先 --dry-run，再 --count 1，确认后批量运行。
HELP
}

positive_integer() { [[ $1 =~ ^[1-9][0-9]{0,5}$ ]]; }

parse_args() {
    local base
    base=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || die '无法定位脚本目录'
    ACCOUNTS="$base/data/accounts.json"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            activate|login|all)
                [[ -z $COMMAND ]] || die '只能指定一个子命令'
                COMMAND=$1; shift ;;
            --accounts|--admin-file|--count|--department-id|--mail-timeout|--login-timeout|--poll-interval|--magpie-auth-file|--retry-unsubmitted)
                [[ $# -ge 2 && -n $2 ]] || die "$1 缺少参数"
                case "$1" in
                    --accounts) ACCOUNTS=$2 ;;
                    --admin-file) ADMIN_FILE=$2 ;;
                    --count) positive_integer "$2" || die 'count 必须是正整数'; COUNT=$2 ;;
                    --department-id) DEPARTMENT=$2 ;;
                    --mail-timeout) positive_integer "$2" || die 'mail-timeout 必须是正整数'; MAIL_TIMEOUT=$2 ;;
                    --login-timeout) positive_integer "$2" || die 'login-timeout 必须是正整数'; LOGIN_TIMEOUT=$2 ;;
                    --poll-interval) positive_integer "$2" || die 'poll-interval 必须是正整数'; POLL_INTERVAL=$2 ;;
                    --magpie-auth-file) MAGPIE_AUTH=$2 ;;
                    --retry-unsubmitted) RETRY_UNSUBMITTED=$2 ;;
                esac
                shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            --force-login) FORCE_LOGIN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die '未知参数，请运行 --help' ;;
        esac
    done
    [[ -n $COMMAND ]] || die '请指定 activate、login 或 all'
    [[ -z $RETRY_UNSUBMITTED ]] || die '--retry-unsubmitted 已停用；重新运行会按远端状态清理未完成账号'
    case "$ACCOUNTS" in /*) ;; *) ACCOUNTS="$PWD/$ACCOUNTS" ;; esac
    if [[ -n $MAGPIE_AUTH ]]; then
        case "$MAGPIE_AUTH" in /*) ;; *) MAGPIE_AUTH="$PWD/$MAGPIE_AUTH" ;; esac
    fi
    case "$ACCOUNTS$ADMIN_FILE$MAGPIE_AUTH" in
        *$'\n'*|*$'\r'*) die '文件路径不能包含换行' ;;
    esac
}

check_dependencies() {
    local cmd
    for cmd in curl jq openssl mktemp stat chmod mkdir mv rm sleep readlink awk; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖：${cmd}，请先安装"
    done
    jq -ne '"a" | scan("a") == "a"' >/dev/null 2>&1 || die '需要支持 scan 的 jq（建议 1.6+）'
}

private_file() {
    local mode
    [[ -f $1 && ! -L $1 && -O $1 ]] || die '凭据文件必须是当前用户持有的普通文件，不能是符号链接'
    mode=$(stat -f '%Lp' "$1" 2>/dev/null) || mode=$(stat -c '%a' "$1") || die '无法检查凭据权限'
    [[ $mode =~ ^[0-7]{3,4}$ ]] || die '无法识别凭据权限'
    (( (8#$mode & 077) == 0 )) || die '管理员凭据权限过宽，请先 chmod 600 该文件'
}

validate_state() {
    jq -e '
        def email_ok: type == "string" and (test("[\\x00-\\x20\\x7f]") | not)
            and test("^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$");
        def password_ok: type == "string" and length > 0 and (test("[\\x00-\\x1f\\x7f]") | not);
        (if type == "array" then {version:1,accounts:.} else . end)
        | type == "object" and .version == 1 and (.accounts | type == "array")
        and ((.tenant_id // "") | type == "string")
        and all(.accounts[];
            (.email | email_ok) and (.password | password_ok)
            and ((.user_id // "") | type == "string")
            and ((.tenant_id // "") | type == "string")
            and ((.mailbox_create_attempted // false) | type == "boolean")
            and ((.magpie_uid_present_before // false) | type == "boolean")
            and ((.magpie_target_uid // "") | type == "string")
            and ((.magpie_status // "pending") as $s | ["pending","authorizing","signed_in"] | index($s) != null)
            and ((.status // "active") as $s | ["prepared","mailbox_created","invite_submitting","invited","register_submitting","active"] | index($s) != null)
            and ((.status // "active") == "active" or (.mailbox_password | password_ok)))
        and (([.accounts[].email | ascii_downcase] | unique | length) == (.accounts | length))
    ' "$1" >/dev/null 2>&1
}

start_child() {
    local target=$1 output=$2 monitor=0
    shift 2
    [[ $- != *m* ]] || monitor=1
    set -m
    "$@" </dev/null >"$output" 2>&1 &
    printf -v "$target" '%s' "$!"
    (( monitor )) || set +m
}

stop_child() {
    local pid=$1 attempts=0
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    kill -TERM -- "-$pid" 2>/dev/null || :
    while kill -0 -- "-$pid" 2>/dev/null && (( attempts < 20 )); do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    kill -KILL -- "-$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
}

bounded_command() {
    local duration=$1 output=$2 deadline rc=0
    shift 2
    deadline=$((SECONDS + duration))
    start_child AUX_PID "$output" "$@"
    while kill -0 "$AUX_PID" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
            stop_child "$AUX_PID"; AUX_PID=''; return 1
        fi
        sleep 0.1
    done
    wait "$AUX_PID" || rc=$?
    stop_child "$AUX_PID"
    AUX_PID=''
    return "$rc"
}

cleanup() {
    local result=$? restore_ok=1
    trap - EXIT INT TERM HUP
    set +e
    [[ -z $LOGIN_PID ]] || stop_child "$LOGIN_PID"
    [[ -z $AUX_PID ]] || stop_child "$AUX_PID"
    if [[ $SETTINGS_CHANGED == 1 ]]; then
        if ! bounded_command 15 "$WORK/restore.log" magpie settings set signInLinkOnly "$OLD_LINK_SETTING"; then
            log '警告：无法恢复 Magpie signInLinkOnly 设置；原值保留在 Magpie 锁目录中，请手动恢复'
            result=1; restore_ok=0
        fi
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    if [[ -n $MAGPIE_LOCK && $restore_ok == 1 ]]; then rm -rf -- "$MAGPIE_LOCK"; fi
    [[ -z $LOCK ]] || rm -rf -- "$LOCK"
    exit "$result"
}

init_workspace() {
    local dir tmp
    umask 077
    dir=$(dirname "$ACCOUNTS")
    [[ ! -L $ACCOUNTS ]] || die '账号文件不能是符号链接'
    mkdir -p -- "$dir" || die '无法创建数据目录'
    if ! mkdir -- "$ACCOUNTS.lock" 2>/dev/null; then
        die '账号文件已锁定；请勿同时运行。异常退出后请确认原进程已停止，再移除对应 .lock 目录'
    fi
    LOCK="$ACCOUNTS.lock"
    printf '%s\n' "$$" >"$LOCK/pid"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    WORK=$(mktemp -d "$dir/.trae-onboard.XXXXXX") || die '无法创建私有工作目录'
    chmod 700 "$WORK" || die '无法限制工作目录权限'
    if [[ -e $ACCOUNTS ]]; then
        if [[ -n $MAGPIE_AUTH || $COMMAND != activate ]] && { [[ -n $MAGPIE_AUTH ]] || command -v magpie >/dev/null 2>&1; }; then
            resolve_magpie_auth
            [[ ! -e $MAGPIE_AUTH || ! $ACCOUNTS -ef $MAGPIE_AUTH ]] || die '账号状态文件不能覆盖 Magpie 凭据库'
        fi
        [[ -f $ACCOUNTS && -O $ACCOUNTS ]] || die '账号文件必须由当前用户持有'
        chmod 600 "$ACCOUNTS" || die '无法限制账号文件权限'
        validate_state "$ACCOUNTS" || die '账号 JSON 格式、状态或字段无效；没有覆盖原文件'
        tmp=$(mktemp "$ACCOUNTS.tmp.XXXXXX") || die '无法创建状态临时文件'
        jq 'if type == "array" then {version:1,tenant_id:"",accounts:.} else . end
            | .accounts |= map(.email |= ascii_downcase | .status //= "active" | .magpie_status //= "pending")' \
            "$ACCOUNTS" >"$tmp" || die '无法规范化账号文件'
        mv -f -- "$tmp" "$ACCOUNTS" || die '无法更新账号文件'
    else
        [[ $COMMAND != login ]] || die 'login 需要存在的账号文件'
        printf '{"version":1,"tenant_id":"","accounts":[]}\n' >"$ACCOUNTS" || die '无法创建账号文件'
    fi
    if [[ -n $RETRY_UNSUBMITTED ]]; then
        RETRY_UNSUBMITTED=$(printf '%s' "$RETRY_UNSUBMITTED" | jq -Rsr ascii_downcase) || die '无法读取重试邮箱'
        jq -e --arg email "$RETRY_UNSUBMITTED" 'any(.accounts[]; .email == $email and .status != "active")' \
            "$ACCOUNTS" >/dev/null || die '--retry-unsubmitted 必须指定状态文件中未完成的账号'
    fi
}

state_update() {
    local email=$1 patch=$2 tmp
    tmp=$(mktemp "$ACCOUNTS.tmp.XXXXXX") || die '无法创建状态临时文件'
    jq --arg email "$email" --slurpfile patch "$patch" \
        '.accounts |= map(if .email == $email then . + $patch[0] else . end)' \
        "$ACCOUNTS" >"$tmp" || die '无法写入状态'
    mv -f -- "$tmp" "$ACCOUNTS" || die '无法提交状态'
}

set_status() {
    local email=$1 status=$2
    jq -n --arg status "$status" '{status:$status}' >"$WORK/patch.json" || die '无法生成状态'
    state_update "$email" "$WORK/patch.json"
}

load_account() {
    jq -e --arg email "$1" '.accounts[] | select(.email == $email)' "$ACCOUNTS" >"$WORK/account.json" || die '找不到状态中的账号'
}

curl_escape() {
    local value=$1
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || die 'HTTP 参数含非法换行'
    value=${value//\\/\\\\}; value=${value//\"/\\\"}
    printf '%s' "$value"
}

# Secrets live in a private curl config, not in the process argument list.
http_request() {
    local method=$1 url=$2 body=$3 output=$4 jar=$5 token=$6 retry=$7
    local config="$WORK/request.conf" attempt=0 delay=1 status rc auth='' retry_after budget remaining port
    HTTP_ERROR=''; HTTP_STATUS=''; HTTP_UNSENT=0
    if [[ -n $token ]]; then IFS= read -r auth <"$token" || [[ -n $auth ]] || return 1; fi
    case "$url" in
        "$CONSOLE/"*|"$MAIL_API/"*) ;;
        *)
            if [[ $url =~ ^http://127\.0\.0\.1:([1-9][0-9]{3,4})/authorize\?[^#[:space:]]+$ ]]; then
                port=${BASH_REMATCH[1]}
                (( port >= 1024 && port <= 65535 )) || { HTTP_ERROR='不允许的回调端口'; return 1; }
            else
                HTTP_ERROR='不允许的请求地址'; return 1
            fi ;;
    esac
    {
        printf 'silent\nshow-error\nconnect-timeout = 15\nmax-time = 45\n'
        printf 'request = "%s"\nurl = "%s"\n' "$method" "$(curl_escape "$url")"
        printf 'output = "%s"\ndump-header = "%s"\nwrite-out = "%%{http_code}"\n' \
            "$(curl_escape "$output")" "$(curl_escape "$WORK/response.headers")"
        if [[ $url == "$MAIL_API/"* ]]; then
            # Mail.tm 只有 ld+json 才返回带 hydra:view 分页信息的集合；纯 JSON 是裸数组。
            printf 'header = "Accept: application/ld+json, application/json;q=0.9"\n'
        else
            printf 'header = "Accept: application/json"\n'
        fi
        if [[ $url == http://127.0.0.1:* ]]; then
            printf 'proto = "=http"\nnoproxy = "*"\n'
        else
            printf 'proto = "=https"\n'
        fi
        if [[ -n $body ]]; then
            printf 'header = "Content-Type: application/json"\ndata-binary = "@%s"\n' "$(curl_escape "$body")"
        fi
        if [[ -n $jar ]]; then
            [[ $url == "$CONSOLE/"* ]] || die '拒绝将企业 Cookie 发送给其他主机'
            printf 'cookie = "%s"\ncookie-jar = "%s"\n' "$(curl_escape "$jar")" "$(curl_escape "$jar")"
            printf 'header = "Origin: %s"\n' "$CONSOLE"
        fi
        if [[ -n $auth ]]; then
            [[ $url == "$MAIL_API/"* ]] || die '拒绝将邮箱 Token 发送给其他主机'
            printf 'header = "Authorization: Bearer %s"\n' "$(curl_escape "$auth")"
        fi
    } >"$config" || die '无法生成私有 HTTP 配置'
    while :; do
        [[ $url != "$MAIL_API/"* ]] || sleep 0.3
        budget=45
        if (( REQUEST_DEADLINE > 0 )); then
            remaining=$((REQUEST_DEADLINE - SECONDS))
            (( remaining > 0 )) || { HTTP_ERROR='本阶段总时限已耗尽'; return 1; }
            (( remaining >= budget )) || budget=$remaining
        fi
        printf 'max-time = %s\n' "$budget" >>"$config"
        rc=0
        HTTP_UNSENT=0
        status=$(curl -q --config "$config" 2>"$WORK/http-error.log") || rc=$?
        HTTP_STATUS=$status
        if [[ $rc == 0 && $status =~ ^2[0-9][0-9]$ ]]; then return 0; fi
        HTTP_ERROR="HTTP ${status:-000} / curl $rc"
        if [[ $status == 000 ]]; then
            case "$rc" in 3|5|6|7) HTTP_UNSENT=1 ;; *) HTTP_UNSENT=0 ;; esac
        fi
        if [[ $retry != yes || $attempt -ge 3 ]]; then return 1; fi
        if [[ $rc == 0 && $status != 429 && ! $status =~ ^5[0-9][0-9]$ ]]; then return 1; fi
        retry_after=$(LC_ALL=C awk 'tolower($1)=="retry-after:" {gsub("\r", "", $2); if ($2 ~ /^[0-9]+$/) print $2}' "$WORK/response.headers" 2>/dev/null)
        if [[ $retry_after =~ ^[0-9]{1,5}$ ]]; then
            retry_after=$((10#$retry_after))
            (( retry_after <= 60 )) || { HTTP_ERROR='服务端要求较长退避，请稍后恢复运行'; return 1; }
            (( retry_after <= delay )) || delay=$retry_after
        fi
        if (( REQUEST_DEADLINE > 0 && SECONDS + delay >= REQUEST_DEADLINE )); then
            HTTP_ERROR='退避将超过本阶段总时限，请稍后恢复'; return 1
        fi
        sleep "$delay"
        attempt=$((attempt + 1)); delay=$((delay * 2))
        (( delay <= 60 )) || delay=60
    done
}

enterprise_post() {
    local path=$1 body=$2 output=$3 jar=$4 retry=${5:-no} code
    http_request POST "$CONSOLE$path" "$body" "$output" "$jar" '' "$retry" || return 1
    if ! jq -e 'type == "object" and .code == 0' "$output" >/dev/null 2>&1; then
        code=$(jq -r 'if (.code | type) == "number" then .code else "unknown" end' "$output" 2>/dev/null) || code=unknown
        HTTP_ERROR="企业接口业务错误 ${code}（未识别的认证/验证要求不会自动绕过）"
        return 1
    fi
}

get_user_info() {
    local jar=$1 output=$2
    printf '%s\n' '{"Attributes":["ent_sso","ent_cloud_identity_login","ent_wecom_login","ent_saml_login","ent_security_repo_blacklist","ent_security_access_control","ent_content_security","ent_custom_agent","allow_personal_mcp_in_team_agent","ent_enterprise_hooks","ent_enterprise_skill","ent_open_platform","ent_knowledge_base","ent_custom_model_quota","ent_department_management","ent_department_quota","ent_feishu_org_sync","ent_wecom_org_sync","product_ide","product_plugin","product_cli","product_solo","model_embed_doubao","model_embed_others","model_enterprise","model_customize","currency_pricing","ai_coding_cue","ent_limit_usage_model","ent_mcp_whitelist","ent_command_blacklist","ent_enterprise_sandbox","ent_ai_code_tracking","enable_token_pool","work_account_grant_multiplier"]}' >"$WORK/info-request.json"
    enterprise_post '/cloudide/api/v3/trae/GetUserInfo' "$WORK/info-request.json" "$output" "$jar" yes
}

account_login() {
    local credentials=$1 jar=$2 output=$3
    : >"$jar"
    jq '{Email:.email,Password:.password}' "$credentials" >"$WORK/login-request.json" || die '无法构造登录请求'
    enterprise_post "$API/account/login" "$WORK/login-request.json" "$output" "$jar" no || return 1
    jq -e '.Data.UserStatus == 1 and .Data.IsAllowLogin == true' "$output" >/dev/null 2>&1 || {
        HTTP_ERROR='账号尚未激活、无登录权限或需要额外认证'; return 1;
    }
}

url_decode() {
    local input=$1 output='' first hex char
    while [[ -n $input ]]; do
        first=${input:0:1}; input=${input:1}
        case "$first" in
            '%')
                [[ ${#input} -ge 2 ]] || return 1
                hex=${input:0:2}; input=${input:2}
                [[ $hex =~ ^[0-9A-Fa-f]{2}$ ]] || return 1
                case "$hex" in 0?|1?|7[fF]) return 1 ;; esac
                printf -v char '%b' "\\x$hex"
                output="$output$char" ;;
            '+') output="$output " ;;
            *) output="$output$first" ;;
        esac
    done
    [[ $output != *$'\r'* && $output != *$'\n'* ]] || return 1
    DECODED=$output
}

query_value() {
    local url=$1 wanted=$2 query part key value found=0
    [[ $url == *\?* && $url != *\#* ]] || return 1
    query=${url#*\?}; QUERY_VALUE=''
    while [[ -n $query ]]; do
        part=${query%%&*}
        if [[ $query == *'&'* ]]; then query=${query#*&}; else query=''; fi
        key=${part%%=*}
        url_decode "$key" || return 1
        [[ $DECODED == "$wanted" ]] || continue
        [[ $found == 0 && $part == *=* ]] || return 1
        value=${part#*=}; url_decode "$value" || return 1
        QUERY_VALUE=$DECODED; found=1
    done
    [[ $found == 1 && -n $QUERY_VALUE ]]
}

main() {
    set +x
    set -euo pipefail
    parse_args "$@"
    check_dependencies
    if [[ $DRY_RUN == 1 ]]; then
        [[ ! -e $ACCOUNTS ]] || { [[ ! -L $ACCOUNTS ]] && validate_state "$ACCOUNTS"; } || die '账号文件无效'
        local count_label=$COUNT
        [[ $COUNT != 0 ]] || count_label=自动
        log "离线预览：${COMMAND}；单阶段上限 ${count_label}。"
        if [[ $COMMAND != login ]]; then
            log '实际运行会检查未完成成员，确认移除后改用新邮箱，并核对 Full 配额。'
        fi
        if [[ $COMMAND != activate ]]; then
            log '导入时可能安装 Magpie/插件/运行时，并临时调整链接显示设置。'
        fi
        log '未联网、未创建文件、未使用 HAR 凭据。'
        return
    fi
    init_workspace
    case "$COMMAND" in
        activate) activate_accounts ;;
        login) login_accounts ;;
        all) activate_accounts; login_accounts ;;
    esac
    log "账号与进度已保存到：${ACCOUNTS}（敏感明文，请妥善保管）"
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/activate-seats.sh" || return 1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/magpie-login.sh" || return 1

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
