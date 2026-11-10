#!/bin/bash

resolve_magpie_auth() {
    local executable target dir loops=0 base
    [[ -z $MAGPIE_AUTH ]] || return 0
    executable=$(command -v magpie) || die '找不到 Magpie'
    while [[ -L $executable ]]; do
        loops=$((loops + 1)); [[ $loops -lt 40 ]] || die 'Magpie 可执行文件符号链接循环'
        target=$(readlink "$executable") || die '无法解析 Magpie 路径'
        case "$target" in /*) executable=$target ;; *) executable="$(dirname "$executable")/$target" ;; esac
    done
    dir=$(cd "$(dirname "$executable")" && pwd -P) || die '无法定位 Magpie 安装目录'
    base=$dir
    case "$dir" in */Magpie.app/Contents/MacOS) base=${dir%/Magpie.app/Contents/MacOS} ;; esac
    if [[ -e $base/.portable && ! -d $base/.portable ]]; then
        MAGPIE_AUTH="$base/data/plugin-auth.json"
    elif [[ -d $base/data ]]; then
        die '检测到可能的 Magpie 便携目录，请用 --magpie-auth-file 指定实际凭据文件以避免读错账号库'
    elif [[ ${XDG_CONFIG_HOME:-} == /* ]]; then
        MAGPIE_AUTH="$XDG_CONFIG_HOME/magpie/plugin-auth.json"
    else
        MAGPIE_AUTH="$HOME/.config/magpie/plugin-auth.json"
    fi
}

magpie_identities() {
    local output=$1
    if [[ ! -e $MAGPIE_AUTH ]]; then printf '[]\n' >"$output"; return; fi
    [[ -f $MAGPIE_AUTH && ! -L $MAGPIE_AUTH && -O $MAGPIE_AUTH ]] || die 'Magpie 账号库不是当前用户持有的普通文件'
    jq -e 'type == "object"' "$MAGPIE_AUTH" >/dev/null 2>&1 || die 'Magpie 账号库损坏；不会当作空库或覆盖'
    jq 'to_entries | map(select(.key == "trae-cn" or (.key | startswith("trae-cn#")))) |
        map({key:.key,uid:(.value.uid // ""),accountId:(.value.accountId // "")})' \
        "$MAGPIE_AUTH" >"$output" || die '无法核对 Magpie 账号身份'
}

setup_magpie() {
    local spec old dir
    if ! command -v magpie >/dev/null 2>&1; then
        log '未安装 Magpie，正在运行官方安装程序…'
        if ! (set -o pipefail; curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 https://usemagpie.ai/install.sh | sh) >"$WORK/install.log" 2>&1; then
            die 'Magpie 官方安装失败，请手动安装后重试'
        fi
        PATH="$HOME/.local/bin:$HOME/.magpie/bin:$PATH"; export PATH
        hash -r
        command -v magpie >/dev/null 2>&1 || die '安装后 PATH 中仍找不到 magpie，请按安装说明更新 PATH'
    fi
    resolve_magpie_auth
    [[ $MAGPIE_AUTH != "$ACCOUNTS" ]] || die '账号状态文件不能覆盖 Magpie 凭据库'
    dir=$(dirname "$MAGPIE_AUTH")
    mkdir -p -- "$dir" || die '无法访问 Magpie 配置目录'
    if ! mkdir -- "$dir/.trae-onboard.lock" 2>/dev/null; then
        die 'Magpie 已被另一批处理锁定；异常退出时请核对锁目录中的原设置后手动恢复'
    fi
    MAGPIE_LOCK="$dir/.trae-onboard.lock"
    printf '%s\n' "$$" >"$MAGPIE_LOCK/pid"
    magpie plugin list --json >"$WORK/plugins.json" 2>"$WORK/magpie-error.log" || die '无法查询 Magpie 插件'
    jq -e 'if type == "array" then true else .plugins | type == "array" end' \
        "$WORK/plugins.json" >/dev/null || die 'Magpie 插件列表格式不受支持'
    spec=$(jq -r --arg plugin "$PLUGIN" '(if type == "array" then . else .plugins end) |
        [.[] | select(.spec == $plugin or (.spec | startswith($plugin + "@"))) | .spec][0] // ""' "$WORK/plugins.json") || die '无法识别 TRAE 插件'
    if [[ -z $spec ]]; then
        log '正在安装 Magpie TRAE 插件及其运行时…'
        magpie plugin install "$PLUGIN" >"$WORK/plugin-install.log" 2>&1 || die 'TRAE 插件安装失败'
    elif jq -e --arg spec "$spec" '(if type == "array" then . else .plugins end) | any(.[]; .spec == $spec and .off == true)' \
        "$WORK/plugins.json" >/dev/null; then
        magpie plugin on "$spec" >"$WORK/plugin-enable.log" 2>&1 || die 'TRAE 插件启用失败'
    fi
    magpie settings get signInLinkOnly --json >"$MAGPIE_LOCK/sign-in-setting.json" 2>"$WORK/magpie-error.log" || die '无法读取 Magpie 链接设置'
    old=$(jq -er 'if type == "boolean" then tostring else error("invalid setting") end' "$MAGPIE_LOCK/sign-in-setting.json") || die 'Magpie 设置格式变化'
    if [[ $old == true ]]; then OLD_LINK_SETTING=on; else OLD_LINK_SETTING=off; fi
    SETTINGS_CHANGED=1
    magpie settings set signInLinkOnly on >"$WORK/setting.log" 2>&1 || die '无法设置 Magpie 仅显示授权链接'
}

extract_authorization() {
    local logfile=$1 output=$2
    jq -Rrs 'gsub("\u001b\\[[0-?]*[ -/]*[@-~]"; "") | split("\n") |
        map(gsub("^\\s+|\\s+$"; "")) |
        map(select(startswith("https://www.trae.cn/authorization?"))) | unique |
        if length == 1 then .[0] else empty end' "$logfile" >"$output" || return 1
    [[ -s $output ]]
}

validate_authorization() {
    local url=$1 callback port device value
    [[ $url == 'https://www.trae.cn/authorization?'* ]] || die '不是预期的 TRAE 授权地址'
    query_value "$url" auth_from && [[ $QUERY_VALUE == solo ]] || die '不支持的 auth_from'
    query_value "$url" auth_type && [[ $QUERY_VALUE == local ]] || die '不支持的 auth_type'
    query_value "$url" client_id && [[ $QUERY_VALUE == ono9krqynydwx5 ]] || die '授权 client_id 与已验证的插件不匹配'
    query_value "$url" device_id || die '授权地址缺少 device_id'
    device=$QUERY_VALUE
    [[ $device =~ ^[0-9]{16}$ ]] || die '设备 ID 格式变化'
    query_value "$url" x_device_id && [[ $QUERY_VALUE == "$device" ]] || die '授权设备 ID 不一致'
    query_value "$url" auth_callback_url || die '授权地址缺少本地回调'
    callback=$QUERY_VALUE
    [[ $callback =~ ^http://127\.0\.0\.1:([0-9]{1,5})/authorize$ ]] || die '拒绝非本机或异常回调地址'
    port=${BASH_REMATCH[1]}
    [[ $port != 0* ]] || die '回调端口格式异常'
    (( port >= 1024 && port <= 65535 )) || die '回调端口越界'
    printf '%s' "$callback" >"$WORK/callback-base"
    printf '%s' "$device" >"$WORK/device-id"
}

wait_magpie() {
    local deadline=$1 rc=0
    while kill -0 "$LOGIN_PID" 2>/dev/null; do
        if (( SECONDS >= deadline )); then die 'Magpie 授权等待超时，进度已保留'; fi
        sleep 1
    done
    wait "$LOGIN_PID" || rc=$?
    stop_child "$LOGIN_PID"
    LOGIN_PID=''
    [[ $rc == 0 ]] || die 'Magpie 登录进程失败；未将账号标记为导入成功'
}

record_magpie_success() {
    local email=$1 uid=$2 identities=$3
    jq --arg uid "$uid" --slurpfile ids "$identities" \
        '{user_id:$uid,tenant_id:.Data.UserInfo.TenantID,magpie_status:"signed_in",
          magpie_key:([$ids[0][] | select(.uid == $uid) | .key][0])}' \
        "$WORK/user-info.json" >"$WORK/patch.json" || die '无法生成导入状态'
    state_update "$email" "$WORK/patch.json"
}

login_one() {
    local email=$1 deadline url uid expected saved_tenant native_tenant present=false
    local REQUEST_DEADLINE=$((SECONDS + LOGIN_TIMEOUT))
    deadline=$REQUEST_DEADLINE
    LOGIN_CHANGED=0
    load_account "$email"
    expected=$(jq -r '.user_id // ""' "$WORK/account.json")
    if [[ $FORCE_LOGIN == 0 && -n $expected ]] && jq -e '.magpie_status == "signed_in"' "$WORK/account.json" >/dev/null; then
        magpie_identities "$WORK/identities-before.json"
        if jq -e --arg uid "$expected" 'any(.[]; .uid == $uid)' "$WORK/identities-before.json" >/dev/null; then
            log '跳过已确认导入的账号（--force-login 可重新授权）。'
            return
        fi
    fi
    account_login "$WORK/account.json" "$WORK/user.cookies" "$WORK/user-login.json" || die "TRAE 账号登录失败：$HTTP_ERROR"
    get_user_info "$WORK/user.cookies" "$WORK/user-info.json" || die "读取登录身份失败：$HTTP_ERROR"
    saved_tenant=$(jq -r '.tenant_id // ""' "$WORK/account.json")
    native_tenant=$(jq -r '.tenant_id // ""' "$ACCOUNTS")
    jq -e --arg email "$email" --arg uid "$expected" --arg tenant "$saved_tenant" --arg native "$native_tenant" --arg host "$CONSOLE" '
        (.Data.UserInfo | (.Email | ascii_downcase) == $email and .UserStatus == 1
            and (.UserID | type == "string" and length > 0) and (.TenantID | type == "string" and length > 0)
            and ($uid == "" or .UserID == $uid) and ($tenant == "" or .TenantID == $tenant)
            and ($native == "" or .TenantID == $native))
        and .HostInfo.Api == $host and .HostInfo.Console == $host and .HostInfo.Core == $host
    ' "$WORK/user-info.json" >/dev/null || die 'TRAE 账号身份、企业或主机与预期不一致'
    uid=$(jq -r '.Data.UserInfo.UserID' "$WORK/user-info.json")
    magpie_identities "$WORK/identities-before.json"
    if jq -e --arg uid "$uid" 'any(.[]; .uid == $uid)' "$WORK/identities-before.json" >/dev/null; then present=true; fi
    if [[ $FORCE_LOGIN == 0 && $present == true ]]; then
        if jq -e '.magpie_status == "signed_in"' "$WORK/account.json" >/dev/null; then
            log '跳过已确认导入的账号（--force-login 可重新授权）。'
            return
        fi
        if jq -e --arg uid "$uid" '.magpie_status == "authorizing" and .magpie_uid_present_before == false and .magpie_target_uid == $uid' \
            "$WORK/account.json" >/dev/null; then
            record_magpie_success "$email" "$uid" "$WORK/identities-before.json"
            LOGIN_CHANGED=1
            log '已对账确认上次新增的 Magpie UID，恢复完成记录。'
            return
        fi
    fi
    jq -n --arg uid "$uid" --argjson present "$present" \
        '{magpie_status:"authorizing",magpie_target_uid:$uid,magpie_uid_present_before:$present}' >"$WORK/patch.json"
    state_update "$email" "$WORK/patch.json"
    log '正在通过本机回调完成 Magpie 授权…'
    start_child LOGIN_PID "$WORK/magpie-login.log" magpie plugin login trae-cn
    while ! extract_authorization "$WORK/magpie-login.log" "$WORK/authorization-url"; do
        kill -0 "$LOGIN_PID" 2>/dev/null || { stop_child "$LOGIN_PID"; LOGIN_PID=''; die 'Magpie 未生成可识别的授权链接'; }
        (( SECONDS < deadline )) || die '等待 Magpie 授权链接超时'
        sleep 1
    done
    IFS= read -r url <"$WORK/authorization-url" || die '授权链接读取失败'
    validate_authorization "$url"
    jq -n --rawfile device "$WORK/device-id" '{DID:$device,SourceType:5}' >"$WORK/refresh-request.json"
    enterprise_post '/cloudide/api/v3/trae/oauth/GetRefreshToken' "$WORK/refresh-request.json" "$WORK/refresh-result.json" "$WORK/user.cookies" no || die "获取刷新凭据失败：$HTTP_ERROR"
    jq -e '.Data.RefreshToken | type == "string" and length > 0' "$WORK/refresh-result.json" >/dev/null || die '刷新凭据响应缺失'
    jq '{RefreshToken:.Data.RefreshToken}' "$WORK/refresh-result.json" >"$WORK/exchange-request.json"
    enterprise_post '/cloudide/api/v3/trae/oauth/ExchangeToken' "$WORK/exchange-request.json" "$WORK/exchange-result.json" "$WORK/user.cookies" no || die "交换授权凭据失败：$HTTP_ERROR"
    jq -e '.Data | (.Token | type == "string" and length > 0) and (.RefreshToken | type == "string" and length > 0) and (.TokenExpireAt != null)' \
        "$WORK/exchange-result.json" >/dev/null || die '授权凭据响应格式变化'
    jq -n --slurpfile user "$WORK/user-info.json" --slurpfile token "$WORK/exchange-result.json" \
        --rawfile callback "$WORK/callback-base" --arg host "$CONSOLE" '
        $user[0].Data.UserInfo as $u |
        {UserID:$u.UserID,ScreenName:($u.Name // $u.Email // $u.UserID),Host:$host,AuthHost:$host,isEnterprise:true} as $info |
        $callback + "?" + ({userJwt:($token[0].Data | tojson),userInfo:($info | tojson),host:$host,authHost:$host,
            consoleHost:$host,coreHost:$host,clientId:"ono9krqynydwx5"} | to_entries |
            map((.key | @uri) + "=" + (.value | @uri)) | join("&"))
    ' -r >"$WORK/callback-url" || die '无法编码 Magpie 回调'
    (( SECONDS < deadline )) || die '企业授权超过本次登录时限'
    IFS= read -r url <"$WORK/callback-url" || die '无法读取本地回调'
    http_request GET "$url" '' "$WORK/callback-result" '' '' no || die "本地回调失败：$HTTP_ERROR"
    wait_magpie "$deadline"
    magpie_identities "$WORK/identities-after.json"
    jq -e --arg uid "$uid" 'any(.[]; .uid == $uid)' "$WORK/identities-after.json" >/dev/null || die 'Magpie 未保存目标 UID；不会标记为成功'
    record_magpie_success "$email" "$uid" "$WORK/identities-after.json"
    LOGIN_CHANGED=1
    if [[ $present == true ]]; then
        log '授权流程已完成且目标 UID 存在；无法确认已有凭据是否已更新。'
    else
        log '已核对目标 UID，Magpie 导入成功。'
    fi
}

login_accounts() {
    local email count=0
    jq -r '.accounts[] | select(.status == "active") | .email' "$ACCOUNTS" >"$WORK/login-emails"
    [[ -s $WORK/login-emails ]] || { log '没有已激活账号可导入。'; return; }
    setup_magpie
    while IFS= read -r email; do
        [[ $COUNT == 0 || $count -lt $COUNT ]] || break
        login_one "$email"
        count=$((count + LOGIN_CHANGED))
    done <"$WORK/login-emails"
    log "本次导入或恢复 $count 个账号；已导入账号不占计数上限。模型调用与长期自动续期未验证。"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/trae-onboard.sh" || exit 1
    main login "$@"
fi
