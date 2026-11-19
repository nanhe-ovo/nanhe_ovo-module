#!/system/bin/sh
# 云更新封装（参照 KernelSU 的 Release 检查 / 下载校验 / 受控安装链路）。
# 由 control.sh（WebUI 后端）引用；只读取固定的发布地址，元数据与暂存包都落在
# /data/adb/nanhe_ovo/update，目录属主 root、权限 700。
#
# 链路：
#   1. check   拉取 GitHub latest Release 元数据，按 versionCode 与本机比较；
#   2. download 域名白名单校验后下载暂存包，核对大小与 SHA256，失败即删半成品；
#   3. apply   写入待应用标记，真正替换在下次开机由 update_apply.sh 完成；
#   4. cancel  清理暂存包、标记与缓存元数据。
#
# 本库不直接替换模块目录：运行中的二进制与脚本先保持原状，重启后一次性落地，
# 避免半更新状态。用户配置（/sdcard/Android/yc/uperf 与线程规则）不在模块目录内，
# 升级不会被覆盖。

UPDATE_ROOT=$RUNTIME_ROOT/update
UPDATE_META=$UPDATE_ROOT/meta
UPDATE_CHANGELOG=$UPDATE_ROOT/changelog.txt
UPDATE_STAGED=$UPDATE_ROOT/staged.zip
UPDATE_PENDING=$UPDATE_ROOT/pending
UPDATE_API=https://api.github.com/repos/nanhe-ovo/nanhe_ovo-module/releases/latest
UPDATE_BUSYBOX=$MODULE/bin/busybox/busybox

update_local_code() {
    LC=$(awk -F '=' '$1=="versionCode"{print $2; exit}' "$MODULE/module.prop" 2>/dev/null)
    case "$LC" in ''|*[!0-9]*) LC=0;; esac
    printf '%s' "$LC"
}

update_local_version() {
    LV=$(awk -F '=' '$1=="version"{print $2; exit}' "$MODULE/module.prop" 2>/dev/null)
    printf '%s' "$LV" | sed 's/[^0-9A-Za-z._+-]/ /g' | tr -d ' \n'
}

update_meta_dir() {
    [ -d "$UPDATE_ROOT" ] || mkdir -p "$UPDATE_ROOT" 2>/dev/null || return 1
    [ ! -L "$UPDATE_ROOT" ] || return 1
    [ "$(stat -c %u "$UPDATE_ROOT" 2>/dev/null)" = 0 ] || return 1
    chmod 700 "$UPDATE_ROOT" 2>/dev/null
}

update_meta_get() {
    [ -f "$UPDATE_META" ] && [ ! -L "$UPDATE_META" ] || return 0
    awk -F= -v k="$1" '$1==k{print $2; exit}' "$UPDATE_META" 2>/dev/null
}

# 整文件重写元数据：参数成对 KEY VALUE。
update_meta_write() {
    update_meta_dir || return 1
    [ ! -L "$UPDATE_META" ] || { err 'update meta symlink refused'; return 1; }
    : > "$WORK/update.meta" || return 1
    while [ "$#" -ge 2 ]; do
        case "$1" in ''|*[!a-z0-9_]*) return 1;; esac
        printf '%s=%s\n' "$1" "$2" >> "$WORK/update.meta" || return 1
        shift 2
    done
    cat "$WORK/update.meta" > "$UPDATE_META" || return 1
    chmod 600 "$UPDATE_META" 2>/dev/null
}

# 只改写一个字段，其余元数据保留。
update_meta_set() {
    UM_KEY=$1 UM_VAL=$2
    [ -f "$UPDATE_META" ] && [ ! -L "$UPDATE_META" ] || return 1
    case "$UM_KEY" in ''|*[!a-z0-9_]*) return 1;; esac
    awk -F= -v k="$UM_KEY" '$1!=k' "$UPDATE_META" > "$WORK/update.meta" || return 1
    printf '%s=%s\n' "$UM_KEY" "$UM_VAL" >> "$WORK/update.meta" || return 1
    cat "$WORK/update.meta" > "$UPDATE_META" || return 1
    chmod 600 "$UPDATE_META" 2>/dev/null
}

# 下载：curl 优先，其次内置 busybox wget，再退系统 wget。三个都不可用即失败。
update_http_get() {
    UG_URL=$1 UG_OUT=$2
    [ -n "$UG_URL" ] && [ -n "$UG_OUT" ] || return 1
    UA="nanhe-ovo/$(update_local_version)"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 8 --max-time 25 -A "$UA" -o "$UG_OUT" "$UG_URL" 2>/dev/null
    elif [ -x "$UPDATE_BUSYBOX" ]; then
        "$UPDATE_BUSYBOX" wget -q -O "$UG_OUT" "$UG_URL" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$UG_OUT" "$UG_URL" 2>/dev/null
    else
        return 1
    fi
}

