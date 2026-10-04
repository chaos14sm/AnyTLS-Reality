#!/usr/bin/env bash
# =============================================================================
#  anytls-reality.sh  —  sing-box / Xray-core 一键管理脚本 (AnyTLS + Reality)
#
#  本脚本的界面风格、菜单结构与交互逻辑参考并派生自 mack-a/v2ray-agent
#      https://github.com/mack-a/v2ray-agent
#  v2ray-agent 以 GNU AGPL-3.0 授权发布，因此本脚本同样以 AGPL-3.0 授权:
#      https://www.gnu.org/licenses/agpl-3.0.html
#
#  与 v2ray-agent 的主要差异
#   * 新增 AnyTLS + Reality (sing-box)，安装菜单中 sing-box 排第一、Xray 排第二
#   * 单一事实来源: 所有配置由 /etc/anytls-reality/state.json 经 jq 渲染生成，
#     密码含特殊字符不会破坏 JSON
#   * 事务式变更: 渲染 -> sing-box check / xray -test -> 备份 -> 落盘 -> 重启 -> 验证，
#     失败自动回滚；密钥只在配置成功写入后才落盘
#   * 只使用稳定版内核: GitHub releases/latest -> 重定向探测 -> 手动输入版本号
#   * 快捷命令: atr
# =============================================================================
export LANG=en_US.UTF-8

ATR_VERSION="v1.0.0"
ATR_PROJECT_NAME="anytls-reality"

# ----------------------------- 路径与常量 -----------------------------------
# ATR_* 变量允许通过环境变量覆盖（主要用于测试），正常使用无需设置
ATR_HOME="${ATR_HOME:-/etc/anytls-reality}"
ATR_STATE="${ATR_HOME}/state.json"
ATR_SCRIPT_PATH="${ATR_HOME}/anytls-reality.sh"
ATR_CMD="atr"
ATR_BIN_DIR="${ATR_BIN_DIR:-/usr/bin}"
ATR_SYSTEMD_DIR="${ATR_SYSTEMD_DIR:-/etc/systemd/system}"
ATR_SYSCTL_FILE="${ATR_SYSCTL_FILE:-/etc/sysctl.d/99-anytls-reality-bbr.conf}"

SB_DIR="${ATR_HOME}/sing-box"
SB_BIN="${SB_DIR}/sing-box"
SB_CONF="${SB_DIR}/conf/config.json"
SB_RULESET_DIR="${SB_DIR}/rule-sets"
SB_UNIT="atr-sing-box"

XRAY_DIR="${ATR_HOME}/xray"
XRAY_BIN="${XRAY_DIR}/xray"
XRAY_CONF="${XRAY_DIR}/conf/config.json"
XRAY_UNIT="atr-xray"

TLS_DIR="${ATR_HOME}/tls"
CLIENT_DIR="${ATR_HOME}/clients"
SUB_DIR="${ATR_HOME}/subscribe"
SUB_REMOTE_FILE="${ATR_HOME}/subscribe_remote/remoteSubscribeUrl"
BACKUP_DIR="${ATR_HOME}/backup"
WEB_ROOT="${ATR_HOME}/www"
NGX_DIR="${ATR_HOME}/nginx"
NGX_CONF="${NGX_DIR}/nginx.conf"
NGX_CONFD="${NGX_DIR}/conf.d"
NGX_UNIT="atr-nginx"
LOCK_FILE="${ATR_HOME}/atr.lock"
ACME_HOME="${ACME_HOME:-${HOME:-/root}/.acme.sh}"

# 更新脚本时使用的默认下载地址（菜单 17 中改过的地址会记住，保存在 ${ATR_HOME}/script_url，优先于此默认值；留空则运行时询问）
ATR_SCRIPT_URL_DEFAULT="https://raw.githubusercontent.com/chaos14sm/AnyTLS-Reality/main/anytls-reality.sh"

# GitHub 下载代理前缀（例如 https://ghfast.top/ ），留空表示直连
GITHUB_PROXY="${GITHUB_PROXY:-}"

# Xray geosite/geoip 来源
XRAY_GEO_REPO="Loyalsoldier/v2ray-rules-dat"
# sing-box geosite/geoip 规则集来源
SB_GEOSITE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
SB_GEOIP_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set"

# nginx 回环端口（与 v2ray-agent 保持一致，便于对照）
NGX_FALLBACK_PORT=31300   # Xray 回落 -> 伪装站 (http/1.1, proxy_protocol)
NGX_FALLBACK_H2_PORT=31302 # Xray 回落 -> 伪装站 (h2, proxy_protocol)
XRAY_TROJAN_PORT=31296
XRAY_VLESS_WS_PORT=31297
XRAY_VMESS_WS_PORT=31299
SB_HTTPUPGRADE_PORT=31306

# 运行期全局变量
RELEASE=""          # debian / ubuntu / centos
PKG_INSTALL=""
PKG_UPDATE=""
CPU_SB=""           # sing-box 资产后缀 linux-amd64 / linux-arm64
CPU_XRAY=""         # Xray 资产名 Xray-linux-64 / Xray-linux-arm64-v8a
ATR_TMP=""

# ----------------------------- 颜色输出 -------------------------------------
# echoContent  : 界面文字，解析 \n \t 以及行尾的 \c（不换行，沿用 v2ray-agent 习惯）
# printRaw     : 数据行（密码、链接、JSON），原样输出，绝不解析反斜杠
_colorCode() {
    case "$1" in
    red) printf '31' ;;
    green) printf '32' ;;
    yellow) printf '33' ;;
    skyBlue) printf '1;36' ;;
    white) printf '37' ;;
    magenta) printf '35' ;;
    *) printf '0' ;;
    esac
}

echoContent() {
    local color=$1
    shift
    local msg="$*" nl='\n'
    if [[ "${msg}" == *'\c' ]]; then
        msg=${msg%'\c'}
        nl=''
    fi
    printf '\033[%sm%b \033[0m%b' "$(_colorCode "${color}")" "${msg}" "${nl}"
}

printRaw() {
    local color=$1
    shift
    printf '\033[%sm%s\033[0m\n' "$(_colorCode "${color}")" "$*"
}

# ----------------------------- 清理与退出 -----------------------------------
ATR_TMP=$(mktemp -d /tmp/atr.XXXXXX 2>/dev/null || echo "")
_atrCleanup() {
    [[ -n "${ATR_TMP}" && -d "${ATR_TMP}" ]] && rm -rf "${ATR_TMP}"
}
trap _atrCleanup EXIT

# =============================================================================
#  01  通用工具: 输入、校验、随机数、端口、编码、锁、日志
# =============================================================================

# ----------------------------- 日志 -----------------------------------------
atrLog() {
    mkdir -p "${ATR_HOME}" 2>/dev/null
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"${ATR_HOME}/atr.log" 2>/dev/null
}

# ----------------------------- 交互输入 -------------------------------------
# 是否有可交互的终端（ATR_FORCE_TTY=1 仅用于测试，让管道输入也走交互分支）
isInteractive() { [[ "${ATR_FORCE_TTY:-0}" == "1" || -t 0 ]]; }

# ask <变量名> <提示> [默认值]   —— EOF(无输入)时返回 1，调用方应中止
ask() {
    local __var=$1 __prompt=$2 __def=${3:-} __ans=
    if ! IFS= read -r -p "${__prompt}" __ans; then
        echo
        return 1
    fi
    [[ -z "${__ans}" ]] && __ans=${__def}
    printf -v "${__var}" '%s' "${__ans}"
}

# confirm <提示> [默认 y|n]  —— 返回 0 表示确认
confirm() {
    local prompt=$1 def=${2:-n} ans=
    local hint="[y/n]"
    [[ "${def}" == "y" ]] && hint="[Y/n]"
    [[ "${def}" == "n" ]] && hint="[y/N]"
    IFS= read -r -p "${prompt}${hint}:" ans || {
        echo
        return 1
    }
    [[ -z "${ans}" ]] && ans=${def}
    [[ "${ans}" == "y" || "${ans}" == "Y" ]]
}

# 进度提示，沿用 v2ray-agent 的 "进度 n/total : 说明"
step() {
    local n=$1 total=$2
    shift 2
    echoContent skyBlue "\n进度  ${n}/${total} : $*"
}

# ----------------------------- 校验函数 -------------------------------------
isInt() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
isPort() { isInt "${1:-}" && ((10#${1} >= 1 && 10#${1} <= 65535)); }
isUUID() { [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
isIPv4() {
    local ip=${1:-} o
    [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in ${ip}; do ((10#${o} <= 255)) || return 1; done
}
isIPv6() { [[ "${1:-}" == *:* && "${1:-}" =~ ^[0-9A-Fa-f:.]+$ ]]; }
isDomainName() { [[ "${1:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$ ]]; }
isHostOrIP() { isDomainName "${1:-}" || isIPv4 "${1:-}" || isIPv6 "${1:-}"; }
# 用户名: 会出现在文件名、URI、YAML、JSON 中，限制为安全字符
isSafeName() { [[ "${1:-}" =~ ^[A-Za-z0-9_][A-Za-z0-9._@-]{0,47}$ ]]; }
# 伪装路径片段: 仅字母数字
isSafePathSeg() { [[ "${1:-}" =~ ^[A-Za-z0-9]{1,32}$ ]]; }
# 密码: 不允许控制字符/换行，长度 1-128（其余字符允许，JSON/URI/YAML 均由程序转义）
isValidSecret() {
    local s=${1:-}
    [[ -n "${s}" && ${#s} -le 128 ]] && [[ "${s}" != *$'\n'* && "${s}" != *$'\r'* && "${s}" != *$'\t'* ]]
}
# 版本号: 只接受稳定版 vX.Y.Z / X.Y.Z / X.Y.Z.W，拒绝带 -alpha/-beta/-rc 的预发布
isStableVersion() { [[ "${1:-}" =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]]; }

# ----------------------------- 随机数 ---------------------------------------
randInt() { # randInt <min> <max>
    local min=$1 max=$2
    echo $(((((RANDOM << 15) | RANDOM) % (max - min + 1)) + min))
}
randStr() { # randStr [长度] [字符集]
    local n=${1:-16} set=${2:-A-Za-z0-9}
    LC_ALL=C tr -dc "${set}" </dev/urandom 2>/dev/null | head -c "${n}"
    echo
}
randHex() { randStr "${1:-8}" 'a-f0-9'; }
randLower() { randStr "${1:-4}" 'a-z'; }
newPassword() { randStr 20 'A-Za-z0-9'; }
newUUID() {
    if [[ -x "${SB_BIN}" ]]; then
        "${SB_BIN}" generate uuid
    elif [[ -x "${XRAY_BIN}" ]]; then
        "${XRAY_BIN}" uuid
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        local h
        h=$(randHex 32)
        echo "${h:0:8}-${h:8:4}-4${h:13:3}-a${h:17:3}-${h:20:12}"
    fi
}

# ----------------------------- 端口 -----------------------------------------
# portInUse <端口> [tcp|udp|any]  —— 0 表示已被占用
portInUse() {
    local port=$1 proto=${2:-any} out=
    if command -v ss >/dev/null 2>&1; then
        case "${proto}" in
        tcp) out=$(ss -ltn 2>/dev/null) ;;
        udp) out=$(ss -lun 2>/dev/null) ;;
        *) out=$(ss -ltn 2>/dev/null; ss -lun 2>/dev/null) ;;
        esac
        echo "${out}" | awk -v p=":${port}\$" 'NR>0 && ($4 ~ p || $5 ~ p) {f=1} END{exit !f}'
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i ":${port}" >/dev/null 2>&1
    else
        return 1
    fi
}

# shellcheck disable=SC2120
# randomFreePort [已占用端口列表(空格分隔)]  —— 在 10000-60000 中挑一个未被占用的
randomFreePort() {
    local avoid=" ${1:-} " p i
    for ((i = 0; i < 60; i++)); do
        p=$(randInt 10000 60000)
        [[ "${avoid}" == *" ${p} "* ]] && continue
        portInUse "${p}" any && continue
        echo "${p}"
        return 0
    done
    return 1
}

# ----------------------------- 编码 -----------------------------------------
urlEncode() { jq -rn --arg v "${1-}" '$v|@uri'; }
# base64 单行（兼容 busybox/GNU）
b64() { printf '%s' "${1-}" | base64 | tr -d '\n'; }

# ----------------------------- 网络辅助 -------------------------------------
_PUBLIC_IP_CACHE_4=""
_PUBLIC_IP_CACHE_6=""
getPublicIP() { # getPublicIP [4|6]
    local t=${1:-4} ip="" url
    if [[ "${t}" == "4" && -n "${_PUBLIC_IP_CACHE_4}" ]]; then
        echo "${_PUBLIC_IP_CACHE_4}"
        return 0
    fi
    if [[ "${t}" == "6" && -n "${_PUBLIC_IP_CACHE_6}" ]]; then
        echo "${_PUBLIC_IP_CACHE_6}"
        return 0
    fi
    ip=$(curl -s "-${t}" -m 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')
    if [[ -z "${ip}" ]]; then
        for url in "https://api64.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
            ip=$(curl -s "-${t}" -m 6 "${url}" 2>/dev/null | tr -d '[:space:]')
            if isIPv4 "${ip}" || isIPv6 "${ip}"; then break; fi
            ip=""
        done
    fi
    [[ "${t}" == "4" ]] && _PUBLIC_IP_CACHE_4=${ip}
    [[ "${t}" == "6" ]] && _PUBLIC_IP_CACHE_6=${ip}
    echo "${ip}"
}

hasIPv6() { [[ -n "$(getPublicIP 6)" ]]; }

# 用 GITHUB_PROXY 包装 github.com 下载地址
ghURL() {
    local u=$1
    if [[ -n "${GITHUB_PROXY}" && "${u}" == https://github.com/* ]]; then
        echo "${GITHUB_PROXY%/}/${u}"
    else
        echo "${u}"
    fi
}

# 下载文件: download <url> <目标> —— 原子写入，失败不留半截文件
download() {
    local url=$1 dest=$2 tmp="${2}.part"
    rm -f "${tmp}"
    if curl -fL --retry 3 --retry-delay 2 -m 600 -sS -o "${tmp}" "$(ghURL "${url}")" 2>/dev/null && [[ -s "${tmp}" ]]; then
        mv -f "${tmp}" "${dest}"
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

# ----------------------------- 事务锁 ---------------------------------------
lockAcquire() {
    command -v flock >/dev/null 2>&1 || return 0
    mkdir -p "${ATR_HOME}"
    exec 9>"${LOCK_FILE}" || return 0
    if ! flock -w 60 9; then
        echoContent red " ---> 另一个 ${ATR_CMD} 操作正在进行，请稍后重试"
        return 1
    fi
}
lockRelease() {
    command -v flock >/dev/null 2>&1 || return 0
    flock -u 9 2>/dev/null
    exec 9>&-
}

# ----------------------------- 日志跟随 -------------------------------------
# followLog <命令...>  —— Ctrl+C 只中止日志命令并返回调用处(菜单)，不退出整个脚本
followLog() {
    local oldTrap
    oldTrap=$(trap -p INT)
    trap 'echo; echoContent yellow " ---> 已停止查看日志，返回菜单"' INT
    "$@"
    if [[ -n "${oldTrap}" ]]; then eval "${oldTrap}"; else trap - INT; fi
    return 0
}

# ----------------------------- 文本/文件小工具 -------------------------------
# 原子写文件: atomicWrite <目标> <权限>  (内容来自 stdin)
atomicWrite() {
    local dest=$1 mode=${2:-644} tmp
    tmp=$(mktemp "${dest}.XXXXXX") || return 1
    if cat >"${tmp}" && chmod "${mode}" "${tmp}" && mv -f "${tmp}" "${dest}"; then
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

# 去掉首尾空白
trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "${s}"
}

# =============================================================================
#  02  系统检测 / 依赖安装
# =============================================================================

checkRoot() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echoContent red " ---> 请使用 root 用户运行（sudo -i 后再执行 ${ATR_CMD}）"
        exit 1
    fi
}

checkSystem() {
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id=$(. /etc/os-release && echo "${ID:-}")
        # shellcheck disable=SC1091
        like=$(. /etc/os-release && echo "${ID_LIKE:-}")
    fi
    case "${id}" in
    debian | ubuntu | raspbian | linuxmint | kali) RELEASE="debian" ;;
    centos | rhel | rocky | almalinux | fedora | ol | amzn | anolis | opencloudos) RELEASE="centos" ;;
    alpine) RELEASE="alpine" ;;
    *)
        case " ${like} " in
        *" debian "* | *" ubuntu "*) RELEASE="debian" ;;
        *" rhel "* | *" fedora "* | *" centos "*) RELEASE="centos" ;;
        esac
        ;;
    esac

    case "${RELEASE}" in
    debian)
        PKG_INSTALL="apt-get install -y -qq"
        PKG_UPDATE="apt-get update -qq"
        ;;
    centos)
        if command -v dnf >/dev/null 2>&1; then
            PKG_INSTALL="dnf install -y -q"
            PKG_UPDATE="dnf makecache -q"
        else
            PKG_INSTALL="yum install -y -q"
            PKG_UPDATE="yum makecache -q"
        fi
        ;;
    alpine)
        echoContent red "\n ---> 本脚本依赖 systemd，暂不支持 Alpine(OpenRC)，请使用 v2ray-agent 或更换系统"
        exit 1
        ;;
    *)
        echoContent red "\n本脚本不支持此系统，请将下方信息反馈给开发者\n"
        [[ -r /etc/os-release ]] && cat /etc/os-release
        exit 1
        ;;
    esac

    if [[ "${ATR_TEST:-0}" != "1" ]]; then
        if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
            echoContent red "\n ---> 未检测到 systemd，本脚本无法使用（容器/部分精简系统不带 systemd）"
            exit 1
        fi
    fi

    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
        echoContent yellow "\n 提示: 检测到 SELinux 为 Enforcing，若使用 nginx 相关协议出现端口权限问题，请放行相应端口或临时设为 Permissive"
    fi
}

checkCPU() {
    case "$(uname -m)" in
    x86_64 | amd64)
        CPU_SB="linux-amd64"
        CPU_XRAY="Xray-linux-64"
        CPU_JQ="jq-linux-amd64"
        ;;
    aarch64 | armv8* | arm64)
        CPU_SB="linux-arm64"
        CPU_XRAY="Xray-linux-arm64-v8a"
        CPU_JQ="jq-linux-arm64"
        ;;
    *)
        echoContent red " ---> 不支持此 CPU 架构: $(uname -m)（仅支持 amd64 / arm64）"
        exit 1
        ;;
    esac
}

# v2ray-agent 与本脚本同机时 80/443、nginx 会冲突，给出提示
warnV2rayAgentConflict() {
    if [[ -d /etc/v2ray-agent && "${ATR_TEST:-0}" != "1" ]]; then
        echoContent yellow "\n 提示: 检测到本机安装了 v2ray-agent。两者的服务名与目录互相独立，"
        echoContent yellow "       但如同时使用 443/80 端口或同名协议端口会冲突，请为本脚本选择不同端口。"
    fi
}

# ----------------------------- 依赖安装 -------------------------------------
_pkgUpdated=""
pkgUpdateOnce() {
    [[ -n "${_pkgUpdated}" ]] && return 0
    _pkgUpdated=1
    # shellcheck disable=SC2086
    ${PKG_UPDATE} >/dev/null 2>&1 || true
}

# pkgInstall <包名...>  —— 失败返回 1
pkgInstall() {
    [[ "${ATR_SKIP_PACKAGES:-0}" == "1" ]] && return 1
    pkgUpdateOnce
    # shellcheck disable=SC2086
    if [[ "${RELEASE}" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive ${PKG_INSTALL} "$@" >/dev/null 2>&1
    else
        ${PKG_INSTALL} "$@" >/dev/null 2>&1
    fi
}

# 命令 -> 包名（按发行版）
toolPkg() {
    case "$1:${RELEASE}" in
    crontab:debian) echo cron ;;
    crontab:centos) echo cronie ;;
    dig:debian) echo dnsutils ;;
    dig:centos) echo bind-utils ;;
    ss:debian) echo iproute2 ;;
    ss:centos) echo iproute ;;
    pgrep:debian) echo procps ;;
    pgrep:centos) echo procps-ng ;;
    flock:*) echo util-linux ;;
    *) echo "$1" ;;
    esac
}

# ensureTool <命令> [optional]
ensureTool() {
    local cmd=$1 optional=${2:-}
    command -v "${cmd}" >/dev/null 2>&1 && return 0
    echoContent green " ---> 安装 ${cmd}"
    pkgInstall "$(toolPkg "${cmd}")"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        if [[ "${optional}" == "optional" ]]; then
            echoContent yellow " ---> ${cmd} 安装失败（可选组件，已跳过）"
            return 1
        fi
        echoContent red " ---> ${cmd} 安装失败，请手动安装后重试"
        return 1
    fi
}

# jq 版本检查（要求 >= 1.6）
jqVersionOK() {
    local v major minor
    v=$(jq --version 2>/dev/null | sed 's/^jq-//')
    major=${v%%.*}
    minor=${v#*.}
    minor=${minor%%[!0-9]*}
    [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]] || return 1
    ((major > 1 || (major == 1 && minor >= 6)))
}

# 无法通过包管理器获得合格 jq 时，下载官方静态二进制
bootstrapJq() {
    mkdir -p "${ATR_HOME}/bin"
    export PATH="${ATR_HOME}/bin:${PATH}"
    echoContent green " ---> 下载 jq 静态二进制"
    if download "https://github.com/jqlang/jq/releases/latest/download/${CPU_JQ}" "${ATR_HOME}/bin/jq"; then
        chmod 755 "${ATR_HOME}/bin/jq"
    fi
    jqVersionOK
}

ensureJq() {
    if command -v jq >/dev/null 2>&1 && jqVersionOK; then return 0; fi
    ensureTool jq optional || true
    if command -v jq >/dev/null 2>&1 && jqVersionOK; then return 0; fi
    bootstrapJq || {
        echoContent red " ---> 无法获得可用的 jq(>=1.6)，请手动安装"
        return 1
    }
}

# 脚本所需的基础工具
installTools() { # installTools <min|full>
    local mode=${1:-min}
    step "${2:-1}" "${3:-1}" "检查、安装依赖工具"
    if [[ "${ATR_SKIP_PACKAGES:-0}" == "1" ]]; then
        echoContent yellow " ---> 已跳过包安装(ATR_SKIP_PACKAGES=1)"
        ensureJq
        return $?
    fi
    echoContent green " ---> 检查、安装更新【新机器会较慢，请耐心等待】"
    pkgUpdateOnce
    if [[ "${RELEASE}" == "centos" ]]; then
        pkgInstall epel-release || true
    fi
    local t
    for t in curl wget tar unzip openssl lsof ss pgrep flock; do
        ensureTool "${t}" || true
    done
    ensureJq || return 1
    ensureTool qrencode optional || true
    ensureTool crontab optional || true
    # RHEL 系装完 cronie 不会自动启动，acme.sh 的续签定时任务依赖它
    if command -v crontab >/dev/null 2>&1; then
        systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1
    fi
    if [[ "${mode}" == "full" ]]; then
        ensureTool socat || true
        ensureTool dig optional || true
    fi
    for t in curl tar openssl; do
        command -v "${t}" >/dev/null 2>&1 || {
            echoContent red " ---> 缺少必要工具 ${t}"
            return 1
        }
    done
    return 0
}

# ----------------------------- 独立 nginx 实例 -------------------------------
# 不使用系统的 nginx 服务/配置，避免默认站点占用 80 端口、与已有网站互相影响。
# 仅复用发行版提供的 nginx 二进制。
NGINX_BIN=""
findNginxBin() {
    NGINX_BIN=$(command -v nginx 2>/dev/null || true)
    if [[ -z "${NGINX_BIN}" ]]; then
        local c
        for c in /usr/sbin/nginx /usr/local/nginx/sbin/nginx /usr/local/sbin/nginx; do
            [[ -x "${c}" ]] && NGINX_BIN=${c} && break
        done
    fi
    [[ -n "${NGINX_BIN}" ]]
}

ensureNginx() {
    findNginxBin && return 0
    echoContent green " ---> 安装 nginx"
    pkgInstall nginx || true
    if ! findNginxBin; then
        echoContent red " ---> nginx 安装失败，请手动安装 nginx 后重试"
        return 1
    fi
    # 刚装好的发行版 nginx 会自动启动并占用 80 端口，停掉它（我们用独立实例）
    if [[ "${ATR_TEST:-0}" != "1" ]]; then
        systemctl stop nginx >/dev/null 2>&1
        systemctl disable nginx >/dev/null 2>&1
    fi
    return 0
}

