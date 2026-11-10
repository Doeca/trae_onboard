#!/bin/bash

admin_login() {
    local email password
    if [[ -n $ADMIN_FILE ]]; then
        private_file "$ADMIN_FILE"
        jq -e '(.email | type == "string" and length > 0) and (.password | type == "string" and length > 0)' \
            "$ADMIN_FILE" >/dev/null 2>&1 || die '管理员文件必须包含 email 和 password'
        jq '{email,password}' "$ADMIN_FILE" >"$WORK/admin.json" || die '无法读取管理员凭据'
    else
        [[ -r /dev/tty && -w /dev/tty ]] || die '无交互终端，请使用 --admin-file'
        printf '管理员邮箱：' >/dev/tty
        IFS= read -r email </dev/tty || die '无法读取管理员邮箱'
        printf '管理员密码：' >/dev/tty
        IFS= read -r -s password </dev/tty || die '无法读取管理员密码'
        printf '\n' >/dev/tty
        [[ -n $email && -n $password ]] || die '管理员邮箱或密码为空'
        printf '%s' "$email" >"$WORK/admin-email"
        printf '%s' "$password" >"$WORK/admin-password"
        unset password
        jq -n --rawfile email "$WORK/admin-email" --rawfile password "$WORK/admin-password" \
            '{email:$email,password:$password}' >"$WORK/admin.json" || die '无法构造管理员凭据'
    fi
    account_login "$WORK/admin.json" "$WORK/admin.cookies" "$WORK/admin-login.json" || die "管理员登录失败：$HTTP_ERROR"
    get_user_info "$WORK/admin.cookies" "$WORK/admin-info.json" || die "无法读取企业信息：$HTTP_ERROR"
    TENANT=$(jq -er '.Data.UserInfo.TenantID | select(type == "string" and length > 0)' "$WORK/admin-info.json") || die '缺少字符串类型企业 ID'
    local saved tmp
    saved=$(jq -r '.tenant_id // ""' "$ACCOUNTS") || die '无法读取状态企业 ID'
    [[ -z $saved || $saved == "$TENANT" ]] || die '管理员企业与状态文件不匹配'
    tmp=$(mktemp "$ACCOUNTS.tmp.XXXXXX") || die '无法创建状态临时文件'
    jq --arg tenant "$TENANT" '.tenant_id=$tenant' "$ACCOUNTS" >"$tmp" || die '无法保存企业 ID'
    mv -f -- "$tmp" "$ACCOUNTS" || die '无法更新状态文件'
    printf '{}\n' >"$WORK/empty.json"
    enterprise_post "$API/config/get_sub_plan" "$WORK/empty.json" "$WORK/plan.json" "$WORK/admin.cookies" yes || die "无法读取管理员订阅信息：$HTTP_ERROR"
    printf '{"CountMode":"subtree","IncludeMemberCount":false}\n' >"$WORK/dept-request.json"
    enterprise_post "$API/department/list" "$WORK/dept-request.json" "$WORK/depts.json" "$WORK/admin.cookies" yes || die "无法读取部门：$HTTP_ERROR"
    ROOT_DEPARTMENT=$(jq -er '.RootDepartmentID | select(type == "string" and length > 0)' "$WORK/depts.json") || die '企业根部门信息缺失'
    [[ -n $DEPARTMENT ]] || DEPARTMENT=$ROOT_DEPARTMENT
    jq -e --arg id "$DEPARTMENT" '.RootDepartmentID == $id or any(.Departments[]; .DepartmentID == $id)' \
        "$WORK/depts.json" >/dev/null || die '指定部门不属于当前企业'
}

snapshot() {
    local page=1 seen=0 total=-1 this_total count next
    get_user_info "$WORK/admin.cookies" "$WORK/admin-info.json" || die "读取实时配额失败：$HTTP_ERROR"
    jq -e --arg tenant "$TENANT" '
        .Data.UserInfo.TenantID == $tenant and
        (.AccountQuotaSummary.Full | .TotalQuota as $t | .OccupiedCount as $o | .ActiveCount as $a |
            all([$t,$o,$a][]; type == "number" and . >= 0 and floor == .) and $o <= $t and $a <= $o)
    ' "$WORK/admin-info.json" >/dev/null || die 'Full 配额缺失、不一致或企业发生变化'
    TOTAL_SEATS=$(jq -r '.AccountQuotaSummary.Full.TotalQuota' "$WORK/admin-info.json")
    OCCUPIED=$(jq -r '.AccountQuotaSummary.Full.OccupiedCount' "$WORK/admin-info.json")
    printf '[]\n' >"$WORK/members.json"
    while :; do
        jq -n --arg id "$ROOT_DEPARTMENT" --argjson page "$page" \
            '{DepartmentID:$id,IncludeSubtree:true,Statuses:[1,9,2,4,3,11],Page:$page,PageSize:100}' >"$WORK/member-request.json"
        enterprise_post "$API/department/member_list" "$WORK/member-request.json" "$WORK/member-page.json" "$WORK/admin.cookies" yes || die "读取成员列表失败：$HTTP_ERROR"
        jq -e '(.Data | type == "array") and (.Total | type == "number" and . >= 0 and floor == .)' \
            "$WORK/member-page.json" >/dev/null || die '成员分页响应格式变化'
        this_total=$(jq -r '.Total' "$WORK/member-page.json")
        [[ $total == -1 ]] && total=$this_total
        [[ $total == "$this_total" ]] || die '分页期间成员数量变化，请重新运行以重新核对'
        count=$(jq '.Data | length' "$WORK/member-page.json")
        next="$WORK/members-next.json"
        jq --slurpfile page "$WORK/member-page.json" '. + $page[0].Data' "$WORK/members.json" >"$next" || die '无法汇总成员'
        mv -f "$next" "$WORK/members.json" || die '无法更新成员快照'
        seen=$((seen + count))
        [[ $seen -le $total ]] || die '成员分页数量不一致'
        [[ $seen -ne $total ]] || break
        [[ $count -gt 0 && $page -lt 10000 ]] || die '成员分页未前进'
        page=$((page + 1))
    done
    jq -e '
        all(.[]; (.UserInfo.Email | type == "string") and (.UserInfo.AccountType | type == "number"))
        and (([.[].UserInfo.Email | ascii_downcase] | unique | length) == length)
        and all(.[] | select(.UserInfo.AccountType == 1); .UserInfo.UserStatus == 1 or .UserInfo.UserStatus == 2)
    ' "$WORK/members.json" >/dev/null || die '成员有未知状态、重复条目或缺失类型；停止以避免误算席位'
    PENDING=$(jq '[.[] | select(.UserInfo.AccountType == 1 and .UserInfo.UserStatus == 2)] | length' "$WORK/members.json")
    FREE_SEATS=$((TOTAL_SEATS - OCCUPIED - PENDING))
}

assert_capacity() {
    (( FREE_SEATS >= 0 )) || die '待邀请人数超过空闲席位；停止创建账号，请先核查现有邀请'
}

member_status() {
    jq -r --arg email "$1" '[.[] | select((.UserInfo.Email | ascii_downcase) == $email)] |
        if length == 0 then "absent" else .[0].UserInfo.UserStatus | tostring end' "$WORK/members.json"
}

assert_room() {
    local email=$1 status room
    assert_capacity
    status=$(member_status "$email") || die '无法核对成员'
    if [[ $status != absent ]]; then
        jq -e --arg email "$email" 'any(.[]; (.UserInfo.Email | ascii_downcase) == $email and .UserInfo.AccountType == 1)' \
            "$WORK/members.json" >/dev/null || die '该邮箱已属于其他席位类型，不能占用 Full 预留'
    fi
    room=$FREE_SEATS
    [[ $status != 2 ]] || room=$((room + 1))
    [[ $status == 1 || $room -gt 0 ]] || die '没有可供当前账号注册的 Full 席位，已保留进度'
}

random_hex() {
    RANDOM_HEX=$(openssl rand -hex "$1") || die '安全随机数生成失败，未创建账号'
    [[ $RANDOM_HEX =~ ^[0-9a-f]+$ && ${#RANDOM_HEX} == $(($1 * 2)) ]] || die '安全随机数输出不符合预期'
}

prepare_account() {
    local domain address tmp page=1 count seen=0 total=0 next
    log '正在创建下一席位的临时邮箱与本地凭据…'
    : >"$WORK/seen-domains"
    while :; do
        http_request GET "$MAIL_API/domains?page=$page" '' "$WORK/domains.json" '' '' yes || die "获取 Mail.tm 域名失败：$HTTP_ERROR"
        jq -e 'type == "array" or (type == "object" and (."hydra:member" | type == "array"))' \
            "$WORK/domains.json" >/dev/null || die 'Mail.tm 域名响应格式变化'
        domain=$(jq -r '(if type == "array" then . else ."hydra:member" end) |
            [.[] | select(.isActive == true and .isPrivate == false) | .domain |
            select(type == "string" and test("^[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$") and (test("[\\x00-\\x20\\x7f]") | not))][0] // ""' \
            "$WORK/domains.json") || die 'Mail.tm 域名响应格式变化'
        [[ -z $domain ]] || break
        # 接口不保证提供 hydra:view；用去重后的新增数量判断分页是否真的前进。
        jq -r '(if type == "array" then . else ."hydra:member" end)[].domain |
            select(type == "string")' "$WORK/domains.json" >"$WORK/domain-page"
        count=$(wc -l <"$WORK/domain-page" | tr -d ' ')
        sort -u "$WORK/seen-domains" "$WORK/domain-page" >"$WORK/domain-union"
        total=$(wc -l <"$WORK/domain-union" | tr -d ' ')
        mv -f "$WORK/domain-union" "$WORK/seen-domains"
        # 纯 JSON 数组没有 hydra:view，只能靠"本页非空且带来新域名"继续。
        next=$(jq -r --argjson total "$total" '
            if type == "array" then (if length > 0 then "more" else "" end)
            elif ((."hydra:view"."hydra:next" // "") | length) > 0 then "more"
            elif ((."hydra:totalItems" | type) == "number") and ."hydra:totalItems" > $total then "more"
            else "" end' "$WORK/domains.json")
        [[ -n $next && $count -gt 0 && $total -gt $seen ]] || die 'Mail.tm 没有可用公共域名'
        seen=$total
        page=$((page + 1)); (( page <= 1000 )) || die 'Mail.tm 域名分页过多'
    done
    random_hex 10; address="trae${RANDOM_HEX}@$domain"
    random_hex 12; printf 'Aa9!%s' "$RANDOM_HEX" >"$WORK/new-password"
    random_hex 12; printf 'Mb7!%s' "$RANDOM_HEX" >"$WORK/new-mailbox-password"
    jq -n --arg email "$address" --arg tenant "$TENANT" --rawfile password "$WORK/new-password" \
        --rawfile mailbox_password "$WORK/new-mailbox-password" \
        '{email:$email,password:$password,mailbox_password:$mailbox_password,tenant_id:$tenant,status:"prepared",magpie_status:"pending"}' \
        >"$WORK/new-account.json" || die '无法生成账号记录'
    tmp=$(mktemp "$ACCOUNTS.tmp.XXXXXX") || die '无法创建状态临时文件'
    jq --slurpfile account "$WORK/new-account.json" '.accounts += $account' "$ACCOUNTS" >"$tmp" || die '无法记录新账号'
    mv -f -- "$tmp" "$ACCOUNTS" || die '无法提交新账号状态'
    NEW_EMAIL=$address
}

mail_token() {
    jq '{address:.email,password:.mailbox_password}' "$WORK/account.json" >"$WORK/mail-request.json" || die '无法生成邮箱请求'
    http_request POST "$MAIL_API/token" "$WORK/mail-request.json" "$WORK/mail-token.json" '' '' no || return 1
    jq -er '.token | select(type == "string" and length > 0 and (test("[\\x00-\\x20]") | not))' \
        "$WORK/mail-token.json" >"$WORK/mail-token" || { HTTP_ERROR='邮箱 Token 响应无效'; return 1; }
}

ensure_mailbox() {
    local email=$1 stage attempting
    load_account "$email"
    stage=$(jq -r '.status' "$WORK/account.json")
    attempting=$(jq -r '.mailbox_create_attempted // false' "$WORK/account.json")
    if [[ $stage != prepared || $attempting == true ]]; then
        if mail_token; then
            if [[ $stage == prepared ]]; then set_status "$email" mailbox_created; fi
            return
        fi
        if [[ $stage != prepared || $RETRY_UNSUBMITTED != "$email" ]]; then
            die "无法恢复邮箱；不会重复开户：${HTTP_ERROR}。确认上次未开户后可使用 --retry-unsubmitted"
        fi
        log '按显式的未提交确认重试邮箱开户。'
    fi
    printf '{"mailbox_create_attempted":true}\n' >"$WORK/patch.json"
    state_update "$email" "$WORK/patch.json"
    jq '{address:.email,password:.mailbox_password}' "$WORK/account.json" >"$WORK/mail-request.json"
    if ! http_request POST "$MAIL_API/accounts" "$WORK/mail-request.json" "$WORK/mail-created.json" '' '' no; then
        if [[ $HTTP_UNSENT == 1 ]]; then
            printf '{"mailbox_create_attempted":false}\n' >"$WORK/patch.json"
            state_update "$email" "$WORK/patch.json"
            die '邮箱开户在建立连接前失败；下次运行可安全重试'
        fi
        mail_token || die '邮箱开户结果不确定且无法认证；已保留凭据，不会自动重建。确认未生效后可用 --retry-unsubmitted'
    fi
    mail_token || die "邮箱认证失败：$HTTP_ERROR"
    set_status "$email" mailbox_created
}

extract_invite_codes() {
    local message=$1 output=$2 url
    : >"$output"
    jq -r '[.text // "", ((.html // []) | if type == "array" then .[] else . end)][] |
        gsub("&amp;|&#0*38;|&#x0*26;"; "&") |
        scan("https://console\\.enterprise\\.trae\\.cn/invite-email\\?[^\\s<>\"\\x27]+")' \
        "$message" >"$WORK/invite-urls" 2>/dev/null || return 1
    while IFS= read -r url; do
        if query_value "$url" code; then printf '%s\n' "$QUERY_VALUE" >>"$output"; fi
    done <"$WORK/invite-urls"
}

wait_invitation() {
    local email=$1 deadline=$((SECONDS + MAIL_TIMEOUT)) page id code next pause
    local count seen before after
    local REQUEST_DEADLINE=$deadline
    log "正在等待有效邀请邮件（最多 ${MAIL_TIMEOUT} 秒）…"
    while (( SECONDS < deadline )); do
        page=1
        : >"$WORK/seen-message-ids"
        while :; do
            (( SECONDS < deadline )) || break
            http_request GET "$MAIL_API/messages?page=$page" '' "$WORK/messages.json" '' "$WORK/mail-token" yes || die "收件箱读取失败：$HTTP_ERROR"
            jq -e 'type == "array" or (type == "object" and (."hydra:member" | type == "array"))' \
                "$WORK/messages.json" >/dev/null || die '收件箱响应格式变化'
            jq -r '(if type == "array" then . else ."hydra:member" end)[].id |
                select(type == "string" and test("^[A-Za-z0-9_-]+$"))' \
                "$WORK/messages.json" >"$WORK/message-ids" || die '无法读取邮件 ID'
            count=$(wc -l <"$WORK/message-ids" | tr -d ' ')
            before=$(sort -u "$WORK/seen-message-ids" | wc -l | tr -d ' ')
            sort -u "$WORK/message-ids" >>"$WORK/seen-message-ids"
            after=$(sort -u "$WORK/seen-message-ids" | wc -l | tr -d ' ')
            seen=$after
            # 接口不再稳定提供 hydra:view，用 hydra:next / hydra:totalItems / 裸数组非空判断是否还有下一页。
            next=$(jq -r --argjson seen "$seen" '
                if type == "array" then (if length > 0 then "more" else "" end)
                elif ((."hydra:view"."hydra:next" // "") | length) > 0 then "more"
                elif ((."hydra:totalItems" | type) == "number") and ."hydra:totalItems" > $seen then "more"
                else "" end' "$WORK/messages.json")
            while IFS= read -r id; do
                (( SECONDS < deadline )) || break
                http_request GET "$MAIL_API/messages/$id" '' "$WORK/message.json" '' "$WORK/mail-token" yes || die "读取邮件失败：$HTTP_ERROR"
                jq -e --arg email "$email" 'any(.to[]?; (.address | ascii_downcase) == $email)' \
                    "$WORK/message.json" >/dev/null || continue
                extract_invite_codes "$WORK/message.json" "$WORK/invite-codes" || die '无法解析邀请邮件'
                while IFS= read -r code; do
                    (( SECONDS < deadline )) || break
                    printf '%s' "$code" >"$WORK/link-code"
                    jq -n --rawfile code "$WORK/link-code" '{CodeType:1,LinkCode:$code}' >"$WORK/code-request.json"
                    if enterprise_post "$API/account/get_code_info" "$WORK/code-request.json" "$WORK/code-info.json" "$WORK/user.cookies" yes; then
                        if jq -e --arg email "$email" --arg tenant "$TENANT" \
                            '(.Data.Email | ascii_downcase) == $email and .Data.TenantID == $tenant and .Data.AccountType == 1' \
                            "$WORK/code-info.json" >/dev/null; then return 0; fi
                    fi
                done <"$WORK/invite-codes"
            done <"$WORK/message-ids"
            [[ -n $next && $count -gt 0 && $after -gt $before ]] || break
            page=$((page + 1))
            [[ $page -le 1000 ]] || die '邮件分页过多，请检查邮箱'
        done
        pause=$((deadline - SECONDS))
        (( pause > 0 )) || break
        (( pause <= POLL_INTERVAL )) || pause=$POLL_INTERVAL
        sleep "$pause"
    done
    die '等待有效邀请邮件超时；邮箱及邀请状态已保留，下次运行继续收信'
}

verify_active() {
    local email=$1 uid
    load_account "$email"
    account_login "$WORK/account.json" "$WORK/user.cookies" "$WORK/user-login.json" || return 1
    get_user_info "$WORK/user.cookies" "$WORK/user-info.json" || return 1
    jq -e --arg email "$email" --arg tenant "$TENANT" '
        .Data.UserInfo | (.Email | ascii_downcase) == $email and .TenantID == $tenant
        and .AccountType == 1 and .UserStatus == 1 and (.UserID | type == "string" and length > 0)
    ' "$WORK/user-info.json" >/dev/null || { HTTP_ERROR='注册后身份/企业/状态不匹配'; return 1; }
    uid=$(jq -r '.Data.UserInfo.UserID' "$WORK/user-info.json")
    snapshot
    jq -e --arg email "$email" --arg uid "$uid" 'any(.[];
        (.UserInfo.Email | ascii_downcase) == $email and .UserInfo.UserID == $uid
        and .UserInfo.AccountType == 1 and .UserInfo.UserStatus == 1)' "$WORK/members.json" >/dev/null || {
        HTTP_ERROR='企业成员列表尚未确认入席，请稍后恢复'; return 1;
    }
    (( OCCUPIED > 0 )) || { HTTP_ERROR='席位占用未确认'; return 1; }
    jq -n --arg uid "$uid" --arg tenant "$TENANT" --argjson occupied "$OCCUPIED" \
        '{status:"active",user_id:$uid,tenant_id:$tenant,verified_occupied_seats:$occupied}' >"$WORK/patch.json"
    state_update "$email" "$WORK/patch.json"
}

activate_account() {
    local email=$1 stage remote
    load_account "$email"
    stage=$(jq -r '.status' "$WORK/account.json")
    snapshot
    remote=$(member_status "$email")
    if [[ $remote == 1 || $stage == register_submitting ]]; then
        if verify_active "$email"; then return; fi
        if [[ $remote == 2 && $stage == register_submitting && $RETRY_UNSUBMITTED == "$email" ]]; then
            log '按显式的未提交确认重新检查邀请并注册。'
            set_status "$email" invited
        elif [[ $remote == absent ]]; then
            die '远端成员不存在，不会重复注册；请先在控制台核查并处理该账号'
        else
            die "无法确认上次注册结果；不会重复注册：${HTTP_ERROR}。确认未生效后可用 --retry-unsubmitted"
        fi
    fi
    assert_room "$email"
    ensure_mailbox "$email"
    load_account "$email"
    stage=$(jq -r '.status' "$WORK/account.json")
    if [[ $stage == invite_submitting && $remote == absent && $RETRY_UNSUBMITTED == "$email" ]]; then
        log '按显式的未提交确认重新核对并发送邀请。'
        set_status "$email" mailbox_created
        stage=mailbox_created
    fi
    if [[ $remote == 2 ]]; then
        set_status "$email" invited
    elif [[ $stage == invite_submitting ]]; then
        die '邀请结果不明确且当前成员列表没有该账号；不会盲目重发，确认未生效后可用 --retry-unsubmitted'
    elif [[ $stage == invited ]]; then
        die '之前确认的邀请在成员列表中消失；请先在控制台核查并处理该账号'
    else
        snapshot
        remote=$(member_status "$email")
        [[ $remote == absent ]] || die '邀请前成员状态变化，请重新运行以核对'
        assert_room "$email"
        jq --arg department "$DEPARTMENT" '{Members:[{Email:.email,Name:(.email | split("@")[0]),RoleID:3,AccountType:1,DepartmentIDs:[$department]}],SendInvite:true}' \
            "$WORK/account.json" >"$WORK/invite-request.json" || die '无法生成邀请请求'
        set_status "$email" invite_submitting
        if ! enterprise_post "$API/account/member/create" "$WORK/invite-request.json" "$WORK/invite-result.json" "$WORK/admin.cookies" no; then
            if [[ $HTTP_UNSENT == 1 ]]; then
                set_status "$email" mailbox_created
                die '邀请在建立连接前失败；下次运行可安全重试'
            fi
            snapshot
            [[ $(member_status "$email") == 2 ]] || die '邀请结果不确定；进度已保留，请核对控制台后恢复'
        else
            jq -e '.SuccessCount == 1 and (.Failures | type == "array" and length == 0)' \
                "$WORK/invite-result.json" >/dev/null || die '邀请存在业务失败项；停止，避免重复发送'
        fi
        set_status "$email" invited
    fi
    : >"$WORK/user.cookies"
    wait_invitation "$email"
    snapshot
    if [[ $(member_status "$email") == 1 ]]; then
        verify_active "$email" || die "成员已变化，但无法确认登录身份：$HTTP_ERROR"
        return
    fi
    assert_room "$email"
    load_account "$email"
    jq --rawfile code "$WORK/link-code" '{Email:.email,Password:.password,Name:(.email | split("@")[0]),SendEmailType:1,Code:$code}' \
        "$WORK/account.json" >"$WORK/register-request.json" || die '无法生成注册请求'
    set_status "$email" register_submitting
    if ! enterprise_post "$API/account/register" "$WORK/register-request.json" "$WORK/register-result.json" "$WORK/user.cookies" no; then
        if [[ $HTTP_UNSENT == 1 ]]; then
            set_status "$email" invited
            die '注册在建立连接前失败；下次运行可安全重试'
        fi
        log '注册响应未确认，正在通过登录和成员状态核对；不会重复提交。'
    fi
    verify_active "$email" || die "注册状态未确认，进度已保留：$HTTP_ERROR"
}

delete_account() {
    local email=$1 tmp
    tmp=$(mktemp "$ACCOUNTS.tmp.XXXXXX") || die '无法创建状态临时文件'
    jq --arg email "$email" '.accounts |= map(select(.email != $email))' "$ACCOUNTS" >"$tmp" || die '无法删除账号记录'
    mv -f -- "$tmp" "$ACCOUNTS" || die '无法提交账号记录删除'
}

activate_accounts() {
    local email remaining remote
    admin_login
    snapshot
    log "Full 席位：总量 ${TOTAL_SEATS}，已占用 ${OCCUPIED}，待邀请 ${PENDING}，可新增 ${FREE_SEATS}。"
    jq -r '.accounts[] | select(.status != "active") | .email' "$ACCOUNTS" >"$WORK/resume-emails" || die '无法读取未完成账号'
    while IFS= read -r email; do
        snapshot
        remote=$(member_status "$email") || die '无法核对成员'
        case "$remote" in
            absent) ;;
            2)
                jq -e --arg email "$email" '[.[] | select((.UserInfo.Email | ascii_downcase) == $email) |
                    select(.UserInfo.AccountType == 1 and .UserInfo.UserStatus == 2) |
                    .UserInfo.UserID | select(type == "string" and length > 0)] | length == 1' \
                    "$WORK/members.json" >/dev/null || die "未完成成员类型或 UserID 无效：$email"
                jq --arg email "$email" '[.[] | select((.UserInfo.Email | ascii_downcase) == $email) | .UserInfo.UserID] | {UserIDs:.}' \
                    "$WORK/members.json" >"$WORK/remove-request.json" || die '无法构造移除请求'
                if ! enterprise_post "$API/account/remove_user" "$WORK/remove-request.json" "$WORK/remove-result.json" "$WORK/admin.cookies" no; then
                    log '移除响应未确认，正在重新核对成员状态。'
                fi
                snapshot
                [[ $(member_status "$email") == absent ]] || die "移除后未确认成员不存在：$email；保留本地记录" ;;
            1) die "未完成记录对应的成员已激活：$email。请先核查，脚本不会移除该成员" ;;
            *) die "未完成成员状态未知：$email；保留本地记录" ;;
        esac
        delete_account "$email"
        log '已确认旧邮箱不在企业成员列表，已删除本地记录。'
    done <"$WORK/resume-emails"
    while [[ $COUNT == 0 || $COMPLETED -lt $COUNT ]]; do
        snapshot
        assert_capacity
        (( FREE_SEATS > 0 )) || break
        prepare_account
        activate_account "$NEW_EMAIL"
        COMPLETED=$((COMPLETED + 1))
        log "已确认激活 $COMPLETED 个账号。"
    done
    snapshot
    remaining=$((TOTAL_SEATS - OCCUPIED))
    log "本次激活 $COMPLETED 个；当前未占用 $remaining 个，其中 $PENDING 个保留给现有邀请。"
    if (( PENDING > 0 )); then log '其他现有邀请继续占用预留席位，不会替他人激活或删除。'; fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/trae-onboard.sh" || exit 1
    main activate "$@"
fi