update_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif [ -x "$UPDATE_BUSYBOX" ]; then
        "$UPDATE_BUSYBOX" sha256sum "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# 下载域名白名单：只认 GitHub _release 资产与其 CDN 跳转域，拒绝任意第三方地址。
update_url_ok() {
    UU_URL=$1
    case "$UU_URL" in https://*) ;; *) return 1;; esac
    UU_HOST=${UU_URL#https://}
    UU_HOST=${UU_HOST%%/*}
    case "$UU_HOST" in
        github.com|www.github.com|objects.githubusercontent.com|release-assets.githubusercontent.com|*.githubusercontent.com) ;;
        *) return 1;;
    esac
    case "$UU_HOST" in *[!A-Za-z0-9.-]*) return 1;; esac
}

# 解析 Release JSON：输出 tag=/code=/url=/size=/sha= 键值行；正文写入 changelog。
# 只识别模块包（nanhe_ovo-v*.zip，排除 -src- 源码包）。
update_parse() {
    UP_FILE=$1
    awk -v changelog="$UPDATE_CHANGELOG" '
    function grab(str, key,   re, q1, after, inner, i, c, esc, out) {
        re = "\"" key "\"[ \t]*:[ \t]*"
        if (!match(str, re)) return ""
        q1 = RSTART + RLENGTH
        after = substr(str, q1)
        if (!match(after, /^"/)) return ""
        inner = substr(after, 2, index(substr(after, 2), "\"") - 1)
        out = ""; i = 1
        while (i <= length(inner)) {
            c = substr(inner, i, 1)
            if (c == "\\") {
                esc = substr(inner, i + 1, 1)
                if (esc == "n") out = out "\n"
                else if (esc == "t") out = out "\t"
                else if (esc == "r") out = out ""
                else if (esc == "\"") out = out "\""
                else if (esc == "\\") out = out "\\"
                else if (esc == "/") out = out "/"
                else out = out "\\" esc
                i += 2
            } else { out = out c; i++ }
        }
        return out
    }
    function list_vals(region, arr, field,   n, rest, after, q2, val) {
        n = 0; rest = region
        while (match(rest, "\"" field "\"[ \t]*:[ \t]*")) {
            after = substr(rest, RSTART + RLENGTH)
            if (field == "size") {
                if (!match(after, /^[0-9]+/)) break
                n++; arr[n] = substr(after, 1, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH + RLENGTH)
            } else {
                if (!match(after, /^"/)) break
                q2 = index(substr(after, 2), "\"")
                if (q2 <= 0) break
                val = substr(after, 2, q2 - 1)
                n++; arr[n] = val
                rest = substr(rest, RSTART + RLENGTH + q2)
            }
        }
        arr[0] = n
    }
    { s = s $0 "\n" }
    END {
        tag = grab(s, "tag_name")
        body = grab(s, "body")
        print "tag=" tag
        code = ""
        if (match(body, /versionCode=[0-9]+/)) {
            v = substr(body, RSTART, RLENGTH)
            sub(/versionCode=/, "", v)
            code = v
        }
        print "code=" code
        ai = index(s, "\"assets\"")
        region = ai > 0 ? substr(s, ai) : ""
        list_vals(region, names, "name")
        list_vals(region, urls, "browser_download_url")
        list_vals(region, sizes, "size")
        list_vals(region, digests, "digest")
        pick = 0
        for (i = 1; i <= names[0]; i++) {
            if (names[i] ~ /^nanhe_ovo-v.*\.zip$/ && index(names[i], "-src-") == 0) { pick = i; break }
        }
        if (pick > 0) {
            print "url=" (pick in urls ? urls[pick] : "")
            print "size=" (pick in sizes ? sizes[pick] : "")
            dg = (pick in digests ? digests[pick] : "")
            if (dg ~ /^sha256:[0-9a-fA-F]{64}$/) print "sha=" substr(dg, 8)
            else print "sha="
        } else { print "url="; print "size="; print "sha=" }
        if (changelog != "") print body > changelog
    }' "$UP_FILE"
}

update_report() { # STATE [VERSION CODE SIZE]
    printf 'info\tupdate_state\t%s\n' "$1"
    [ -n "${2:-}" ] && printf 'info\tupdate_version\t%s\n' "$2"
    [ -n "${3:-}" ] && printf 'info\tupdate_code\t%s\n' "$3"
    [ -n "${4:-}" ] && printf 'info\tupdate_size\t%s\n' "$4"
}

# 检查更新（联网）。失败只记日志并把状态置 failed，不抛栈打断面板。
cmd_update_check() {
    update_meta_dir || { err 'update runtime unavailable'; return 1; }
    UC_JSON="$WORK/update.latest.json"
    if ! update_http_get "$UPDATE_API" "$UC_JSON" || [ ! -s "$UC_JSON" ]; then
        log_write warn update '检查更新失败：无法连接发布源（网络不可达或设备没有可用的 curl/wget）'
        update_meta_write state failed checked "$(log_stamp)"
        update_report failed
        return 1
    fi
    PARSED=$(update_parse "$UC_JSON") || PARSED=
    UC_TAG=; UC_CODE=; UC_URL=; UC_SIZE=; UC_SHA=
    while IFS="=" read -r PK PV; do
        case "$PK" in
            tag) UC_TAG=$PV;; code) UC_CODE=$PV;; url) UC_URL=$PV;;
            size) UC_SIZE=$PV;; sha) UC_SHA=$PV;;
        esac
    done <<EOF
$PARSED
EOF
    case "$UC_TAG" in ''|*[!A-Za-z0-9._+-]*) UC_TAG=;; esac
    if [ -z "$UC_URL" ]; then
        log_write warn update '发布元数据里没有可用的模块包地址，已跳过本次检查'
        update_meta_write state failed checked "$(log_stamp)"
        update_report failed
        return 1
    fi
    UC_UNSAFE=0
    if ! update_url_ok "$UC_URL"; then
        UC_UNSAFE=1
        log_write warn update '发布资产地址不在允许的域名内，将在下载阶段拦截'
    fi
    case "$UC_CODE" in ''|*[!0-9]*) UC_CODE=;; esac
    LOCAL_CODE=$(update_local_code)
    if [ "$UC_UNSAFE" = 1 ] || [ -z "$UC_CODE" ]; then
        STATE=unknown
    elif [ "$UC_CODE" -gt "$LOCAL_CODE" ]; then
        STATE=available
    else
        STATE=uptodate
    fi
    update_meta_write state "$STATE" version "$UC_TAG" code "$UC_CODE" \
        url "$UC_URL" size "$UC_SIZE" sha "$UC_SHA" checked "$(log_stamp)"
    update_report "$STATE" "$UC_TAG" "$UC_CODE" "$UC_SIZE"
    case "$STATE" in
        available) log_write info update "发现新版本 $UC_TAG（versionCode $UC_CODE），等待下载";;
        uptodate) log_write info update "当前已是最新版本（$(update_local_version)）";;
        unknown) log_write warn update '远端版本号缺失，无法判断是否需要更新';;
    esac
    printf 'ok\tupdate check\n'
}

# 读取缓存状态（不联网）。
cmd_update_status() {
    update_meta_dir || { err 'update runtime unavailable'; return 1; }
    US_STATE=$(update_meta_get state)
    US_VERSION=$(update_meta_get version)
    US_CODE=$(update_meta_get code)
    US_SIZE=$(update_meta_get size)
    case "$US_STATE" in
        available|uptodate|downloaded|pending|failed|unknown) ;;
        *) US_STATE=none;;
    esac
    update_report "$US_STATE" "$US_VERSION" "$US_CODE" "$US_SIZE"
    printf 'ok\tupdate status\n'
}

cmd_update_changelog() {
    if [ -f "$UPDATE_CHANGELOG" ] && [ ! -L "$UPDATE_CHANGELOG" ] && [ -s "$UPDATE_CHANGELOG" ]; then
        sed '/^[[:space:]]*$/d' "$UPDATE_CHANGELOG"
    fi
    printf 'ok\tupdate changelog\n'
}

cmd_update_download() {
    UD_STATE=$(update_meta_get state)
    case "$UD_STATE" in available|unknown) ;;
        *) err '当前没有可下载的更新包'; return 1;;
    esac
    UD_URL=$(update_meta_get url)
    [ -n "$UD_URL" ] || { err '更新地址缺失'; return 1; }
    update_url_ok "$UD_URL" || { err '下载地址不在允许的域名内'; return 1; }
    update_meta_dir || { err 'update runtime unavailable'; return 1; }
    [ ! -L "$UPDATE_STAGED" ] || { err 'staged package symlink refused'; return 1; }
    rm -f "$UPDATE_STAGED" 2>/dev/null
    if ! update_http_get "$UD_URL" "$UPDATE_STAGED" || [ ! -s "$UPDATE_STAGED" ]; then
        rm -f "$UPDATE_STAGED" 2>/dev/null
        err '更新包下载失败，已清理半成品'
        log_write warn update '更新包下载失败（网络中断或地址不可达）'
        return 1
    fi
    UD_SIZE=$(update_meta_get size)
    case "$UD_SIZE" in *[!0-9]*) UD_SIZE=;; esac
    if [ -n "$UD_SIZE" ]; then
        ACT_SIZE=$(wc -c < "$UPDATE_STAGED" 2>/dev/null | tr -d ' ')
        [ "$ACT_SIZE" = "$UD_SIZE" ] || {
            rm -f "$UPDATE_STAGED" 2>/dev/null
            err "更新包大小不符（期望 $UD_SIZE，实际 $ACT_SIZE），已删除"
            return 1
        }
    fi
    UD_SHA=$(update_meta_get sha)
    case "$UD_SHA" in ''|*[!0-9a-fA-F]*) UD_SHA=;; esac
    if [ -n "$UD_SHA" ]; then
        ACT_SHA=$(update_sha256 "$UPDATE_STAGED")
        if [ "$ACT_SHA" != "$UD_SHA" ]; then
            rm -f "$UPDATE_STAGED" 2>/dev/null
            err 'SHA256 校验失败，更新包已删除，请勿刷入'
            log_write error update '更新包 SHA256 不匹配，已拒绝安装'
            return 1
        fi
    fi
    # 包结构自检：必须能列出 module.prop，避免下载到错误页面或残缺压缩包。
    if command -v unzip >/dev/null 2>&1; then
        unzip -l "$UPDATE_STAGED" 2>/dev/null | grep -q 'module.prop' || {
            rm -f "$UPDATE_STAGED" 2>/dev/null
            err '更新包结构不完整（缺少 module.prop），已删除'
            return 1
        }
    elif [ -x "$UPDATE_BUSYBOX" ]; then
        "$UPDATE_BUSYBOX" unzip -l "$UPDATE_STAGED" 2>/dev/null | grep -q 'module.prop' || {
            rm -f "$UPDATE_STAGED" 2>/dev/null
            err '更新包结构不完整（缺少 module.prop），已删除'
            return 1
        }
    fi
    chmod 600 "$UPDATE_STAGED" 2>/dev/null
    update_meta_set state downloaded
    printf 'info\tupdate_state\tdownloaded\n'
    log_write info update "更新包已校验通过并暂存（$ACT_SIZE 字节），重启后落地"
    printf 'ok\tupdate downloaded\t%s\n' "${ACT_SIZE:-未知}"
}

cmd_update_apply() {
    UA_STATE=$(update_meta_get state)
    case "$UA_STATE" in downloaded) ;;
        *) err '没有已校验的暂存包，请先下载更新'; return 1;;
    esac
    [ -f "$UPDATE_STAGED" ] && [ ! -L "$UPDATE_STAGED" ] || { err '暂存包缺失或被替换'; return 1; }
    UA_VERSION=$(update_meta_get version)
    UA_SHA=$(update_meta_get sha)
    UA_URL=$(update_meta_get url)
    [ ! -L "$UPDATE_PENDING" ] || { err 'pending marker symlink refused'; return 1; }
    : > "$WORK/update.pending" || return 1
    printf 'version=%s\n' "$UA_VERSION" >> "$WORK/update.pending"
    printf 'sha=%s\n' "$UA_SHA" >> "$WORK/update.pending"
    printf 'url=%s\n' "$UA_URL" >> "$WORK/update.pending"
    printf 'staged=%s\n' "$UPDATE_STAGED" >> "$WORK/update.pending"
    cat "$WORK/update.pending" > "$UPDATE_PENDING" || return 1
    chmod 600 "$UPDATE_PENDING" 2>/dev/null
    update_meta_set state pending
    printf 'info\tupdate_state\tpending\n'
    log_write info update "已安排重启后应用 $UA_VERSION"
    printf 'ok\tupdate pending\t%s\n' "$UA_VERSION"
}

cmd_update_cancel() {
    rm -f "$UPDATE_STAGED" "$UPDATE_PENDING" "$UPDATE_META" "$UPDATE_CHANGELOG" 2>/dev/null
    printf 'ok\tupdate cancel\n'
}