nginxVersionGE() { # nginxVersionGE <major.minor.patch>  —— 当前 nginx >= 指定版本 ?
    findNginxBin || return 1
    local cur want=$1
    cur=$("${NGINX_BIN}" -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
    [[ -n "${cur}" ]] || return 1
    [[ "$(printf '%s\n%s\n' "${want}" "${cur}" | sort -V | head -n 1)" == "${want}" ]]
}

# systemd 开机启动
bootStartup() {
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable "$1" >/dev/null 2>&1
}

# =============================================================================
#  03  协议注册表 / 状态(state.json) / 用户
#      state.json 是唯一事实来源，所有核心配置都由它经 jq 渲染生成
# =============================================================================

# ----------------------------- 协议注册表 ------------------------------------
# 顺序即菜单顺序: 前 5 项是预设组合；sing-box 排在 Xray 之前
read -r -d '' PROTO_REGISTRY <<'EOF'
[
 {"id":"vless_reality_vision","name":"VLESS+Reality+Vision","short":"VLESS_Reality_Vision","cores":["sing-box","xray"],"reality":true,"tls":false,"net":"tcp","note":"推荐","preset":true},
 {"id":"anytls_reality","name":"AnyTLS+Reality","short":"AnyTLS_Reality","cores":["sing-box"],"reality":true,"tls":false,"net":"tcp","note":"推荐","preset":true},
 {"id":"tuic","name":"Tuic","short":"Tuic","cores":["sing-box"],"reality":false,"tls":true,"net":"udp","preset":true},
 {"id":"hysteria2","name":"Hysteria2","short":"Hysteria2","cores":["sing-box"],"reality":false,"tls":true,"net":"udp","preset":true},
 {"id":"naive","name":"Naive","short":"Naive","cores":["sing-box"],"reality":false,"tls":true,"net":"tcp","preset":true},
 {"id":"vless_vision_tls","name":"VLESS+TLS_Vision+TCP","short":"VLESS_TCP_TLS_Vision","cores":["sing-box","xray"],"reality":false,"tls":true,"net":"tcp","note":"推荐"},
 {"id":"vless_ws","name":"VLESS+TLS+WS","short":"VLESS_WS","cores":["sing-box","xray"],"reality":false,"tls":true,"net":"tcp","note":"仅CDN推荐","cdn":true},
 {"id":"vmess_ws","name":"VMess+TLS+WS","short":"VMess_WS","cores":["sing-box","xray"],"reality":false,"tls":true,"net":"tcp","note":"仅CDN推荐","cdn":true},
 {"id":"trojan","name":"Trojan+TLS","short":"Trojan","cores":["sing-box","xray"],"reality":false,"tls":true,"net":"tcp","note":"不推荐"},
 {"id":"vless_reality_grpc","name":"VLESS+Reality+gRPC","short":"VLESS_Reality_gRPC","cores":["sing-box"],"reality":true,"tls":false,"net":"tcp"},
 {"id":"vmess_httpupgrade","name":"VMess+TLS+HTTPUpgrade","short":"VMess_HTTPUpgrade","cores":["sing-box"],"reality":false,"tls":true,"net":"tcp","note":"仅CDN推荐","cdn":true,"nginx":true},
 {"id":"anytls_tls","name":"AnyTLS+TLS(证书)","short":"AnyTLS","cores":["sing-box"],"reality":false,"tls":true,"net":"tcp"},
 {"id":"vless_reality_xhttp","name":"VLESS+Reality+XHTTP","short":"VLESS_Reality_XHTTP","cores":["xray"],"reality":true,"tls":false,"net":"tcp"},
 {"id":"vless_xhttp_tls","name":"VLESS+XHTTP+TLS","short":"VLESS_XHTTP_TLS","cores":["xray"],"reality":false,"tls":true,"net":"tcp","note":"CDN可用","cdn":true}
]
EOF

protoField() { # protoField <id> <字段>
    jq -r --arg id "$1" --arg f "$2" '.[]|select(.id==$id)|.[$f]|if .==null then "" else tostring end' <<<"${PROTO_REGISTRY}"
}
protoName() { protoField "$1" name; }
protoShort() { protoField "$1" short; }

# 菜单列表: protoMenu <core> [preset]  —— 打印编号并填充 PROTO_MENU_IDS
PROTO_MENU_IDS=()
protoMenu() {
    local core=$1 onlyPreset=${2:-} i=0 id name note
    PROTO_MENU_IDS=()
    while IFS=$'\t' read -r id name note; do
        i=$((i + 1))
        PROTO_MENU_IDS+=("${id}")
        echoContent yellow "${i}.${name}${note:+[${note}]}"
    done < <(jq -r --arg c "${core}" --arg p "${onlyPreset}" \
        '.[]|select(.cores|index($c))|select($p==""  or .preset==true)|[.id,.name,(.note//"")]|@tsv' <<<"${PROTO_REGISTRY}")
}

# 解析多选输入 "1,2,3" -> 全局数组 SELECTED_IDS（按 PROTO_MENU_IDS）；失败返回 1
SELECTED_IDS=()
parseSelection() {
    local input=${1// /} tok idx
    SELECTED_IDS=()
    if [[ "${input}" == *"，"* ]]; then
        echoContent red " ---> 请使用英文逗号分隔"
        return 1
    fi
    [[ -n "${input}" ]] || {
        echoContent red " ---> 输入不能为空"
        return 1
    }
    local IFS=','
    for tok in ${input}; do
        [[ -z "${tok}" ]] && continue
        if ! isInt "${tok}" || ((10#${tok} < 1 || 10#${tok} > ${#PROTO_MENU_IDS[@]})); then
            echoContent red " ---> 输入不合法: ${tok}"
            return 1
        fi
        idx=$((10#${tok} - 1))
        # 去重（注意: 这里 IFS 已被设为逗号，不能用 ${arr[*]} 拼接）
        local seen=0 s
        for s in "${SELECTED_IDS[@]}"; do
            [[ "${s}" == "${PROTO_MENU_IDS[idx]}" ]] && seen=1
        done
        ((seen == 0)) && SELECTED_IDS+=("${PROTO_MENU_IDS[idx]}")
    done
    ((${#SELECTED_IDS[@]} > 0))
}

# ----------------------------- 默认状态 --------------------------------------
stateDefault() {
    cat <<'EOF'
{
  "schema": 1,
  "domain": "",
  "tls": {"mode": "none", "ca": "letsencrypt", "dns_api": "", "wildcard": false, "parent": ""},
  "reality": {"sni": "", "dest_port": 443, "private_key": "", "public_key": "", "short_id": "", "mldsa_seed": "", "mldsa_verify": ""},
  "users": [],
  "protocols": {},
  "path": "",
  "cdn": "",
  "alpn": "h2",
  "extra_ports": [],
  "nginx": {"subscribe": {"enabled": false, "port": 0, "ssl": true, "salt": ""}, "redirect302": ""},
  "routing": {
    "block_bt": false,
    "global": "",
    "blacklist": {"domains": [], "ips": [], "cn": false, "allow": []},
    "warp": {"v4": {"domains": []}, "v6": {"domains": []}, "config": {}},
    "ipv6": {"domains": []},
    "socks5_out": {},
    "socks5_in": {},
    "dns_unlock": {},
    "sni_proxy": {},
    "vmess_out": {}
  },
  "firewall": {"opened": []},
  "log": {"debug": false}
}
EOF
}

stateExists() { [[ -s "${ATR_STATE}" ]] && jq -e . "${ATR_STATE}" >/dev/null 2>&1; }

stateInit() {
    mkdir -p "${ATR_HOME}" "${TLS_DIR}" "${CLIENT_DIR}" "${BACKUP_DIR}" "${SB_DIR}/conf" "${XRAY_DIR}/conf" "${WEB_ROOT}" "${SUB_DIR}"
    chmod 700 "${TLS_DIR}" "${CLIENT_DIR}" "${BACKUP_DIR}" 2>/dev/null
    chmod 755 "${WEB_ROOT}" "${SUB_DIR}" 2>/dev/null
    # 711: 其他用户只能"穿越"到 www/ 与 subscribe/（nginx worker 降权后需要读取），不能列目录；
    # 私密内容各自保持 600/700（state.json、clients/、backup/、tls/、配置文件）
    chmod 711 "${ATR_HOME}" 2>/dev/null
    if ! stateExists; then
        stateDefault | jq . | atomicWrite "${ATR_STATE}" 600
    fi
}

# S <jq 参数...> <过滤器>  —— 读取当前已生效的 state.json
S() { jq -r "$@" "${ATR_STATE}" 2>/dev/null; }

# ----------------------------- 候选状态(暂存) --------------------------------
NEW_STATE=""
stagedBegin() {
    if stateExists; then NEW_STATE=$(jq . "${ATR_STATE}"); else NEW_STATE=$(stateDefault | jq .); fi
}
# stagedEdit <jq 参数...> <过滤器>
stagedEdit() {
    [[ -n "${NEW_STATE}" ]] || stagedBegin
    local out
    if out=$(printf '%s' "${NEW_STATE}" | jq "$@" 2>/dev/null) && [[ -n "${out}" ]]; then
        NEW_STATE=${out}
        return 0
    fi
    echoContent red " ---> 内部错误: 状态修改失败"
    return 1
}
stagedDiscard() { NEW_STATE=""; }
# stagedGet <jq 参数...> <过滤器>
stagedGet() { printf '%s' "${NEW_STATE}" | jq -r "$@" 2>/dev/null; }

# ----------------------------- 状态查询 --------------------------------------
protoInstalled() { jq -e --arg id "$1" '.protocols[$id]' "${ATR_STATE}" >/dev/null 2>&1; }
# 按注册表顺序列出已安装协议（与菜单顺序一致，预设的 5 个在最前），而不是 state 里的插入顺序，
# 这样状态行、自检顺序、Reality 管理里的编号在任何机器上都是稳定的。
installedProtocols() {
    jq -r --argjson reg "${PROTO_REGISTRY}" '((.protocols // {}) | keys) as $k | $reg[] | .id | select(. as $i | ($k | index($i)) != null)' "${ATR_STATE}" 2>/dev/null
}
installedProtocolsOfCore() { S --arg c "$1" '.protocols|to_entries[]|select(.value.core==$c)|.key'; }
coreInUse() { # coreInUse <core> —— state 中是否有使用该核心的协议
    [[ -n "$(installedProtocolsOfCore "$1")" ]]
}
protoPort() { S --arg id "$1" '.protocols[$id].port // empty'; }
userCount() { S '.users|length'; }
userNames() { S '.users[].name'; }
userExists() { jq -e --arg n "$1" '.users[]|select(.name==$n)' "${ATR_STATE}" >/dev/null 2>&1; }

# ----------------------------- 状态校验 --------------------------------------
# 返回错误列表(每行一个)，空表示通过。校验的是"候选状态"（stdin）
read -r -d '' JQ_VALIDATE <<'EOF'
def udp_ids: ["tuic","hysteria2"];
def netof($id): if (udp_ids | index($id)) != null then "udp" else "tcp" end;
(.protocols // {}) as $P
| (.users // []) as $U
| ([ $P | to_entries[] | select(.value.port != null)
     | {who: .key, port: .value.port, net: netof(.key)} ]
   + (if (.routing.socks5_in.port // null) != null then [{who:"socks5_in", port:.routing.socks5_in.port, net:"tcp"}] else [] end)
   + (if ((.nginx.subscribe.enabled // false) and ((.nginx.subscribe.port // 0) > 0)) then [{who:"subscribe", port:.nginx.subscribe.port, net:"tcp"}] else [] end)
   + [ (.extra_ports // [])[] | {who:"extra_port", port:., net:"tcp"} ]) as $ports
| [
    # 端口范围
    ($ports[] | select((.port | type) != "number" or .port < 1 or .port > 65535) | "端口不合法: \(.who)=\(.port)"),
    # 端口冲突（同协议类型下端口不得重复）
    ($ports | group_by([.net, .port])[] | select(length > 1) | "端口冲突: \(map(.who) | join(", ")) 同时使用 \(.[0].net)/\(.[0].port)"),
    # 至少一个用户
    (if ($P | length) > 0 and ($U | length) == 0 then "没有用户" else empty end),
    # 用户名唯一
    ($U | group_by(.name)[] | select(length > 1) | "用户名重复: \(.[0].name)")
  ]
| .[]
EOF

# 按注册表补充校验（Reality / TLS 依赖）
validateState() { # stdin: 候选状态 JSON
    local st errs reg_reality reg_tls
    st=$(cat)
    errs=$(printf '%s' "${st}" | jq -r "${JQ_VALIDATE}" 2>&1) || {
        echo "状态校验程序异常: ${errs}"
        return 1
    }
    [[ -n "${errs}" ]] && printf '%s\n' "${errs}"
    # Reality / TLS 依赖（需要注册表信息，故在这里检查）
    reg_reality=$(jq -r --argjson st "${st}" '[.[]|select(.reality==true)|.id] | map(select(. as $i | ($st.protocols[$i] != null)))|length' <<<"${PROTO_REGISTRY}")
    reg_tls=$(jq -r --argjson st "${st}" '[.[]|select(.tls==true)|.id] | map(select(. as $i | ($st.protocols[$i] != null)))|length' <<<"${PROTO_REGISTRY}")
    if [[ "${reg_reality}" != "0" ]]; then
        local f
        for f in sni private_key public_key short_id; do
            if [[ -z "$(printf '%s' "${st}" | jq -r --arg f "${f}" '.reality[$f] // ""')" ]]; then
                echo "Reality 参数缺失: ${f}"
            fi
        done
    fi
    if [[ "${reg_tls}" != "0" ]]; then
        local d mode
        d=$(printf '%s' "${st}" | jq -r '.domain // ""')
        mode=$(printf '%s' "${st}" | jq -r '.tls.mode // "none"')
        [[ -z "${d}" ]] && echo "TLS 类协议需要域名"
        if [[ "${mode}" != "acme" && "${mode}" != "custom" ]]; then
            echo "TLS 类协议需要证书（tls.mode 应为 acme 或 custom）"
        elif [[ -n "${d}" && ( ! -s "${TLS_DIR}/${d}.crt" || ! -s "${TLS_DIR}/${d}.key" ) ]]; then
            echo "证书文件不存在: ${TLS_DIR}/${d}.crt|.key"
        fi
    fi
    return 0
}

# ----------------------------- 用户 -----------------------------------------
# 向候选状态追加用户（不落盘）: stagedUserAdd <name> [uuid] [password]
stagedUserAdd() {
    local name=$1 uuid=${2:-} pass=${3:-}
    [[ -z "${uuid}" ]] && uuid=$(newUUID)
    [[ -z "${pass}" ]] && pass=$(newPassword)
    if stagedGet --arg n "${name}" '.users[]|select(.name==$n)|.name' | grep -q .; then
        echoContent red " ---> 用户名已存在: ${name}"
        return 1
    fi
    if stagedGet --arg u "${uuid}" '.users[]|select(.uuid==$u)|.name' | grep -q .; then
        echoContent red " ---> UUID 已被其他用户使用"
        return 1
    fi
    stagedEdit --arg n "${name}" --arg u "${uuid}" --arg p "${pass}" '.users += [{name:$n,uuid:$u,password:$p}]'
}

# 从候选状态删除用户，至少保留一个
stagedUserDel() {
    local name=$1 cnt
    cnt=$(stagedGet '.users|length')
    if [[ "${cnt}" -le 1 ]]; then
        echoContent red " ---> 至少需要保留一个用户，无法删除"
        return 1
    fi
    if ! stagedGet --arg n "${name}" '.users[]|select(.name==$n)|.name' | grep -q .; then
        echoContent red " ---> 用户不存在: ${name}"
        return 1
    fi
    stagedEdit --arg n "${name}" '.users |= map(select(.name != $n))'
}

# =============================================================================
#  04  内核版本解析 / 下载校验 / 安装 / 升级 / 回退
#      只使用稳定版: GitHub releases/latest API -> 重定向探测 -> 手动输入版本号
# =============================================================================

REPO_SB="SagerNet/sing-box"
REPO_XRAY="XTLS/Xray-core"

coreRepo() { [[ "$1" == "sing-box" ]] && echo "${REPO_SB}" || echo "${REPO_XRAY}"; }
coreBin() { [[ "$1" == "sing-box" ]] && echo "${SB_BIN}" || echo "${XRAY_BIN}"; }
coreUnit() { [[ "$1" == "sing-box" ]] && echo "${SB_UNIT}" || echo "${XRAY_UNIT}"; }
coreConf() { [[ "$1" == "sing-box" ]] && echo "${SB_CONF}" || echo "${XRAY_CONF}"; }
coreLabel() { [[ "$1" == "sing-box" ]] && echo "sing-box" || echo "Xray-core"; }

# 当前已安装版本（形如 1.14.2 / 26.3.27），未安装返回空
coreVersion() {
    local bin
    bin=$(coreBin "$1")
    [[ -x "${bin}" ]] || return 0
    if [[ "$1" == "sing-box" ]]; then
        "${bin}" version 2>/dev/null | awk '/sing-box version/{print $3; exit}'
    else
        "${bin}" version 2>/dev/null | awk 'NR==1{print $2}'
    fi
}

coreInstalled() { [[ -x "$(coreBin "$1")" ]]; }

# ----------------------------- 版本解析 --------------------------------------
_setResolveSource() { [[ -n "${ATR_TMP}" ]] && printf '%s' "$1" >"${ATR_TMP}/resolve_source"; }
lastResolveSource() { cat "${ATR_TMP}/resolve_source" 2>/dev/null; }

# 手动输入版本号（仅交互终端）
askManualVersion() { # askManualVersion <core>
    local core=$1 v="" tries=0
    isInteractive || return 1
    # 本函数的 stdout 会被调用方捕获为版本号，所有界面文字必须走 stderr
    {
        echoContent yellow " ---> 无法自动获取 $(coreLabel "${core}") 最新稳定版本，请手动输入"
        echoContent yellow "      可在 https://github.com/$(coreRepo "${core}")/releases 查看，只接受稳定版(不含 alpha/beta/rc)"
    } >&2
    while ((tries < 3)); do
        tries=$((tries + 1))
        ask v "请输入版本号(例如 v1.14.2，回车放弃):" || return 1
        [[ -z "${v}" ]] && return 1
        if isStableVersion "${v}"; then
            echo "v${v#v}"
            return 0
        fi
        echoContent red " ---> 版本号不合法或不是稳定版: ${v}" >&2
    done
    return 1
}

# 解析某核心的最新稳定版 tag；成功时打印 tag，来源用 lastResolveSource 读取
resolveLatestVersion() { # resolveLatestVersion <core>
    local core=$1 repo tag="" eff=""
    repo=$(coreRepo "${core}")

    # 1) GitHub releases/latest API（该接口本身不返回预发布版；仍用正则二次过滤 beta/rc）
    tag=$(curl -fsSL -m 15 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
    if isStableVersion "${tag}"; then
        _setResolveSource "GitHub API"
        echo "v${tag#v}"
        return 0
    fi
    [[ -n "${tag}" ]] && atrLog "releases/latest returned non-stable tag '${tag}' for ${repo}, falling back"

    # 2) 重定向探测: github.com/<repo>/releases/latest -> .../releases/tag/<tag>
    eff=$(curl -fsSIL -m 15 -o /dev/null -w '%{url_effective}' "$(ghURL "https://github.com/${repo}/releases/latest")" 2>/dev/null)
    tag=${eff##*/}
    if [[ "${eff}" == *"/releases/tag/"* ]] && isStableVersion "${tag}"; then
        _setResolveSource "重定向探测"
        echo "v${tag#v}"
        return 0
    fi

    # 3) 手动输入
    if tag=$(askManualVersion "${core}"); then
        _setResolveSource "手动输入"
        echo "${tag}"
        return 0
    fi
    return 1
}

# 最近的稳定版本列表（用于回退菜单），每行一个 tag
listStableVersions() { # listStableVersions <core> [数量]
    local repo n=${2:-8}
    repo=$(coreRepo "$1")
    curl -fsSL -m 20 "https://api.github.com/repos/${repo}/releases?per_page=40" 2>/dev/null |
        jq -r '.[]|select(.prerelease==false and .draft==false)|.tag_name' 2>/dev/null |
        while read -r t; do isStableVersion "${t}" && echo "${t}"; done | head -n "${n}"
}

# ----------------------------- 下载校验 --------------------------------------
sha256Of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# 取得资产的期望 sha256（取不到返回空）
fetchExpectedSha256() { # fetchExpectedSha256 <core> <tag> <资产名>
    local core=$1 tag=$2 asset=$3
    if [[ "${core}" == "sing-box" ]]; then
        curl -fsSL -m 15 "https://api.github.com/repos/${REPO_SB}/releases/tags/${tag}" 2>/dev/null |
            jq -r --arg n "${asset}" '.assets[]|select(.name==$n)|.digest // empty' 2>/dev/null | sed 's/^sha256://'
    else
        curl -fsSL -m 15 "$(ghURL "https://github.com/${REPO_XRAY}/releases/download/${tag}/${asset}.dgst")" 2>/dev/null |
            awk '/^SHA2-256=/{print $2; exit}'
    fi
}

# ----------------------------- 安装二进制 ------------------------------------
# installCoreBinary <core> <tag>  —— 下载、校验、验证可运行后原子替换；旧版本保留为 .prev
installCoreBinary() {
    local core=$1 tag=$2 ver=${2#v} work url asset newbin dest expected actual
    work=$(mktemp -d "${ATR_TMP:-/tmp}/core.XXXXXX") || return 1
    dest=$(coreBin "${core}")
    mkdir -p "$(dirname "${dest}")"

    if [[ "${core}" == "sing-box" ]]; then
        asset="sing-box-${ver}-${CPU_SB}.tar.gz"
        url="https://github.com/${REPO_SB}/releases/download/${tag}/${asset}"
    else
        asset="${CPU_XRAY}.zip"
        url="https://github.com/${REPO_XRAY}/releases/download/${tag}/${asset}"
    fi

    echoContent green " ---> 下载 $(coreLabel "${core}") ${tag}"
    if ! download "${url}" "${work}/${asset}"; then
        echoContent red " ---> 下载失败: ${url}"
        rm -rf "${work}"
        return 1
    fi

    expected=$(fetchExpectedSha256 "${core}" "${tag}" "${asset}")
    if [[ -n "${expected}" ]]; then
        actual=$(sha256Of "${work}/${asset}")
        if [[ "${actual}" != "${expected}" ]]; then
            echoContent red " ---> SHA256 校验失败，文件可能被篡改或下载不完整"
            echoContent red "      期望: ${expected}"
            echoContent red "      实际: ${actual}"
            rm -rf "${work}"
            return 1
        fi
        echoContent green " ---> SHA256 校验通过"
    else
        echoContent yellow " ---> 未能获取官方校验值，跳过 SHA256 校验"
    fi

    if [[ "${core}" == "sing-box" ]]; then
        tar -xzf "${work}/${asset}" -C "${work}" >/dev/null 2>&1
        newbin=$(find "${work}" -type f -name sing-box | head -n 1)
    else
        mkdir -p "${work}/x"
        unzip -oq "${work}/${asset}" -d "${work}/x" >/dev/null 2>&1
        newbin="${work}/x/xray"
    fi
    if [[ -z "${newbin}" || ! -f "${newbin}" ]]; then
        echoContent red " ---> 解压失败或压缩包内未找到可执行文件"
        rm -rf "${work}"
        return 1
    fi
    chmod 755 "${newbin}"
    if ! "${newbin}" version >/dev/null 2>&1; then
        echoContent red " ---> 下载的核心无法在本机运行（架构/依赖不匹配）"
        rm -rf "${work}"
        return 1
    fi

    [[ -f "${dest}" ]] && cp -f "${dest}" "${dest}.prev"
    cp -f "${newbin}" "${dest}.new" && chmod 755 "${dest}.new" && mv -f "${dest}.new" "${dest}"
    rm -rf "${work}"
    atrLog "installed ${core} ${tag}"
    echoContent green " ---> $(coreLabel "${core}") 安装完成: $(coreVersion "${core}")"
    return 0
}

# ensureCore <core> [进度n] [进度total]  —— 未安装则安装最新稳定版（失败可重试）
ensureCore() {
    local core=$1 tag=""
    [[ -n "${2:-}" ]] && step "$2" "${3:-1}" "安装 $(coreLabel "${core}")"
    if coreInstalled "${core}"; then
        echoContent green " ---> $(coreLabel "${core}") 已安装: $(coreVersion "${core}")"
        [[ "${core}" == "xray" ]] && ensureXrayGeo
        return 0
    fi
    while true; do
        if tag=$(resolveLatestVersion "${core}"); then
            echoContent green " ---> 最新稳定版本: ${tag}（来源: $(lastResolveSource)）"
            if installCoreBinary "${core}" "${tag}"; then
                [[ "${core}" == "xray" ]] && ensureXrayGeo
                return 0
            fi
        else
            echoContent red " ---> 无法确定 $(coreLabel "${core}") 的稳定版本号"
        fi
        if isInteractive && confirm "核心获取失败，是否重新尝试？" n; then
            continue
        fi
        return 1
    done
}

# ----------------------------- 升级 / 回退 -----------------------------------
# 用新核心检查现有配置是否仍然有效；无配置视为通过
coreCheckConfig() { # coreCheckConfig <core> [配置文件]
    local core=$1 conf=${2:-}
    [[ -z "${conf}" ]] && conf=$(coreConf "${core}")
    [[ -f "${conf}" ]] || return 0
    if [[ "${core}" == "sing-box" ]]; then
        "${SB_BIN}" check -c "${conf}" 2>&1
    else
        XRAY_LOCATION_ASSET="${XRAY_DIR}" "${XRAY_BIN}" run -test -c "${conf}" 2>&1
    fi
}

# upgradeCore <core> [指定版本]  —— 升级(或回退)并在失败时恢复旧二进制
upgradeCore() {
    local core=$1 want=${2:-} tag cur
    cur=$(coreVersion "${core}")
    if [[ -n "${want}" ]]; then
        tag=${want}
    else
        tag=$(resolveLatestVersion "${core}") || {
            echoContent red " ---> 无法确定最新稳定版本"
            return 1
        }
        echoContent green " ---> 当前版本: ${cur:-未安装}   最新稳定版: ${tag}（来源: $(lastResolveSource)）"
        if [[ -n "${cur}" && "v${cur}" == "${tag}" ]]; then
            confirm "当前已是最新稳定版，是否仍要重新安装？" n || return 0
        else
            confirm "是否升级到 ${tag}？" y || return 0
        fi
    fi
    installCoreBinary "${core}" "${tag}" || return 1

    local conf out
    conf=$(coreConf "${core}")
    if [[ -f "${conf}" ]]; then
        if ! out=$(coreCheckConfig "${core}"); then
            echoContent red " ---> 新版本无法加载现有配置，已恢复旧版本"
            echoContent yellow "${out}"
            [[ -f "$(coreBin "${core}").prev" ]] && cp -f "$(coreBin "${core}").prev" "$(coreBin "${core}")"
            return 1
        fi
        if serviceActive "$(coreUnit "${core}")" || [[ -f "${ATR_SYSTEMD_DIR}/$(coreUnit "${core}").service" ]]; then
            restartCoreChecked "${core}" || {
                echoContent red " ---> 新版本启动失败，恢复旧版本"
                [[ -f "$(coreBin "${core}").prev" ]] && cp -f "$(coreBin "${core}").prev" "$(coreBin "${core}")"
                restartCoreChecked "${core}" >/dev/null 2>&1
                return 1
            }
        fi
    fi
    echoContent green " ---> $(coreLabel "${core}") 已更新到 $(coreVersion "${core}")"
}

# 回退到历史稳定版: 列出最近稳定版供选择，列表取不到则手动输入
rollbackCore() {
    local core=$1 versions v i choice chosen=""
    echoContent yellow "\n1.只能回退到最近的稳定版本"
    echoContent yellow "2.不保证回退后一定可以正常使用"
    echoContent yellow "3.如果回退的版本不支持当前配置，核心会启动失败；此时会自动恢复"
    echoContent skyBlue "------------------------Version-------------------------------"
    versions=$(listStableVersions "${core}" 8)
    if [[ -n "${versions}" ]]; then
        i=0
        while read -r v; do
            i=$((i + 1))
            echoContent yellow "${i}:${v}"
        done <<<"${versions}"
        echoContent skyBlue "--------------------------------------------------------------"
        ask choice "请输入要回退的版本编号:" || return 1
        if isInt "${choice}"; then
            chosen=$(sed -n "${choice}p" <<<"${versions}")
        fi
    else
        chosen=$(askManualVersion "${core}") || return 1
    fi
    if [[ -z "${chosen}" ]]; then
        echoContent red " ---> 输入有误"
        return 1
    fi
    confirm "回退版本为 ${chosen}，是否继续？" n || return 0
    upgradeCore "${core}" "${chosen}"
}

# ----------------------------- geo 数据 --------------------------------------
# Xray: geosite.dat / geoip.dat（Loyalsoldier），路由中使用 geosite:/geoip: 需要
ensureXrayGeo() {
    [[ -s "${XRAY_DIR}/geosite.dat" && -s "${XRAY_DIR}/geoip.dat" ]] && return 0
    updateXrayGeo
}
updateXrayGeo() {
    mkdir -p "${XRAY_DIR}"
    local ok=0 f
    echoContent green " ---> 更新 Xray geosite/geoip（来源 ${XRAY_GEO_REPO}）"
    for f in geosite.dat geoip.dat; do
        if download "https://github.com/${XRAY_GEO_REPO}/releases/latest/download/${f}" "${XRAY_DIR}/${f}"; then
            ok=$((ok + 1))
        else
            echoContent yellow " ---> ${f} 下载失败（保留旧文件）"
        fi
    done
    ((ok == 2))
}

# sing-box 本地规则集: ensureSingBoxRuleSet <geosite|geoip> <名称>  —— 不存在则下载
ensureSingBoxRuleSet() {
    local kind=$1 name=$2 f base
    f="${SB_RULESET_DIR}/${kind}-${name}.srs"
    [[ -s "${f}" ]] && return 0
    mkdir -p "${SB_RULESET_DIR}"
    base=${SB_GEOSITE_URL}
    [[ "${kind}" == "geoip" ]] && base=${SB_GEOIP_URL}
    download "${base}/${kind}-${name}.srs" "${f}"
}

# 刷新全部已存在的 sing-box 规则集（cron 使用）
updateSingBoxRuleSets() {
    [[ -d "${SB_RULESET_DIR}" ]] || return 0
    local f n kind name base
    for f in "${SB_RULESET_DIR}"/*.srs; do
        [[ -e "${f}" ]] || continue
        n=$(basename "${f}" .srs)
        kind=${n%%-*}
        name=${n#*-}
        base=${SB_GEOSITE_URL}
        [[ "${kind}" == "geoip" ]] && base=${SB_GEOIP_URL}
        download "${base}/${kind}-${name}.srs" "${f}" || echoContent yellow " ---> 规则集 ${n} 更新失败（保留旧文件）"
    done
}

# =============================================================================
#  05  TLS 证书: acme.sh (HTTP-01 / Cloudflare / 阿里云 DNS API) / 已有证书导入 / 续签
#      证书统一放在 ${TLS_DIR}/<域名>.crt|.key；acme.sh 通过 --reloadcmd 在续签后重启核心。
# =============================================================================

ACME_SH="${ACME_HOME}/acme.sh"
ACME_INSTALL_URL="${ACME_INSTALL_URL:-https://get.acme.sh}"
ACME_LOG="${TLS_DIR}/acme.log"

acmeInstalled() { [[ -x "${ACME_SH}" ]]; }

installAcme() {
    acmeInstalled && return 0
    [[ "${ATR_SKIP_PACKAGES:-0}" == "1" && "${ATR_TEST_ACME:-0}" != "1" ]] && return 1
    mkdir -p "${TLS_DIR}"
    echoContent green " ---> 安装 acme.sh"
    curl -fsSL -m 120 "${ACME_INSTALL_URL}" 2>>"${ACME_LOG}" | sh >>"${ACME_LOG}" 2>&1
    if ! acmeInstalled; then
        echoContent red " ---> acme.sh 安装失败"
        tail -n 20 "${ACME_LOG}" 2>/dev/null
        echoContent yellow "错误排查:"
        echoContent yellow "  1.获取 GitHub 文件失败，请稍后再试: https://www.githubstatus.com/"
        echoContent yellow "  2.纯 IPv6 机器需要设置 NAT64 才能访问 GitHub"
        return 1
    fi
    # acme.sh 安装器会写入自己的 cron；若 cron 不可用则补一条
    if command -v crontab >/dev/null 2>&1 && ! crontab -l 2>/dev/null | grep -q "acme.sh"; then
        (
            crontab -l 2>/dev/null
            echo "0 3 * * * \"${ACME_HOME}\"/acme.sh --cron --home \"${ACME_HOME}\" >/dev/null 2>&1"
        ) | crontab -
    fi
    return 0
}

# ----------------------------- 域名/解析检查 ---------------------------------
# 域名解析 IP 是否指向本机（HTTP-01 必须）。返回 0 一致，1 不一致/解析失败
checkDomainPointsHere() { # checkDomainPointsHere <域名>
    local domain=$1 dnsIP="" publicIP="" t=4
    if command -v dig >/dev/null 2>&1; then
        dnsIP=$(dig @1.1.1.1 +time=2 +short "${domain}" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
        [[ -z "${dnsIP}" ]] && dnsIP=$(dig @8.8.8.8 +time=2 +short "${domain}" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    fi
    [[ -z "${dnsIP}" ]] && dnsIP=$(getent ahostsv4 "${domain}" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z "${dnsIP}" ]]; then
        t=6
        if command -v dig >/dev/null 2>&1; then
            dnsIP=$(dig @2606:4700:4700::1111 +time=2 aaaa +short "${domain}" 2>/dev/null | head -n 1)
        fi
        [[ -z "${dnsIP}" ]] && dnsIP=$(getent ahostsv6 "${domain}" 2>/dev/null | awk 'NR==1{print $1}')
    fi
    if [[ -z "${dnsIP}" ]]; then
        echoContent red " ---> 无法通过 DNS 解析到域名 ${domain} 的 IP，请检查域名是否正确、解析是否已生效"
        return 1
    fi
    publicIP=$(getPublicIP "${t}")
    if [[ "${publicIP}" != "${dnsIP}" ]]; then
        echoContent red " ---> 域名解析 IP 与本机 IP 不一致"
        echoContent yellow "      本机 IP : ${publicIP:-未知}"
        echoContent yellow "      DNS 解析: ${dnsIP}"
        echoContent yellow "      如域名开启了 Cloudflare 橙云(代理)，请关闭后等待几分钟，或改用 DNS API 方式申请证书"
        return 1
    fi
    echoContent green " ---> 域名解析校验通过 (${domain} -> ${dnsIP})"
    return 0
}

# ----------------------------- 证书信息 --------------------------------------
# tlsDaysLeft <crt 文件>  -> 剩余天数（负数表示已过期；无法读取返回空）
tlsDaysLeft() {
    local f=$1 end ts now
    [[ -s "${f}" ]] || return 1
    end=$(openssl x509 -noout -enddate -in "${f}" 2>/dev/null | sed 's/^notAfter=//')
    [[ -n "${end}" ]] || return 1
    ts=$(date -d "${end}" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(((ts - now) / 86400))
}

tlsIssuer() { openssl x509 -noout -issuer -in "$1" 2>/dev/null | sed 's/^issuer= *//'; }

# 证书文件是否可用: 私钥与证书匹配 + 覆盖域名 + 未过期
# tlsValidate <crt> <key> <域名>  失败时在 TLS_ERR 里给出原因
TLS_ERR=""
tlsValidate() {
    local crt=$1 key=$2 domain=$3 d pubc pubk
    TLS_ERR=""
    [[ -s "${crt}" && -s "${key}" ]] || {
        TLS_ERR="证书或私钥文件不存在/为空"
        return 1
    }
    openssl x509 -noout -in "${crt}" >/dev/null 2>&1 || {
        TLS_ERR="证书格式不正确（需要 PEM）"
        return 1
    }
    openssl pkey -in "${key}" -noout >/dev/null 2>&1 || {
        TLS_ERR="私钥格式不正确或需要口令（需要无口令 PEM）"
        return 1
    }
    pubc=$(openssl x509 -noout -pubkey -in "${crt}" 2>/dev/null | openssl sha256 2>/dev/null)
    pubk=$(openssl pkey -pubout -in "${key}" 2>/dev/null | openssl sha256 2>/dev/null)
    if [[ -z "${pubc}" || "${pubc}" != "${pubk}" ]]; then
        TLS_ERR="私钥与证书不匹配"
        return 1
    fi
    if ! openssl x509 -noout -checkhost "${domain}" -in "${crt}" 2>/dev/null | grep -q "does match"; then
        TLS_ERR="证书不覆盖域名 ${domain}"
        return 1
    fi
    d=$(tlsDaysLeft "${crt}")
    if [[ -n "${d}" ]] && ((d < 0)); then
        TLS_ERR="证书已过期 ${d#-} 天"
        return 1
    fi
    return 0
}

# 已有证书是否可直接复用（有效且剩余 >7 天）
tlsReusable() { # tlsReusable <域名>
    local d
    tlsValidate "${TLS_DIR}/$1.crt" "${TLS_DIR}/$1.key" "$1" || return 1
    d=$(tlsDaysLeft "${TLS_DIR}/$1.crt")
    [[ -n "${d}" ]] && ((d > 7))
}

# ----------------------------- 导入已有证书 ----------------------------------
tlsImportCustom() { # tlsImportCustom <域名> <crt 路径> <key 路径>
    local domain=$1 crt=$2 key=$3
    if ! tlsValidate "${crt}" "${key}" "${domain}"; then
        echoContent red " ---> 证书不可用: ${TLS_ERR}"
        return 1
    fi
    mkdir -p "${TLS_DIR}"
    install -m 644 "${crt}" "${TLS_DIR}/${domain}.crt"
    install -m 600 "${key}" "${TLS_DIR}/${domain}.key"
    echoContent green " ---> 已导入证书（有效期剩余 $(tlsDaysLeft "${TLS_DIR}/${domain}.crt") 天）"
    echoContent yellow " ---> 自定义证书不会自动续签，请在到期前更换"
    return 0
}

# ----------------------------- acme.sh 申请 ----------------------------------
# 80 端口准备: 被本脚本的 nginx 占用则临时停掉；被其他进程占用则失败
_prepare80() {
    portInUse 80 tcp || return 0
    if serviceActive "${NGX_UNIT}"; then
        echoContent yellow " ---> 临时停止 ${NGX_UNIT} 以释放 80 端口"
        serviceStop "${NGX_UNIT}"
        NGX_WAS_STOPPED=1
        sleep 1
    fi
    if portInUse 80 tcp; then
        echoContent red " ---> 80 端口被占用，HTTP-01 验证无法进行:"
        lsof -i :80 2>/dev/null | grep LISTEN | head -n 3
        echoContent yellow "      请先停止占用 80 端口的程序，或改用 DNS API 方式"
        return 1
    fi
    return 0
}
_restore80() { [[ "${NGX_WAS_STOPPED:-0}" == "1" ]] && systemctl start "${NGX_UNIT}" >/dev/null 2>&1; NGX_WAS_STOPPED=0; }

# acmeIssue <域名> <http|cf|ali> <CA> [通配符 yes|no] [凭据1] [凭据2]
#   cf : 凭据1 = CF_Token        ali: 凭据1 = Ali_Key, 凭据2 = Ali_Secret
# 成功后证书已安装到 ${TLS_DIR}/<域名>.crt|.key
acmeIssue() {
    local domain=$1 method=$2 ca=$3 wildcard=${4:-no} c1=${5:-} c2=${6:-}
    local parent main rc=0 args=() v6=""
    installAcme || return 1
    mkdir -p "${TLS_DIR}"
    parent=${domain#*.}
    if [[ "${method}" != "http" && "${ca}" == "buypass" ]]; then
        echoContent red " ---> buypass 不支持 DNS API 申请证书"
        return 1
    fi
    [[ "${ca}" == "zerossl" ]] && {
        echoContent yellow " ---> ZeroSSL 需要注册邮箱"
        local mail=""
        ask mail "请输入邮箱地址:" || return 1
        [[ "${mail}" == *@*.* ]] || {
            echoContent red " ---> 邮箱格式不正确"
            return 1
        }
        "${ACME_SH}" --register-account -m "${mail}" --server zerossl >>"${ACME_LOG}" 2>&1
    }
    [[ "$(getPublicIP 4)" == "" && -n "$(getPublicIP 6)" ]] && v6="--listen-v6"

    case "${method}" in
    http)
        _prepare80 || return 1
        echoContent green " ---> 生成证书中 (HTTP-01)"
        "${ACME_SH}" --issue -d "${domain}" --standalone -k ec-256 --server "${ca}" ${v6} >>"${ACME_LOG}" 2>&1 || rc=$?
        _restore80
        main=${domain}
        ;;
    cf | ali)
        echoContent green " ---> DNS API 生成证书中"
        if [[ "${wildcard}" == "yes" ]]; then
            args=(-d "*.${parent}" -d "${parent}")
            main="*.${parent}"
        else
            args=(-d "${domain}")
            main=${domain}
        fi
        if [[ "${method}" == "cf" ]]; then
            CF_Token="${c1}" "${ACME_SH}" --issue "${args[@]}" --dns dns_cf -k ec-256 --server "${ca}" ${v6} >>"${ACME_LOG}" 2>&1 || rc=$?
        else
            Ali_Key="${c1}" Ali_Secret="${c2}" "${ACME_SH}" --issue "${args[@]}" --dns dns_ali -k ec-256 --server "${ca}" ${v6} >>"${ACME_LOG}" 2>&1 || rc=$?
        fi
        ;;
    *)
        echoContent red " ---> 未知的申请方式: ${method}"
        return 1
        ;;
    esac
    # acme.sh: 0 成功, 2 表示证书仍在有效期内被跳过（已有证书），均视为可继续安装
    if ((rc != 0 && rc != 2)); then
        echoContent red " ---> 证书申请失败 (acme.sh 退出码 ${rc})，最近日志:"
        tail -n 12 "${ACME_LOG}" | sed 's/\x1b\[[0-9;]*m//g'
        return 1
    fi
    "${ACME_SH}" --installcert -d "${main}" --ecc \
        --fullchain-file "${TLS_DIR}/${domain}.crt" --key-file "${TLS_DIR}/${domain}.key" \
        --reloadcmd "${ATR_SCRIPT_PATH} reload-core" >>"${ACME_LOG}" 2>&1 || {
        echoContent red " ---> 安装证书失败，最近日志:"
        tail -n 8 "${ACME_LOG}" | sed 's/\x1b\[[0-9;]*m//g'
        return 1
    }
    chmod 600 "${TLS_DIR}/${domain}.key" 2>/dev/null
    if ! tlsValidate "${TLS_DIR}/${domain}.crt" "${TLS_DIR}/${domain}.key" "${domain}"; then
        echoContent red " ---> 申请到的证书不可用: ${TLS_ERR}"
        return 1
    fi
    echoContent green " ---> TLS 证书生成成功（有效期剩余 $(tlsDaysLeft "${TLS_DIR}/${domain}.crt") 天，自动续签由 acme.sh 的定时任务负责）"
    return 0
}

# ----------------------------- 交互: 为一个域名准备证书 ------------------------
# tlsSetupInteractive [域名]  成功后设置 TLS_DOMAIN / TLS_MODE / TLS_CA / TLS_DNS_API / TLS_WILDCARD
TLS_DOMAIN=""
TLS_MODE=""
TLS_CA="letsencrypt"
TLS_DNS_API=""
TLS_WILDCARD="false"
tlsSetupInteractive() {
    local domain=${1:-} choice m c1="" c2="" ca wild="no" crt key
    TLS_DOMAIN=""
    TLS_MODE=""
    TLS_DNS_API=""
    TLS_WILDCARD="false"
    echoContent skyBlue "\n================== 配置 TLS 证书 =================="
    echoContent yellow "Tuic / Hysteria2 / Naive / Trojan / WS 等协议需要域名与证书（Reality 不需要）。\n"
    if [[ -z "${domain}" ]]; then
        while true; do
            ask domain "请输入要配置的域名 例: www.example.com:" || return 1
            isDomainName "${domain}" && break
            echoContent red " ---> 域名格式不正确"
        done
    fi
    if tlsReusable "${domain}"; then
        echoContent green " ---> 检测到有效证书（剩余 $(tlsDaysLeft "${TLS_DIR}/${domain}.crt") 天）"
        if confirm "是否直接使用该证书？" y; then
            TLS_DOMAIN=${domain}
            TLS_MODE=$(S '.tls.mode // "none"')
            if [[ "${TLS_MODE}" != "acme" && "${TLS_MODE}" != "custom" ]]; then
                # 状态里没有记录来源: 有 acme.sh 的证书目录就当作 acme，否则视为自定义证书(不自动续签)
                if [[ -d "${ACME_HOME}/${domain}_ecc" ]]; then TLS_MODE=acme; else TLS_MODE=custom; fi
            fi
            return 0
        fi
    fi
    echoContent red "\n=============================================================="
    echoContent yellow "1.acme.sh HTTP-01 [默认，需 80 端口空闲且域名已解析到本机]"
    echoContent yellow "2.acme.sh DNS API - Cloudflare [支持 NAT/橙云/通配符]"
    echoContent yellow "3.acme.sh DNS API - 阿里云 [支持 NAT/通配符]"
    echoContent yellow "4.使用已有证书文件"
    echoContent red "=============================================================="
    ask choice "请选择[回车默认1]:" || return 1
    case "${choice:-1}" in
    1) m=http ;;
    2) m=cf ;;
    3) m=ali ;;
    4) m=custom ;;
    *)
        echoContent red " ---> 选择错误"
        return 1
        ;;
    esac
    if [[ "${m}" == "custom" ]]; then
        ask crt "证书文件路径(PEM，建议 fullchain):" || return 1
        ask key "私钥文件路径(PEM，无口令):" || return 1
        tlsImportCustom "${domain}" "${crt}" "${key}" || return 1
        TLS_DOMAIN=${domain}
        TLS_MODE=custom
        return 0
    fi
    echoContent yellow "\n证书颁发机构: 1.letsencrypt[默认]  2.zerossl  3.buypass[不支持DNS]"
    ask choice "请选择[回车默认1]:" || return 1
    case "${choice:-1}" in 2) ca=zerossl ;; 3) ca=buypass ;; *) ca=letsencrypt ;; esac
    if [[ "${m}" == "http" ]]; then
        checkDomainPointsHere "${domain}" || {
            confirm "域名解析校验未通过，仍要继续尝试申请吗？" n || return 1
        }
        allowPort80Hint
    elif [[ "${m}" == "cf" ]]; then
        echoContent yellow "\n Cloudflare API Token 需要 Zone.DNS 编辑权限，教程: https://www.v2ray-agent.com/archives/1701160377972"
        ask c1 "请输入 API Token:" || return 1
        [[ -n "${c1}" ]] || {
            echoContent red " ---> 不能为空"
            return 1
        }
        confirm "是否为 *.${domain#*.} 申请通配符证书？" n && wild=yes
    else
        ask c1 "请输入 Ali Key:" || return 1
        ask c2 "请输入 Ali Secret:" || return 1
        [[ -n "${c1}" && -n "${c2}" ]] || {
            echoContent red " ---> 不能为空"
            return 1
        }
        confirm "是否为 *.${domain#*.} 申请通配符证书？" n && wild=yes
    fi
    acmeIssue "${domain}" "${m}" "${ca}" "${wild}" "${c1}" "${c2}" || return 1
    TLS_DOMAIN=${domain}
    TLS_MODE=acme
    TLS_CA=${ca}
    [[ "${m}" != "http" ]] && TLS_DNS_API=${m}
    [[ "${wild}" == "yes" ]] && TLS_WILDCARD=true
    return 0
}

# HTTP-01 需要 80/tcp 对外开放：尝试放行
allowPort80Hint() {
    fwOpen 80 tcp
}

# 把 tlsSetupInteractive 的结果写入候选状态
stagedSetTLS() {
    stagedEdit --arg d "${TLS_DOMAIN}" --arg m "${TLS_MODE}" --arg ca "${TLS_CA}" --arg api "${TLS_DNS_API}" --argjson w "${TLS_WILDCARD}" \
        '.domain=$d | .tls.mode=$m | .tls.ca=$ca | .tls.dns_api=$api | .tls.wildcard=$w'
}

# ----------------------------- 管理/续签 -------------------------------------
tlsStatusLine() {
    local d crt days
    d=$(S '.domain // ""')
    [[ -n "${d}" ]] || {
        echoContent yellow " ---> 尚未配置域名/证书"
        return 1
    }
    crt="${TLS_DIR}/${d}.crt"
    days=$(tlsDaysLeft "${crt}")
    echoContent skyBlue " ---> 域名: ${d}"
    echoContent skyBlue " ---> 方式: $(S '.tls.mode // "-"')   颁发机构: $(tlsIssuer "${crt}")"
    if [[ -n "${days}" ]]; then
        if ((days < 0)); then echoContent red " ---> 证书已过期 ${days#-} 天"; else echoContent green " ---> 证书剩余有效期: ${days} 天"; fi
    fi
}

# 立即续签并重启核心（CLI: atr renew-tls；也可在菜单里手动触发）
renewTLSNow() {
    local d mode main
    d=$(S '.domain // ""')
    mode=$(S '.tls.mode // "none"')
    [[ -n "${d}" ]] || {
        echoContent red " ---> 未配置域名"
        return 1
    }
    if [[ "${mode}" == "custom" ]]; then
        echoContent yellow " ---> 使用的是自定义证书，无法自动续签，请手动替换后执行: ${ATR_CMD} (证书管理 -> 导入证书)"
        return 1
    fi
    acmeInstalled || {
        echoContent red " ---> 未安装 acme.sh"
        return 1
    }
    main=${d}
    [[ "$(S '.tls.wildcard')" == "true" ]] && main="*.${d#*.}"
    local viaDNS=0
    [[ -n "$(S '.tls.dns_api // ""')" ]] && viaDNS=1
    ((viaDNS)) || _prepare80 || return 1
    "${ACME_SH}" --renew -d "${main}" --ecc --force >>"${ACME_LOG}" 2>&1
    local rc=$?
    ((viaDNS)) || _restore80
    if ((rc != 0 && rc != 2)); then
        echoContent red " ---> 续签失败 (退出码 ${rc})"
        tail -n 10 "${ACME_LOG}" | sed 's/\x1b\[[0-9;]*m//g'
        return 1
    fi
    "${ACME_SH}" --installcert -d "${main}" --ecc --fullchain-file "${TLS_DIR}/${d}.crt" --key-file "${TLS_DIR}/${d}.key" \
        --reloadcmd "${ATR_SCRIPT_PATH} reload-core" >>"${ACME_LOG}" 2>&1
    chmod 600 "${TLS_DIR}/${d}.key" 2>/dev/null
    echoContent green " ---> 续签完成，剩余有效期 $(tlsDaysLeft "${TLS_DIR}/${d}.crt") 天"
    reloadAll
}

# =============================================================================
#  06  Reality: 目标域名(SNI)选择与检测 / 密钥对 / Short ID / ML-DSA-65
#      注意: 这里只"生成"并返回，绝不写盘；密钥由 apply 事务在配置校验通过后一并落盘
# =============================================================================

# 推荐的 Reality 目标域名（均为 TLS1.3 + h2，站点稳定、证书链正常）
read -r -d '' REALITY_SNI_LIST <<'EOF'
dl.google.com
www.apple.com
download-installer.cdn.mozilla.net
www.python.org
www.amd.com
www.microsoft.com
addons.mozilla.org
www.nvidia.com
s0.awsstatic.com
d1.awsstatic.com
images-na.ssl-images-amazon.com
m.media-amazon.com
player.live-video.net
www.oracle.com
www.cisco.com
www.samsung.com
EOF

# 前 5 个域名的证书链较短（实测 Xray 与 sing-box 作服务端都能完成 Reality 握手）；
# 其余域名只适合 sing-box 作服务端（见 realityXrayCompat）。
REALITY_CORE_HINT=""   # 非空且为 xray 时，域名检测会额外做 Xray 兼容性检查

# 解析 "host" 或 "host:port"，成功则设置 SNI_HOST / SNI_PORT
SNI_HOST=""
SNI_PORT=443
parseSniInput() {
    local in
    in=$(trim "${1:-}")
    in=${in#https://}
    in=${in#http://}
    in=${in%%/*}
    SNI_HOST=${in%%:*}
    SNI_PORT=443
    if [[ "${in}" == *:* ]]; then
        SNI_PORT=${in##*:}
    fi
    isDomainName "${SNI_HOST}" && isPort "${SNI_PORT}"
}

# Xray 作为 Reality 服务端的兼容性检查。
# 实测: 目标同时满足 "支持 X25519MLKEM768" 且 "证书链 > 3500 字节" 时，Xray 服务端无法完成握手
#      （日志 "handshake did not complete successfully"；ML-DSA-65 也无法解决），而 sing-box 作服务端没有此问题。
# 返回 0=兼容 1=不兼容(已打印原因) 2=无法判断(本机没有 xray)
realityXrayCompat() { # realityXrayCompat <host> <port>
    local ping len
    [[ -x "${XRAY_BIN}" ]] || return 2
    ping=$(timeout 15 "${XRAY_BIN}" tls ping "$1:$2" 2>/dev/null)
    len=$(awk '/Certificate chain.s total length:/{print $5; exit}' <<<"${ping}")
    if grep -q "X25519MLKEM768" <<<"${ping}" && isInt "${len}" && ((len > 3500)); then
        echoContent red "      ✗ 该目标证书链较长(${len} 字节)且启用了 X25519MLKEM768 —— Xray-core 作服务端无法与它完成 Reality 握手"
        echoContent yellow "        (sing-box 作服务端不受影响)。请选推荐列表前几项，如 dl.google.com / www.apple.com / www.python.org"
        return 1
    fi
    echoContent green "      ✓ Xray 兼容性检查通过（证书链 ${len:-?} 字节）"
    return 0
}

# realityCoreHint [正在安装的核心] —— 只要有 Reality 协议由 Xray 承载（已安装或即将安装），就返回 xray。
# Reality 目标域名是各协议共用的，所以只要 Xray 参与，就必须选 Xray 能握手的域名。
realityCoreHint() {
    local core=${1:-} id
    if [[ "${core}" == "xray" ]]; then
        echo xray
        return
    fi
    while read -r id; do
        [[ -z "${id}" ]] && continue
        if [[ "$(protoField "${id}" reality)" == "true" ]]; then
            echo xray
            return
        fi
    done < <(installedProtocolsOfCore xray 2>/dev/null)
    echo ""
}

# 检测 Reality 目标是否可用；返回 0=通过(可有警告) 1=不通过
# 检查项: TLS1.3 握手 + X25519 + h2(ALPN) + 握手耗时 + 是否为 Cloudflare 代理域名
checkRealityTarget() { # checkRealityTarget <host> [port] [xray]
    local host=$1 port=${2:-443} forCore=${3:-${REALITY_CORE_HINT}} out proto alpn t0 t1 ms cf failed=0
    echoContent skyBlue "\n ---> 检测 Reality 目标 ${host}:${port}"
    if ! command -v openssl >/dev/null 2>&1; then
        echoContent yellow "      未找到 openssl，跳过 TLS1.3 可达性检测"
        return 0
    fi
    t0=$(date +%s%N)
    out=$(timeout 12 openssl s_client -connect "${host}:${port}" -servername "${host}" -tls1_3 -alpn h2 -curves X25519 </dev/null 2>&1)
    if grep -qiE 'unknown option|unrecognized option' <<<"${out}"; then
        out=$(timeout 12 openssl s_client -connect "${host}:${port}" -servername "${host}" -tls1_3 -alpn h2 </dev/null 2>&1)
    fi
    t1=$(date +%s%N)
    ms=$(((t1 - t0) / 1000000))

    proto=$(grep -m1 -oE 'TLSv1\.3' <<<"${out}")
    alpn=$(sed -n 's/^ALPN protocol: *//p' <<<"${out}" | head -n 1)

    if [[ -z "${proto}" ]]; then
        echoContent red "      ✗ 不支持 TLSv1.3（或无法连接）—— Reality 要求目标必须支持 TLS1.3"
        local why
        why=$(grep -m1 -iE 'errno|refused|timed out|unreachable|no route|resolve|handshake failure|alert' <<<"${out}")
        [[ -n "${why}" ]] && echoContent yellow "        原因: ${why}"
        failed=1
    else
        echoContent green "      ✓ TLSv1.3 握手成功（X25519），耗时约 ${ms}ms"
        if ((ms > 800)); then
            echoContent yellow "      ! 握手耗时偏高(${ms}ms)，目标离本机较远时会增加首包延迟，建议换一个更近的域名"
        fi
    fi
    if ((failed == 0)); then
        if [[ "${alpn}" == "h2" ]]; then
            echoContent green "      ✓ 支持 HTTP/2 (ALPN h2)"
        else
            echoContent yellow "      ! 目标未协商 h2（ALPN: ${alpn:-无}），建议选择支持 h2 的域名，流量特征更像正常浏览器"
        fi
    fi

    # 不允许使用被 Cloudflare 代理的域名: 否则回源探测流量会被他人滥用
    cf=$(curl -s -m 6 "https://${host}:${port}/cdn-cgi/trace" 2>/dev/null | grep -c 'visit_scheme=https')
    if [[ "${cf}" != "0" ]]; then
        echoContent red "      ✗ 该域名已启用 Cloudflare 代理，禁止作为 Reality 目标（会导致 VPS 流量被他人滥用）"
        failed=1
    fi
    if ((failed == 0)) && [[ "${forCore}" == "xray" ]]; then
        realityXrayCompat "${host}" "${port}" || failed=1
    fi
    ((failed == 0))
}

# 交互选择 Reality 目标。成功时设置 PICK_SNI / PICK_PORT 并返回 0
PICK_SNI=""
PICK_PORT=443
realityPickSNI() { # realityPickSNI [当前值 host:port]
    local current=${1:-} choice i=0 line total count
    local -a list=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && list+=("${line}")
    done <<<"${REALITY_SNI_LIST}"
    total=${#list[@]}

    echoContent skyBlue "\n================ 配置 Reality 目标域名(SNI) ==============="
    echoContent yellow "# 注意事项"
    echoContent yellow "选择一个 TLS1.3 + h2 的真实站点；客户端的 SNI 与回源目标都使用它。"
    echoContent yellow "建议选离本机网络近、非 Cloudflare 代理、非自己的域名。\n"
    count=12
    ((count > total)) && count=${total}
    for ((i = 0; i < count; i++)); do
        echoContent yellow "$((i + 1)).${list[i]}"
    done
    echoContent yellow "r.随机推荐域名"
    echoContent yellow "直接输入域名(可带端口，例如 example.com:443) 即为自定义"
    [[ -n "${current}" ]] && echoContent green "当前: ${current}"

    while true; do
        ask choice "请选择[回车=随机]:" || return 1
        [[ -z "${choice}" || "${choice}" == "r" || "${choice}" == "R" ]] && choice=$((RANDOM % total + 1))
        if isInt "${choice}" && ((10#${choice} >= 1 && 10#${choice} <= total)); then
            choice=${list[$((10#${choice} - 1))]}
        fi
        if ! parseSniInput "${choice}"; then
            echoContent red " ---> 域名或端口不合法: ${choice}"
            continue
        fi
        if checkRealityTarget "${SNI_HOST}" "${SNI_PORT}"; then
            PICK_SNI=${SNI_HOST}
            PICK_PORT=${SNI_PORT}
            echoContent yellow "\n ---> 客户端可用域名: ${PICK_SNI}:${PICK_PORT}"
            return 0
        fi
        if confirm "该目标未通过检测，仍要强制使用吗？(不推荐)" n; then
            PICK_SNI=${SNI_HOST}
            PICK_PORT=${SNI_PORT}
            echoContent yellow "\n ---> 已强制使用: ${PICK_SNI}:${PICK_PORT}"
            return 0
        fi
        echoContent yellow " ---> 请重新选择"
    done
}

# ----------------------------- 密钥生成（只返回，不落盘） ---------------------
# genRealityKeypair  -> 打印 "私钥 公钥"（空格分隔）
genRealityKeypair() {
    local out priv pub
    if [[ -x "${SB_BIN}" ]]; then
        out=$("${SB_BIN}" generate reality-keypair 2>/dev/null)
        priv=$(awk '/PrivateKey/{print $2; exit}' <<<"${out}")
        pub=$(awk '/PublicKey/{print $2; exit}' <<<"${out}")
    elif [[ -x "${XRAY_BIN}" ]]; then
        out=$("${XRAY_BIN}" x25519 2>/dev/null)
        priv=$(awk '/PrivateKey/{print $NF; exit}' <<<"${out}")
        # 新版输出 "Password (PublicKey): xxx"，旧版 "Public key: xxx"
        pub=$(awk '/[Pp]ublic ?[Kk]ey|Password/{print $NF; exit}' <<<"${out}")
    else
        return 1
    fi
    [[ -n "${priv}" && -n "${pub}" ]] || return 1
    printf '%s %s\n' "${priv}" "${pub}"
}

# 校验一对密钥是否匹配（需要 Xray 才能由私钥推导公钥）；无法校验时返回 2
verifyRealityKeypair() { # verifyRealityKeypair <priv> <pub>
    [[ -x "${XRAY_BIN}" ]] || return 2
    local derived
    derived=$("${XRAY_BIN}" x25519 -i "$1" 2>/dev/null | awk '/[Pp]ublic ?[Kk]ey|Password/{print $NF; exit}')
    [[ -n "${derived}" ]] || return 2
    [[ "${derived}" == "$2" ]]
}

genShortId() { randHex 16; }

# ----------------------------- 写入候选状态 -----------------------------------
# stagedSetReality <sni> <dest_port> [重新生成密钥 yes|no] —— 只修改候选状态
stagedSetReality() {
    local sni=$1 port=$2 regen=${3:-no} kp priv pub sid
    local curPriv
    curPriv=$(stagedGet '.reality.private_key // ""')
    if [[ -z "${curPriv}" || "${regen}" == "yes" ]]; then
        kp=$(genRealityKeypair) || {
            echoContent red " ---> 无法生成 Reality 密钥对（需要先安装 sing-box 或 Xray）"
            return 1
        }
        priv=${kp%% *}
        pub=${kp##* }
        stagedEdit --arg p "${priv}" --arg u "${pub}" '.reality.private_key=$p | .reality.public_key=$u' || return 1
    fi
    sid=$(stagedGet '.reality.short_id // ""')
    if [[ -z "${sid}" || "${regen}" == "yes" ]]; then
        stagedEdit --arg s "$(genShortId)" '.reality.short_id=$s' || return 1
    fi
    stagedEdit --arg sni "${sni}" --argjson port "${port}" '.reality.sni=$sni | .reality.dest_port=$port'
}

# =============================================================================
#  07  配置渲染: state.json --jq--> sing-box / Xray 配置
#      所有值都通过 jq 的 --arg/--argjson 传入，密码/路径里的任何字符都不会破坏 JSON。
#      渲染是纯函数: 同一份状态永远得到同一份配置（不含随机数）。
#
#  路由 token 约定（存于 state.routing.*）:
#      domain:example.com   域名后缀        geosite:netflix  规则集(域名)
#      geoip:cn             规则集(IP)      ip:1.2.3.0/24    IP/CIDR
# =============================================================================

# ----------------------------- sing-box --------------------------------------
read -r -d '' JQ_SINGBOX <<'EOF'
. as $S
| ($S.path // "") as $P
| ($S.routing // {}) as $R
| ($S.domain // "") as $D
| def cert: {certificate_path: ($tlsdir + "/" + $D + ".crt"), key_path: ($tlsdir + "/" + $D + ".key")};
  def tlsCert: ({enabled: true, server_name: $D} + cert);
  def tlsReality: {enabled: true, server_name: $S.reality.sni,
      reality: {enabled: true,
                handshake: {server: $S.reality.sni, server_port: ($S.reality.dest_port // 443)},
                private_key: $S.reality.private_key, short_id: [$S.reality.short_id]}};
  def users($p):
    $S.users | map(
      if ($p == "vless_reality_vision" or $p == "vless_vision_tls") then {name: .name, uuid: .uuid, flow: "xtls-rprx-vision"}
      elif ($p == "vless_ws" or $p == "vless_reality_grpc") then {name: .name, uuid: .uuid}
      elif ($p == "vmess_ws" or $p == "vmess_httpupgrade") then {name: .name, uuid: .uuid, alterId: 0}
      elif ($p == "tuic") then {name: .name, uuid: .uuid, password: .password}
      elif ($p == "naive") then {username: .name, password: .password}
      else {name: .name, password: .password} end);
  def inbound($id; $c):
    if $id == "vless_reality_vision" then {type: "vless", tag: "vless-reality-vision", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsReality}
    elif $id == "anytls_reality" then {type: "anytls", tag: "anytls-reality", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsReality}
    elif $id == "tuic" then {type: "tuic", tag: "tuic", listen: $listen, listen_port: $c.port, users: users($id), congestion_control: ($c.congestion // "bbr"), tls: (tlsCert + {alpn: ["h3"]})}
    elif $id == "hysteria2" then {type: "hysteria2", tag: "hysteria2", listen: $listen, listen_port: $c.port, users: users($id),
        up_mbps: ($c.down_mbps // 100), down_mbps: ($c.up_mbps // 50), tls: (tlsCert + {alpn: ["h3"]})}
    elif $id == "naive" then {type: "naive", tag: "naive", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert}
    elif $id == "vless_vision_tls" then {type: "vless", tag: "vless-vision-tls", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert}
    elif $id == "vless_ws" then {type: "vless", tag: "vless-ws", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert,
        transport: {type: "ws", path: ("/" + $P + "ws"), max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol"}}
    elif $id == "vmess_ws" then {type: "vmess", tag: "vmess-ws", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert,
        transport: {type: "ws", path: ("/" + $P + "vws"), max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol"}}
    elif $id == "trojan" then {type: "trojan", tag: "trojan", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert}
    elif $id == "vless_reality_grpc" then {type: "vless", tag: "vless-reality-grpc", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsReality,
        transport: {type: "grpc", service_name: "grpc"}}
    elif $id == "vmess_httpupgrade" then {type: "vmess", tag: "vmess-httpupgrade", listen: "127.0.0.1", listen_port: $hup, users: users($id),
        transport: {type: "httpupgrade", path: ("/" + $P + "hu")}}
    elif $id == "anytls_tls" then {type: "anytls", tag: "anytls-tls", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert}
    else empty end;
  # ---- 路由 token 工具 ----
  def dom($t): [$t[] | select(startswith("domain:")) | .[7:]];
  def gsite($t): [$t[] | select(startswith("geosite:")) | .[8:]];
  def gip($t): [$t[] | select(startswith("geoip:")) | .[6:]];
  def ipc($t): [$t[] | select(startswith("ip:")) | .[3:]];
  # 同一条规则内不同字段是 AND 关系，所以域名与规则集必须拆成两条规则
  def routeTo($t; $ob):
    [ (if (dom($t) | length) > 0 then {domain_suffix: dom($t), outbound: $ob} else empty end),
      (if (gsite($t) | length) > 0 then {rule_set: [gsite($t)[] | "geosite-" + .], outbound: $ob} else empty end) ];
  def rejectDom($t):
    [ (if (dom($t) | length) > 0 then {domain_suffix: dom($t), action: "reject"} else empty end),
      (if (gsite($t) | length) > 0 then {rule_set: [gsite($t)[] | "geosite-" + .], action: "reject"} else empty end) ];
  def dnsRouteTo($t; $srv):
    [ (if (dom($t) | length) > 0 then {domain_suffix: dom($t), server: $srv} else empty end),
      (if (gsite($t) | length) > 0 then {rule_set: [gsite($t)[] | "geosite-" + .], server: $srv} else empty end) ];

  ($R.global // "") as $G
  | ($R.blacklist // {}) as $B
  | ($R.warp.config // {}) as $W
  | (($W.private_key // "") != "") as $haveWarp
  | ((($R.warp.v4.domains // []) | length) > 0 or $G == "warp_v4") as $useW4
  | ((($R.warp.v6.domains // []) | length) > 0 or $G == "warp_v6") as $useW6
  | ((($R.ipv6.domains // []) | length) > 0 or $G == "ipv6") as $useV6
  | ((($R.socks5_out.server // "") != "") and ((($R.socks5_out.domains // []) | length) > 0 or $G == "socks5")) as $useS5
  | ((($R.socks5_in.port // 0) > 0)) as $haveS5in
  | ([ ($B.domains // [])[], ($B.allow // [])[], ($R.warp.v4.domains // [])[], ($R.warp.v6.domains // [])[],
       ($R.ipv6.domains // [])[], ($R.socks5_out.domains // [])[], ($R.socks5_in.domains // [])[],
       ($R.dns_unlock.domains // [])[], ($B.ips // [])[] ]
     + (if ($B.cn // false) then ["geosite:cn", "geoip:cn"] else [] end)
     | map(select(startswith("geosite:") or startswith("geoip:"))) | unique) as $setTokens
  | ([ $S.protocols | to_entries[] | select(.value.core == "sing-box") | inbound(.key; .value) ]
     + (if $haveS5in then [{type: "socks", tag: "socks5_inbound", listen: $listen, listen_port: $R.socks5_in.port,
                            users: [{username: $R.socks5_in.user, password: $R.socks5_in.pass}]}] else [] end)) as $inbounds
  | {
      log: {level: (if $debug == "1" then "debug" else "warn" end), timestamp: true},
      dns: {
        servers: ([{type: "local", tag: "local"}]
                  + (if ($R.dns_unlock.server // "") != "" then [{type: "udp", tag: "dnsRouting", server: $R.dns_unlock.server}] else [] end)
                  + (if (($R.sni_proxy.ip // "") != "" and (dom($R.sni_proxy.domains // []) | length) > 0)
                     then [{type: "hosts", tag: "sni_hosts",
                            predefined: (reduce dom($R.sni_proxy.domains // [])[] as $d ({}; .[$d] = $R.sni_proxy.ip))}] else [] end)),
        rules: ((if ($R.dns_unlock.server // "") != "" then dnsRouteTo(($R.dns_unlock.domains // []); "dnsRouting") else [] end)
                + (if (($R.sni_proxy.ip // "") != "" and (dom($R.sni_proxy.domains // []) | length) > 0)
                   then [{domain: dom($R.sni_proxy.domains // []), server: "sni_hosts"}] else [] end))
      },
      inbounds: $inbounds,
      outbounds: ([{type: "direct", tag: "direct"}]
                  + (if $useV6 then [{type: "direct", tag: "IPv6_out", domain_resolver: {server: "local", strategy: "ipv6_only"}}] else [] end)
                  + (if $useS5 then [{type: "socks", tag: "socks5_outbound", server: $R.socks5_out.server, server_port: $R.socks5_out.port,
                                      version: "5", username: ($R.socks5_out.user // ""), password: ($R.socks5_out.pass // "")}] else [] end)),
      endpoints: ((if ($haveWarp and $useW4) then [{type: "wireguard", tag: "warp_v4", address: ["172.16.0.2/32"], private_key: $W.private_key,
                    peers: [{address: "162.159.192.1", port: 2408, public_key: $W.public_key, reserved: $W.reserved, allowed_ips: ["0.0.0.0/0", "::/0"]}]}] else [] end)
                  + (if ($haveWarp and $useW6) then [{type: "wireguard", tag: "warp_v6", address: [($W.address_v6 + "/128")], private_key: $W.private_key,
                    peers: [{address: "162.159.192.1", port: 2408, public_key: $W.public_key, reserved: $W.reserved, allowed_ips: ["0.0.0.0/0", "::/0"]}]}] else [] end)),
      route: {
        default_domain_resolver: "local",
        rules: ([{action: "sniff"}, {protocol: "dns", action: "hijack-dns"}]
                # Socks5 入站: 仅允许指定来源 IP 访问指定目标，其余一律拒绝（它是明文代理，绝不能对外开放）
                + (if $haveS5in then
                     ((if ($R.socks5_in.ip_strategy // "") != "" then [{inbound: "socks5_inbound", action: "resolve", strategy: $R.socks5_in.ip_strategy}] else [] end)
                      + (if ($R.socks5_in.all // false) then [{inbound: ["socks5_inbound"], source_ip_cidr: ($R.socks5_in.allow_ips // []), outbound: "direct"}]
                         else ([ (if (dom($R.socks5_in.domains // []) | length) > 0 then {inbound: ["socks5_inbound"], source_ip_cidr: ($R.socks5_in.allow_ips // []), domain_suffix: dom($R.socks5_in.domains // []), outbound: "direct"} else empty end),
                                 (if (gsite($R.socks5_in.domains // []) | length) > 0 then {inbound: ["socks5_inbound"], source_ip_cidr: ($R.socks5_in.allow_ips // []), rule_set: [gsite($R.socks5_in.domains // [])[] | "geosite-" + .], outbound: "direct"} else empty end) ]) end)
                      + [{inbound: ["socks5_inbound"], action: "reject"}])
                   else [] end)
                + (if ($R.block_bt // false) then [{protocol: "bittorrent", action: "reject"}] else [] end)
                + (if (($B.allow // []) | length) > 0 then routeTo(($B.allow // []); "direct") else [] end)
                + rejectDom(($B.domains // []))
                + (if (($B.ips // []) | length) > 0 then
                     ((if (ipc($B.ips) | length) > 0 then [{ip_cidr: ipc($B.ips), action: "reject"}] else [] end)
                      + (if (gip($B.ips) | length) > 0 then [{rule_set: [gip($B.ips)[] | "geoip-" + .], action: "reject"}] else [] end))
                   else [] end)
                + (if ($B.cn // false) then [{rule_set: ["geosite-cn"], action: "reject"}, {rule_set: ["geoip-cn"], action: "reject"}] else [] end)
                + (if ($haveWarp and ($R.warp.v4.domains // []) != []) then routeTo(($R.warp.v4.domains // []); "warp_v4") else [] end)
                + (if ($haveWarp and ($R.warp.v6.domains // []) != []) then routeTo(($R.warp.v6.domains // []); "warp_v6") else [] end)
                + (if (($R.ipv6.domains // []) | length) > 0 then routeTo(($R.ipv6.domains // []); "IPv6_out") else [] end)
                + (if ($useS5 and (($R.socks5_out.domains // []) | length) > 0) then routeTo(($R.socks5_out.domains // []); "socks5_outbound") else [] end)),
        rule_set: ($setTokens | map((split(":")) as $x | {tag: ($x[0] + "-" + $x[1]), type: "local", format: "binary",
                                                         path: ($rsdir + "/" + $x[0] + "-" + $x[1] + ".srs")})),
        final: (if $G == "warp_v4" and $haveWarp then "warp_v4"
                elif $G == "warp_v6" and $haveWarp then "warp_v6"
                elif $G == "ipv6" then "IPv6_out"
                elif $G == "socks5" and $useS5 then "socks5_outbound"
                else "direct" end)
      }
    }
  | (if (.endpoints | length) == 0 then del(.endpoints) else . end)
  | (if (.dns.rules | length) == 0 then .dns |= del(.rules) else . end)
  | (if (.route.rule_set | length) == 0 then .route |= del(.rule_set) else . end)
EOF

# 入站监听地址: 内核有 IPv6 时用 "::"(双栈)，IPv6 被禁用的机器上绑定 "::" 会失败，回退 0.0.0.0
sbListenAddr() { if [[ -e /proc/net/if_inet6 ]]; then echo "::"; else echo "0.0.0.0"; fi; }

# renderSingBox <state.json 路径>  -> stdout: sing-box 配置
renderSingBox() {
    jq --arg tlsdir "${TLS_DIR}" --arg rsdir "${SB_RULESET_DIR}" --arg listen "$(sbListenAddr)" \
        --arg debug "$(jq -r 'if .log.debug then "1" else "0" end' "$1")" \
        --argjson hup "${SB_HTTPUPGRADE_PORT}" "${JQ_SINGBOX}" "$1"
}

# ----------------------------- Xray ------------------------------------------
read -r -d '' JQ_XRAY <<'EOF'
. as $S
| ($S.path // "") as $P
| ($S.routing // {}) as $R
| ($S.domain // "") as $D
| ($S.protocols // {}) as $PR
| def tlsCert: {rejectUnknownSni: true, minVersion: "1.2",
                certificates: [{certificateFile: ($tlsdir + "/" + $D + ".crt"), keyFile: ($tlsdir + "/" + $D + ".key"), ocspStapling: 3600}]};
  def xusers($p):
    $S.users | map(
      if ($p == "vless_reality_vision" or $p == "vless_vision_tls") then {id: .uuid, flow: "xtls-rprx-vision", email: (.name + "@" + $p)}
      elif ($p == "vmess_ws") then {id: .uuid, alterId: 0, email: (.name + "@" + $p)}
      elif ($p == "trojan") then {password: .password, email: (.name + "@" + $p)}
      else {id: .uuid, email: (.name + "@" + $p)} end);
  def realityS($c):
    {show: false, target: ($S.reality.sni + ":" + (($S.reality.dest_port // 443) | tostring)), xver: 0,
     serverNames: [$S.reality.sni], privateKey: $S.reality.private_key, shortIds: [$S.reality.short_id]}
    + (if ($S.reality.mldsa_seed // "") != "" then {mldsa65Seed: $S.reality.mldsa_seed, minClientVer: "1.8.2", maxTimeDiff: 70000} else {} end);
  def sniffing: if $sniff == "1" then {sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}} else {} end;
  # Vision 前置的回落链: 默认回落到 nginx(或 Trojan -> nginx)，h2 回落到 31302，WS 按路径回落
  def fallbacks:
    [ (if ($PR.trojan.core // "") == "xray" then {dest: $trojanPort, xver: 1} else {dest: $ngxPort, xver: 1} end),
      {alpn: "h2", dest: $ngxH2Port, xver: 1} ]
    + (if ($PR.vless_ws.core // "") == "xray" then [{path: ("/" + $P + "ws"), dest: $wsPort, xver: 1}] else [] end)
    + (if ($PR.vmess_ws.core // "") == "xray" then [{path: ("/" + $P + "vws"), dest: $vwsPort, xver: 1}] else [] end);
  def inbound($id; $c):
    if $id == "vless_vision_tls" then
      {port: $c.port, protocol: "vless", tag: "VLESSTCP",
       settings: {clients: xusers($id), decryption: "none", fallbacks: fallbacks},
       streamSettings: {network: "tcp", security: "tls", tlsSettings: (tlsCert + {alpn: (if ($S.alpn // "h2") == "http/1.1" then ["http/1.1", "h2"] else ["h2", "http/1.1"] end)})}} + sniffing
    elif $id == "vless_ws" then
      {listen: "127.0.0.1", port: $wsPort, protocol: "vless", tag: "VLESSWS",
       settings: {clients: xusers($id), decryption: "none"},
       streamSettings: {network: "ws", security: "none", wsSettings: {acceptProxyProtocol: true, path: ("/" + $P + "ws")}}}
    elif $id == "vmess_ws" then
      {listen: "127.0.0.1", port: $vwsPort, protocol: "vmess", tag: "VMessWS",
       settings: {clients: xusers($id)},
       streamSettings: {network: "ws", security: "none", wsSettings: {acceptProxyProtocol: true, path: ("/" + $P + "vws")}}}
    elif $id == "trojan" then
      {listen: "127.0.0.1", port: $trojanPort, protocol: "trojan", tag: "trojanTCP",
       settings: {clients: xusers($id), fallbacks: [{dest: ($ngxPort | tostring), xver: 1}]},
       streamSettings: {network: "tcp", security: "none", tcpSettings: {acceptProxyProtocol: true}}}
    elif $id == "vless_reality_vision" then
      {port: $c.port, protocol: "vless", tag: "VLESSReality",
       settings: {clients: xusers($id), decryption: "none"},
       streamSettings: {network: "tcp", security: "reality", realitySettings: realityS($c)}} + sniffing
    elif $id == "vless_reality_xhttp" then
      {port: $c.port, protocol: "vless", tag: "VLESSRealityXHTTP",
       settings: {clients: xusers($id), decryption: "none"},
       streamSettings: {network: "xhttp", security: "reality", realitySettings: realityS($c),
                        xhttpSettings: {host: $S.reality.sni, path: ("/" + $P + "xHTTP"), mode: "auto"}}}
    elif $id == "vless_xhttp_tls" then
      {port: $c.port, protocol: "vless", tag: "VLESSXHTTPTLS",
       settings: {clients: xusers($id), decryption: "none"},
       streamSettings: {network: "xhttp", security: "tls", tlsSettings: (tlsCert + {serverName: $D}),
                        xhttpSettings: {host: $D, path: ("/" + $P + "xHTTP"), mode: "auto"}}}
    else empty end;
  def dom($t): [$t[] | select(startswith("domain:")) | .[7:]];
  def gsite($t): [$t[] | select(startswith("geosite:"))];
  def xdomains($t): ([$t[] | select(startswith("domain:"))] + gsite($t));
  def xips($t): [$t[] | select(startswith("ip:") or startswith("geoip:")) | if startswith("ip:") then .[3:] else . end];
  def toRule($t; $ob): if (xdomains($t) | length) > 0 then [{type: "field", domain: xdomains($t), outboundTag: $ob}] else [] end;

  ($R.global // "") as $G
  | ($R.blacklist // {}) as $B
  | ($R.warp.config // {}) as $W
  | (($W.private_key // "") != "") as $haveWarp
  | ((($R.warp.v4.domains // []) | length) > 0 or $G == "warp_v4") as $useW4
  | ((($R.warp.v6.domains // []) | length) > 0 or $G == "warp_v6") as $useW6
  | ((($R.ipv6.domains // []) | length) > 0 or $G == "ipv6") as $useV6
  | ((($R.socks5_out.server // "") != "") and ((($R.socks5_out.domains // []) | length) > 0 or $G == "socks5")) as $useS5
  | ([ $PR | to_entries[] | select(.value.core == "xray") | inbound(.key; .value) ]
     # "添加新端口": 额外端口用 dokodemo-door 转发到 Vision 前置端口
     + (if ($PR.vless_vision_tls.core // "") == "xray" then
          [ ($S.extra_ports // [])[] | {listen: "0.0.0.0", port: ., protocol: "dokodemo-door", tag: ("dokodemo-door-newPort-" + tostring),
              settings: {address: "127.0.0.1", port: $PR.vless_vision_tls.port, network: "tcp", followRedirect: false}} ]
        else [] end)) as $inbounds
  | {
      log: ({loglevel: (if $debug == "1" then "debug" else "warning" end), error: ($logdir + "/error.log")}
            + (if $debug == "1" then {access: ($logdir + "/access.log")} else {} end)),
      policy: {levels: {"0": {handshake: 4, connIdle: 300}}},
      dns: (if (($R.dns_unlock.server // "") != "" and ((($R.dns_unlock.domains // []) | length) > 0)) then
              {servers: [{address: $R.dns_unlock.server, port: 53, domains: xdomains($R.dns_unlock.domains)}, "localhost"]}
            elif (($R.sni_proxy.ip // "") != "" and ((($R.sni_proxy.domains // []) | length) > 0)) then
              {hosts: (reduce xdomains($R.sni_proxy.domains)[] as $d ({}; .[$d] = $R.sni_proxy.ip)), servers: ["8.8.8.8", "1.1.1.1"]}
            else {servers: ["localhost"]} end),
      inbounds: $inbounds,
      outbounds: ((if $G == "warp_v4" and $haveWarp then [{protocol: "wireguard", tag: "warp_v4", settings: {secretKey: $W.private_key, address: ["172.16.0.2/32"],
                      peers: [{publicKey: $W.public_key, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: "162.159.192.1:2408"}], reserved: $W.reserved, mtu: 1280}}]
                   elif $G == "warp_v6" and $haveWarp then [{protocol: "wireguard", tag: "warp_v6", settings: {secretKey: $W.private_key, address: [($W.address_v6 + "/128")],
                      peers: [{publicKey: $W.public_key, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: "162.159.192.1:2408"}], reserved: $W.reserved, mtu: 1280}}]
                   elif $G == "ipv6" then [{protocol: "freedom", tag: "IPv6_out", settings: {domainStrategy: "ForceIPv6"}}]
                   elif $G == "socks5" and $useS5 then [{protocol: "socks", tag: "socks5_outbound", settings: {servers: [{address: $R.socks5_out.server, port: $R.socks5_out.port,
                      users: [{user: ($R.socks5_out.user // ""), pass: ($R.socks5_out.pass // "")}]}]}}]
                   else [] end)
                  + [{protocol: "freedom", tag: "direct", settings: {domainStrategy: "UseIP"}}, {protocol: "blackhole", tag: "block"}]
                  + (if ($haveWarp and $useW4 and $G != "warp_v4") then [{protocol: "wireguard", tag: "warp_v4", settings: {secretKey: $W.private_key, address: ["172.16.0.2/32"],
                      peers: [{publicKey: $W.public_key, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: "162.159.192.1:2408"}], reserved: $W.reserved, mtu: 1280}}] else [] end)
                  + (if ($haveWarp and $useW6 and $G != "warp_v6") then [{protocol: "wireguard", tag: "warp_v6", settings: {secretKey: $W.private_key, address: [($W.address_v6 + "/128")],
                      peers: [{publicKey: $W.public_key, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: "162.159.192.1:2408"}], reserved: $W.reserved, mtu: 1280}}] else [] end)
                  + (if ($useV6 and $G != "ipv6") then [{protocol: "freedom", tag: "IPv6_out", settings: {domainStrategy: "ForceIPv6"}}] else [] end)
                  + (if ($useS5 and $G != "socks5") then [{protocol: "socks", tag: "socks5_outbound", settings: {servers: [{address: $R.socks5_out.server, port: $R.socks5_out.port,
                      users: [{user: ($R.socks5_out.user // ""), pass: ($R.socks5_out.pass // "")}]}]}}] else [] end)),
      routing: {
        domainStrategy: "IPOnDemand",
        rules: ((if ($R.block_bt // false) then [{type: "field", protocol: ["bittorrent"], outboundTag: "block"}] else [] end)
                + (if (($B.allow // []) | length) > 0 then toRule(($B.allow // []); "direct") else [] end)
                + toRule(($B.domains // []); "block")
                + (if (xips($B.ips // []) | length) > 0 then [{type: "field", ip: xips($B.ips // []), outboundTag: "block"}] else [] end)
                + (if ($B.cn // false) then [{type: "field", domain: ["geosite:cn"], outboundTag: "block"}, {type: "field", ip: ["geoip:cn"], outboundTag: "block"}] else [] end)
                + (if ($haveWarp and ($R.warp.v4.domains // []) != []) then toRule(($R.warp.v4.domains // []); "warp_v4") else [] end)
                + (if ($haveWarp and ($R.warp.v6.domains // []) != []) then toRule(($R.warp.v6.domains // []); "warp_v6") else [] end)
                + (if (($R.ipv6.domains // []) | length) > 0 then toRule(($R.ipv6.domains // []); "IPv6_out") else [] end)
                + (if ($useS5 and (($R.socks5_out.domains // []) | length) > 0) then toRule(($R.socks5_out.domains // []); "socks5_outbound") else [] end))
      }
    }
EOF

# renderXray <state.json 路径>  -> stdout: Xray 配置
renderXray() {
    local needSniff
    needSniff=$(jq -r 'if (.routing.block_bt == true) or ((.routing.blacklist.domains // [])|length > 0) or (.routing.blacklist.cn == true) or ((.routing.warp.v4.domains // [])|length > 0) or ((.routing.warp.v6.domains // [])|length > 0) or ((.routing.ipv6.domains // [])|length > 0) or ((.routing.socks5_out.domains // [])|length > 0) then "1" else "0" end' "$1")
    jq --arg tlsdir "${TLS_DIR}" --arg logdir "${XRAY_DIR}" \
        --arg debug "$(jq -r 'if .log.debug then "1" else "0" end' "$1")" --arg sniff "${needSniff}" \
        --argjson ngxPort "${NGX_FALLBACK_PORT}" --argjson ngxH2Port "${NGX_FALLBACK_H2_PORT}" \
        --argjson trojanPort "${XRAY_TROJAN_PORT}" --argjson wsPort "${XRAY_VLESS_WS_PORT}" \
        --argjson vwsPort "${XRAY_VMESS_WS_PORT}" "${JQ_XRAY}" "$1"
}

# 某核心在该状态下是否需要运行（有该核心的协议）
stateNeedsCore() { # stateNeedsCore <state.json> <core>
    # Socks5 入站只由 sing-box 提供，所以仅配置了 Socks5 入站时也需要 sing-box
    jq -e --arg c "$2" '([.protocols|to_entries[]|select(.value.core==$c)]|length>0) or ($c=="sing-box" and ((.routing.socks5_in.port // 0) > 0))' "$1" >/dev/null 2>&1
}
# Xray 的 Vision/WS/Trojan 前置需要 nginx 回落站
stateNeedsNginxFallback() {
    jq -e '[.protocols|to_entries[]|select(.value.core=="xray" and (.key=="vless_vision_tls" or .key=="vless_ws" or .key=="vmess_ws" or .key=="trojan"))]|length>0' "$1" >/dev/null 2>&1
}
stateNeedsHttpUpgradeNginx() {
    jq -e '.protocols.vmess_httpupgrade != null' "$1" >/dev/null 2>&1
}
stateNeedsSubscribe() {
    jq -e '.nginx.subscribe.enabled == true' "$1" >/dev/null 2>&1
}
stateNeedsNginx() {
    stateNeedsNginxFallback "$1" || stateNeedsHttpUpgradeNginx "$1" || stateNeedsSubscribe "$1"
}

# =============================================================================
#  08  独立 nginx 实例 / 伪装站 / systemd 单元
#      nginx 只承担: Xray 回落伪装站(31300/31302)、VMess+HTTPUpgrade 的 TLS 终结、订阅服务。
#      使用自己的配置目录与 atr-nginx.service，不碰系统 nginx。
# =============================================================================

# ----------------------------- nginx 主配置 ----------------------------------
writeNginxMainConf() {
    mkdir -p "${NGX_DIR}/tmp/body" "${NGX_DIR}/tmp/proxy" "${NGX_DIR}/tmp/fastcgi" \
        "${NGX_DIR}/tmp/uwsgi" "${NGX_DIR}/tmp/scgi" "${NGX_CONFD}" "${WEB_ROOT}"
    local userLine=""
    # 默认由 nginx 自己降权；测试环境可通过 ATR_NGINX_USER 指定
    [[ -n "${ATR_NGINX_USER:-}" ]] && userLine="user ${ATR_NGINX_USER};"
    atomicWrite "${NGX_CONF}" 644 <<EOF
${userLine}
worker_processes auto;
pid ${NGX_DIR}/nginx.pid;
error_log ${NGX_DIR}/error.log warn;
events {
    worker_connections 4096;
}
http {
    types {
        text/html html htm;
        text/css css;
        application/javascript js;
        application/json json;
        application/xml xml;
        image/png png;
        image/jpeg jpg jpeg;
        image/gif gif;
        image/svg+xml svg;
        image/x-icon ico;
        font/woff2 woff2;
        text/plain txt;
    }
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    access_log off;
    client_body_temp_path ${NGX_DIR}/tmp/body;
    proxy_temp_path ${NGX_DIR}/tmp/proxy;
    fastcgi_temp_path ${NGX_DIR}/tmp/fastcgi;
    uwsgi_temp_path ${NGX_DIR}/tmp/uwsgi;
    scgi_temp_path ${NGX_DIR}/tmp/scgi;
    include ${NGX_CONFD}/*.conf;
}
EOF
}

# ----------------------------- 站点配置渲染 ----------------------------------
NGX_SSL_COMMON='ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers on;'

# 伪装站 location：支持 302 重定向
_ngxRootLocation() { # _ngxRootLocation <redirect URL|空>
    if [[ -n "${1:-}" ]]; then
        printf '    location / {\n        return 302 %s;\n    }\n' "'$1'"
    else
        printf '    location / {\n    }\n'
    fi
}

# 校验会被写入 nginx 配置的值（防止配置注入）
_ngxSafeValue() { [[ "${1:-}" =~ ^[A-Za-z0-9._:/@%?=\&#+~,-]+$ ]]; }

# renderNginxConfs <state.json> <输出目录>  —— 只写需要的文件，不需要的不生成
renderNginxConfs() {
    local st=$1 out=$2 domain path redirect port h2a h2b ssl6 sub_port sub_ssl
    mkdir -p "${out}"
    domain=$(jq -r '.domain // ""' "${st}")
    path=$(jq -r '.path // ""' "${st}")
    redirect=$(jq -r '.nginx.redirect302 // ""' "${st}")
    if [[ -n "${redirect}" ]] && ! _ngxSafeValue "${redirect}"; then
        echoContent red " ---> 302 目标含非法字符，已忽略: ${redirect}"
        redirect=""
    fi
    ssl6=""
    hasIPv6 && ssl6=1

    # ---- Xray 回落伪装站（回环，仅 Xray 回落可达）----
    if stateNeedsNginxFallback "${st}"; then
        if nginxVersionGE 1.25.1; then
            h2a="listen 127.0.0.1:${NGX_FALLBACK_H2_PORT} so_keepalive=on proxy_protocol;"
            h2b="http2 on;"
        else
            h2a="listen 127.0.0.1:${NGX_FALLBACK_H2_PORT} http2 so_keepalive=on proxy_protocol;"
            h2b=""
        fi
        {
            cat <<EOF
# 由 ${ATR_PROJECT_NAME} 生成，请勿手动修改（改动会在下次变更时被覆盖）
# 非域名访问(IP 扫描/探测)一律 403，只有携带正确域名才返回伪装站
server {
    listen 127.0.0.1:${NGX_FALLBACK_PORT} proxy_protocol default_server;
    server_name _;
    return 403;
}
server {
    ${h2a}
    ${h2b}
    server_name ${domain};
    root ${WEB_ROOT};
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    client_header_timeout 1071906480m;
    keepalive_timeout 1071906480m;
$(_ngxRootLocation "${redirect}")
}
server {
    listen 127.0.0.1:${NGX_FALLBACK_PORT} proxy_protocol;
    server_name ${domain};
    root ${WEB_ROOT};
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
$(_ngxRootLocation "${redirect}")
}
EOF
        } >"${out}/atr_alone.conf"
    fi

    # ---- sing-box VMess+HTTPUpgrade: nginx 终结 TLS 后转发到回环 ----
    if stateNeedsHttpUpgradeNginx "${st}"; then
        port=$(jq -r '.protocols.vmess_httpupgrade.port' "${st}")
        {
            cat <<EOF
server {
    listen ${port} ssl so_keepalive=on;
$([[ -n "${ssl6}" ]] && echo "    listen [::]:${port} ssl so_keepalive=on;")
    server_name ${domain};
    root ${WEB_ROOT};
    ssl_certificate ${TLS_DIR}/${domain}.crt;
    ssl_certificate_key ${TLS_DIR}/${domain}.key;
    ${NGX_SSL_COMMON}
    client_max_body_size 100m;

    location /${path}hu {
        if (\$http_upgrade != "websocket") {
            return 444;
        }
        proxy_pass http://127.0.0.1:${SB_HTTPUPGRADE_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
        proxy_redirect off;
        proxy_read_timeout 86400s;
    }
$(_ngxRootLocation "${redirect}")
}
EOF
        } >"${out}/atr_httpupgrade.conf"
    fi

    # ---- 订阅服务 ----
    if stateNeedsSubscribe "${st}"; then
        sub_port=$(jq -r '.nginx.subscribe.port' "${st}")
        sub_ssl=$(jq -r '.nginx.subscribe.ssl' "${st}")
        {
            if [[ "${sub_ssl}" == "true" ]]; then
                cat <<EOF
server {
    listen ${sub_port} ssl so_keepalive=on;
$([[ -n "${ssl6}" ]] && echo "    listen [::]:${sub_port} ssl so_keepalive=on;")
    server_name ${domain};
    ssl_certificate ${TLS_DIR}/${domain}.crt;
    ssl_certificate_key ${TLS_DIR}/${domain}.key;
    ${NGX_SSL_COMMON}
EOF
            else
                cat <<EOF
server {
    listen ${sub_port} so_keepalive=on;
$([[ -n "${ssl6}" ]] && echo "    listen [::]:${sub_port} so_keepalive=on;")
    server_name _;
EOF
            fi
            cat <<EOF
    root ${WEB_ROOT};
    client_max_body_size 1m;
    # 令牌固定为 8-64 位字母数字，杜绝路径穿越（含 {} 的正则必须加引号，否则 nginx 会把 { 当作块起始符）
    location ~ "^/s/(clashMeta|default|clashMetaProfiles|sing-box|sing-box_profiles)/([A-Za-z0-9]{8,64})\$" {
        default_type 'text/plain; charset=utf-8';
        alias ${SUB_DIR}/\$1/\$2;
    }
    location / {
    }
}
EOF
        } >"${out}/atr_subscribe.conf"
    fi
    return 0
}

# ----------------------------- 伪装站内容 ------------------------------------
BUILTIN_SITE_HTML='<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Welcome</title>
<style>body{font-family:system-ui,Arial,sans-serif;max-width:640px;margin:12vh auto;padding:0 1rem;color:#333}h1{font-weight:500}</style>
</head><body><h1>Welcome</h1><p>This site is under construction. Please check back later.</p></body></html>'

# installFakeSite [模板编号1-9]  —— 下载 v2ray-agent 提供的静态站模板，失败则使用内置页面
installFakeSite() {
    local n=${1:-} z tmpd
    [[ -n "${n}" ]] || n=$(randInt 1 9)
    mkdir -p "${WEB_ROOT}"
    tmpd="${ATR_TMP:-/tmp}/site.$$"
    rm -rf "${tmpd}"
    mkdir -p "${tmpd}"
    z="${tmpd}/site.zip"
    if command -v unzip >/dev/null 2>&1 &&
        download "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/fodder/blog/unable/html${n}.zip" "${z}" &&
        unzip -oq "${z}" -d "${tmpd}/x" >/dev/null 2>&1; then
        rm -rf "${tmpd}/x/__MACOSX"
        rm -rf "${WEB_ROOT:?}"/* 2>/dev/null
        cp -r "${tmpd}/x/." "${WEB_ROOT}/"
        echoContent green " ---> 添加伪装站点成功（模板 ${n}）"
    else
        printf '%s\n' "${BUILTIN_SITE_HTML}" >"${WEB_ROOT}/index.html"
        echoContent yellow " ---> 伪装站模板下载失败，已使用内置简易页面"
    fi
    chmod -R a+rX "${WEB_ROOT}" 2>/dev/null
    rm -rf "${tmpd}"
    return 0
}

# ----------------------------- systemd 单元 ----------------------------------
# 仅在内容变化时重写并 daemon-reload
_writeUnitFile() { # _writeUnitFile <单元名> (内容来自 stdin)
    local name=$1 f="${ATR_SYSTEMD_DIR}/$1.service" tmp
    mkdir -p "${ATR_SYSTEMD_DIR}"
    tmp=$(mktemp "${ATR_TMP:-/tmp}/unit.XXXXXX") || return 1
    cat >"${tmp}"
    if [[ -f "${f}" ]] && cmp -s "${tmp}" "${f}"; then
        rm -f "${tmp}"
        return 0
    fi
    install -m 644 "${tmp}" "${f}" && rm -f "${tmp}"
    systemctl daemon-reload >/dev/null 2>&1
}

writeUnit() { # writeUnit <sing-box|xray|nginx>
    case "$1" in
    sing-box)
        _writeUnitFile "${SB_UNIT}" <<EOF
[Unit]
Description=Sing-Box Service (${ATR_PROJECT_NAME})
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${SB_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStartPre=${SB_BIN} check -c ${SB_CONF}
ExecStart=${SB_BIN} run -c ${SB_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNPROC=infinity
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        ;;
    xray)
        _writeUnitFile "${XRAY_UNIT}" <<EOF
[Unit]
Description=Xray Service (${ATR_PROJECT_NAME})
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${XRAY_DIR}
Environment="XRAY_LOCATION_ASSET=${XRAY_DIR}"
ExecStartPre=${XRAY_BIN} run -test -c ${XRAY_CONF}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONF}
Restart=on-failure
RestartPreventExitStatus=23
RestartSec=10
LimitNPROC=infinity
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        ;;
    nginx)
        findNginxBin || return 1
        _writeUnitFile "${NGX_UNIT}" <<EOF
[Unit]
Description=nginx for ${ATR_PROJECT_NAME} (isolated instance)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStartPre=${NGINX_BIN} -t -c ${NGX_CONF} -p ${NGX_DIR}/
ExecStart=${NGINX_BIN} -g 'daemon off;' -c ${NGX_CONF} -p ${NGX_DIR}/
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        ;;
    esac
}

# =============================================================================
#  09  事务引擎: 服务控制 / 防火墙 / 校验 / 应用 / 回滚
#
#   applyStaged: 校验状态 -> 渲染 -> 用真实内核 check/-test 校验 -> 备份 -> 原子落盘
#                -> 启停服务 -> 验证服务与端口 -> 失败则自动回滚
#   state.json(含 Reality 密钥)只在配置校验通过之后才写盘，
#   从根本上避免"客户端公钥与服务端私钥不匹配"。
# =============================================================================

TXN_MARK="${ATR_HOME}/.txn"

# ----------------------------- 服务控制 --------------------------------------
serviceActive() { systemctl is-active --quiet "$1" >/dev/null 2>&1; }
serviceStop() { systemctl stop "$1" >/dev/null 2>&1; }
serviceDisable() { systemctl disable "$1" >/dev/null 2>&1; }
serviceEnable() { systemctl enable "$1" >/dev/null 2>&1; }

# 等待服务进入 active（最多 N 秒）
waitServiceActive() { # waitServiceActive <unit> [秒]
    local unit=$1 t=${2:-10} i
    for ((i = 0; i < t * 2; i++)); do
        serviceActive "${unit}" && return 0
        sleep 0.5
    done
    return 1
}

# 等待端口开始监听
waitListening() { # waitListening <port> <tcp|udp> [秒]
    local port=$1 proto=$2 t=${3:-10} i
    for ((i = 0; i < t * 2; i++)); do
        portInUse "${port}" "${proto}" && return 0
        sleep 0.5
    done
    return 1
}

serviceLogTail() { # serviceLogTail <unit> [行数]
    journalctl -u "$1" -n "${2:-15}" --no-pager 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

# ----------------------------- 期望的端口 ------------------------------------
# 公网需要放行的 "proto port" 列表（含端口跳跃范围）
desiredFirewallPorts() { # <state.json>
    jq -r '
      def udp: ["tuic","hysteria2"];
      def netof($id): if (udp | index($id)) != null then "udp" else "tcp" end;
      ( [ .protocols | to_entries[] | select(.value.port != null)
          | {port: (.value.port|tostring), proto: netof(.key)} ]
        + (if (.routing.socks5_in.port // 0) > 0 then [{port: (.routing.socks5_in.port|tostring), proto: "tcp"}] else [] end)
        + (if (.nginx.subscribe.enabled // false) and ((.nginx.subscribe.port // 0) > 0) then [{port: (.nginx.subscribe.port|tostring), proto: "tcp"}] else [] end)
        + [ (.extra_ports // [])[] | {port: tostring, proto: "tcp"} ]
        + [ .protocols | to_entries[] | select((.value.hop // "") != "") | {port: (.value.hop|split("-")|join(":")), proto: "udp"} ]
      ) | unique_by([.port, .proto])[] | "\(.proto) \(.port)"' "$1" 2>/dev/null
}

# 需要验证"正在监听"的 "proto port" 列表（含回环内部端口）
expectedListeners() { # <state.json>
    local st=$1
    jq -r '
      def udp: ["tuic","hysteria2"];
      def netof($id): if (udp | index($id)) != null then "udp" else "tcp" end;
      [ .protocols | to_entries[] | select(.value.port != null)
        | "\(netof(.key)) \(.value.port)" ][]' "${st}"
    if [[ "$(jq -r '.protocols.vmess_httpupgrade // empty | "y"' "${st}")" == "y" ]]; then echo "tcp ${SB_HTTPUPGRADE_PORT}"; fi
    if stateNeedsNginxFallback "${st}"; then echo "tcp ${NGX_FALLBACK_PORT}"; echo "tcp ${NGX_FALLBACK_H2_PORT}"; fi
    [[ "$(jq -r '.protocols.vless_ws.core // ""' "${st}")" == "xray" ]] && echo "tcp ${XRAY_VLESS_WS_PORT}"
    [[ "$(jq -r '.protocols.vmess_ws.core // ""' "${st}")" == "xray" ]] && echo "tcp ${XRAY_VMESS_WS_PORT}"
    [[ "$(jq -r '.protocols.trojan.core // ""' "${st}")" == "xray" ]] && echo "tcp ${XRAY_TROJAN_PORT}"
    jq -r 'if (.routing.socks5_in.port // 0) > 0 then "tcp \(.routing.socks5_in.port)" else empty end' "${st}"
    jq -r 'if (.nginx.subscribe.enabled // false) then "tcp \(.nginx.subscribe.port)" else empty end' "${st}"
    jq -r '(.extra_ports // [])[] | "tcp \(.)"' "${st}"
}

# ----------------------------- 防火墙 ----------------------------------------
_fwKind() {
    [[ "${ATR_SKIP_FIREWALL:-0}" == "1" ]] && { echo none; return; }
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo ufw
    elif command -v firewall-cmd >/dev/null 2>&1 && [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]; then
        echo firewalld
    elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'; then
        echo iptables
    else
        echo none
    fi
}

# fwOpen <端口|范围a:b> <tcp|udp>
fwOpen() {
    local port=$1 proto=$2 kind
    kind=$(_fwKind)
    case "${kind}" in
    ufw) ufw allow "${port}/${proto}" >/dev/null 2>&1 ;;
    firewalld)
        firewall-cmd --permanent --zone=public --add-port="${port//:/-}/${proto}" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        ;;
    iptables)
        if ! iptables -C INPUT -p "${proto}" --dport "${port}" -m comment --comment "atr:${proto}/${port}" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p "${proto}" --dport "${port}" -m comment --comment "atr:${proto}/${port}" -j ACCEPT 2>/dev/null
        fi
        command -v ip6tables >/dev/null 2>&1 && ip6tables -I INPUT -p "${proto}" --dport "${port}" -m comment --comment "atr:${proto}/${port}" -j ACCEPT 2>/dev/null
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        else
            echoContent yellow " ---> 提示: 已用 iptables 放行 ${port}/${proto}，但系统未安装 netfilter-persistent，重启后规则可能丢失"
        fi
        ;;
    esac
    return 0
}

fwClose() {
    local port=$1 proto=$2 kind
    kind=$(_fwKind)
    case "${kind}" in
    ufw) ufw delete allow "${port}/${proto}" >/dev/null 2>&1 ;;
    firewalld)
        firewall-cmd --permanent --zone=public --remove-port="${port//:/-}/${proto}" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        ;;
    iptables)
        while iptables -D INPUT -p "${proto}" --dport "${port}" -m comment --comment "atr:${proto}/${port}" -j ACCEPT 2>/dev/null; do :; done
        command -v ip6tables >/dev/null 2>&1 && while ip6tables -D INPUT -p "${proto}" --dport "${port}" -m comment --comment "atr:${proto}/${port}" -j ACCEPT 2>/dev/null; do :; done
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
        ;;
    esac
    return 0
}

# 把"期望端口"与"已放行端口"做差，打印需要新增/回收的项
# fwDiff <旧state.json> <新state.json> <add|remove>
fwDiff() {
    local old=$1 new=$2 mode=$3 tmpo tmpn
    tmpo=$(mktemp "${ATR_TMP:-/tmp}/fw.XXXXXX") || return 1
    tmpn=$(mktemp "${ATR_TMP:-/tmp}/fw.XXXXXX") || return 1
    [[ -s "${old}" ]] && desiredFirewallPorts "${old}" | sort -u >"${tmpo}"
    desiredFirewallPorts "${new}" | sort -u >"${tmpn}"
    if [[ "${mode}" == "add" ]]; then comm -13 "${tmpo}" "${tmpn}"; else comm -23 "${tmpo}" "${tmpn}"; fi
    rm -f "${tmpo}" "${tmpn}"
}

fwApplyList() { # fwApplyList <open|close>  (stdin: "proto port" 每行)
    local action=$1 proto port
    while read -r proto port; do
        [[ -z "${port}" ]] && continue
        if [[ "${action}" == "open" ]]; then
            fwOpen "${port}" "${proto}"
            echoContent green " ---> 已放行 ${proto}/${port}"
        else
            fwClose "${port}" "${proto}"
            echoContent yellow " ---> 已回收 ${proto}/${port}"
        fi
    done
}

# ----------------------------- 备份 / 回滚 -----------------------------------
# 受事务管理的文件
_txnFiles() {
    echo "${ATR_STATE}"
    echo "${SB_CONF}"
    echo "${XRAY_CONF}"
    echo "${ATR_SYSTEMD_DIR}/${SB_UNIT}.service"
    echo "${ATR_SYSTEMD_DIR}/${XRAY_UNIT}.service"
    echo "${ATR_SYSTEMD_DIR}/${NGX_UNIT}.service"
    echo "${NGX_CONF}"
    local f
    for f in "${NGX_CONFD}"/atr_*.conf; do [[ -e "${f}" ]] && echo "${f}"; done
}

# backupLive <备份目录>  —— 记录每个文件原先是否存在
backupLive() {
    local bdir=$1 f key
    mkdir -p "${bdir}/files"
    : >"${bdir}/manifest"
    while read -r f; do
        [[ -z "${f}" ]] && continue
        key=$(printf '%s' "${f}" | sed 's#/#%#g')
        if [[ -f "${f}" ]]; then
            cp -p "${f}" "${bdir}/files/${key}"
            printf 'E\t%s\n' "${f}" >>"${bdir}/manifest"
        else
            printf 'N\t%s\n' "${f}" >>"${bdir}/manifest"
        fi
    done < <(_txnFiles)
    # nginx 站点配置在新事务里可能新增，同样需要记录"原先不存在"
    for f in atr_alone.conf atr_httpupgrade.conf atr_subscribe.conf; do
        grep -qF "${NGX_CONFD}/${f}" "${bdir}/manifest" || printf 'N\t%s\n' "${NGX_CONFD}/${f}" >>"${bdir}/manifest"
    done
    chmod 700 "${bdir}"
}

restoreFromBackup() { # restoreFromBackup <备份目录>
    local bdir=$1 kind f key
    [[ -f "${bdir}/manifest" ]] || return 1
    while IFS=$'\t' read -r kind f; do
        key=$(printf '%s' "${f}" | sed 's#/#%#g')
        if [[ "${kind}" == "E" ]]; then
            mkdir -p "$(dirname "${f}")"
            cp -p "${bdir}/files/${key}" "${f}"
        else
            rm -f "${f}"
        fi
    done <"${bdir}/manifest"
    systemctl daemon-reload >/dev/null 2>&1
    return 0
}

pruneBackups() { # 只保留最近 10 份（目录名是时间戳，glob 展开即按时间升序）
    local keep=10 dirs=() d n i
    for d in "${BACKUP_DIR}"/*/; do [[ -d "${d}" ]] && dirs+=("${d}"); done
    n=${#dirs[@]}
    ((n <= keep)) && return 0
    for ((i = 0; i < n - keep; i++)); do rm -rf "${dirs[i]}"; done
}

# 若上次事务在落盘途中被中断（.txn 仍存在），自动从备份恢复
recoverIfNeeded() {
    [[ -f "${TXN_MARK}" ]] || return 0
    local bdir
    bdir=$(cat "${TXN_MARK}")
    echoContent yellow "\n ---> 检测到上次操作未完成，正在从备份恢复: ${bdir}"
    if [[ -d "${bdir}" ]] && restoreFromBackup "${bdir}"; then
        rm -f "${TXN_MARK}"
        applyServices "${ATR_STATE}" >/dev/null 2>&1
        atrLog "recovered interrupted transaction from ${bdir}"
        echoContent green " ---> 已恢复到上次可用配置"
    else
        echoContent red " ---> 自动恢复失败，请手动检查 ${ATR_HOME}（备份目录: ${bdir}）"
    fi
}

# ----------------------------- 资源准备 / 校验 --------------------------------
# prepareAssets <state.json> —— 内核、规则集、nginx 是否就绪
prepareAssets() {
    local st=$1 core tok name kind
    for core in sing-box xray; do
        if stateNeedsCore "${st}" "${core}" && ! coreInstalled "${core}"; then
            echoContent red " ---> $(coreLabel "${core}") 未安装"
            return 1
        fi
    done
    if stateNeedsCore "${st}" sing-box; then
        while read -r tok; do
            [[ -z "${tok}" ]] && continue
            kind=${tok%%:*}
            name=${tok#*:}
            if ! ensureSingBoxRuleSet "${kind}" "${name}"; then
                echoContent red " ---> 无法下载 sing-box 规则集 ${kind}-${name}（名称不存在或网络不可达）"
                return 1
            fi
        done < <(jq -r '[ .routing.blacklist.domains[]?, .routing.blacklist.allow[]?, .routing.blacklist.ips[]?, .routing.warp.v4.domains[]?, .routing.warp.v6.domains[]?,
                          .routing.ipv6.domains[]?, .routing.socks5_out.domains[]?, .routing.socks5_in.domains[]?, .routing.dns_unlock.domains[]? ]
                        + (if .routing.blacklist.cn == true then ["geosite:cn","geoip:cn"] else [] end)
                        | map(select(startswith("geosite:") or startswith("geoip:"))) | unique[]' "${st}")
    fi
    if stateNeedsCore "${st}" xray; then ensureXrayGeo >/dev/null 2>&1; fi
    if stateNeedsNginx "${st}"; then ensureNginx || return 1; fi
    return 0
}

# 用真实内核/nginx 校验已渲染的候选配置；失败时输出内核的原始报错
checkRendered() { # checkRendered <stage 目录> <state.json>
    local stage=$1 st=$2 out
    if stateNeedsCore "${st}" sing-box; then
        if ! out=$("${SB_BIN}" check -c "${stage}/sing-box/config.json" 2>&1); then
            echoContent red " ---> sing-box 配置校验失败，未做任何改动:"
            printf '%s\n' "${out}" | sed 's/\x1b\[[0-9;]*m//g' | tail -n 8
            return 1
        fi
    fi
    if stateNeedsCore "${st}" xray; then
        if ! out=$(XRAY_LOCATION_ASSET="${XRAY_DIR}" "${XRAY_BIN}" run -test -format json -c "${stage}/xray/config.json" 2>&1); then
            echoContent red " ---> Xray 配置校验失败，未做任何改动:"
            printf '%s\n' "${out}" | grep -v '^$' | tail -n 8
            return 1
        fi
    fi
    if stateNeedsNginx "${st}" && findNginxBin; then
        writeNginxMainConf
        sed "s#include ${NGX_CONFD}/\*\.conf;#include ${stage}/nginx/*.conf;#" "${NGX_CONF}" >"${stage}/nginx_test.conf"
        local rc=0
        out=$("${NGINX_BIN}" -t -c "${stage}/nginx_test.conf" -p "${NGX_DIR}/" 2>&1) || rc=$?
        if ((rc != 0)); then
            echoContent red " ---> nginx 配置校验失败，未做任何改动:"
            printf '%s\n' "${out}" | grep -v 'directive makes sense only' | tail -n 6
            return 1
        fi
    fi
    return 0
}

# SELinux 为 Enforcing 时，nginx 要监听非标准端口需标记为 http_port_t（尽力而为，失败不影响流程）
selinuxAllowNginxPorts() { # selinuxAllowNginxPorts <state.json>
    command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] || return 0
    if ! command -v semanage >/dev/null 2>&1; then
        echoContent yellow " ---> SELinux 为 Enforcing 且未安装 semanage(policycoreutils-python-utils)，nginx 的非标准端口可能被拒绝"
        return 0
    fi
    local p
    for p in "${NGX_FALLBACK_PORT}" "${NGX_FALLBACK_H2_PORT}" $(jq -r '[.protocols.vmess_httpupgrade.port // empty, (if .nginx.subscribe.enabled then .nginx.subscribe.port else empty end)] | .[]' "$1" 2>/dev/null); do
        semanage port -l 2>/dev/null | grep -w http_port_t | grep -qw "${p}" ||
            semanage port -a -t http_port_t -p tcp "${p}" >/dev/null 2>&1 ||
            semanage port -m -t http_port_t -p tcp "${p}" >/dev/null 2>&1
    done
    return 0
}

# ----------------------------- 服务应用 / 验证 --------------------------------
# 按 state 启停各服务；某核心无协议则停止并禁用
applyServices() { # applyServices <state.json> [force]
    local st=$1 force=${2:-}
    local needNgx=0 needSB=0 needX=0
    stateNeedsNginx "${st}" && needNgx=1
    stateNeedsCore "${st}" sing-box && needSB=1
    stateNeedsCore "${st}" xray && needX=1

    if ((needNgx)); then
        findNginxBin || ensureNginx || return 1
        selinuxAllowNginxPorts "${st}"
        writeNginxMainConf
        writeUnit nginx
        serviceEnable "${NGX_UNIT}"
        systemctl restart "${NGX_UNIT}" >/dev/null 2>&1
    else
        serviceActive "${NGX_UNIT}" && serviceStop "${NGX_UNIT}"
        serviceDisable "${NGX_UNIT}"
    fi
    if ((needSB)); then
        writeUnit sing-box
        serviceEnable "${SB_UNIT}"
        if [[ -n "${force}" || "${SB_CHANGED:-1}" == "1" ]] || ! serviceActive "${SB_UNIT}"; then
            systemctl restart "${SB_UNIT}" >/dev/null 2>&1
        fi
    else
        serviceActive "${SB_UNIT}" && serviceStop "${SB_UNIT}"
        serviceDisable "${SB_UNIT}"
    fi
    if ((needX)); then
        writeUnit xray
        serviceEnable "${XRAY_UNIT}"
        if [[ -n "${force}" || "${X_CHANGED:-1}" == "1" ]] || ! serviceActive "${XRAY_UNIT}"; then
            systemctl restart "${XRAY_UNIT}" >/dev/null 2>&1
        fi
    else
        serviceActive "${XRAY_UNIT}" && serviceStop "${XRAY_UNIT}"
        serviceDisable "${XRAY_UNIT}"
    fi
    # UDP 端口跳跃规则以 state 为准重建（回滚时同样会恢复）
    declare -F reconcileHopRules >/dev/null && reconcileHopRules "${st}"
    return 0
}

# 验证服务 active 且期望端口全部在监听；失败时打印原因并返回 1
verifyRuntime() { # verifyRuntime <state.json>
    local st=$1 ok=0 proto port unit
    for unit in "${SB_UNIT}:sing-box" "${XRAY_UNIT}:xray" "${NGX_UNIT}:nginx"; do
        local u=${unit%%:*} c=${unit##*:} need=0
        case "${c}" in
        nginx) stateNeedsNginx "${st}" && need=1 ;;
        *) stateNeedsCore "${st}" "${c}" && need=1 ;;
        esac
        ((need)) || continue
        if ! waitServiceActive "${u}" 10; then
            echoContent red " ---> 服务 ${u} 未能启动，最近日志:"
            serviceLogTail "${u}" 12
            ok=1
        fi
    done
    ((ok == 0)) || return 1
    while read -r proto port; do
        [[ -z "${port}" ]] && continue
        if ! waitListening "${port}" "${proto}" 10; then
            echoContent red " ---> 端口 ${proto}/${port} 没有在监听"
            ok=1
        fi
    done < <(expectedListeners "${st}" | sort -u)
    return "${ok}"
}

# ----------------------------- 事务主体 --------------------------------------
# applyStaged [说明]  —— 应用 NEW_STATE；成功返回 0 并更新 state.json；任何一步失败都保持/恢复原状
applyStaged() {
    local why=${1:-变更} ts stage bdir st oldst errs core
    [[ -n "${NEW_STATE}" ]] || {
        echoContent red " ---> 内部错误: 没有待应用的状态"
        return 1
    }
    stateInit
    lockAcquire || return 1
    ts=$(date +%Y%m%d-%H%M%S)
    stage="${ATR_TMP:-/tmp}/stage.${ts}.$$"
    mkdir -p "${stage}/sing-box" "${stage}/xray" "${stage}/nginx"
    st="${stage}/state.json"
    printf '%s\n' "${NEW_STATE}" | jq . >"${st}"

    # 1) 状态校验（端口冲突/缺失字段/证书文件）
    errs=$(validateState <"${st}")
    if [[ -n "${errs}" ]]; then
        echoContent red " ---> 配置不合法，未做任何改动:"
        printf '%s\n' "${errs}" | sed 's/^/      - /'
        rm -rf "${stage}"
        lockRelease
        return 1
    fi

    # 2) 资源就绪
    if ! prepareAssets "${st}"; then
        rm -rf "${stage}"
        lockRelease
        return 1
    fi

    # 3) 渲染
    for core in sing-box xray; do
        if stateNeedsCore "${st}" "${core}"; then
            if [[ "${core}" == "sing-box" ]]; then renderSingBox "${st}" >"${stage}/sing-box/config.json"; else renderXray "${st}" >"${stage}/xray/config.json"; fi
            if ! jq -e . "${stage}/${core}/config.json" >/dev/null 2>&1; then
                echoContent red " ---> 内部错误: ${core} 配置渲染结果不是合法 JSON"
                rm -rf "${stage}"
                lockRelease
                return 1
            fi
        fi
    done
    renderNginxConfs "${st}" "${stage}/nginx"

    # 4) 用真实内核/nginx 校验
    if ! checkRendered "${stage}" "${st}"; then
        rm -rf "${stage}"
        lockRelease
        return 1
    fi

    # 5) 备份 + 事务标记（崩溃后可恢复）
    bdir="${BACKUP_DIR}/${ts}"
    backupLive "${bdir}"
    printf '%s' "${bdir}" >"${TXN_MARK}"
    oldst="${bdir}/files/$(printf '%s' "${ATR_STATE}" | sed 's#/#%#g')"
    [[ -f "${oldst}" ]] || oldst=""

    # 6) 判断各核心配置是否有变化（无变化则不重启）
    SB_CHANGED=1
    X_CHANGED=1
    if [[ -n "${oldst}" ]]; then
        cmp -s "${stage}/sing-box/config.json" "${SB_CONF}" 2>/dev/null && SB_CHANGED=0
        cmp -s "${stage}/xray/config.json" "${XRAY_CONF}" 2>/dev/null && X_CHANGED=0
    fi

    # 7) 原子落盘（先配置，后 state）
    mkdir -p "${SB_DIR}/conf" "${XRAY_DIR}/conf" "${NGX_CONFD}"
    if stateNeedsCore "${st}" sing-box; then install -m 600 "${stage}/sing-box/config.json" "${SB_CONF}"; else rm -f "${SB_CONF}"; fi
    if stateNeedsCore "${st}" xray; then install -m 600 "${stage}/xray/config.json" "${XRAY_CONF}"; else rm -f "${XRAY_CONF}"; fi
    rm -f "${NGX_CONFD}"/atr_*.conf
    local nf
    for nf in "${stage}"/nginx/*.conf; do
        [[ -e "${nf}" ]] && install -m 644 "${nf}" "${NGX_CONFD}/$(basename "${nf}")"
    done
    install -m 600 "${st}" "${ATR_STATE}"

    # 8) 防火墙放行（新增的先开，回收的等成功后再关）
    local addList
    addList=$(fwDiff "${oldst}" "${st}" add)
    [[ -n "${addList}" ]] && fwApplyList open <<<"${addList}"

    # 9) 启停服务 + 验证
    echoContent green " ---> 应用配置并重启服务…"
    applyServices "${st}"
    if ! verifyRuntime "${st}"; then
        echoContent red "\n ---> 新配置运行异常，正在自动回滚到变更前的状态…"
        restoreFromBackup "${bdir}"
        [[ -n "${addList}" ]] && fwApplyList close <<<"${addList}" >/dev/null
        SB_CHANGED=1
        X_CHANGED=1
        if [[ -n "${oldst}" ]]; then
            applyServices "${ATR_STATE}" force
            verifyRuntime "${ATR_STATE}" >/dev/null 2>&1 && echoContent green " ---> 已回滚，旧配置运行正常" || echoContent red " ---> 回滚后旧配置也未能正常运行，请检查日志"
        else
            applyServices "${ATR_STATE}" force
            echoContent yellow " ---> 首次安装失败，已清理本次改动"
        fi
        rm -f "${TXN_MARK}"
        atrLog "ROLLBACK (${why}) backup=${bdir}"
        rm -rf "${stage}"
        lockRelease
        return 1
    fi

    # 10) 成功: 回收不再需要的端口、清理标记、保留备份
    local delList
    delList=$(fwDiff "${oldst}" "${st}" remove)
    [[ -n "${delList}" ]] && fwApplyList close <<<"${delList}"
    rm -f "${TXN_MARK}"
    pruneBackups
    atrLog "APPLIED (${why}) backup=${bdir}"
    rm -rf "${stage}"
    lockRelease
    NEW_STATE=""
    echoContent green " ---> 配置已生效（${why}）"
    return 0
}

# 当前配置不变，仅重启（证书续签 hook / 手动重启使用）
reloadAll() {
    stateExists || return 1
    lockAcquire || return 1
    SB_CHANGED=1
    X_CHANGED=1
    applyServices "${ATR_STATE}" force
    local rc=0
    verifyRuntime "${ATR_STATE}" || rc=1
    lockRelease
    return "${rc}"
}

# 升级内核后重启并验证（upgradeCore 使用）
restartCoreChecked() { # restartCoreChecked <core>
    local core=$1 unit proto port rc=0
    unit=$(coreUnit "${core}")
    systemctl restart "${unit}" >/dev/null 2>&1
    waitServiceActive "${unit}" 10 || return 1
    while read -r proto port; do
        [[ -z "${port}" ]] && continue
        waitListening "${port}" "${proto}" 8 || rc=1
    done < <(jq -r --arg c "${core}" 'def udp: ["tuic","hysteria2"]; def netof($id): if (udp|index($id))!=null then "udp" else "tcp" end; .protocols|to_entries[]|select(.value.core==$c and .value.port!=null)|"\(netof(.key)) \(.value.port)"' "${ATR_STATE}" 2>/dev/null)
    return "${rc}"
}

# =============================================================================
#  10  客户端节点: 一份 (用户 x 协议) 描述 -> 分享链接 / sing-box 出站 / mihomo 代理
#      三种格式都由同一个 jq 程序产生，凭据与名称里的任何字符都会被正确转义/编码。
#
#      mihomo 不支持 AnyTLS+Reality（官方文档: 现在和将来都不会支持），故该协议只输出 sing-box。
#      sing-box 的 naive 出站依赖 cronet 库（官方发行版二进制不含），故 naive 不放进 sing-box
#      客户端配置，只给 naive+https 链接与 NaiveProxy 官方客户端配置。
# =============================================================================

read -r -d '' JQ_NODES <<'EOF'
. as $S
| ($S.domain // "") as $D
| ($S.path // "") as $P
| ($S.reality // {}) as $RE
| ($S.protocols // {}) as $PR
| (($S.cdn // "") | split(",") | map(select(length > 0))) as $cdns
| def short($id): ($reg | map(select(.id == $id)) | .[0].short // $id);
  def cdnCapable($id): ($reg | map(select(.id == $id)) | .[0].cdn // false);
  def isReality($id): ($reg | map(select(.id == $id)) | .[0].reality // false);
  def vport: ($PR.vless_vision_tls.port // 443);
  def portof($id; $c): if (($id == "vless_ws" or $id == "vmess_ws" or $id == "trojan") and $c.core == "xray") then vport else $c.port end;
  # ---- 链接工具 ----
  def hostp($h): if ($h | contains(":")) then "[" + $h + "]" else $h end;
  def q($pairs): $pairs | map(.[0] + "=" + .[1]) | join("&");
  def e: @uri;
  # ---- 节点基础字段 ----
  def mk($u; $id; $c; $server; $suffix):
    {name: ($u.name + "-" + short($id) + $suffix), user: $u.name, proto: $id, core: $c.core,
     uuid: $u.uuid, password: $u.password, server: $server, port: portof($id; $c),
     sni: "", host: "", path: "", pbk: ($RE.public_key // ""), sid: ($RE.short_id // ""),
     pqv: (if $c.core == "xray" then ($RE.mldsa_verify // "") else "" end), cc: ($c.congestion // "bbr"),
     up: ($c.up_mbps // 50), down: ($c.down_mbps // 100), hop: ($c.hop // "")};
  def withReality: . + {sni: ($RE.sni // "")};
  def withTLS: . + {sni: $D, host: $D};
  def nodeOf($u; $id; $c; $server; $suffix):
    mk($u; $id; $c; $server; $suffix)
    | if   $id == "vless_reality_vision" or $id == "anytls_reality" or $id == "vless_reality_grpc" then withReality
      elif $id == "vless_reality_xhttp" then (withReality | . + {host: ($RE.sni // ""), path: ("/" + $P + "xHTTP")})
      elif $id == "vless_ws" then (withTLS | . + {path: ("/" + $P + "ws")})
      elif $id == "vmess_ws" then (withTLS | . + {path: ("/" + $P + "vws")})
      elif $id == "vmess_httpupgrade" then (withTLS | . + {path: ("/" + $P + "hu")})
      elif $id == "vless_xhttp_tls" then (withTLS | . + {path: ("/" + $P + "xHTTP")})
      else withTLS end;
  # ---- 三种输出 ----
  def uri($n):
    if $n.proto == "vless_reality_vision" then
      "vless://\($n.uuid)@\(hostp($n.server)):\($n.port)?" + q([["encryption","none"],["security","reality"],["type","tcp"],["sni",($n.sni|e)],["fp","chrome"],["pbk",$n.pbk],["sid",$n.sid],["flow","xtls-rprx-vision"]] + (if $n.pqv != "" then [["pqv",$n.pqv]] else [] end)) + "#" + ($n.name|e)
    elif $n.proto == "vless_reality_grpc" then
      "vless://\($n.uuid)@\(hostp($n.server)):\($n.port)?" + q([["encryption","none"],["security","reality"],["type","grpc"],["sni",($n.sni|e)],["fp","chrome"],["pbk",$n.pbk],["sid",$n.sid],["serviceName","grpc"]]) + "#" + ($n.name|e)
    elif $n.proto == "vless_reality_xhttp" then
      "vless://\($n.uuid)@\(hostp($n.server)):\($n.port)?" + q([["encryption","none"],["security","reality"],["type","xhttp"],["sni",($n.sni|e)],["host",($n.host|e)],["path",($n.path|e)],["mode","auto"],["fp","chrome"],["pbk",$n.pbk],["sid",$n.sid]] + (if $n.pqv != "" then [["pqv",$n.pqv]] else [] end)) + "#" + ($n.name|e)
    elif $n.proto == "vless_vision_tls" then
      "vless://\($n.uuid)@\(hostp($n.server)):\($n.port)?" + q([["encryption","none"],["security","tls"],["type","tcp"],["host",($n.host|e)],["fp","chrome"],["headerType","none"],["sni",($n.sni|e)],["flow","xtls-rprx-vision"]]) + "#" + ($n.name|e)
    elif $n.proto == "vless_ws" then
      "vless://\($n.uuid)@\(hostp($n.server)):\($n.port)?" + q([["encryption","none"],["security","tls"],["type","ws"],["host",($n.host|e)],["sni",($n.sni|e)],["fp","chrome"],["path",($n.path|e)]]) + "#" + ($n.name|e)
    elif $n.proto == "vless_xhttp_tls" then
      "vless://\($n.uuid)@\(hostp($n.server)):\($n.port)?" + q([["encryption","none"],["security","tls"],["type","xhttp"],["sni",($n.sni|e)],["host",($n.host|e)],["fp","chrome"],["alpn","h2"],["path",($n.path|e)],["mode","auto"]]) + "#" + ($n.name|e)
    elif $n.proto == "vmess_ws" or $n.proto == "vmess_httpupgrade" then
      "vmess://" + ({v: "2", ps: $n.name, add: $n.server, port: ($n.port|tostring), id: $n.uuid, aid: "0", scy: "auto",
                     net: (if $n.proto == "vmess_ws" then "ws" else "httpupgrade" end), type: "none", host: $n.host, path: $n.path,
                     tls: "tls", sni: $n.sni, alpn: "", fp: "chrome"} | tojson | @base64)
    elif $n.proto == "trojan" then
      "trojan://\($n.password|e)@\(hostp($n.server)):\($n.port)?" + q([["security","tls"],["peer",($n.sni|e)],["sni",($n.sni|e)],["fp","chrome"],["alpn","http%2F1.1"],["type","tcp"]]) + "#" + ($n.name|e)
    elif $n.proto == "hysteria2" then
      "hysteria2://\($n.password|e)@\(hostp($n.server)):\($n.port)?" + q((if $n.hop != "" then [["mport",$n.hop]] else [] end) + [["peer",($n.sni|e)],["insecure","0"],["sni",($n.sni|e)],["alpn","h3"]]) + "#" + ($n.name|e)
    elif $n.proto == "tuic" then
      "tuic://\($n.uuid):\($n.password|e)@\(hostp($n.server)):\($n.port)?" + q([["congestion_control",$n.cc],["alpn","h3"],["sni",($n.sni|e)],["udp_relay_mode","quic"],["allow_insecure","0"]]) + "#" + ($n.name|e)
    elif $n.proto == "naive" then
      "naive+https://\($n.user|e):\($n.password|e)@\(hostp($n.server)):\($n.port)?padding=true#" + ($n.name|e)
    elif $n.proto == "anytls_tls" then
      "anytls://\($n.password|e)@\(hostp($n.server)):\($n.port)?" + q([["peer",($n.sni|e)],["insecure","0"],["sni",($n.sni|e)]]) + "#" + ($n.name|e)
    else null end;
  def tlsSB($n): {enabled: true, server_name: $n.sni};
  def utls: {enabled: true, fingerprint: "chrome"};
  def realitySB($n): {enabled: true, public_key: $n.pbk, short_id: $n.sid};
  def singbox($n):
    {tag: $n.name, server: $n.server, server_port: $n.port} as $b
    | if $n.proto == "vless_reality_vision" then
        $b + {type: "vless", uuid: $n.uuid, flow: "xtls-rprx-vision", tls: (tlsSB($n) + {utls: utls, reality: realitySB($n)}), packet_encoding: "xudp"}
      elif $n.proto == "anytls_reality" then
        $b + {type: "anytls", password: $n.password, tls: (tlsSB($n) + {utls: utls, reality: realitySB($n)})}
      elif $n.proto == "vless_reality_grpc" then
        $b + {type: "vless", uuid: $n.uuid, tls: (tlsSB($n) + {utls: utls, reality: realitySB($n)}), packet_encoding: "xudp", transport: {type: "grpc", service_name: "grpc"}}
      elif $n.proto == "vless_vision_tls" then
        $b + {type: "vless", uuid: $n.uuid, flow: "xtls-rprx-vision", tls: (tlsSB($n) + {utls: utls}), packet_encoding: "xudp"}
      elif $n.proto == "vless_ws" then
        $b + {type: "vless", uuid: $n.uuid, tls: (tlsSB($n) + {utls: utls}), packet_encoding: "xudp",
              transport: {type: "ws", path: $n.path, max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol", headers: {Host: $n.host}}}
      elif $n.proto == "vmess_ws" then
        $b + {type: "vmess", uuid: $n.uuid, security: "auto", alter_id: 0, tls: (tlsSB($n) + {utls: utls}), packet_encoding: "packetaddr",
              transport: {type: "ws", path: $n.path, max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol", headers: {Host: $n.host}}}
      elif $n.proto == "vmess_httpupgrade" then
        $b + {type: "vmess", uuid: $n.uuid, security: "auto", alter_id: 0, tls: (tlsSB($n) + {utls: utls}), packet_encoding: "packetaddr",
              transport: {type: "httpupgrade", path: $n.path, host: $n.host}}
      elif $n.proto == "trojan" then
        $b + {type: "trojan", password: $n.password, tls: (tlsSB($n) + {alpn: ["http/1.1"], utls: utls})}
      elif $n.proto == "hysteria2" then
        $b + {type: "hysteria2", password: $n.password, up_mbps: $n.up, down_mbps: $n.down, tls: (tlsSB($n) + {alpn: ["h3"]})}
        + (if $n.hop != "" then {server_ports: [($n.hop | split("-") | join(":"))]} else {} end)
      elif $n.proto == "tuic" then
        $b + {type: "tuic", uuid: $n.uuid, password: $n.password, congestion_control: $n.cc, tls: (tlsSB($n) + {alpn: ["h3"]})}
      elif $n.proto == "anytls_tls" then
        $b + {type: "anytls", password: $n.password, tls: tlsSB($n)}
      else null end;   # naive(需要 cronet)、xhttp(sing-box 不支持) 不输出
  def mihomo($n):
    {name: $n.name, server: $n.server, port: $n.port} as $b
    | if $n.proto == "vless_reality_vision" then
        $b + {type: "vless", uuid: $n.uuid, network: "tcp", tls: true, udp: true, flow: "xtls-rprx-vision", servername: $n.sni,
              "reality-opts": {"public-key": $n.pbk, "short-id": $n.sid}, "client-fingerprint": "chrome"}
      elif $n.proto == "vless_reality_grpc" then
        $b + {type: "vless", uuid: $n.uuid, network: "grpc", tls: true, udp: true, servername: $n.sni,
              "reality-opts": {"public-key": $n.pbk, "short-id": $n.sid}, "grpc-opts": {"grpc-service-name": "grpc"}, "client-fingerprint": "chrome"}
      elif $n.proto == "vless_reality_xhttp" then
        $b + {type: "vless", uuid: $n.uuid, network: "xhttp", tls: true, udp: true, alpn: ["h2"], servername: $n.sni,
              "xhttp-opts": {path: $n.path, host: $n.host}, "reality-opts": {"public-key": $n.pbk, "short-id": $n.sid}, "client-fingerprint": "chrome"}
      elif $n.proto == "vless_vision_tls" then
        $b + {type: "vless", uuid: $n.uuid, network: "tcp", tls: true, udp: true, flow: "xtls-rprx-vision", servername: $n.sni, "client-fingerprint": "chrome"}
      elif $n.proto == "vless_ws" then
        $b + {type: "vless", uuid: $n.uuid, udp: true, tls: true, network: "ws", "client-fingerprint": "chrome", servername: $n.sni,
              "ws-opts": {path: $n.path, headers: {Host: $n.host}}}
      elif $n.proto == "vless_xhttp_tls" then
        $b + {type: "vless", uuid: $n.uuid, udp: true, tls: true, network: "xhttp", "packet-encoding": "xudp", "client-fingerprint": "chrome", alpn: ["h2"], servername: $n.sni,
              "xhttp-opts": {path: $n.path, host: $n.host, mode: "auto"}}
      elif $n.proto == "vmess_ws" then
        $b + {type: "vmess", uuid: $n.uuid, alterId: 0, cipher: "auto", udp: true, tls: true, "client-fingerprint": "chrome", servername: $n.sni, network: "ws",
              "ws-opts": {path: $n.path, headers: {Host: $n.host}}}
      elif $n.proto == "vmess_httpupgrade" then
        $b + {type: "vmess", uuid: $n.uuid, alterId: 0, cipher: "auto", udp: true, tls: true, "client-fingerprint": "chrome", servername: $n.sni, network: "ws",
              "ws-opts": {path: $n.path, headers: {Host: $n.host}, "v2ray-http-upgrade": true}}
      elif $n.proto == "trojan" then
        $b + {type: "trojan", password: $n.password, "client-fingerprint": "chrome", udp: true, sni: $n.sni, alpn: ["http/1.1"]}
      elif $n.proto == "hysteria2" then
        ($b | if $n.hop != "" then del(.port) + {ports: $n.hop} else . end)
        + {type: "hysteria2", password: $n.password, alpn: ["h3"], sni: $n.sni, up: "\($n.up) Mbps", down: "\($n.down) Mbps"}
      elif $n.proto == "tuic" then
        $b + {type: "tuic", uuid: $n.uuid, password: $n.password, alpn: ["h3"], "congestion-controller": $n.cc, "udp-relay-mode": "native", sni: $n.sni}
      elif $n.proto == "anytls_tls" then
        $b + {type: "anytls", password: $n.password, "client-fingerprint": "chrome", udp: true, sni: $n.sni, alpn: ["h2", "http/1.1"]}
      else null end;   # anytls_reality: mihomo 官方声明不支持；naive: 不支持
  # 格式化明文（沿用 v2ray-agent 的"格式化明文"展示）
  def plain($n):
    if $n.proto == "vless_reality_vision" then "协议类型:VLESS reality，地址:\($n.server)，端口:\($n.port)，用户ID:\($n.uuid)，flow:xtls-rprx-vision，SNI:\($n.sni)，publicKey:\($n.pbk)，shortId:\($n.sid)，client-fingerprint:chrome，传输方式:tcp"
    elif $n.proto == "anytls_reality" then "协议类型:AnyTLS reality，地址:\($n.server)，端口:\($n.port)，密码:\($n.password)，SNI:\($n.sni)，publicKey:\($n.pbk)，shortId:\($n.sid)，uTLS:chrome(必须开启)，传输方式:tcp"
    elif $n.proto == "vless_reality_grpc" then "协议类型:VLESS reality gRPC，地址:\($n.server)，端口:\($n.port)，用户ID:\($n.uuid)，SNI:\($n.sni)，publicKey:\($n.pbk)，shortId:\($n.sid)，serviceName:grpc"
    elif $n.proto == "vless_reality_xhttp" then "协议类型:VLESS reality XHTTP，地址:\($n.server)，端口:\($n.port)，用户ID:\($n.uuid)，SNI:\($n.sni)，publicKey:\($n.pbk)，shortId:\($n.sid)，路径:\($n.path)，模式:auto"
    elif $n.proto == "vless_vision_tls" then "协议类型:VLESS TLS Vision，地址:\($n.server)，端口:\($n.port)，用户ID:\($n.uuid)，SNI:\($n.sni)，flow:xtls-rprx-vision，client-fingerprint:chrome"
    elif $n.proto == "vless_ws" then "协议类型:VLESS WS TLS，地址:\($n.server)，端口:\($n.port)，用户ID:\($n.uuid)，伪装域名/SNI:\($n.sni)，路径:\($n.path)"
    elif $n.proto == "vmess_ws" then "协议类型:VMess WS TLS，地址:\($n.server)，端口:\($n.port)，用户ID:\($n.uuid)，伪装域名/SNI:\($n.sni)，路径:\($n.path)"
    elif $n.proto == "vmess_httpupgrade" then "协议类型:VMess HTTPUpgrade TLS，地址:\($n.server)，端口:\($n.port)，用户ID:\($n.uuid)，伪装域名/SNI:\($n.sni)，路径:\($n.path)"
    elif $n.proto == "vless_xhttp_tls" then "协议类型:VLESS XHTTP TLS，地址:\($n.server)，端口:\($n.port)，用户ID:\($n.uuid)，SNI:\($n.sni)，路径:\($n.path)，模式:auto"
    elif $n.proto == "trojan" then "协议类型:Trojan TLS，地址:\($n.server)，端口:\($n.port)，密码:\($n.password)，SNI:\($n.sni)，alpn:http/1.1"
    elif $n.proto == "hysteria2" then "协议类型:Hysteria2，地址:\($n.server)，端口:\($n.port)\(if $n.hop != "" then "(端口跳跃 \($n.hop))" else "" end)，密码:\($n.password)，SNI:\($n.sni)，alpn:h3，上行:\($n.up)Mbps，下行:\($n.down)Mbps"
    elif $n.proto == "tuic" then "协议类型:Tuic，地址:\($n.server)，端口:\($n.port)，uuid:\($n.uuid)，password:\($n.password)，congestion-controller:\($n.cc)，alpn:h3，SNI:\($n.sni)"
    elif $n.proto == "naive" then "协议类型:Naive，地址:\($n.server)，端口:\($n.port)，用户名:\($n.user)，密码:\($n.password)"
    elif $n.proto == "anytls_tls" then "协议类型:AnyTLS TLS，地址:\($n.server)，端口:\($n.port)，密码:\($n.password)，SNI:\($n.sni)"
    else "" end;
  # NaiveProxy 官方客户端配置
  def naiveClient($n): if $n.proto == "naive" then {listen: "socks://127.0.0.1:1080", proxy: ("https://" + ($n.user|e) + ":" + ($n.password|e) + "@" + $n.server + ":" + ($n.port|tostring))} else null end;

  [ ($PR | to_entries | sort_by(.key as $k | ($reg | map(.id) | index($k))))[] | .key as $id | .value as $c
    | ($S.users | map(select($user == "" or .name == $user))[]) as $u
    | ( [nodeOf($u; $id; $c; (if isReality($id) then $ip else $D end); "")]
        + (if cdnCapable($id) and ($D != "") then [ range(0; $cdns | length) as $i | nodeOf($u; $id; $c; $cdns[$i]; "_cdn\($i + 1)") ] else [] end) )[]
    | . as $n
    | $n + {uri: uri($n), singbox: singbox($n), mihomo: mihomo($n), naive: naiveClient($n), plain: plain($n)}
  ]
EOF

# 节点视图: nodeViews [用户名] [state文件]  -> JSON 数组（每个元素含 uri/singbox/mihomo/plain）
# 公网 IP 优先取 ATR_PUBLIC_IP（调用方批量处理时先查好，避免重复联网）
nodeViews() {
    local ip=${ATR_PUBLIC_IP:-} st=${2:-${ATR_STATE}}
    if [[ -z "${ip}" ]]; then
        ip=$(getPublicIP 4)
        [[ -z "${ip}" ]] && ip=$(getPublicIP 6)
    fi
    jq --arg ip "${ip}" --arg user "${1:-}" --argjson reg "${PROTO_REGISTRY}" "${JQ_NODES}" "${st}"
}

# ----------------------------- YAML 输出 -------------------------------------
# 把 JSON 值渲染为 YAML（所有字符串用 JSON 引号形式，天然合法且不会被注入）
read -r -d '' JQ_YAML <<'EOF'
def isscalar: (type != "object" and type != "array");
# 键只含 [A-Za-z0-9_-] 时原样输出，否则加引号（例如 "geosite:cn,private"）
def sk: (explode | all(. == 45 or . == 95 or (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or (. >= 97 and . <= 122)));
def kq: if (length > 0 and sk) then . else tojson end;
def y($ind):
  if type == "object" then
    to_entries
    | map( (.key | kq) as $k | .value as $v
           | if ($v | type) == "object" and ($v | length) > 0 then
               "\($ind)\($k):\n" + ($v | y($ind + "  "))
             elif ($v | type) == "array" and ($v | length) > 0 and ($v | all(isscalar)) and (($v | tojson | length) <= 70) then
               "\($ind)\($k): \($v | tojson)"
             elif ($v | type) == "array" and ($v | length) > 0 and ($v | all(isscalar)) then
               "\($ind)\($k):\n" + ($v | map("\($ind)  - " + tojson) | join("\n"))
             elif ($v | type) == "array" and ($v | length) > 0 then
               "\($ind)\($k):\n" + ($v | map("\($ind)  - " + (. | tojson)) | join("\n"))
             else "\($ind)\($k): \($v | tojson)" end )
    | join("\n")
  else "\($ind)\(tojson)" end;
# mihomo proxies 列表: 每个代理 "  - name: ..." 后续字段缩进 4 格
def proxies_yaml:
  "proxies:\n" + (map( "  - " + (y("    ")[4:]) ) | join("\n"));
EOF

# jsonToMihomoYaml: stdin = JSON 数组(代理对象)  -> stdout = "proxies:" YAML
jsonToMihomoYaml() {
    jq -r "${JQ_YAML} proxies_yaml"
}

# =============================================================================
#  11  客户端: 配置文件 / 账号展示 / 完整配置模板 / 订阅 / 自检
#      安装、改密、添加用户、改 SNI 之后都会自动重新生成全部客户端配置。
# =============================================================================

# 规则集镜像前缀（与 v2ray-agent 模板一致，便于国内客户端下载；留空则直连 GitHub）
RULESET_MIRROR="${ATR_RULESET_MIRROR-https://gh-proxy.com/}"

# ----------------------------- sing-box 最小可运行配置 ------------------------
read -r -d '' JQ_SB_MIN <<'EOF'
($nodes | map(.tag)) as $tags
| {
    log: {level: "warn", timestamp: true},
    dns: {servers: [{type: "local", tag: "local"}]},
    inbounds: [{type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080}],
    outbounds: ($nodes
                + (if ($tags | length) > 1 then [{type: "selector", tag: "proxy", outbounds: $tags, default: $tags[0]}] else [] end)
                + [{type: "direct", tag: "direct"}]),
    route: {default_domain_resolver: "local",
            rules: [{action: "sniff"}, {protocol: "dns", action: "hijack-dns"}, {ip_is_private: true, outbound: "direct"}],
            final: (if ($tags | length) > 1 then "proxy" else $tags[0] end)}
  }
EOF

# ----------------------------- sing-box 完整配置（分流/DNS/策略组）-------------
read -r -d '' JQ_SB_FULL <<'EOF'
def rs($kind; $name): {tag: ($kind + "-" + $name), type: "remote", format: "binary",
    url: ($mirror + "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/" + $kind + "/" + $name + ".srs"), update_interval: "1d"};
def grp($tag; $members): {type: "selector", tag: $tag, outbounds: $members};
($nodes | map(.tag)) as $tags
| {
    log: {disabled: false, level: "info", timestamp: true},
    http_clients: [{tag: "rule_set_http", detour: "本地直连"}],
    experimental: {
      clash_api: {external_controller: "127.0.0.1:9090", external_ui: "metacubexd",
                  external_ui_download_url: ($mirror + "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"),
                  external_ui_download_detour: "direct", default_mode: "rule"},
      cache_file: {enabled: true}
    },
    dns: {
      servers: [
        {tag: "dns_proxy", type: "https", server: "1.1.1.1", server_port: 443, detour: "自动选择", path: "/dns-query"},
        {tag: "dns_direct", type: "h3", server: "dns.alidns.com", server_port: 443, path: "/dns-query", domain_resolver: "local"},
        {tag: "google", type: "tls", server: "8.8.4.4"},
        {type: "local", tag: "local"}
      ],
      rules: [
        {action: "route", clash_mode: "direct", server: "dns_direct"},
        {action: "route", clash_mode: "global", server: "dns_proxy"},
        {action: "route", rule_set: "geosite-cn", server: "dns_direct"},
        {action: "route", rule_set: "geosite-geolocation-!cn", server: "dns_proxy"}
      ],
      strategy: "prefer_ipv4", final: "dns_direct"
    },
    inbounds: [
      {type: "tun", tag: "tun-in", stack: "system", address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], auto_route: true, strict_route: true},
      {type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 1082}
    ],
    outbounds: ([
        {type: "urltest", tag: "自动选择", outbounds: $tags, url: "https://www.gstatic.com/generate_204", interval: "3m", tolerance: 50, interrupt_exist_connections: false},
        grp("手动切换"; $tags),
        grp("Telegram"; ["手动切换", "自动选择"]),
        grp("YouTube"; ["手动切换", "自动选择"]),
        grp("netflix"; ["手动切换", "自动选择"]),
        grp("OpenAI"; ["手动切换", "自动选择"]),
        grp("Apple"; ["手动切换", "自动选择", "direct"]),
        grp("Google"; ["手动切换", "自动选择"]),
        grp("Microsoft"; ["手动切换", "自动选择", "direct"]),
        grp("Github"; ["手动切换", "自动选择", "direct"]),
        (grp("本地直连"; ["direct", "手动切换", "自动选择"]) + {default: "direct"}),
        (grp("漏网之鱼"; ["自动选择", "手动切换", "direct"]) + {default: "自动选择"}),
        {tag: "direct", type: "direct"}
      ] + $nodes),
    route: {
      default_http_client: "rule_set_http",
      default_domain_resolver: "local",
      rule_set: [rs("geosite"; "category-ads-all"), rs("geosite"; "telegram"), rs("geoip"; "telegram"), rs("geosite"; "youtube"),
                 rs("geosite"; "netflix"), rs("geoip"; "netflix"), rs("geosite"; "openai@ads"), rs("geosite"; "openai"), rs("geosite"; "apple"),
                 rs("geosite"; "google"), rs("geoip"; "google"), rs("geosite"; "microsoft"), rs("geosite"; "geolocation-!cn"),
                 rs("geosite"; "github"), rs("geosite"; "private"), rs("geosite"; "cn"), rs("geoip"; "private"), rs("geoip"; "cn")],
      rules: [
        {action: "sniff", timeout: "1s"},
        {protocol: "dns", action: "hijack-dns"},
        {ip_is_private: true, outbound: "direct"},
        {clash_mode: "global", outbound: "手动切换"},
        {clash_mode: "direct", outbound: "本地直连"},
        {type: "logical", mode: "or",
         rules: [{rule_set: "geosite-category-ads-all"}, {domain_regex: "^stun\\..+"}, {domain_keyword: ["stun", "httpdns"]}, {protocol: "stun"}],
         action: "reject", method: "default", no_drop: false},
        {rule_set: ["geosite-telegram", "geoip-telegram"], outbound: "Telegram"},
        {rule_set: "geosite-youtube", outbound: "YouTube"},
        {rule_set: ["geosite-netflix", "geoip-netflix"], outbound: "netflix"},
        {rule_set: "geosite-openai@ads", action: "reject", method: "default", no_drop: false},
        {rule_set: "geosite-openai", outbound: "OpenAI"},
        {rule_set: "geosite-apple", outbound: "Apple"},
        {rule_set: ["geosite-google", "geoip-google"], outbound: "Google"},
        {rule_set: "geosite-microsoft", outbound: "Microsoft"},
        {rule_set: "geosite-github", outbound: "Github"},
        {rule_set: "geosite-geolocation-!cn", outbound: "手动切换"},
        {rule_set: ["geosite-private", "geosite-cn", "geoip-private", "geoip-cn"], outbound: "本地直连"}
      ],
      final: "漏网之鱼",
      auto_detect_interface: true
    }
  }
EOF

# ----------------------------- mihomo 完整配置 --------------------------------
# $proxies: 代理数组；$provider: 非空则使用订阅 provider（URL），否则内联 proxies
read -r -d '' JQ_CLASH_FULL <<'EOF'
def rp($behavior; $url; $path): {type: "http", behavior: $behavior, url: ($mirror + $url), path: $path, interval: 86400};
def sel($name; $members): {name: $name, type: "select", proxies: $members};
($proxies | map(.name)) as $names
| (if $provider != "" then {use: [$providerName]} else {proxies: $names} end) as $src
| {
    "log-level": "info", mode: "rule", ipv6: true, "mixed-port": 7890, "allow-lan": false,
    "find-process-mode": "strict", "external-controller": "127.0.0.1:9090",
    "geox-url": {geoip: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat",
                 geosite: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
                 mmdb: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb"},
    "geo-auto-update": true, "geo-update-interval": 24,
    "external-controller-cors": {"allow-private-network": true},
    profile: {"store-selected": true, "store-fake-ip": true},
    sniffer: {enable: true, "override-destination": false, sniff: {QUIC: {ports: [443]}, TLS: {ports: [443]}, HTTP: {ports: [80]}}},
    dns: {enable: true, "prefer-h3": false, listen: "127.0.0.1:1053", ipv6: true, "enhanced-mode": "fake-ip", "fake-ip-range": "198.18.0.1/16",
          "fake-ip-filter": ["*.lan", "*.local", "dns.google", "localhost.ptlogin2.qq.com"], "use-hosts": true,
          nameserver: ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "1.1.1.1", "8.8.8.8"],
          "proxy-server-nameserver": ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"],
          "nameserver-policy": {"geosite:cn,private": ["https://doh.pub/dns-query", "https://dns.alidns.com/dns-query"]}}
  }
  + (if $provider != "" then
       {"proxy-providers": {($providerName): {type: "http", path: ("./" + $providerName + "_provider.yaml"), url: $provider, interval: 3600, proxy: "DIRECT",
                            "health-check": {enable: true, url: "https://cp.cloudflare.com/generate_204", interval: 300}}}}
     else {proxies: $proxies} end)
  + {
    "proxy-groups": [
      ({name: "手动切换", type: "select"} + $src),
      ({name: "自动选择", type: "url-test", url: "https://cp.cloudflare.com/generate_204", interval: 36000, tolerance: 50} + $src),
      sel("全球代理"; ["手动切换", "自动选择"]),
      sel("流媒体"; ["手动切换", "自动选择", "DIRECT"]),
      sel("DNS_Proxy"; ["自动选择", "手动切换", "DIRECT"]),
      sel("Telegram"; ["手动切换", "自动选择"]),
      sel("Google"; ["手动切换", "自动选择", "DIRECT"]),
      sel("YouTube"; ["手动切换", "自动选择"]),
      sel("Netflix"; ["流媒体", "手动切换", "自动选择"]),
      sel("Spotify"; ["流媒体", "手动切换", "自动选择", "DIRECT"]),
      sel("HBO"; ["流媒体", "手动切换", "自动选择"]),
      sel("Bing"; ["手动切换", "自动选择"]),
      sel("OpenAI"; ["手动切换", "自动选择"]),
      sel("ClaudeAI"; ["手动切换", "自动选择"]),
      sel("Disney"; ["流媒体", "手动切换", "自动选择"]),
      sel("GitHub"; ["手动切换", "自动选择", "DIRECT"]),
      sel("国内媒体"; ["DIRECT"]),
      sel("本地直连"; ["DIRECT", "自动选择"]),
      sel("漏网之鱼"; ["DIRECT", "手动切换", "自动选择"])
    ],
    "rule-providers": {
      lan: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Lan/Lan.yaml"; "./Rules/lan.yaml"),
      reject: rp("domain"; "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/reject.txt"; "./ruleset/reject.yaml"),
      proxy: rp("domain"; "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/proxy.txt"; "./ruleset/proxy.yaml"),
      direct: rp("domain"; "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt"; "./ruleset/direct.yaml"),
      private: rp("domain"; "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/private.txt"; "./ruleset/private.yaml"),
      gfw: rp("domain"; "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt"; "./ruleset/gfw.yaml"),
      greatfire: rp("domain"; "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/greatfire.txt"; "./ruleset/greatfire.yaml"),
      "tld-not-cn": rp("domain"; "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt"; "./ruleset/tld-not-cn.yaml"),
      telegramcidr: rp("ipcidr"; "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/telegramcidr.txt"; "./ruleset/telegramcidr.yaml"),
      applications: rp("classical"; "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/applications.txt"; "./ruleset/applications.yaml"),
      Disney: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Disney/Disney.yaml"; "./ruleset/disney.yaml"),
      Netflix: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Netflix/Netflix.yaml"; "./ruleset/netflix.yaml"),
      YouTube: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/YouTube/YouTube.yaml"; "./ruleset/youtube.yaml"),
      HBO: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/HBO/HBO.yaml"; "./ruleset/hbo.yaml"),
      OpenAI: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/OpenAI/OpenAI.yaml"; "./ruleset/openai.yaml"),
      ClaudeAI: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Claude/Claude.yaml"; "./ruleset/claudeai.yaml"),
      Bing: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Bing/Bing.yaml"; "./ruleset/bing.yaml"),
      Google: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Google/Google.yaml"; "./ruleset/google.yaml"),
      GitHub: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/GitHub/GitHub.yaml"; "./ruleset/github.yaml"),
      Spotify: rp("classical"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Spotify/Spotify.yaml"; "./ruleset/spotify.yaml"),
      ChinaMaxDomain: rp("domain"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_Domain.yaml"; "./Rules/ChinaMaxDomain.yaml"),
      ChinaMaxIPNoIPv6: rp("ipcidr"; "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_IP_No_IPv6.yaml"; "./Rules/ChinaMaxIPNoIPv6.yaml")
    },
    rules: ["RULE-SET,YouTube,YouTube,no-resolve", "RULE-SET,Google,Google,no-resolve", "RULE-SET,GitHub,GitHub",
            "RULE-SET,telegramcidr,Telegram,no-resolve", "RULE-SET,Spotify,Spotify,no-resolve", "RULE-SET,Netflix,Netflix",
            "RULE-SET,HBO,HBO", "RULE-SET,Bing,Bing", "RULE-SET,OpenAI,OpenAI", "RULE-SET,ClaudeAI,ClaudeAI", "RULE-SET,Disney,Disney",
            "RULE-SET,proxy,全球代理", "RULE-SET,gfw,全球代理", "RULE-SET,applications,本地直连", "RULE-SET,ChinaMaxDomain,本地直连",
            "RULE-SET,ChinaMaxIPNoIPv6,本地直连,no-resolve", "RULE-SET,lan,本地直连,no-resolve", "GEOIP,CN,本地直连", "MATCH,漏网之鱼"]
  }
EOF

# 把一个 JSON 对象整体渲染为 YAML（顶层，不加缩进）
jsonObjToYaml() { jq -r "${JQ_YAML} y(\"\")"; }

# ----------------------------- 生成各类配置 ----------------------------------
# cfgSbMin <outbounds JSON 数组>    stdout: 最小可运行配置
cfgSbMin() { jq -n --argjson nodes "$1" "${JQ_SB_MIN}"; }
cfgSbFull() { jq -n --argjson nodes "$1" --arg mirror "${RULESET_MIRROR}" "${JQ_SB_FULL}"; }
# cfgClashFull <proxies JSON 数组> [provider URL] [provider 名称]  stdout: YAML
cfgClashFull() {
    jq -n --argjson proxies "$1" --arg mirror "${RULESET_MIRROR}" --arg provider "${2:-}" --arg providerName "${3:-atr_provider}" \
        "${JQ_CLASH_FULL}" | jsonObjToYaml
}

# 用 sing-box 校验一份(派生的)客户端配置；失败只告警，不影响事务
_checkClientFile() { # _checkClientFile <文件> <描述>
    [[ -x "${SB_BIN}" ]] || return 0
    local out
    if ! out=$("${SB_BIN}" check -c "$1" 2>&1); then
        echoContent yellow " ---> 提示: $2 未通过 sing-box 校验（不影响服务端）:"
        printf '%s\n' "${out}" | sed 's/\x1b\[[0-9;]*m//g' | tail -n 3
        return 1
    fi
}

# ----------------------------- 生成全部用户的客户端文件 ------------------------
# 目录: ${CLIENT_DIR}/<用户>/{links.txt, sing-box.json, sing-box-full.json, mihomo-proxies.yaml, mihomo-full.yaml, naive-client.json}
# shellcheck disable=SC2120
generateClientFiles() { # generateClientFiles [用户名]
    stateExists || return 1
    local only=${1:-} u d n views dir sbouts mhprox
    mkdir -p "${CLIENT_DIR}"
    chmod 700 "${CLIENT_DIR}" 2>/dev/null
    [[ -z "${ATR_PUBLIC_IP:-}" ]] && {
        ATR_PUBLIC_IP=$(getPublicIP 4)
        [[ -z "${ATR_PUBLIC_IP}" ]] && ATR_PUBLIC_IP=$(getPublicIP 6)
    }
    # 清理已删除用户的目录
    if [[ -z "${only}" ]]; then
        for d in "${CLIENT_DIR}"/*/; do
            [[ -d "${d}" ]] || continue
            n=$(basename "${d}")
            userExists "${n}" || rm -rf "${d}"
        done
    fi
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        [[ -n "${only}" && "${u}" != "${only}" ]] && continue
        dir="${CLIENT_DIR}/${u}"
        mkdir -p "${dir}"
        chmod 700 "${dir}"
        rm -f "${dir}"/links.txt "${dir}"/sing-box*.json "${dir}"/mihomo*.yaml "${dir}"/naive-client.json
        views=$(nodeViews "${u}") || continue
        jq -r '.[]|select(.uri!=null)|.uri' <<<"${views}" >"${dir}/links.txt"
        sbouts=$(jq -c '[.[]|select(.singbox!=null)|.singbox]' <<<"${views}")
        mhprox=$(jq -c '[.[]|select(.mihomo!=null)|.mihomo]' <<<"${views}")
        if [[ "$(jq 'length' <<<"${sbouts}")" != "0" ]]; then
            cfgSbMin "${sbouts}" | jq . >"${dir}/sing-box.json"
            cfgSbFull "${sbouts}" | jq . >"${dir}/sing-box-full.json"
            _checkClientFile "${dir}/sing-box.json" "${u} 的 sing-box 客户端配置"
            _checkClientFile "${dir}/sing-box-full.json" "${u} 的 sing-box 完整客户端配置"
        fi
        if [[ "$(jq 'length' <<<"${mhprox}")" != "0" ]]; then
            jsonToMihomoYaml <<<"${mhprox}" >"${dir}/mihomo-proxies.yaml"
            cfgClashFull "${mhprox}" >"${dir}/mihomo-full.yaml"
        fi
        if [[ "$(jq '[.[]|select(.naive!=null)]|length' <<<"${views}")" != "0" ]]; then
            jq '[.[]|select(.naive!=null)|.naive][0]' <<<"${views}" >"${dir}/naive-client.json"
        fi
        chmod 600 "${dir}"/* 2>/dev/null
    done < <(userNames)
    if stateExists && [[ "$(S '.nginx.subscribe.enabled')" == "true" ]]; then
        generateSubscription >/dev/null 2>&1
    fi
    return 0
}

# ----------------------------- 二维码 ----------------------------------------
printQR() { # printQR <文本>
    command -v qrencode >/dev/null 2>&1 || return 0
    if ((${#1} > 2300)); then
        echoContent yellow "    (链接过长，已跳过二维码；请直接复制链接，或使用订阅/完整配置文件)"
        return 0
    fi
    printf '%s' "$1" | qrencode -s 1 -m 1 -t ANSIUTF8
}

# ----------------------------- 展示账号 --------------------------------------
# showAccounts [用户名] [是否显示二维码 0|1]
showAccounts() {
    stateExists || {
        echoContent red " ---> 未安装"
        return 1
    }
    local only=${1:-} qr=${2:-0} u views total i name proto title uri plain
    local dir
    [[ -z "${ATR_PUBLIC_IP:-}" ]] && {
        ATR_PUBLIC_IP=$(getPublicIP 4)
        [[ -z "${ATR_PUBLIC_IP}" ]] && ATR_PUBLIC_IP=$(getPublicIP 6)
    }
    [[ -n "${only}" ]] && ! userExists "${only}" && {
        echoContent red " ---> 用户不存在: ${only}"
        return 1
    }
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        [[ -n "${only}" && "${u}" != "${only}" ]] && continue
        views=$(nodeViews "${u}")
        total=$(jq 'length' <<<"${views}")
        echoContent skyBlue "\n==================== 账号: ${u} ===================="
        echoContent yellow "UUID: \c"
        printRaw yellow "$(S --arg n "${u}" '.users[]|select(.name==$n)|.uuid')"
        echoContent yellow "密码: \c"
        printRaw yellow "$(S --arg n "${u}" '.users[]|select(.name==$n)|.password')"
        for ((i = 0; i < total; i++)); do
            name=$(jq -r ".[${i}].name" <<<"${views}")
            proto=$(jq -r ".[${i}].proto" <<<"${views}")
            title=$(protoName "${proto}")
            uri=$(jq -r ".[${i}].uri // empty" <<<"${views}")
            plain=$(jq -r ".[${i}].plain" <<<"${views}")
            echoContent skyBlue "\n [${i}] ${title}  (${name})"
            if [[ -n "${uri}" ]]; then
                echoContent yellow " ---> 通用分享链接"
                printRaw green "    ${uri}"
            else
                echoContent yellow " ---> 通用分享链接: 该协议没有标准分享链接，请使用下方 sing-box 客户端配置"
            fi
            echoContent yellow " ---> 格式化明文"
            printRaw green "    ${plain}"
            if [[ "${qr}" == "1" && -n "${uri}" ]]; then
                echoContent yellow " ---> 二维码"
                printQR "${uri}"
            fi
        done
        dir="${CLIENT_DIR}/${u}"
        if [[ -s "${dir}/sing-box.json" ]]; then
            echoContent skyBlue "\n---------- sing-box 客户端配置（完整可运行：sing-box run -c config.json）----------"
            jq . "${dir}/sing-box.json"
            echoContent yellow "\n 完整分流配置(含 tun/DNS/策略组): ${dir}/sing-box-full.json"
        fi
        if [[ -s "${dir}/mihomo-proxies.yaml" ]]; then
            echoContent skyBlue "\n---------- mihomo / Clash.Meta 配置片段（粘贴到 proxies: 下）----------"
            cat "${dir}/mihomo-proxies.yaml"
            echoContent yellow "\n 完整 mihomo 配置: ${dir}/mihomo-full.yaml"
        fi
        if jq -e '[.[]|select(.proto=="anytls_reality")]|length>0' <<<"${views}" >/dev/null 2>&1; then
            echoContent red "\n ! 注意: mihomo(Clash.Meta) 官方明确不支持 AnyTLS+Reality，该节点仅 sing-box 客户端可用"
            echoContent yellow "   (SFA/SFI/sing-box、Hiddify 等基于 sing-box 内核的客户端)。mihomo 用户请使用上面的 VLESS+Reality 等节点。"
        fi
        if [[ -s "${dir}/naive-client.json" ]]; then
            echoContent skyBlue "\n---------- NaiveProxy 官方客户端配置 ----------"
            jq . "${dir}/naive-client.json"
        fi
        echoContent yellow "\n 客户端文件目录: ${dir}/"
    done < <(userNames)
}

# ----------------------------- 订阅 ------------------------------------------
subscriptionBase() { # 订阅 URL 前缀 scheme://host:port
    local scheme=https host port
    [[ "$(S '.nginx.subscribe.ssl')" == "true" ]] || scheme=http
    host=$(S '.domain // ""')
    [[ -z "${host}" || "${scheme}" == "http" ]] && host=$(getPublicIP 4)
    port=$(S '.nginx.subscribe.port')
    echo "${scheme}://${host}:${port}"
}

subscriptionToken() { # 用户名 + salt 的 md5（订阅 URL 令牌）
    printf '%s' "${1}$(S '.nginx.subscribe.salt')" | md5sum | awk '{print $1}'
}

# 把远程机器的订阅合并进本机用户订阅（远程用户名与 salt 需与本机一致，令牌才相同）
_appendRemoteSubscriptions() { # _appendRemoteSubscriptions <令牌> <default文件> <clash文件> <singbox_profiles文件>
    local token=$1 fdef=$2 fclash=$3 fsb=$4 line host port alias scheme tmp
    [[ -s "${SUB_REMOTE_FILE}" ]] || return 0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        host=$(cut -d: -f1 <<<"${line}")
        port=$(cut -d: -f2 <<<"${line}")
        alias=$(cut -d: -f3 <<<"${line}")
        scheme=https
        [[ "$(cut -d: -f4 <<<"${line}")" == "http" ]] && scheme=http
        # host/port/alias 会进入 URL 与 sed 脚本，必须严格校验
        isPort "${port}" && isSafeName "${alias}" || continue
        isDomainName "${host}" || isIPv4 "${host}" || continue
        tmp=$(mktemp "${ATR_TMP:-/tmp}/rs.XXXXXX")
        # 通用订阅
        if curl -fsSk -m 15 "${scheme}://${host}:${port}/s/default/${token}" -o "${tmp}" 2>/dev/null && [[ -s "${tmp}" ]]; then
            base64 -d <"${tmp}" 2>/dev/null | sed "s/#\([^#]*\)\$/#\1_${alias}/" >>"${fdef}"
        fi
        # clash: 去掉 proxies: 行并给 name 加后缀
        if curl -fsSk -m 15 "${scheme}://${host}:${port}/s/clashMeta/${token}" -o "${tmp}" 2>/dev/null && [[ -s "${tmp}" ]]; then
            grep -v '^proxies:' "${tmp}" | sed "s/^\\(  - name: \"[^\"]*\\)\"/\\1_${alias}\"/" >>"${fclash}"
        fi
        # sing-box 出站数组
        if curl -fsSk -m 15 "${scheme}://${host}:${port}/s/sing-box_profiles/${token}" -o "${tmp}" 2>/dev/null && jq -e 'type=="array"' "${tmp}" >/dev/null 2>&1; then
            jq --arg a "_${alias}" 'map(.tag += $a)' "${tmp}" >"${tmp}.2" && jq -s '.[0] + .[1]' "${fsb}" "${tmp}.2" >"${tmp}.3" && mv "${tmp}.3" "${fsb}"
        fi
        rm -f "${tmp}" "${tmp}.2" "${tmp}.3"
    done <"${SUB_REMOTE_FILE}"
}

generateSubscription() {
    [[ "$(S '.nginx.subscribe.enabled')" == "true" ]] || return 0
    local u token base views sbouts mhprox kind w
    base=$(subscriptionBase)
    for kind in default clashMeta clashMetaProfiles sing-box sing-box_profiles; do
        mkdir -p "${SUB_DIR}/${kind}"
        find "${SUB_DIR}/${kind}" -type f -delete 2>/dev/null
    done
    w="${ATR_TMP:-/tmp}/sub.$$"
    mkdir -p "${w}"
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        token=$(subscriptionToken "${u}")
        views=$(nodeViews "${u}")
        jq -r '.[]|select(.uri!=null)|.uri' <<<"${views}" >"${w}/links"
        jq -c '[.[]|select(.singbox!=null)|.singbox]' <<<"${views}" >"${w}/sb.json"
        jq -c '[.[]|select(.mihomo!=null)|.mihomo]' <<<"${views}" >"${w}/mh.json"
        jsonToMihomoYaml <"${w}/mh.json" >"${w}/clash" 2>/dev/null
        _appendRemoteSubscriptions "${token}" "${w}/links" "${w}/clash" "${w}/sb.json"
        base64 -w 0 "${w}/links" 2>/dev/null >"${SUB_DIR}/default/${token}" || base64 "${w}/links" | tr -d '\n' >"${SUB_DIR}/default/${token}"
        cp "${w}/clash" "${SUB_DIR}/clashMeta/${token}"
        cp "${w}/sb.json" "${SUB_DIR}/sing-box_profiles/${token}"
        # 完整 mihomo 配置: 用 provider 指向本机订阅
        sbouts=$(cat "${w}/sb.json")
        cfgClashFull "$(cat "${w}/mh.json")" "${base}/s/clashMeta/${token}" "$(subscriptionToken "provider")" >"${SUB_DIR}/clashMetaProfiles/${token}" 2>/dev/null
        if [[ "$(jq length <<<"${sbouts}")" != "0" ]]; then
            cfgSbFull "${sbouts}" | jq . >"${SUB_DIR}/sing-box/${token}"
        fi
    done < <(userNames)
    rm -rf "${w}"
    chmod -R a+rX "${SUB_DIR}" 2>/dev/null
    return 0
}

showSubscriptionLinks() { # showSubscriptionLinks [用户名]
    [[ "$(S '.nginx.subscribe.enabled')" == "true" ]] || {
        echoContent yellow " ---> 未启用订阅服务（需要 nginx）"
        return 1
    }
    local only=${1:-} u token base
    base=$(subscriptionBase)
    [[ "${base}" == http://* ]] && echoContent yellow " ---> 提示: 当前为 HTTP 明文订阅，可能被运营商拦截，建议配置域名证书后使用 HTTPS"
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        [[ -n "${only}" && "${u}" != "${only}" ]] && continue
        token=$(subscriptionToken "${u}")
        echoContent skyBlue "\n---------- 订阅: ${u} ----------"
        echoContent yellow "默认订阅(通用):"
        printRaw green "    ${base}/s/default/${token}"
        printQR "${base}/s/default/${token}"
        [[ -s "${SUB_DIR}/clashMetaProfiles/${token}" ]] && {
            echoContent yellow "Clash.Meta(mihomo) 订阅:"
            printRaw green "    ${base}/s/clashMetaProfiles/${token}"
        }
        [[ -s "${SUB_DIR}/sing-box/${token}" ]] && {
            echoContent yellow "sing-box 订阅:"
            printRaw green "    ${base}/s/sing-box/${token}"
        }
    done < <(userNames)
}

# ----------------------------- 自检（回环握手）--------------------------------
# 用刚装好的服务端对应的客户端配置，在本机回环上真实握手一次并访问外网。
# 能发现: 公私钥不匹配、SNI/short_id 写错、端口未放行到进程、证书问题。
# 返回: 0 通过  1 失败  2 跳过(无法自检)
selfCheckProtocol() { # selfCheckProtocol <协议id> [用户名]
    local id=$1 user=${2:-} node out cfg cp pid log code url title
    title=$(protoName "${id}")
    [[ -x "${SB_BIN}" ]] || {
        echoContent yellow "  - ${title}: 跳过（本机没有 sing-box，仅验证端口监听）"
        return 2
    }
    [[ -n "${user}" ]] || user=$(userNames | head -n 1)
    node=$(nodeViews "${user}" | jq -c --arg p "${id}" '[.[]|select(.proto==$p and (.name|test("_cdn[0-9]+$")|not))][0]')
    if [[ -z "${node}" || "${node}" == "null" ]] || [[ "$(jq -r '.singbox // empty|type' <<<"${node}")" != "object" ]]; then
        echoContent yellow "  - ${title}: 跳过（sing-box 客户端不支持该协议，请用对应客户端验证）"
        return 2
    fi
    cp=$(randomFreePort)
    cfg="${ATR_TMP:-/tmp}/selfcheck.${id}.json"
    log="${ATR_TMP:-/tmp}/selfcheck.${id}.log"
    # 指向本机回环；TLS 类协议只验证服务端功能，不验证证书链，故 insecure
    jq -n --argjson n "$(jq -c '.singbox' <<<"${node}")" --argjson cp "${cp}" '
      ($n | .server = "127.0.0.1" | del(.server_ports)
          | if (.tls.reality == null) then .tls.insecure = true else . end) as $o
      | {log: {level: "warn"}, inbounds: [{type: "mixed", tag: "in", listen: "127.0.0.1", listen_port: $cp}],
         outbounds: [$o], route: {final: $o.tag}}' >"${cfg}"
    "${SB_BIN}" run -c "${cfg}" >"${log}" 2>&1 &
    pid=$!
    sleep 2
    code=000
    for url in "https://www.cloudflare.com/cdn-cgi/trace" "http://www.gstatic.com/generate_204"; do
        code=$(curl -s -m 15 -x "socks5h://127.0.0.1:${cp}" -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)
        [[ "${code}" == "200" || "${code}" == "204" ]] && break
    done
    kill "${pid}" 2>/dev/null
    wait "${pid}" 2>/dev/null
    if [[ "${code}" == "200" || "${code}" == "204" ]]; then
        echoContent green "  ✓ ${title}: 握手成功，经隧道访问外网正常 (HTTP ${code})"
        return 0
    fi
    out=$(sed 's/\x1b\[[0-9;]*m//g' "${log}" | grep -iE 'error|fail|reality|tls|handshake' | tail -n 3)
    echoContent red "  ✗ ${title}: 自检失败 (HTTP ${code})"
    [[ -n "${out}" ]] && printf '      %s\n' "${out}"
    if [[ "$(jq -r '.core' <<<"${node}")" == "xray" && "$(protoField "${id}" reality)" == "true" ]]; then
        # Xray 承载的 Reality: 先看是不是目标域名不兼容（证书链长 + X25519MLKEM768）
        realityXrayCompat "$(S '.reality.sni')" "$(S '.reality.dest_port')" >/dev/null 2>&1 || {
            echoContent red "      原因: 目标域名 $(S '.reality.sni') 与 Xray 不兼容（证书链较长且启用 X25519MLKEM768）"
            echoContent yellow "      请用 Reality 管理 → 修改目标域名(SNI)，选 dl.google.com / www.apple.com / www.python.org 等"
        }
    fi
    if grep -qi 'reality verification failed' "${log}"; then
        echoContent red "      原因: Reality 校验失败 —— 客户端公钥与服务端私钥不匹配，或 short_id/SNI 不一致"
    fi
    return 1
}

selfCheckAll() {
    stateExists || {
        echoContent red " ---> 未安装"
        return 1
    }
    local id fail=0 skip=0 pass=0 rc user
    user=$(userNames | head -n 1)
    echoContent skyBlue "\n进度  自检 : 回环握手测试（用户 ${user}）"
    while read -r id; do
        [[ -z "${id}" ]] && continue
        selfCheckProtocol "${id}" "${user}"
        rc=$?
        case ${rc} in 0) pass=$((pass + 1)) ;; 1) fail=$((fail + 1)) ;; *) skip=$((skip + 1)) ;; esac
    done < <(installedProtocols)
    echoContent yellow " ---> 自检结果: 通过 ${pass}，失败 ${fail}，跳过 ${skip}"
    ((fail == 0))
}

# =============================================================================
#  12  用户管理: 查看 / 添加 / 删除(至少保留一个) / 重置密码或 UUID
#      每一次变更都是一次事务；成功后自动重新生成全部客户端配置并展示。
# =============================================================================

# 变更成功后: 重新生成全部客户端配置，展示受影响用户的账号，并提示需要同步
postChangeShow() { # postChangeShow [用户名|空=全部] [提示语]
    generateClientFiles
    showAccounts "${1:-}" 0
    echoContent yellow "\n ! ${2:-配置已变更}：客户端配置已自动重新生成，请把上面的链接/配置同步到对应客户端。"
}

# 用户选择器: 列出编号，选择后设置 PICKED_USER
PICKED_USER=""
pickUser() { # pickUser [提示]
    local i=0 name sel
    local -a names=()
    PICKED_USER=""
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        names+=("${name}")
        i=$((i + 1))
        echoContent yellow "${i}.${name}"
    done < <(userNames)
    ((i > 0)) || {
        echoContent red " ---> 没有用户"
        return 1
    }
    ask sel "${1:-请选择用户编号或输入用户名}:" || return 1
    if isInt "${sel}" && ((10#${sel} >= 1 && 10#${sel} <= i)); then
        PICKED_USER=${names[$((10#${sel} - 1))]}
    elif userExists "${sel}"; then
        PICKED_USER=${sel}
    else
        echoContent red " ---> 选择错误"
        return 1
    fi
}

# 询问一个用户的 名称 / UUID / 密码（可回车随机），写入候选状态
# shellcheck disable=SC2120
promptNewUser() { # promptNewUser [默认用户名]
    local uuid name pass
    while true; do
        ask uuid "请输入合法的 UUID，[回车]随机 UUID:" || return 1
        [[ -z "${uuid}" ]] && {
            uuid=$(newUUID)
            break
        }
        if ! isUUID "${uuid}"; then
            echoContent red " ---> UUID 格式不正确"
            continue
        fi
        if stagedGet --arg u "${uuid}" '.users[]|select(.uuid==$u)|.name' | grep -q .; then
            echoContent red " ---> UUID 不可重复"
            continue
        fi
        break
    done
    while true; do
        ask name "请输入用户名(字母数字 . _ @ -)，[回车]使用 ${1:-${uuid%%-*}}:" || return 1
        [[ -z "${name}" ]] && name=${1:-${uuid%%-*}}
        isSafeName "${name}" || {
            echoContent red " ---> 用户名只能包含字母、数字、. _ @ -，且不超过 48 位"
            continue
        }
        if stagedGet --arg n "${name}" '.users[]|select(.name==$n)|.name' | grep -q .; then
            echoContent red " ---> 用户名不可重复"
            continue
        fi
        break
    done
    while true; do
        ask pass "请输入密码(用于 AnyTLS/Hysteria2/Tuic/Trojan/Naive，可含特殊字符)，[回车]随机:" || return 1
        [[ -z "${pass}" ]] && {
            pass=$(newPassword)
            break
        }
        isValidSecret "${pass}" && break
        echoContent red " ---> 密码不能为空、不能含换行/制表符，且不超过 128 位"
    done
    stagedUserAdd "${name}" "${uuid}" "${pass}"
}

userAddFlow() {
    stateExists && [[ "$(userCount)" != "0" ]] || {
        echoContent red " ---> 尚未安装任何协议"
        return 1
    }
    local num i names=()
    ask num "请输入要添加的用户数量:" || return 1
    if ! isInt "${num}" || ((num < 1 || num > 50)); then
        echoContent red " ---> 输入有误（1-50）"
        return 1
    fi
    stagedBegin
    for ((i = 1; i <= num; i++)); do
        echoContent skyBlue "\n---- 第 ${i}/${num} 个用户 ----"
        promptNewUser || {
            stagedDiscard
            return 1
        }
        names+=("$(stagedGet '.users|last|.name')")
    done
    if applyStaged "添加用户"; then
        generateClientFiles
        local n
        for n in "${names[@]}"; do showAccounts "${n}" 0; done
        echoContent yellow "\n ---> 已添加 ${#names[@]} 个用户，账号会同时添加到所有已安装的协议"
    else
        stagedDiscard
        return 1
    fi
}

userDeleteFlow() {
    stateExists || {
        echoContent red " ---> 尚未安装"
        return 1
    }
    if [[ "$(userCount)" -le 1 ]]; then
        echoContent red " ---> 只剩一个用户，至少需要保留一个，无法删除"
        return 1
    fi
    pickUser "请选择要删除的用户编号或输入用户名[仅支持单个删除]" || return 1
    confirm "确认删除用户 ${PICKED_USER} ？该用户的所有客户端将立即失效" n || return 0
    stagedBegin
    stagedUserDel "${PICKED_USER}" || {
        stagedDiscard
        return 1
    }
    if applyStaged "删除用户"; then
        generateClientFiles
        echoContent green " ---> 已删除用户 ${PICKED_USER}（并同步移除其客户端配置文件）"
    else
        stagedDiscard
        return 1
    fi
}

# 重置密码 / UUID
# userResetFlow [用户名] [密码|空=随机] [模式 password|uuid|both]  —— 带参数时为非交互(CLI)
userResetFlow() {
    local user=${1:-} newpass=${2:-} mode=${3:-} choice newuuid
    stateExists || {
        echoContent red " ---> 尚未安装"
        return 1
    }
    if [[ -z "${user}" ]]; then
        pickUser "请选择要重置凭据的用户编号或输入用户名" || return 1
        user=${PICKED_USER}
        echoContent red "\n=============================================================="
        echoContent yellow "1.重置密码  [AnyTLS / Hysteria2 / Tuic / Trojan / Naive 使用]"
        echoContent yellow "2.重置 UUID [VLESS / VMess / Tuic 使用]"
        echoContent yellow "3.两者都重置"
        echoContent red "=============================================================="
        ask choice "请选择[回车默认1]:" || return 1
        case "${choice:-1}" in 1) mode=password ;; 2) mode=uuid ;; 3) mode=both ;; *)
            echoContent red " ---> 选择错误"
            return 1
            ;;
        esac
        if [[ "${mode}" != "uuid" ]]; then
            while true; do
                ask newpass "请输入新密码(可含特殊字符)，[回车]随机:" || return 1
                [[ -z "${newpass}" ]] && break
                isValidSecret "${newpass}" && break
                echoContent red " ---> 密码不能为空、不能含换行/制表符，且不超过 128 位"
            done
        fi
    fi
    userExists "${user}" || {
        echoContent red " ---> 用户不存在: ${user}"
        return 1
    }
    mode=${mode:-password}
    stagedBegin
    if [[ "${mode}" == "password" || "${mode}" == "both" ]]; then
        [[ -z "${newpass}" ]] && newpass=$(newPassword)
        isValidSecret "${newpass}" || {
            echoContent red " ---> 密码不合法"
            stagedDiscard
            return 1
        }
        stagedEdit --arg n "${user}" --arg p "${newpass}" '.users |= map(if .name==$n then .password=$p else . end)' || return 1
    fi
    if [[ "${mode}" == "uuid" || "${mode}" == "both" ]]; then
        newuuid=$(newUUID)
        stagedEdit --arg n "${user}" --arg u "${newuuid}" '.users |= map(if .name==$n then .uuid=$u else . end)' || return 1
    fi
    if applyStaged "重置凭据(${user})"; then
        postChangeShow "${user}" "用户 ${user} 的凭据已重置，旧凭据已失效"
    else
        stagedDiscard
        return 1
    fi
}

# ----------------------------- 菜单 ------------------------------------------
manageUsers() {
    stateExists && [[ "$(userCount)" != "0" ]] || {
        echoContent red " ---> 未安装，请先使用 1.安装 或 2.任意组合安装"
        return 1
    }
    echoContent skyBlue "\n功能 1/1 : 用户管理"
    echoContent red "\n=============================================================="
    echoContent yellow "# 添加用户时可自定义用户名/UUID/密码；账号会同时添加到所有已安装的协议\n"
    echoContent yellow "1.查看账号"
    echoContent yellow "2.查看订阅"
    echoContent yellow "3.管理其他订阅"
    echoContent yellow "4.添加用户"
    echoContent yellow "5.删除用户"
    echoContent yellow "6.重置密码/UUID"
    echoContent yellow "7.重新生成全部客户端配置"
    echoContent red "=============================================================="
    local c
    ask c "请输入:" || return 1
    case "${c}" in
    1)
        local qr=0
        confirm "是否同时显示二维码？" n && qr=1
        showAccounts "" "${qr}"
        ;;
    2) subscriptionMenu ;;
    3) otherSubscriptionMenu ;;
    4) userAddFlow ;;
    5) userDeleteFlow ;;
    6) userResetFlow ;;
    7)
        generateClientFiles
        echoContent green " ---> 已重新生成全部客户端配置: ${CLIENT_DIR}/"
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# =============================================================================
#  13  安装流程
#      1.安装 (5 个预设组合)  2.任意组合安装 (全部协议，前 5 个在最前)  3.一键无域名 AnyTLS+Reality
#      所有改动先累积在候选状态里，最后由 applyStaged 作为一次事务应用。
# =============================================================================

# ----------------------------- 命令别名 atr -----------------------------------
aliasInstall() {
    local self
    self=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)
    [[ -f "${self}" ]] || return 0 # 通过管道执行时没有脚本文件
    mkdir -p "${ATR_HOME}"
    if [[ "${self}" != "${ATR_SCRIPT_PATH}" ]]; then
        install -m 700 "${self}" "${ATR_SCRIPT_PATH}" 2>/dev/null || return 0
    fi
    mkdir -p "${ATR_BIN_DIR}" 2>/dev/null
    if [[ ! -L "${ATR_BIN_DIR}/${ATR_CMD}" || "$(readlink -f "${ATR_BIN_DIR}/${ATR_CMD}")" != "$(readlink -f "${ATR_SCRIPT_PATH}")" ]]; then
        ln -sf "${ATR_SCRIPT_PATH}" "${ATR_BIN_DIR}/${ATR_CMD}" 2>/dev/null &&
            echoContent green "快捷方式创建成功，可执行[${ATR_CMD}]重新打开脚本"
    fi
}

# ----------------------------- 选择核心 --------------------------------------
SELECTED_CORE=""
selectCore() { # sing-box 排第一，Xray 排第二
    local c
    SELECTED_CORE=""
    echoContent skyBlue "\n功能 1/1 : 选择核心安装"
    echoContent red "\n=============================================================="
    echoContent yellow "1.sing-box"
    echoContent yellow "2.Xray-core"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1) SELECTED_CORE="sing-box" ;;
    2) SELECTED_CORE="xray" ;;
    *)
        echoContent red " ---> 选择错误"
        return 1
        ;;
    esac
}

# ----------------------------- 端口询问 --------------------------------------
# 本次候选状态里已占用的 "net port"（用于避免协议之间冲突）
stagedUsedPorts() {
    printf '%s' "${NEW_STATE}" | jq -r '
      def udp: ["tuic","hysteria2"];
      def netof($id): if (udp | index($id)) != null then "udp" else "tcp" end;
      [.protocols | to_entries[] | select(.value.port != null) | "\(netof(.key)) \(.value.port)"][]' 2>/dev/null
}
# 端口是否已被本脚本当前生效的同类协议使用（重装时属于"自己人"，不算冲突）
portOwnedByUs() { # portOwnedByUs <port> <net>
    stateExists || return 1
    desiredFirewallPorts "${ATR_STATE}" | grep -qx "$2 $1"
}
# 推荐端口: 第一个 TCP Reality 协议优先 443，否则随机
suggestPort() { # suggestPort <net> <id>
    local net=$1 id=$2 reg used p
    reg=$(protoField "${id}" reality)
    used=$(stagedUsedPorts | awk '{print $2}' | tr '\n' ' ')
    if [[ "${net}" == "tcp" && "${reg}" == "true" ]]; then
        if [[ " ${used} " != *" 443 "* ]] && { ! portInUse 443 tcp || portOwnedByUs 443 tcp; }; then
            echo 443
            return
        fi
    fi
    p=$(randomFreePort "${used}")
    echo "${p:-$(randInt 10000 60000)}"
}

# askPort <变量> <协议id> <描述> <net> [默认]
askPort() {
    local __v=$1 id=$2 desc=$3 net=$4 def=${5:-} p
    [[ -z "${def}" ]] && def=$(suggestPort "${net}" "${id}")
    while true; do
        ask p "请输入${desc}端口[回车默认: ${def}]:" || return 1
        [[ -z "${p}" ]] && p=${def}
        if ! isPort "${p}"; then
            echoContent red " ---> 端口不合法"
            continue
        fi
        if stagedUsedPorts | grep -qx "${net} ${p}"; then
            echoContent red " ---> 端口 ${p}/${net} 已被本次配置的其他协议使用"
            continue
        fi
        if portInUse "${p}" "${net}" && ! portOwnedByUs "${p}" "${net}"; then
            echoContent yellow " ---> 端口 ${p}/${net} 正被其他程序占用:"
            lsof -i "${net}:${p}" 2>/dev/null | head -n 3
            confirm "仍要使用该端口吗？(服务会因端口冲突而启动失败，通常应换一个)" n || continue
        fi
        break
    done
    printf -v "${__v}" '%s' "${p}"
}

# ----------------------------- 单个协议的参数 ---------------------------------
# configureProtocol <core> <id>  —— 询问端口/参数并写入候选状态
configureProtocol() {
    local core=$1 id=$2 name port c up down cc
    name=$(protoName "${id}")
    echoContent yellow "\n===================== 配置 ${name} ====================="
    case "${id}" in
    vless_ws | vmess_ws | trojan)
        if [[ "${core}" == "xray" ]]; then
            echoContent green " ---> ${name} 通过 VLESS+Vision 前置的回落接入，无需单独端口"
            stagedEdit --arg id "${id}" --arg c "${core}" '.protocols[$id]={core:$c}'
            return $?
        fi
        askPort port "${id}" "${name} " tcp || return 1
        stagedEdit --arg id "${id}" --arg c "${core}" --argjson p "${port}" '.protocols[$id]={core:$c,port:$p}'
        ;;
    vless_vision_tls)
        askPort port "${id}" "${name} " tcp 443 || return 1
        stagedEdit --arg id "${id}" --arg c "${core}" --argjson p "${port}" '.protocols[$id]={core:$c,port:$p}'
        ;;
    tuic)
        askPort port "${id}" "${name} (UDP) " udp || return 1
        echoContent skyBlue "\n请选择拥塞控制算法"
        echoContent yellow "1.bbr(默认)  2.cubic  3.new_reno"
        ask c "请选择:" || return 1
        case "${c}" in 2) cc=cubic ;; 3) cc=new_reno ;; *) cc=bbr ;; esac
        stagedEdit --arg id "${id}" --arg c "${core}" --argjson p "${port}" --arg cc "${cc}" '.protocols[$id]={core:$c,port:$p,congestion:$cc}'
        ;;
    hysteria2)
        askPort port "${id}" "${name} (UDP) " udp || return 1
        echoContent yellow "请输入本地带宽峰值的下行速度（默认 100，单位 Mbps）"
        ask down "下行速度:" || return 1
        isInt "${down}" && ((down > 0)) || down=100
        echoContent yellow "请输入本地带宽峰值的上行速度（默认 50，单位 Mbps）"
        ask up "上行速度:" || return 1
        isInt "${up}" && ((up > 0)) || up=50
        # 保留已设置的端口跳跃
        local hop=""
        hop=$(S '.protocols.hysteria2.hop // ""')
        stagedEdit --arg id "${id}" --arg c "${core}" --argjson p "${port}" --argjson d "${down}" --argjson u "${up}" --arg hop "${hop}" \
            '.protocols[$id]={core:$c,port:$p,down_mbps:$d,up_mbps:$u,hop:$hop}'
        ;;
    *)
        local net=tcp
        askPort port "${id}" "${name} " "${net}" || return 1
        stagedEdit --arg id "${id}" --arg c "${core}" --argjson p "${port}" '.protocols[$id]={core:$c,port:$p}'
        ;;
    esac
}

# 伪装路径（WS / XHTTP / HTTPUpgrade 用）
ensurePath() {
    local cur seg
    cur=$(stagedGet '.path // ""')
    [[ -n "${cur}" ]] && return 0
    while true; do
        ask seg "请输入自定义路径[例: alone]，不要斜杠，[回车]随机路径:" || return 1
        [[ -z "${seg}" ]] && seg=$(randLower 4)
        isSafePathSeg "${seg}" && break
        echoContent red " ---> 路径只能包含字母和数字"
    done
    stagedEdit --arg p "${seg}" '.path=$p'
    echoContent yellow " ---> path: ${seg}"
}

# ----------------------------- 安装引擎 --------------------------------------
# installProtocols <core> <id...>
installProtocols() {
    local core=$1
    shift
    local -a ids=("$@")
    local id needTLS=0 needReality=0 needNginx=0 needPath=0 n=0 total i
    local reuse="n"

    # Xray 的 WS/VMess-WS/Trojan 只能挂在 Vision 前置的回落上
    if [[ "${core}" == "xray" ]]; then
        local need0=0
        for id in "${ids[@]}"; do [[ "${id}" == vless_ws || "${id}" == vmess_ws || "${id}" == trojan ]] && need0=1; done
        if ((need0)) && [[ " ${ids[*]} " != *" vless_vision_tls "* ]]; then
            echoContent yellow " ---> Xray 的 WS/VMess-WS/Trojan 依赖 VLESS+TLS_Vision 前置，已自动加入"
            ids=(vless_vision_tls "${ids[@]}")
        fi
    fi
    for id in "${ids[@]}"; do
        [[ "$(protoField "${id}" tls)" == "true" ]] && needTLS=1
        [[ "$(protoField "${id}" reality)" == "true" ]] && needReality=1
        case "${id}" in vless_ws | vmess_ws | vmess_httpupgrade | vless_reality_xhttp | vless_xhttp_tls) needPath=1 ;; esac
        [[ "${id}" == vmess_httpupgrade ]] && needNginx=1
        [[ "${core}" == "xray" ]] && case "${id}" in vless_vision_tls | vless_ws | vmess_ws | trojan) needNginx=1 ;; esac
    done
    total=4
    ((needTLS)) && total=$((total + 1))
    ((needReality)) && total=$((total + 1))
    ((needNginx)) && total=$((total + 1))
    total=$((total + 1)) # 自检/展示

    stateInit
    n=$((n + 1))
    if ((needTLS || needNginx)); then installTools full "${n}" "${total}"; else installTools min "${n}" "${total}"; fi || return 1
    n=$((n + 1))
    ensureCore "${core}" "${n}" "${total}" || {
        echoContent red " ---> 核心安装失败"
        return 1
    }

    # 已有安装: 追加/更新 还是 清空重装
    stagedBegin
    if [[ -n "$(installedProtocols)" ]]; then
        echoContent yellow "\n检测到已有安装，当前协议: $(installedProtocols | while read -r x; do printf '%s ' "$(protoName "${x}")"; done)"
        echoContent yellow "1.追加/更新所选协议（保留其他协议、用户、密钥）[默认]"
        echoContent yellow "2.清空现有全部配置后重新安装"
        local m
        ask m "请选择:" || return 1
        if [[ "${m}" == "2" ]]; then
            confirm "确认清空现有全部配置？(会先自动备份)" n || return 1
            NEW_STATE=$(stateDefault | jq .)
        fi
    fi

    # 协议若已在另一个核心上，需要确认迁移
    for id in "${ids[@]}"; do
        local oldcore
        oldcore=$(stagedGet --arg id "${id}" '.protocols[$id].core // ""')
        if [[ -n "${oldcore}" && "${oldcore}" != "${core}" ]]; then
            confirm "$(protoName "${id}") 目前运行在 ${oldcore} 上，是否迁移到 ${core}？" y || return 1
        fi
    done

    # --- TLS / 证书 ---
    if ((needTLS)); then
        n=$((n + 1))
        step "${n}" "${total}" "配置域名与 TLS 证书"
        local d
        d=$(stagedGet '.domain // ""')
        if [[ -n "${d}" ]] && tlsReusable "${d}"; then
            echoContent green " ---> 检测到域名 ${d} 的有效证书（剩余 $(tlsDaysLeft "${TLS_DIR}/${d}.crt") 天）"
            confirm "是否沿用？" y && reuse=y
        fi
        if [[ "${reuse}" != "y" ]]; then
            tlsSetupInteractive || {
                echoContent red " ---> 证书配置失败，已中止（未做任何改动）"
                stagedDiscard
                return 1
            }
            stagedSetTLS || return 1
        fi
    fi

    # --- Reality ---
    if ((needReality)); then
        n=$((n + 1))
        step "${n}" "${total}" "配置 Reality（目标域名 SNI 与密钥对）"
        local cur="" keep="n" rc
        # Reality 目标域名由所有 Reality 协议共用；只要有协议跑在 Xray 上，就按 Xray 的兼容性要求检测
        REALITY_CORE_HINT=$(realityCoreHint "${core}")
        cur=$(stagedGet 'if (.reality.sni // "") != "" then "\(.reality.sni):\(.reality.dest_port)" else "" end')
        if [[ -n "${cur}" ]]; then
            echoContent green " ---> 已有 Reality 配置: ${cur}（公钥 $(stagedGet '.reality.public_key')）"
            rc=0
            [[ "${REALITY_CORE_HINT}" == "xray" ]] && { realityXrayCompat "${cur%%:*}" "${cur##*:}" || rc=$?; }
            if ((rc == 1)); then
                echoContent yellow " ---> 现有目标域名不适合 Xray，需要重新选择（目标域名各协议共用，更换后已有 Reality 客户端需同步 SNI）"
            else
                confirm "是否沿用现有目标域名与密钥对？" y && keep=y
            fi
        fi
        if [[ "${keep}" != "y" ]]; then
            realityPickSNI "${cur}" || return 1
            stagedSetReality "${PICK_SNI}" "${PICK_PORT}" no || return 1
            echoContent green " ---> 已生成 Reality 密钥对与 Short ID（尚未写盘，校验通过后一并生效）"
        fi
    fi

    # --- 用户 ---
    n=$((n + 1))
    step "${n}" "${total}" "配置用户与协议端口"
    if [[ "$(stagedGet '.users|length')" == "0" ]]; then
        echoContent yellow "\n创建第一个用户:"
        promptNewUser || {
            stagedDiscard
            return 1
        }
    else
        echoContent green " ---> 保留现有 $(stagedGet '.users|length') 个用户"
    fi
    ((needPath)) && { ensurePath || return 1; }
    for id in "${ids[@]}"; do
        configureProtocol "${core}" "${id}" || {
            stagedDiscard
            return 1
        }
    done

    # --- 伪装站 (nginx 回落) ---
    if ((needNginx)); then
        n=$((n + 1))
        step "${n}" "${total}" "伪装站点"
        [[ -s "${WEB_ROOT}/index.html" ]] || installFakeSite
    fi

    # --- 应用 ---
    n=$((n + 1))
    step "${n}" "${total}" "应用配置（校验 → 备份 → 落盘 → 启动 → 验证，失败自动回滚）"
    if ! applyStaged "安装 ${ids[*]}"; then
        stagedDiscard
        echoContent red "\n ---> 安装失败，系统已保持/恢复到变更前状态。请根据上面的提示处理后重试。"
        return 1
    fi

    # --- 自检 + 展示 ---
    n=$((n + 1))
    step "${n}" "${total}" "自检并生成客户端配置"
    generateClientFiles
    selfCheckAll || echoContent yellow " ---> 自检有失败项，请查看上面的提示后再使用对应协议"
    showAccounts "" 0
    return 0
}

# ----------------------------- 菜单入口 --------------------------------------
# 1.安装 / 重新安装: 5 个预设组合（可多选，回车默认 1,2）
installPresetFlow() {
    selectCore || return 1
    echoContent skyBlue "\n========================== 预设组合 =========================="
    echoContent yellow "无域名只选 Reality 即可；Tuic/Hysteria2/Naive 需要域名与证书\n"
    protoMenu "${SELECTED_CORE}" preset
    [[ "${SELECTED_CORE}" == "xray" ]] && echoContent yellow "\n(Xray 只有 VLESS+Reality+Vision 属于预设；其余协议请使用 2.任意组合安装)"
    local sel
    ask sel "请选择[多选，例如:1,2，回车默认 1,2]:" || return 1
    [[ -z "${sel}" ]] && sel="1,2"
    [[ "${SELECTED_CORE}" == "xray" ]] && [[ "${sel}" == "1,2" ]] && sel="1"
    parseSelection "${sel}" || return 1
    installProtocols "${SELECTED_CORE}" "${SELECTED_IDS[@]}"
}

# 2.任意组合安装: 列出全部协议（前 5 个在最前）
installCustomFlow() {
    selectCore || return 1
    echoContent skyBlue "\n========================任意组合安装============================"
    echoContent yellow "无域名安装 Reality 只选 Reality 类协议即可\n"
    protoMenu "${SELECTED_CORE}"
    local sel
    ask sel "请选择[多选，例如:1,2,3]:" || return 1
    parseSelection "${sel}" || return 1
    installProtocols "${SELECTED_CORE}" "${SELECTED_IDS[@]}"
}

# 3.一键无域名 AnyTLS+Reality（sing-box）
installOneClickFlow() {
    echoContent skyBlue "\n=================== 一键无域名 AnyTLS + Reality ==================="
    echoContent yellow "流程: 安装 sing-box → 询问端口与 Reality SNI(带检测) → 生成密钥对 → 配置 AnyTLS 入站"
    echoContent yellow "      → systemd 服务 → 防火墙放行 → 自检启动\n"
    installProtocols sing-box anytls_reality
}

# 非交互入口: atr install-anytls-reality [--port N] [--sni host[:port]] [--user name]
cliInstallAnyTLSReality() {
    local port="" sni="" user="" a
    while [[ $# -gt 0 ]]; do
        a=$1
        case "${a}" in
        --port)
            port=$2
            shift
            ;;
        --sni)
            sni=$2
            shift
            ;;
        --user)
            user=$2
            shift
            ;;
        *)
            echoContent red " ---> 未知参数: ${a}"
            return 1
            ;;
        esac
        shift
    done
    [[ -n "${port}" ]] && ! isPort "${port}" && {
        echoContent red " ---> 端口不合法"
        return 1
    }
    [[ -n "${user}" ]] && ! isSafeName "${user}" && {
        echoContent red " ---> 用户名不合法"
        return 1
    }
    if [[ -n "${sni}" ]] && ! parseSniInput "${sni}"; then
        echoContent red " ---> SNI 不合法"
        return 1
    fi
    installTools min 1 5 || return 1
    ensureCore sing-box 2 5 || return 1
    stateInit
    stagedBegin
    [[ -z "${port}" ]] && port=$(suggestPort tcp anytls_reality)
    if [[ -z "${sni}" ]]; then
        SNI_HOST=www.microsoft.com
        SNI_PORT=443
    fi
    step 3 5 "检测 Reality 目标 ${SNI_HOST}:${SNI_PORT}"
    checkRealityTarget "${SNI_HOST}" "${SNI_PORT}" || {
        echoContent red " ---> 目标未通过检测，请换一个 --sni"
        return 1
    }
    stagedSetReality "${SNI_HOST}" "${SNI_PORT}" no || return 1
    if [[ "$(stagedGet '.users|length')" == "0" ]]; then
        stagedUserAdd "${user:-$(randHex 6)}" || return 1
    fi
    stagedEdit --argjson p "${port}" '.protocols.anytls_reality={core:"sing-box",port:$p}' || return 1
    step 4 5 "应用配置"
    applyStaged "安装 AnyTLS+Reality" || {
        stagedDiscard
        return 1
    }
    step 5 5 "自检并生成客户端配置"
    generateClientFiles
    selfCheckAll
    showAccounts "" 0
}

# =============================================================================
#  14  管理菜单: Reality / Hysteria2 / Tuic / 端口跳跃 / alpn / 添加新端口 / CDN /
#      伪装站 / 证书 / 订阅 / core 管理
# =============================================================================

requireInstalled() {
    stateExists && [[ -n "$(installedProtocols)" ]] || {
        echoContent red " ---> 未安装，请先使用 1.安装 或 2.任意组合安装"
        return 1
    }
}

# 已安装的 Reality 类协议 id 列表
installedRealityProtocols() {
    local id
    while read -r id; do
        [[ -z "${id}" ]] && continue
        [[ "$(protoField "${id}" reality)" == "true" ]] && echo "${id}"
    done < <(installedProtocols)
}

# ----------------------------- 5. REALITY 管理 --------------------------------
realityShowParams() {
    echoContent skyBlue "\n---------------- 当前 Reality 参数 ----------------"
    echoContent yellow "目标域名(SNI): \c"
    printRaw green "$(S '.reality.sni'):$(S '.reality.dest_port')"
    echoContent yellow "公钥(客户端用): \c"
    printRaw green "$(S '.reality.public_key')"
    echoContent yellow "Short ID      : \c"
    printRaw green "$(S '.reality.short_id')"
    local id
    while read -r id; do
        [[ -z "${id}" ]] && continue
        echoContent yellow "$(protoName "${id}") 端口: \c"
        printRaw green "$(protoPort "${id}")  (核心: $(S --arg i "${id}" '.protocols[$i].core'))"
    done < <(installedRealityProtocols)
}

manageReality() {
    requireInstalled || return 1
    [[ -n "$(installedRealityProtocols)" ]] || {
        echoContent red " ---> 请先安装 Reality 类协议（VLESS+Reality+Vision / AnyTLS+Reality 等）"
        return 1
    }
    echoContent skyBlue "\n功能 1/1 : REALITY 管理"
    echoContent red "\n=============================================================="
    echoContent yellow "1.查看当前 Reality 参数"
    echoContent yellow "2.修改目标域名(SNI)   [保留密钥对，客户端需同步 SNI]"
    echoContent yellow "3.修改协议端口        [客户端需同步端口]"
    echoContent yellow "4.重置密钥对与 Short ID [所有 Reality 客户端全部失效]"
    echoContent yellow "5.自检(回环握手测试)"
    echoContent red "=============================================================="
    local c id cur port
    ask c "请选择:" || return 1
    case "${c}" in
    1) realityShowParams ;;
    2)
        cur="$(S '.reality.sni'):$(S '.reality.dest_port')"
        REALITY_CORE_HINT=$(realityCoreHint)
        realityPickSNI "${cur}" || return 1
        stagedBegin
        stagedSetReality "${PICK_SNI}" "${PICK_PORT}" no || return 1
        if applyStaged "修改 Reality SNI"; then
            postChangeShow "" "Reality 目标域名已改为 ${PICK_SNI}:${PICK_PORT}"
            selfCheckAll
        else stagedDiscard; fi
        ;;
    3)
        echoContent yellow "请选择要修改端口的协议:"
        local -a ids=()
        local i=0
        while read -r id; do
            [[ -z "${id}" ]] && continue
            ids+=("${id}")
            i=$((i + 1))
            echoContent yellow "${i}.$(protoName "${id}") (当前 $(protoPort "${id}"))"
        done < <(installedRealityProtocols)
        ask c "请选择:" || return 1
        if ! isInt "${c}" || ((c < 1 || c > i)); then
            echoContent red " ---> 选择错误"
            return 1
        fi
        id=${ids[$((c - 1))]}
        stagedBegin
        askPort port "${id}" "$(protoName "${id}") 新" tcp "$(protoPort "${id}")" || return 1
        stagedEdit --arg id "${id}" --argjson p "${port}" '.protocols[$id].port=$p' || return 1
        if applyStaged "修改 ${id} 端口"; then
            postChangeShow "" "$(protoName "${id}") 端口已改为 ${port}"
        else stagedDiscard; fi
        ;;
    4)
        confirm "重置后所有 Reality 客户端都需要更新公钥/Short ID，确认？(先备份，失败自动回滚)" n || return 0
        stagedBegin
        stagedSetReality "$(S '.reality.sni')" "$(S '.reality.dest_port')" yes || return 1
        if applyStaged "重置 Reality 密钥对"; then
            postChangeShow "" "Reality 密钥对已重置"
            selfCheckAll
        else stagedDiscard; fi
        ;;
    5) selfCheckAll ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- 端口跳跃 (Hysteria2 / Tuic) --------------------
HOP_UNIT="atr-hop"

hopSupported() { command -v iptables >/dev/null 2>&1 || { command -v firewall-cmd >/dev/null 2>&1 && [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]; }; }

# 删除本脚本创建的全部跳跃规则
hopRulesRemoveAll() {
    local ipt r
    for ipt in iptables ip6tables; do
        command -v "${ipt}" >/dev/null 2>&1 || continue
        "${ipt}" -t nat -S PREROUTING 2>/dev/null | grep -- 'atr_hop_' | sed 's/^-A /-D /' | while read -r r; do
            # shellcheck disable=SC2086
            "${ipt}" -t nat ${r} 2>/dev/null
        done
    done
    if [[ -s "${ATR_HOME}/hop_firewalld.list" ]] && command -v firewall-cmd >/dev/null 2>&1; then
        while read -r r; do
            firewall-cmd --permanent --remove-forward-port="${r}" >/dev/null 2>&1
        done <"${ATR_HOME}/hop_firewalld.list"
        firewall-cmd --reload >/dev/null 2>&1
        : >"${ATR_HOME}/hop_firewalld.list"
    fi
}

# hopRuleAdd <协议id> <a-b> <目标端口>
hopRuleAdd() {
    local id=$1 range=${2/-/:} port=$3 ipt spec
    if command -v firewall-cmd >/dev/null 2>&1 && [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]; then
        spec="port=${2}:proto=udp:toport=${port}"
        firewall-cmd --permanent --add-masquerade >/dev/null 2>&1
        firewall-cmd --permanent --add-forward-port="${spec}" >/dev/null 2>&1 && echo "${spec}" >>"${ATR_HOME}/hop_firewalld.list"
        firewall-cmd --reload >/dev/null 2>&1
        return 0
    fi
    for ipt in iptables ip6tables; do
        command -v "${ipt}" >/dev/null 2>&1 || continue
        "${ipt}" -t nat -A PREROUTING -p udp --dport "${range}" -m comment --comment "atr_hop_${id}" -j REDIRECT --to-ports "${port}" 2>/dev/null
    done
}

# 以 state 为准重建全部跳跃规则（幂等），并维护开机恢复单元
reconcileHopRules() { # reconcileHopRules <state.json>
    local st=$1 id range port any=0
    hopRulesRemoveAll
    while read -r id range port; do
        [[ -z "${range}" ]] && continue
        hopRuleAdd "${id}" "${range}" "${port}"
        any=1
    done < <(jq -r '.protocols|to_entries[]|select((.value.hop // "") != "")|"\(.key) \(.value.hop) \(.value.port)"' "${st}" 2>/dev/null)
    if ((any)); then
        _writeUnitFile "${HOP_UNIT}" <<EOF
[Unit]
Description=Re-apply UDP port-hopping rules (${ATR_PROJECT_NAME})
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ATR_SCRIPT_PATH} apply-hop

[Install]
WantedBy=multi-user.target
EOF
        serviceEnable "${HOP_UNIT}"
    elif [[ -f "${ATR_SYSTEMD_DIR}/${HOP_UNIT}.service" ]]; then
        serviceDisable "${HOP_UNIT}"
        rm -f "${ATR_SYSTEMD_DIR}/${HOP_UNIT}.service"
        systemctl daemon-reload >/dev/null 2>&1
    fi
    return 0
}

portHoppingMenu() { # portHoppingMenu <hysteria2|tuic>
    local id=$1 c range a b port other
    protoInstalled "${id}" || {
        echoContent red " ---> 请先安装 $(protoName "${id}")"
        return 1
    }
    hopSupported || {
        echoContent red " ---> 未检测到 iptables / firewalld，无法使用端口跳跃"
        return 1
    }
    port=$(protoPort "${id}")
    echoContent skyBlue "\n进度 1/1 : 端口跳跃 ($(protoName "${id}"))"
    echoContent red "\n=============================================================="
    echoContent yellow "1.添加端口跳跃"
    echoContent yellow "2.删除端口跳跃"
    echoContent yellow "3.查看端口跳跃"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        echoContent yellow "# 仅支持 Hysteria2、Tuic；范围必须在 30000-40000 内，建议 1000 个端口左右"
        ask range "请输入端口跳跃的范围，例如[30000-31000]:" || return 1
        a=${range%-*}
        b=${range#*-}
        if [[ "${range}" != *-* ]] || ! isPort "${a}" || ! isPort "${b}" || ((a < 30000 || b > 40000 || a >= b)); then
            echoContent red " ---> 范围不合法（需 30000-40000 内且起点小于终点）"
            return 1
        fi
        # 范围内不能包含其他协议的 UDP 端口
        while read -r other; do
            [[ -z "${other}" ]] && continue
            ((other >= a && other <= b)) && {
                echoContent red " ---> 范围内包含已被使用的 UDP 端口 ${other}"
                return 1
            }
        done < <(desiredFirewallPorts "${ATR_STATE}" | awk '$1=="udp" && $2 !~ /:/ {print $2}')
        stagedBegin
        stagedEdit --arg id "${id}" --arg r "${a}-${b}" '.protocols[$id].hop=$r' || return 1
        if applyStaged "端口跳跃 ${a}-${b}"; then
            postChangeShow "" "已开启端口跳跃 ${a}-${b} -> ${port}"
        else stagedDiscard; fi
        ;;
    2)
        [[ -n "$(S --arg i "${id}" '.protocols[$i].hop // ""')" ]] || {
            echoContent yellow " ---> 未设置端口跳跃"
            return 0
        }
        stagedBegin
        stagedEdit --arg id "${id}" '.protocols[$id].hop=""' || return 1
        if applyStaged "删除端口跳跃"; then
            postChangeShow "" "端口跳跃已删除"
        else stagedDiscard; fi
        ;;
    3)
        range=$(S --arg i "${id}" '.protocols[$i].hop // ""')
        if [[ -n "${range}" ]]; then echoContent green " ---> 当前端口跳跃范围: ${range} -> ${port}"; else echoContent yellow " ---> 未设置端口跳跃"; fi
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- 4/6. Hysteria2 / Tuic 管理 ---------------------
manageUDPProtocol() { # manageUDPProtocol <hysteria2|tuic>
    local id=$1 c name
    name=$(protoName "${id}")
    echoContent skyBlue "\n进度  1/1 : ${name} 管理"
    echoContent red "\n=============================================================="
    if protoInstalled "${id}"; then
        echoContent yellow "依赖 sing-box 内核\n"
        echoContent yellow "1.重新配置(端口/参数)"
        echoContent yellow "2.卸载"
        echoContent yellow "3.端口跳跃管理"
    else
        echoContent yellow "依赖 sing-box 内核与域名证书\n"
        echoContent yellow "1.安装"
    fi
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    if ! protoInstalled "${id}"; then
        [[ "${c}" == "1" ]] && installProtocols sing-box "${id}"
        return
    fi
    case "${c}" in
    1)
        stagedBegin
        configureProtocol sing-box "${id}" || {
            stagedDiscard
            return 1
        }
        if applyStaged "重新配置 ${name}"; then postChangeShow "" "${name} 参数已修改"; else stagedDiscard; fi
        ;;
    2)
        confirm "确认卸载 ${name} ？" n || return 0
        stagedBegin
        stagedEdit --arg id "${id}" 'del(.protocols[$id])' || return 1
        if applyStaged "卸载 ${name}"; then
            generateClientFiles
            echoContent green " ---> ${name} 已卸载"
        else stagedDiscard; fi
        ;;
    3) portHoppingMenu "${id}" ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}
manageHysteria() { manageUDPProtocol hysteria2; }
manageTuic() { manageUDPProtocol tuic; }

# ----------------------------- 14. 切换 alpn ----------------------------------
manageAlpn() {
    protoInstalled vless_vision_tls && [[ "$(S '.protocols.vless_vision_tls.core')" == "xray" ]] || {
        echoContent red " ---> 此功能仅用于 Xray-core 的 VLESS+TLS_Vision 前置，请先安装"
        return 1
    }
    local cur c
    cur=$(S '.alpn // "h2"')
    echoContent skyBlue "\n功能 1/1 : 切换 alpn"
    echoContent red "\n=============================================================="
    echoContent green "当前 alpn 首位为: ${cur}"
    echoContent yellow "  1.http/1.1 首位时，Trojan 可用，gRPC 部分客户端可用【客户端支持手动选择 alpn 的可用】"
    echoContent yellow "  2.h2 首位时，gRPC 可用，Trojan 部分客户端可用【客户端支持手动选择 alpn 的可用】"
    echoContent yellow "  3.客户端不支持手动更换 alpn 时，可用此功能调整服务端顺序来使用相应的协议"
    echoContent red "=============================================================="
    if [[ "${cur}" == "h2" ]]; then echoContent yellow "1.切换 http/1.1 首位"; else echoContent yellow "1.切换 h2 首位"; fi
    ask c "请选择:" || return 1
    [[ "${c}" == "1" ]] || {
        echoContent red " ---> 选择错误"
        return 1
    }
    stagedBegin
    if [[ "${cur}" == "h2" ]]; then stagedEdit '.alpn="http/1.1"'; else stagedEdit '.alpn="h2"'; fi
    if applyStaged "切换 alpn"; then echoContent green " ---> alpn 已切换"; else stagedDiscard; fi
}

# ----------------------------- 12. 添加新端口 (Xray) --------------------------
manageExtraPorts() {
    protoInstalled vless_vision_tls && [[ "$(S '.protocols.vless_vision_tls.core')" == "xray" ]] || {
        echoContent red " ---> 此功能仅支持 Xray-core 的 VLESS+TLS_Vision 前置，请先安装"
        return 1
    }
    local c ports p
    echoContent skyBlue "\n功能 1/1 : 添加新端口"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项"
    echoContent yellow "额外端口用 dokodemo-door 转发到默认端口 $(protoPort vless_vision_tls)，不影响默认端口"
    echoContent yellow "可用于 CDN 支持的备用端口(如 2053,2083,2087,2096,8443)；录入示例: 2053,2083,2087\n"
    echoContent yellow "1.查看已添加端口"
    echoContent yellow "2.添加端口"
    echoContent yellow "3.删除端口"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1) echoContent green " ---> 已添加: $(S '.extra_ports|map(tostring)|join(", ")')" ;;
    2)
        ask ports "请输入端口号(逗号分隔):" || return 1
        stagedBegin
        local IFS=','
        for p in ${ports}; do
            p=$(trim "${p}")
            isPort "${p}" || {
                echoContent red " ---> 端口不合法: ${p}"
                stagedDiscard
                return 1
            }
            stagedEdit --argjson p "${p}" '.extra_ports = ((.extra_ports + [$p]) | unique)' || return 1
        done
        unset IFS
        if applyStaged "添加新端口"; then
            echoContent green " ---> 添加完毕（客户端把端口改为新端口即可）"
        else stagedDiscard; fi
        ;;
    3)
        ask p "请输入要删除的端口:" || return 1
        isPort "${p}" || {
            echoContent red " ---> 端口不合法"
            return 1
        }
        stagedBegin
        stagedEdit --argjson p "${p}" '.extra_ports -= [$p]' || return 1
        if applyStaged "删除端口"; then echoContent green " ---> 已删除"; else stagedDiscard; fi
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- 10. CDN 节点管理 -------------------------------
manageCDN() {
    requireInstalled || return 1
    local any=0 c val id
    while read -r id; do
        [[ -z "${id}" ]] && continue
        [[ "$(protoField "${id}" cdn)" == "true" ]] && any=$((any + 1))
    done < <(installedProtocols)
    if ((any == 0)); then
        echoContent yellow "\n教程: https://www.v2ray-agent.com/archives/cloudflarezi-xuan-ip\n"
        echoContent red " ---> 未检测到可用的协议，仅支持 WS / HTTPUpgrade / XHTTP+TLS 相关协议"
        return 1
    fi
    echoContent skyBlue "\n进度 1/1 : CDN 节点管理"
    echoContent red "=============================================================="
    echoContent yellow "# 注意事项: 教程 https://www.v2ray-agent.com/archives/cloudflarezi-xuan-ip ，不了解 Cloudflare 优选请不要使用"
    echoContent yellow "当前: $(S '.cdn // "(未设置)"')\n"
    echoContent yellow "1.CNAME www.digitalocean.com"
    echoContent yellow "2.CNAME who.int"
    echoContent yellow "3.CNAME blog.hostmonit.com"
    echoContent yellow "4.CNAME www.visa.com.hk"
    echoContent yellow "5.手动输入[可输入多个，例如: 1.1.1.1,1.1.2.2,cloudflare.com 逗号分隔]"
    echoContent yellow "6.移除 CDN 节点"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1) val=www.digitalocean.com ;;
    2) val=who.int ;;
    3) val=blog.hostmonit.com ;;
    4) val=www.visa.com.hk ;;
    5)
        ask val "请输入想要自定义的 CDN IP 或域名:" || return 1
        val=${val// /}
        local t ok=1
        local IFS=','
        for t in ${val}; do isHostOrIP "${t}" || ok=0; done
        unset IFS
        ((ok)) && [[ -n "${val}" ]] || {
            echoContent red " ---> 含不合法的域名/IP"
            return 1
        }
        ;;
    6) val="" ;;
    *)
        echoContent red " ---> 选择错误"
        return 1
        ;;
    esac
    stagedBegin
    stagedEdit --arg v "${val}" '.cdn=$v' || return 1
    if applyStaged "CDN 节点"; then
        postChangeShow "" "CDN 节点已${val:+设置为 ${val}}${val:-移除}"
    else stagedDiscard; fi
}

# ----------------------------- 8. 伪装站管理 ----------------------------------
manageFakeSite() {
    stateNeedsNginxFallback "${ATR_STATE}" || {
        echoContent red " ---> 此功能用于 Xray-core 的 VLESS+TLS_Vision 回落伪装站，请先安装"
        return 1
    }
    local c r
    echoContent skyBlue "\n进度 1/1 : 更换伪装站点"
    echoContent red "=============================================================="
    echoContent yellow "# 如需自定义，请手动复制模版文件到 ${WEB_ROOT}/\n"
    echoContent yellow "1.新手引导"
    echoContent yellow "2.游戏网站"
    echoContent yellow "3.个人博客01"
    echoContent yellow "4.企业站"
    echoContent yellow "5.解锁加密的音乐文件模版[https://github.com/ix64/unlock-music]"
    echoContent yellow "6.mikutap[https://github.com/HFIProgramming/mikutap]"
    echoContent yellow "7.企业站02"
    echoContent yellow "8.个人博客02"
    echoContent yellow "9.404自动跳转baidu"
    echoContent yellow "10.302重定向网站"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    if [[ "${c}" =~ ^[1-9]$ ]]; then
        installFakeSite "${c}"
        reloadAll >/dev/null 2>&1
    elif [[ "${c}" == "10" ]]; then
        echoContent red "\n=============================================================="
        echoContent yellow "重定向的优先级更高，配置 302 之后更换伪装站点在根路径下将不起作用；删除 302 后恢复"
        echoContent yellow "1.添加"
        echoContent yellow "2.删除"
        ask c "请选择:" || return 1
        if [[ "${c}" == "1" ]]; then
            ask r "请输入要重定向的地址，例如 https://www.baidu.com:" || return 1
            if ! [[ "${r}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~:/?#@%=\&+-]*)?$ ]]; then
                echoContent red " ---> 地址不合法（需以 http(s):// 开头，不能含空格/引号等特殊字符）"
                return 1
            fi
            stagedBegin
            stagedEdit --arg r "${r}" '.nginx.redirect302=$r' || return 1
            if applyStaged "302 重定向"; then echoContent green " ---> 302 重定向已设置"; else stagedDiscard; fi
        elif [[ "${c}" == "2" ]]; then
            stagedBegin
            stagedEdit '.nginx.redirect302=""' || return 1
            if applyStaged "移除 302"; then echoContent green " ---> 已移除 302 重定向"; else stagedDiscard; fi
        fi
    else
        echoContent red " ---> 选择错误"
    fi
}

# ----------------------------- 9. 证书管理 ------------------------------------
manageCertificate() {
    stateExists || {
        echoContent red " ---> 未安装"
        return 1
    }
    local c d
    echoContent skyBlue "\n进度  1/1 : 证书管理"
    echoContent red "\n=============================================================="
    tlsStatusLine
    echoContent red "=============================================================="
    echoContent yellow "1.立即续签证书"
    echoContent yellow "2.重新申请证书(更换域名或申请方式)"
    echoContent yellow "3.导入已有证书"
    echoContent yellow "4.查看 acme 日志"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1) renewTLSNow ;;
    2)
        tlsSetupInteractive "$(S '.domain // ""')" || return 1
        stagedBegin
        stagedSetTLS || return 1
        if applyStaged "更新证书"; then echoContent green " ---> 证书已更新并生效"; else stagedDiscard; fi
        ;;
    3)
        local crt key
        d=$(S '.domain // ""')
        [[ -n "${d}" ]] || ask d "请输入域名:" || return 1
        ask crt "证书文件路径(PEM):" || return 1
        ask key "私钥文件路径(PEM，无口令):" || return 1
        tlsImportCustom "${d}" "${crt}" "${key}" || return 1
        stagedBegin
        TLS_DOMAIN=${d}
        TLS_MODE=custom
        TLS_CA=$(S '.tls.ca // "letsencrypt"')
        TLS_DNS_API=""
        TLS_WILDCARD=false
        stagedSetTLS
        if applyStaged "导入证书"; then echoContent green " ---> 已导入并生效"; else stagedDiscard; fi
        ;;
    4) tail -n 100 "${ACME_LOG}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- 订阅 ------------------------------------------
enableSubscription() {
    local port ssl=false d salt
    ensureNginx || return 1
    d=$(S '.domain // ""')
    if [[ -n "${d}" ]] && tlsReusable "${d}"; then
        ssl=true
        echoContent green " ---> 使用域名 ${d} 的证书提供 HTTPS 订阅"
    else
        echoContent yellow " ---> 没有可用的域名证书，将使用 HTTP 明文订阅，可能被运营商拦截，请注意风险"
        confirm "是否继续使用 HTTP 订阅？" n || return 1
    fi
    stagedBegin
    askPort port subscribe "订阅" tcp "$(randomFreePort "$(stagedUsedPorts | awk '{print $2}' | tr '\n' ' ')")" || return 1
    salt=$(randLower 12)
    stagedEdit --argjson p "${port}" --argjson s "${ssl}" --arg salt "${salt}" '.nginx.subscribe={enabled:true,port:$p,ssl:$s,salt:$salt}' || return 1
    [[ -s "${WEB_ROOT}/index.html" ]] || installFakeSite
    if applyStaged "启用订阅服务"; then
        generateClientFiles
        showSubscriptionLinks
    else stagedDiscard; return 1; fi
}

subscriptionMenu() {
    requireInstalled || return 1
    if [[ "$(S '.nginx.subscribe.enabled')" != "true" ]]; then
        echoContent yellow "\n订阅服务尚未启用（需要 nginx，用于一条链接导入全部节点）"
        confirm "是否现在启用？" y && enableSubscription
        return
    fi
    local c
    echoContent skyBlue "\n---------- 订阅管理 ----------"
    echoContent yellow "1.查看订阅链接"
    echoContent yellow "2.重置订阅令牌(salt)   [旧订阅链接立即失效]"
    echoContent yellow "3.关闭订阅服务"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        generateClientFiles
        showSubscriptionLinks
        ;;
    2)
        stagedBegin
        stagedEdit --arg s "$(randLower 12)" '.nginx.subscribe.salt=$s' || return 1
        if applyStaged "重置订阅令牌"; then
            generateClientFiles
            showSubscriptionLinks
        else stagedDiscard; fi
        ;;
    3)
        stagedBegin
        stagedEdit '.nginx.subscribe.enabled=false' || return 1
        if applyStaged "关闭订阅服务"; then echoContent green " ---> 订阅服务已关闭"; else stagedDiscard; fi
        ;;
    esac
}

# 3.管理其他订阅（把其他机器的订阅合并进本机订阅，两台机器的用户名与 salt 需相同）
otherSubscriptionMenu() {
    local c line n host port alias http
    mkdir -p "$(dirname "${SUB_REMOTE_FILE}")"
    echoContent skyBlue "\n===================== 添加其他机器订阅 ====================="
    echoContent yellow "1.添加"
    echoContent yellow "2.移除"
    echoContent yellow "3.查看"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        echoContent skyBlue "录入示例：www.example.com:443:vps1  (域名:端口:机器别名)"
        ask line "请输入域名:端口:机器别名:" || return 1
        host=$(cut -d: -f1 <<<"${line}")
        port=$(cut -d: -f2 <<<"${line}")
        alias=$(cut -d: -f3 <<<"${line}")
        if ! { isDomainName "${host}" || isIPv4 "${host}"; } || ! isPort "${port}" || ! isSafeName "${alias}"; then
            echoContent red " ---> 格式不合法（域名或IPv4:端口:别名，别名只能含字母数字 . _ @ -）"
            return 1
        fi
        http=""
        confirm "是否是 HTTP 订阅？" n && http=":http"
        echo "${host}:${port}:${alias}${http}" >>"${SUB_REMOTE_FILE}"
        generateClientFiles
        echoContent green " ---> 已添加并重新生成订阅"
        ;;
    2)
        [[ -s "${SUB_REMOTE_FILE}" ]] || {
            echoContent yellow " ---> 没有其他订阅"
            return 0
        }
        grep -v '^$' "${SUB_REMOTE_FILE}" | awk '{print NR":"$0}'
        ask n "请选择要删除的编号[仅支持单个删除]:" || return 1
        isInt "${n}" || {
            echoContent red " ---> 选择错误"
            return 1
        }
        sed -i "${n}d" "${SUB_REMOTE_FILE}"
        generateClientFiles
        echoContent green " ---> 已删除并重新生成订阅"
        ;;
    3) [[ -s "${SUB_REMOTE_FILE}" ]] && grep -v '^$' "${SUB_REMOTE_FILE}" | awk '{print NR":"$0}' || echoContent yellow " ---> 没有其他订阅" ;;
    esac
}

# ----------------------------- 16. core 管理 ----------------------------------
installCronUpdateGeo() {
    command -v crontab >/dev/null 2>&1 || {
        echoContent red " ---> 未安装 cron"
        return 1
    }
    if crontab -l 2>/dev/null | grep -q "${ATR_SCRIPT_PATH} update-geo"; then
        echoContent yellow " ---> 已添加自动更新定时任务，请不要重复添加"
        return 0
    fi
    (
        crontab -l 2>/dev/null
        echo "35 1 * * * /bin/bash ${ATR_SCRIPT_PATH} update-geo >> ${ATR_HOME}/cron_geo.log 2>&1"
    ) | crontab -
    echoContent green " ---> 已添加每天凌晨更新 geo 文件的定时任务"
}

# 更新 geo 数据并重载（cron: atr update-geo）
updateGeoAll() {
    local changed=0
    if coreInstalled xray; then updateXrayGeo && changed=1; fi
    if coreInstalled sing-box; then updateSingBoxRuleSets && changed=1; fi
    ((changed)) && reloadAll >/dev/null 2>&1
    return 0
}

toggleDebugLog() {
    local cur
    cur=$(S '.log.debug')
    stagedBegin
    if [[ "${cur}" == "true" ]]; then stagedEdit '.log.debug=false'; else stagedEdit '.log.debug=true'; fi
    if applyStaged "切换调试日志"; then
        [[ "${cur}" == "true" ]] && echoContent green " ---> 已关闭调试日志" || echoContent yellow " ---> 已开启调试日志（排查完请关闭，日志量较大）"
    else stagedDiscard; fi
}

# 查看日志: viewLog <sing-box|xray|nginx|acme>
viewLog() {
    case "$1" in
    sing-box) followLog journalctl -u "${SB_UNIT}" -n 80 -f --no-pager ;;
    xray)
        followLog journalctl -u "${XRAY_UNIT}" -n 80 -f --no-pager
        ;;
    nginx) followLog journalctl -u "${NGX_UNIT}" -n 80 -f --no-pager ;;
    acme) tail -n 100 "${ACME_LOG}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' ;;
    esac
}

coreManageMenu() {
    local avail=() core c
    coreInstalled sing-box && avail+=("sing-box")
    coreInstalled xray && avail+=("xray")
    ((${#avail[@]} > 0)) || {
        echoContent red "\n ---> 没有检测到已安装的核心，请先安装"
        return 1
    }
    if ((${#avail[@]} == 1)); then
        core=${avail[0]}
    else
        echoContent skyBlue "\n功能 1/1 : 请选择核心"
        echoContent yellow "1.sing-box"
        echoContent yellow "2.Xray-core"
        ask c "请输入:" || return 1
        case "${c}" in 1) core=sing-box ;; 2) core=xray ;; *)
            echoContent red " ---> 选择错误"
            return 1
            ;;
        esac
        coreInstalled "${core}" || {
            echoContent red " ---> ${core} 未安装"
            return 1
        }
    fi
    local unit
    unit=$(coreUnit "${core}")
    echoContent skyBlue "\n进度 1/1 : $(coreLabel "${core}") 版本管理（当前 $(coreVersion "${core}")，仅稳定版）"
    echoContent red "\n=============================================================="
    echoContent yellow "1.升级 $(coreLabel "${core}")"
    echoContent yellow "2.回退 $(coreLabel "${core}")"
    echoContent yellow "3.关闭 $(coreLabel "${core}")"
    echoContent yellow "4.打开 $(coreLabel "${core}")"
    echoContent yellow "5.重启 $(coreLabel "${core}")"
    if [[ "${core}" == "xray" ]]; then
        echoContent yellow "6.更新 geosite、geoip"
        echoContent yellow "7.设置自动更新 geo 文件[每天凌晨更新]"
        echoContent yellow "8.启用/关闭调试日志   [当前: $(S 'if .log.debug then "开" else "关" end')]"
        echoContent yellow "9.查看日志"
    else
        echoContent yellow "6.更新 sing-box 规则集(geosite/geoip)"
        echoContent yellow "7.设置自动更新规则集[每天凌晨更新]"
        echoContent yellow "8.启用/关闭调试日志   [当前: $(S 'if .log.debug then "开" else "关" end')]"
        echoContent yellow "9.查看日志"
    fi
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1) upgradeCore "${core}" ;;
    2) rollbackCore "${core}" ;;
    3)
        serviceStop "${unit}"
        echoContent green " ---> 已关闭"
        ;;
    4)
        systemctl start "${unit}" >/dev/null 2>&1
        waitServiceActive "${unit}" 8 && echoContent green " ---> 已启动" || {
            echoContent red " ---> 启动失败，最近日志:"
            serviceLogTail "${unit}" 12
        }
        ;;
    5)
        systemctl restart "${unit}" >/dev/null 2>&1
        waitServiceActive "${unit}" 8 && echoContent green " ---> 已重启" || {
            echoContent red " ---> 重启失败，最近日志:"
            serviceLogTail "${unit}" 12
        }
        ;;
    6)
        if [[ "${core}" == "xray" ]]; then updateXrayGeo; else updateSingBoxRuleSets; fi
        reloadAll >/dev/null 2>&1
        echoContent green " ---> 更新完毕"
        ;;
    7) installCronUpdateGeo ;;
    8) toggleDebugLog ;;
    9) viewLog "${core}" ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# =============================================================================
#  15  分流工具 / BT 下载管理 / 域名黑名单
#      WARP(IPv4/IPv6) · IPv6 · Socks5(出站/入站) · DNS · SNI 反向代理 · 黑白名单
#      所有规则都是 state.routing 里的 token，由 jq 渲染进 sing-box 与 Xray 两个核心。
# =============================================================================

# ----------------------------- token 解析 ------------------------------------
# geosite 名称是否存在（本地规则集 或 sing-geosite 仓库探测）
geositeExists() { # geositeExists <名称>
    local n=$1
    [[ "${n}" =~ ^[a-z0-9@!-]+$ ]] || return 1
    [[ -s "${SB_RULESET_DIR}/geosite-${n}.srs" ]] && return 0
    curl -fsI -m 8 "${SB_GEOSITE_URL}/geosite-${n}.srs" >/dev/null 2>&1
}
geoipExists() {
    [[ "$1" =~ ^[a-z0-9@!-]+$ ]] || return 1
    [[ -s "${SB_RULESET_DIR}/geoip-$1.srs" ]] && return 0
    curl -fsI -m 8 "${SB_GEOIP_URL}/geoip-$1.srs" >/dev/null 2>&1
}
isCIDR() { # IPv4/IPv6 地址或 CIDR
    local a=${1%%/*} m=""
    [[ "$1" == */* ]] && m=${1##*/}
    if isIPv4 "${a}"; then
        [[ -z "${m}" ]] || { isInt "${m}" && ((m <= 32)); }
    elif isIPv6 "${a}"; then
        [[ -z "${m}" ]] || { isInt "${m}" && ((m <= 128)); }
    else
        return 1
    fi
}

# classifyDomainToken <输入>  -> 打印标准 token（domain:/geosite:），无法识别返回 1
classifyDomainToken() {
    local t
    t=$(trim "$1")
    t=${t,,}
    [[ -n "${t}" ]] || return 1
    case "${t}" in
    domain:*)
        isDomainName "${t#domain:}" && echo "${t}"
        return
        ;;
    geosite:*)
        geositeExists "${t#geosite:}" && echo "${t}"
        return
        ;;
    esac
    if isDomainName "${t}"; then
        echo "domain:${t}"
        return 0
    fi
    if geositeExists "${t}"; then
        echo "geosite:${t}"
        return 0
    fi
    return 1
}

# parseDomainList <逗号分隔>  -> 每行一个 token；无法识别的在 stderr 提示并跳过
parseDomainList() {
    local item tok count=0
    local IFS=','
    for item in $1; do
        item=$(trim "${item}")
        [[ -z "${item}" ]] && continue
        if tok=$(classifyDomainToken "${item}"); then
            echo "${tok}"
            count=$((count + 1))
        else
            echoContent yellow " ---> 已跳过无法识别的规则: ${item}（需是域名，或 geosite 预定义列表名，如 netflix、openai、cn）" >&2
        fi
    done
    ((count > 0))
}

# parseIPList <逗号分隔>  -> ip:/geoip: token
parseIPList() {
    local item count=0
    local IFS=','
    for item in $1; do
        item=$(trim "${item}")
        item=${item,,}
        [[ -z "${item}" ]] && continue
        if [[ "${item}" == "cn" ]]; then
            echo "geoip:cn"
            count=$((count + 1))
        elif [[ "${item}" == geoip:* ]] && geoipExists "${item#geoip:}"; then
            echo "${item}"
            count=$((count + 1))
        elif isCIDR "${item}"; then
            # 裸 IP 统一补成 CIDR（IPv4 /32，IPv6 /128），避免各核心对裸地址的处理差异
            if [[ "${item}" != */* ]]; then
                if [[ "${item}" == *:* ]]; then item="${item}/128"; else item="${item}/32"; fi
            fi
            echo "ip:${item}"
            count=$((count + 1))
        else
            echoContent yellow " ---> 已跳过不合法的 IP/CIDR: ${item}" >&2
        fi
    done
    ((count > 0))
}

# stagedAddTokens <路径(如 .routing.warp.v4.domains)> <token...>
stagedAddTokens() {
    local path=$1 arr
    shift
    arr=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
    stagedEdit --argjson t "${arr}" "${path} = (((${path} // []) + \$t) | unique)"
}

showTokens() { # showTokens <路径>
    local out
    out=$(S "(${1} // [])[]")
    if [[ -z "${out}" ]]; then echoContent yellow "    (空)"; else printf '%s\n' "${out}" | sed 's/^/    /'; fi
}

# 应用并给出统一提示
applyRouting() { # applyRouting <说明>
    if applyStaged "$1"; then
        echoContent green " ---> 完毕（$1）"
        return 0
    fi
    stagedDiscard
    return 1
}

# 分流的前提: 已安装至少一个协议或 Socks5 入站
requireRoutingBase() {
    stateExists && { [[ -n "$(installedProtocols)" ]] || [[ "$(S '.routing.socks5_in.port // 0')" != "0" ]]; } || {
        echoContent red " ---> 未安装任意协议，请使用 1.安装 或 2.任意组合安装 后再使用"
        return 1
    }
}

# ----------------------------- WARP ------------------------------------------
WARP_DIR="${ATR_HOME}/warp"
WARP_REG="${WARP_DIR}/warp-reg"

# 把 warp-reg 的输出解析成 JSON {private_key,public_key,address_v6,reserved:[..]}
parseWarpRegOutput() { # stdin: warp-reg 输出
    local txt priv pub v6 res
    txt=$(cat)
    priv=$(awk -F': *' '/^private_key/{print $2; exit}' <<<"${txt}" | tr -d '[:space:]')
    pub=$(awk -F': *' '/^public_key/{print $2; exit}' <<<"${txt}" | tr -d '[:space:]')
    v6=$(awk -F': *' '/^v6/{print $2; exit}' <<<"${txt}" | tr -d '[:space:]')
    res=$(awk -F': *' '/^reserved/{print $2; exit}' <<<"${txt}")
    [[ -n "${priv}" && -n "${pub}" && -n "${v6}" && -n "${res}" ]] || return 1
    jq -n --arg p "${priv}" --arg u "${pub}" --arg v "${v6}" --argjson r "$(jq -c . <<<"${res}" 2>/dev/null || echo null)" \
        'if $r == null then error("bad reserved") else {private_key:$p, public_key:$u, address_v6:$v, reserved:$r} end' 2>/dev/null
}

# 确保候选状态里有 WARP 账号（没有则下载 warp-reg 并注册）
ensureWarpConfig() {
    if [[ "$(stagedGet '(.routing.warp.config.private_key // "") != ""')" == "true" ]]; then return 0; fi
    local arch cfg
    case "$(uname -m)" in x86_64 | amd64) arch="main-linux-amd64" ;; aarch64 | arm64) arch="main-linux-arm64" ;; *)
        echoContent red " ---> 不支持的架构"
        return 1
        ;;
    esac
    if [[ ! -x "${WARP_REG}" ]]; then
        echoContent yellow "\n# 注意事项"
        echoContent yellow "# 依赖第三方程序 warp-reg，请熟知其中风险"
        echoContent yellow "# 项目地址: https://github.com/badafans/warp-reg \n"
        confirm "warp-reg 未安装，是否下载并注册 WARP 账号？" n || return 1
        mkdir -p "${WARP_DIR}"
        download "https://github.com/badafans/warp-reg/releases/download/v1.0/${arch}" "${WARP_REG}" || {
            echoContent red " ---> 下载 warp-reg 失败"
            return 1
        }
        chmod 755 "${WARP_REG}"
    fi
    cfg=$("${WARP_REG}" 2>/dev/null | parseWarpRegOutput) || {
        echoContent red " ---> 注册 WARP 账号失败（warp-reg 输出无法解析）"
        return 1
    }
    stagedEdit --argjson c "${cfg}" '.routing.warp.config=$c'
}

# 清理工具类域名规则（"全局"模式会替代它们），保留黑名单/BT
clearToolRoutes() {
    stagedEdit '.routing.warp.v4.domains=[] | .routing.warp.v6.domains=[] | .routing.ipv6.domains=[] | .routing.socks5_out.domains=[]'
}

warpMenu() { # warpMenu <v4|v6>
    local t=$1 label c list toks
    requireRoutingBase || return 1
    label="WARP分流[第三方 IP${t}]"
    echoContent skyBlue "\n进度  1/1 : ${label}"
    echoContent red "=============================================================="
    echoContent yellow "1.查看已分流域名"
    echoContent yellow "2.添加域名"
    echoContent yellow "3.设置WARP全局"
    echoContent yellow "4.卸载WARP分流"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        echoContent yellow "已分流域名:"
        showTokens ".routing.warp.v${t#v}.domains"
        [[ "$(S '.routing.global')" == "warp_${t}" ]] && echoContent green " ---> 已设置 WARP ${t} 全局分流"
        ;;
    2)
        echoContent yellow "# 支持 sing-box / Xray-core；录入示例: netflix,openai,example.com"
        ask list "请按照上面示例录入域名:" || return 1
        toks=$(parseDomainList "${list}") || {
            echoContent red " ---> 没有可用的规则"
            return 1
        }
        stagedBegin
        ensureWarpConfig || {
            stagedDiscard
            return 1
        }
        # shellcheck disable=SC2086
        stagedAddTokens ".routing.warp.${t}.domains" ${toks} || return 1
        applyRouting "WARP ${t} 分流"
        ;;
    3)
        echoContent yellow "# 注意事项: 会清除其他工具的分流规则(保留黑名单/BT)，全部出站流量走 WARP ${t}"
        confirm "是否确认设置？" n || return 0
        stagedBegin
        ensureWarpConfig || {
            stagedDiscard
            return 1
        }
        clearToolRoutes
        stagedEdit --arg g "warp_${t}" '.routing.global=$g' || return 1
        applyRouting "WARP ${t} 全局"
        ;;
    4)
        stagedBegin
        stagedEdit --arg k "${t}" '.routing.warp[$k].domains=[]' || return 1
        [[ "$(stagedGet '.routing.global')" == "warp_${t}" ]] && stagedEdit '.routing.global=""'
        if [[ "$(stagedGet '[(.routing.warp.v4.domains|length),(.routing.warp.v6.domains|length)]|add')" == "0" ]] &&
            [[ "$(stagedGet '.routing.global|startswith("warp_")')" != "true" ]]; then
            stagedEdit '.routing.warp.config={}'
        fi
        applyRouting "卸载 WARP ${t} 分流"
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- IPv6 分流 -------------------------------------
ipv6Menu() {
    local c list toks
    requireRoutingBase || return 1
    hasIPv6 || {
        echoContent red " ---> 本机不支持 IPv6"
        return 1
    }
    echoContent skyBlue "\n功能 1/1 : IPv6分流"
    echoContent red "=============================================================="
    echoContent yellow "1.查看已分流域名"
    echoContent yellow "2.添加域名"
    echoContent yellow "3.设置IPv6全局"
    echoContent yellow "4.卸载IPv6分流"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        showTokens ".routing.ipv6.domains"
        [[ "$(S '.routing.global')" == "ipv6" ]] && echoContent green " ---> 已设置 IPv6 全局分流"
        ;;
    2)
        ask list "请录入域名(示例: netflix,openai,example.com):" || return 1
        toks=$(parseDomainList "${list}") || return 1
        stagedBegin
        # shellcheck disable=SC2086
        stagedAddTokens ".routing.ipv6.domains" ${toks} || return 1
        applyRouting "IPv6 分流"
        ;;
    3)
        echoContent yellow "# 注意: 会清除其他工具的分流规则，全部出站流量走 IPv6"
        confirm "是否确认设置？" n || return 0
        stagedBegin
        clearToolRoutes
        stagedEdit '.routing.global="ipv6"' || return 1
        applyRouting "IPv6 全局"
        ;;
    4)
        stagedBegin
        stagedEdit '.routing.ipv6.domains=[]' || return 1
        [[ "$(stagedGet '.routing.global')" == "ipv6" ]] && stagedEdit '.routing.global=""'
        applyRouting "卸载 IPv6 分流"
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- Socks5 ----------------------------------------
socks5OutMenu() {
    local c ip port user pass list toks
    echoContent skyBlue "\n功能 1/1 : Socks5出站"
    echoContent red "=============================================================="
    echoContent yellow "1.安装Socks5出站"
    echoContent yellow "2.设置Socks5全局转发"
    echoContent yellow "3.查看分流规则"
    echoContent yellow "4.添加分流规则"
    ask c "请选择:" || return 1
    case "${c}" in
    1 | 2)
        echoContent yellow "\n==================== 配置 Socks5 出站（转发机、代理机） ====================\n"
        ask ip "请输入落地机IP地址:" || return 1
        isHostOrIP "${ip}" || {
            echoContent red " ---> 地址不合法"
            return 1
        }
        ask port "请输入落地机端口:" || return 1
        isPort "${port}" || {
            echoContent red " ---> 端口不合法"
            return 1
        }
        ask user "请输入用户名:" || return 1
        ask pass "请输入用户密码:" || return 1
        [[ -n "${user}" && -n "${pass}" ]] || {
            echoContent red " ---> 用户名/密码不能为空"
            return 1
        }
        stagedBegin
        stagedEdit --arg ip "${ip}" --argjson port "${port}" --arg u "${user}" --arg p "${pass}" \
            '.routing.socks5_out={server:$ip,port:$port,user:$u,pass:$p,domains:(.routing.socks5_out.domains // [])}' || return 1
        if [[ "${c}" == "2" ]]; then
            echoContent yellow "# 注意: 会清除其他工具的分流规则(保留黑名单/BT)，全部出站流量走 Socks5"
            confirm "是否确认设置？" n || {
                stagedDiscard
                return 0
            }
            clearToolRoutes
            stagedEdit '.routing.global="socks5"' || return 1
        else
            ask list "请输入要分流的域名(示例: netflix,openai,example.com):" || return 1
            toks=$(parseDomainList "${list}") || {
                stagedDiscard
                return 1
            }
            # shellcheck disable=SC2086
            stagedAddTokens ".routing.socks5_out.domains" ${toks} || return 1
        fi
        applyRouting "Socks5 出站"
        ;;
    3)
        echoContent yellow "出站配置: $(S '.routing.socks5_out|if (.server // "") != "" then "\(.server):\(.port) 用户 \(.user)" else "(未配置)" end')"
        echoContent yellow "分流域名:"
        showTokens ".routing.socks5_out.domains"
        ;;
    4)
        [[ -n "$(S '.routing.socks5_out.server // ""')" ]] || {
            echoContent red " ---> 请先安装 Socks5 出站"
            return 1
        }
        ask list "请输入要分流的域名(增量添加):" || return 1
        toks=$(parseDomainList "${list}") || return 1
        stagedBegin
        # shellcheck disable=SC2086
        stagedAddTokens ".routing.socks5_out.domains" ${toks} || return 1
        applyRouting "Socks5 出站规则"
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

socks5InMenu() {
    local c port user pass strat ips list toks
    echoContent skyBlue "\n功能 1/1 : Socks5入站（解锁机/落地机，仅 sing-box）"
    echoContent red "=============================================================="
    echoContent yellow "1.安装Socks5入站"
    echoContent yellow "2.查看分流规则"
    echoContent yellow "3.修改允许访问的域名/来源 IP"
    echoContent yellow "4.查看入站配置(需配置到其他机器的出站)"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        echoContent red "# 注意: Socks5 是明文代理，仅限设备间转发，禁止用于代理访问；默认拒绝一切未授权来源"
        ensureCore sing-box || return 1
        stagedBegin
        askPort port socks5 "Socks5 入站" tcp "$(randomFreePort "$(stagedUsedPorts | awk '{print $2}' | tr '\n' ' ')")" || return 1
        ask user "请输入用户名[回车随机]:" || return 1
        [[ -z "${user}" ]] && user=$(newUUID)
        ask pass "请输入密码[回车随机]:" || return 1
        [[ -z "${pass}" ]] && pass=$(newPassword)
        echoContent yellow "\n请选择分流域名 DNS 解析类型: 1.IPv4[默认]  2.IPv6"
        ask strat "请选择:" || return 1
        [[ "${strat}" == "2" ]] && strat=ipv6_only || strat=ipv4_only
        ask ips "请输入允许访问的来源 IP，多个用英文逗号隔开(例如 1.1.1.1,2.2.2.2):" || return 1
        local arr
        arr=$(parseIPList "${ips}" | grep '^ip:' | sed 's/^ip://' | jq -R . | jq -sc .) || return 1
        [[ "${arr}" != "[]" ]] || {
            echoContent red " ---> 来源 IP 不能为空"
            stagedDiscard
            return 1
        }
        local all=false
        confirm "是否允许访问所有网站？(选 n 则只允许下面指定的域名)" n && all=true
        local domArr='[]'
        if [[ "${all}" == "false" ]]; then
            ask list "请输入允许访问的域名(示例: netflix,openai,example.com):" || return 1
            toks=$(parseDomainList "${list}") || {
                stagedDiscard
                return 1
            }
            domArr=$(printf '%s\n' "${toks}" | jq -R . | jq -sc .)
        fi
        stagedEdit --argjson port "${port}" --arg u "${user}" --arg p "${pass}" --arg s "${strat}" --argjson ips "${arr}" --argjson all "${all}" --argjson d "${domArr}" \
            '.routing.socks5_in={port:$port,user:$u,pass:$p,ip_strategy:$s,allow_ips:$ips,all:$all,domains:$d}' || return 1
        applyRouting "Socks5 入站"
        ;;
    2)
        echoContent yellow "允许来源 IP: $(S '.routing.socks5_in.allow_ips // []|join(",")')   允许所有网站: $(S '.routing.socks5_in.all // false')"
        showTokens ".routing.socks5_in.domains"
        ;;
    3)
        [[ "$(S '.routing.socks5_in.port // 0')" != "0" ]] || {
            echoContent red " ---> 请先安装 Socks5 入站"
            return 1
        }
        ask ips "请输入允许访问的来源 IP(多个逗号隔开，替换原有):" || return 1
        local arr2
        arr2=$(parseIPList "${ips}" | grep '^ip:' | sed 's/^ip://' | jq -R . | jq -sc .) || return 1
        ask list "请输入允许访问的域名(替换原有，留空表示允许所有网站):" || return 1
        stagedBegin
        if [[ -z "${list}" ]]; then
            stagedEdit --argjson ips "${arr2}" '.routing.socks5_in.allow_ips=$ips | .routing.socks5_in.all=true | .routing.socks5_in.domains=[]' || return 1
        else
            toks=$(parseDomainList "${list}") || {
                stagedDiscard
                return 1
            }
            stagedEdit --argjson ips "${arr2}" --argjson d "$(printf '%s\n' "${toks}" | jq -R . | jq -sc .)" \
                '.routing.socks5_in.allow_ips=$ips | .routing.socks5_in.all=false | .routing.socks5_in.domains=$d' || return 1
        fi
        applyRouting "Socks5 入站规则"
        ;;
    4)
        [[ "$(S '.routing.socks5_in.port // 0')" != "0" ]] || {
            echoContent red " ---> 未安装 Socks5 入站"
            return 1
        }
        echoContent yellow "\n ---> 下列内容需要配置到其他机器的出站，请不要进行代理行为\n"
        echoContent green " 端口: $(S '.routing.socks5_in.port')"
        echoContent green " 用户名称: \c"
        printRaw green "$(S '.routing.socks5_in.user')"
        echoContent green " 用户密码: \c"
        printRaw green "$(S '.routing.socks5_in.pass')"
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

socks5Menu() {
    local c
    echoContent skyBlue "\n功能 1/1 : Socks5分流"
    echoContent red "=============================================================="
    echoContent red "# 注意事项: 流量明文访问；仅限正常网络环境下设备间流量转发，禁止用于代理访问。"
    echoContent yellow "1.Socks5出站"
    echoContent yellow "2.Socks5入站"
    echoContent yellow "3.卸载"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        requireRoutingBase || return 1
        socks5OutMenu
        ;;
    2) socks5InMenu ;;
    3)
        echoContent yellow "1.卸载Socks5出站  2.卸载Socks5入站  3.卸载全部"
        ask c "请选择:" || return 1
        stagedBegin
        case "${c}" in
        1) stagedEdit '.routing.socks5_out={} | (if .routing.global=="socks5" then .routing.global="" else . end)' ;;
        2) stagedEdit '.routing.socks5_in={}' ;;
        3) stagedEdit '.routing.socks5_out={} | .routing.socks5_in={} | (if .routing.global=="socks5" then .routing.global="" else . end)' ;;
        *)
            echoContent red " ---> 选择错误"
            stagedDiscard
            return 1
            ;;
        esac || return 1
        applyRouting "卸载 Socks5"
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- DNS 分流 / SNI 反向代理 ------------------------
dnsRoutingMenu() {
    local c dns list toks
    requireRoutingBase || return 1
    echoContent skyBlue "\n功能 1/1 : DNS分流"
    echoContent red "=============================================================="
    echoContent yellow "1.添加"
    echoContent yellow "2.卸载"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        ask dns "请输入分流的DNS(IP 地址):" || return 1
        isIPv4 "${dns}" || isIPv6 "${dns}" || {
            echoContent red " ---> DNS 必须是 IP 地址"
            return 1
        }
        ask list "请按示例录入域名(示例: netflix,disney,hulu):" || return 1
        toks=$(parseDomainList "${list}") || return 1
        stagedBegin
        stagedEdit --arg d "${dns}" '.routing.dns_unlock={server:$d,domains:[]}' || return 1
        # shellcheck disable=SC2086
        stagedAddTokens ".routing.dns_unlock.domains" ${toks} || return 1
        applyRouting "DNS 分流"
        echoContent yellow "\n ---> 如还无法观看可尝试: 1.重启 VPS  2.卸载 DNS 解锁后修改本机 /etc/resolv.conf 并重启"
        ;;
    2)
        stagedBegin
        stagedEdit '.routing.dns_unlock={}' || return 1
        applyRouting "卸载 DNS 分流"
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

sniRoutingMenu() {
    local c ip list toks
    requireRoutingBase || return 1
    echoContent skyBlue "\n功能 1/1 : SNI反向代理分流"
    echoContent red "=============================================================="
    echoContent yellow "# sing-box 不支持规则集，仅支持指定域名；Xray-core 支持 geosite 列表"
    echoContent yellow "1.添加"
    echoContent yellow "2.卸载"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        ask ip "请输入分流的 SNI 代理 IP:" || return 1
        isIPv4 "${ip}" || isIPv6 "${ip}" || {
            echoContent red " ---> 必须是 IP 地址"
            return 1
        }
        ask list "请按示例录入域名(示例: www.netflix.com,www.google.com):" || return 1
        toks=$(parseDomainList "${list}") || return 1
        stagedBegin
        stagedEdit --arg i "${ip}" '.routing.sni_proxy={ip:$i,domains:[]}' || return 1
        # shellcheck disable=SC2086
        stagedAddTokens ".routing.sni_proxy.domains" ${toks} || return 1
        applyRouting "SNI 反向代理分流"
        ;;
    2)
        stagedBegin
        stagedEdit '.routing.sni_proxy={}' || return 1
        applyRouting "卸载 SNI 反向代理分流"
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- 11. 分流工具 -----------------------------------
routingToolsMenu() {
    local c
    echoContent skyBlue "\n功能 1/1 : 分流工具"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项"
    echoContent yellow "# 用于服务端的流量分流，可用于解锁 ChatGPT、流媒体等相关内容\n"
    echoContent yellow "1.WARP分流【第三方 IPv4】"
    echoContent yellow "2.WARP分流【第三方 IPv6】"
    echoContent yellow "3.IPv6分流"
    echoContent yellow "4.Socks5分流【替换任意门分流】"
    echoContent yellow "5.DNS分流"
    echoContent yellow "7.SNI反向代理分流"
    ask c "请选择:" || return 1
    case "${c}" in
    1) warpMenu v4 ;;
    2) warpMenu v6 ;;
    3) ipv6Menu ;;
    4) socks5Menu ;;
    5) dnsRoutingMenu ;;
    7) sniRoutingMenu ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- 13. BT 下载管理 --------------------------------
btMenu() {
    requireRoutingBase || return 1
    local c cur
    cur=$(S '.routing.block_bt')
    echoContent skyBlue "\n功能 1/1 : BT下载管理"
    echoContent red "\n=============================================================="
    if [[ "${cur}" == "true" ]]; then echoContent yellow "当前状态:已禁止下载BT"; else echoContent yellow "当前状态:允许下载BT"; fi
    echoContent yellow "1.禁止下载BT"
    echoContent yellow "2.允许下载BT"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    stagedBegin
    case "${c}" in
    1) stagedEdit '.routing.block_bt=true' ;;
    2) stagedEdit '.routing.block_bt=false' ;;
    *)
        echoContent red " ---> 选择错误"
        stagedDiscard
        return 1
        ;;
    esac || return 1
    applyRouting "BT 下载管理"
}

# ----------------------------- 15. 域名黑名单 ---------------------------------
# 屏蔽大陆时默认放行的域名（Google Play、Apple、微软、Bing 等，与 v2ray-agent 一致）
CN_ALLOW_DEFAULT="googleplay.com,play.google.com,play.googleapis.com,play-lh.googleusercontent.com,play-games.googleusercontent.com,play-fe.googleapis.com,dl.google.com,apple.com,apple-pki,apple-tvplus,apple-update,itunes,icloud,beats,bing.com,microsoft.com,gstatic,googleapis.com,googleapis.cn"

blacklistMenu() {
    requireRoutingBase || return 1
    local c list toks
    echoContent skyBlue "\n进度  1/1 : 域名黑名单"
    echoContent red "\n=============================================================="
    echoContent yellow "1.查看已屏蔽域名"
    echoContent yellow "2.添加域名"
    echoContent yellow "3.屏蔽大陆域名+IP"
    echoContent yellow "4.卸载黑/白名单"
    echoContent yellow "5.添加IP"
    echoContent yellow "6.添加域名白名单"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        echoContent yellow "已屏蔽域名:"
        showTokens ".routing.blacklist.domains"
        echoContent yellow "已屏蔽 IP:"
        showTokens ".routing.blacklist.ips"
        [[ "$(S '.routing.blacklist.cn')" == "true" ]] && echoContent green " ---> 已屏蔽大陆域名+IP"
        echoContent yellow "域名白名单(直连):"
        showTokens ".routing.blacklist.allow"
        ;;
    2)
        echoContent yellow "# 规则支持预定义域名列表(geosite)与自定义域名；录入示例: speedtest,facebook,cn,example.com"
        echoContent yellow "# 添加规则为增量配置，不会删除之前设置的内容"
        ask list "请按照上面示例录入域名:" || return 1
        toks=$(parseDomainList "${list}") || return 1
        stagedBegin
        # shellcheck disable=SC2086
        stagedAddTokens ".routing.blacklist.domains" ${toks} || return 1
        applyRouting "域名黑名单"
        ;;
    3)
        toks=$(parseDomainList "${CN_ALLOW_DEFAULT}" 2>/dev/null)
        stagedBegin
        stagedEdit '.routing.blacklist.cn=true' || return 1
        # shellcheck disable=SC2086
        [[ -n "${toks}" ]] && stagedAddTokens ".routing.blacklist.allow" ${toks}
        applyRouting "屏蔽大陆域名+IP"
        ;;
    4)
        stagedBegin
        stagedEdit '.routing.blacklist={domains:[],ips:[],cn:false,allow:[]}' || return 1
        applyRouting "卸载黑/白名单"
        ;;
    5)
        echoContent yellow "录入示例: 1.1.1.1,8.8.8.8,1.1.1.0/24,2400:3200::/32,cn"
        ask list "请按照上面示例录入 IP:" || return 1
        toks=$(parseIPList "${list}") || {
            echoContent red " ---> IP 不能为空/不合法"
            return 1
        }
        stagedBegin
        # shellcheck disable=SC2086
        stagedAddTokens ".routing.blacklist.ips" ${toks} || return 1
        applyRouting "IP 黑名单"
        ;;
    6)
        echoContent yellow "录入示例: speedtest,openai,google.com"
        ask list "请按照上面示例录入域名:" || return 1
        toks=$(parseDomainList "${list}") || return 1
        stagedBegin
        # shellcheck disable=SC2086
        stagedAddTokens ".routing.blacklist.allow" ${toks} || return 1
        applyRouting "域名白名单"
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# =============================================================================
#  16  状态显示 / 日志 / BBR 与 DD / 更新脚本 / 卸载
# =============================================================================

# ----------------------------- 状态 ------------------------------------------
_coreStatusLine() { # _coreStatusLine <core>
    local core=$1 v st
    coreInstalled "${core}" || return 1
    v=$(coreVersion "${core}")
    if serviceActive "$(coreUnit "${core}")"; then st="运行中"; else st="未运行"; fi
    printf '%s v%s[%s]' "$(coreLabel "${core}")" "${v}" "${st}"
}

showInstallStatus() {
    local line="" x protoNames=""
    stateExists || {
        echoContent yellow "\n状态: 尚未安装"
        return 0
    }
    line=$(_coreStatusLine sing-box)
    x=$(_coreStatusLine xray) && line="${line:+${line}  |  }${x}"
    [[ -n "${line}" ]] && echoContent yellow "\n核心: ${line}"
    while read -r x; do
        [[ -z "${x}" ]] && continue
        protoNames+="$(protoName "${x}") "
    done < <(installedProtocols)
    [[ -n "${protoNames}" ]] && echoContent yellow "已安装协议: ${protoNames}"
    if stateNeedsNginx "${ATR_STATE}"; then
        if serviceActive "${NGX_UNIT}"; then echoContent yellow "nginx: 运行中"; else echoContent yellow "nginx: 未运行"; fi
    fi
    local d
    d=$(S '.domain // ""')
    if [[ -n "${d}" && -s "${TLS_DIR}/${d}.crt" ]]; then
        echoContent yellow "证书: ${d}（剩余 $(tlsDaysLeft "${TLS_DIR}/${d}.crt") 天）"
    fi
}

showStatusCLI() {
    showInstallStatus
    stateExists || return 0
    local proto port
    echoContent skyBlue "\n监听检查:"
    while read -r proto port; do
        [[ -z "${port}" ]] && continue
        if portInUse "${port}" "${proto}"; then echoContent green "  ✓ ${proto}/${port}"; else echoContent red "  ✗ ${proto}/${port} 未监听"; fi
    done < <(expectedListeners "${ATR_STATE}" | sort -u)
}

# ----------------------------- 19. 查看日志 -----------------------------------
logsMenu() {
    local c
    echoContent skyBlue "\n功能 1/1 : 查看日志"
    echoContent red "\n=============================================================="
    echoContent yellow "# 实时日志按 Ctrl+C 返回菜单\n"
    echoContent yellow "1.sing-box 实时日志"
    echoContent yellow "2.Xray-core 实时日志"
    echoContent yellow "3.nginx 实时日志"
    echoContent yellow "4.证书(acme)日志"
    echoContent yellow "5.脚本操作日志(安装/回滚记录)"
    echoContent yellow "6.启用/关闭调试日志   [当前: $(S 'if .log.debug then "开" else "关" end')]"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1) viewLog sing-box ;;
    2) viewLog xray ;;
    3) viewLog nginx ;;
    4) viewLog acme ;;
    5) tail -n 80 "${ATR_HOME}/atr.log" 2>/dev/null || echoContent yellow " ---> 暂无记录" ;;
    6) toggleDebugLog ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# ----------------------------- 18. BBR / DD -----------------------------------
enableBuiltinBBR() {
    local avail
    modprobe tcp_bbr >/dev/null 2>&1
    avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
    if [[ "${avail}" != *bbr* ]]; then
        echoContent red " ---> 当前内核不支持 BBR（需要 Linux 4.9+ 且带 tcp_bbr 模块），可考虑使用 tcpx.sh 更换内核"
        return 1
    fi
    mkdir -p "$(dirname "${ATR_SYSCTL_FILE}")"
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >"${ATR_SYSCTL_FILE}"
    sysctl -q -p "${ATR_SYSCTL_FILE}" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    # 回读验证: 容器/部分虚拟化环境不允许修改内核参数，不能假装成功
    if [[ "${cc}" != "bbr" ]]; then
        rm -f "${ATR_SYSCTL_FILE}"
        echoContent red " ---> 未能生效：当前拥塞控制算法仍是 ${cc:-未知}（容器或受限虚拟化环境通常不允许修改内核参数），已撤销写入"
        return 1
    fi
    echoContent green " ---> 已启用原版 BBR+FQ（当前: ${cc}/${qd}）"
    echoContent yellow " ---> 配置文件: ${ATR_SYSCTL_FILE}（删除该文件并重启即可恢复）"
}

bbrMenu() {
    local c w
    echoContent red "\n=============================================================="
    echoContent green "BBR、DD脚本用的[ylx2016]的成熟作品，地址[https://github.com/ylx2016/Linux-NetSpeed]，请熟知"
    echoContent yellow "1.安装脚本【推荐原版BBR+FQ】（运行第三方 tcpx.sh：BBR/内核/DD 等）"
    echoContent yellow "2.仅启用原版 BBR+FQ（本脚本内置，不下载任何第三方脚本）"
    echoContent yellow "3.回退主目录"
    echoContent red "=============================================================="
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        echoContent red "\n ! 将下载并以 root 身份运行第三方脚本 tcpx.sh；它包含 DD 重装系统功能（会清空整块磁盘）。"
        echoContent red " ! 请务必确认你知道自己在选什么，并已备份数据。"
        confirm "确认继续下载并运行 tcpx.sh ？" n || return 0
        w=$(mktemp -d "${ATR_TMP:-/tmp}/tcpx.XXXXXX")
        if download "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh" "${w}/tcpx.sh"; then
            chmod +x "${w}/tcpx.sh"
            (cd "${w}" && ./tcpx.sh)
        else
            echoContent red " ---> 下载 tcpx.sh 失败"
        fi
        rm -rf "${w}"
        ;;
    2) enableBuiltinBBR ;;
    *) return 0 ;;
    esac
}

# ----------------------------- 17. 更新脚本 -----------------------------------
updateScript() {
    local url="" f newver
    [[ -s "${ATR_HOME}/script_url" ]] && url=$(cat "${ATR_HOME}/script_url")
    [[ -z "${url}" ]] && url=${ATR_SCRIPT_URL_DEFAULT}
    if [[ -z "${url}" ]]; then
        echoContent yellow "尚未配置脚本更新地址（例如你自己托管的 raw 链接）"
        ask url "请输入脚本下载地址(https://...):" || return 1
    else
        echoContent yellow "更新地址: ${url}"
        confirm "使用该地址更新？" y || {
            ask url "请输入新的脚本下载地址:" || return 1
        }
    fi
    [[ "${url}" =~ ^https://[A-Za-z0-9._~:/?#@%=\&+-]+$ ]] || {
        echoContent red " ---> 地址不合法（必须是 https:// 链接）"
        return 1
    }
    f="${ATR_TMP:-/tmp}/atr-new.sh"
    echoContent green " ---> 下载新版本"
    if ! download "${url}" "${f}"; then
        echoContent red " ---> 下载失败"
        return 1
    fi
    if ! bash -n "${f}" 2>/dev/null || ! grep -q "ATR_PROJECT_NAME=\"${ATR_PROJECT_NAME}\"" "${f}"; then
        echoContent red " ---> 下载的文件不是有效的 ${ATR_PROJECT_NAME} 脚本（语法错误或标识不符），已放弃更新"
        return 1
    fi
    newver=$(sed -n 's/^ATR_VERSION="\(.*\)"/\1/p' "${f}" | head -n 1)
    echoContent yellow " ---> 当前版本 ${ATR_VERSION}，远程版本 ${newver:-未知}"
    confirm "确认更新？" y || return 0
    printf '%s' "${url}" >"${ATR_HOME}/script_url"
    [[ -f "${ATR_SCRIPT_PATH}" ]] && cp -f "${ATR_SCRIPT_PATH}" "${ATR_SCRIPT_PATH}.prev"
    install -m 700 "${f}" "${ATR_SCRIPT_PATH}.new" && mv -f "${ATR_SCRIPT_PATH}.new" "${ATR_SCRIPT_PATH}"
    echoContent green " ---> 更新完毕，请重新执行 [${ATR_CMD}] 打开脚本（旧版本已备份为 ${ATR_SCRIPT_PATH}.prev）"
    exit 0
}

# ----------------------------- 20. 卸载 ---------------------------------------
uninstallAll() {
    local proto port
    # 防御: ATR_HOME 被误设成系统目录时拒绝删除；并要求目录里确实有本脚本的痕迹
    case "${ATR_HOME%/}" in
    "" | /etc | /usr | /var | /home | /root | /opt | /bin | /sbin | /lib | /tmp | /boot | /srv | /mnt)
        echoContent red " ---> 拒绝卸载: ATR_HOME=${ATR_HOME} 不是安全的安装目录"
        return 1
        ;;
    esac
    if [[ ! -f "${ATR_HOME}/state.json" && ! -f "${ATR_SCRIPT_PATH}" ]]; then
        echoContent red " ---> ${ATR_HOME} 中没有 ${ATR_PROJECT_NAME} 的安装痕迹，拒绝卸载"
        return 1
    fi
    echoContent red "\n=============================================================="
    echoContent red "将停止并删除: sing-box / Xray / nginx 服务、全部配置、用户与客户端文件、防火墙规则、端口跳跃规则、${ATR_CMD} 命令"
    echoContent yellow "不会删除: acme.sh 及其证书记录(可选)、sysctl 的 BBR 配置、系统已装的软件包"
    echoContent red "=============================================================="
    confirm "是否确认卸载安装内容？" n || {
        echoContent green " ---> 放弃卸载"
        return 0
    }
    local delAcme=n
    confirm "是否同时删除 acme.sh 与其保存的证书(${ACME_HOME})？" n && delAcme=y

    if stateExists; then
        # 回收防火墙放行
        while read -r proto port; do
            [[ -z "${port}" ]] && continue
            fwClose "${port}" "${proto}"
        done < <(desiredFirewallPorts "${ATR_STATE}")
    fi
    hopRulesRemoveAll
    local u
    for u in "${SB_UNIT}" "${XRAY_UNIT}" "${NGX_UNIT}" "${HOP_UNIT}"; do
        serviceActive "${u}" && serviceStop "${u}"
        serviceDisable "${u}"
        rm -f "${ATR_SYSTEMD_DIR}/${u}.service"
    done
    systemctl daemon-reload >/dev/null 2>&1
    echoContent green " ---> 已停止并删除 systemd 服务"
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "${ATR_SCRIPT_PATH}" | crontab - 2>/dev/null
    fi
    if [[ "${delAcme}" == "y" ]]; then
        [[ -x "${ACME_SH}" ]] && "${ACME_SH}" --uninstall >/dev/null 2>&1
        rm -rf "${ACME_HOME}"
        echoContent green " ---> 已删除 acme.sh"
    fi
    rm -f "${ATR_BIN_DIR}/${ATR_CMD}"
    rm -rf "${ATR_HOME}"
    echoContent green " ---> 卸载完成"
    exit 0
}

# =============================================================================
#  17  主菜单 / 命令行入口 / main
# =============================================================================

usage() {
    cat <<EOF
${ATR_PROJECT_NAME} ${ATR_VERSION} —— sing-box / Xray 管理脚本 (AnyTLS+Reality)

用法: ${ATR_CMD} [命令]

  (无命令)                         打开交互式管理菜单
  install-anytls-reality [选项]    非交互一键安装 AnyTLS+Reality
        --port N        监听端口(默认 443，被占用则随机)
        --sni host[:p]  Reality 目标域名(默认 www.microsoft.com)
        --user name     首个用户名(默认随机)
  status                           查看服务与端口状态
  show [用户] [1]                  查看账号(第二个参数 1 同时显示二维码)
  sub [用户]                       查看订阅链接
  selfcheck                        自检(回环握手测试)
  sni <host[:port]> [--force]      修改 Reality 目标域名(SNI)
  passwd <用户> [新密码]           重置密码(不给则随机)
  adduser <用户> [uuid] [密码]     添加用户
  deluser <用户>                   删除用户(至少保留一个)
  restart                          重启全部服务
  log [sing-box|xray|nginx|acme]   查看日志(Ctrl+C 返回)
  renew-tls | update-geo | reload-core | apply-hop   (定时任务/钩子使用)
  uninstall                        卸载
  version | help
EOF
}

# ----------------------------- 命令行子命令 ----------------------------------
cliSetSNI() { # cliSetSNI <host[:port]> [--force]
    local target=${1:-} force=${2:-}
    requireInstalled || return 1
    [[ -n "$(installedRealityProtocols)" ]] || {
        echoContent red " ---> 未安装 Reality 类协议"
        return 1
    }
    parseSniInput "${target}" || {
        echoContent red " ---> SNI 不合法: ${target}"
        return 1
    }
    REALITY_CORE_HINT=$(realityCoreHint)
    if ! checkRealityTarget "${SNI_HOST}" "${SNI_PORT}" && [[ "${force}" != "--force" ]]; then
        echoContent red " ---> 目标未通过检测（加 --force 可强制使用）"
        return 1
    fi
    stagedBegin
    stagedSetReality "${SNI_HOST}" "${SNI_PORT}" no || return 1
    if applyStaged "修改 Reality SNI"; then
        postChangeShow "" "Reality 目标域名已改为 ${SNI_HOST}:${SNI_PORT}"
        selfCheckAll
    else
        stagedDiscard
        return 1
    fi
}

cliAddUser() { # cliAddUser <name> [uuid] [password]
    local name=${1:-} uuid=${2:-} pass=${3:-}
    requireInstalled || return 1
    isSafeName "${name}" || {
        echoContent red " ---> 用户名不合法"
        return 1
    }
    [[ -n "${uuid}" ]] && ! isUUID "${uuid}" && {
        echoContent red " ---> UUID 不合法"
        return 1
    }
    [[ -n "${pass}" ]] && ! isValidSecret "${pass}" && {
        echoContent red " ---> 密码不合法"
        return 1
    }
    stagedBegin
    stagedUserAdd "${name}" "${uuid}" "${pass}" || {
        stagedDiscard
        return 1
    }
    if applyStaged "添加用户 ${name}"; then
        postChangeShow "${name}" "已添加用户 ${name}"
    else
        stagedDiscard
        return 1
    fi
}

cliDelUser() {
    requireInstalled || return 1
    stagedBegin
    stagedUserDel "${1:-}" || {
        stagedDiscard
        return 1
    }
    if applyStaged "删除用户 ${1}"; then
        generateClientFiles
        echoContent green " ---> 已删除用户 ${1}"
    else
        stagedDiscard
        return 1
    fi
}

# ----------------------------- 主菜单 ----------------------------------------
printMenu() {
    cd "${HOME:-/root}" 2>/dev/null || true
    echoContent red "\n=============================================================="
    echoContent green "脚本: ${ATR_PROJECT_NAME}（基于 mack-a/v2ray-agent 改造，AGPL-3.0）"
    echoContent green "当前版本：${ATR_VERSION}"
    echoContent green "参考项目：https://github.com/mack-a/v2ray-agent"
    echoContent green "描述：sing-box / Xray 管理脚本 [AnyTLS + Reality]\c"
    showInstallStatus
    echoContent red "\n=============================================================="
    if stateExists && [[ -n "$(installedProtocols)" ]]; then
        echoContent yellow "1.重新安装"
    else
        echoContent yellow "1.安装"
    fi
    echoContent yellow "2.任意组合安装"
    echoContent yellow "3.一键无域名 AnyTLS+Reality"
    echoContent yellow "4.Hysteria2管理"
    echoContent yellow "5.REALITY管理"
    echoContent yellow "6.Tuic管理"
    echoContent skyBlue "-------------------------工具管理-----------------------------"
    echoContent yellow "7.用户管理"
    echoContent yellow "8.伪装站管理"
    echoContent yellow "9.证书管理"
    echoContent yellow "10.CDN节点管理"
    echoContent yellow "11.分流工具"
    echoContent yellow "12.添加新端口"
    echoContent yellow "13.BT下载管理"
    echoContent yellow "14.切换alpn"
    echoContent yellow "15.域名黑名单"
    echoContent skyBlue "-------------------------版本管理-----------------------------"
    echoContent yellow "16.core管理"
    echoContent yellow "17.更新脚本"
    echoContent yellow "18.安装BBR、DD脚本"
    echoContent skyBlue "-------------------------脚本管理-----------------------------"
    echoContent yellow "19.查看日志"
    echoContent yellow "20.卸载脚本"
    echoContent red "=============================================================="
}

# 返回 0 继续循环；返回 1 表示输入结束(EOF)应退出
menuOnce() {
    local c
    printMenu
    ask c "请选择:" || return 1
    case "${c}" in
    1) installPresetFlow ;;
    2) installCustomFlow ;;
    3) installOneClickFlow ;;
    4) manageHysteria ;;
    5) manageReality ;;
    6) manageTuic ;;
    7) manageUsers ;;
    8) manageFakeSite ;;
    9) manageCertificate ;;
    10) manageCDN ;;
    11) routingToolsMenu ;;
    12) manageExtraPorts ;;
    13) btMenu ;;
    14) manageAlpn ;;
    15) blacklistMenu ;;
    16) coreManageMenu ;;
    17) updateScript ;;
    18) bbrMenu ;;
    19) logsMenu ;;
    20) uninstallAll ;;
    0 | q | exit) return 1 ;;
    "") ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
    return 0
}

menuLoop() {
    while menuOnce; do
        echo
        IFS= read -r -p "按回车返回主菜单（输入 q 退出）:" _back || break
        [[ "${_back}" == "q" || "${_back}" == "Q" ]] && break
    done
}

# ----------------------------- main ------------------------------------------
main() {
    local cmd=${1:-menu}
    case "${cmd}" in
    version | -v | --version)
        echo "${ATR_PROJECT_NAME} ${ATR_VERSION}"
        return 0
        ;;
    help | -h | --help)
        usage
        return 0
        ;;
    esac
    # 先校验命令是否合法: 输错命令不应该产生任何副作用（装 atr、建目录、装依赖）
    case "${cmd}" in
    menu | install-anytls-reality | reload-core | restart | renew-tls | update-geo | apply-hop | status | show | sub | selfcheck | sni | passwd | adduser | deluser | log | uninstall) ;;
    *)
        usage
        exit 1
        ;;
    esac
    checkRoot
    checkSystem
    checkCPU
    mkdir -p "${ATR_HOME}"
    chmod 711 "${ATR_HOME}" 2>/dev/null
    ensureJq || exit 1
    recoverIfNeeded
    aliasInstall
    if [[ ! -x "${ATR_SCRIPT_PATH}" ]]; then
        echoContent yellow "\n 提示: 脚本没有保存到本机文件(可能是通过管道 curl | bash 运行的)，${ATR_CMD} 命令与证书自动续签后的重载钩子将不可用。"
        echoContent yellow "       请先下载保存为文件再运行:  wget -O anytls-reality.sh ${ATR_SCRIPT_URL_DEFAULT:-<脚本地址>} && bash anytls-reality.sh"
    fi
    shift || true
    case "${cmd}" in
    menu)
        warnV2rayAgentConflict
        menuLoop
        ;;
    install-anytls-reality) cliInstallAnyTLSReality "$@" ;;
    reload-core | restart) reloadAll ;;
    renew-tls) renewTLSNow ;;
    update-geo) updateGeoAll ;;
    apply-hop) reconcileHopRules "${ATR_STATE}" ;;
    status) showStatusCLI ;;
    show) showAccounts "${1:-}" "${2:-0}" ;;
    sub) showSubscriptionLinks "${1:-}" ;;
    selfcheck) selfCheckAll ;;
    sni) cliSetSNI "${1:-}" "${2:-}" ;;
    passwd) userResetFlow "${1:-}" "${2:-}" password ;;
    adduser) cliAddUser "${1:-}" "${2:-}" "${3:-}" ;;
    deluser) cliDelUser "${1:-}" ;;
    log) viewLog "${1:-sing-box}" ;;
    uninstall) uninstallAll ;;
    *)
        usage
        exit 1
        ;;
    esac
}

# 被 source（测试）时不自动运行。
# 注意: 通过管道执行(curl | bash)时 BASH_SOURCE[0] 为空，必须回退到 $0，否则脚本会静默地什么都不做。
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi
