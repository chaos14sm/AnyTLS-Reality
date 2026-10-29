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

# v1.2.3 安全修复：
# - 旧 peer 布局清理不再把密钥作为外部命令参数；清理后 peer 文件由后续发布重建。
# - 恢复或服务控制失败会阻止后续修改，保留未完成事务的恢复依据。
# - 公网模式过滤全部 Xray DNS（包括 DNS 解锁），ForceIP 已迁移到 sockopt。
# - 候选版本核对 draft/prerelease；升级还需通过互通检查，失败原子恢复旧内核。
# 可选固定版本（仍核验正式发布属性和 SHA256）：
#   ATR_XRAY_VERSION=v26.3.27 bash anytls-reality.sh
#   ATR_SINGBOX_VERSION=v1.14.3 bash anytls-reality.sh
# 不永久固定某个版本；GitHub 元数据不可核实时中止（核验需要能直连 api.github.com，不经过 GITHUB_PROXY）。
# v1.2.4：
# - 撤销收口改为按白名单重建发布目录：被撤销的令牌和旧版布局里的对等密钥不再出现在任何外部命令的参数里，
#   仍有效的文件不会被先删掉；启动对账撤下旧版 peer 布局后，在同一把锁里立即按新布局重新发布。
# - 换内核时的互通检查区分"握手失败"（自动恢复旧内核）和"无法自动验证"（保留新内核并列出，只确认了服务启动与端口监听）；
#   安装验收同理。ATR_ALLOW_UNTESTED_CORE 取消。
# - 有未完成的事务时 status / show / log 仍可使用；atr recover 重试恢复，atr recover --abandon 放弃恢复（备份保留）。
# v1.2.5：
# - 订阅要不要重新发布按磁盘上的实际状态判断（每个用户的 default/<令牌>、对等分享开着时的 peer/<用户>/default、nginx 订阅配置格式），
#   不再依赖进程内的标记：发布失败、_swapSubDir 两次 mv 之间被中断、开机任务只撤下没发布，下一次运行 atr 都会自动补发。
# - 清空/删除之后的复查本身失败（find 出错）按"没删干净"处理，走停止 nginx 的兜底，不再当成已经清空。
# - 自检客户端与节点承载核心一致；Naive 仍需专用客户端验证，节点生成错误按失败处理。
# v1.2.6（真机审计 2026-10-25）：
# - 核心单元 ProtectSystem=strict + RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK：连不上 systemd/D-Bus，写不了系统目录。
# - 公网出口模式也禁止本机的 NAT 公网地址（探测 + 手动补充）；Socks5 来源白名单排在嗅探和 DNS 劫持之前。
# - 防火墙: 放行失败回滚、没有防火墙不提示、nftables 默认拒绝给出手动命令；证书导入原子化；订阅完整性检查覆盖全部类型。
ATR_VERSION="v1.3.2"
# v1.3.2：HY2 目标评估与默认反代；Reality 每节点目标/密钥复用、原生兼容验收、时间差；AnyTLS 填充。
# v1.2.9：补齐 ACME / 卸载防火墙提示；状态显示 Reality 与订阅配置。
# v1.2.8：按节点所属核心自检；Reality 支持共享/按协议独立配置。
# v1.2.7：证书导入增加持久撤销日志与开机预恢复；防火墙撤销按后端/地址族记录，
# 在实际修改前同步日志，配置回滚与崩溃恢复均重放；不再全局 reload firewalld。
# 管理员在环境里指定的本机公网地址（订阅链接用它；出口访问模式也直接用它，不再联网探测）。只认启动时的环境变量，
# 运行中 ATR_PUBLIC_IP 会被当作缓存改写，不能用来判断"管理员是否指定过"
ATR_PUBLIC_IP_ENV="${ATR_PUBLIC_IP:-}"
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
# 版本 tag 的数字格式检查（不是发布属性检查）；正式稳定版还必须通过 verifyStableReleaseTag 核验 draft/prerelease。
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
# 订阅令牌: 每个用户一个独立的随机值（128 位），与节点密码/UUID 没有任何数学关系
newSubToken() { randHex 32; }
# 客户端配置里本地控制接口（127.0.0.1:9090）的 secret，每个用户一个
newApiSecret() { randHex 24; }
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
LOCK_DEPTH=0
lockAcquire() {
    if ((LOCK_DEPTH > 0)); then # 本进程（或它的子 shell）已经持有：可重入，只增加深度
        LOCK_DEPTH=$((LOCK_DEPTH + 1))
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        echoContent red " ---> 缺少 flock（util-linux），无法保证并发操作的安全，已中止。请先安装 util-linux 再重试"
        return 1
    fi
    mkdir -p "${ATR_HOME}"
    if ! { exec 9>"${LOCK_FILE}"; } 2>/dev/null; then
        echoContent red " ---> 无法打开锁文件 ${LOCK_FILE}，已中止（不会在没有锁的情况下修改配置）"
        return 1
    fi
    if ! flock -w 60 9; then
        exec 9>&-
        echoContent red " ---> 另一个 ${ATR_CMD} 操作正在进行，请稍后重试"
        return 1
    fi
    LOCK_DEPTH=1
}
lockRelease() {
    if ((LOCK_DEPTH > 1)); then
        LOCK_DEPTH=$((LOCK_DEPTH - 1))
        return 0
    fi
    ((LOCK_DEPTH == 1)) || return 0 # 本来就没持有
    flock -u 9 2>/dev/null
    exec 9>&-
    LOCK_DEPTH=0
}

# 事务标记: applyStaged 落盘期间存在，内容是本次备份目录；崩溃或回滚失败后保留，作为恢复依据
TXN_MARK="${ATR_HOME}/.txn"
TLS_TXN_MARK="${ATR_HOME}/.tls-txn"
TLS_RECOVERY_UNIT="atr-tls-recover"
# 获锁后检查：未完成的事务不能被新的配置、重启或发布覆盖。
_requireCleanTransaction() {
    if [[ -e "${TLS_TXN_MARK}" || -L "${TLS_TXN_MARK}" ]]; then
        echoContent red " ---> 存在尚未恢复完成的证书事务: ${TLS_TXN_MARK}。已拒绝修改/重启/发布，请执行 ${ATR_CMD} recover"
        return 1
    fi
    if [[ -e "${TXN_MARK}" || -L "${TXN_MARK}" ]]; then
        echoContent red " ---> 存在尚未恢复完成的事务: ${TXN_MARK}。已拒绝修改/重启/发布。排除问题后执行 ${ATR_CMD} recover 重试恢复，或 ${ATR_CMD} recover --abandon 放弃这次恢复（status / show / log 仍可使用）"
        return 1
    fi
    return 0
}

# find 只要第一个匹配项（打印出来，可能为空）。find 本身失败（读不了目录、I/O 错误）时返回 1：
# 调用方必须把它当成"不确定"，不能当成"没有"——否则检测失败就成了检测通过
_findFirst() { # _findFirst <find 参数...>
    local out
    out=$(find "$@" -print -quit 2>/dev/null) || return 1
    printf '%s' "${out}"
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

# ----------------------------- jq: 数据不出现在进程命令行上 ---------------------
# Linux 默认允许任何本机用户读取其他进程的命令行（/proc/<pid>/cmdline）。脚本里的 jq 经常要带上密码、UUID、
# 私钥、令牌、对等密钥，甚至整份 state，所以这里接管全部 jq 调用：--arg / --argjson 的"值"先写进只有 root 能进入的
# 私有临时目录里的文件，再用 --rawfile 交给 jq，命令行上只剩文件路径；--argjson 的值在 jq 程序开头用 fromjson 还原，
# 对调用方完全透明。用完立即清空文件内容。（改用环境变量并不能代替：它同样会被继承、被子进程看到。）
_JQ_SEQ=0
_JQ_DIR=""
_jqTmpDir() {
    [[ -n "${_JQ_DIR}" && -d "${_JQ_DIR}" ]] && return 0
    _JQ_DIR=${ATR_TMP:-}
    if [[ -z "${_JQ_DIR}" || ! -d "${_JQ_DIR}" ]]; then
        _JQ_DIR=$(mktemp -d /tmp/atr-jq.XXXXXX 2>/dev/null) || {
            _JQ_DIR=""
            return 1
        }
    fi
}
jq() {
    local -a in=("$@") out=() used=()
    local n=${#in[@]} i=0 a name val f pre="" prog_idx=-1 no_prog=0 rc has_data=0
    for a in "$@"; do [[ "${a}" == "--arg" || "${a}" == "--argjson" ]] && has_data=1; done
    if ! _jqTmpDir; then
        if ((has_data)); then # 数据不能退回到命令行上：直接失败
            printf '内部错误: 无法创建 jq 用的私有临时目录，已拒绝把数据放到命令行上执行\n' >&2
            return 1
        fi
        command jq "$@" # 没有任何 --arg/--argjson：命令行上本来就没有数据
        return
    fi
    while ((i < n)); do
        a=${in[i]}
        case "${a}" in
        --arg | --argjson)
            name=${in[i + 1]-}
            val=${in[i + 2]-}
            _JQ_SEQ=$((_JQ_SEQ + 1))
            f="${_JQ_DIR}/jq.${BASHPID}.${_JQ_SEQ}"
            used+=("${f}")
            if ! printf '%s' "${val}" >"${f}"; then
                for f in "${used[@]}"; do : >"${f}" 2>/dev/null; done
                printf '内部错误: 无法写入 jq 参数文件，已中止（不会改用命令行传参）\n' >&2
                return 1
            fi
            out+=(--rawfile "${name}" "${f}")
            [[ "${a}" == "--argjson" ]] && pre+="(\$${name} | fromjson) as \$${name} | "
            i=$((i + 3))
            ;;
        --slurpfile | --rawfile)
            out+=("${a}" "${in[i + 1]-}" "${in[i + 2]-}")
            i=$((i + 3))
            ;;
        -f | --from-file)
            out+=("${a}" "${in[i + 1]-}")
            no_prog=1
            i=$((i + 2))
            ;;
        -L | --indent)
            out+=("${a}" "${in[i + 1]-}")
            i=$((i + 2))
            ;;
        -?*)
            out+=("${a}")
            i=$((i + 1))
            ;;
        *)
            ((prog_idx < 0 && no_prog == 0)) && prog_idx=${#out[@]}
            out+=("${a}")
            i=$((i + 1))
            ;;
        esac
    done
    if ((prog_idx >= 0)); then
        out[prog_idx]="${pre}${out[prog_idx]}"
    elif [[ -n "${pre}" ]]; then # 没有可以加前缀的内联程序（例如 -f）：无法安全转换，宁可失败也不改用命令行传参
        for f in "${used[@]}"; do : >"${f}" 2>/dev/null; done
        printf '内部错误: 这种 jq 调用形式无法在不暴露参数的前提下转换，已拒绝执行\n' >&2
        return 1
    fi
    command jq "${out[@]}"
    rc=$?
    for f in "${used[@]}"; do : >"${f}" 2>/dev/null; done
    return "${rc}"
}
# 外部命令是否存在（jq 有同名包装函数，所以对 jq 必须只看外部命令）
_hasCmd() {
    if [[ "$1" == "jq" ]]; then type -P jq >/dev/null 2>&1; else command -v "$1" >/dev/null 2>&1; fi
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
    _hasCmd "${cmd}" && return 0
    echoContent green " ---> 安装 ${cmd}"
    pkgInstall "$(toolPkg "${cmd}")"
    if ! _hasCmd "${cmd}"; then
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

# 无法通过包管理器获得合格 jq 时，下载官方静态二进制。
# 固定版本并校验 SHA256（哈希取自 jqlang/jq 该版本发布的 sha256sum.txt，写死在脚本里，不依赖下载渠道，
# 经 GITHUB_PROXY 下载也无法被替换）；校验不通过的文件绝不会被执行。
JQ_BOOT_VERSION="1.7.1"
JQ_BOOT_SHA256_AMD64="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
JQ_BOOT_SHA256_ARM64="4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5"
bootstrapJq() {
    local want tmp
    case "${CPU_JQ}" in
    jq-linux-amd64) want=${JQ_BOOT_SHA256_AMD64} ;;
    jq-linux-arm64) want=${JQ_BOOT_SHA256_ARM64} ;;
    *) return 1 ;;
    esac
    tmp=$(mktemp "${ATR_TMP:-/tmp}/jq.XXXXXX") || return 1
    echoContent green " ---> 下载 jq ${JQ_BOOT_VERSION} 静态二进制（固定版本，SHA256 校验）"
    if download "https://github.com/jqlang/jq/releases/download/jq-${JQ_BOOT_VERSION}/${CPU_JQ}" "${tmp}" &&
        [[ "$(sha256sum "${tmp}" 2>/dev/null | awk '{print $1}')" == "${want}" ]]; then
        mkdir -p "${ATR_HOME}/bin"
        export PATH="${ATR_HOME}/bin:${PATH}"
        install -m 755 "${tmp}" "${ATR_HOME}/bin/jq"
    else
        echoContent red " ---> jq 下载失败或 SHA256 校验不通过，已丢弃该文件"
    fi
    rm -f "${tmp}"
    jqVersionOK
}

ensureJq() {
    if _hasCmd jq && jqVersionOK; then return 0; fi
    ensureTool jq optional || true
    if _hasCmd jq && jqVersionOK; then return 0; fi
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
    ensureTool python3 || return 1
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
 {"id":"naive","name":"Naive","short":"Naive","cores":["sing-box"],"reality":false,"tls":true,"net":"tcp","preset":true,"selfcheck":false},
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
  "egress": {"mode": "", "local_ips": []},
  "nginx": {"subscribe": {"enabled": false, "port": 0, "ssl": true, "peer_key": "", "remotes": []}, "redirect302": ""},
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

# ----------------------------- nginx 专用账号与目录权限 ------------------------
# 订阅目录里有全部用户的节点凭据。nginx worker 使用专用系统账号（无登录、无家目录），
# 只有 root 与该账号所属的组能读取订阅目录；其他本机用户既不能列目录，也不能读文件。
NGX_USER="atr-nginx"
ngxWorkerUser() { echo "${ATR_NGINX_USER:-${NGX_USER}}"; } # ATR_NGINX_USER 仅用于测试环境
ngxWorkerGroup() { id -gn "$(ngxWorkerUser)" 2>/dev/null; }
_sbinCmd() { # 非 root 的 PATH 里常常没有 /usr/sbin
    command -v "$1" 2>/dev/null && return 0
    local d
    for d in /usr/sbin /sbin; do
        [[ -x "${d}/$1" ]] && {
            echo "${d}/$1"
            return 0
        }
    done
    return 1
}
ensureNginxAccount() {
    local u uadd nologin
    u=$(ngxWorkerUser)
    id -u "${u}" >/dev/null 2>&1 && return 0
    [[ "${u}" == "${NGX_USER}" ]] || return 1 # 显式指定的账号不存在时，不替用户创建
    uadd=$(_sbinCmd useradd) || return 1
    nologin=$(_sbinCmd nologin) || nologin=/usr/sbin/nologin
    "${uadd}" --system --user-group --no-create-home --home-dir /nonexistent --shell "${nologin}" "${u}" >/dev/null 2>&1
    id -u "${u}" >/dev/null 2>&1
}
removeNginxAccount() {
    local c
    id -u "${NGX_USER}" >/dev/null 2>&1 && {
        c=$(_sbinCmd userdel) && "${c}" "${NGX_USER}" >/dev/null 2>&1
    }
    if getent group "${NGX_USER}" >/dev/null 2>&1; then
        c=$(_sbinCmd groupdel) && "${c}" "${NGX_USER}" >/dev/null 2>&1
    fi
    return 0
}
# 订阅目录树（含 peer/）: root:<nginx 组>，目录 750，文件 640。失败返回 1，调用方必须停止发布
_applySubTreePerms() { # _applySubTreePerms <目录>
    local d=$1 g
    g=$(ngxWorkerGroup)
    [[ -n "${g}" && -d "${d}" ]] || return 1
    chown -R root:"${g}" "${d}" || return 1
    # 目录 750、文件 640。文件名就是令牌/对等密钥，所以不能用 find -exec chmod（会把全部文件名放到 chmod 的命令行上），
    # 改用一条只带目录路径的递归命令；X 只给目录加执行位，而这里的文件从来不是可执行的
    chmod -R u=rwX,g=rX,o= "${d}"
}
# 目录权限模型:
#   不需要 nginx: ATR_HOME 与 subscribe/ 只有 root 能进入（700）
#   需要 nginx:   ATR_HOME 为 root:<nginx 组> 710（该组只能"穿越"进去读取 www/ 与 subscribe/，不能列目录）；
#                 subscribe/ 为 root:<nginx 组> 750，里面的文件 640。
#   clients/、backup/、tls/、state.json、各核心配置保持各自的 700/600，与此无关。
applyHomePerms() { # applyHomePerms <是否需要 nginx: 0|1>
    local need=${1:-0} g
    mkdir -p "${SUB_DIR}"
    if ((need)); then
        g=$(ngxWorkerGroup)
        [[ -n "${g}" ]] || return 1
        chown root:"${g}" "${ATR_HOME}" || return 1
        chmod 710 "${ATR_HOME}"
        _applySubTreePerms "${SUB_DIR}" || return 1
    else
        chown root:root "${ATR_HOME}" 2>/dev/null
        chown -R root:root "${SUB_DIR}" 2>/dev/null
        chmod 700 "${ATR_HOME}"
        chmod -R go-rwx "${SUB_DIR}" 2>/dev/null
    fi
    return 0
}
# nginx 主配置是否已经是"专用账号"模型（升级前的旧安装不是）
nginxModelCurrent() { grep -q "^user $(ngxWorkerUser);" "${NGX_CONF}" 2>/dev/null; }

stateInit() {
    local rc
    lockAcquire || return 1
    if ! _requireCleanTransaction; then lockRelease; return 1; fi
    _stateInitLocked
    rc=$?
    lockRelease
    return "${rc}"
}
_stateInitLocked() {
    mkdir -p "${ATR_HOME}" "${TLS_DIR}" "${CLIENT_DIR}" "${BACKUP_DIR}" "${SB_DIR}/conf" "${XRAY_DIR}/conf" "${WEB_ROOT}" "${SUB_DIR}"
    chmod 700 "${TLS_DIR}" "${CLIENT_DIR}" "${BACKUP_DIR}" 2>/dev/null
    chmod 755 "${WEB_ROOT}" 2>/dev/null
    # ATR_HOME / subscribe/ 的权限按"当前已生效的状态是否需要 nginx"设置（不需要时只有 root 能进入）。
    # 升级前的旧安装还没有 nginx 专用账号：保持原状，由 applyServices 在重启 nginx 之前统一迁移。
    local need=0
    if stateExists && declare -F stateNeedsNginx >/dev/null && stateNeedsNginx "${ATR_STATE}"; then need=1; fi
    if ((need)); then
        if [[ -n "$(ngxWorkerGroup)" ]] && nginxModelCurrent; then applyHomePerms 1; fi
    else
        applyHomePerms 0
    fi
    if ! stateExists; then
        stateDefault | jq . | atomicWrite "${ATR_STATE}" 600
    fi
}

# S <jq 参数...> <过滤器>  —— 读取当前已生效的 state.json
S() { jq -r "$@" "${ATR_STATE}" 2>/dev/null; }

# ----------------------------- 候选状态(暂存) --------------------------------
NEW_STATE=""
STAGED_BASE=""
# state.json 当前内容的指纹: stagedBegin 记下它，applyStaged 拿到锁后再比对。不一致说明这期间有别的操作提交过，
# 本次基于旧快照构造的整份 state 不能再提交（否则会悄悄覆盖对方刚改的密码、令牌……）。交互提示期间不持有锁，所以用版本校验而不是长期占锁
stateRevision() { [[ -s "${ATR_STATE}" ]] && sha256sum "${ATR_STATE}" 2>/dev/null | awk '{print $1}'; }
stagedBegin() {
    STAGED_BASE=$(stateRevision)
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
stagedDiscard() {
    NEW_STATE=""
    STAGED_BASE=""
}
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
# 订阅 URL 令牌: 每个用户一个独立的随机令牌（存于 state.json）。重置节点密码/UUID 不会改变它；
# 需要收回已泄露的订阅链接时，请单独"更换订阅链接"
subscriptionToken() { S --arg n "$1" '.users[]|select(.name==$n)|.sub_token // empty'; }
userApiSecret() { S --arg n "$1" '.users[]|select(.name==$n)|.api_secret // empty'; }

atrTools() {
    command -v python3 >/dev/null 2>&1 || { echoContent yellow " ---> 此功能需要 Python3，未能验证" >&2; return 2; }
    # Python source uses fd 3 so stdin remains available for JSON/secret input.
    python3 /dev/fd/3 "$@" 3<<'ATR_TOOLS_PY'
"""AnyTLS-Reality v1.3.2 standard-library diagnostics. No automatic core downloads."""
import argparse, contextlib, hashlib, http.client, ipaddress, json, os, pathlib, re
import signal, socket, ssl, subprocess, sys, tempfile, time, urllib.parse

def clean(s):
    return ''.join(c if c.isprintable() else '?' for c in str(s))[:1000]

def url_parts(url):
    if not isinstance(url,str) or len(url)>2048 or re.search(r'[\s\x00-\x1f\x7f\\"\'{};$]',url):
        raise ValueError('网址过长或含空格、控制字符、配置元字符')
    u=urllib.parse.urlsplit(url)
    if u.scheme not in ('http','https') or not u.hostname or u.username or u.password or u.fragment:
        raise ValueError('需要不含用户名密码和片段的 HTTP/HTTPS 网址')
    if u.port is not None and not 1<=u.port<=65535:raise ValueError('端口不合法')
    return u

def site_check(url,allow_private=False):
    report={'url':clean(url),'status':'unknown','risks':[],'warnings':[],
            'limitations':['只代表本 VPS 当前访问结果；长期稳定、域名语义和滥用价值需人工判断'],
            'http_status':None,'bytes':0,'truncated':False,'headers':{},'assets':[]}
    conn=None
    try:
        deadline=time.monotonic()+10
        u=url_parts(url);port=u.port or (443 if u.scheme=='https' else 80)
        # getaddrinfo has no Python timeout. A bounded child prevents a stuck
        # resolver from keeping the interactive assessment alive indefinitely.
        lookup='import socket,sys,json;print(json.dumps(list(dict.fromkeys(x[4][0] for x in socket.getaddrinfo(sys.argv[1],int(sys.argv[2]),type=socket.SOCK_STREAM)))))'
        dns=subprocess.run([sys.executable,'-c',lookup,u.hostname,str(port)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=5,check=True)
        addresses=json.loads(dns.stdout)
        if not addresses:raise ValueError('DNS 没有返回地址')
        if not allow_private and any(not ipaddress.ip_address(a).is_global for a in addresses):
            raise ValueError('远端网址解析到非公网地址；本地文件请使用专用选项')
        # Pin this connection to the checked DNS result, preserving the original TLS SNI.
        remaining=max(.1,deadline-time.monotonic())
        conn=(http.client.HTTPSConnection(u.hostname,port,timeout=remaining,context=ssl.create_default_context())
              if u.scheme=='https' else http.client.HTTPConnection(u.hostname,port,timeout=remaining))
        conn._create_connection=lambda addr,timeout,source_address=None:socket.create_connection((addresses[0],port),timeout,source_address)
        path=urllib.parse.urlunsplit(('', '',u.path or '/',u.query,''))
        conn.request('GET',path,headers={'User-Agent':'Mozilla/5.0','Accept-Encoding':'identity','Connection':'close'})
        response=conn.getresponse();report['http_status']=response.status
        headers={}
        for k,v in response.getheaders():headers.setdefault(k.lower(),[]).append(clean(v))
        selected=['server','via','x-cache','x-served-by','cf-ray','x-nf-request-id','set-cookie','content-security-policy','content-security-policy-report-only','location','content-type','content-length']
        selected += [k for k in headers if k.startswith('x-vercel')]
        report['headers']={k:headers[k] for k in dict.fromkeys(selected) if k in headers}
        body=bytearray()
        while len(body)<=51200:
            remaining=deadline-time.monotonic()
            if remaining<=0:raise TimeoutError('响应超过 10 秒')
            if conn.sock:conn.sock.settimeout(remaining)
            b=response.read1(min(4096,51201-len(body)))
            if not b:break
            body.extend(b)
        report['bytes']=len(body);report['truncated']=len(body)>51200
        if response.status!=200:report['risks'].append('首页不是 HTTP 200')
        if 300<=response.status<400 or 'location' in headers:report['risks'].append('入口存在跳转，建议直接输入最终网址重新检测')
        if ('cloudflare' in ' '.join(headers.get('server',[])).lower() or 'cf-ray' in headers
            or 'x-nf-request-id' in headers or any(k.startswith('x-vercel') for k in headers)
            or ('varnish' in ' '.join(headers.get('via',[])).lower() and 'x-served-by' in headers)):
            report['risks'].append('检测到明显 CDN/托管平台标识')
        elif any(k in headers for k in ('via','x-cache','x-served-by')):report['warnings'].append('存在缓存/代理头，不能仅据此确认 CDN 类型')
        if 'set-cookie' in headers:report['risks'].append('设置 Cookie，不适合作为无会话静态伪装页')
        csp=' '.join(headers.get('content-security-policy',[]))
        if csp:
            if re.search(r'https?://|nonce-|sha(256|384|512)-',csp):report['warnings'].append('CSP 含绝对来源或动态校验，需检查资源加载')
            else:report['warnings'].append('存在 CSP；self/none 等指令不自动判定不合格')
        if report['truncated']:report['risks'].append('首页超过 50 KiB（已截断检测下载）')
        elif len(body)>10240:report['warnings'].append('首页超过优先推荐的 10 KiB')
        html=body.decode('utf-8','replace')
        if re.search(r'cf-chl-|checking your browser|verify you are human|<[^>]*captcha',html,re.I):report['risks'].append('页面可能是人机验证或访问挑战')
        if u.scheme!='https':report['warnings'].append('使用明文 HTTP 上游，优先选择 HTTPS')
        # Only same-origin static assets, no arbitrary download or application paths.
        for item in re.findall(r'(?:src|href)\s*=\s*["\']([^"\']+)',html,re.I):
            absolute=urllib.parse.urljoin(url,item);a=urllib.parse.urlsplit(absolute)
            if (a.scheme,a.netloc)==(u.scheme,u.netloc) and re.search(r'\.(css|js|svg|ico|png|jpe?g|gif|webp|woff2?)$',a.path,re.I):
                if re.fullmatch(r'/[A-Za-z0-9_./%~-]+',a.path) and '..' not in a.path and len(a.path)<200:
                    entry={'path':a.path,'url':urllib.parse.urlunsplit((a.scheme,a.netloc,a.path,a.query,''))}
                    if entry not in report['assets']:report['assets'].append(entry)
            if len(report['assets'])>=16:break
        report['status']='not_recommended' if report['risks'] else 'acceptable_sample'
    except Exception as e:report['error']=clean(type(e).__name__+': '+str(e))
    finally:
        if conn:conn.close()
    return report

def padding_validate(lines):
    if not isinstance(lines,list) or not lines or len(lines)>65:raise ValueError('需要 1-65 行策略数组')
    entries={}
    for line in lines:
        if not isinstance(line,str) or len(line)>2048 or not re.fullmatch(r'(stop|0|[1-9][0-9]*)=[0-9,c-]+',line):raise ValueError('策略行格式不合法')
        key,value=line.split('=',1)
        if key in entries:raise ValueError('策略项重复: '+key)
        entries[key]=value
    if not re.fullmatch(r'[1-9][0-9]*',entries.get('stop','')) or not 1<=int(entries['stop'])<=64:raise ValueError('stop 必须在 1-64')
    stop=int(entries['stop']);total=0
    for key,value in entries.items():
        if key=='stop':continue
        if int(key)>=stop:raise ValueError('包编号必须小于 stop')
        tokens=value.split(',')
        if len(tokens)>32 or tokens[0]=='c' or tokens[-1]=='c':raise ValueError('分包列表不合法')
        subtotal=0
        for i,t in enumerate(tokens):
            if t=='c':
                if key=='0' or (i and tokens[i-1]=='c'):raise ValueError('检查符位置不合法')
                continue
            m=re.fullmatch(r'([0-9]+)-([0-9]+)',t)
            if not m:raise ValueError('需要 min-max 包长范围')
            lo,hi=map(int,m.groups())
            if not 1<=lo<=hi<=16384:raise ValueError('单段包长需满足 1 <= min <= max <= 16384')
            subtotal+=hi
        if key=='0' and (len(tokens)!=1 or subtotal>16384):raise ValueError('认证填充不支持分包')
        if subtotal>65536:raise ValueError('单次策略开销过大')
        total+=subtotal
    if total>262144:raise ValueError('策略总填充上限过大')
    return {'valid':True,'stop':stop,'upper_bytes':total,'sha256':hashlib.sha256('\n'.join(lines).encode()).hexdigest()}

def label(n):
    n=int(n);out=''
    if not 1<=n<=1000000:raise ValueError('标签计数超出范围')
    while n:n,r=divmod(n-1,26);out=chr(65+r)+out
    return out

def endpoint(value):
    if not isinstance(value,str):raise ValueError('目标地址必须是字符串')
    u=urllib.parse.urlsplit('//'+value)
    if not u.hostname or u.username or u.password or u.path or u.query or u.fragment:raise ValueError('目标格式应为 host:port 或 [IPv6]:port')
    host=u.hostname;port=u.port or 443
    try:ipaddress.ip_address(host)
    except ValueError:
        if len(host)>253 or not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?',host):raise ValueError('目标主机名不合法')
    if not 1<=port<=65535:raise ValueError('目标端口不合法')
    return {'host':host,'port':port}

def validate_extras(s):
    if not isinstance(s,dict) or not isinstance(s.get('protocols',{}),dict):raise ValueError('状态结构不合法')
    errors=[];p=s.get('protocols',{})
    for ident,c in p.items():
        if not isinstance(c,dict):raise ValueError('协议参数必须是对象')
        clients=c.get('test_clients',[])
        if not isinstance(clients,list) or any(x not in ('sing-box','xray','mihomo') for x in clients):raise ValueError('客户端验收列表不合法')
        r=c.get('reality') if s.get('reality_mode','shared')=='independent' else s.get('reality',{})
        if ident in ('anytls_reality','vless_reality_vision','vless_reality_grpc','vless_reality_xhttp') and r:
            try:
                endpoint((('['+r.get('dest_host',r['sni'])+']') if ':' in r.get('dest_host',r['sni']) else r.get('dest_host',r['sni']))+':'+str(r.get('dest_port',443)))
                t=r.get('max_time_diff_seconds',70 if r.get('mldsa_seed') and c.get('core')=='xray' else 0)
                if type(t)!=int or not 0<=t<=86400:raise ValueError('时间差需为 0-86400 整数秒')
                tag=r.get('label')
                if tag is not None and not re.fullmatch('[A-Z]{1,5}',str(tag)):raise ValueError('Reality 标签格式不合法')
            except (KeyError,ValueError,TypeError) as e:errors.append(ident+': '+str(e))
        if 'padding_scheme' in c:
            try:padding_validate(c['padding_scheme'])
            except ValueError as e:errors.append(ident+': '+str(e))
    h=p.get('hysteria2',{});m=h.get('masquerade') or {};mode=m.get('mode','off')
    settings=s.get('monitor',{})
    if settings and (not isinstance(settings,dict) or type(settings.get('enabled',False))!=bool or type(settings.get('threshold_mbps',100))!=int or not 1<=settings.get('threshold_mbps',100)<=1000000):errors.append('流量阈值参数不合法')
    try:
        if mode in ('proxy','redirect'):url_parts(m.get('url',''))
        if mode=='file':
            d=pathlib.Path(m.get('directory',''))
            if not d.is_absolute() or not d.is_dir() or not(d/'index.html').is_file():raise ValueError('本地公开目录需要绝对路径与 index.html')
            if not(d/'robots.txt').is_file():raise ValueError('本地公开目录需要 robots.txt（User-agent: * / Disallow: /）')
            if d.resolve() in map(pathlib.Path,('/','/etc','/root','/proc','/sys','/home','/var')):raise ValueError('拒绝公开敏感根目录')
        if mode=='string' and (not isinstance(m.get('content'),str) or len(m['content'].encode())>51200):raise ValueError('固定内容必须为不超过 50 KiB 的字符串')
        if 'gateway_port' in m and (type(m['gateway_port'])!=int or not 1<=m['gateway_port']<=65535 or mode!='proxy'):raise ValueError('伪装网关端口不合法')
        paths=m.get('assets',[])
        if not isinstance(paths,list) or len(paths)>16:raise ValueError('静态资源白名单超限')
        for a in paths:
            u=url_parts(a['url']);base=url_parts(m['url'])
            if (u.scheme,u.netloc)!=(base.scheme,base.netloc) or not re.fullmatch(r'/[A-Za-z0-9_./%~-]+',a['path']) or '..' in a['path']:raise ValueError('资源必须为同源安全静态路径')
    except (ValueError,KeyError,TypeError) as e:errors.append('HY2: '+str(e))
    return errors

def nginx_gateway(s,ca):
    h=s.get('protocols',{}).get('hysteria2',{});m=h.get('masquerade',{})
    if h.get('obfs',{}).get('type') or m.get('mode')!='proxy' or not m.get('gateway_port'):return ''
    errors=validate_extras(s)
    if errors:raise ValueError('; '.join(errors))
    if not pathlib.Path(ca).is_file():raise ValueError('无法找到验证 HTTPS 上游所需的 CA 文件')
    u=url_parts(m['url']);fallback='<html><head><title>Welcome</title></head><body><p>This page is temporarily unavailable.</p></body></html>'
    cache=pathlib.Path(os.environ.get('ATR_TOOLS_NGX_HOME',str(pathlib.Path(os.environ.get('ATR_TOOLS_NGX_LOG','/var/log/nginx/atr-hy2-access.log')).parent)))/'tmp/hy2-cache'
    text='proxy_cache_path '+json.dumps(str(cache))+' levels=1:2 keys_zone=atr_hy2_cache:1m max_size=8m inactive=30m use_temp_path=off;\n'
    text+='''# Global HTTP request limits; current sing-box does NOT forward trusted client IP.
limit_req_zone $server_name zone=atr_hy2_global:1m rate=5r/s;
limit_conn_zone $server_name zone=atr_hy2_connections:1m;
server {
 listen 127.0.0.1:%d;
 server_name _;
 server_tokens off;
 limit_req zone=atr_hy2_global burst=10 nodelay;
 limit_req_status 429;
 limit_conn atr_hy2_connections 8;
 limit_conn_status 429;
 limit_rate 64k;
 client_max_body_size 1k;
 access_log %s;
 add_header X-Robots-Tag "noindex, nofollow" always;
 location = /robots.txt { default_type text/plain; return 200 "User-agent: *\\nDisallow: /\\n"; }
 location @atr_hy2_fallback { default_type text/html; return 200 '%s'; }
'''%(m['gateway_port'],json.dumps(os.environ.get('ATR_TOOLS_NGX_LOG','/var/log/nginx/atr-hy2-access.log')),fallback)
    for path,url in [('/',m['url'])]+[(a['path'],a['url']) for a in m.get('assets',[])]:
        host=url_parts(url).hostname
        text+=''' location = %s {
  if ($request_method !~ ^(GET|HEAD)$) { return 405; }
  proxy_pass %s;
  proxy_set_header Host %s;
  proxy_set_header Cookie "";
  proxy_set_header Authorization "";
  proxy_set_header X-Forwarded-For "";
  proxy_ssl_server_name on;
  proxy_ssl_name %s;
  proxy_ssl_verify on;
  proxy_ssl_verify_depth 5;
  proxy_ssl_trusted_certificate %s;
  proxy_cache atr_hy2_cache;
  proxy_cache_key %s;
  proxy_cache_valid 200 1m;
  proxy_cache_lock on;
  proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
  proxy_connect_timeout 5s;
  proxy_read_timeout 10s;
  proxy_intercept_errors on;
  error_page 301 302 303 307 308 403 500 502 503 504 = @atr_hy2_fallback;
 }
'''%(path,json.dumps(url if url_parts(url).query else url+'?'),json.dumps(url_parts(url).netloc),json.dumps(host),json.dumps(ca),json.dumps(url))
    return text+' location / { return 404; }\n}\n'

def node_probe(node,core,binary,scope,address=None,timeout=12):
    result={'status':'unknown','core':core,'scope':scope,'authenticated_transfer':False,
            'external_ingress_verified':False,'reason':''}
    if not binary or not os.path.isfile(binary) or not os.access(binary,os.X_OK):result.update(status='unverified',reason='缺少指定客户端核心');return result
    endpoint_address=address or ('127.0.0.1' if scope=='loopback' else node['server'])
    if core=='sing-box' and node.get('singbox') is None or core=='mihomo' and node.get('mihomo') is None:
        result.update(status='not_applicable',reason='客户端不支持该协议/传输');return result
    if core=='xray' and node.get('proto') not in ('vless_reality_vision','vless_reality_grpc','vless_reality_xhttp'):
        result.update(status='not_applicable',reason='Xray 探针不支持此协议');return result
    result['binary_sha256']=hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest()
    v=subprocess.run([binary,'-v'] if core=='mihomo' else [binary,'version'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=5)
    result['version']=clean(v.stdout.decode(errors='replace').splitlines()[0] if v.stdout else '')
    processes=[]
    with tempfile.TemporaryDirectory(prefix='atr-client-probe.') as td:
        os.chmod(td,0o700);root=pathlib.Path(td);sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
        # All probe SOCKS listeners require ephemeral authentication.
        import secrets
        user='probe';password=secrets.token_hex(16);n=dict(node)
        if core=='sing-box':
            outbound=dict(n['singbox']);outbound['server']=endpoint_address
            cfg={'log':{'level':'warn'},'inbounds':[{'type':'socks','listen':'127.0.0.1','listen_port':port,'users':[{'username':user,'password':password}]}], 'outbounds':[outbound],'route':{'final':outbound['tag']}}
            check=[binary,'check','-c'];start=[binary,'run','-c']
        elif core=='mihomo':
            proxy=dict(n['mihomo']);proxy['server']=endpoint_address
            cfg={'mixed-port':port,'bind-address':'127.0.0.1','allow-lan':False,'authentication':[user+':'+password], 'mode':'rule','log-level':'warning','proxies':[proxy],'rules':['MATCH,'+proxy['name']]}
            check=[binary,'-t','-f'];start=[binary,'-d',td,'-f']
        else:
            network={'vless_reality_vision':'tcp','vless_reality_grpc':'grpc','vless_reality_xhttp':'xhttp'}[n['proto']]
            reality={'serverName':n['sni'],'publicKey':n['pbk'],'shortId':n['sid'],'fingerprint':'chrome'}
            if n.get('pqv'):reality['mldsa65Verify']=n['pqv']
            stream={'network':network,'security':'reality','realitySettings':reality}
            if network=='grpc':stream['grpcSettings']={'serviceName':'grpc'}
            if network=='xhttp':stream['xhttpSettings']={'host':n['host'],'path':n['path'],'mode':'auto'}
            account={'id':n['uuid'],'encryption':'none'}
            if network=='tcp':account['flow']='xtls-rprx-vision'
            cfg={'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':port,'protocol':'socks','settings':{'auth':'password','accounts':[{'user':user,'pass':password}]}}],
                 'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':endpoint_address,'port':n['port'],'users':[account]}]},'streamSettings':stream}]}
            check=[binary,'run','-test','-c'];start=[binary,'run','-c']
        config=root/'client.json';config.write_text(json.dumps(cfg));config.chmod(0o600)
        try:
            q=subprocess.run(check+[str(config)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=8)
            if q.returncode:result.update(status='failed',reason='客户端配置未通过原生校验');return result
            with (root/'client.log').open('wb') as log:
                p=subprocess.Popen(start+[str(config)],stdout=log,stderr=log,**({'start_new_session':True} if os.name!='nt' else {'creationflags':subprocess.CREATE_NEW_PROCESS_GROUP}));processes.append(p)
                time.sleep(.8)
                # curl credentials stay in a private config, never process arguments.
                curl=root/'curl.conf'
                url=os.environ.get('ATR_TOOLS_TEST_URL','https://www.cloudflare.com/cdn-cgi/trace')
                curl.write_text('proxy = "socks5h://127.0.0.1:%d"\nproxy-user = "%s:%s"\nurl = %s\nmax-time = %d\nsilent\nshow-error\n'%(port,user,password,json.dumps(url),timeout));curl.chmod(0o600)
                q=subprocess.run(['curl','-q','--config',str(curl),'--noproxy','','--output',str(root/'body'),'--write-out','%{http_code}'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout+2)
                body=(root/'body').read_bytes() if(root/'body').exists() else b''
                expected=os.environ.get('ATR_TOOLS_TEST_NONCE')
                good=q.returncode==0 and q.stdout.decode()=='200' and (expected.encode() in body if expected else b'ip=' in body)
                result.update(status='passed' if good else 'failed',authenticated_transfer=good,reason='认证转发通过' if good else '未取得预期测试响应')
                # --scope external is an explicit assertion by the operator running on another host.
                result['external_ingress_verified']=False
                result['external_execution_claimed']=bool(good and scope=='external' and endpoint_address not in ('127.0.0.1','::1'))
                if scope=='external':result['external_scope']='调用者声明从外部主机执行；报告不自动证明执行位置'
        except subprocess.TimeoutExpired:result.update(status='failed',reason='探针超时')
        finally:
            for p in processes:
                with contextlib.suppress(ProcessLookupError):
                    if os.name=='nt':p.terminate()
                    else:os.killpg(p.pid,signal.SIGTERM)
                try:p.wait(3)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        if os.name=='nt':p.kill()
                        else:os.killpg(p.pid,signal.SIGKILL)
                    p.wait()
    return result

def monitor(state,home):
    settings=state.get('monitor',{});now=time.time();sample={'time':now,'rx':0,'tx':0}
    for path in pathlib.Path('/sys/class/net').glob('*/statistics/rx_bytes'):
        if path.parents[1].name=='lo':continue
        sample['rx']+=int(path.read_text());sample['tx']+=int(path.with_name('tx_bytes').read_text())
    f=pathlib.Path(home)/'monitor.sample.json';previous=json.loads(f.read_text()) if f.exists() else None
    result={'scope':'宿主网卡总流量（包括其他服务），非 HY2 用户流量','sample':sample,'alert':False}
    if previous and now>previous['time']:
        delta=now-previous['time'];rate=max(0,sample['rx']-previous['rx'],sample['tx']-previous['tx'])*8/delta/1e6
        result.update(peak_direction_mbps=round(rate,3),threshold_mbps=settings.get('threshold_mbps',100),alert=rate>=settings.get('threshold_mbps',100))
    tmp=f.with_name(f.name+'.new');fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as out:json.dump(sample,out)
    os.replace(tmp,f)
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('command',choices=['site-check','endpoint-url','site-show','padding','label','endpoint','validate','nginx','probe','monitor'])
    parser.add_argument('value',nargs='?');parser.add_argument('--allow-private',action='store_true',help='仅隔离测试使用，不由交互安装启用')
    parser.add_argument('--core',choices=['sing-box','xray','mihomo']);parser.add_argument('--binary');parser.add_argument('--scope',choices=['loopback','server-return','external'],default='loopback');parser.add_argument('--address');parser.add_argument('--ca',default='/etc/ssl/certs/ca-certificates.crt');parser.add_argument('--home')
    a=parser.parse_args();cmd=a.command
    try:
        if cmd=='endpoint-url':url_parts(a.value);return 0
        elif cmd=='site-check':r=site_check(a.value,a.allow_private)
        elif cmd=='site-show':
            r=json.load(sys.stdin);print('检测结果: '+r['status']);print('HTTP: %s，已读正文: %s 字节%s'%(r['http_status'],r['bytes'],'（截断）' if r['truncated'] else ''))
            for k,values in r['headers'].items():
                for v in values:print(clean(k+': '+v))
            for k in ('risks','warnings','limitations'):
                for v in r[k]:print(clean(k+': '+v))
            if r.get('error'):print(clean(r['error']))
            return 0
        elif cmd=='padding':r=padding_validate(json.load(sys.stdin))
        elif cmd=='label':print(label(a.value));return 0
        elif cmd=='endpoint':r=endpoint(a.value)
        elif cmd=='validate':
            errors=validate_extras(json.load(sys.stdin));print('\n'.join(errors));return 1 if errors else 0
        elif cmd=='nginx':print(nginx_gateway(json.load(sys.stdin),a.ca));return 0
        elif cmd=='probe':r=node_probe(json.load(sys.stdin),a.core,a.binary,a.scope,a.address)
        elif cmd=='monitor':r=monitor(json.load(sys.stdin),a.home)
        print(json.dumps(r,ensure_ascii=False))
        if cmd=='probe':return 0 if r['status']=='passed' else (2 if r['status'] in ('unverified','not_applicable','unknown') else 1)
        return 0
    except Exception as e:
        print(json.dumps({'error':clean(str(e))},ensure_ascii=False));return 2

if __name__=='__main__':
    def stop(*args):raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,stop)
    try:raise SystemExit(main())
    except KeyboardInterrupt:raise SystemExit(130)
ATR_TOOLS_PY
}

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
    (if ($P.hysteria2.masquerade.gateway_port // 0)>0 and ($ports|any(.net=="tcp" and .port==$P.hysteria2.masquerade.gateway_port)) then "HY2 网关端口与 TCP 入站冲突" else empty end),
    # 端口范围
    ($ports[] | select((.port | type) != "number" or .port < 1 or .port > 65535) | "端口不合法: \(.who)=\(.port)"),
    # 端口冲突（同协议类型下端口不得重复）
    ($ports | group_by([.net, .port])[] | select(length > 1) | "端口冲突: \(map(.who) | join(", ")) 同时使用 \(.[0].net)/\(.[0].port)"),
    # HY2 bandwidth / obfs / masquerade
    ($P.hysteria2 // {} | . as $h
      | (if (["auto","fixed"]|index($h.bandwidth_mode // "auto"))==null then "HY2 带宽模式不合法" else empty end),
        ([.up_mbps,.down_mbps][] | select(.!=null) | select(type!="number" or .<1 or .>1000000 or floor!=.) | "HY2 固定带宽需为 1-1000000 的整数"),
        (if (.obfs // null)!=null and ((.obfs.type!="salamander") or (.obfs.password|type)!="string" or (.obfs.password|length)<8 or (.obfs.password|length)>256 or (.obfs.password|test("[[:cntrl:]]"))) then "HY2 混淆参数不合法" else empty end),
        (if (["off","redirect","proxy","file","string"]|index($h.masquerade.mode // "off"))==null then "HY2 伪装模式不合法" else empty end)),
    # 跳跃范围必须互不重叠，不能覆盖任何 UDP 主端口（包括自身）
    ($P|to_entries[]|select((.value.hop // "")!="")|. as $x
      | if (["tuic","hysteria2"]|index($x.key))==null or (.value.hop|type)!="string" or (.value.hop|test("^[0-9]{5}-[0-9]{5}$")|not)
        then "跳跃范围格式不合法"
        else (.value.hop|split("-")|map(tonumber)) as $r
          | (if $r[0]<30000 or $r[1]>40000 or $r[0]>=$r[1] then "跳跃范围应为 30000-40000 且起点小于终点" else empty end),
            ($ports[]|select(.net=="udp" and .port>=$r[0] and .port<=$r[1])|"跳跃范围覆盖 UDP 主端口"),
            ($P|to_entries[]|select(.key!=$x.key and (.value.hop // "")!="")|(.value.hop|split("-")|map(tonumber?)) as $q
             |select(($q|length)==2 and $q[0]<=$r[1] and $q[1]>=$r[0])|"跳跃范围相互重叠") end),
    # 至少一个用户
    (if ($P | length) > 0 and ($U | length) == 0 then "没有用户" else empty end),
    # 用户名唯一
    ($U | group_by(.name)[] | select(length > 1) | "用户名重复: \(.[0].name)"),
    # Socks5 入站必须有来源 IP 白名单: 空数组会被 sing-box 当作"不限制来源"，等于对所有来源放行
    (if (.routing.socks5_in.port // null) != null and ((.routing.socks5_in.allow_ips // []) | length) == 0
     then "Socks5 入站的来源 IP 白名单为空（空白名单等于允许所有来源）；请在 11.分流工具→Socks5入站→3 里重新设置" else empty end),
    # 出口访问模式只能是 空(未选择) / public / full
    ((.egress.mode // "") as $m | if (["", "public", "full"] | index($m)) != null then empty else "出口访问模式不合法: \($m)" end),
    # 出口访问模式里的本机地址（探测到的公网地址、管理员手动补充的地址）只能是 IP / CIDR
    ([(.egress.public_ips // [])[], (.egress.extra_ips // [])[]][]
       | select((type != "string") or ((test("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2})?$") or test("^[0-9A-Fa-f:]+(/[0-9]{1,3})?$")) | not))
       | "出口访问模式的本机地址不合法: \(.)"),
    # 对等密钥会被写进 nginx 配置作为路径片段：只能是空(未启用)或 16-64 位字母数字
    ((.nginx.subscribe.peer_key // "") as $k | if $k == "" or ($k | test("^[A-Za-z0-9]{16,64}$")) then empty else "对等密钥格式不合法（需要 16-64 位字母数字）" end)
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
    local mode id profile ids f
    mode=$(jq -r '.reality_mode // "shared"' <<<"${st}")
    [[ "${mode}" == shared || "${mode}" == independent ]] || echo "Reality 配置方式不合法: ${mode}"
    if [[ "${reg_reality}" != "0" ]]; then
        ids=$(jq -r --argjson st "${st}" '.[]|select(.reality==true)|.id|select(. as $i | $st.protocols[$i] != null)' <<<"${PROTO_REGISTRY}")
        while read -r id; do
            [[ -n "${id}" ]] || continue
            profile=$(jq --arg id "${id}" 'if (.reality_mode // "shared") == "independent" then .protocols[$id].reality // {} else .reality // {} end' <<<"${st}")
            for f in sni private_key public_key short_id; do
                [[ -n "$(jq -r --arg f "${f}" '.[$f] // ""' <<<"${profile}")" ]] || echo "Reality 参数缺失: ${id}.${f}"
            done
            isDomainName "$(jq -r '.sni // ""' <<<"${profile}")" || echo "Reality SNI 不合法: ${id}"
            isPort "$(jq -r '.dest_port // 443' <<<"${profile}")" || echo "Reality 目标端口不合法: ${id}"
            if [[ -n "$(jq -r '.private_key // ""' <<<"${profile}")" ]]; then
                verifyRealityKeypair "$(jq -r '.private_key' <<<"${profile}")" "$(jq -r '.public_key // ""' <<<"${profile}")" || echo "Reality 密钥不匹配或无法校验: ${id}"
            fi
        done <<<"${ids}"
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
    if command -v python3 >/dev/null 2>&1; then
        local extra_errors extra_rc=0
        extra_errors=$(atrTools validate <<<"${st}") || extra_rc=$?
        [[ -z "${extra_errors}" ]] || printf '%s\n' "${extra_errors}"
        if ((extra_rc)) && [[ -z "${extra_errors}" ]]; then echo "附加校验器异常，未通过校验"; fi
    elif jq -e '[.protocols[]?|select(.padding_scheme!=null or .reality.dest_host!=null or .masquerade.gateway_port!=null)]|length>0' <<<"${st}" >/dev/null; then
        echo "无法校验新参数：缺少 Python3"
    fi
    local hy2 mode url
    hy2=$(jq -c '.protocols.hysteria2 // {}' <<<"${st}")
    mode=$(jq -r '.masquerade.mode // "off"' <<<"${hy2}")
    if [[ "${mode}" == redirect || "${mode}" == proxy ]]; then
        url=$(jq -r '.masquerade.url // ""' <<<"${hy2}")
        hy2URLValid "${url}" || echo "HY2 伪装目标 URL 不合法"
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
    stagedEdit --arg n "${name}" --arg u "${uuid}" --arg p "${pass}" --arg t "$(newSubToken)" --arg a "$(newApiSecret)" '.users += [{name:$n,uuid:$u,password:$p,sub_token:$t,api_secret:$a}]'
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

# 数字格式不是 stable 属性；所有候选都必须核对 GitHub 正式发布元数据。
_stableTagFromRelease() {
    local tag
    tag=$(jq -er 'select(type=="object" and .draft==false and .prerelease==false) | .tag_name | select(type=="string")') || return 1
    isStableVersion "${tag}" || return 1
    printf 'v%s\n' "${tag#v}"
}
verifyStableReleaseTag() { # <core> <tag>
    local core=$1 tag=$2 got
    isStableVersion "${tag}" || return 1
    tag="v${tag#v}"
    got=$(curl -fsSL -m 15 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$(coreRepo "${core}")/releases/tags/${tag}" 2>/dev/null | _stableTagFromRelease) || return 1
    [[ "${got}" == "${tag}" ]]
}
coreRequestedVersion() {
    case "$1" in
    sing-box) printf '%s' "${ATR_SINGBOX_VERSION:-}" ;;
    xray) printf '%s' "${ATR_XRAY_VERSION:-}" ;;
    *) return 1 ;;
    esac
}

# 解析最新正式稳定版；显式固定版本也要验证发布属性及下载摘要。
resolveLatestVersion() { # resolveLatestVersion <core>
    local core=$1 repo tag="" eff="" pinned
    repo=$(coreRepo "${core}")
    pinned=$(coreRequestedVersion "${core}") || return 1
    if [[ -n "${pinned}" ]]; then
        if verifyStableReleaseTag "${core}" "${pinned}"; then
            _setResolveSource "管理员固定版本"
            printf 'v%s\n' "${pinned#v}"
            return 0
        fi
        echoContent red " ---> 固定版本格式无效、不是正式稳定发布，或无法核实元数据: ${pinned}" >&2
        return 1
    fi
    tag=$(curl -fsSL -m 15 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | _stableTagFromRelease)
    if [[ -n "${tag}" ]]; then
        _setResolveSource "GitHub API（正式稳定发布）"
        printf '%s\n' "${tag}"
        return 0
    fi
    # 网页 latest 可能指向没有 beta/rc 后缀的 Pre-release，必须再查该 tag 的正式发布属性。
    eff=$(curl -fsSIL -m 15 -o /dev/null -w '%{url_effective}' "$(ghURL "https://github.com/${repo}/releases/latest")" 2>/dev/null)
    tag=${eff##*/}
    if [[ "${eff}" == *"/releases/tag/"* ]] && verifyStableReleaseTag "${core}" "${tag}"; then
        _setResolveSource "重定向探测 + 正式发布核验"
        printf 'v%s\n' "${tag#v}"
        return 0
    fi
    if tag=$(askManualVersion "${core}") && verifyStableReleaseTag "${core}" "${tag}"; then
        _setResolveSource "手动指定 + 正式发布核验"
        printf '%s\n' "${tag}"
        return 0
    fi
    echoContent red " ---> 无法核实正式稳定发布，已中止。核验需要能直连 api.github.com（不经过 GITHUB_PROXY，纯 IPv6 或被限流的机器会失败）；请稍后重试，或用 ATR_XRAY_VERSION / ATR_SINGBOX_VERSION 指定版本（同样需要核验）" >&2
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

fetchExpectedSha256() { # fetchExpectedSha256 <core> <tag> <资产名>
    # 取得资产的期望 sha256（取不到返回 1）。
    # 优先用 GitHub API 的 assets[].digest: api.github.com 不经过 GITHUB_PROXY，所以即使下载代理不可信，
    # 校验值仍来自独立渠道。ATR_EXPECTED_SHA256 可手动指定（自行从可信渠道核对后得到）。
    local core=$1 tag=$2 asset=$3 d i repo
    if [[ -n "${ATR_EXPECTED_SHA256:-}" ]]; then
        d=${ATR_EXPECTED_SHA256,,}
        if [[ "${d}" =~ ^[0-9a-f]{64}$ ]]; then
            echo "${d}"
            return 0
        fi
        echoContent red " ---> ATR_EXPECTED_SHA256 不是合法的 64 位十六进制 SHA256" >&2
        return 1
    fi
    repo=$(coreRepo "${core}")
    for i in 1 2 3; do
        d=$(curl -fsSL -m 15 "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>/dev/null |
            jq -r --arg n "${asset}" '.assets[]|select(.name==$n)|.digest // empty' 2>/dev/null | sed 's/^sha256://')
        if [[ "${d}" =~ ^[0-9a-f]{64}$ ]]; then
            echo "${d}"
            return 0
        fi
        ((i < 3)) && sleep 2
    done
    # API 没有给出摘要（旧版本资产，或被限流）: Xray 另有官方 .dgst 文件。但只有在没配置下载代理时才采用，
    # 否则 .dgst 与压缩包走同一个代理，恶意代理可以同时替换两者，校验就失去意义
    if [[ "${core}" == "xray" && -z "${GITHUB_PROXY}" ]]; then
        d=$(curl -fsSL -m 15 "https://github.com/${REPO_XRAY}/releases/download/${tag}/${asset}.dgst" 2>/dev/null |
            awk '/^SHA2-256=/{print $2; exit}')
        if [[ "${d}" =~ ^[0-9a-f]{64}$ ]]; then
            echo "${d}"
            return 0
        fi
    fi
    return 1
}

# ----------------------------- 安装二进制 ------------------------------------
# installCoreBinary <core> <tag>  —— 下载、校验、验证可运行后原子替换；旧版本保留为 .prev
installCoreBinary() {
    local rc
    lockAcquire || return 1
    if ! _requireCleanTransaction; then lockRelease; return 1; fi
    _installCoreBinaryLocked "$@"
    rc=$?
    lockRelease
    return "${rc}"
}
_installCoreBinaryLocked() {
    local core=$1 tag=$2 ver=${2#v} work url asset newbin dest expected actual
    _requireCleanTransaction || return 1
    if ! verifyStableReleaseTag "${core}" "${tag}"; then
        echoContent red " ---> 无法确认 ${tag} 是正式稳定发布，已拒绝下载/执行（核验需要能直连 api.github.com）"
        return 1
    fi
    tag="v${tag#v}"
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

    # 先取校验值: 取不到就不必下载几十 MB 再中止，也保证任何下载物在被解压/执行之前就已完成校验
    expected=$(fetchExpectedSha256 "${core}" "${tag}" "${asset}")
    if [[ -z "${expected}" ]]; then
        if [[ "${ATR_ALLOW_UNVERIFIED:-0}" == "1" ]]; then
            echoContent red " ---> 警告: 未能取得官方校验值，按 ATR_ALLOW_UNVERIFIED=1 的要求跳过校验，下载内容的完整性与来源无法保证！"
        else
            echoContent red " ---> 未能取得官方 SHA256 校验值，已中止安装（不会运行未经校验的程序）"
            echoContent yellow "      常见原因: GitHub API 限流，或 API 返回的数据里没有这个文件的摘要，请稍后重试。"
            echoContent yellow "      也可以先从可信渠道核对该文件的 SHA256，再用 ATR_EXPECTED_SHA256=<64位十六进制> 重新运行"
            echoContent yellow "      （它只补充摘要，不能代替正式发布核验：仍然需要能直连 api.github.com）。"
            rm -rf "${work}"
            return 1
        fi
    fi

    echoContent green " ---> 下载 $(coreLabel "${core}") ${tag}"
    if ! download "${url}" "${work}/${asset}"; then
        echoContent red " ---> 下载失败: ${url}"
        rm -rf "${work}"
        return 1
    fi

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

    if [[ -f "${dest}" ]] && ! cp -p "${dest}" "${dest}.prev"; then
        echoContent red " ---> 无法备份旧内核，已中止替换"
        rm -rf "${work}"
        return 1
    fi
    if ! { cp -f "${newbin}" "${dest}.new" && chmod 755 "${dest}.new" && mv -f "${dest}.new" "${dest}"; }; then
        echoContent red " ---> 无法替换内核文件，未报告安装成功"
        rm -f "${dest}.new"
        rm -rf "${work}"
        return 1
    fi
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
            warnKnownCoreIssue "${core}" "${tag}"
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
# 回退同样采用原子替换，避免向仍在运行的可执行文件直接 cp。
_restorePreviousCore() {
    local bin
    bin=$(coreBin "$1")
    [[ -f "${bin}.prev" ]] || { echoContent red " ---> 没有旧内核备份可恢复"; return 1; }
    atomicWrite "${bin}" 755 <"${bin}.prev" && cmp -s "${bin}.prev" "${bin}"
}
# 已知有问题的内核版本组合（只提示，不阻止）。按版本号写死的条目不会过时出错，最多只是不再相关。每行: <core>|<tag>|<说明>
ATR_KNOWN_CORE_ISSUES="xray|v26.10.21|作为 Reality 服务端时与 sing-box 1.14.x 客户端握手失败（reality verification failed；2026-10 在 sing-box 1.14.2、1.14.4 上实测）。同核心自检使用 Xray；请为 Xray 节点选择兼容客户端，并验证实际使用的客户端组合"
warnKnownCoreIssue() { # warnKnownCoreIssue <core> <tag>
    local c t msg
    while IFS='|' read -r c t msg; do
        [[ -n "${c}" && "${c}" == "$1" && "${t}" == "v${2#v}" ]] && echoContent yellow " ---> 已知问题: $(coreLabel "$1") ${t} ${msg}"
    done <<<"${ATR_KNOWN_CORE_ISSUES}"
    return 0
}
# 换内核后用该核心自身做真实客户端握手；失败时恢复旧内核。Naive 无自动探针。
# 只能证明当前同版本自洽，不能证明旧版或其他核心客户端仍兼容。
_checkCoreInterop() {
    local core=$1 id user rc ids fail=0 unverified=()
    stateExists || return 1
    ids=$(installedProtocolsOfCore "${core}") || return 1
    [[ -n "${ids}" ]] || return 0
    user=$(userNames | head -n 1)
    [[ -n "${user}" ]] || return 1
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        rc=0
        selfCheckProtocol "${id}" "${user}" || rc=$?
        case "${rc}" in
        0) ;;
        2) unverified+=("$(protoName "${id}")") ;;
        *) fail=1 ;;
        esac
    done <<<"${ids}"
    ((fail == 0)) || return 1
    if ((${#unverified[@]})); then
        echoContent yellow " ---> 未自动验证（只确认了服务启动与端口监听，请用实际客户端确认）: ${unverified[*]}"
    fi
    selfCheckSelectedClients "${core}" || return 1
    return 0
}
# 该核心承载、但无法用本机 sing-box 自动验证的协议名（判断条件与 selfCheckProtocol 的跳过条件相同）
coreUncheckableNames() { # coreUncheckableNames <core>
    local id user rc names=()
    stateExists || return 0
    user=$(userNames | head -n 1)
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        rc=0
        selfCheckSupported "${id}" "${user}" || rc=$?
        ((rc == 1 || rc == 2)) && names+=("$(protoName "${id}")") # rc 3（生成出错）不是"不支持"，换内核后会按失败处理
    done < <(installedProtocolsOfCore "$1")
    ((${#names[@]} == 0)) || printf '%s\n' "${names[*]}"
}
# 换内核之前说明哪些协议不能自动验证（在拿锁之前、确认之前调用）
noteUncheckableProtocols() { # noteUncheckableProtocols <core>
    local names
    names=$(coreUncheckableNames "$1")
    [[ -n "${names}" ]] || return 0
    echoContent yellow " ---> 以下协议无法用本机 sing-box 自动做互通验证，换内核后只能确认服务启动与端口监听: ${names}"
    echoContent yellow "      其余协议握手失败会自动恢复旧内核；上面这些请换内核后用实际客户端确认"
}
_upgradeCoreLocked() {
    local core=$1 want=${2:-} tag conf out reason="" wasActive=0 triedRestart=0
    serviceActive "$(coreUnit "${core}")" && wasActive=1
    # 版本的解析与确认都在 upgradeCore 里、拿锁之前完成（锁内不提示）
    if [[ -z "${want}" ]]; then
        echoContent red " ---> 内部错误: 未指定内核版本"
        return 1
    fi
    tag=${want}
    installCoreBinary "${core}" "${tag}" || return 1
    conf=$(coreConf "${core}")
    if [[ -f "${conf}" ]]; then
        if ! out=$(coreCheckConfig "${core}"); then
            reason="新版本无法加载现有配置"
            printf '%s\n' "${out}"
        elif serviceActive "$(coreUnit "${core}")" || [[ -f "${ATR_SYSTEMD_DIR}/$(coreUnit "${core}").service" ]]; then
            triedRestart=1
            if ! restartCoreChecked "${core}"; then
                reason="新版本未能正常启动"
            elif ! _checkCoreInterop "${core}"; then
                reason="新版本互通检查未通过"
            fi
        fi
    fi
    if [[ -n "${reason}" ]]; then
        echoContent red " ---> ${reason}，正在恢复旧内核"
        if ! _restorePreviousCore "${core}"; then
            echoContent red " ---> 恢复旧内核失败，请立即检查内核文件和服务；未报告升级成功"
            return 1
        fi
        if ((wasActive || triedRestart)) && ! restartCoreChecked "${core}"; then
            echoContent red " ---> 已恢复旧内核文件，但旧服务未恢复正常"
        else
            echoContent yellow " ---> 已恢复旧内核；本次升级失败，兼容性仍需核实"
        fi
        return 1
    fi
    echoContent green " ---> $(coreLabel "${core}") 已更新到 $(coreVersion "${core}")"
}

upgradeCore() {
    local core=$1 want=${2:-} rc cur
    # 网络探测和人工确认不持有事务锁；选定候选后才锁定，锁内重新读取当前配置和版本。
    # 指定了版本（rollbackCore）时，说明与确认由调用方完成
    if [[ -z "${want}" ]]; then
        want=$(resolveLatestVersion "${core}") || return 1
        cur=$(coreVersion "${core}")
        echoContent green " ---> 当前版本: ${cur:-未安装}   候选稳定版: ${want}（来源: $(lastResolveSource)）"
        warnKnownCoreIssue "${core}" "${want}"
        noteUncheckableProtocols "${core}"
        if [[ -n "${cur}" && "v${cur#v}" == "${want}" ]]; then
            confirm "当前版本与候选相同，是否重新安装？" n || return 0
        else
            confirm "是否安装 ${want}（可自动验证的协议握手失败时恢复旧内核）？" y || return 0
        fi
    fi
    lockAcquire || return 1
    if ! _requireCleanTransaction; then
        lockRelease
        return 1
    fi
    _upgradeCoreLocked "${core}" "${want}"
    rc=$?
    lockRelease
    return "${rc}"
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
    warnKnownCoreIssue "${core}" "${chosen}"
    noteUncheckableProtocols "${core}"
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
# TLS 两文件导入使用持久撤销日志。标记删除并同步之前，操作尚未提交；
# SIGKILL 后下一次 atr（以及开机依赖单元）恢复原来的文件。不是双文件原子 rename。
_tlsRestoreLocked() {
    local st domain hadCrt hadKey f live had mode rc=0
    [[ -e "${TLS_TXN_MARK}" || -L "${TLS_TXN_MARK}" ]] || return 0
    st=$(cat "${TLS_TXN_MARK}" 2>/dev/null) || return 1
    # 恢复依据只能指向本机私有 TLS 暂存目录，不能接受任意路径或符号链接。
    if [[ "${st%/*}" != "${TLS_DIR}" || ! "${st##*/}" =~ ^\.import\.[A-Za-z0-9]+$ || ! -d "${st}" || -L "${st}" ]]; then
        echoContent red " ---> 证书事务标记不合法，已保留恢复依据: ${TLS_TXN_MARK}"
        return 1
    fi
    domain=$(jq -er '.domain' "${st}/manifest.json") || return 1
    isDomainName "${domain}" || return 1
    hadCrt=$(jq -er '.had_crt | select(. == 0 or . == 1)' "${st}/manifest.json") || return 1
    hadKey=$(jq -er '.had_key | select(. == 0 or . == 1)' "${st}/manifest.json") || return 1
    for f in crt key; do
        live="${TLS_DIR}/${domain}.${f}"; had=${hadCrt}; mode=644
        [[ "${f}" == key ]] && had=${hadKey} && mode=600
        if ((had)); then
            { atomicWrite "${live}" "${mode}" <"${st}/old.${f}" && cmp -s "${st}/old.${f}" "${live}"; } || rc=1
        else
            _removeLive "${live}" || rc=1
        fi
    done
    if ((rc == 0)) && sync -f "${TLS_DIR}" && _removeLive "${TLS_TXN_MARK}" && sync -f "${ATR_HOME}"; then
        rm -rf "${st}"
        atrLog "TLS transaction recovered (${domain})"
        return 0
    fi
    echoContent red " ---> 证书恢复没有完成，标记和备份已保留；已拒绝新的修改。请处理后执行 ${ATR_CMD} recover"
    return 1
}

recoverTLSIfNeeded() {
    [[ -e "${TLS_TXN_MARK}" || -L "${TLS_TXN_MARK}" ]] || return 0
    local rc
    lockAcquire || return 1
    _tlsRestoreLocked; rc=$?
    lockRelease
    return "${rc}"
}

tlsImportCustom() { # tlsImportCustom <域名> <crt 路径> <key 路径>
    local domain=$1 crt=$2 key=$3 st hadCrt=0 hadKey=0 rc=0
    local dcrt="${TLS_DIR}/${domain}.crt" dkey="${TLS_DIR}/${domain}.key"
    isDomainName "${domain}" || return 1
    if ! tlsValidate "${crt}" "${key}" "${domain}"; then
        echoContent red " ---> 证书不可用: ${TLS_ERR}"
        return 1
    fi
    mkdir -p "${TLS_DIR}" || return 1
    lockAcquire || return 1
    if ! _requireCleanTransaction; then lockRelease; return 1; fi
    st=$(mktemp -d "${TLS_DIR}/.import.XXXXXX") || { lockRelease; return 1; }
    [[ -e "${dcrt}" || -L "${dcrt}" ]] && hadCrt=1
    [[ -e "${dkey}" || -L "${dkey}" ]] && hadKey=1
    # 完整准备并核对新旧文件，所有数据同步成功之前不碰 live 文件。
    if ! { atomicWrite "${st}/new.crt" 644 <"${crt}" && cmp -s "${crt}" "${st}/new.crt" &&
           atomicWrite "${st}/new.key" 600 <"${key}" && cmp -s "${key}" "${st}/new.key" &&
           tlsValidate "${st}/new.crt" "${st}/new.key" "${domain}"; } ||
       ! { ((hadCrt == 0)) || { atomicWrite "${st}/old.crt" 644 <"${dcrt}" && cmp -s "${dcrt}" "${st}/old.crt"; }; } ||
       ! { ((hadKey == 0)) || { atomicWrite "${st}/old.key" 600 <"${dkey}" && cmp -s "${dkey}" "${st}/old.key"; }; } ||
       ! { jq -n --arg domain "${domain}" --argjson c "${hadCrt}" --argjson k "${hadKey}" \
              '{domain:$domain,had_crt:$c,had_key:$k}' | atomicWrite "${st}/manifest.json" 600; } ||
       ! sync -f "${st}"; then
        rm -rf "${st}"; lockRelease
        echoContent red " ---> 无法准备证书及备份，原来的证书没有改动"
        return 1
    fi
    # WAL：先持久化撤销依据，再替换任一 live 文件。
    if ! { printf '%s' "${st}" | atomicWrite "${TLS_TXN_MARK}" 600 &&
           [[ "$(cat "${TLS_TXN_MARK}")" == "${st}" ]] && sync -f "${ATR_HOME}"; }; then
        # 写标记可能已成功；保留备份并尝试恢复，不能直接删除恢复依据。
        if [[ -e "${TLS_TXN_MARK}" || -L "${TLS_TXN_MARK}" ]]; then _tlsRestoreLocked; else rm -rf "${st}"; fi
        lockRelease
        echoContent red " ---> 证书事务标记没有确认持久化，未报告导入成功"
        return 1
    fi
    if ! { atomicWrite "${dkey}" 600 <"${st}/new.key" && sync -f "${TLS_DIR}" &&
           atomicWrite "${dcrt}" 644 <"${st}/new.crt" &&
           cmp -s "${st}/new.key" "${dkey}" && cmp -s "${st}/new.crt" "${dcrt}" &&
           tlsValidate "${dcrt}" "${dkey}" "${domain}" && sync -f "${TLS_DIR}"; }; then
        echoContent red " ---> 替换证书失败，正在恢复原来的证书"
        _tlsRestoreLocked || rc=1
        lockRelease
        ((rc == 0)) && echoContent yellow " ---> 已恢复原来的证书"
        return 1
    fi
    if ! { _removeLive "${TLS_TXN_MARK}" && sync -f "${ATR_HOME}"; }; then
        echoContent red " ---> 新证书已经落盘，但事务提交未完成；保留备份，未报告成功，请执行 ${ATR_CMD} recover"
        lockRelease
        return 1
    fi
    rm -rf "${st}"
    lockRelease
    echoContent green " ---> 已导入证书（有效期剩余 $(tlsDaysLeft "${dcrt}") 天）"
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
allowPort80Hint() { printf 'tcp 80\n' | fwApplyList open; }

# 把 tlsSetupInteractive 的结果写入候选状态
stagedSetTLS() {
    local fingerprint
    fingerprint=$(sha256Of "${TLS_DIR}/${TLS_DOMAIN}.crt")
    [[ "${fingerprint}" =~ ^[0-9a-f]{64}$ ]] || return 1
    stagedEdit --arg d "${TLS_DOMAIN}" --arg m "${TLS_MODE}" --arg ca "${TLS_CA}" --arg api "${TLS_DNS_API}" --argjson w "${TLS_WILDCARD}" --arg fp "${fingerprint}" \
        '.domain=$d | .tls.mode=$m | .tls.ca=$ca | .tls.dns_api=$api | .tls.wildcard=$w | .tls.cert_sha256=$fp'
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

# 共享配置考虑所有 Xray Reality 协议；独立配置只考虑指定协议。
realityCoreHint() {
    local core=${1:-} id=${2:-} mode
    [[ "${core}" == xray ]] && { echo xray; return; }
    mode=$(stagedGet '.reality_mode // "shared"')
    [[ -n "${mode}" ]] || mode=$(realityMode)
    if [[ "${mode}" == independent ]]; then
        [[ -n "${core}" ]] || core=$(S --arg id "${id}" '.protocols[$id].core // ""')
        [[ "${core}" == xray ]] && echo xray || echo ""
        return
    fi
    while read -r id; do
        [[ "$(protoField "${id}" reality)" == true ]] && { echo xray; return; }
    done < <(installedProtocolsOfCore xray 2>/dev/null)
    echo ""
}

# 检测 Reality 目标是否可用；返回 0=通过(可有警告) 1=不通过
# 检查项: TLS1.3 握手 + X25519 + h2(ALPN) + 握手耗时 + 是否为 Cloudflare 代理域名

# 交互选择 Reality 目标。成功时设置 PICK_SNI / PICK_PORT 并返回 0
PICK_SNI=""
PICK_PORT=443

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

x25519PublicFromPrivate() { # x25519PublicFromPrivate <私钥 base64url 32 字节>  ->  公钥 base64url（无填充）
    # 用 openssl 推导：私钥只经过管道，不会出现在任何进程的命令行上
    # （xray x25519 -i <私钥> 会把私钥放进命令行，同机用户可以读到）
    local b64=$1 raw pub
    command -v openssl >/dev/null 2>&1 || return 1
    b64=${b64//-/+}
    b64=${b64//_//}
    while ((${#b64} % 4)); do b64+="="; done
    raw=$(printf '%s' "${b64}" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [[ "${raw}" =~ ^[0-9a-f]{64}$ ]] || return 1
    # PKCS#8 外壳 + 32 字节原始私钥 -> 取出 SPKI 的最后 32 字节即公钥
    # （十六进制 -> 字节用 printf 的 \x 转义完成，不依赖 xxd；它在很多精简系统里没有）
    pub=$(printf "$(printf '302e020100300506032b656e04220420%s' "${raw}" | sed 's/../\\x&/g')" |
        openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')
    [[ ${#pub} -eq 43 ]] || return 1
    printf '%s' "${pub}"
}

# 校验一对密钥是否匹配；无法校验（没有 openssl 等）时返回 2
verifyRealityKeypair() { # verifyRealityKeypair <priv> <pub>
    local derived
    derived=$(x25519PublicFromPrivate "$1") || return 2
    [[ -n "${derived}" ]] || return 2
    [[ "${derived}" == "$2" ]]
}

genShortId() { randHex 16; }

# ----------------------------- 写入候选状态 -----------------------------------
# 未带模式的旧 state 按共享处理；独立模式的参数保存在 protocols.<id>.reality。
realityMode() { S '.reality_mode // "shared"'; }
realityProfile() { # <协议 id> [state 文件]
    jq --arg id "$1" 'if (.reality_mode // "shared") == "independent" then .protocols[$id].reality // {} else .reality // {} end' "${2:-${ATR_STATE}}"
}
stagedRealityProfile() {
    stagedGet --arg id "${1:-}" 'if (.reality_mode // "shared") == "independent" then .protocols[$id].reality // {} else .reality // {} end'
}
_realityIDsJson() { jq '[.[]|select(.reality==true)|.id]' <<<"${PROTO_REGISTRY}"; }

stagedRealityMode() { # <shared|independent> [共享时采用的协议 id]
    local mode=$1 anchor=${2:-} old ids profile
    [[ "${mode}" == shared || "${mode}" == independent ]] || return 1
    old=$(stagedGet '.reality_mode // "shared"')
    [[ "${old}" == "${mode}" ]] && return 0
    ids=$(_realityIDsJson) || return 1
    if [[ "${mode}" == independent ]]; then
        # 复制现有配置，切换本身不使既有客户端失效；新加入的协议稍后配置。
        stagedEdit --argjson ids "${ids}" '.reality as $r | .reality_mode="independent" | .protocols |= with_entries(if (.key as $i | $ids | index($i)) != null then .value.reality=$r else . end)'
    else
        [[ -n "${anchor}" ]] || { echoContent red " ---> 独立模式切回共享模式必须选择采用哪一个协议的配置"; return 1; }
        profile=$(stagedRealityProfile "${anchor}") || return 1
        [[ "$(jq -r '.private_key // ""' <<<"${profile}")" != "" ]] || return 1
        stagedEdit --argjson p "${profile}" '.reality=$p | .reality_mode="shared" | .protocols |= with_entries(.value |= del(.reality))'
    fi
}

pickRealityProtocol() { # 现有 Reality 协议，输出放在 PICK_REALITY_ID
    local id n=0 c ids=()
    while read -r id; do
        [[ -n "${id}" ]] || continue
        ids+=("${id}"); n=$((n+1))
        echoContent yellow "${n}.$(protoName "${id}") ($(S --arg i "${id}" '.protocols[$i].core'))"
    done < <(installedRealityProtocols)
    ((n > 0)) || return 1
    ask c "请选择协议:" || return 1
    isInt "${c}" && ((c >= 1 && c <= n)) || return 1
    PICK_REALITY_ID=${ids[$((c-1))]}
}

pickRealityMode() {
    local c current
    current=$(stagedGet '.reality_mode // "shared"')
    echoContent yellow "\nReality 配置方式（端口仍需各不相同）:"
    echoContent yellow "1.共享：所有 Reality 协议使用相同 SNI、密钥对、Short ID"
    echoContent yellow "2.独立：按协议单独配置，可分别修改/重置"
    local default=1 anchor=""
    [[ "${current}" == independent ]] && default=2
    ask c "请选择[回车沿用当前方式 ${default}]:" "${default}" || return 1
    case "${c}" in
    1)
        if [[ "${current}" == independent ]]; then
            echoContent yellow "请选择共享配置的来源；其他 Reality 节点的客户端可能需要更新:"
            pickRealityProtocol || return 1; anchor=${PICK_REALITY_ID}
            confirm "确认改为共享所选协议的配置？" n || return 1
        fi
        stagedRealityMode shared "${anchor}"
        ;;
    2) stagedRealityMode independent ;;
    *) return 1 ;;
    esac
}

# independent 时目标 id 必须明确；shared 时空 id 表示修改共享配置。



# =============================================================================
#  07  配置渲染: state.json --jq--> sing-box / Xray 配置
#      所有值都通过 jq 的 --arg/--argjson 传入，密码/路径里的任何字符都不会破坏 JSON。
#      渲染是纯函数: 同一份状态永远得到同一份配置（不含随机数）。
#
#  路由 token 约定（存于 state.routing.*）:
#      domain:example.com   域名后缀        geosite:netflix  规则集(域名)
#      geoip:cn             规则集(IP)      ip:1.2.3.0/24    IP/CIDR
# =============================================================================

# 「公网出口」模式下，客户端不得访问的地址段（两个核心共用）: 回环、私网、CGNAT、链路本地(含云厂商元数据 169.254.169.254)、
# 组播/保留、IPv4 映射的 IPv6（::ffff:0:0/96 里的 IPv4 地址不会被 IPv4 段匹配到，必须单独列出）、ULA、IPv6 链路本地。
# 不含 NAT64(64:ff9b::/96)，否则会让纯 IPv6 主机无法经 NAT64 访问 IPv4 网站。再加上本机自己的地址 egress_self:
# local_ips（网卡地址，每次应用配置时刷新）、public_ips（探测到的公网地址: NAT / 1:1 映射时它不在任何网卡上）、extra_ips（管理员手动补充）。
read -r -d '' JQ_EGRESS_DEF <<'EOF'
def egress_cidrs: ["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.168.0.0/16","198.18.0.0/15","224.0.0.0/4","240.0.0.0/4","::/128","::1/128","::ffff:0:0/96","100::/64","fc00::/7","fe80::/10","ff00::/8"];
def egress_self: (($S.egress.local_ips // []) + ($S.egress.public_ips // []) + ($S.egress.extra_ips // [])) | unique;
EOF

# ----------------------------- sing-box --------------------------------------
read -r -d '' JQ_SINGBOX <<'EOF'
. as $S
| ($S.path // "") as $P
| ($S.routing // {}) as $R
| ($S.domain // "") as $D
| def cert: {certificate_path: ($tlsdir + "/" + $D + ".crt"), key_path: ($tlsdir + "/" + $D + ".key")};
  @@EGRESS_DEF@@
  def tlsCert: ({enabled: true, server_name: $D} + cert);
  def tlsReality($id): (if ($S.reality_mode // "shared") == "independent" then $S.protocols[$id].reality else $S.reality end) as $RE |
    {enabled:true,server_name:$RE.sni,reality:({enabled:true,handshake:{server:($RE.dest_host // $RE.sni),server_port:($RE.dest_port // 443)},private_key:$RE.private_key,short_id:[$RE.short_id]}
    + (if ($RE.max_time_diff_seconds // 0)>0 then {max_time_difference:(($RE.max_time_diff_seconds|tostring)+"s")} else {} end))};
  def users($p):
    $S.users | map(
      if ($p == "vless_reality_vision" or $p == "vless_vision_tls") then {name: .name, uuid: .uuid, flow: "xtls-rprx-vision"}
      elif ($p == "vless_ws" or $p == "vless_reality_grpc") then {name: .name, uuid: .uuid}
      elif ($p == "vmess_ws" or $p == "vmess_httpupgrade") then {name: .name, uuid: .uuid, alterId: 0}
      elif ($p == "tuic") then {name: .name, uuid: .uuid, password: .password}
      elif ($p == "naive") then {username: .name, password: .password}
      else {name: .name, password: .password} end);
  def inbound($id; $c):
    if $id == "vless_reality_vision" then {type: "vless", tag: "vless-reality-vision", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsReality($id)}
    elif $id == "anytls_reality" then {type: "anytls", tag: "anytls-reality", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsReality($id)} + (if $c.padding_scheme!=null then {padding_scheme:$c.padding_scheme} else {} end)
    elif $id == "tuic" then {type: "tuic", tag: "tuic", listen: $listen, listen_port: $c.port, users: users($id), congestion_control: ($c.congestion // "bbr"), tls: (tlsCert + {alpn: ["h3"]})}
    elif $id == "hysteria2" then {type: "hysteria2", tag: "hysteria2", listen: $listen, listen_port: $c.port, users: users($id),
        tls: (tlsCert + {alpn: ["h3"]})}
        + (if ($c.bandwidth_mode // (if ($c.up_mbps // 0)>0 or ($c.down_mbps // 0)>0 then "fixed" else "auto" end)) == "fixed"
           then {up_mbps: ($c.down_mbps // 100), down_mbps: ($c.up_mbps // 50)} else {ignore_client_bandwidth:true} end)
        + (if ($c.obfs.type // "") != "" then {obfs:$c.obfs} else {} end)
        + (if ($c.obfs.type // "")!="" then {}
           elif ($c.masquerade.gateway_port // 0)>0 then {masquerade:{type:"proxy",url:("http://127.0.0.1:"+($c.masquerade.gateway_port|tostring)),rewrite_host:true}}
           elif ($c.masquerade.mode // "off")=="file" then {masquerade:{type:"file",directory:$c.masquerade.directory}}
           elif ($c.masquerade.mode // "off")=="string" then {masquerade:{type:"string",status_code:200,content:$c.masquerade.content,headers:{"Content-Type":["text/html; charset=utf-8"]}}}
           elif ($c.masquerade.mode // "off") == "redirect" then {masquerade:{type:"string",status_code:302,headers:{Location:[$c.masquerade.url],"Content-Type":["text/plain; charset=utf-8"]},content:"Redirecting."}}
           elif ($c.masquerade.mode // "off") == "proxy" then {masquerade:{type:"proxy",url:$c.masquerade.url,rewrite_host:true}} else {} end)
    elif $id == "naive" then {type: "naive", tag: "naive", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert}
    elif $id == "vless_vision_tls" then {type: "vless", tag: "vless-vision-tls", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert}
    elif $id == "vless_ws" then {type: "vless", tag: "vless-ws", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert,
        transport: {type: "ws", path: ("/" + $P + "ws"), max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol"}}
    elif $id == "vmess_ws" then {type: "vmess", tag: "vmess-ws", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert,
        transport: {type: "ws", path: ("/" + $P + "vws"), max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol"}}
    elif $id == "trojan" then {type: "trojan", tag: "trojan", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert}
    elif $id == "vless_reality_grpc" then {type: "vless", tag: "vless-reality-grpc", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsReality($id),
        transport: {type: "grpc", service_name: "grpc"}}
    elif $id == "vmess_httpupgrade" then {type: "vmess", tag: "vmess-httpupgrade", listen: "127.0.0.1", listen_port: $hup, users: users($id),
        transport: {type: "httpupgrade", path: ("/" + $P + "hu")}}
    elif $id == "anytls_tls" then {type: "anytls", tag: "anytls-tls", listen: $listen, listen_port: $c.port, users: users($id), tls: tlsCert} + (if $c.padding_scheme!=null then {padding_scheme:$c.padding_scheme} else {} end)
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
        # Socks5 入站的来源白名单最先检查（在嗅探和 DNS 劫持之前）: 否则来自非白名单来源的 DNS 请求会先被 hijack-dns 处理，
        # 绕过来源限制。invert 只写在子规则上，只取反"来源在白名单里"这一项；白名单为空时整个 Socks5 入站直接拒绝。
        # 末尾那条 Socks5 reject 保留作兜底
        rules: ((if $haveS5in then
                   (if (($R.socks5_in.allow_ips // []) | length) == 0 then [{inbound: ["socks5_inbound"], action: "reject"}]
                    else [{type: "logical", mode: "and", rules: [{inbound: ["socks5_inbound"]}, {source_ip_cidr: $R.socks5_in.allow_ips, invert: true}], action: "reject"}] end)
                 else [] end)
                + [{action: "sniff"}, {protocol: "dns", action: "hijack-dns"}]
                # 出口访问模式 = 公网出口: 先把域名解析成 IP（resolve 只补充目的地址，域名规则照常匹配），再拒绝一切指向
                # 回环/私网/链路本地/本机自身地址的连接。必须排在所有放行规则之前，Socks5 入站的放行规则也不例外
                + (if ($S.egress.mode // "") == "public" then [{action: "resolve"}, {ip_cidr: (egress_cidrs + egress_self), action: "reject"}] else [] end)
                # Socks5 入站: 仅允许指定来源 IP 访问指定目标，其余一律拒绝（它是明文代理，绝不能对外开放）
                + (if $haveS5in then
                     ((if ($R.socks5_in.ip_strategy // "") != "" then [{inbound: "socks5_inbound", action: "resolve", strategy: $R.socks5_in.ip_strategy}] else [] end)
                      # 来源白名单为空时不生成任何放行规则（只剩最后的 reject）: source_ip_cidr 为空数组会被 sing-box 当作"不限制来源"
                      + (if (($R.socks5_in.allow_ips // []) | length) == 0 then []
                         elif ($R.socks5_in.all // false) then [{inbound: ["socks5_inbound"], source_ip_cidr: ($R.socks5_in.allow_ips // []), outbound: "direct"}]
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
JQ_SINGBOX=${JQ_SINGBOX/@@EGRESS_DEF@@/${JQ_EGRESS_DEF}}
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
| @@EGRESS_DEF@@
  # 公网出口: 先放行"添加新端口"的 dokodemo-door（它只是把流量转给本机 Vision 前置端口，不是客户端的目的地），再拦截内网/本机目的地。
  # 不用 geoip:private（它需要 geoip.dat 文件）；显式地址段与数据文件无关。Xray 不接受 ::ffff:0:0/96 这种写法，但它会先把 IPv4 映射地址归一成 IPv4 再匹配（见 t_security 的实测）。
  # 域名目标（已用 DNS rebinding 实测，见 t_rebind）: 路由检查用的是 Xray 的一次解析，freedom 出站"拨号前"会再解析一次；如果两次解析的结果不同（攻击者控制的域名第一次给公网地址、第二次给 127.0.0.1），
  # 光靠路由规则会被绕过。所以公网出口模式下还要做两件事: 1) 用 DNS 服务器自身的 unexpectedIPs 把落在这些地址段的解析结果丢掉（路由检查和 freedom 的再解析都经过它，拨号只可能用到通过过滤的地址）；
  # 2) 直连出站改用 ForceIP: 解析失败就直接失败，绝不退回去按域名拨号（退回去就是交给系统解析器再解析一次，等于绕过了过滤）。
  def realityOf($id): if ($S.reality_mode // "shared") == "independent" then $S.protocols[$id].reality else $S.reality end;
  def xpublic: ($S.egress.mode // "") == "public";
  def egress_xip: (egress_cidrs - ["::ffff:0:0/96"]) + egress_self;
  def xdns($a): ($a | if type == "object" then . else {address: .} end)
      | if xpublic then . + {unexpectedIPs: ((.unexpectedIPs // []) + egress_xip | unique)} else . end;
  def egress_x: if xpublic then
      ([ ($S.extra_ports // [])[] | "dokodemo-door-newPort-" + tostring ]) as $dk
      | (if ($dk | length) > 0 and ($PR.vless_vision_tls.core // "") == "xray" then [{type: "field", inboundTag: $dk, outboundTag: "direct"}] else [] end)
        + [{type: "field", ip: egress_xip, outboundTag: "block"}]
    else [] end;
  def tlsCert: {rejectUnknownSni: true, minVersion: "1.2",
                certificates: [{certificateFile: ($tlsdir + "/" + $D + ".crt"), keyFile: ($tlsdir + "/" + $D + ".key"), ocspStapling: 3600}]};
  def xusers($p):
    $S.users | map(
      if ($p == "vless_reality_vision" or $p == "vless_vision_tls") then {id: .uuid, flow: "xtls-rprx-vision", email: (.name + "@" + $p)}
      elif ($p == "vmess_ws") then {id: .uuid, alterId: 0, email: (.name + "@" + $p)}
      elif ($p == "trojan") then {password: .password, email: (.name + "@" + $p)}
      else {id: .uuid, email: (.name + "@" + $p)} end);
  def realityS($id): realityOf($id) as $RE |
    {show: false, target: ((if (($RE.dest_host // $RE.sni)|contains(":")) then "["+($RE.dest_host // $RE.sni)+"]" else ($RE.dest_host // $RE.sni) end) + ":" + (($RE.dest_port // 443) | tostring)), xver: 0,
     serverNames: [$RE.sni], privateKey: $RE.private_key, shortIds: [$RE.short_id]}
    + (if ($RE.mldsa_seed // "") != "" then {mldsa65Seed: $RE.mldsa_seed, minClientVer: "1.8.2"} else {} end)
    + {maxTimeDiff:(1000*($RE.max_time_diff_seconds // (if ($RE.mldsa_seed // "")!="" then 70 else 0 end)))};
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
       streamSettings: {network: "tcp", security: "reality", realitySettings: realityS($id)}} + sniffing
    elif $id == "vless_reality_xhttp" then
      {port: $c.port, protocol: "vless", tag: "VLESSRealityXHTTP",
       settings: {clients: xusers($id), decryption: "none"},
       streamSettings: {network: "xhttp", security: "reality", realitySettings: realityS($id),
                        xhttpSettings: {host: (realityOf($id) | .sni), path: ("/" + $P + "xHTTP"), mode: "auto"}}}
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
      log: {loglevel: (if $debug == "1" then "debug" else "warning" end)},
      policy: {levels: {"0": {handshake: 4, connIdle: 300}}},
      dns: (if (($R.dns_unlock.server // "") != "" and ((($R.dns_unlock.domains // []) | length) > 0)) then
              {servers: [xdns({address: $R.dns_unlock.server, port: 53, domains: xdomains($R.dns_unlock.domains)}), xdns("localhost")]}
            elif (($R.sni_proxy.ip // "") != "" and ((($R.sni_proxy.domains // []) | length) > 0)) then
              {hosts: (reduce xdomains($R.sni_proxy.domains)[] as $d ({}; .[$d] = $R.sni_proxy.ip)), servers: [xdns("8.8.8.8"), xdns("1.1.1.1")]}
            else {servers: [xdns("localhost")]} end),
      inbounds: $inbounds,
      outbounds: ((if $G == "warp_v4" and $haveWarp then [{protocol: "wireguard", tag: "warp_v4", settings: {secretKey: $W.private_key, address: ["172.16.0.2/32"],
                      peers: [{publicKey: $W.public_key, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: "162.159.192.1:2408"}], reserved: $W.reserved, mtu: 1280}}]
                   elif $G == "warp_v6" and $haveWarp then [{protocol: "wireguard", tag: "warp_v6", settings: {secretKey: $W.private_key, address: [($W.address_v6 + "/128")],
                      peers: [{publicKey: $W.public_key, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: "162.159.192.1:2408"}], reserved: $W.reserved, mtu: 1280}}]
                   elif $G == "ipv6" then [{protocol: "freedom", tag: "IPv6_out", streamSettings: {sockopt: {domainStrategy: "ForceIPv6"}}}]
                   elif $G == "socks5" and $useS5 then [{protocol: "socks", tag: "socks5_outbound", settings: {servers: [{address: $R.socks5_out.server, port: $R.socks5_out.port,
                      users: [{user: ($R.socks5_out.user // ""), pass: ($R.socks5_out.pass // "")}]}]}}]
                   else [] end)
                  + [{protocol: "freedom", tag: "direct", streamSettings: {sockopt: {domainStrategy: (if xpublic then "ForceIP" else "UseIP" end)}}}, {protocol: "blackhole", tag: "block"}]
                  + (if ($haveWarp and $useW4 and $G != "warp_v4") then [{protocol: "wireguard", tag: "warp_v4", settings: {secretKey: $W.private_key, address: ["172.16.0.2/32"],
                      peers: [{publicKey: $W.public_key, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: "162.159.192.1:2408"}], reserved: $W.reserved, mtu: 1280}}] else [] end)
                  + (if ($haveWarp and $useW6 and $G != "warp_v6") then [{protocol: "wireguard", tag: "warp_v6", settings: {secretKey: $W.private_key, address: [($W.address_v6 + "/128")],
                      peers: [{publicKey: $W.public_key, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: "162.159.192.1:2408"}], reserved: $W.reserved, mtu: 1280}}] else [] end)
                  + (if ($useV6 and $G != "ipv6") then [{protocol: "freedom", tag: "IPv6_out", streamSettings: {sockopt: {domainStrategy: "ForceIPv6"}}}] else [] end)
                  + (if ($useS5 and $G != "socks5") then [{protocol: "socks", tag: "socks5_outbound", settings: {servers: [{address: $R.socks5_out.server, port: $R.socks5_out.port,
                      users: [{user: ($R.socks5_out.user // ""), pass: ($R.socks5_out.pass // "")}]}]}}] else [] end)),
      routing: {
        domainStrategy: "IPOnDemand",
        rules: (egress_x
                + (if ($R.block_bt // false) then [{type: "field", protocol: ["bittorrent"], outboundTag: "block"}] else [] end)
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
JQ_XRAY=${JQ_XRAY/@@EGRESS_DEF@@/${JQ_EGRESS_DEF}}
renderXray() {
    local needSniff
    needSniff=$(jq -r 'if (.routing.block_bt == true) or ((.routing.blacklist.domains // [])|length > 0) or (.routing.blacklist.cn == true) or ((.routing.warp.v4.domains // [])|length > 0) or ((.routing.warp.v6.domains // [])|length > 0) or ((.routing.ipv6.domains // [])|length > 0) or ((.routing.socks5_out.domains // [])|length > 0) then "1" else "0" end' "$1")
    jq --arg tlsdir "${TLS_DIR}" \
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
    stateNeedsNginxFallback "$1" || stateNeedsHttpUpgradeNginx "$1" || stateNeedsSubscribe "$1" || stateNeedsHY2Gateway "$1"
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
    # worker 使用专用账号 atr-nginx（见 ensureNginxAccount）；测试环境可通过 ATR_NGINX_USER 指定
    local userLine
    userLine="user $(ngxWorkerUser);"
    # worker 要往临时目录写（请求体/代理缓冲）；nginx 自己通常会 chown，这里显式做一次，不依赖这个行为
    chown -R "$(ngxWorkerUser):$(ngxWorkerGroup)" "${NGX_DIR}/tmp" 2>/dev/null || true
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
    local st=$1 out=$2 domain path redirect port h2a h2b ssl6 sub_port sub_ssl peer_key peer_loc=""
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
        peer_key=$(jq -r '.nginx.subscribe.peer_key // ""' "${st}")
        peer_loc=""
        if [[ "${peer_key}" =~ ^[A-Za-z0-9]{16,64}$ ]]; then
            peer_loc=$(
                cat <<PEER
    location ~ "^/s/peer/${peer_key}/([A-Za-z0-9_][A-Za-z0-9._@-]{0,47})/(default|clashMeta|sing-box_profiles)\$" {
        default_type 'text/plain; charset=utf-8';
        alias ${SUB_DIR}/peer/\$1/\$2;
    }
PEER
            )
        fi
        {
            echo "# atr-sub-layout 2"
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
    # 供其他机器合并本机订阅的对等端点: /s/peer/<对等密钥>/<用户名>/<类型>。密钥由这份配置自己核对（所以这份配置是 600 权限），
    # 文件按 peer/<用户名>/<类型> 存放、路径里没有密钥：重置/关闭密钥在配置提交、nginx 重启的那一刻就生效，不依赖随后的文件发布；
    # 创建目录时也不需要把密钥交给任何外部命令
${peer_loc}
    location / {
    }
}
EOF
        } >"${out}/atr_subscribe.conf"
    fi
    renderHY2Gateway "${st}" "${out}" || return 1
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
UNIT_REWRITTEN=0
_writeUnitFile() { # _writeUnitFile <单元名> (内容来自 stdin)
    local name=$1 f="${ATR_SYSTEMD_DIR}/$1.service" tmp
    mkdir -p "${ATR_SYSTEMD_DIR}" || return 1
    tmp=$(mktemp "${ATR_TMP:-/tmp}/unit.XXXXXX") || return 1
    if ! cat >"${tmp}"; then rm -f "${tmp}"; return 1; fi
    if [[ -f "${f}" ]] && cmp -s "${tmp}" "${f}"; then
        rm -f "${tmp}"
        return 0
    fi
    if ! { atomicWrite "${f}" 644 <"${tmp}" && cmp -s "${tmp}" "${f}"; }; then
        rm -f "${tmp}"
        echoContent red " ---> 无法写入 systemd 单元: ${f}"
        return 1
    fi
    rm -f "${tmp}"
    UNIT_REWRITTEN=1
    systemctl daemon-reload >/dev/null 2>&1 || {
        echoContent red " ---> systemd daemon-reload 失败"
        return 1
    }
}

writeTLSRecoveryUnit() {
    _writeUnitFile "${TLS_RECOVERY_UNIT}" <<EOF
[Unit]
Description=Recover interrupted TLS import (${ATR_PROJECT_NAME})
After=local-fs.target
Before=${SB_UNIT}.service ${XRAY_UNIT}.service ${NGX_UNIT}.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=${ATR_SCRIPT_PATH} recover-tls
UMask=0077
EOF
}

writeUnit() { # writeUnit <sing-box|xray|nginx>
    writeTLSRecoveryUnit || return 1
    case "$1" in
    sing-box)
        _writeUnitFile "${SB_UNIT}" <<EOF
[Unit]
Description=Sing-Box Service (${ATR_PROJECT_NAME})
Documentation=https://sing-box.sagernet.org
Requires=${TLS_RECOVERY_UNIT}.service
After=network.target nss-lookup.target ${TLS_RECOVERY_UNIT}.service

[Service]
User=root
WorkingDirectory=${SB_DIR}
# 只保留服务端真正需要的能力。整个系统（含安装目录: 脚本、二进制、配置、state）对服务只读（ProtectSystem=strict），
# 也不能创建 Unix 套接字（RestrictAddressFamilies），所以在服务自身的沙箱里改不了管理脚本，连不上 systemd / D-Bus 去启动沙箱之外的任务，
# 也写不了 cron 等系统目录。它仍以 root 运行、能读取宿主上的大多数文件: 内核被攻陷仍应按已获得 root 权限处理。
# sing-box 需要 AF_NETLINK（监控网卡，2026-10 strace 实测），两个内核都不需要 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${ATR_HOME}
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ExecStartPre=${SB_BIN} check -c ${SB_CONF}
ExecStart=${SB_BIN} run -c ${SB_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
TasksMax=65535

[Install]
WantedBy=multi-user.target
EOF
        ;;
    xray)
        _writeUnitFile "${XRAY_UNIT}" <<EOF
[Unit]
Description=Xray Service (${ATR_PROJECT_NAME})
Documentation=https://github.com/xtls
Requires=${TLS_RECOVERY_UNIT}.service
After=network.target nss-lookup.target ${TLS_RECOVERY_UNIT}.service

[Service]
User=root
WorkingDirectory=${XRAY_DIR}
Environment="XRAY_LOCATION_ASSET=${XRAY_DIR}"
# 沙箱与 sing-box 相同（见上面的说明）；Xray 只用 AF_INET / AF_INET6
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${ATR_HOME}
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ExecStartPre=${XRAY_BIN} run -test -c ${XRAY_CONF}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONF}
Restart=on-failure
RestartPreventExitStatus=23
RestartSec=10
LimitNOFILE=1048576
TasksMax=65535

[Install]
WantedBy=multi-user.target
EOF
        ;;
    nginx)
        findNginxBin || return 1
        _writeUnitFile "${NGX_UNIT}" <<EOF
[Unit]
Description=nginx for ${ATR_PROJECT_NAME} (isolated instance)
Requires=${TLS_RECOVERY_UNIT}.service
After=network.target nss-lookup.target ${TLS_RECOVERY_UNIT}.service

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

# TXN_MARK 与 _requireCleanTransaction 定义在 01-util（03 / 04 段已经要用到它们）

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
    if stateNeedsHY2Gateway "${st}"; then jq -r '"tcp \(.protocols.hysteria2.masquerade.gateway_port)"' "${st}"; fi
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
    elif command -v nft >/dev/null 2>&1 && _nftDropInput >/dev/null; then
        echo nft
    else
        echo none
    fi
}
# 原生 nftables 里默认拒绝的 input 链: 打印 "<族> <表> <链>"（第一个），没有就返回 1。本脚本不管理 nftables 规则（另建一张表放行
# 抵消不了别的表的 drop，要放行就得改管理员自己的规则集），只用来准确提示。iptables-nft 的规则在上面已经按 iptables 处理
_nftDropInput() {
    nft list ruleset 2>/dev/null | awk '
        $1 == "table" { fam = $2; tbl = $3 }
        $1 == "chain" { ch = $2 }
        /hook input/ && /policy drop/ { print fam, tbl, ch; found = 1; exit }
        END { exit !found }'
}
# ufw 里已经有放行这个端口的规则吗（以 ufw status 为准，不只看 allow / delete 的返回值）
_ufwHas() { # _ufwHas <端口|a:b> <tcp|udp>
    local status family=${3:-v4}
    status=$(ufw status 2>/dev/null) || return 2
    if [[ "${family}" == v6 ]]; then
        grep -qE "^${1}/${2}[[:space:]]+\(v6\)[[:space:]]+ALLOW" <<<"${status}"
    else
        grep -qE "^${1}/${2}[[:space:]]+ALLOW" <<<"${status}"
    fi
}
# 给管理员的手动命令
_fwManualCmd() { # _fwManualCmd <ufw|firewalld|iptables|nft> <open|close> <端口|a:b> <tcp|udp>
    local kind=$1 act=$2 port=$3 proto=$4 fam tbl ch
    case "${kind}" in
    ufw) if [[ "${act}" == open ]]; then echo "ufw allow ${port}/${proto}"; else echo "ufw delete allow ${port}/${proto}"; fi ;;
    firewalld) echo "firewall-cmd --permanent --zone=public --$([[ "${act}" == open ]] && echo add || echo remove)-port=${port//:/-}/${proto} && firewall-cmd --reload" ;;
    iptables) echo "iptables -$([[ "${act}" == open ]] && echo I || echo D) INPUT -p ${proto} --dport ${port} -j ACCEPT" ;;
    nft)
        read -r fam tbl ch <<<"$(_nftDropInput)"
        if [[ "${act}" == open ]]; then
            echo "nft insert rule ${fam:-inet} ${tbl:-filter} ${ch:-input} ${proto} dport ${port//:/-} accept"
        else
            echo "（如果之前手动加过）从 nftables 规则集里删除 ${proto} dport ${port//:/-} 的放行规则"
        fi
        ;;
    esac
}

# 后端查询统一返回 0=存在、1=不存在、2=无法确认。错误不能被当作规则不存在。
_fwQuery() { # <kind> <part> <port> <proto>
    local kind=$1 part=$2 port=$3 proto=$4 rc cmd
    case "${kind}:${part}" in
    ufw:v4 | ufw:v6) _ufwHas "${port}" "${proto}" "${part}"; return $? ;;
    firewalld:permanent) firewall-cmd --permanent --zone=public --query-port="${port//:/-}/${proto}" >/dev/null 2>&1 ;;
    firewalld:runtime) firewall-cmd --zone=public --query-port="${port//:/-}/${proto}" >/dev/null 2>&1 ;;
    iptables:v4 | iptables:v6)
        cmd=iptables; [[ "${part}" == v6 ]] && cmd=ip6tables
        command -v "${cmd}" >/dev/null 2>&1 || return 2
        "${cmd}" -C INPUT -p "${proto}" --dport "${port}" -m comment --comment "atr:${proto}/${port}" -j ACCEPT >/dev/null 2>&1
        ;;
    *) return 2 ;;
    esac
    rc=$?; ((rc == 0 || rc == 1)) && return "${rc}"
    return 2
}

# 调用真正的防火墙命令之前先记撤销动作。配置事务中还会将其同步到备份目录，SIGKILL 后可重放。
# 逐个记录永久/运行时、IPv4/IPv6，只记录操作前不存在的部分，绝不删除管理员已有的部分。
FW_CREATED=""
FW_JOURNAL_FILE=""
_fwRecordUndo() { # <kind> <part> <port> <proto>
    local line old="" expected
    printf -v line '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"
    if [[ -n "${FW_JOURNAL_FILE:-}" ]]; then
        if [[ -f "${FW_JOURNAL_FILE}" ]]; then old=$(cat "${FW_JOURNAL_FILE}") || return 1; fi
        expected="${old}${old:+$'\n'}${line}"
        printf '%s\n' "${expected}" | atomicWrite "${FW_JOURNAL_FILE}" 600 || return 1
        [[ "$(cat "${FW_JOURNAL_FILE}")" == "${expected}" ]] && sync -f "${FW_JOURNAL_FILE}" || return 1
    fi
    FW_CREATED+="${line}"$'\n'
}

_fwDelete() { # <kind> <part> <port> <proto>；删除后必须确认不存在
    local kind=$1 part=$2 port=$3 proto=$4 rc cmd
    _fwQuery "$@"; rc=$?
    ((rc == 1)) && return 0
    ((rc == 0)) || return 1
    case "${kind}:${part}" in
    ufw:v4) ufw delete allow proto "${proto}" from 0.0.0.0/0 to 0.0.0.0/0 port "${port}" >/dev/null 2>&1 ;;
    ufw:v6) ufw delete allow proto "${proto}" from ::/0 to ::/0 port "${port}" >/dev/null 2>&1 ;;
    firewalld:permanent) firewall-cmd --permanent --zone=public --remove-port="${port//:/-}/${proto}" >/dev/null 2>&1 ;;
    firewalld:runtime) firewall-cmd --zone=public --remove-port="${port//:/-}/${proto}" >/dev/null 2>&1 ;;
    iptables:v4 | iptables:v6)
        cmd=iptables; [[ "${part}" == v6 ]] && cmd=ip6tables
        # 只删除带 atr 注释的规则；同规则重复时全部清理。
        while "${cmd}" -D INPUT -p "${proto}" --dport "${port}" -m comment --comment "atr:${proto}/${port}" -j ACCEPT >/dev/null 2>&1; do :; done
        ;;
    *) return 1 ;;
    esac
    _fwQuery "$@"; rc=$?
    ((rc == 1))
}

_fwSave() {
    if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save >/dev/null 2>&1; else return 0; fi
}

fwRollbackJournal() { # <撤销日志文件>；可重入，失败保留日志和配置事务标记
    local f=$1 lines=() i kind part port proto extra rc=0
    [[ -e "${f}" ]] || return 0
    [[ -f "${f}" && ! -L "${f}" ]] || return 1
    mapfile -t lines <"${f}" || return 1
    for ((i=${#lines[@]}-1; i>=0; i--)); do
        IFS=$'\t' read -r kind part port proto extra <<<"${lines[i]}"
        if [[ -n "${extra}" || ! "${port}" =~ ^[0-9]+(:[0-9]+)?$ || ! "${proto}" =~ ^(tcp|udp)$ ]]; then
            echoContent red " ---> 防火墙撤销日志损坏，已保留恢复依据: ${f}"
            rc=1; continue
        fi
        case "${kind}:${part}" in ufw:v4 | ufw:v6 | firewalld:permanent | firewalld:runtime | iptables:v4 | iptables:v6) ;;
        *) rc=1; continue ;;
        esac
        if ! _fwDelete "${kind}" "${part}" "${port}" "${proto}"; then
            echoContent red " ---> 防火墙撤销未完成: ${kind}/${part} ${proto}/${port}"
            rc=1
        elif [[ "${kind}" == iptables ]] && ! _fwSave; then
            echoContent red " ---> 防火墙规则已撤销，但持久保存失败"
            rc=1
        fi
    done
    return "${rc}"
}

_fwHasGlobalIPv6() { ip -o -6 addr show scope global 2>/dev/null | grep -q 'inet6 '; }

# 0=本次添加；10=已有；20=nft 手动管理；30=无需防火墙；1=失败。
fwOpen() {
    local port=$1 proto=$2 kind part rc changed=0 cmd parts=()
    kind=$(_fwKind)
    case "${kind}" in
    none) return 30 ;;
    nft) return 20 ;;
    ufw) parts=(v4 v6) ;;
    firewalld) parts=(permanent runtime) ;;
    iptables) parts=(v4 v6) ;;
    *) return 1 ;;
    esac
    for part in "${parts[@]}"; do
        if [[ "${kind}:${part}" == ufw:v6 ]] && grep -qi '^IPV6=no' /etc/default/ufw 2>/dev/null; then
            if _fwHasGlobalIPv6; then echoContent red " ---> UFW 没有管理本机的全球 IPv6，请手动处理或用 ATR_SKIP_FIREWALL=1"; return 1; fi
            continue
        fi
        _fwQuery "${kind}" "${part}" "${port}" "${proto}"; rc=$?
        ((rc == 0)) && continue
        if ((rc != 1)); then
            if [[ "${kind}:${part}" == iptables:v6 ]] && ! _fwHasGlobalIPv6; then
                echoContent yellow " ---> 本机没有全球 IPv6，未能查询 ip6tables；只处理 IPv4"
                continue
            fi
            echoContent red " ---> 无法确认 ${kind}/${part} 的原有规则，拒绝修改"
            return 1
        fi
        _fwRecordUndo "${kind}" "${part}" "${port}" "${proto}" || return 1
        case "${kind}:${part}" in
        ufw:v4) ufw allow proto "${proto}" from 0.0.0.0/0 to 0.0.0.0/0 port "${port}" >/dev/null 2>&1 || return 1 ;;
        ufw:v6) ufw allow proto "${proto}" from ::/0 to ::/0 port "${port}" >/dev/null 2>&1 || return 1 ;;
        firewalld:permanent) firewall-cmd --permanent --zone=public --add-port="${port//:/-}/${proto}" >/dev/null 2>&1 || return 1 ;;
        firewalld:runtime) firewall-cmd --zone=public --add-port="${port//:/-}/${proto}" >/dev/null 2>&1 || return 1 ;;
        iptables:v4 | iptables:v6)
            cmd=iptables; [[ "${part}" == v6 ]] && cmd=ip6tables
            "${cmd}" -I INPUT -p "${proto}" --dport "${port}" -m comment --comment "atr:${proto}/${port}" -j ACCEPT >/dev/null 2>&1 || return 1
            ;;
        esac
        _fwQuery "${kind}" "${part}" "${port}" "${proto}" || return 1
        changed=1
    done
    if [[ "${kind}" == iptables ]] && ((changed)); then
        _fwSave || return 1
        command -v netfilter-persistent >/dev/null 2>&1 || echoContent yellow " ---> 提示: 未安装 netfilter-persistent，重启后放行规则可能丢失"
    fi
    ((changed)) && return 0
    return 10
}

fwClose() { # 与放行相同，分别处理运行时/永久及 IPv4/IPv6，不执行全局 firewalld reload
    local port=$1 proto=$2 kind part rc changed=0 fail=0 parts=()
    kind=$(_fwKind)
    case "${kind}" in
    none) return 30 ;; nft) return 20 ;;
    ufw) parts=(v4 v6) ;; firewalld) parts=(runtime permanent) ;; iptables) parts=(v4 v6) ;;
    *) return 1 ;;
    esac
    for part in "${parts[@]}"; do
        _fwQuery "${kind}" "${part}" "${port}" "${proto}"; rc=$?
        ((rc == 1)) && continue
        if ((rc != 0)); then
            [[ "${kind}:${part}" == iptables:v6 ]] && ! _fwHasGlobalIPv6 && continue
            fail=1; continue
        fi
        changed=1
        _fwDelete "${kind}" "${part}" "${port}" "${proto}" || fail=1
    done
    if [[ "${kind}" == iptables ]] && ((changed)); then _fwSave || fail=1; fi
    ((fail)) && return 1
    ((changed)) && return 0
    return 10
}

# 把期望端口与旧 state 做差。
fwDiff() { # <旧 state> <新 state> <add|remove>
    local old=$1 new=$2 mode=$3 tmpo tmpn
    tmpo=$(mktemp "${ATR_TMP:-/tmp}/fw.XXXXXX") || return 1
    tmpn=$(mktemp "${ATR_TMP:-/tmp}/fw.XXXXXX") || { rm -f "${tmpo}"; return 1; }
    [[ -s "${old}" ]] && desiredFirewallPorts "${old}" | sort -u >"${tmpo}"
    desiredFirewallPorts "${new}" | sort -u >"${tmpn}"
    if [[ "${mode}" == add ]]; then comm -13 "${tmpo}" "${tmpn}"; else comm -23 "${tmpo}" "${tmpn}"; fi
    rm -f "${tmpo}" "${tmpn}"
}

fwApplyList() { # <open|close>，失败返回非零；只有已核实的结果才显示成功
    local action=$1 proto port rc fail=0 kind manual=()
    kind=$(_fwKind)
    while read -r proto port; do
        [[ -z "${port}" ]] && continue
        rc=0
        if [[ "${action}" == open ]]; then
            fwOpen "${port}" "${proto}" || rc=$?
            case "${rc}" in
            0) echoContent green " ---> 已放行 ${proto}/${port}" ;;
            10) echoContent green " ---> 防火墙原本就放行了 ${proto}/${port}" ;;
            20) manual+=("$(_fwManualCmd nft open "${port}" "${proto}")") ;;
            30) ;;
            *) echoContent red " ---> 未能自动放行 ${proto}/${port}（${kind}）；请检查日志或手动处理"; fail=1 ;;
            esac
        else
            fwClose "${port}" "${proto}" || rc=$?
            case "${rc}" in
            0) echoContent yellow " ---> 已回收 ${proto}/${port}" ;;
            10 | 30) ;;
            20) manual+=("$(_fwManualCmd nft close "${port}" "${proto}")") ;;
            *) echoContent red " ---> 未能完整回收 ${proto}/${port} 的放行规则（${kind}），请手动检查"; fail=1 ;;
            esac
        fi
    done
    if ((${#manual[@]})); then
        echoContent yellow " ---> nftables 由你自己管理（配置照常生效），请确认下面的规则:"
        printf '      %s\n' "${manual[@]}"
    fi
    return "${fail}"
}


# ----------------------------- 备份 / 回滚 -----------------------------------
# 受事务管理的文件
_txnFiles() {
    echo "${ATR_STATE}"
    echo "${ATR_SYSTEMD_DIR}/atr-monitor.service"
    echo "${ATR_SYSTEMD_DIR}/atr-monitor.timer"
    echo "${SB_CONF}"
    echo "${XRAY_CONF}"
    echo "${ATR_SYSTEMD_DIR}/${SB_UNIT}.service"
    echo "${ATR_SYSTEMD_DIR}/${XRAY_UNIT}.service"
    echo "${ATR_SYSTEMD_DIR}/${NGX_UNIT}.service"
    echo "${ATR_SYSTEMD_DIR}/${TLS_RECOVERY_UNIT}.service"
    echo "${ATR_SYSTEMD_DIR}/atr-hop.service"
    echo "${NGX_CONF}"
    local f
    for f in "${NGX_CONFD}"/atr_*.conf; do [[ -e "${f}" ]] && echo "${f}"; done
}

# backupLive <备份目录>  —— 记录每个文件原先是否存在
backupLive() {
    local bdir=$1 f key
    mkdir -p "${bdir}/files" || return 1
    : >"${bdir}/manifest" || return 1
    while read -r f; do
        [[ -z "${f}" ]] && continue
        key=$(printf '%s' "${f}" | sed 's#/#%#g')
        if [[ -f "${f}" ]]; then
            # 复制后逐字节核对：磁盘写满时 cp 可能报错，也可能留下被截断的备份，两种都不能算"已备份"
            cp -p "${f}" "${bdir}/files/${key}" && cmp -s "${f}" "${bdir}/files/${key}" || return 1
            printf 'E\t%s\n' "${f}" >>"${bdir}/manifest" || return 1
        else
            printf 'N\t%s\n' "${f}" >>"${bdir}/manifest" || return 1
        fi
    done < <(_txnFiles)
    # nginx 站点配置在新事务里可能新增，同样需要记录"原先不存在"
    for f in atr_alone.conf atr_httpupgrade.conf atr_subscribe.conf; do
        grep -qF "${NGX_CONFD}/${f}" "${bdir}/manifest" || printf 'N\t%s\n' "${NGX_CONFD}/${f}" >>"${bdir}/manifest" || return 1
    done
    chmod 700 "${bdir}"
}

restoreFromBackup() { # restoreFromBackup <备份目录>  —— 任何一个文件没能恢复就返回 1（并列出来），绝不假装成功
    local bdir=$1 kind f key rc=0 tmp
    [[ -f "${bdir}/manifest" ]] || return 1
    while IFS=$'\t' read -r kind f; do
        key=$(printf '%s' "${f}" | sed 's#/#%#g')
        if [[ "${kind}" == "E" ]]; then
            # 同目录临时文件 + rename，再核对内容
            tmp="${f}.atr-restore.$$"
            if mkdir -p "$(dirname "${f}")" && cp -p "${bdir}/files/${key}" "${tmp}" && mv -f "${tmp}" "${f}" && cmp -s "${bdir}/files/${key}" "${f}"; then
                :
            else
                rm -f "${tmp}"
                echoContent red " ---> 恢复失败: ${f}"
                rc=1
            fi
        else
            rm -f "${f}"
            if [[ -e "${f}" ]]; then
                echoContent red " ---> 无法删除（应当不存在）: ${f}"
                rc=1
            fi
        fi
    done <"${bdir}/manifest"
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    return "${rc}"
}

# ----------------------------- 落盘 ------------------------------------------
# 把 <源文件> 换成 <目标>：同目录临时文件 + rename（崩溃或写满不会留下半截文件），然后核对内容
_commitFile() { # _commitFile <源> <目标> <模式>
    atomicWrite "$2" "$3" <"$1" && cmp -s "$1" "$2"
}
# 删除并确认确实没了
_removeLive() { # _removeLive <目标>
    rm -f -- "$1"
    [[ ! -e "$1" && ! -L "$1" ]]
}
# 把候选配置落到 live 位置（先配置，后 state）。每一步都检查，任何一步失败返回 1，由调用方回滚
_commitLive() { # _commitLive <stage 目录> <候选 state 文件>
    local stage=$1 st=$2 nf base mode
    mkdir -p "${SB_DIR}/conf" "${XRAY_DIR}/conf" "${NGX_CONFD}" || return 1
    if stateNeedsCore "${st}" sing-box; then _commitFile "${stage}/sing-box/config.json" "${SB_CONF}" 600 || return 1; else _removeLive "${SB_CONF}" || return 1; fi
    if stateNeedsCore "${st}" xray; then _commitFile "${stage}/xray/config.json" "${XRAY_CONF}" 600 || return 1; else _removeLive "${XRAY_CONF}" || return 1; fi
    for nf in "${NGX_CONFD}"/atr_*.conf; do
        [[ -e "${nf}" ]] && { _removeLive "${nf}" || return 1; }
    done
    for nf in "${stage}"/nginx/*.conf; do
        [[ -e "${nf}" ]] || continue
        base=$(basename "${nf}")
        mode=644
        [[ "${base}" == "atr_subscribe.conf" ]] && mode=600 # 里面有对等密钥
        _commitFile "${nf}" "${NGX_CONFD}/${base}" "${mode}" || return 1
    done
    _commitFile "${st}" "${ATR_STATE}" 600
}
# 服务和端口正常并不能证明落盘的就是候选内容；成功之前再核对一遍，不一致就当作失败
_verifyCommitted() { # _verifyCommitted <stage 目录> <候选 state 文件>
    local stage=$1 st=$2 nf bad=0 base
    cmp -s "${st}" "${ATR_STATE}" || { echoContent red " ---> 核对失败: state.json 与候选内容不一致"; bad=1; }
    if stateNeedsCore "${st}" sing-box; then cmp -s "${stage}/sing-box/config.json" "${SB_CONF}" || { echoContent red " ---> 核对失败: ${SB_CONF}"; bad=1; }; else [[ ! -e "${SB_CONF}" ]] || { echoContent red " ---> 核对失败: ${SB_CONF} 应当不存在"; bad=1; }; fi
    if stateNeedsCore "${st}" xray; then cmp -s "${stage}/xray/config.json" "${XRAY_CONF}" || { echoContent red " ---> 核对失败: ${XRAY_CONF}"; bad=1; }; else [[ ! -e "${XRAY_CONF}" ]] || { echoContent red " ---> 核对失败: ${XRAY_CONF} 应当不存在"; bad=1; }; fi
    for nf in "${stage}"/nginx/*.conf; do
        [[ -e "${nf}" ]] || continue
        cmp -s "${nf}" "${NGX_CONFD}/$(basename "${nf}")" || { echoContent red " ---> 核对失败: ${NGX_CONFD}/$(basename "${nf}")"; bad=1; }
    done
    for nf in "${NGX_CONFD}"/atr_*.conf; do
        [[ -e "${nf}" ]] || continue
        base=$(basename "${nf}")
        [[ -e "${stage}/nginx/${base}" ]] || { echoContent red " ---> 核对失败: ${nf} 不在候选内容里"; bad=1; }
    done
    return "${bad}"
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
    recoverTLSIfNeeded || return 1
    [[ -e "${TXN_MARK}" || -L "${TXN_MARK}" ]] || return 0
    local bdir rc=0
    lockAcquire || return 1
    if [[ -e "${TXN_MARK}" || -L "${TXN_MARK}" ]]; then
        bdir=$(cat "${TXN_MARK}" 2>/dev/null) || rc=1
        echoContent yellow "\n ---> 检测到上次操作未完成，正在从备份恢复: ${bdir}"
        if ((rc == 0)) && [[ -d "${bdir}" ]] && restoreFromBackup "${bdir}" && fwRollbackJournal "${bdir}/firewall.undo"; then
            SB_CHANGED=1
            X_CHANGED=1
            if ! applyServices "${ATR_STATE}" force || ! verifyRuntime "${ATR_STATE}"; then
                echoContent red " ---> 文件已恢复，但服务没有恢复正常；事务标记和备份仍保留"
                rc=1
            elif ! _removeLive "${TXN_MARK}"; then
                echoContent red " ---> 恢复后无法清除事务标记，已停止后续操作"
                rc=1
            else
                atrLog "recovered interrupted transaction from ${bdir}"
                echoContent green " ---> 已恢复到上次可用配置"
            fi
        else
            echoContent red " ---> 自动恢复失败，事务标记和备份仍保留；请检查 ${ATR_HOME}（备份目录: ${bdir}）"
            rc=1
        fi
    fi
    lockRelease
    return "${rc}"
}

# 放弃未完成的事务（atr recover --abandon）: 不再自动恢复，事务标记改名归档，备份目录原样保留。
# 之后以磁盘上现有的配置为准——它可能是变更前、变更后或恢复到一半的状态，所以必须由管理员确认
abandonTransaction() {
    if [[ -e "${TLS_TXN_MARK}" || -L "${TLS_TXN_MARK}" ]]; then
        echoContent red " ---> 证书事务必须先恢复，不支持放弃；请执行 ${ATR_CMD} recover"
        return 1
    fi
    local bdir arch
    if [[ ! -e "${TXN_MARK}" && ! -L "${TXN_MARK}" ]]; then
        echoContent green " ---> 没有未完成的事务"
        return 0
    fi
    bdir=$(cat "${TXN_MARK}" 2>/dev/null)
    echoContent yellow "\n ---> 未完成的事务，备份目录: ${bdir:-<标记无法读取>}"
    echoContent yellow "      放弃后不再自动恢复，之后以磁盘上现有的配置为准（可能是变更前、变更后或恢复到一半的状态）。"
    echoContent yellow "      备份目录不会因此删除（之后的修改只保留最近 10 份备份），需要时可以手动对照。"
    confirm "确认放弃这次恢复？" n || return 0
    lockAcquire || return 1
    # 确认期间没有持锁: 重新确认标记还在、而且还是刚才那一份
    if [[ ! -e "${TXN_MARK}" && ! -L "${TXN_MARK}" ]] || [[ "$(cat "${TXN_MARK}" 2>/dev/null)" != "${bdir}" ]]; then
        lockRelease
        echoContent yellow " ---> 事务标记在确认期间发生了变化（可能已被另一个操作处理），没有做任何改动，请重新查看"
        return 1
    fi
    arch="${ATR_HOME}/.txn.abandoned.$(date +%Y%m%d-%H%M%S)"
    if ! mv -f -- "${TXN_MARK}" "${arch}" || [[ -e "${TXN_MARK}" || -L "${TXN_MARK}" ]]; then
        lockRelease
        echoContent red " ---> 无法移走事务标记 ${TXN_MARK}"
        return 1
    fi
    atrLog "transaction ABANDONED by the administrator: marker archived as ${arch}, backup=${bdir}"
    lockRelease
    echoContent green " ---> 已放弃恢复，事务标记已归档为 ${arch}"
    if [[ -e "${ATR_STATE}" ]] && ! jq -e . "${ATR_STATE}" >/dev/null 2>&1; then
        echoContent red " ---> 注意: ${ATR_STATE} 不是合法的 JSON，需要先从备份目录手动恢复它"
    fi
    echoContent yellow "      建议先执行 ${ATR_CMD} status 检查，再执行 ${ATR_CMD} restart 按当前配置重新应用全部服务"
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
    if stateNeedsNginx "${st}"; then
        ensureNginx || return 1
        if ! ensureNginxAccount; then
            echoContent red " ---> 无法创建 nginx 专用账号 ${NGX_USER}（需要系统提供 useradd），未做任何改动"
            return 1
        fi
    fi
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

# 启用/更新 nginx 实例: 专用账号 -> 目录权限 -> 主配置 -> 单元 -> 重启。任何一步失败都返回 1。
# 权限必须先于配置和重启切换到"专用组可读、其他用户不可读"的模型，且失败不能只警告后继续。
activateNginx() { # activateNginx <state.json>
    local st=$1
    findNginxBin || ensureNginx || return 1
    if ! ensureNginxAccount; then
        echoContent red " ---> 无法创建 nginx 专用账号 ${NGX_USER}（需要系统提供 useradd）"
        return 1
    fi
    if ! applyHomePerms 1; then
        echoContent red " ---> 设置安装目录/订阅目录的权限失败，请检查 ${ATR_HOME} 的属主与权限"
        return 1
    fi
    selinuxAllowNginxPorts "${st}"
    writeNginxMainConf || return 1
    writeUnit nginx || return 1
    serviceEnable "${NGX_UNIT}" || return 1
    systemctl restart "${NGX_UNIT}" >/dev/null 2>&1 || {
        echoContent red " ---> 重启服务失败: ${NGX_UNIT}（未能启动），最近日志:"
        serviceLogTail "${NGX_UNIT}" 8
        return 1
    }
}

# 把已安装的 nginx 迁移到"专用账号 + 受限权限"模型（旧版安装升级用）并确认它起来了。失败返回 1，
# 此时调用方不得发布任何含凭据的文件。
migrateNginxModel() {
    stateNeedsNginx "${ATR_STATE}" || return 0
    activateNginx "${ATR_STATE}" || return 1
    if ! waitServiceActive "${NGX_UNIT}" 10; then
        echoContent red " ---> nginx 未能以新模型启动，最近日志:"
        serviceLogTail "${NGX_UNIT}" 8
        return 1
    fi
    atrLog "nginx migrated to the dedicated-account model"
}

# ----------------------------- 服务应用 / 验证 --------------------------------
# 停止并确认停止；未安装的单元不必 disable。
_stopManagedService() {
    local unit=$1
    if serviceActive "${unit}"; then
        serviceStop "${unit}" || {
            echoContent red " ---> 停止服务失败: ${unit}"
            return 1
        }
    fi
    if serviceActive "${unit}"; then
        echoContent red " ---> 服务仍在运行，应当停止: ${unit}"
        return 1
    fi
    if [[ -f "${ATR_SYSTEMD_DIR}/${unit}.service" ]]; then
        serviceDisable "${unit}" || return 1
    fi
    return 0
}

# 按 state 启停各服务；某核心无协议则停止并禁用
applyServices() { # applyServices <state.json> [force]
    local st=$1 force=${2:-} needNgx=0 needSB=0 needX=0
    stateNeedsNginx "${st}" && needNgx=1
    stateNeedsCore "${st}" sing-box && needSB=1
    stateNeedsCore "${st}" xray && needX=1
    if ((needNgx)); then
        activateNginx "${st}" || return 1
    else
        _stopManagedService "${NGX_UNIT}" || return 1
        applyHomePerms 0 || return 1
    fi
    if ((needSB)); then
        UNIT_REWRITTEN=0
        writeUnit sing-box || return 1
        serviceEnable "${SB_UNIT}" || return 1
        if [[ -n "${force}" || "${SB_CHANGED:-1}" == "1" || "${UNIT_REWRITTEN}" == "1" ]] || ! serviceActive "${SB_UNIT}"; then
            systemctl restart "${SB_UNIT}" >/dev/null 2>&1 || {
                echoContent red " ---> 重启服务失败: ${SB_UNIT}（未能启动），最近日志:"
                serviceLogTail "${SB_UNIT}" 12
                return 1
            }
        fi
    else
        _stopManagedService "${SB_UNIT}" || return 1
    fi
    if ((needX)); then
        UNIT_REWRITTEN=0
        writeUnit xray || return 1
        serviceEnable "${XRAY_UNIT}" || return 1
        if [[ -n "${force}" || "${X_CHANGED:-1}" == "1" || "${UNIT_REWRITTEN}" == "1" ]] || ! serviceActive "${XRAY_UNIT}"; then
            systemctl restart "${XRAY_UNIT}" >/dev/null 2>&1 || {
                echoContent red " ---> 重启服务失败: ${XRAY_UNIT}（未能启动），最近日志:"
                serviceLogTail "${XRAY_UNIT}" 12
                return 1
            }
        fi
    else
        _stopManagedService "${XRAY_UNIT}" || return 1
    fi
    if declare -F reconcileHopRules >/dev/null; then reconcileHopRules "${st}" || return 1; fi
    reconcileMonitor "${st}" || return 1
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
        if ((!need)); then
            if serviceActive "${u}"; then
                echoContent red " ---> 服务 ${u} 应当停止但仍在运行"
                ok=1
            fi
            continue
        fi
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

# ----------------------------- 撤销收口（订阅发布目录）-------------------------
# 关闭订阅发布: 清空已发布的内容（失败时宁可不提供订阅，也不留下旧链接或可读的残片）
_closeSubscription() {
    [[ -d "${SUB_DIR}" ]] || return 0
    local first
    find "${SUB_DIR}" -mindepth 1 -delete 2>/dev/null
    # 必须确认真的删干净了（只读文件系统等情况下删除会失败，nginx 却会继续提供旧内容）；
    # 复查本身失败（读不了目录）同样不能当成"已清空"，一律走下面停止 nginx 的兜底
    if first=$(_findFirst "${SUB_DIR}" -mindepth 1) && [[ -z "${first}" ]]; then return 0; fi
    echoContent red " ---> 无法删除已发布的订阅文件，改为停止 nginx，确保不再提供旧订阅"
    serviceStop "${NGX_UNIT}"
    if serviceActive "${NGX_UNIT}"; then
        echoContent red " ---> nginx 也没能停止！请立即手动处理: systemctl stop ${NGX_UNIT}，并检查 ${SUB_DIR} 所在的文件系统"
        return 2
    fi
    echoContent yellow " ---> nginx 已停止（订阅与伪装站暂不可用）。排除文件系统问题后执行 ${ATR_CMD} restart 恢复"
    return 1
}
# 订阅的 nginx 配置是不是当前格式（对等端点按 peer/<用户名>/<类型> 取文件，并由配置核对密钥）
nginxSubLayoutCurrent() {
    grep -q '^# atr-sub-layout 2$' "${NGX_CONFD}/atr_subscribe.conf" 2>/dev/null
}
# 撤销收口的实际动作: 按白名单重建发布目录。只把 state 里仍然有效的名字复制进新目录，整体换入，旧目录按固定路径删除。
# 被撤销的令牌、旧版布局里以对等密钥命名的目录，名字都不会出现在任何外部命令的参数里（rm 只拿到固定的 .old 路径，
# 在它自己的递归里删除）；仍然有效的文件也不会先被删掉、再等下一次发布。
# 源文件必须用 < 读: _copyFile 的 cat -- "$1" 会把源路径（也就是有效令牌）放进 cat 的命令行。
# 由 _pruneRevokedSubscription 在持锁时调用，读取它的 valid / users / peer（Bash 动态作用域：不要把它当独立函数调用）。
# 旧版 peer 布局的内容不会搬过来；要不要重新发布由 _subscriptionIncomplete 按磁盘状态判断
_rebuildSubDir() {
    local tmp kind t u k fail=0 old_umask
    rm -rf "${SUB_DIR}".prune.* 2>/dev/null # 上次崩溃留下的（持锁，所以不会是别人正在用的）
    old_umask=$(umask)
    umask 077
    tmp=$(mktemp -d "${SUB_DIR}.prune.XXXXXX") || {
        umask "${old_umask}"
        return 1
    }
    for kind in default clashMeta clashMetaProfiles sing-box sing-box_profiles; do
        mkdir -p "${tmp}/${kind}" || fail=1
        for t in "${!valid[@]}"; do
            [[ -f "${SUB_DIR}/${kind}/${t}" && ! -L "${SUB_DIR}/${kind}/${t}" ]] || continue
            cat <"${SUB_DIR}/${kind}/${t}" >"${tmp}/${kind}/${t}" || fail=1
        done
    done
    if [[ -n "${peer}" && -d "${SUB_DIR}/peer" && ! -L "${SUB_DIR}/peer" ]]; then
        # 第二层出现目录 = 旧版 peer/<密钥>/<用户>/ 布局；find 失败（无法确认）同样按旧布局处理。这两种情况都不搬 peer 内容
        # （含密钥的目录名无法安全处理），之后 _subscriptionIncomplete 会发现 peer 文件缺失，按新布局重新发布
        local sub
        if sub=$(_findFirst "${SUB_DIR}/peer" -mindepth 2 -type d) && [[ -z "${sub}" ]]; then
            for u in "${!users[@]}"; do # 新布局 peer/<用户名>/<类型>: 用户名不是凭据
                for k in default clashMeta sing-box_profiles; do
                    [[ -f "${SUB_DIR}/peer/${u}/${k}" && ! -L "${SUB_DIR}/peer/${u}/${k}" ]] || continue
                    { mkdir -p "${tmp}/peer/${u}" && cat <"${SUB_DIR}/peer/${u}/${k}" >"${tmp}/peer/${u}/${k}"; } || fail=1
                done
            done
        fi
    fi
    umask "${old_umask}"
    if ((fail == 0)) && _applySubTreePerms "${tmp}" && _swapSubDir "${tmp}"; then
        return 0
    fi
    rm -rf "${tmp}"
    return 1
}
# 用 staging 目录整体替换 SUB_DIR（旧令牌对应的文件随旧目录一起消失）
_swapSubDir() { # _swapSubDir <staging 目录>
    local stage=$1
    rm -rf "${SUB_DIR}.old"
    if [[ -e "${SUB_DIR}" ]]; then mv "${SUB_DIR}" "${SUB_DIR}.old" || return 1; fi
    if ! mv "${stage}" "${SUB_DIR}"; then
        [[ -e "${SUB_DIR}.old" ]] && mv "${SUB_DIR}.old" "${SUB_DIR}"
        return 1
    fi
    rm -rf "${SUB_DIR}.old"
}
# 撤销收口。按当前 state 清除已发布目录里不再有效的内容：失效令牌对应的文件、已删除用户的文件、对等分享关闭后的 peer/、
# 以及旧版目录布局的遗留；订阅整体关闭时清空整个目录。只复制仍有效的文件、整体换入（不渲染、不联网），所以几乎不会失败；
# 删不掉（或删完复查仍有）就改为停止 nginx。必须持锁调用：applyStaged 提交之后、每次发布之前、启动对账都会用到。
#   _pruneRevokedSubscription        清除。0=已确认干净  1=删不掉，已改为停止 nginx（旧订阅不会再被提供）  2=连 nginx 也没能停止
#   _pruneRevokedSubscription check  只检查不动。0=干净  10=存在应被撤销的内容
_pruneRevokedSubscription() {
    local mode=${1:-prune}
    [[ -d "${SUB_DIR}" ]] || return 0
    if [[ "$(S '.nginx.subscribe.enabled')" != "true" ]]; then
        local first
        if first=$(_findFirst "${SUB_DIR}" -mindepth 1) && [[ -z "${first}" ]]; then return 0; fi # 扫描失败不算"空"
        [[ "${mode}" == check ]] && return 10
        _closeSubscription
        return
    fi
    local -A valid=() users=()
    local u t kind f name d sub stale=0 peer
    while IFS=$'\t' read -r u t; do
        [[ -z "${u}" ]] && continue
        users["${u}"]=1
        [[ -n "${t}" ]] && valid["${t}"]=1
    done < <(S '.users[]? | "\(.name)\t\(.sub_token // "")"')
    peer=$(S '.nginx.subscribe.peer_key // ""')
    # 先只检查: 这里只用 shell 内建的测试，不把任何条目名交给外部命令
    for kind in default clashMeta clashMetaProfiles sing-box sing-box_profiles; do
        for f in "${SUB_DIR}/${kind}"/*; do
            [[ -e "${f}" || -L "${f}" ]] || continue
            name=${f##*/}
            [[ "${name}" =~ ^[A-Za-z0-9]+$ && -n "${valid[${name}]:-}" && -f "${f}" && ! -L "${f}" ]] && continue
            stale=1
        done
    done
    if [[ -d "${SUB_DIR}/peer" || -L "${SUB_DIR}/peer" ]]; then
        if [[ -z "${peer}" ]]; then
            stale=1
        else
            for d in "${SUB_DIR}/peer"/*; do
                [[ -e "${d}" || -L "${d}" ]] || continue
                name=${d##*/}
                # 只认 peer/<现存用户>/ 下的普通文件。条件的顺序不能改: 先确认 name 是现存用户名，find 才会拿到这个路径
                # （旧版 peer/<密钥>/<用户>/ 布局里 name 就是对等密钥，绝不能出现在 find 的参数里）。find 失败按"过期"处理（触发重建）
                if [[ -n "${users[${name}]:-}" && -d "${d}" && ! -L "${d}" ]] && sub=$(_findFirst "${d}" -mindepth 1 \( -type d -o -type l \)) && [[ -z "${sub}" ]]; then
                    continue
                fi
                stale=1
                break
            done
        fi
    fi
    # 其余不认识的顶层条目（旧版本遗留）
    for f in "${SUB_DIR}"/* "${SUB_DIR}"/.[!.]*; do
        [[ -e "${f}" || -L "${f}" ]] || continue
        case "${f##*/}" in
        default | clashMeta | clashMetaProfiles | sing-box | sing-box_profiles | peer) ;;
        *) stale=1 ;;
        esac
    done
    if [[ "${mode}" == check ]]; then
        ((stale)) && return 10
        return 0
    fi
    ((stale)) || return 0
    # 按白名单重建（不逐项删除），重建完再扫一遍确认真的干净了；否则改为停止 nginx
    if _rebuildSubDir && _pruneRevokedSubscription check; then
        return 0
    fi
    echoContent red " ---> 无法清除已被撤销的订阅文件（文件系统只读或没有权限？）"
    _closeSubscription
}
# 订阅已启用，但已发布的内容不完整吗？0 = 不完整（需要重新发布）。按生成逻辑检查每个用户应有的全部类型，只看磁盘上的实际状态，不依赖任何进程内标记，
# 所以发布失败、进程中断（包括 _swapSubDir 两次 mv 之间：目录不在，或之后被 mkdir -p 建成空目录）、开机任务只撤下没发布，
# 下一次运行都会再识别出来。订阅或对等分享已关闭时不算不完整：修复检测不会重新打开分享
_subscriptionIncomplete() {
    [[ "$(S '.nginx.subscribe.enabled')" == "true" ]] || return 1
    local u t peer kind
    nginxSubLayoutCurrent || return 0
    peer=$(S '.nginx.subscribe.peer_key // ""')
    while IFS=$'\t' read -r u t; do
        [[ -n "${u}" ]] || continue
        [[ -n "${t}" ]] || return 0
        # 这四种每个用户都会生成（AnyTLS+Reality 这类 mihomo 不支持的协议只是不出现在 clashMeta 里，文件照样有）
        for kind in default clashMeta clashMetaProfiles sing-box_profiles; do
            [[ -f "${SUB_DIR}/${kind}/${t}" ]] || return 0
        done
        # sing-box 完整配置只在这个用户有 sing-box 能用的节点时生成，即已发布的 sing-box_profiles 不是空数组（bash 内建读取，不调外部命令）
        if [[ "$(<"${SUB_DIR}/sing-box_profiles/${t}")" != "[]" ]]; then
            [[ -f "${SUB_DIR}/sing-box/${t}" ]] || return 0
        fi
        if [[ -n "${peer}" ]]; then
            for kind in default clashMeta sing-box_profiles; do
                [[ -f "${SUB_DIR}/peer/${u}/${kind}" ]] || return 0
            done
        fi
    done < <(S '.users[]? | "\(.name)\t\(.sub_token // "")"')
    return 1
}
# 启动时对账：提交之后、清理之前进程被中断，或有人手工动过发布目录，都会留下应被撤销的内容；发布失败或被中断则会留下不完整的发布目录。
# 只读检查不加锁，真有问题才加锁，并在锁内重新判断（等锁期间别的进程可能已经处理完）。先清除应撤销的内容，再按磁盘状态判断
# 要不要重新发布。重新发布失败只提示（应撤销的内容已经清除），下一次运行会再试；strict（atr recover）时返回非零。
# no-republish: 开机时的 apply-hop 只清除不发布，留给下一次运行
reconcileSubscription() { # reconcileSubscription [no-republish|strict]
    stateExists || return 0
    local stale=0 rc=0
    if [[ -d "${SUB_DIR}" ]]; then
        _pruneRevokedSubscription check
        (($? == 10)) && stale=1
    fi
    ((stale)) || _subscriptionIncomplete || return 0
    lockAcquire || {
        echoContent red " ---> 订阅目录需要清理或重新发布，但拿不到锁，没有处理。请稍后执行 ${ATR_CMD} restart"
        return 1
    }
    if ! _requireCleanTransaction; then
        lockRelease
        return 1
    fi
    if ((stale)); then
        echoContent yellow "\n ---> 检测到订阅目录里有已被撤销的内容或旧版目录布局（上次操作可能被中断，或刚从旧版本升级），正在清除…"
        _pruneRevokedSubscription
        rc=$?
    fi
    if ((rc == 0)) && _subscriptionIncomplete; then
        if [[ "${1:-}" == no-republish ]] || ! declare -F generateSubscription >/dev/null; then
            echoContent yellow " ---> 已发布的订阅不完整，这次（开机任务）不重新发布；下一次运行 ${ATR_CMD} 时会自动补发"
            atrLog "reconcile: subscription incomplete, republish deferred"
        else
            echoContent yellow " ---> 已发布的订阅不完整（上次发布失败或被中断，或刚从旧版目录布局升级），正在按当前配置重新发布…"
            if ! generateSubscription; then
                echoContent red " ---> 重新发布失败（应被撤销的内容已经清除）。下一次运行 ${ATR_CMD} 会自动重试，也可以排除问题后执行 ${ATR_CMD} restart"
                atrLog "reconcile: republish of an incomplete subscription FAILED"
                [[ "${1:-}" == strict ]] && rc=1
            fi
        fi
    fi
    lockRelease
    return "${rc}"
}

# ----------------------------- 事务主体 --------------------------------------
# applyStaged [说明]  —— 应用 NEW_STATE；成功返回 0 并更新 state.json；任何一步失败都保持/恢复原状
# 本机所有网卡的地址（/32 与 /128），JSON 数组。「公网出口」模式把它们也列入禁止访问，
# 否则客户端可以直接连本机的公网 IP 来访问本机上只监听在内部的服务
egressLocalIPs() {
    local raw a
    if command -v ip >/dev/null 2>&1; then
        raw=$(ip -o addr show 2>/dev/null | awk '{print $4}' | sed 's#/.*##')
    else
        raw=$(hostname -I 2>/dev/null | tr ' ' '\n')
    fi
    while IFS= read -r a; do
        a=${a%%%*}
        if isIPv4 "${a}"; then
            echo "${a}/32"
        elif [[ "${a}" == *:* && "${a}" =~ ^[0-9a-fA-F:]+$ ]]; then
            echo "${a,,}/128"
        fi
    done <<<"${raw}" | sort -u | jq -R . | jq -sc .
}

# 本机的公网地址（NAT / 云厂商 1:1 映射时它不在任何网卡上，egressLocalIPs 看不到）。用 getPublicIP 探测（Cloudflare trace，
# 取不到再试另外几个 HTTPS 服务），只接受合法 IP；打印 JSON 数组（/32、/128），一个都没探测到返回 1。会联网: 只在安装、
# atr restart 和出口访问模式菜单这些低频时机调用，不在 applyStaged 里调用，也不要在持锁时调用
egressDetectPublicIPs() {
    local a out=()
    if [[ -n "${ATR_PUBLIC_IP_ENV}" ]]; then # 管理员指定的地址优先，不联网
        a=${ATR_PUBLIC_IP_ENV}
        if isIPv4 "${a}"; then out+=("${a}/32"); elif isIPv6 "${a}"; then out+=("${a,,}/128"); fi
        ((${#out[@]})) || return 1
        printf '%s\n' "${out[@]}" | jq -R . | jq -sc 'unique'
        return 0
    fi
    _PUBLIC_IP_CACHE_4=""
    _PUBLIC_IP_CACHE_6=""
    a=$(getPublicIP 4)
    isIPv4 "${a}" && out+=("${a}/32")
    a=$(getPublicIP 6)
    isIPv6 "${a}" && out+=("${a,,}/128")
    ((${#out[@]})) || return 1
    printf '%s\n' "${out[@]}" | jq -R . | jq -sc 'unique'
}
egressDetectFailedHint() {
    echoContent yellow " ---> 未能探测本机的公网地址（沿用上次的结果）。如果这台机器在 NAT 后面，公网地址不在网卡上，"
    echoContent yellow "      请在 11.分流工具 → 6.出口访问模式 → 3 里手动补充（egress.extra_ips）"
}
EGRESS_CDN_NOTE="如果本机在 CDN/反代后面，或出站经过代理/隧道（例如系统级 WARP），探测值可能不是本机的公网地址，请在 11.分流工具 → 6 里用手动地址（egress.extra_ips）覆盖"
EGRESS_PUBLIC_MAX_AGE=$((7 * 86400))
# 把探测到的本机公网地址写进暂存状态（只在公网出口模式、且没有关闭自动探测时）。探测失败保留原来的值并提示手动补充，从不让调用方失败。
# 在 stagedBegin 之后、applyStaged 之前调用（会联网，所以不要在持锁时调用）
stagedRefreshEgressPublicIPs() {
    [[ "$(stagedGet '.egress.mode // ""')" == "public" ]] || return 0
    [[ "$(stagedGet '.egress.public_detect != false')" == "true" ]] || return 0 # 注意不能写 // true: jq 的 // 把 false 也当成空
    local ips
    if ips=$(egressDetectPublicIPs); then
        stagedEdit --argjson ips "${ips}" --argjson t "$(date +%s)" '.egress.public_ips=$ips | .egress.public_ips_at=$t' || return 0
        echoContent green " ---> 本机公网地址: $(jq -r 'join(", ")' <<<"${ips}")（公网出口模式会禁止客户端经节点访问它）"
        echoContent yellow "      ${EGRESS_CDN_NOTE}"
    else
        egressDetectFailedHint
    fi
    return 0
}
# 公网出口模式下，本机公网地址超过 7 天没刷新（或从来没探测过）就提示一次（打开菜单、atr status 时）
egressPublicStaleNotice() {
    stateExists || return 0
    [[ "$(S '.egress.mode // ""')" == "public" && "$(S '.egress.public_detect != false')" == "true" ]] || return 0
    local at now
    at=$(S '.egress.public_ips_at // 0')
    [[ "${at}" =~ ^[0-9]+$ ]] || at=0
    now=$(date +%s)
    ((now - at > EGRESS_PUBLIC_MAX_AGE)) || return 0
    if ((at == 0)); then
        echoContent yellow "\n ---> 出口访问模式: 还没有探测过本机的公网地址（NAT 后的公网 IP 不在网卡上，探测后才能禁止客户端经节点访问它）"
    else
        echoContent yellow "\n ---> 出口访问模式: 本机公网地址上次探测是 $(((now - at) / 86400)) 天前"
    fi
    echoContent yellow "      执行 ${ATR_CMD} restart 刷新，或在 11.分流工具 → 6.出口访问模式 → 2 里重新探测"
}

applyStaged() {
    local why=${1:-变更} ts stage bdir st oldst errs core
    # Bash 动态作用域：fwOpen 的记录只属于本次事务，嵌套调用也不会污染外层。
    local FW_CREATED="" FW_JOURNAL_FILE="" fwCleanupFailed=0
    [[ -n "${NEW_STATE}" ]] || {
        echoContent red " ---> 内部错误: 没有待应用的状态"
        return 1
    }
    lockAcquire || return 1
    if ! _requireCleanTransaction; then lockRelease; return 1; fi
    stateInit || { lockRelease; return 1; }
    if [[ -n "${STAGED_BASE}" && "$(stateRevision)" != "${STAGED_BASE}" ]]; then
        echoContent red " ---> 本次操作开始之后，配置已被另一个操作修改过（例如另一个终端或定时任务）。为避免覆盖对方的修改，本次操作已取消，请重新进行"
        NEW_STATE=""
        STAGED_BASE=""
        lockRelease
        return 1
    fi
    ts=$(date +%Y%m%d-%H%M%S)
    stage="${ATR_TMP:-/tmp}/stage.${ts}.$$"
    mkdir -p "${stage}/sing-box" "${stage}/xray" "${stage}/nginx"
    st="${stage}/state.json"
    # 公网出口模式: 每次应用都刷新一次本机网卡地址（渲染是纯函数，所以地址要先进入 state）
    if [[ "$(stagedGet '.egress.mode // ""')" == "public" ]]; then
        stagedEdit --argjson ips "$(egressLocalIPs)" '.egress.local_ips=$ips' || {
            rm -rf "${stage}"
            lockRelease
            return 1
        }
    fi
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
    renderNginxConfs "${st}" "${stage}/nginx" || { rm -rf "${stage}"; lockRelease; return 1; }

    # 4) 用真实内核/nginx 校验
    if ! checkRendered "${stage}" "${st}"; then
        rm -rf "${stage}"
        lockRelease
        return 1
    fi

    # 5) 备份 + 事务标记（崩溃后可恢复）。备份和标记没有确认写成功之前不能动 live 文件，否则之后失败就没有可恢复的依据
    bdir=$(mktemp -d "${BACKUP_DIR}/${ts}.XXXXXX") || { rm -rf "${stage}"; lockRelease; return 1; }
    if ! backupLive "${bdir}"; then
        echoContent red " ---> 无法完整备份当前配置（磁盘空间或权限问题？）。为保证随时可以回滚，本次没有做任何改动"
        rm -rf "${bdir}" "${stage}"
        lockRelease
        return 1
    fi
    if ! { printf '%s' "${bdir}" | atomicWrite "${TXN_MARK}" 600 && [[ "$(cat "${TXN_MARK}" 2>/dev/null)" == "${bdir}" ]] && sync -f "${ATR_HOME}"; }; then
        echoContent red " ---> 无法写入事务标记 ${TXN_MARK}。本次没有做任何改动"
        rm -f "${TXN_MARK}" 2>/dev/null
        rm -rf "${bdir}" "${stage}"
        lockRelease
        return 1
    fi
    oldst="${bdir}/files/$(printf '%s' "${ATR_STATE}" | sed 's#/#%#g')"
    [[ -f "${oldst}" ]] || oldst=""
    FW_JOURNAL_FILE="${bdir}/firewall.undo"

    # 6) 判断各核心配置是否有变化（无变化则不重启）
    SB_CHANGED=1
    X_CHANGED=1
    if [[ -n "${oldst}" && "$(jq -r '.tls.cert_sha256 // ""' "${oldst}")" == "$(jq -r '.tls.cert_sha256 // ""' "${st}")" ]]; then
        cmp -s "${stage}/sing-box/config.json" "${SB_CONF}" 2>/dev/null && SB_CHANGED=0
        cmp -s "${stage}/xray/config.json" "${XRAY_CONF}" 2>/dev/null && X_CHANGED=0
    fi

    # 7) 原子落盘（先配置，后 state），逐项检查并核对内容；8) 防火墙放行（新增的先开，回收的等成功后再关）；
    # 9) 启停服务 + 验证运行状态 + 核对落盘内容就是候选内容。任何一环失败都进入回滚
    local failWhy="" addList="" restored=1
    if ! _commitLive "${stage}" "${st}"; then
        failWhy="配置文件没能写入（磁盘已满、只读文件系统或权限问题？）"
    else
        addList=$(fwDiff "${oldst}" "${st}" add)
        if [[ -n "${addList}" ]] && ! fwApplyList open <<<"${addList}"; then
            failWhy="防火墙放行失败（配置即使生效，客户端也连不上）"
        else
            echoContent green " ---> 应用配置并重启服务…"
            if ! applyServices "${st}" || ! verifyRuntime "${st}"; then
                failWhy="新配置运行异常"
            elif ! _verifyCommitted "${stage}" "${st}"; then
                failWhy="落盘的配置与候选内容不一致"
            fi
        fi
    fi
    if [[ -n "${failWhy}" ]]; then
        echoContent red "\n ---> ${failWhy}，正在自动回滚到变更前的状态…"
        restoreFromBackup "${bdir}" || restored=0
        fwRollbackJournal "${FW_JOURNAL_FILE}" || restored=0
        SB_CHANGED=1
        X_CHANGED=1
        if ((restored)); then
            if ! applyServices "${ATR_STATE}" force || ! verifyRuntime "${ATR_STATE}"; then
                restored=0
            elif ! _removeLive "${TXN_MARK}"; then
                restored=0
            fi
        fi
        if ((restored)); then
            if [[ -n "${oldst}" ]]; then
                echoContent green " ---> 已回滚，旧配置运行正常"
            else
                echoContent yellow " ---> 首次安装失败，已清理本次改动"
            fi
        else
            echoContent red " ---> 回滚没有完整完成！事务标记和备份已保留（${bdir}）；已拒绝后续修改。排除文件或服务错误后执行 ${ATR_CMD} recover 重试（status / show / log 仍可使用）"
        fi
        atrLog "ROLLBACK (${why}) reason=${failWhy} restored=${restored} backup=${bdir}"
        rm -rf "${stage}"
        lockRelease
        return 1
    fi

    # 10) 成功: 回收不再需要的端口、清理标记、保留备份
    local delList prc=0
    delList=$(fwDiff "${oldst}" "${st}" remove)
    if [[ -n "${delList}" ]] && ! fwApplyList close <<<"${delList}"; then fwCleanupFailed=1; fi
    rm -f "${TXN_MARK}"
    if [[ -e "${TXN_MARK}" ]]; then
        # 标记留着，下次运行会把它当作"上次操作未完成"并回滚到旧配置——必须明说，不能报成功
        echoContent red " ---> 配置已写入并运行正常，但无法删除事务标记 ${TXN_MARK}：下次运行脚本时它会被当作未完成的操作，并把配置回滚到旧版本。请手动删除该文件（回滚用的备份在 ${bdir}）"
        atrLog "APPLIED but txn marker could not be removed (${why}) backup=${bdir}"
        rm -rf "${stage}"
        lockRelease
        NEW_STATE=""
        STAGED_BASE=""
        return 1
    fi
    pruneBackups
    atrLog "APPLIED (${why}) backup=${bdir}"
    rm -rf "${stage}"
    # 11) 撤销收口：新 state 已提交，已发布目录里属于旧令牌/已删除用户/已关闭的订阅的内容必须在这里（仍持有锁）清除，
    # 不依赖后面的发布能不能成功。清不掉就改为停止 nginx；连这也做不到则明确报告"撤销未完成"
    _pruneRevokedSubscription || prc=$?
    lockRelease
    NEW_STATE=""
    STAGED_BASE=""
    if ((prc >= 2)); then
        echoContent red " ---> 配置已写入，但「撤销未完成」：已发布的订阅目录里仍留有应被撤销的文件，nginx 也没能停止（见上面的提示）。请先处理再继续使用订阅"
        atrLog "APPLIED but subscription revocation incomplete (${why}) rc=${prc}"
        return 3
    fi
    if ((fwCleanupFailed)); then
        echoContent red " ---> 配置已生效，但旧防火墙规则没有完整回收；请按上面的提示手动处理，未报告全部成功"
        return 1
    fi
    echoContent green " ---> 配置已生效（${why}）"
    return 0
}

# 当前配置不变，仅重启（证书续签 hook / 手动重启使用）
# 公网出口模式记录的本机网卡地址与现在的网卡地址不一致吗（IP 变了、加了网卡）
egressAddrsStale() {
    local cur old
    cur=$(egressLocalIPs | jq -c 'sort') || return 1
    old=$(S -c '(.egress.local_ips // []) | sort')
    [[ "${cur}" != "${old}" ]]
}

reloadAll() {
    stateExists || return 1
    local rc=0 pubips="" pubok=0 need=0 at now
    # 本机公网地址要联网探测（最多几十秒）: 在拿锁之前做，锁内只比较、写入
    if [[ "$(S '.egress.mode // ""')" == "public" && "$(S '.egress.public_detect != false')" == "true" ]]; then
        if pubips=$(egressDetectPublicIPs); then pubok=1; else egressDetectFailedHint; fi
    fi
    lockAcquire || return 1
    if ! _requireCleanTransaction; then
        lockRelease
        return 1
    fi
    SB_CHANGED=1
    X_CHANGED=1
    if [[ "$(S '.egress.mode // ""')" == "public" ]]; then
        # 本机地址列表只在应用配置时刷新；网卡地址或公网地址变了（或公网地址的探测时间已超过一天）就先走一次完整的应用
        egressAddrsStale && need=1
        if ((pubok)); then
            at=$(S '.egress.public_ips_at // 0')
            [[ "${at}" =~ ^[0-9]+$ ]] || at=0
            now=$(date +%s)
            [[ "$(jq -c 'sort' <<<"${pubips}")" != "$(S -c '(.egress.public_ips // []) | sort')" ]] && need=1
            ((now - at > 86400)) && need=1
        fi
    fi
    if ((need)); then
        stagedBegin
        if ((pubok)); then
            stagedEdit --argjson ips "${pubips}" --argjson t "$(date +%s)" '.egress.public_ips=$ips | .egress.public_ips_at=$t' || rc=1
        fi
        if ((rc == 0)); then
            applyStaged "刷新本机地址（出口访问模式）" || rc=1
        fi
        ((rc == 0)) || stagedDiscard
    fi
    if ((rc == 0)); then
        applyServices "${ATR_STATE}" force || rc=1
        verifyRuntime "${ATR_STATE}" || rc=1
    fi
    # 订阅文件必须与 state 保持一致（令牌或权限模型迁移之后要重新发布，旧文件随之撤销）
    if ((rc == 0)) && [[ "$(S '.nginx.subscribe.enabled')" == "true" ]]; then
        generateSubscription || rc=1
    fi
    lockRelease
    return "${rc}"
}

# 升级内核后重启并验证（upgradeCore 使用）
restartCoreChecked() { # restartCoreChecked <core>
    local core=$1 unit proto port rc=0
    unit=$(coreUnit "${core}")
    systemctl restart "${unit}" >/dev/null 2>&1 || return 1
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
#      sing-box 的 naive 出站需要 libcronet.so 与二进制放在同一目录（官方压缩包里带有，本脚本只安装
#      单个二进制；服务端的 naive 入站不依赖它）。客户端是否带这个库因人而异，故 naive 不放进
#      sing-box 客户端配置，只给 naive+https 链接与 NaiveProxy 官方客户端配置。
# =============================================================================

read -r -d '' JQ_NODES <<'EOF'
. as $S
| ($S.domain // "") as $D
| ($S.path // "") as $P

| ($S.protocols // {}) as $PR
| (($S.cdn // "") | split(",") | map(select(length > 0))) as $cdns
| def realityOf($id): if ($S.reality_mode // "shared") == "independent" then $S.protocols[$id].reality // {} else $S.reality // {} end;
  def short($id): ($reg | map(select(.id == $id)) | .[0].short // $id);
  def cdnCapable($id): ($reg | map(select(.id == $id)) | .[0].cdn // false);
  def isReality($id): ($reg | map(select(.id == $id)) | .[0].reality // false);
  def vport: ($PR.vless_vision_tls.port // 443);
  def portof($id; $c): if (($id == "vless_ws" or $id == "vmess_ws" or $id == "trojan") and $c.core == "xray") then vport else $c.port end;
  # ---- 链接工具 ----
  def hostp($h): if ($h | contains(":")) then "[" + $h + "]" else $h end;
  def q($pairs): $pairs | map(.[0] + "=" + .[1]) | join("&");
  def e: @uri;
  # ---- 节点基础字段 ----
  def mk($u; $id; $c; $server; $suffix): realityOf($id) as $RE |
    {name: ($u.name + "-" + short($id) + $suffix), user: $u.name, proto: $id, core: $c.core,
     uuid: $u.uuid, password: $u.password, server: $server, port: portof($id; $c),
     sni: "", host: "", path: "", pbk: ($RE.public_key // ""), sid: ($RE.short_id // ""),
     pqv: (if $c.core == "xray" then ($RE.mldsa_verify // "") else "" end), cc: ($c.congestion // "bbr"),
     bandwidth_mode: ($c.bandwidth_mode // (if ($c.up_mbps // 0)>0 or ($c.down_mbps // 0)>0 then "fixed" else "auto" end)),
     up: ($c.up_mbps // 50), down: ($c.down_mbps // 100), hop: ($c.hop // ""), obfs: ($c.obfs // {})};
  def withReality: . + {sni: (realityOf(.proto) | .sni // "")};
  def withTLS: . + {sni: $D, host: $D};
  def nodeOf($u; $id; $c; $server; $suffix):
    mk($u; $id; $c; $server; $suffix)
    | if   $id == "vless_reality_vision" or $id == "anytls_reality" or $id == "vless_reality_grpc" then withReality
      elif $id == "vless_reality_xhttp" then (withReality | . + {host: .sni, path: ("/" + $P + "xHTTP")})
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
      "hysteria2://\($n.password|e)@\(hostp($n.server)):\($n.port)\(if $n.hop!="" then ","+$n.hop else "" end)/?" + q([["sni",($n.sni|e)],["insecure","0"]] + (if ($n.obfs.type // "")!="" then [["obfs",$n.obfs.type],["obfs-password",($n.obfs.password|e)]] else [] end)) + "#" + ($n.name|e)
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
        ($b | if $n.hop!="" then del(.server_port)+{server_ports:[(($n.port|tostring)+":"+($n.port|tostring)),($n.hop|split("-")|join(":"))]} else . end)
        + {type:"hysteria2",password:$n.password,tls:(tlsSB($n)+{alpn:["h3"]})}
        + (if $n.bandwidth_mode=="fixed" then {up_mbps:$n.up,down_mbps:$n.down} else {} end)
        + (if ($n.obfs.type // "")!="" then {obfs:$n.obfs} else {} end)
      elif $n.proto == "tuic" then
        $b + {type: "tuic", uuid: $n.uuid, password: $n.password, congestion_control: $n.cc, tls: (tlsSB($n) + {alpn: ["h3"]})}
      elif $n.proto == "anytls_tls" then
        $b + {type: "anytls", password: $n.password, tls: tlsSB($n)}
      else null end;   # naive(出站需要 libcronet.so)、xhttp(sing-box 不支持) 不输出
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
        ($b | if $n.hop!="" then .+{ports:(( $n.port|tostring)+","+$n.hop)} else . end)
        + {type:"hysteria2",password:$n.password,alpn:["h3"],sni:$n.sni}
        + (if $n.bandwidth_mode=="fixed" then {up:"\($n.up) Mbps",down:"\($n.down) Mbps"} else {} end)
        + (if ($n.obfs.type // "")!="" then {obfs:$n.obfs.type,"obfs-password":$n.obfs.password} else {} end)
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
    elif $n.proto == "hysteria2" then "协议类型:Hysteria2，地址:\($n.server)，端口:\($n.port)\(if $n.hop != "" then "(端口跳跃 \($n.hop))" else "" end)，密码:\($n.password)，SNI:\($n.sni)，alpn:h3，带宽:\(if $n.bandwidth_mode=="auto" then "BBR 自适应" else "上行 \($n.up) / 下行 \($n.down) Mbps" end)，混淆:\($n.obfs.type // "关闭")"
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
    | $n + {uri: uri($n), uri_single: (if $n.proto=="hysteria2" and $n.hop!="" then uri($n+{hop:""}) else null end), singbox: singbox($n), mihomo: mihomo($n), naive: naiveClient($n), plain: plain($n)}
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
    # 控制接口只监听回环，并且必须带 secret；secret 为空（例如生成失败）时干脆不生成控制接口，绝不退回无认证接口。
    # 也不再自动下载面板（经镜像下载的面板代码无法验证完整性，而它与控制接口同源，被篡改后能直接操作代理）。
    # 需要面板请自行下载并核对后再配置 external_ui
    experimental: ({cache_file: {enabled: true}}
      + (if $secret != "" then {clash_api: {external_controller: "127.0.0.1:9090", default_mode: "rule", secret: $secret}} else {} end)),
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
    "find-process-mode": "strict", "external-controller": "127.0.0.1:9090", secret: $secret,
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
# secret 为空时不生成控制接口（理由见上面的 sing-box 完整配置）
| (if $secret == "" then del(.["external-controller"], .["external-controller-cors"], .secret) else . end)
EOF

# 把一个 JSON 对象整体渲染为 YAML（顶层，不加缩进）
jsonObjToYaml() { jq -r "${JQ_YAML} y(\"\")"; }

# ----------------------------- 生成各类配置 ----------------------------------
# cfgSbMin <outbounds JSON 数组>    stdout: 最小可运行配置
cfgSbMin() { jq -n --argjson nodes "$1" "${JQ_SB_MIN}"; }
cfgSbFull() { jq -n --argjson nodes "$1" --arg mirror "${RULESET_MIRROR}" --arg secret "${2:-}" "${JQ_SB_FULL}"; }
# cfgClashFull <proxies JSON 数组> [provider URL] [控制接口 secret] [provider 名称]  stdout: YAML
# cfgSbFull <outbounds JSON 数组> [控制接口 secret]
cfgClashFull() {
    jq -n --argjson proxies "$1" --arg mirror "${RULESET_MIRROR}" --arg provider "${2:-}" --arg secret "${3:-}" --arg providerName "${4:-atr_provider}" \
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
_generateClientFilesLocked() { # _generateClientFilesLocked [用户名]
    _requireCleanTransaction || return 1
    stateExists || return 1
    local only=${1:-} u d n views dir sbouts mhprox rc=0 out
    local -a problems=()
    persistUserSecrets || {
        rc=1
        problems+=("用户令牌/密钥没能写入 state")
    }
    if ! { mkdir -p "${CLIENT_DIR}" && chmod 700 "${CLIENT_DIR}"; }; then
        echoContent red " ---> 无法创建/设置客户端配置目录 ${CLIENT_DIR}"
        return 1
    fi
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
        if ! { mkdir -p "${dir}" && chmod 700 "${dir}"; }; then
            problems+=("${u}: 无法创建目录")
            continue
        fi
        rm -f "${dir}"/links.txt "${dir}"/hy2-single-port.txt "${dir}"/anytls-reality.json "${dir}"/probe-*.json "${dir}"/sing-box*.json "${dir}"/mihomo*.yaml "${dir}"/naive-client.json
        views=$(nodeViews "${u}") || {
            problems+=("${u}: 无法生成节点信息")
            continue
        }
        jq -r '.[]|select(.uri!=null)|.uri' <<<"${views}" >"${dir}/links.txt" || problems+=("${u}: links.txt 写入失败")
        if [[ "$(jq '[.[]|select(.uri_single!=null)]|length' <<<"${views}")" != 0 ]]; then
            jq -r '.[]|select(.uri_single!=null)|.uri_single' <<<"${views}" >"${dir}/hy2-single-port.txt" || problems+=("${u}: 单端口备用链接生成失败")
        fi
        if [[ "$(jq '[.[]|select(.proto=="anytls_reality")]|length' <<<"${views}")" != 0 ]]; then
            out=$(cfgSbMin "$(jq -c '[.[]|select(.proto=="anytls_reality")|.singbox]' <<<"${views}")") && printf '%s\n' "${out}" >"${dir}/anytls-reality.json" || problems+=("${u}: AnyTLS JSON 生成失败")
        fi
        sbouts=$(jq -c '[.[]|select(.singbox!=null)|.singbox]' <<<"${views}")
        mhprox=$(jq -c '[.[]|select(.mihomo!=null)|.mihomo]' <<<"${views}")
        if [[ "$(jq 'length' <<<"${sbouts}")" != "0" ]]; then
            out=$(cfgSbMin "${sbouts}") && jq . <<<"${out}" >"${dir}/sing-box.json" || problems+=("${u}: sing-box.json 生成失败")
            out=$(cfgSbFull "${sbouts}" "$(userApiSecret "${u}")") && jq . <<<"${out}" >"${dir}/sing-box-full.json" || problems+=("${u}: sing-box-full.json 生成失败")
            _checkClientFile "${dir}/sing-box.json" "${u} 的 sing-box 客户端配置" || problems+=("${u}: sing-box.json 未通过校验")
            _checkClientFile "${dir}/sing-box-full.json" "${u} 的 sing-box 完整客户端配置" || problems+=("${u}: sing-box-full.json 未通过校验")
        fi
        if [[ "$(jq 'length' <<<"${mhprox}")" != "0" ]]; then
            jsonToMihomoYaml <<<"${mhprox}" >"${dir}/mihomo-proxies.yaml" || problems+=("${u}: mihomo-proxies.yaml 生成失败")
            cfgClashFull "${mhprox}" "" "$(userApiSecret "${u}")" >"${dir}/mihomo-full.yaml" || problems+=("${u}: mihomo-full.yaml 生成失败")
        fi
        if [[ "$(jq '[.[]|select(.naive!=null)]|length' <<<"${views}")" != "0" ]]; then
            jq '[.[]|select(.naive!=null)|.naive][0]' <<<"${views}" >"${dir}/naive-client.json" || problems+=("${u}: naive-client.json 生成失败")
        fi
        chmod 600 "${dir}"/* || problems+=("${u}: 无法设置文件权限")
    done < <(userNames)
    if stateExists && [[ "$(S '.nginx.subscribe.enabled')" == "true" ]]; then
        generateSubscription || {
            echoContent red " ---> 订阅文件未能发布，订阅服务暂时不可用（凭据不会以不安全的权限落盘）。请根据上面的提示处理后重试"
            problems+=("订阅文件没有发布")
        }
    fi
    if ((${#problems[@]} > 0)); then
        echoContent red " ---> 客户端配置没有全部生成成功（${#problems[@]} 项问题）:"
        printf '       - %s\n' "${problems[@]}" >&2
        rc=1
    fi
    return "${rc}"
}
# 配置已经生效之后重新生成客户端文件和订阅。返回 0=全部成功；失败时已打印原因，调用方必须把失败继续往上传，
# 不能再宣称"已重新生成"。已被撤销的旧令牌/旧订阅链接在提交时已经从发布目录清除（见 applyStaged），与这里成败无关。
# shellcheck disable=SC2120
regenClients() { # regenClients [用户名]
    generateClientFiles "$@" && return 0
    echoContent red " ---> 服务端配置已生效，已被撤销的旧订阅链接/旧密钥已经失效；但客户端配置或订阅文件没有全部生成成功（原因见上）。修复后可用「重新生成全部客户端配置」重试"
    return 1
}
# 整个生成过程持有事务锁（可重入），保证各用户的文件和订阅都来自同一份 state
# shellcheck disable=SC2120
generateClientFiles() { # generateClientFiles [用户名]
    stateExists || return 1
    local only=${1:-} rc
    lockAcquire || return 1
    _generateClientFilesLocked "${only}"
    rc=$?
    lockRelease
    return "${rc}"
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



# 为没有订阅令牌 / 控制接口 secret 的用户补齐随机值，并清掉旧版的全局 salt，直接写入 state.json
# （旧版本升级，或手工构造的状态）。它们不进入任何内核/nginx 配置，所以无需走完整事务、也无需重启服务。
# 状态变了就置 USER_SECRETS_CHANGED=1：调用方必须随后重新发布订阅文件，不能只更新 state。
# 还有没有需要补发的令牌/密钥，或需要清除的旧 salt（只读检查，不加锁）
_userSecretsPending() {
    [[ -n "$(jq -r '.users[]? | select((.sub_token // "") == "" or (.api_secret // "") == "") | .name' "${ATR_STATE}" 2>/dev/null)" ]] && return 0
    jq -e '(.nginx.subscribe // {}) | has("salt")' "${ATR_STATE}" >/dev/null 2>&1
}
_persistUserSecretsLocked() {
    _requireCleanTransaction || return 1
    local need n st new cnt=0 hadSalt=0
    need=$(jq -r '.users[]? | select((.sub_token // "") == "" or (.api_secret // "") == "") | .name' "${ATR_STATE}" 2>/dev/null)
    jq -e '(.nginx.subscribe // {}) | has("salt")' "${ATR_STATE}" >/dev/null 2>&1 && hadSalt=1
    [[ -z "${need}" && "${hadSalt}" == "0" ]] && return 0
    st=$(jq '.nginx.subscribe |= ((. // {}) | del(.salt) | . + {peer_key: (.peer_key // ""), remotes: (.remotes // [])})' "${ATR_STATE}") || return 1
    while IFS= read -r n; do
        [[ -z "${n}" ]] && continue
        if [[ -z "$(jq -r --arg n "${n}" '.users[]|select(.name==$n)|.sub_token // ""' <<<"${st}")" ]]; then
            new=$(jq --arg n "${n}" --arg t "$(newSubToken)" '.users |= map(if .name==$n then .sub_token=$t else . end)' <<<"${st}") || return 1
            st=${new}
            cnt=$((cnt + 1))
        fi
        if [[ -z "$(jq -r --arg n "${n}" '.users[]|select(.name==$n)|.api_secret // ""' <<<"${st}")" ]]; then
            new=$(jq --arg n "${n}" --arg t "$(newApiSecret)" '.users |= map(if .name==$n then .api_secret=$t else . end)' <<<"${st}") || return 1
            st=${new}
        fi
    done <<<"${need}"
    if ! printf '%s\n' "${st}" | atomicWrite "${ATR_STATE}" 600; then
        echoContent red " ---> 无法写入 ${ATR_STATE}，用户的订阅令牌/控制接口 secret 没有更新"
        return 1
    fi
    USER_SECRETS_CHANGED=1 # 只有真正写成功了才算数
    if ((cnt > 0)) && [[ "$(S '.nginx.subscribe.enabled')" == "true" ]]; then
        echoContent yellow " ---> 已为 ${cnt} 个用户生成独立的随机订阅令牌：旧订阅链接已失效，请在客户端重新导入新的订阅链接"
    fi
    atrLog "user secrets migrated: sub_token=${cnt}, legacy salt removed=${hadSalt}"
    return 0
}
# 写 state 的路径之一，所以必须持锁（可重入）。没有待办事项时不加锁直接返回
persistUserSecrets() {
    USER_SECRETS_CHANGED=0
    stateExists || return 0
    _userSecretsPending || return 0
    local rc
    lockAcquire || return 1
    _persistUserSecretsLocked
    rc=$?
    lockRelease
    return "${rc}"
}

# ----------------------------- 合并其他机器的订阅 -----------------------------
# 对方机器在 菜单 7→3→5 里开启「对等密钥」后，本机用这把密钥从
#   <scheme>://<host>:<port>/s/peer/<对等密钥>/<用户名>/<类型>
# 取回"同名用户"在对方机器上的节点。对等密钥只用于服务器之间合并，与各用户自己的订阅令牌互相独立；
# 证书一律严格校验（私有 CA / 自签证书请在条目里提供 cacert 文件），取回内容必须通过格式校验才会被合并。
_fetchRemote() { # _fetchRemote <url> <输出文件> <https|http> [CA 证书文件]  —— 成功返回 0（响应体可以为空）
    local url=$1 out=$2 scheme=$3 ca=${4:-} sz
    local -a opt=(-fsS -m 15 --max-redirs 0 --proto "=${scheme}")
    [[ -n "${ca}" ]] && opt+=(--cacert "${ca}")
    # URL 里带着对等密钥，不能出现在命令行上（/proc/<pid>/cmdline 同机用户可读，而一次请求最长持续 15 秒）：
    # 用 --config - 从标准输入读 URL，命令行上只剩非敏感选项。配置值里的反斜杠和双引号要转义，换行等控制字符直接拒绝
    [[ "${url}" =~ [[:cntrl:]] ]] && return 1
    url=${url//\\/\\\\}
    url=${url//\"/\\\"}
    # 用 head -c 兜底限制大小（--max-filesize 对未知长度的分块传输不生效）
    printf 'url = "%s"\n' "${url}" | curl "${opt[@]}" --config - 2>/dev/null | head -c 2097153 >"${out}"
    [[ "${PIPESTATUS[1]}" == "0" && "${PIPESTATUS[2]}" == "0" ]] || return 1
    sz=$(stat -c %s "${out}" 2>/dev/null || echo 0)
    ((sz <= 2097152))
}
_validRemoteDefault() { # 正文是 base64；解码后每个非空行都必须是 scheme://… 形式的链接
    local dec line n=0
    dec=$(base64 -d <"$1" 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[a-z][a-z0-9+.-]*://[^[:space:][:cntrl:]]+$ ]] || return 1
        n=$((n + 1))
    done <<<"${dec}"
    ((n > 0))
}
_validRemoteClash() { # 只接受本脚本生成的 proxies 片段: 首行可以是 "proxies:"，其余每一行都缩进两格；不允许控制字符
    LC_ALL=C grep -q '[[:cntrl:]]' "$1" && return 1
    awk 'NR==1 && $0=="proxies:" {next} /^  / {next} {bad=1} END{exit bad}' "$1"
}
_validRemoteSingbox() {
    jq -e 'type == "array" and all(.[]; type == "object" and (.tag | type) == "string" and (.type | type) == "string")' "$1" >/dev/null 2>&1
}
# 条目字段是否合法（会进入 URL 与 sed 脚本，必须严格校验）
_remoteFieldsOK() { # _remoteFieldsOK <host> <port> <alias> <scheme>
    { isDomainName "$1" || isIPv4 "$1"; } && isPort "$2" && isSafeName "$3" && [[ "$4" == "https" ]]
}
_appendRemoteSubscriptions() { # _appendRemoteSubscriptions <用户名> <default文件> <clash文件> <singbox_profiles文件>
    local user=$1 fdef=$2 fclash=$3 fsb=$4 e host port alias scheme key ca tmp url reason
    while IFS= read -r e; do
        [[ -z "${e}" ]] && continue
        host=$(jq -r '.host // ""' <<<"${e}")
        port=$(jq -r '.port // ""' <<<"${e}")
        alias=$(jq -r '.alias // ""' <<<"${e}")
        scheme=$(jq -r '.scheme // "https"' <<<"${e}")
        key=$(jq -r '.key // ""' <<<"${e}")
        ca=$(jq -r '.cacert // ""' <<<"${e}")
        if [[ "${scheme}" != "https" ]]; then # 对等密钥会被明文传输，不再支持 HTTP
            echoContent yellow " ---> 远程订阅 ${alias}: 不再支持 HTTP（对等密钥会被明文传输），已跳过；请让对方启用 HTTPS 后重新添加"
            continue
        fi
        _remoteFieldsOK "${host}" "${port}" "${alias}" "${scheme}" || continue
        [[ "${key}" =~ ^[A-Za-z0-9]{16,64}$ ]] || continue # 没有对等密钥的条目（旧版导入）不参与合并
        if [[ -n "${ca}" && ! -r "${ca}" ]]; then
            echoContent yellow " ---> 远程订阅 ${alias}: CA 证书文件不可读(${ca})，已跳过"
            continue
        fi
        url="${scheme}://${host}:${port}/s/peer/${key}/${user}"
        tmp=$(mktemp "${ATR_TMP:-/tmp}/rs.XXXXXX") || continue
        # 通用订阅: 取不到（连接/证书/密钥/用户名不对）或内容校验不过 -> 整条跳过并告知；
        # 对方没有可分享的节点时返回空文件 -> 没有可合并的内容，不算失败
        reason=""
        if ! _fetchRemote "${url}/default" "${tmp}" "${scheme}" "${ca}"; then
            reason="连接、证书、对等密钥或同名用户不匹配"
        elif [[ -s "${tmp}" ]] && ! _validRemoteDefault "${tmp}"; then
            reason="返回内容格式不合法"
        fi
        if [[ -n "${reason}" ]]; then
            echoContent yellow " ---> 远程订阅 ${alias}(${host}:${port}): 取回或校验失败（${reason}），已跳过"
            atrLog "remote subscription ${alias}: ${reason} (user ${user})"
        elif [[ -s "${tmp}" ]]; then
            base64 -d <"${tmp}" 2>/dev/null | sed "s/#\([^#]*\)\$/#\1_${alias}/" >>"${fdef}"
            # clash: 去掉 proxies: 行并给 name 加后缀
            if _fetchRemote "${url}/clashMeta" "${tmp}" "${scheme}" "${ca}" && [[ -s "${tmp}" ]] && _validRemoteClash "${tmp}"; then
                grep -v '^proxies:' "${tmp}" | sed "s/^\\(  - name: \"[^\"]*\\)\"/\\1_${alias}\"/" >>"${fclash}"
            fi
            # sing-box 出站数组
            if _fetchRemote "${url}/sing-box_profiles" "${tmp}" "${scheme}" "${ca}" && [[ -s "${tmp}" ]] && _validRemoteSingbox "${tmp}"; then
                jq --arg a "_${alias}" 'map(.tag += $a)' "${tmp}" >"${tmp}.2" && jq -s '.[0] + .[1]' "${fsb}" "${tmp}.2" >"${tmp}.3" && mv "${tmp}.3" "${fsb}"
            fi
        fi
        rm -f "${tmp}" "${tmp}.2" "${tmp}.3"
    done < <(S -c '(.nginx.subscribe.remotes // [])[]')
}

# 每个用户的订阅文件是否齐全且结构合法（换入前的最后一道检查）
_validateSubStage() { # _validateSubStage <staging 目录> <peer 密钥或空>
    local d=$1 peer=$2 u t
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        t=$(subscriptionToken "${u}")
        [[ -n "${t}" ]] || return 1
        [[ -e "${d}/default/${t}" && -e "${d}/clashMeta/${t}" && -s "${d}/clashMetaProfiles/${t}" ]] || return 1
        # 用标准输入读文件：文件名就是令牌，不能出现在 jq 的命令行上
        jq -e 'type == "array"' <"${d}/sing-box_profiles/${t}" >/dev/null 2>&1 || return 1
        if [[ -e "${d}/sing-box/${t}" ]]; then jq -e . <"${d}/sing-box/${t}" >/dev/null 2>&1 || return 1; fi
        if [[ -n "${peer}" ]]; then [[ -e "${d}/peer/${u}/default" ]] || return 1; fi
    done < <(userNames)
}
# 复制文件。目标文件名是令牌/对等密钥，所以不用 cp（会把目标路径放在命令行上），改用 shell 重定向
_copyFile() { # _copyFile <源> <目标>
    cat -- "$1" >"$2"
}
# 文件内容 -> base64（一行）；任何一环失败都返回非零
_b64file() { # _b64file <输入文件> <输出文件>
    base64 -w 0 "$1" >"$2" 2>/dev/null && return 0
    base64 "$1" 2>/dev/null | tr -d '\n' >"$2"
    [[ "${PIPESTATUS[0]}" == "0" && "${PIPESTATUS[1]}" == "0" ]]
}

# 发布订阅文件。顺序不能变：
#   1) 令牌/密钥落到 state  2) nginx 必须已是"专用账号 + 受限权限"模型（否则先迁移，迁移失败就不发布）
#   3) 在独立的 staging 目录里生成全部文件、校验结构、设好属主/权限  4) 整体换入。
# 全程持有事务锁（和 applyStaged 同一把，可重入）：发布期间 state 不会被别的操作改动，两个进程也不会共用暂存目录。
# 任何一步失败都关闭订阅（并验证确实关闭了），不降级成"所有人可读"，也不留下已被撤销的旧链接。
_generateSubscriptionLocked() {
    _requireCleanTransaction || return 1
    [[ "$(S '.nginx.subscribe.enabled')" == "true" ]] || return 0 # 拿到锁之后重新确认（等锁期间可能被关掉）
    # 任何一次发布尝试都先保证"已被撤销的内容不在发布目录里"，不管后面的发布成不成功
    _pruneRevokedSubscription
    if (($? >= 2)); then
        echoContent red " ---> 无法清除已撤销的订阅文件，本次不发布"
        return 1
    fi
    persistUserSecrets || {
        echoContent red " ---> 无法更新用户令牌/密钥，本次不发布订阅文件（仍然有效的已发布内容保持不变，已被撤销的内容已清除）"
        return 1
    }
    if ! nginxModelCurrent; then
        echoContent yellow " ---> 检测到旧版 nginx 权限模型，发布订阅前先迁移到专用账号模型（会重启 nginx）…"
        if ! migrateNginxModel; then
            echoContent red " ---> 迁移失败，本次不发布订阅文件"
            _closeSubscription
            return 1
        fi
    fi
    if ! nginxSubLayoutCurrent; then
        # 订阅的 nginx 配置是旧格式（对等端点按旧的目录布局取文件），先按当前 state 重新渲染并应用一次，再按新布局发布
        echoContent yellow " ---> 订阅服务的 nginx 配置是旧版格式，先重新应用一次配置…"
        stagedBegin
        if ! applyStaged "更新订阅服务的 nginx 配置"; then
            stagedDiscard
            echoContent red " ---> 更新失败，本次不发布订阅文件"
            _closeSubscription
            return 1
        fi
    fi
    [[ -z "${ATR_PUBLIC_IP:-}" ]] && {
        ATR_PUBLIC_IP=$(getPublicIP 4)
        [[ -z "${ATR_PUBLIC_IP}" ]] && ATR_PUBLIC_IP=$(getPublicIP 6)
    }
    local u token base views sbouts kind w="" peer old_umask stage="" fail=0 sbfull
    base=$(subscriptionBase)
    peer=$(S '.nginx.subscribe.peer_key // ""')
    # 持有锁，所以残留的 .new* / .old 只可能是上次崩溃留下的；本次用独立的 mktemp 暂存目录
    rm -rf "${SUB_DIR}.new" "${SUB_DIR}".new.* "${SUB_DIR}".prune.* "${SUB_DIR}.old" 2>/dev/null
    # 订阅文件含节点凭据: 创建时就只有 root 可读，换入前再统一交给 nginx 专用组
    old_umask=$(umask)
    umask 077
    stage=$(mktemp -d "${SUB_DIR}.new.XXXXXX") || fail=1
    if ((!fail)); then
        for kind in default clashMeta clashMetaProfiles sing-box sing-box_profiles; do
            mkdir -p "${stage}/${kind}" || fail=1
        done
        w=$(mktemp -d "${ATR_TMP:-/tmp}/sub.XXXXXX") || fail=1
    fi
    while ((!fail)) && IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        token=$(subscriptionToken "${u}")
        [[ -n "${token}" ]] || {
            fail=1
            break
        }
        views=$(nodeViews "${u}") || {
            fail=1
            break
        }
        jq -r '.[]|select(.uri!=null)|.uri' <<<"${views}" >"${w}/links" || fail=1
        jq -c '[.[]|select(.singbox!=null)|.singbox]' <<<"${views}" >"${w}/sb.json" || fail=1
        jq -c '[.[]|select(.mihomo!=null)|.mihomo]' <<<"${views}" >"${w}/mh.json" || fail=1
        ((fail)) && break
        jsonToMihomoYaml <"${w}/mh.json" >"${w}/clash" 2>/dev/null || fail=1
        # 本机作为"被合并方"：只放本机自己的节点（不含已合并进来的远程节点，避免两台机器互相合并时重复膨胀）
        if [[ -n "${peer}" ]]; then
            mkdir -p "${stage}/peer/${u}" || fail=1
            _b64file "${w}/links" "${stage}/peer/${u}/default" || fail=1
            _copyFile "${w}/clash" "${stage}/peer/${u}/clashMeta" || fail=1
            _copyFile "${w}/sb.json" "${stage}/peer/${u}/sing-box_profiles" || fail=1
        fi
        ((fail)) && break
        _appendRemoteSubscriptions "${u}" "${w}/links" "${w}/clash" "${w}/sb.json" # 远程合并是尽力而为：取不到只跳过并提示
        _b64file "${w}/links" "${stage}/default/${token}" || fail=1
        _copyFile "${w}/clash" "${stage}/clashMeta/${token}" || fail=1
        _copyFile "${w}/sb.json" "${stage}/sing-box_profiles/${token}" || fail=1
        # 完整 mihomo 配置: 用 provider 指向本机订阅
        sbouts=$(cat "${w}/sb.json")
        cfgClashFull "$(cat "${w}/mh.json")" "${base}/s/clashMeta/${token}" "$(userApiSecret "${u}")" >"${stage}/clashMetaProfiles/${token}" 2>/dev/null || fail=1
        if [[ "$(jq length <<<"${sbouts}")" != "0" ]]; then
            sbfull="${w}/sbfull.json"
            { cfgSbFull "${sbouts}" "$(userApiSecret "${u}")" >"${sbfull}" && jq . <"${sbfull}" >"${stage}/sing-box/${token}"; } || fail=1
        fi
    done < <(userNames)
    [[ -n "${w}" ]] && rm -rf "${w}"
    umask "${old_umask}"
    # 结构校验 -> 设好属主/权限 -> 整体换入；任何一步失败都不发布，并确认旧内容已被撤下
    if ((!fail)); then _validateSubStage "${stage}" "${peer}" || fail=1; fi
    if ((!fail)); then { _applySubTreePerms "${stage}" && _swapSubDir "${stage}"; } || fail=1; fi
    if ((fail)); then
        echoContent red " ---> 订阅文件发布失败（磁盘空间、权限、渲染或目录替换出错），不会发布残缺的文件"
        [[ -n "${stage}" ]] && rm -rf "${stage}"
        rm -rf "${SUB_DIR}.old"
        _closeSubscription
        return 1
    fi
    # 上一次失败时 nginx 可能被停掉了（见 _closeSubscription）；发布成功后要让它重新运行起来
    if stateNeedsNginx "${ATR_STATE}" && ! serviceActive "${NGX_UNIT}"; then
        systemctl start "${NGX_UNIT}" >/dev/null 2>&1
        if ! waitServiceActive "${NGX_UNIT}" 10; then
            echoContent red " ---> 订阅文件已发布，但 nginx 没能启动"
            return 1
        fi
    fi
    return 0
}
generateSubscription() {
    [[ "$(S '.nginx.subscribe.enabled')" == "true" ]] || return 0
    local rc
    lockAcquire || return 1
    _generateSubscriptionLocked
    rc=$?
    lockRelease
    return "${rc}"
}

_showSubscriptionLinksLocked() { # _showSubscriptionLinksLocked [用户名]
    local only=${1:-} u token base regen=0
    # 令牌刚变过、或某个用户的订阅文件还不存在 -> 先重新发布，再显示链接（否则会打印出尚未生效的新链接，旧链接还在被提供）
    persistUserSecrets || {
        echoContent red " ---> 无法更新用户令牌，无法提供可用的订阅链接"
        return 1
    }
    ((USER_SECRETS_CHANGED)) && regen=1
    # 已发布的内容不完整（某个用户的订阅文件不在、对等分享开着但 peer 文件不在、nginx 订阅配置还是旧格式）也要先重新发布
    _subscriptionIncomplete && regen=1
    if ((regen)); then
        generateSubscription || {
            echoContent red " ---> 订阅文件未能发布，无法提供可用的订阅链接"
            return 1
        }
    fi
    base=$(subscriptionBase)
    [[ "${base}" == http://* ]] && echoContent yellow " ---> 提示: 当前为 HTTP 明文订阅，订阅令牌和全部节点凭据会明文经过网络（可被中间人读取，也可能被运营商拦截），建议配置域名证书后使用 HTTPS"
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
showSubscriptionLinks() { # showSubscriptionLinks [用户名]
    [[ "$(S '.nginx.subscribe.enabled')" == "true" ]] || {
        echoContent yellow " ---> 未启用订阅服务（需要 nginx）"
        return 1
    }
    local rc
    lockAcquire || return 1
    _showSubscriptionLinksLocked "$@"
    rc=$?
    lockRelease
    return "${rc}"
}

# ----------------------------- 自检（回环握手）--------------------------------
# 同核心自检：承载协议的核心也是本次探针客户端，升级验收不再依赖跨核心兼容。
selfCheckSupported() { # 0 可测；1 缺对应核心；2 不支持；3 配置/节点异常
    local id=$1 user=${2:-} core views node
    core=$(S --arg id "${id}" '.protocols[$id].core // ""')
    case "${core}" in
    sing-box)
        [[ "$(protoField "${id}" selfcheck)" == false ]] && return 2
        [[ -x "${SB_BIN}" ]] || return 1
        ;;
    xray)
        [[ -x "${XRAY_BIN}" ]] || return 1
        case "${id}" in vless_reality_vision | vless_vision_tls | vless_ws | vmess_ws | trojan | vless_reality_xhttp | vless_xhttp_tls) ;;
        *) return 2 ;;
        esac
        ;;
    *) return 3 ;;
    esac
    [[ -n "${user}" ]] || user=$(userNames | head -n 1)
    views=$(nodeViews "${user}") || return 3
    node=$(jq -ce --arg p "${id}" '[.[]|select(.proto==$p and (.name|test("_cdn[0-9]+$")|not))][0] | select(type=="object")' <<<"${views}") || return 3
    if [[ "${core}" == sing-box ]]; then jq -e '.singbox|type=="object"' <<<"${node}" >/dev/null || return 3; fi
    return 0
}

cfgXraySelfcheck() { # <node JSON> <本地 socks 端口>；凭据经 jq 私有文件传递
    jq -n --argjson n "$1" --argjson cp "$2" --arg cert "${TLS_DIR}/$(S '.domain').crt" '
      ($n.proto) as $p
      | ($p == "vless_reality_vision" or $p == "vless_reality_xhttp") as $reality
      | (if $p == "vmess_ws" then "vmess" elif $p == "trojan" then "trojan" else "vless" end) as $protocol
      | (if $protocol == "trojan" then {servers:[{address:"127.0.0.1",port:$n.port,password:$n.password}]}
         else {vnext:[{address:"127.0.0.1",port:$n.port,users:[
             (if $protocol == "vmess" then {id:$n.uuid,alterId:0,security:"auto"}
              else {id:$n.uuid,encryption:"none"} + (if ($p=="vless_reality_vision" or $p=="vless_vision_tls") then {flow:"xtls-rprx-vision"} else {} end) end)]}]} end) as $settings
      | (if ($p=="vless_reality_xhttp" or $p=="vless_xhttp_tls") then "xhttp" elif ($p=="vless_ws" or $p=="vmess_ws") then "ws" else "tcp" end) as $network
      | ({network:$network,security:(if $reality then "reality" else "tls" end)}
        + (if $reality then {realitySettings:({serverName:$n.sni,fingerprint:"chrome",publicKey:$n.pbk,shortId:$n.sid}
                  + (if ($n.pqv // "") != "" then {mldsa65Verify:$n.pqv} else {} end))}
           else {tlsSettings:{serverName:$n.sni,certificates:[{certificateFile:$cert,usage:"verify"}],alpn:(if $network=="ws" or $protocol=="trojan" then ["http/1.1"] else ["h2","http/1.1"] end)}} end)
        + (if $network=="ws" then {wsSettings:{path:$n.path,headers:{Host:$n.host}}}
           elif $network=="xhttp" then {xhttpSettings:{host:$n.host,path:$n.path,mode:"auto"}} else {} end)) as $stream
      | {log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$cp,protocol:"socks",settings:{udp:true}}],
         outbounds:[{tag:"probe",protocol:$protocol,settings:$settings,streamSettings:$stream}]}'
}

selfCheckProtocol() { # 0 通过；1 失败；2 无法自动验证
    local id=$1 user=${2:-} title core sc=0 node cp cfg log bin pid code url out
    title=$(protoName "${id}")
    core=$(S --arg id "${id}" '.protocols[$id].core // ""')
    [[ -n "${user}" ]] || user=$(userNames | head -n 1)
    selfCheckSupported "${id}" "${user}" || sc=$?
    case "${sc}" in
    1) echoContent yellow "  - ${title}: 未验证（缺少 ${core} 客户端核心）"; return 2 ;;
    2) echoContent yellow "  - ${title}: 未验证（${core} 自检客户端不支持此协议）"; return 2 ;;
    0) ;;
    *) echoContent red "  ✗ ${title}: 自检失败（节点配置生成异常）"; return 1 ;;
    esac
    node=$(nodeViews "${user}" | jq -ce --arg p "${id}" '[.[]|select(.proto==$p and (.name|test("_cdn[0-9]+$")|not))][0]') || return 1
    if [[ "${id}" == hysteria2 ]]; then
        echoContent yellow "      覆盖范围: 本机认证与转发；绕过 DNS、证书校验和跳跃范围，不证明公网 UDP 可达。"
    fi
    cp=$(randomFreePort) || return 1
    cfg="${ATR_TMP}/selfcheck.${id}.json"; log="${ATR_TMP}/selfcheck.${id}.log"
    if [[ "${core}" == xray ]]; then
        bin=${XRAY_BIN}
        cfgXraySelfcheck "${node}" "${cp}" >"${cfg}" || return 1
        "${bin}" run -test -c "${cfg}" >"${log}" 2>&1 || { echoContent red "  ✗ ${title}: Xray 自检配置校验失败"; return 1; }
    else
        bin=${SB_BIN}
        jq -n --argjson n "$(jq -c '.singbox' <<<"${node}")" --argjson cp "${cp}" --argjson sp "$(jq .port <<<"${node}")" '
          ($n | .server="127.0.0.1" | .server_port=$sp | del(.server_ports) | if .tls.reality==null then .tls.insecure=true else . end) as $o
          | {log:{level:"warn"},inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:$cp}],outbounds:[$o],route:{final:$o.tag}}' >"${cfg}" || return 1
        "${bin}" check -c "${cfg}" >"${log}" 2>&1 || { echoContent red "  ✗ ${title}: sing-box 自检配置校验失败"; return 1; }
    fi
    "${bin}" run -c "${cfg}" >>"${log}" 2>&1 &
    pid=$!
    sleep 2
    if ! kill -0 "${pid}" 2>/dev/null; then
        wait "${pid}" 2>/dev/null
        echoContent red "  ✗ ${title}: ${core} 自检客户端启动失败（检查配置或本地端口占用）"
        return 1
    fi
    code=000
    for url in https://www.cloudflare.com/cdn-cgi/trace http://www.gstatic.com/generate_204; do
        code=$(curl -s -m 15 -x "socks5h://127.0.0.1:${cp}" -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)
        [[ "${code}" == 200 || "${code}" == 204 ]] && break
    done
    kill "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null
    if [[ "${code}" == 200 || "${code}" == 204 ]]; then
        echoContent green "  ✓ ${title}: ${core} → ${core} 握手成功 (HTTP ${code})"
        return 0
    fi
    echoContent red "  ✗ ${title}: ${core} → ${core} 自检失败 (HTTP ${code})"
    out=$(grep -iE 'error|fail|reality|tls|handshake' "${log}" | tail -n 3)
    [[ -n "${out}" ]] && printRaw red "${out}"
    return 1
}


selfCheckAll() { # 返回 1 = 至少一个协议握手失败；无法自动验证的协议只列出，不算失败
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
    echoContent yellow " ---> 自检结果: 通过 ${pass}，失败 ${fail}，未自动验证 ${skip}"
    ((skip == 0)) || echoContent yellow "      未自动验证的协议只确认了服务启动与端口监听，请用对应客户端确认"
    echoContent yellow "      回环通过不等于部署验收；DNS、可信证书、公网入口及跳跃范围仍需外部客户端验证。"
    selfCheckSelectedClients || fail=$((fail+1))
    ((fail == 0))
}

# =============================================================================
#  12  用户管理: 查看 / 添加 / 删除(至少保留一个) / 重置密码或 UUID
#      每一次变更都是一次事务；成功后自动重新生成全部客户端配置并展示。
# =============================================================================

# 变更成功后: 重新生成全部客户端配置，展示受影响用户的账号，并提示需要同步
postChangeShow() { # postChangeShow [用户名|空=全部] [提示语]；返回 0=全部成功，1=客户端/订阅文件没有全部生成
    local gr=0
    regenClients || gr=1
    showAccounts "${1:-}" 0
    if ((gr)); then
        echoContent red "\n ! ${2:-配置已变更}，但客户端配置/订阅文件没有全部生成成功，上面显示的账号信息请以实际生效的服务端配置为准。"
    else
        echoContent yellow "\n ! ${2:-配置已变更}：客户端配置已自动重新生成，请把上面的链接/配置同步到对应客户端。"
    fi
    return "${gr}"
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
        local n gr=0
        regenClients || gr=1
        for n in "${names[@]}"; do showAccounts "${n}" 0; done
        echoContent yellow "\n ---> 已添加 ${#names[@]} 个用户，账号会同时添加到所有已安装的协议"
        return "${gr}"
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
        echoContent green " ---> 已删除用户 ${PICKED_USER}（该用户的所有客户端凭据和订阅链接已失效）"
        regenClients
    else
        stagedDiscard
        return 1
    fi
}

# 重置密码 / UUID
# userResetFlow [用户名] [密码|空=随机] [模式 password|uuid|both] [更换订阅链接 1|0，缺省: 订阅已启用则更换]  —— 带参数时为非交互(CLI)
userResetFlow() {
    local user=${1:-} newpass=${2:-} mode=${3:-} rotate=${4:-} choice newuuid
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
        if [[ "$(S '.nginx.subscribe.enabled')" == "true" ]]; then
            echoContent yellow "\n 订阅链接与节点密码是两回事：只重置密码/UUID，已泄露的订阅链接仍然能取到重置后的新凭据。"
            if confirm "是否同时更换该用户的订阅链接？（旧链接立即失效，需要在客户端重新导入）" y; then rotate=1; else rotate=0; fi
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
    # 不更换订阅链接的话，已泄露的旧链接仍能取到新凭据；订阅已启用时 CLI 默认也更换（--keep-sub 保留）
    if [[ -z "${rotate}" ]]; then
        if [[ "$(S '.nginx.subscribe.enabled')" == "true" ]]; then rotate=1; else rotate=0; fi
    fi
    if [[ "${rotate}" == "1" ]]; then
        stagedEdit --arg n "${user}" --arg t "$(newSubToken)" '.users |= map(if .name==$n then .sub_token=$t else . end)' || return 1
    fi
    if applyStaged "重置凭据(${user})"; then
        local pr=0
        postChangeShow "${user}" "用户 ${user} 的凭据已重置，旧凭据已失效" || pr=1
        if [[ "${rotate}" == "1" && "$(S '.nginx.subscribe.enabled')" == "true" ]]; then
            if ((pr)); then
                echoContent red " ---> 该用户的旧订阅链接已失效，但新的订阅链接没能发布，暂时没有可用的订阅链接。请按上面的提示处理后再用「查看订阅链接」重试"
            else
                echoContent yellow " ---> 该用户的订阅链接也已更换，旧订阅链接已失效，请在客户端重新导入下面的新链接:"
                showSubscriptionLinks "${user}" || pr=1
            fi
        fi
        return "${pr}"
    else
        stagedDiscard
        return 1
    fi
}

# 更换订阅链接: 单个用户或全部用户（旧链接立即失效）
rotateSubTokens() { # rotateSubTokens [用户名|空=全部]
    local only=${1:-} n
    stagedBegin
    while IFS= read -r n; do
        [[ -z "${n}" ]] && continue
        [[ -n "${only}" && "${n}" != "${only}" ]] && continue
        stagedEdit --arg n "${n}" --arg t "$(newSubToken)" '.users |= map(if .name==$n then .sub_token=$t else . end)' || {
            stagedDiscard
            return 1
        }
    done < <(userNames)
    applyStaged "更换订阅链接${only:+(${only})}" || {
        stagedDiscard
        return 1
    }
}

# 用户选择器（可选"全部"）: 设置 PICKED_USER，空字符串表示全部用户
pickUserOrAll() { # pickUserOrAll [提示]
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
    echoContent yellow "a.全部用户"
    ask sel "${1:-请选择用户编号、输入用户名，或输入 a 选择全部用户}:" || return 1
    if [[ "${sel}" == "a" || "${sel}" == "A" ]]; then
        PICKED_USER=""
    elif isInt "${sel}" && ((10#${sel} >= 1 && 10#${sel} <= i)); then
        PICKED_USER=${names[$((10#${sel} - 1))]}
    elif userExists "${sel}"; then
        PICKED_USER=${sel}
    else
        echoContent red " ---> 选择错误"
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
    echoContent yellow "3.合并其他机器的订阅"
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
        regenClients && echoContent green " ---> 已重新生成全部客户端配置: ${CLIENT_DIR}/"
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

# ----------------------------- HY2 参数 --------------------------------------
configureHY2Bandwidth() { # 只编辑候选状态，调用方负责事务
    local c current down up
    current=$(stagedGet '.protocols.hysteria2 | .bandwidth_mode // (if (.up_mbps // 0)>0 or (.down_mbps // 0)>0 then "fixed" else "auto" end)')
    echoContent yellow "1.BBR 自适应（新安装默认；不填写固定带宽）  2.固定带宽（客户端视角 Mbps）"
    ask c "带宽模式 [当前 ${current}，回车保留]:" "${current}" || return 1
    case "${c}" in
    1|auto|0) stagedEdit '.protocols.hysteria2 |= (. + {bandwidth_mode:"auto"} | del(.up_mbps,.down_mbps))' ;;
    2|fixed)
        while :; do
            ask down "客户端下载 Mbps（0 切换自适应）:" "$(stagedGet '.protocols.hysteria2.down_mbps // 100')" || return 1
            [[ "${down}" == 0 ]] && { stagedEdit '.protocols.hysteria2 |= (. + {bandwidth_mode:"auto"} | del(.up_mbps,.down_mbps))'; return $?; }
            [[ "${down}" =~ ^[1-9][0-9]{0,6}$ ]] && ((down <= 1000000)) && break
            echoContent red " ---> 请输入 1-1000000 的整数，或 0 选择自适应"
        done
        while :; do
            ask up "客户端上传 Mbps（0 切换自适应）:" "$(stagedGet '.protocols.hysteria2.up_mbps // 50')" || return 1
            [[ "${up}" == 0 ]] && { stagedEdit '.protocols.hysteria2 |= (. + {bandwidth_mode:"auto"} | del(.up_mbps,.down_mbps))'; return $?; }
            [[ "${up}" =~ ^[1-9][0-9]{0,6}$ ]] && ((up <= 1000000)) && break
            echoContent red " ---> 请输入 1-1000000 的整数，或 0 选择自适应"
        done
        stagedEdit --argjson u "${up}" --argjson d "${down}" '.protocols.hysteria2 += {bandwidth_mode:"fixed",up_mbps:$u,down_mbps:$d}'
        ;;
    *) echoContent red " ---> 带宽模式不合法"; return 1 ;;
    esac
}




manageHY2Option() {
    stagedBegin || return 1
    case "$1" in
    bandwidth) configureHY2Bandwidth ;;
    obfs) configureHY2Obfs ;;
    masquerade) configureHY2Masquerade ;;
    esac || { stagedDiscard; return 1; }
    if applyStaged "修改 HY2 $1"; then postChangeShow "" "HY2 参数已修改"; else stagedDiscard; return 1; fi
}

# 使用导出节点的 DNS、证书验证和端口范围；从服务端发起仍不能证明外部 UDP 可达。
selfCheckHY2Endpoint() {
    stateExists && protoInstalled hysteria2 || return 1
    local user node cp cfg log pid code rc=1
    user=$(userNames | head -n 1)
    node=$(nodeViews "${user}" | jq -ce '[.[]|select(.proto=="hysteria2")][0]') || return 1
    cp=$(randomFreePort) || return 1
    cfg="${ATR_TMP}/hy2-endpoint.json"; log="${ATR_TMP}/hy2-endpoint.log"
    echoContent yellow " ---> 导出配置实连：保留域名解析、证书验证及跳跃范围；本机发起，只采样部分端口，不能证明外部客户端可达。"
    jq -n --argjson o "$(jq .singbox <<<"${node}")" --argjson cp "${cp}" \
       '{log:{level:"warn"},inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:$cp}],outbounds:[$o],route:{final:$o.tag}}' >"${cfg}" || return 1
    "${SB_BIN}" check -c "${cfg}" >"${log}" 2>&1 || { echoContent red " ---> 导出实连配置未通过核心校验"; return 1; }
    "${SB_BIN}" run -c "${cfg}" >>"${log}" 2>&1 & pid=$!
    sleep 2
    code=$(curl -sS -m 20 -x "socks5h://127.0.0.1:${cp}" -o /dev/null -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    kill "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null
    if [[ "${code}" == 200 ]]; then
        echoContent green " ---> 导出配置实连采样通过（HTTP ${code}）；公网外部入口与全部跳跃端口：未验证。"; rc=0
    else
        echoContent red " ---> 导出配置实连未通过（HTTP ${code}），请检查 DNS、证书链及 UDP/跳跃规则。"
        echoContent yellow "      本机回连失败也可能来自 NAT 回流限制；请再从外部客户端测试。"
    fi
    return "${rc}"
}


# v1.3.2: 每入站配置；复制参数不建立隐式联动。旧 shared 数据仅在显式配置时迁移。
realityPerProtocol() {
    stagedRealityMode independent || return 1
    local id n tag used
    n=$(stagedGet '.reality_label_next // 1')
    [[ "${n}" =~ ^[1-9][0-9]*$ ]] || return 1
    while read -r id; do
        [[ -n "${id}" ]] || continue
        [[ -n "$(stagedGet --arg id "${id}" '.protocols[$id].reality.label // ""')" ]] && continue
        while :; do
            tag=$(atrTools label "${n}") || return 1
            used=$(stagedGet --arg t "${tag}" '[.protocols[]?.reality.label // empty|select(.==$t)]|length')
            n=$((n+1)); [[ "${used}" == 0 ]] && break
        done
        stagedEdit --arg id "${id}" --arg t "${tag}" '.protocols[$id].reality.label=$t' || return 1
    done < <(stagedGet --argjson ids "$(_realityIDsJson)" '.protocols|keys[]|select(. as $i|$ids|index($i))')
    stagedEdit --argjson n "${n}" '.reality_label_next=$n'
}

realityNewLabel() { # <id>，不复用其他节点标签
    local id=$1 n tag
    n=$(stagedGet '.reality_label_next // 1')
    while :; do
        tag=$(atrTools label "${n}") || return 1
        n=$((n+1))
        [[ "$(stagedGet --arg t "${tag}" '[.protocols[]?.reality.label // empty|select(.==$t)]|length')" == 0 ]] && break
    done
    stagedEdit --arg id "${id}" --arg t "${tag}" --argjson n "${n}" '.protocols[$id].reality.label=$t | .reality_label_next=$n'
}

stagedSetReality() { # <sni> <dest_port> [regen yes|no] [id] [dest_host]
    local sni=$1 port=$2 regen=${3:-no} id=${4:-} dest=${5:-} kp priv pub sid profile mode old_sni
    mode=$(stagedGet '.reality_mode // "shared"')
    isDomainName "${sni}" && isPort "${port}" || return 1
    if [[ "${mode}" == independent ]]; then [[ -n "${id}" && "$(protoField "${id}" reality)" == true ]] || return 1; fi
    profile=$(stagedRealityProfile "${id}") || return 1
    old_sni=$(jq -r '.sni // ""' <<<"${profile}")
    if [[ -z "${dest}" ]]; then
        dest=$(jq -r '.dest_host // ""' <<<"${profile}")
        [[ -n "${dest}" && "${dest}" != "${old_sni}" ]] || dest=${sni}
    fi
    atrTools endpoint "$(realityEndpoint "${dest}" "${port}")" >/dev/null || return 1
    priv=$(jq -r '.private_key // ""' <<<"${profile}")
    if [[ -z "${priv}" || "${regen}" == yes ]]; then
        kp=$(genRealityKeypair) || return 1; priv=${kp%% *}; pub=${kp##* }
        profile=$(jq --arg p "${priv}" --arg u "${pub}" '.private_key=$p|.public_key=$u' <<<"${profile}") || return 1
    fi
    sid=$(jq -r '.short_id // ""' <<<"${profile}")
    if [[ -z "${sid}" || "${regen}" == yes ]]; then profile=$(jq --arg s "$(genShortId)" '.short_id=$s' <<<"${profile}") || return 1; fi
    # 新配置 60 秒；已有配置缺失时保留原先关闭/ML-DSA 70 秒的有效语义。
    if [[ -z "${old_sni}" ]]; then profile=$(jq '.max_time_diff_seconds=60' <<<"${profile}") || return 1; fi
    profile=$(jq --arg s "${sni}" --arg d "${dest}" --argjson p "${port}" '.sni=$s|.dest_host=$d|.dest_port=$p' <<<"${profile}") || return 1
    if [[ "${mode}" == independent ]]; then stagedEdit --arg id "${id}" --argjson r "${profile}" '.protocols[$id].reality=$r'; else stagedEdit --argjson r "${profile}" '.reality=$r'; fi
}

realityEndpoint() { if [[ "$1" == *:* ]]; then printf '[%s]:%s' "$1" "$2"; else printf '%s:%s' "$1" "$2"; fi; }

realityXrayCompat() { # <dest_host> <port> [sni]，0=筛查通过 1=已知风险 2=无法判断
    local host=$1 port=$2 sni=${3:-$1} ping block len rc=0 ip
    [[ -x "${XRAY_BIN}" ]] || { echoContent yellow "      ? Xray 未安装，未验证目标兼容性"; return 2; }
    local -a args=()
    if [[ "${host}" != "${sni}" ]]; then
        ip=$(getent ahosts "${host}" 2>/dev/null | awk 'NR==1{print $1}')
        [[ -n "${ip}" ]] || { echoContent yellow "      ? 无法解析 dest"; return 2; }
        args=(-ip "${ip}")
    fi
    ping=$(timeout 15 "${XRAY_BIN}" tls ping "${args[@]}" "${sni}:${port}" 2>&1) || rc=$?
    block=$(awk '/^Pinging with SNI/{seen=1;next} seen{print}' <<<"${ping}")
    len=$(awk '/Certificate chain.s total length:/{print $5;exit}' <<<"${block}")
    if ((rc!=0)) || ! grep -q 'TLS ping finished' <<<"${block}" || ! grep -q 'Handshake succeeded' <<<"${block}" || ! grep -qE 'TLS Version: *TLS 1\.3' <<<"${block}" || ! isInt "${len}" || ((len<=0)) || ! grep -qE 'TLS Post-Quantum key exchange: *(true|false)' <<<"${block}"; then
        echoContent yellow "      ? Xray 目标兼容性无法判断（退出码 ${rc}，输出缺失或格式未知）；未标记通过"
        return 2
    fi
    if grep -q 'X25519MLKEM768' <<<"${block}" && ((len>3500)); then
        echoContent yellow "      ! 此 Xray 版本存在长证书链(${len})与 MLKEM 组合风险；需实际认证验证，建议换目标"
        return 1
    fi
    echoContent green "      ✓ Xray 目标筛查通过（证书链 ${len} 字节）；完整 Reality 认证仍需实测"
}

checkRealityTarget() { # <dest_host> [port] [core] [sni]
    local host=$1 port=${2:-443} core=${3:-${REALITY_CORE_HINT:-}} sni=${4:-$1} out rc=0 url endpoint
    endpoint=$(realityEndpoint "${host}" "${port}")
    echoContent skyBlue "\n ---> 检测 dest=${endpoint}，SNI=${sni}"
    command -v openssl >/dev/null 2>&1 || { echoContent yellow "      ? 缺少 OpenSSL，无法判断"; return 2; }
    out=$(timeout 12 openssl s_client -connect "${endpoint}" -servername "${sni}" -tls1_3 -alpn h2 -curves X25519 -verify_hostname "${sni}" -verify_return_error </dev/null 2>&1) || rc=$?
    if ((rc!=0)); then
        echoContent yellow "      ? TLS 探测未成功（退出码 ${rc}），没有标记通过"
        return 2
    fi
    if ! grep -q 'TLSv1.3' <<<"${out}" || ! grep -qE 'Verify return code: 0|Verification: OK' <<<"${out}"; then
        echoContent yellow "      ? TLS 版本或证书验证结果缺失，无法判断"; return 2
    fi
    echoContent green "      ✓ TLS1.3 与 SNI 证书验证成功"
    grep -qE 'ALPN protocol: *h2' <<<"${out}" || { echoContent yellow "      ! 未协商 h2，目标不推荐"; return 1; }
    url=$(curl -q -sS --max-time 6 --connect-to "${sni}:${port}:${endpoint}" "https://${sni}:${port}/cdn-cgi/trace" 2>/dev/null) || {
        echoContent yellow "      ? HTTP 目标特征未能检查，不能判定全部通过"; return 2;
    }
    if grep -q 'visit_scheme=https' <<<"${url}"; then echoContent red "      ✗ Cloudflare 代理目标不适用"; return 1; fi
    [[ "${core}" != xray ]] || { realityXrayCompat "${host}" "${port}" "${sni}"; return $?; }
    return 0
}

realityPickSNI() { # 兼容旧调用，另返回 PICK_DEST_HOST
    local current=${1:-} c raw n=0 parsed rc
    local -a list=()
    while read -r raw; do [[ -n "${raw}" ]] && list+=("${raw}"); done <<<"${REALITY_SNI_LIST}"
    echoContent yellow "选择 SNI，再单独确认 dest；目标必须能够正确服务该 SNI。"
    for raw in "${list[@]:0:12}"; do n=$((n+1)); echoContent yellow "${n}.${raw}"; done
    echoContent yellow "输入编号或域名；回车随机。当前: ${current:-无}；q 取消"
    while :; do
        ask c "SNI:" || return 1; [[ "${c}" == q ]] && return 1
        [[ -n "${c}" && "${c}" != r ]] || c=$((RANDOM % ${#list[@]} + 1))
        if isInt "${c}" && ((10#${c}>=1 && 10#${c}<=${#list[@]})); then c=${list[$((10#${c}-1))]}; fi
        parseSniInput "${c}" || { echoContent red " ---> SNI 不合法"; continue; }
        PICK_SNI=${SNI_HOST}; PICK_PORT=${SNI_PORT}
        ask raw "dest [默认 ${PICK_SNI}:${PICK_PORT}，可填 IP:端口]:" "${PICK_SNI}:${PICK_PORT}" || return 1
        parsed=$(atrTools endpoint "${raw}") || { echoContent red " ---> dest 不合法"; continue; }
        PICK_DEST_HOST=$(jq -r .host <<<"${parsed}"); PICK_PORT=$(jq -r .port <<<"${parsed}")
        rc=0; checkRealityTarget "${PICK_DEST_HOST}" "${PICK_PORT}" "${REALITY_CORE_HINT:-}" "${PICK_SNI}" || rc=$?
        ((rc==0)) && return 0
        confirm "检测未通过或无法判断，仍明确使用此目标？" n && return 0
    done
}

configureRealityForInstall() {
    local core=$1 id existing c anchor r src choice rc
    shift
    realityPerProtocol || return 1
    for id in "$@"; do
        [[ "$(protoField "${id}" reality)" == true ]] || continue
        existing=$(stagedGet --arg id "${id}" '.protocols[$id].reality.sni // ""')
        if [[ -n "${existing}" ]]; then
            echoContent yellow " ---> $(protoName "${id}") 已有参数，默认保留（修改请使用 Reality 管理）"
            continue
        fi
        echoContent skyBlue "\n配置 $(protoName "${id}") 的 Reality 参数"
        src=$(stagedGet --arg id "${id}" '.protocols|to_entries[]|select(.key!=$id and (.value.reality.sni // "")!="")|.key')
        choice=3
        if [[ -n "${src}" ]]; then
            while read -r anchor; do
                r=$(stagedRealityProfile "${anchor}")
                printRaw yellow "[$(jq -r .label <<<"${r}")] $(protoName "${anchor}") dest=$(jq -r '.dest_host // .sni' <<<"${r}"):$(jq -r '.dest_port // 443' <<<"${r}") SNI=$(jq -r .sni <<<"${r}") 公钥指纹=$(jq -r .public_key <<<"${r}" | sha256sum | cut -c1-12)"
            done <<<"${src}"
            echoContent yellow "1.复制所选整套参数  2.仅复制 dest+SNI，生成独立密钥/Short ID  3.全新配置（默认）"
            ask choice "请选择:" 3 || return 1
        fi
        case "${choice}" in
        1|2)
            ask c "来源标签（如 A；复制后不联动修改）:" || return 1
            anchor=$(stagedGet --arg t "${c^^}" '.protocols|to_entries[]|select(.value.reality.label==$t)|.key')
            [[ -n "${anchor}" && "${anchor}" != "${id}" ]] || return 1
            r=$(stagedRealityProfile "${anchor}") || return 1
            r=$(jq 'del(.label)' <<<"${r}")
            if [[ "${choice}" == 2 ]]; then r=$(jq '{sni,dest_host:(.dest_host // .sni),dest_port:(.dest_port // 443),max_time_diff_seconds:60}' <<<"${r}"); fi
            rc=0; checkRealityTarget "$(jq -r '.dest_host // .sni' <<<"${r}")" "$(jq -r '.dest_port // 443' <<<"${r}")" "${core}" "$(jq -r .sni <<<"${r}")" || rc=$?
            if ((rc)); then confirm "该核心的目标检测未通过/无法判断，仍继续复制？" n || return 1; fi
            stagedEdit --arg id "${id}" --argjson r "${r}" '.protocols[$id].reality=$r' || return 1
            stagedSetReality "$(jq -r .sni <<<"${r}")" "$(jq -r '.dest_port // 443' <<<"${r}")" no "${id}" "$(jq -r '.dest_host // .sni' <<<"${r}")" || return 1
            ;;
        3)
            REALITY_CORE_HINT=${core}
            realityPickSNI || return 1
            stagedEdit --arg id "${id}" '.protocols[$id].reality={}' || return 1
            stagedSetReality "${PICK_SNI}" "${PICK_PORT}" no "${id}" "${PICK_DEST_HOST:-${PICK_SNI}}" "${PICK_DEST_HOST}" || return 1
            ;;
        *) return 1 ;;
        esac
        realityNewLabel "${id}" || return 1
    done
}

realitySetTimeMenu() {
    local id seconds profile
    pickRealityProtocol || return 1; id=${PICK_REALITY_ID}
    echoContent yellow "握手允许时间偏差：新节点默认 60 秒；0 关闭。不会限制已建立连接的时长。客户端也需校准时间。"
    if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then
        echoContent yellow " ---> 系统时间同步未确认；可检查 chrony/ntpd。不会自动修改系统时间。"
    fi
    ask seconds "请输入 0-86400 秒:" 60 || return 1
    [[ "${seconds}" =~ ^(0|[1-9][0-9]{0,4})$ ]] && ((seconds<=86400)) || return 1
    confirm "为 $(protoName "${id}") 设置 ${seconds} 秒？旧参数仅在本次确认后修改。" n || return 0
    stagedBegin; realityPerProtocol || return 1
    stagedEdit --arg id "${id}" --argjson t "${seconds}" '.protocols[$id].reality.max_time_diff_seconds=$t' || return 1
    if applyStaged "Reality 时间差"; then selfCheckProtocol "${id}"; else stagedDiscard; return 1; fi
}

realityStatusExtras() {
    stateExists || return 0
    local id r t core
    while read -r id; do
        r=$(realityProfile "${id}");core=$(S --arg id "${id}" '.protocols[$id].core')
        t=$(jq -r --arg c "${core}" '.max_time_diff_seconds // (if $c=="xray" and (.mldsa_seed // "")!="" then 70 else 0 end)' <<<"${r}")
        printRaw yellow "[$(jq -r '.label // "旧配置"' <<<"${r}")] ${id}: dest=$(jq -r '.dest_host // .sni' <<<"${r}"):$(jq -r '.dest_port // 443' <<<"${r}") SNI=$(jq -r .sni <<<"${r}") 时间差=$([[ "${t}" == 0 ]] && echo 关闭 || echo "${t} 秒")"
    done < <(installedRealityProtocols)
}

# v1.3.2 HY2：标准 HTTP/3 与 obfs 明确择一；新装默认检测远端站点。
hy2Explain() {
    echoContent yellow "HY2 默认使用标准 HTTP/3。仅当网络针对 QUIC/HTTP/3 封锁、但放行其他 UDP 时才考虑混淆。"
    echoContent yellow "启用 obfs 将不兼容标准 QUIC，普通浏览器无法访问 HTTP/3 伪装；保存的伪装配置会标记为未生效。"
}

configureHY2Transport() {
    local c
    hy2Explain
    echoContent yellow "1.标准 HTTP/3 + 选择反代站点（默认）  2.UDP 混淆模式"
    ask c "请选择:" 1 || return 1
    case "${c}" in
    1) stagedEdit 'del(.protocols.hysteria2.obfs)' || return 1; hy2ChooseProxy ;;
    2) configureHY2ObfsPassword ;;
    *) return 1 ;;
    esac
}

configureHY2ObfsPassword() {
    local secret
    IFS= read -r -s -p "Salamander 密码（回车随机生成）:" secret || return 1; echo
    [[ -n "${secret}" ]] || secret=$(openssl rand -hex 24) || return 1
    jq -ne --arg p "${secret}" '$p|length>=8 and length<=256 and (test("[[:cntrl:]]")|not)' >/dev/null || return 1
    stagedEdit --arg p "${secret}" '.protocols.hysteria2.obfs={type:"salamander",password:$p}'
}

configureHY2Obfs() {
    local c
    hy2Explain
    echoContent yellow "1.关闭混淆，使用标准 HTTP/3（默认）  2.开启 Salamander"
    ask c "请选择:" 1 || return 1
    case "${c}" in
    1) stagedEdit 'del(.protocols.hysteria2.obfs)' ;;
    2) confirm "确认失去标准 HTTP/3 伪装能力？" n || return 0; configureHY2ObfsPassword ;;
    *) return 1 ;;
    esac
}

hy2ChooseProxy() {
    local c url report rc p assets
    echoContent yellow "目标选择原则："
    echoContent yellow "1.避免 Cloudflare 等 CDN/托管平台标识出现在非对应网络的 VPS 上。"
    echoContent yellow "2.目标应稳定、无跳转、不需登录、不屏蔽当前机房 IP；故障可能产生错误页。"
    echoContent yellow "3.页面内容应匹配你的域名语义，脚本无法替你判断。"
    echoContent yellow "首页优先 <10 KiB，建议 <50 KiB；无 Cookie/挑战页。CSP 会分析，不一律否决。"
    echoContent yellow "只代理首页和限量同源静态资源，不镜像下载站或任意路径；全局 HTTP 限流不等于整台 VPS 流量上限。"
    while :; do
        echoContent yellow "1.SQLite https://www.sqlite.org/  2.Lua https://www.lua.org/  3.OpenBSD https://www.openbsd.org/  4.自定义  q.取消"
        ask c "请选择（默认 SQLite，仍需检测与确认）:" 1 || return 1
        case "${c}" in
        1) url=https://www.sqlite.org/ ;;
        2) url=https://www.lua.org/ ;;
        3) url=https://www.openbsd.org/ ;;
        4) ask url "请输入 HTTP/HTTPS 网址:" || return 1 ;;
        q) return 1 ;;
        *) echoContent red " ---> 选择错误"; continue ;;
        esac
        hy2URLValid "${url}" || { echoContent red " ---> 网址格式不合法"; continue; }
        report=$(atrTools site-check "${url}") || { echoContent yellow " ---> 检测器失败，不能视为通过"; continue; }
        atrTools site-show <<<"${report}" || return 1
        rc=$(jq -r .status <<<"${report}")
        echoContent yellow "长期稳定性、域名语义和低滥用价值需人工确认；没有 CDN 头不能证明完全没有 CDN。"
        if [[ "${rc}" != acceptable_sample ]]; then echoContent yellow " ---> 此目标不推荐或无法判断；继续代表明确接受上述风险。"; fi
        confirm "是否继续使用这个网址？（否则重新选择）" n || continue
        p=$(stagedGet '.protocols.hysteria2.masquerade.gateway_port // 0')
        if [[ "${p}" == 0 ]]; then
            p=8080
            if portInUse "${p}" tcp || stagedUsedPorts | grep -qx "tcp ${p}"; then p=$(randomFreePort) || return 1; fi
        fi
        assets=$(jq -c '.assets // []' <<<"${report}")
        stagedEdit --arg u "${url}" --argjson p "${p}" --argjson a "${assets}" --arg status "${rc}" \
          '.protocols.hysteria2.masquerade={mode:"proxy",url:$u,gateway_port:$p,assets:$a,assessment:$status}' || return 1
        echoContent yellow " ---> 使用独立本地 Nginx 网关：全局请求/并发限流、robots.txt 与故障小页面。当前核心不支持可信真实 IP 传递，不宣称按客户端 IP 限流。"
        return 0
    done
}

configureHY2Masquerade() {
    local c url dir file content
    hy2Explain
    if [[ -n "$(stagedGet '.protocols.hysteria2.obfs.type // ""')" ]]; then
        confirm "当前开启混淆。关闭混淆并启用标准 HTTP/3 伪装？" n || return 0
        stagedEdit 'del(.protocols.hysteria2.obfs)' || return 1
    fi
    echoContent yellow "1.默认 404  2.302 跳转（高级）  3.检测并选择反代站点（推荐）  4.本地文件（自行准备）  5.固定内容"
    ask c "请选择:" 3 || return 1
    case "${c}" in
    1) stagedEdit 'del(.protocols.hysteria2.masquerade)' ;;
    2)
        ask url "跳转网址:" || return 1; hy2URLValid "${url}" || return 1
        stagedEdit --arg u "${url}" '.protocols.hysteria2.masquerade={mode:"redirect",url:$u}' ;;
    3) hy2ChooseProxy ;;
    4)
        echoContent yellow "使用核心原生 file；目录内全部内容必须可公开，准备 index.html 与 robots.txt。暂不推荐模板，不自动配置按 IP 限流。"
        ask dir "公开目录绝对路径:" || return 1
        stagedEdit --arg d "${dir}" '.protocols.hysteria2.masquerade={mode:"file",directory:$d}' || return 1
        atrTools validate <<<"${NEW_STATE}" ;;
    5)
        ask file "UTF-8 固定内容文件（不超过 50 KiB）:" || return 1
        [[ -f "${file}" && "$(wc -c <"${file}")" -le 51200 ]] || return 1
        content=$(cat -- "${file}") || return 1
        stagedEdit --arg c "${content}" '.protocols.hysteria2.masquerade={mode:"string",content:$c}' ;;
    *) return 1 ;;
    esac
}

hy2URLValid() { atrTools endpoint-url "$1" >/dev/null 2>&1; }

stateNeedsHY2Gateway() {
    jq -e '(.protocols.hysteria2 // {}) as $h | ($h.obfs.type // "")=="" and ($h.masquerade.mode // "")=="proxy" and ($h.masquerade.gateway_port // 0)>0' "$1" >/dev/null
}

renderHY2Gateway() {
    stateNeedsHY2Gateway "$1" || return 0
    local ca
    for ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do [[ -s "${ca}" ]] && break; done
    ATR_TOOLS_NGX_HOME="${NGX_DIR}" ATR_TOOLS_NGX_LOG="${NGX_DIR}/hy2-access.log" atrTools nginx --ca "${ca}" <"$1" >"$2/atr_hy2_masq.conf"
}

configureAnyTLSPadding() {
    local id=$1 c file line data='[]'
    echoContent yellow "AnyTLS 填充：省略字段使用核心默认，并非关闭。自定义不保证更难识别，可能增加开销。"
    echoContent yellow "1.沿用当前（默认）  2.核心默认  3.查看默认参考与当前值  4.从 UTF-8 文件导入  5.多行输入，单独一行 END 结束"
    ask c "请选择:" 1 || return 1
    case "${c}" in
    1) return 0 ;;
    2) stagedEdit --arg id "${id}" 'del(.protocols[$id].padding_scheme)' ;;
    3)
        echoContent yellow "默认参考（sing-anytls v0.0.11；未配置时以实际核心版本为准）:"
        printf '%s\n' 'stop=8' '0=30-30' '1=100-400' '2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000' '3=9-9,500-1000' '4=500-1000' '5=500-1000' '6=500-1000' '7=500-1000'
        stagedGet --arg id "${id}" '.protocols[$id].padding_scheme // "核心默认"'
        [[ ! -x "${SB_BIN}" ]] || "${SB_BIN}" version | head -n 1
        configureAnyTLSPadding "${id}" ;;
    4)
        ask file "策略文件路径:" || return 1; [[ -f "${file}" && "$(wc -c <"${file}")" -le 32768 ]] || return 1
        data=$(jq -Rs 'split("\n")|map(rtrimstr("\r"))|map(select(length>0))' "${file}") || return 1
        atrTools padding <<<"${data}" || return 1
        stagedEdit --arg id "${id}" --argjson p "${data}" '.protocols[$id].padding_scheme=$p' ;;
    5)
        while IFS= read -r line; do
            [[ "${line}" == END ]] && break
            data=$(jq --arg l "${line}" '.+[$l]' <<<"${data}") || return 1
            [[ "$(jq length <<<"${data}")" -le 65 ]] || return 1
        done
        [[ "${line}" == END ]] || return 1
        atrTools padding <<<"${data}" || return 1
        stagedEdit --arg id "${id}" --argjson p "${data}" '.protocols[$id].padding_scheme=$p' ;;
    *) return 1 ;;
    esac
}

manageAnyTLSPadding() {
    local id
    echoContent yellow "选择 AnyTLS 协议 ID：anytls_reality / anytls_tls"
    ask id "协议 ID:" anytls_reality || return 1
    [[ "${id}" == anytls_reality || "${id}" == anytls_tls ]] && protoInstalled "${id}" || return 1
    stagedBegin; configureAnyTLSPadding "${id}" || { stagedDiscard; return 1; }
    if applyStaged "AnyTLS 填充策略"; then postChangeShow "" "填充策略已更新；新会话由服务端协商下发"; selfCheckProtocol "${id}"; else stagedDiscard; return 1; fi
}

configureRealityClientChecks() {
    if [[ "$1" == anytls_reality ]]; then
        echoContent yellow "AnyTLS+Reality 使用 sing-box 原生验收；当前导出中 Xray、mihomo 客户端不适用此组合。"
        stagedEdit --arg id "$1" '.protocols[$id].test_clients=[]'
        return $?
    fi
    local id=$1 c
    echoContent yellow "$(protoName "${id}") 客户端验收：1.仅同核心（默认）  2.还要 sing-box  3.还要 mihomo  4.两者都测。缺核心显示未验证，不自动下载。"
    ask c "请选择:" 1 || return 1
    case "${c}" in
    1) stagedEdit --arg id "${id}" '.protocols[$id].test_clients=[]' ;;
    2) stagedEdit --arg id "${id}" '.protocols[$id].test_clients=["sing-box"]' ;;
    3) stagedEdit --arg id "${id}" '.protocols[$id].test_clients=["mihomo"]' ;;
    4) stagedEdit --arg id "${id}" '.protocols[$id].test_clients=["sing-box","mihomo"]' ;;
    *) return 1 ;;
    esac
}

clientProbe() { # <id> <client> [loopback|server-return] [binary]
    local id=$1 client=$2 scope=${3:-loopback} bin=${4:-} node rc=0 result
    [[ "${client}" == sing-box || "${client}" == xray || "${client}" == mihomo ]] || return 2
    if [[ -z "${bin}" ]]; then
        case "${client}" in sing-box) bin=${SB_BIN} ;; xray) bin=${XRAY_BIN} ;; mihomo) bin=$(command -v mihomo || true) ;; esac
    fi
    node=$(nodeViews "$(userNames | head -n 1)" | jq -ce --arg id "${id}" '[.[]|select(.proto==$id)][0]') || return 2
    result=$(atrTools probe --core "${client}" --binary "${bin}" --scope "${scope}" <<<"${node}") || rc=$?
    printf '%s\n' "${result}"
    return "${rc}"
}

selfCheckSelectedClients() { # [仅此服务端核心]
    local core=${1:-} id client rc fail=0
    while read -r id client; do
        [[ -n "${client}" ]] || continue
        echoContent yellow " ---> 指定客户端组合 ${client} → $(S --arg id "${id}" '.protocols[$id].core') / ${id}"
        rc=0; clientProbe "${id}" "${client}" || rc=$?
        ((rc==0)) || fail=1
    done < <(jq -r --arg c "${core}" '.protocols|to_entries[]|select($c=="" or .value.core==$c)|.key as $id|(.value.test_clients // [])[]|"\($id) \(.)"' "${ATR_STATE}")
    ((fail==0)) || echoContent yellow " ---> 指定客户端验收失败或未完成；不等同于服务端损坏。"
    return "${fail}"
}

selfCheckCLI() {
    if [[ $# == 0 ]]; then selfCheckAll; return $?; fi
    local id="" client="" scope=loopback bin=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --protocol) [[ $# -ge 2 ]] || return 1; id=$2; shift 2 ;;
        --client) [[ $# -ge 2 ]] || return 1; client=$2; shift 2 ;;
        --binary) [[ $# -ge 2 ]] || return 1; bin=$2; shift 2 ;;
        --endpoint) scope=server-return; shift ;;
        *) return 1 ;;
        esac
    done
    [[ -n "${id}" && -n "${client}" ]] && protoInstalled "${id}" || return 1
    clientProbe "${id}" "${client}" "${scope}" "${bin}"
}

clientTestCLI() { # 外部主机使用导出的 node JSON；不会安装别名/迁移配置
    local file="" client="" bin="" scope=server-return address=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --node) [[ $# -ge 2 ]] || return 2; file=$2; shift 2 ;;
        --client) [[ $# -ge 2 ]] || return 2; client=$2; shift 2 ;;
        --binary) [[ $# -ge 2 ]] || return 2; bin=$2; shift 2 ;;
        --external) scope=external; shift ;;
        --address) [[ $# -ge 2 ]] || return 2; address=$2; shift 2 ;;
        *) return 2 ;;
        esac
    done
    [[ -s "${file}" && -n "${client}" && -n "${bin}" ]] || { echo '用法: client-test --node node.json --client sing-box|xray|mihomo --binary 核心路径 [--external]'; return 2; }
    atrTools probe --core "${client}" --binary "${bin}" --scope "${scope}" ${address:+--address "$address"} <"${file}"
}

externalProbeExport() {
    local id path user
    pickRealityProtocol || return 1; id=${PICK_REALITY_ID}; user=$(userNames | head -n 1)
    path="${CLIENT_DIR}/${user}/probe-${id}.json"
    nodeViews "${user}" | jq --arg id "${id}" '[.[]|select(.proto==$id)][0]' | atomicWrite "${path}" 600 || return 1
    echoContent yellow " ---> 已生成 ${path}（含客户端凭据，勿公开）。复制到另一网络主机，然后运行："
    printRaw yellow "bash anytls-reality.sh client-test --node probe-${id}.json --client sing-box --binary /path/to/sing-box --external"
    echoContent yellow "外部主机需 Python3、curl 和选定核心；--external 是执行者声明，脚本不凭该标志伪造已验证位置。"
}

showAnyTLSExport() {
    local user file
    user=$(userNames | head -n 1);file="${CLIENT_DIR}/${user}/anytls-reality.json"
    [[ -s "${file}" ]] || regenClients || return 1
    [[ -s "${file}" ]] || { echoContent yellow " ---> 未安装 AnyTLS+Reality"; return 1; }
    echoContent yellow "这是 sing-box JSON 导入文件，不是通用 AnyTLS URI。"
    printRaw green "${file}"
    confirm "显示配置内容？（含凭据）" n && cat "${file}"
    return 0
}

monitorSample() {
    local report
    lockAcquire || return 1
    report=$(atrTools monitor --home "${ATR_HOME}" <"${ATR_STATE}") || { lockRelease; return 1; }
    printf '%s\n' "${report}"
    if [[ "$(jq -r .alert <<<"${report}")" == true ]]; then atrLog "流量阈值告警: ${report}"; fi
    lockRelease
}


cliSetSNI() { # sni host[:port] [--dest host:port] [--protocol id] [--force]
    local target=${1:-} force=no id="" dest="" host port parsed
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --force) force=yes; shift ;;
        --protocol) [[ $# -ge 2 ]] || return 1; id=$2; shift 2 ;;
        --dest) [[ $# -ge 2 ]] || return 1; dest=$2; shift 2 ;;
        *) return 1 ;;
        esac
    done
    requireInstalled || return 1
    parseSniInput "${target}" || return 1; host=${SNI_HOST};port=${SNI_PORT}
    if [[ "$(realityMode)" == independent ]]; then
        [[ -n "${id}" ]] && installedRealityProtocols | grep -Fxq "${id}" || { echoContent red " ---> 按协议配置必须指定 --protocol"; return 1; }
    elif [[ -n "${id}" ]]; then
        echoContent red " ---> 旧共享模式：请先 reality-mode independent，再修改单个协议"; return 1
    fi
    if [[ -n "${dest}" ]]; then
        parsed=$(atrTools endpoint "${dest}") || return 1
        dest=$(jq -r .host <<<"${parsed}");port=$(jq -r .port <<<"${parsed}")
    else dest=${host}; fi
    REALITY_CORE_HINT=$(realityCoreHint "" "${id}")
    if ! checkRealityTarget "${dest}" "${port}" "${REALITY_CORE_HINT}" "${host}" && [[ "${force}" != yes ]]; then
        echoContent red " ---> 检测未通过/无法判断；未修改，可明确使用 --force"; return 1
    fi
    stagedBegin; stagedSetReality "${host}" "${port}" no "${id}" "${dest}" || return 1
    if applyStaged "修改 Reality 目标 ${id}"; then postChangeShow "" "目标已更新，客户端需同步 SNI"; selfCheckAll; else stagedDiscard; return 1; fi
}

reconcileMonitor() { # state，各文件纳入配置事务。仅日志告警，无外发或自动停服。
    local st=$1
    if [[ "$(jq -r '.monitor.enabled // false' "${st}")" == true ]]; then
        _writeUnitFile atr-monitor <<EOF
[Unit]
Description=AnyTLS-Reality host traffic sample (local log only)
[Service]
Type=oneshot
ExecStart=${ATR_SCRIPT_PATH} monitor-sample
EOF
        [[ $? == 0 ]] || return 1
        local timer
        timer=$(cat <<'EOF'
[Unit]
Description=AnyTLS-Reality periodic traffic sample
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=atr-monitor.service
[Install]
WantedBy=timers.target
EOF
)
        printf '%s\n' "${timer}" | atomicWrite "${ATR_SYSTEMD_DIR}/atr-monitor.timer" 644 || return 1
        systemctl daemon-reload && systemctl enable --now atr-monitor.timer || return 1
    elif [[ -f "${ATR_SYSTEMD_DIR}/atr-monitor.timer" ]] || systemctl is-active --quiet atr-monitor.timer; then
        systemctl disable --now atr-monitor.timer || return 1
        rm -f "${ATR_SYSTEMD_DIR}/atr-monitor.timer" "${ATR_SYSTEMD_DIR}/atr-monitor.service" || return 1
        systemctl daemon-reload || return 1
    fi
}

monitorMenu() {
    local c threshold
    echoContent yellow "宿主网卡采样包含其他服务；无法用用户流量 API 代替未认证 HTTP/3 流量统计。"
    echoContent yellow "1.采样  2.设置每分钟采样与本机日志阈值告警  3.停止采样  4.查看日志"
    ask c "请选择:" 1 || return 1
    case "${c}" in
    1) monitorSample ;;
    2)
        ask threshold "单方向阈值 Mbps:" 100 || return 1
        [[ "${threshold}" =~ ^[1-9][0-9]{0,6}$ ]] && ((threshold<=1000000)) || return 1
        stagedBegin; stagedEdit --argjson t "${threshold}" '.monitor={enabled:true,threshold_mbps:$t}' || return 1
        if applyStaged "本机流量阈值日志"; then echoContent yellow " ---> 每分钟采样并写本机日志；未配置外发渠道，不自动停代理。"; else stagedDiscard; return 1; fi ;;
    3)
        stagedBegin; stagedEdit '.monitor.enabled=false' || return 1
        if ! applyStaged "停止采样"; then stagedDiscard; return 1; fi ;;
    4) tail -n 30 "${ATR_HOME}/atr.log"; tail -n 20 "${NGX_DIR}/hy2-access.log" 2>/dev/null ;;
    *) return 1 ;;
    esac
}

# ----------------------------- 单个协议的参数 ---------------------------------
# configureProtocol <core> <id>  —— 询问端口/参数并写入候选状态
configureProtocol() {
    local core=$1 id=$2 name port c cc
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
        stagedEdit --arg id "${id}" --arg c "${core}" --argjson p "${port}" '.protocols[$id]=((.protocols[$id] // {}) + {core:$c,port:$p})'
        ;;
    vless_vision_tls)
        askPort port "${id}" "${name} " tcp 443 || return 1
        stagedEdit --arg id "${id}" --arg c "${core}" --argjson p "${port}" '.protocols[$id]=((.protocols[$id] // {}) + {core:$c,port:$p})'
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
        stagedEdit --arg id "${id}" --arg c "${core}" --argjson p "${port}" '.protocols[$id]=((.protocols[$id] // {})+{core:$c,port:$p})' || return 1
        configureHY2Bandwidth || return 1
        if ! protoInstalled hysteria2; then configureHY2Transport || return 1; fi
        ;;
    *)
        local net=tcp
        askPort port "${id}" "${name} " "${net}" || return 1
        stagedEdit --arg id "${id}" --arg c "${core}" --argjson p "${port}" '.protocols[$id]=((.protocols[$id] // {}) + {core:$c,port:$p})'
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
    local reuse="n" egress=""

    # 最开始先问出口访问模式（已经选过就沿用，不再重复问）
    egress=$(S '.egress.mode // ""' 2>/dev/null)
    if [[ -z "${egress}" ]]; then
        pickEgressMode "" || return 1
        egress=${EGRESS_PICK}
    else
        echoContent green " ---> 出口访问模式沿用: $(egressModeLabel "${egress}")（可在 11.分流工具 → 6 修改）"
    fi

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

    stagedEdit --arg m "${egress}" '.egress.mode=$m' || return 1
    stagedRefreshEgressPublicIPs

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
        configureRealityForInstall "${core}" "${ids[@]}" || return 1
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

    for id in "${ids[@]}"; do
        if [[ "${id}" == anytls_reality || "${id}" == anytls_tls ]]; then configureAnyTLSPadding "${id}" || { stagedDiscard; return 1; }; fi
        if [[ "$(protoField "${id}" reality)" == true ]]; then configureRealityClientChecks "${id}" || { stagedDiscard; return 1; }; fi
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
    local gr=0
    regenClients || gr=1
    selfCheckAll || { echoContent red " ---> 配置已生效，但有协议自检失败；请按上面的提示检查日志、目标域名或内核版本"; gr=1; }
    showAccounts "" 0
    return "${gr}"
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
    local port="" sni="" user="" egress="" mode="" a profile dest="" parsed
    while [[ $# -gt 0 ]]; do
        a=$1
        case "${a}" in
        --dest) [[ $# -ge 2 ]] || return 1; dest=$2; shift ;;
        --reality-mode) [[ $# -ge 2 ]] || return 1; mode=$2; shift ;;
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
        --egress)
            egress=$2
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
    [[ -n "${egress}" && "${egress}" != "public" && "${egress}" != "full" ]] && {
        echoContent red " ---> --egress 只能是 public（公网出口，默认）或 full（允许内网访问）"
        return 1
    }
    if [[ -n "${sni}" ]] && ! parseSniInput "${sni}"; then
        echoContent red " ---> SNI 不合法"
        return 1
    fi
    [[ -z "${mode}" || "${mode}" == shared || "${mode}" == independent ]] || { echoContent red " ---> --reality-mode 只能是 shared 或 independent"; return 1; }
    # 合并独立配置必须显式选择来源，避免非交互安装意外覆盖其他节点。
    if [[ "${mode}" == shared && "$(realityMode)" == independent ]]; then
        echoContent red " ---> 请先用 reality-mode shared --from 协议ID 选择共享参数来源"
        return 1
    fi
    installTools min 1 5 || return 1
    ensureCore sing-box 2 5 || return 1
    stateInit
    stagedBegin
    if [[ -z "${mode}" ]]; then realityPerProtocol || return 1; else stagedRealityMode "${mode}" || return 1; fi
    # 未指定时：已经选过就沿用，否则默认公网出口（更安全的一侧）
    [[ -z "${egress}" ]] && egress=$(stagedGet '.egress.mode // ""')
    stagedEdit --arg m "${egress:-public}" '.egress.mode=$m' || return 1
    stagedRefreshEgressPublicIPs
    [[ -z "${port}" ]] && port=$(suggestPort tcp anytls_reality)
    if [[ -z "${sni}" ]]; then
        profile=$(stagedRealityProfile anytls_reality) || return 1
        SNI_HOST=$(jq -r '.sni // ""' <<<"${profile}")
        SNI_PORT=$(jq -r '.dest_port // 443' <<<"${profile}")
        [[ -n "${SNI_HOST}" ]] || SNI_HOST=www.microsoft.com
    fi
    if [[ -n "${dest}" ]]; then
        parsed=$(atrTools endpoint "${dest}") || return 1
        dest=$(jq -r .host <<<"${parsed}"); SNI_PORT=$(jq -r .port <<<"${parsed}")
    else dest=$(stagedGet '.protocols.anytls_reality.reality.dest_host // .reality.dest_host // empty'); [[ -n "${dest}" ]] || dest=${SNI_HOST}; fi
    step 3 5 "检测 Reality 目标 ${SNI_HOST}:${SNI_PORT}"
    REALITY_CORE_HINT=$(realityCoreHint sing-box anytls_reality)
    checkRealityTarget "${dest}" "${SNI_PORT}" sing-box "${SNI_HOST}" || {
        echoContent red " ---> 目标未通过检测，请换一个 --sni"
        return 1
    }
    stagedSetReality "${SNI_HOST}" "${SNI_PORT}" no anytls_reality "${dest}" || return 1
    if [[ "$(stagedGet '.reality_mode // "shared"')" == independent && -z "$(stagedGet '.protocols.anytls_reality.reality.label // ""')" ]]; then realityNewLabel anytls_reality || return 1; fi
    if [[ "$(stagedGet '.users|length')" == "0" ]]; then
        stagedUserAdd "${user:-$(randHex 6)}" || return 1
    fi
    stagedEdit --argjson p "${port}" '.protocols.anytls_reality=((.protocols.anytls_reality // {}) + {core:"sing-box",port:$p})' || return 1
    step 4 5 "应用配置"
    applyStaged "安装 AnyTLS+Reality" || {
        stagedDiscard
        return 1
    }
    step 5 5 "自检并生成客户端配置"
    local gr=0
    regenClients || gr=1
    selfCheckAll || gr=1
    showAccounts "" 0
    return "${gr}"
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

# 能力诊断的解释器与临时探针完全独立；不安装别名、不迁移状态、不改服务。
realityCapabilities() {
    if ! command -v python3 >/dev/null 2>&1; then
        echoContent yellow " ---> 未能确认: 能力检测需要 Python 3（标准库），未安装任何依赖"
        return 2
    fi
    local sb="" xr=""
    [[ -x "${SB_BIN}" ]] && sb=${SB_BIN}
    [[ -x "${XRAY_BIN}" ]] && xr=${XRAY_BIN}
    ATR_PROBE_SB="${sb}" ATR_PROBE_XRAY="${xr}" ATR_PROBE_STATE="${ATR_STATE}" ATR_PROBE_SCRIPT="${BASH_SOURCE[0]}" ATR_PROBE_VERSION="${ATR_VERSION}" python3 - "$@" <<'ATR_REALITY_PROBE_PY'
"""Embedded stdlib-only REALITY diagnostic. AGPL-3.0, same as parent script.
Only temporary loopback services and one-time credentials are used.
"""
import argparse, base64, datetime, hashlib, http.server, json, mmap, os, pathlib
import platform, re, secrets, shutil, signal, socket, struct, subprocess, sys
import tempfile, threading, time, urllib.request, uuid, zipfile
os.umask(0o077)

MLKEM = 0x11EC
X25519 = 29
NAMES = {MLKEM:'X25519MLKEM768', X25519:'X25519', 23:'P256', 24:'P384', 25:'P521', 0x6399:'X25519Kyber768Draft00'}
HRR = bytes.fromhex('cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c')
REFERENCE_TAG = 'v26.10.21'
PROCESSES = []
SOCKS_USER = secrets.token_hex(12)
SOCKS_PASS = secrets.token_urlsafe(24)

class ProbeError(Exception): pass
def group_name(n): return NAMES.get(n, 'GREASE' if n & 0x0f0f == 0x0a0a else '0x%04x'%n)
def u16(b,p):
    if p+2>len(b): raise ProbeError('TLS 消息截断')
    return int.from_bytes(b[p:p+2],'big')

def parse_hello(data, server=False):
    """Parse a complete handshake message, not a TCP packet or byte substring."""
    if len(data)<4 or data[0] != (2 if server else 1): raise ProbeError('不是预期的 TLS Hello')
    n=int.from_bytes(data[1:4],'big')
    if n!=len(data)-4 or n<35: raise ProbeError('TLS Hello 长度不合法')
    b=data[4:]; p=34; sid=b[p]; p+=1+sid
    if server: p+=3
    else:
        p+=2+u16(b,p)
        if p>=len(b): raise ProbeError('TLS 压缩字段截断')
        p+=1+b[p]
    total=u16(b,p); p+=2; end=p+total
    if end!=len(b): raise ProbeError('TLS 扩展长度不合法')
    out={'groups':[], 'key_shares':[]} if not server else {'selected_group':None, 'hello_retry_request':b[2:34]==HRR}
    seen=set()
    while p<end:
        typ=u16(b,p); size=u16(b,p+2); p+=4
        if p+size>end or typ in seen: raise ProbeError('TLS 扩展重复或截断')
        seen.add(typ); e=b[p:p+size]; p+=size
        if not server and typ==10:
            if u16(e,0)!=len(e)-2 or (len(e)-2)%2: raise ProbeError('supported_groups 不合法')
            out['groups']=[u16(e,i) for i in range(2,len(e),2)]
        if typ==51:
            if server:
                g=u16(e,0); out['selected_group']=g
                if out['hello_retry_request']:
                    if len(e)!=2: raise ProbeError('HRR key_share 不合法')
                elif len(e)<4 or u16(e,2)!=len(e)-4: raise ProbeError('服务端 key_share 长度不合法')
            else:
                if u16(e,0)!=len(e)-2: raise ProbeError('key_share 列表截断')
                q=2
                while q<len(e):
                    g=u16(e,q); k=u16(e,q+2); q+=4
                    if q+k>len(e): raise ProbeError('key_share 内容截断')
                    out['key_shares'].append({'group':g,'bytes':k}); q+=k
    return out

class TLSRecords:
    """Reassemble TLS records AND handshake messages across arbitrary TCP splits."""
    def __init__(self,server=False): self.buf=bytearray(); self.hs=bytearray(); self.server=server; self.hello=None; self.error=None
    def feed(self,data):
        if self.hello is not None or self.error: return
        self.buf.extend(data)
        try:
            if len(self.buf)+len(self.hs)>262144: raise ProbeError('TLS 捕获超出长度上限')
            while len(self.buf)>=5:
                typ=self.buf[0]; n=u16(self.buf,3)
                if n>18432: raise ProbeError('TLS record 超出长度上限')
                if len(self.buf)<5+n: break
                payload=bytes(self.buf[5:5+n]); del self.buf[:5+n]
                if typ!=22: continue
                self.hs.extend(payload)
                while len(self.hs)>=4:
                    k=int.from_bytes(self.hs[1:4],'big')
                    if k>131072: raise ProbeError('TLS handshake 超出长度上限')
                    if len(self.hs)<4+k: break
                    msg=bytes(self.hs[:4+k]); del self.hs[:4+k]
                    if msg[0]==(2 if self.server else 1): self.hello=parse_hello(msg,self.server); return
        except (ProbeError,IndexError) as e: self.error=str(e)

def metadata(binary):
    if not binary or not os.path.isfile(binary) or not os.access(binary,os.X_OK):
        return {'available':False,'reason':'未找到可执行核心'}
    h=hashlib.sha256()
    with open(binary,'rb') as f:
        for block in iter(lambda:f.read(1048576),b''): h.update(block)
    out={'available':True,'path':os.path.realpath(binary),'sha256':h.hexdigest(),'go_version':None,'utls_module':None}
    try:
        p=subprocess.run([binary,'version'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=5,text=True)
        out['version_output']=p.stdout[:2000].strip()
        if p.returncode: out.update(available=False,reason='核心无法运行')
    except (OSError,subprocess.TimeoutExpired): out.update(available=False,reason='核心无法运行或读取版本超时')
    try:
        with open(binary,'rb') as f, mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ) as b:
            at=b.find(b'\xff Go buildinf:')
            if at>=0 and at+32<len(b) and b[at+15]&2:
                def string_at(p):
                    n=0; shift=0
                    while shift<64:
                        v=b[p]; p+=1; n|=(v&127)<<shift
                        if not v&128: break
                        shift+=7
                    if shift>=64 or n>1048576 or p+n>len(b): raise ValueError()
                    return bytes(b[p:p+n]),p+n
                ver,pos=string_at(at+32); mods,pos=string_at(pos)
                out['go_version']=ver.decode('utf8','replace')
                if len(mods)>=32: mods=mods[16:-16]
                last_utls=False
                for line in mods.decode('utf8','replace').splitlines():
                    fields=line.split('\t')
                    if len(fields)>=3 and fields[0]=='dep' and fields[1] in ('github.com/metacubex/utls','github.com/refraction-networking/utls'):
                        out['utls_module']={'path':fields[1],'version':fields[2]}
                        last_utls=True
                    elif fields[0]=='=>' and last_utls and len(fields)>=2:
                        out['utls_module']['replacement']={'path':fields[1],'version':fields[2] if len(fields)>2 else '(devel)'}
                        last_utls=False
                    else: last_utls=False
    except (OSError,ValueError,IndexError): pass
    return out

def free_port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]
def write_json(path,data):
    with open(path,'w',encoding='utf8') as f: os.chmod(path,0o600); json.dump(data,f)
def stop(p):
    if p is None: return
    if p.poll() is None:
        try: os.killpg(p.pid,signal.SIGTERM)
        except ProcessLookupError: pass
        try: p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try: os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            p.wait(timeout=2)
    if p in PROCESSES: PROCESSES.remove(p)
def start(binary,cfg,path,ports):
    write_json(path,cfg)
    p=subprocess.Popen([binary,'run','-c',str(path)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    PROCESSES.append(p)
    for port in ports:
        ready=False
        for _ in range(40):
            if p.poll() is not None: break
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1): ready=True; break
            except OSError: time.sleep(.05)
        if not ready or p.poll() is not None:
            stop(p); raise ProbeError('临时探针无法启动（配置、版本或端口问题）')
    return p

def exact(s,n):
    b=b''
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise ProbeError('探针连接提前结束')
        b+=x
    return b
def socks_auth(s):
    s.sendall(b'\x05\x01\x02')
    if exact(s,2)!=b'\x05\x02': raise ProbeError('SOCKS 认证方式不匹配')
    user=SOCKS_USER.encode(); password=SOCKS_PASS.encode()
    s.sendall(b'\x01'+bytes([len(user)])+user+bytes([len(password)])+password)
    if exact(s,2)!=b'\x01\x00': raise ProbeError('SOCKS 一次性认证失败')
def socks_connect(port,dest,timeout):
    s=socket.create_connection(('127.0.0.1',port),timeout=timeout); s.settimeout(timeout)
    try:
        socks_auth(s)
        s.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01'+struct.pack('!H',dest))
        h=exact(s,4)
        if h[:2]!=b'\x05\x00': raise ProbeError('代理拒绝测试连接')
        n={1:4,4:16}.get(h[3])
        if h[3]==3: n=exact(s,1)[0]
        if n is None: raise ProbeError('SOCKS 地址类型异常')
        exact(s,n+2); return s
    except BaseException: s.close(); raise

class Tap:
    def __init__(self,destination=None):
        self.destination=destination; self.client=TLSRecords(); self.server=TLSRecords(True)
        self.sock=socket.socket(); self.sock.bind(('127.0.0.1',0)); self.sock.listen(8); self.sock.settimeout(.2)
        self.port=self.sock.getsockname()[1]; self.closed=threading.Event(); self.sockets=[]
        self.thread=threading.Thread(target=self.accept,daemon=True); self.thread.start()
    def accept(self):
        while not self.closed.is_set():
            try: c,_=self.sock.accept()
            except socket.timeout: continue
            except OSError: break
            self.sockets.append(c); c.settimeout(.3)
            if self.destination is None:
                threading.Thread(target=self.copy,args=(c,None,self.client),daemon=True).start()
            else:
                try: u=socket.create_connection(('127.0.0.1',self.destination),timeout=2); u.settimeout(.3)
                except OSError: c.close(); continue
                self.sockets.append(u)
                threading.Thread(target=self.copy,args=(c,u,self.client),daemon=True).start()
                threading.Thread(target=self.copy,args=(u,c,self.server),daemon=True).start()
    def copy(self,src,dst,parser):
        try:
            while not self.closed.is_set():
                try: b=src.recv(16384)
                except socket.timeout: continue
                if not b: break
                parser.feed(b)
                if dst is None:
                    if parser.hello is not None or parser.error: break
                else: dst.sendall(b)
        except OSError: pass
        finally:
            try: src.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            if dst is not None:
                try: dst.shutdown(socket.SHUT_RDWR)
                except OSError: pass
    def close(self):
        self.closed.set(); self.sock.close()
        for s in self.sockets:
            try: s.close()
            except OSError: pass
        self.thread.join(timeout=1)

def keypair(sb):
    p=subprocess.run([sb,'generate','reality-keypair'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=5)
    priv=re.search(r'PrivateKey:\s*(\S+)',p.stdout); pub=re.search(r'PublicKey:\s*(\S+)',p.stdout)
    if p.returncode or not priv or not pub: raise ProbeError('无法生成一次性 REALITY 密钥')
    return priv[1],pub[1]

def client_capture(sb,fp,proto,tmp,kp,timeout):
    tap=Tap(); p=None; cp=free_port()
    try:
        out={'type':proto,'tag':'test','server':'127.0.0.1','server_port':tap.port,
             'tls':{'enabled':True,'server_name':'probe.invalid','utls':{'enabled':True,'fingerprint':fp},'reality':{'enabled':True,'public_key':kp[1],'short_id':secrets.token_hex(8)}}}
        if proto=='anytls': out['password']=secrets.token_urlsafe(24)
        else: out.update(uuid=str(uuid.uuid4()),flow='xtls-rprx-vision')
        cfg={'log':{'disabled':True},'inbounds':[{'type':'socks','listen':'127.0.0.1','listen_port':cp,'users':[{'username':SOCKS_USER,'password':SOCKS_PASS}]}], 'outbounds':[out], 'route':{'final':'test'}}
        p=start(sb,cfg,tmp/'capture.json',[cp])
        # Capture mode intentionally stops at ClientHello, without authentication.
        s=socket.create_connection(('127.0.0.1',cp),timeout=timeout); s.settimeout(timeout)
        try:
            socks_auth(s)
            s.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x50')
            deadline=time.monotonic()+timeout
            while not tap.client.hello and not tap.client.error and time.monotonic()<deadline: time.sleep(.03)
        finally: s.close()
        if tap.client.error: raise ProbeError('ClientHello 解析失败: '+tap.client.error)
        h=tap.client.hello
        if not h: raise ProbeError('未捕获 ClientHello（超时或指纹不可用）')
        shares=[s['group'] for s in h['key_shares']]
        has=any(s['group']==MLKEM and s['bytes']==1216 for s in h['key_shares'])
        return {'status':'observed','groups':[group_name(x) for x in h['groups']],
                'key_shares':[{'group':group_name(x['group']),'bytes':x['bytes']} for x in h['key_shares']],
                'mlkem_advertised':MLKEM in h['groups'],'mlkem_key_share':has,
                'mlkem_before_x25519':has and (X25519 not in shares or shares.index(MLKEM)<shares.index(X25519))}
    except (ProbeError,OSError,subprocess.TimeoutExpired) as e: return {'status':'unknown','reason':str(e)[:180]}
    finally: stop(p); tap.close()

def fetch_reference(tmp):
    arch={'x86_64':'64','amd64':'64','aarch64':'arm64-v8a','arm64':'arm64-v8a'}.get(platform.machine().lower())
    if not arch: raise ProbeError('自动参考探针仅支持 amd64 / arm64；请用 --xray 指定')
    asset='Xray-linux-'+arch+'.zip'
    # Direct verified HTTPS; no download proxies or unverified override.
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def get(url,limit):
        req=urllib.request.Request(url,headers={'User-Agent':'AnyTLS-Reality-capability-probe/1.3.2','Accept':'application/vnd.github+json'})
        deadline=time.monotonic()+60; data=bytearray()
        with opener.open(req,timeout=15) as r:
            while True:
                b=r.read(65536)
                if not b: break
                data.extend(b)
                if len(data)>limit or time.monotonic()>deadline: raise ProbeError('参考探针下载超出大小或时间上限')
        return bytes(data)
    release=json.loads(get('https://api.github.com/repos/XTLS/Xray-core/releases/tags/'+REFERENCE_TAG,2097152))
    if not isinstance(release,dict) or not isinstance(release.get('assets'),list): raise ProbeError('参考探针发布元数据不合法')
    if release.get('draft') is not False or release.get('prerelease') is not False or release.get('tag_name')!=REFERENCE_TAG: raise ProbeError('无法核实参考探针的正式发布属性')
    a=next((a for a in release['assets'] if isinstance(a,dict) and a.get('name')==asset),None)
    digest=a.get('digest','') if a else ''
    if not isinstance(digest,str) or not re.fullmatch(r'sha256:[0-9a-fA-F]{64}',digest): raise ProbeError('未取得参考探针官方 SHA256，拒绝执行下载物')
    url='https://github.com/XTLS/Xray-core/releases/download/'+REFERENCE_TAG+'/'+asset
    data=get(url,125829120)
    if hashlib.sha256(data).hexdigest()!=digest[7:].lower(): raise ProbeError('参考探针 SHA256 不匹配')
    archive=tmp/'reference.zip'; archive.write_bytes(data)
    with zipfile.ZipFile(archive) as z:
        entry=z.getinfo('xray')
        if entry.file_size>125829120 or (entry.external_attr>>16)&0o170000==0o120000: raise ProbeError('参考探针 ZIP 内容不合法')
        target=tmp/'reference-xray'; target.write_bytes(z.read(entry)); target.chmod(0o700)
    return str(target),{'downloaded':True,'tag':REFERENCE_TAG,'archive_sha256':digest[7:].lower()}

def xr_client(cp,server,sni,kp,sid,user):
    return {'log':{'loglevel':'none'},'inbounds':[{'listen':'127.0.0.1','port':cp,'protocol':'socks','settings':{'udp':False,'auth':'password','accounts':[{'user':SOCKS_USER,'pass':SOCKS_PASS}]}}],
       'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':'127.0.0.1','port':server,'users':[{'id':user,'encryption':'none','flow':'xtls-rprx-vision'}]}]},
       'streamSettings':{'network':'tcp','security':'reality','realitySettings':{'serverName':sni,'fingerprint':'chrome','publicKey':kp[1],'shortId':sid}}}]}

class Fixture:
    def __init__(self):
        self.token=secrets.token_hex(24); token=self.token
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path!='/'+token: self.send_error(404); return
                body=('ATR_PROBE_'+token).encode(); self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
            def log_message(self,*args): pass
        self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.server.daemon_threads=True
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True); self.thread.start()
        self.port=self.server.server_address[1]
    def close(self): self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=1)

def tunnel_case(sb,xr,tmp,kp,fixture,sni,target_port,timeout,reference=False,dest_host=None):
    sp=free_port(); cp=free_port(); sid=secrets.token_hex(8); user=str(uuid.uuid4()); server=None; client=None; tap=None
    target_host=dest_host or ('127.0.0.1' if sni=='localhost' else sni)
    try:
        if reference:
            cfg={'log':{'loglevel':'none'},'inbounds':[{'listen':'127.0.0.1','port':sp,'protocol':'vless',
                 'settings':{'clients':[{'id':user,'flow':'xtls-rprx-vision'}],'decryption':'none'},
                 'streamSettings':{'network':'tcp','security':'reality','realitySettings':{'target':(('['+target_host+']') if ':' in target_host else target_host)+':'+str(target_port),'serverNames':[sni],'privateKey':kp[0],'shortIds':[sid]}}}],
                 'outbounds':[{'protocol':'freedom','settings':{'finalRules':[{'action':'allow','network':'tcp','port':str(fixture.port),'ip':['127.0.0.1/32']}]}}]}
            server=start(xr,cfg,tmp/'reference-server.json',[sp])
        else:
            cfg={'log':{'disabled':True},'inbounds':[{'type':'vless','tag':'test','listen':'127.0.0.1','listen_port':sp,
                'users':[{'uuid':user,'flow':'xtls-rprx-vision'}], 'tls':{'enabled':True,'server_name':sni,'reality':{'enabled':True,'handshake':{'server':target_host,'server_port':target_port},'private_key':kp[0],'short_id':[sid]}}}],
                'outbounds':[{'type':'direct'}]}
            server=start(sb,cfg,tmp/'singbox-server.json',[sp])
        tap=Tap(sp)
        client=start(xr,xr_client(cp,tap.port,sni,kp,sid,user),tmp/'reference-client.json',[cp])
        data=b''; failure=None
        try:
            with socks_connect(cp,fixture.port,timeout) as s:
                s.sendall(('GET /'+fixture.token+' HTTP/1.1\r\nHost: probe.invalid\r\nConnection: close\r\n\r\n').encode())
                deadline=time.monotonic()+timeout
                while len(data)<65536 and time.monotonic()<deadline:
                    b=s.recv(4096)
                    if not b: break
                    data+=b
                    if ('ATR_PROBE_'+fixture.token).encode() in data: break
        except (OSError,ProbeError) as e: failure=type(e).__name__
        h=tap.server.hello; g=h.get('selected_group') if h else None
        passed=('ATR_PROBE_'+fixture.token).encode() in data and server.poll() is None and client.poll() is None
        ch=tap.client.hello
        status='passed' if passed else ('unknown' if h is None or h.get('hello_retry_request') else 'failed')
        return {'status':status,'authenticated_tunnel':passed,
                'selected_group':group_name(g) if g is not None and not h.get('hello_retry_request') else None,
                'requested_group':group_name(g) if h and h.get('hello_retry_request') and g is not None else None,
                'hello_retry_request':h.get('hello_retry_request',False) if h else None,
                'reference_mlkem_key_share':any(k['group']==MLKEM and k['bytes']==1216 for k in ch['key_shares']) if ch else None,
                'reason':None if passed else (failure or '未完成 REALITY 认证后的测试数据转发')}
    except (OSError,ProbeError,subprocess.TimeoutExpired) as e: return {'status':'unknown','reason':str(e)[:180],'authenticated_tunnel':False,'selected_group':None}
    finally: stop(client); stop(server); tap.close() if tap else None

def controlled_targets(xr,tmp):
    if not shutil.which('openssl'): raise ProbeError('缺少 openssl，无法生成临时目标证书')
    crt=tmp/'fixture.crt'; key=tmp/'fixture.key'
    p=subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-keyout',str(key),'-out',str(crt),'-days','1','-subj','/CN=localhost'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
    if p.returncode: raise ProbeError('无法生成临时目标证书')
    classic=free_port(); hybrid=free_port(); inbounds=[]
    for port,group in [(classic,'X25519'),(hybrid,'X25519MLKEM768')]:
        inbounds.append({'listen':'127.0.0.1','port':port,'protocol':'vless','settings':{'clients':[{'id':str(uuid.uuid4())}],'decryption':'none'},
            'streamSettings':{'network':'tcp','security':'tls','tlsSettings':{'minVersion':'1.3','maxVersion':'1.3','alpn':['h2'],
             'curvePreferences':[group],'certificates':[{'certificateFile':str(crt),'keyFile':str(key)}]}}})
    # Target can complete TLS but cannot forward the nonce, even on accidental fallback.
    p=start(xr,{'log':{'loglevel':'none'},'inbounds':inbounds,'outbounds':[{'protocol':'blackhole'}]},tmp/'targets.json',[classic,hybrid])
    return p,classic,hybrid

def configured_targets(statefile):
    try:
        st=json.loads(pathlib.Path(statefile).read_text()); out=[]
        for ident,p in st.get('protocols',{}).items():
            if p.get('core')!='sing-box' or ident not in ('anytls_reality','vless_reality_vision','vless_reality_grpc'): continue
            r=p.get('reality',{}) if st.get('reality_mode','shared')=='independent' else st.get('reality',{})
            host=r.get('sni',''); dest=r.get('dest_host',host); port=r.get('dest_port',443)
            if valid_target(host,port) and isinstance(dest,str) and dest and (host,dest,port) not in [(t['sni'],t.get('dest_host',t['sni']),t['port']) for t in out]: out.append({'sni':host,'dest_host':dest,'port':port,'source_protocol':ident})
        return out[:4]
    except (OSError,ValueError,TypeError,AttributeError): return []
def valid_target(host,port): return isinstance(host,str) and re.fullmatch(r'(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}',host) is not None and type(port) is int and 1<=port<=65535

def server_probes(sb,xr,tmp,kp,targets,timeout):
    fixture=Fixture(); target_process=None
    result={'status':'unknown','scope':'临时 VLESS 入站测试共用 REALITY 层；不等同 AnyTLS 应用层或生产节点连通性测试','current_targets':[]}
    try:
        target_process,classic,hybrid=controlled_targets(xr,tmp)
        # localhost fixture SNI is mapped to loopback by normal resolver.
        c=tunnel_case(sb,xr,tmp,kp,fixture,'localhost',classic,timeout)
        r=tunnel_case(sb,xr,tmp,kp,fixture,'localhost',hybrid,timeout,reference=True)
        h=tunnel_case(sb,xr,tmp,kp,fixture,'localhost',hybrid,timeout)
        result.update(classical_control=c,hybrid_reference_control=r,hybrid_test=h)
        reference_ok=r.get('authenticated_tunnel') and r.get('selected_group')=='X25519MLKEM768' and r.get('reference_mlkem_key_share')
        classic_ok=c.get('authenticated_tunnel') and c.get('selected_group')=='X25519'
        if reference_ok and h.get('authenticated_tunnel') and h.get('selected_group')=='X25519MLKEM768':
            result.update(status='supported_verified',reason='已完成混合交换、REALITY 认证及一次性数据转发；参考对照通过')
        elif reference_ok and classic_ok and h.get('status')=='failed':
            result.update(status='hybrid_test_failed',reason='混合测试失败，经典与混合参考对照通过；仅适用于本次版本/探针组合，不推断所有实现均不支持')
        else: result['reason']='对照不完整或结果不一致，不能判定为不支持'
        for target in targets:
            test=tunnel_case(sb,xr,tmp,kp,fixture,target['sni'],target['port'],timeout,dest_host=target.get('dest_host'))
            result['current_targets'].append({**target,**test,'scope':'当前 SNI/目标配置的临时实例；使用参考客户端与一次性密钥，并非生产连接抓包'})
    except (OSError,ProbeError,subprocess.TimeoutExpired) as e: result['reason']=str(e)[:180]
    finally: stop(target_process); fixture.close()
    return result

def display(r):
    print('REALITY 能力与协商检测（'+r['script_version']+'）')
    print('sing-box: '+r['sing_box'].get('version_output',r['sing_box'].get('reason','未知')).split('\n')[0])
    if r['sing_box'].get('sha256'): print('SHA256: '+r['sing_box']['sha256'])
    module=r['sing_box'].get('utls_module'); print('uTLS 依赖: '+(module['path']+' '+module['version'] if module else '未能读取；不以此推断能力'))
    if module and module.get('replacement'): print('  模块替换: '+module['replacement']['path']+' '+module['replacement']['version'])
    for c in r['client_tests']:
        samples=c['samples']; good=[s for s in samples if s['status']=='observed']; offered=sum(s['mlkem_key_share'] for s in good)
        advertised=sum(s['mlkem_advertised'] for s in good)
        print('客户端 '+c['protocol']+' / '+c['fingerprint']+': 声明 MLKEM '+str(advertised)+'/'+str(len(good))+'，发送混合 KeyShare '+str(offered)+'/'+str(len(good))+'，未确认 '+str(len(samples)-len(good)))
        if good:
            print('  首样本 groups: '+', '.join(good[0]['groups']))
            print('  首样本 key_share: '+', '.join(k['group']+'('+str(k['bytes'])+')' for k in good[0]['key_shares']))
        else: print('  '+samples[0].get('reason','未能确认'))
    labels={'supported_verified':'已验证支持混合交换','hybrid_test_failed':'本次混合测试失败','unknown':'未能确认','not_run':'未执行','passed':'认证及转发成功','failed':'测试失败'}
    s=r['server']; print('服务端: '+labels.get(s['status'],s['status'])+' — '+s.get('reason','未能确认'))
    for name,label in [('classical_control','经典对照'),('hybrid_reference_control','混合参考对照'),('hybrid_test','sing-box 混合测试')]:
        if name in s:
            t=s[name]; print('  '+label+': '+labels.get(t['status'],t['status'])+'，协商 '+str(t.get('selected_group') or '未能确认'))
    for t in s.get('current_targets',[]): print('目标 '+t['sni']+':'+str(t['port'])+': '+labels.get(t['status'],t['status'])+'，协商 '+str(t.get('selected_group') or '未能确认'))
    print('认证: '+r['authentication']['conclusion'])
    print('结论: '+r['conclusion'])
    for note in r['limitations']: print('说明: '+note)

def main(argv=None):
    ap=argparse.ArgumentParser(description='REALITY 能力诊断；临时回环实例，不修改生产配置')
    ap.add_argument('--sing-box',default=os.environ.get('ATR_PROBE_SB',''))
    ap.add_argument('--xray',default=os.environ.get('ATR_PROBE_XRAY',''))
    ap.add_argument('--state',default=os.environ.get('ATR_PROBE_STATE','/etc/anytls-reality/state.json'))
    ap.add_argument('--fingerprints',default='chrome,firefox,safari,randomized')
    ap.add_argument('--samples',type=int,default=3,help='randomized 样本数，1–20')
    ap.add_argument('--protocol',choices=['anytls','vless','both'],default='both')
    ap.add_argument('--target',action='append',default=[],help='额外目标 SNI[:端口]，最多 4 个')
    ap.add_argument('--timeout',type=float,default=5,help='单次网络操作超时，1–15 秒')
    ap.add_argument('--quick',action='store_true',help='只捕获客户端，不运行服务端/目标探针')
    ap.add_argument('--no-fetch',action='store_true',help='缺少 Xray 参考探针时不临时下载')
    ap.add_argument('--json',action='store_true',help='标准输出仅输出 JSON')
    ap.add_argument('--output',help='将脱敏 JSON 报告另存为文件（原子替换）')
    a=ap.parse_args(argv)
    fps=list(dict.fromkeys(a.fingerprints.split(',')))
    if not 1<=a.samples<=20 or not 1<=a.timeout<=15 or not fps or len(fps)>8 or any(f not in ('chrome','firefox','safari','edge','ios','randomized','360','qq','android') for f in fps): ap.error('指纹、样本数或超时参数不合法')
    targets=configured_targets(a.state)
    for t in a.target:
        host,sep,port=t.partition(':')
        if not valid_target(host,int(port) if sep and port.isdecimal() and len(port)<=5 else (443 if not sep else 0)): ap.error('目标必须是有效 SNI[:端口]')
        targets.append({'sni':host,'port':int(port) if sep else 443,'source_protocol':'command-line'})
    targets=list({(t['sni'],t['port']):t for t in targets}.values())
    if len(targets)>4: ap.error('目标数量超过 4 个')
    sb=a.sing_box or shutil.which('sing-box') or ''; xr=a.xray or shutil.which('xray') or ''
    if a.output:
        protected=[a.state,os.environ.get('ATR_PROBE_SCRIPT','')]
        for core in (sb,xr):
            if core:
                binary=pathlib.Path(core).resolve()
                protected.extend([str(binary),str(binary.parent/'conf/config.json'),str(binary.parent.parent/'state.json'),str(binary.parent.parent/'anytls-reality.sh')])
        dest=pathlib.Path(a.output).resolve()
        if any(p and dest==pathlib.Path(p).resolve() for p in protected): ap.error('报告路径不能覆盖状态文件、核心、核心配置或管理脚本')
    r={'schema':1,'script_version':os.environ.get('ATR_PROBE_VERSION','1.3.2'),'time_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
       'sing_box':metadata(sb),'reference':{'available':False},'client_tests':[],
       'server':{'status':'unknown','reason':'未执行'},
       'authentication':{'status':'not_verified','conclusion':'本探针未验证 ML-DSA 等额外抗量子身份认证；混合密钥交换不等于完整抗量子认证'},
       'limitations':['抓到声明或 KeyShare 不等于本次已协商该算法；仅凭指纹差异不判定必然可识别。',
          '服务端测试使用共用 REALITY 层的临时 VLESS 入站，不能用 Xray 客户端直接证明 AnyTLS 应用层互通。',
          '服务端能力成立不代表当前 sing-box 客户端会使用；生产节点状态、防火墙与长期安全不在本项证明范围内。']}
    with tempfile.TemporaryDirectory(prefix='atr-reality-probe.') as temp:
        tmp=pathlib.Path(temp); os.chmod(tmp,0o700)
        if r['sing_box']['available']:
            try:
                kp=keypair(sb)
                for proto in (['anytls','vless'] if a.protocol=='both' else [a.protocol]):
                    for fp in fps:
                        samples=[client_capture(sb,fp,proto,tmp,kp,a.timeout) for _ in range(a.samples if fp=='randomized' else 1)]
                        r['client_tests'].append({'protocol':proto,'fingerprint':fp,'samples':samples})
                if a.quick: r['server']={'status':'not_run','reason':'快速模式仅执行客户端捕获'}
                else:
                    try:
                        provenance={'downloaded':False}
                        if not xr and not a.no_fetch:
                            if not a.json: print('临时取得校验后的 Xray 参考探针（不安装、不替换核心）…',file=sys.stderr)
                            xr,provenance=fetch_reference(tmp)
                        r['reference']={**metadata(xr),**provenance}
                        if r['reference']['available']: r['server']=server_probes(sb,xr,tmp,kp,targets,a.timeout)
                        else: r['server']={'status':'unknown','reason':'缺少可运行的 Xray 参考探针；可指定 --xray，或允许临时下载'}
                    except (ProbeError,OSError,ValueError,KeyError,TypeError,zipfile.BadZipFile) as e: r['server']={'status':'unknown','reason':'参考探针准备失败: '+(str(e)[:180] if isinstance(e,ProbeError) else type(e).__name__)+'；未执行未经核验的下载物'}
            except (ProbeError,OSError,subprocess.TimeoutExpired) as e: r['server']={'status':'unknown','reason':str(e)[:180]}
        else: r['server']={'status':'unknown','reason':'未找到可运行的 sing-box；请先安装或用 --sing-box 指定'}
        # Rehash local binaries; a concurrent core replacement invalidates attribution.
        if r['sing_box'].get('available') and metadata(sb).get('sha256')!=r['sing_box']['sha256']:
            r['server']={'status':'unknown','reason':'检测期间核心发生替换，本次结果不能归因于同一个二进制'}
            r['client_tests']=[]
        if r['reference'].get('available') and metadata(xr).get('sha256')!=r['reference']['sha256']:
            r['server']={'status':'unknown','reason':'检测期间参考探针发生替换，无法确认结果'}
        observed=[s for c in r['client_tests'] for s in c['samples'] if s['status']=='observed']
        emitted=any(s['mlkem_key_share'] for s in observed)
        r['conclusion']=('已在部分已测指纹观察到混合 KeyShare，需结合认证后协商结果判断。' if emitted else
             '已捕获的客户端样本均未发送混合 KeyShare；结论仅限本次核心、协议及指纹。' if observed else '客户端能力未能确认。')
        if r['server']['status']=='supported_verified':
            r['conclusion']='服务端已验证支持混合交换；'+r['conclusion']+' 服务端成功使用参考客户端，不代表本机 sing-box 客户端已使用混合交换。'
        r['complete']=r['sing_box'].get('available',False) and bool(r['client_tests']) and all(s['status']=='observed' for c in r['client_tests'] for s in c['samples']) and (a.quick or (r['server']['status'] in ('supported_verified','hybrid_test_failed') and all(t['status']!='unknown' for t in r['server'].get('current_targets',[]))))
        if a.output:
            dest=pathlib.Path(a.output).absolute(); fd,path=tempfile.mkstemp(prefix='.atr-report.',dir=dest.parent)
            try:
                with os.fdopen(fd,'w') as f: json.dump(r,f,ensure_ascii=False,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
                os.replace(path,dest)
            finally:
                if os.path.exists(path): os.unlink(path)
        if a.json: print(json.dumps(r,ensure_ascii=False,indent=2))
        else: display(r)
    return 0 if r['complete'] else 2

def cleanup():
    for p in list(reversed(PROCESSES)): stop(p)
def interrupted(signum,frame): raise KeyboardInterrupt()
if __name__=='__main__':
    signal.signal(signal.SIGTERM,interrupted)
    try: sys.exit(main())
    except KeyboardInterrupt: print('检测已中止；临时探针正在清理',file=sys.stderr); sys.exit(130)
    except (OSError,ValueError,ProbeError) as e: print('检测未能完成: '+type(e).__name__,file=sys.stderr); sys.exit(2)
    finally: cleanup()
ATR_REALITY_PROBE_PY
}

# ----------------------------- 5. REALITY 管理 --------------------------------
realityShowParams() {
    echoContent skyBlue "\n---------------- 当前 Reality 参数 ----------------"
    echoContent yellow "配置方式: $(realityMode)"
    local id profile
    realityStatusExtras
    while read -r id; do
        [[ -n "${id}" ]] || continue
        profile=$(realityProfile "${id}")
        echoContent yellow "$(protoName "${id}")（$(S --arg id "${id}" '.protocols[$id].core')，端口 $(protoPort "${id}")）"
        printRaw green "  SNI: $(jq -r '.sni' <<<"${profile}"):$(jq -r '.dest_port // 443' <<<"${profile}")"
        printRaw green "  公钥: $(jq -r '.public_key' <<<"${profile}")"
        printRaw green "  Short ID: $(jq -r '.short_id' <<<"${profile}")"
    done < <(installedRealityProtocols)
}

manageReality() {
    requireInstalled || return 1
    [[ -n "$(installedRealityProtocols)" ]] || { echoContent red " ---> 请先安装 Reality 类协议"; return 1; }
    echoContent skyBlue "\nREALITY 管理（当前 $(realityMode)）"
    echoContent yellow "1.查看各协议 Reality 参数"
    echoContent yellow "2.修改 SNI（保留密钥，独立模式先选协议）"
    echoContent yellow "3.修改协议端口"
    echoContent yellow "4.重置密钥对和 Short ID（独立模式只影响所选协议）"
    echoContent yellow "5.按各自核心自检"
    echoContent yellow "6.切换共享 / 独立配置"
    echoContent yellow "7.REALITY 能力与协商检测（MLKEM / 指纹 / 服务端）"
    echoContent yellow "8.指定客户端组合自检  9.时间差限制  10.AnyTLS 填充策略"
    echoContent yellow "11.AnyTLS JSON 导入文件  12.导出外部实连探针"
    local c id="" profile port scope="全部 Reality 协议"
    ask c "请选择:" || return 1
    case "${c}" in
    1) realityShowParams ;;
    2 | 4)
        if [[ "$(realityMode)" == independent ]]; then
            pickRealityProtocol || return 1
            id=${PICK_REALITY_ID}; scope=$(protoName "${id}")
        fi
        profile=$(realityProfile "${id}")
        if [[ "${c}" == 2 ]]; then
            REALITY_CORE_HINT=$(realityCoreHint "" "${id}")
            echoContent yellow "影响范围: ${scope}；已有客户端需同步 SNI"
            realityPickSNI "$(jq -r '.sni' <<<"${profile}"):$(jq -r '.dest_port // 443' <<<"${profile}")" || return 1
            stagedBegin
            stagedSetReality "${PICK_SNI}" "${PICK_PORT}" no "${id}" "${PICK_DEST_HOST:-${PICK_SNI}}" || return 1
        else
            confirm "重置 ${scope} 的密钥和 Short ID？相关客户端必须更新，失败自动回滚。" n || return 0
            stagedBegin
            stagedSetReality "$(jq -r '.sni' <<<"${profile}")" "$(jq -r '.dest_port // 443' <<<"${profile}")" yes "${id}" || return 1
        fi
        if applyStaged "修改 Reality ${scope}"; then postChangeShow "" "Reality 参数已更新"; selfCheckAll; else stagedDiscard; return 1; fi
        ;;
    3)
        pickRealityProtocol || return 1; id=${PICK_REALITY_ID}
        stagedBegin
        askPort port "${id}" "$(protoName "${id}") 新" tcp "$(protoPort "${id}")" || return 1
        stagedEdit --arg id "${id}" --argjson p "${port}" '.protocols[$id].port=$p' || return 1
        if applyStaged "修改 ${id} 端口"; then postChangeShow "" "端口已更新"; else stagedDiscard; return 1; fi
        ;;
    5) selfCheckAll ;;
    6)
        stagedBegin
        pickRealityMode || return 1
        if applyStaged "切换 Reality 配置方式"; then postChangeShow "" "Reality 配置方式已更新"; selfCheckAll; else stagedDiscard; return 1; fi
        ;;
    7) realityCapabilities ;;
    8)
        pickRealityProtocol || return 1
        local client
        ask client "客户端核心（sing-box / mihomo / xray）:" sing-box || return 1
        clientProbe "${PICK_REALITY_ID}" "${client}" ;;
    9) realitySetTimeMenu ;;
    10) manageAnyTLSPadding ;;
    11) showAnyTLSExport ;;
    12) externalProbeExport ;;
    *) echoContent red " ---> 选择错误"; return 1 ;;
    esac
}


# ----------------------------- 端口跳跃 (Hysteria2 / Tuic) --------------------
HOP_UNIT="atr-hop"

hopSupported() { command -v iptables >/dev/null 2>&1 || { command -v firewall-cmd >/dev/null 2>&1 && [[ "$(firewall-cmd --state 2>/dev/null)" == running ]]; }; }

# 记录采用固定字段，绝不 eval 防火墙输出。firewalld 分别管理运行时和永久配置，不全局 reload。
_hopExists() { # 0=存在；1=不存在；2=查询失败
    local kind=$1 part=$2 range=$3 port=${4:-} rc
    case "${kind}" in
    iptables|ip6tables)
        "${kind}" -w 5 -t nat -C PREROUTING -p udp --dport "${range/-/:}" -m comment --comment "atr_hop_${part}" -j REDIRECT --to-ports "${port}" >/dev/null 2>&1; rc=$?
        ;;
    firewalld|firewalld6)
        local -a opts=()
        [[ "${part%%@*}" == permanent ]] && opts+=(--permanent)
        [[ "${part}" != *@* ]] || opts+=("--zone=${part#*@}")
        local query=--query-forward-port
        if [[ "${kind}" == firewalld6 ]]; then
            local r=${range#port=} p=${range##*:toport=}
            r=${r%%:proto=*}
            range="rule family=\"ipv6\" forward-port port=\"${r}\" protocol=\"udp\" to-port=\"${p}\""
            query=--query-rich-rule
        fi
        firewall-cmd "${opts[@]}" "${query}=${range}" >/dev/null 2>&1; rc=$?
        ;;
    *) return 2 ;;
    esac
    case "${rc}" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

_hopChange() { # add|del kind part range [port]，调用前已记录逆操作
    local action=$1 kind=$2 part=$3 range=$4 port=${5:-} rc flag
    _hopExists "${kind}" "${part}" "${range}" "${port}"; rc=$?
    ((rc<2)) || return 1
    if [[ "${action}" == add && ${rc} == 0 || "${action}" == del && ${rc} == 1 ]]; then return 0; fi
    case "${kind}" in
    iptables|ip6tables)
        flag=-A; [[ "${action}" == del ]] && flag=-D
        "${kind}" -w 5 -t nat "${flag}" PREROUTING -p udp --dport "${range/-/:}" -m comment --comment "atr_hop_${part}" -j REDIRECT --to-ports "${port}" >/dev/null 2>&1 || return 1
        ;;
    firewalld|firewalld6)
        local -a opts=()
        [[ "${part%%@*}" == permanent ]] && opts+=(--permanent)
        [[ "${part}" != *@* ]] || opts+=("--zone=${part#*@}")
        local value=${range}
        flag=--add-forward-port; [[ "${action}" == del ]] && flag=--remove-forward-port
        if [[ "${kind}" == firewalld6 ]]; then
            local r=${range#port=} p=${range##*:toport=}
            r=${r%%:proto=*}
            value="rule family=\"ipv6\" forward-port port=\"${r}\" protocol=\"udp\" to-port=\"${p}\""
            flag=--add-rich-rule; [[ "${action}" == del ]] && flag=--remove-rich-rule
        fi
        firewall-cmd "${opts[@]}" "${flag}=${value}" >/dev/null 2>&1 || return 1
        ;;
    *) return 1 ;;
    esac
    _hopExists "${kind}" "${part}" "${range}" "${port}"; rc=$?
    if [[ "${action}" == add ]]; then ((rc==0)); else ((rc==1)); fi
}

_hopSnapshot() { # stdout: 本脚本拥有的实际规则
    local ipt out line part range port scope spec rc kind zone
    local -a fields
    for ipt in iptables ip6tables; do
        command -v "${ipt}" >/dev/null 2>&1 || continue
        out=$("${ipt}" -w 5 -t nat -S PREROUTING 2>/dev/null) || return 1
        while IFS= read -r line; do
            [[ "${line}" == *atr_hop_* ]] || continue
            # 只接受脚本的规范规则；未知带标签规则不冒险删除。
            line=${line//\"/}
            read -r -a fields <<<"${line}"
            [[ ${#fields[@]} == 16 && ${fields[0]} == -A && ${fields[1]} == PREROUTING && ${fields[2]} == -p && ${fields[3]} == udp && ${fields[4]} == -m && ${fields[5]} == udp && ${fields[6]} == --dport && ${fields[8]} == -m && ${fields[9]} == comment && ${fields[10]} == --comment && ${fields[12]} == -j && ${fields[13]} == REDIRECT && ${fields[14]} == --to-ports ]] || {
                echoContent red " ---> 无法识别已有跳跃规则: ${ipt}" >&2; return 1;
            }
            part=${fields[11]#atr_hop_}; range=${fields[7]/:/-}; port=${fields[15]}
            [[ "${part}" == tuic || "${part}" == hysteria2 ]] && [[ "${range}" =~ ^[0-9]+-[0-9]+$ && "${port}" =~ ^[0-9]+$ ]] || return 1
            printf '%s %s %s %s\n' "${ipt}" "${part}" "${range}" "${port}"
        done <<<"${out}"
    done
    if [[ -s "${ATR_HOME}/hop_firewalld.list" ]]; then
        command -v firewall-cmd >/dev/null 2>&1 || return 1
        while read -r scope spec; do
            [[ -n "${scope}" ]] || continue
            if [[ "${scope}" == port=* ]]; then spec=${scope}; scope=legacy; fi
            kind=firewalld
            if [[ "${scope}" == ipv6-* ]]; then kind=firewalld6; scope=${scope#ipv6-}; fi
            [[ "${scope}" =~ ^(runtime|permanent)(@[A-Za-z0-9_-]+)?$ || "${scope}" == legacy ]] || return 1
            [[ "${spec}" =~ ^port=[0-9]+-[0-9]+:proto=udp:toport=[0-9]+$ ]] || return 1
            for part in runtime permanent; do
                [[ "${scope}" == legacy || "${scope%%@*}" == "${part}" ]] || continue
                if [[ "${scope}" == *@* ]]; then zone=${scope#*@}; else zone=$(firewall-cmd --get-default-zone 2>/dev/null) || return 1; fi
                [[ "${zone}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
                _hopExists "${kind}" "${part}@${zone}" "${spec}"; rc=$?
                ((rc<2)) || return 1
                ((rc!=0)) || printf '%s %s@%s %s\n' "${kind}" "${part}" "${zone}" "${spec}"
            done
        done <"${ATR_HOME}/hop_firewalld.list"
    fi
}

_hopRecover() {
    local journal="${ATR_HOME}/hop.pending" action kind part range port rc=0
    [[ -d "${journal}" ]] || return 0
    [[ -f "${journal}/ready" ]] || { rm -f "${journal}/ledger" "${journal}/ops"; rmdir "${journal}"; return $?; }
    while read -r action kind part range port; do
        [[ -n "${kind}" ]] || continue
        if [[ "${action}" == add ]]; then action=del; else action=add; fi
        _hopChange "${action}" "${kind}" "${part}" "${range}" "${port}" || rc=1
    done < <(tac "${journal}/ops")
    if ((rc==0)); then
        cp "${journal}/ledger" "${ATR_HOME}/hop_firewalld.list" || return 1
        rm -f "${journal}/ready" "${journal}/ops" "${journal}/ledger"
        rmdir "${journal}" || return 1
    else
        echoContent red " ---> 跳跃规则回滚未完成，已保留 ${journal}；排除防火墙故障后重试。" >&2
    fi
    return "${rc}"
}

_hopDesired() {
    local st=$1 id range port ipt backend=iptables zone
    if command -v firewall-cmd >/dev/null 2>&1 && [[ "$(firewall-cmd --state 2>/dev/null)" == running ]]; then backend=firewalld; fi
    local rows
    rows=$(jq -er '.protocols // {} | to_entries | map(select((.value.hop // "")!="")) | .[]? | "\(.key) \(.value.hop) \(.value.port)"' "${st}"); local rc=$?
    [[ ${rc} == 0 || ${rc} == 4 ]] || return 1
    while read -r id range port; do
        [[ -n "${id}" ]] || continue
        [[ "${id}" == hysteria2 || "${id}" == tuic ]] && [[ "${range}" =~ ^[0-9]{5}-[0-9]{5}$ ]] && isPort "${port}" || return 1
        local a=${range%-*} b=${range#*-}
        ((a>=30000 && b<=40000 && a<b)) || return 1
        if [[ "${backend}" == firewalld ]]; then
            zone=$(firewall-cmd --get-default-zone 2>/dev/null) || return 1
            [[ "${zone}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
            local kind part
            for kind in firewalld firewalld6; do
                for part in runtime permanent; do
                    printf '%s %s@%s port=%s:proto=udp:toport=%s\n' "${kind}" "${part}" "${zone}" "${range}" "${port}"
                done
            done
        else
            command -v iptables >/dev/null 2>&1 || return 1
            for ipt in iptables ip6tables; do
                command -v "${ipt}" >/dev/null 2>&1 && printf '%s %s %s %s\n' "${ipt}" "${id}" "${range}" "${port}"
            done
        fi
    done <<<"${rows}"
    return 0
}

_hopSync() { # 调用方持锁；每次写规则前先持久记录逆操作
    local st=$1 journal="${ATR_HOME}/hop.pending" tmp action kind part range port rc line
    _hopRecover || return 1
    tmp=$(mktemp -d "${ATR_TMP}/hop.XXXXXX") || return 1
    if ! _hopSnapshot >"${tmp}/old" || ! _hopDesired "${st}" >"${tmp}/desired"; then
        rm -f "${tmp}/old" "${tmp}/desired"; rmdir "${tmp}"
        echoContent red " ---> 跳跃规则查询或参数检查失败，未改动规则" >&2; return 1
    fi
    sort -u "${tmp}/old" -o "${tmp}/old" && sort -u "${tmp}/desired" -o "${tmp}/desired" || return 1
    mkdir -m 700 "${journal}" || return 1
    if [[ -f "${ATR_HOME}/hop_firewalld.list" ]]; then cp "${ATR_HOME}/hop_firewalld.list" "${journal}/ledger" || return 1; else : >"${journal}/ledger" || return 1; fi
    if [[ ! -f "${journal}/ledger" ]] || ! : >"${journal}/ops" || ! touch "${journal}/ready" || ! sync -f "${journal}"; then return 1; fi
    : >"${tmp}/ledger" || { _hopRecover; return 1; }
    # 先添加新范围，成功后才删旧范围；从不接管管理员原有的相同 firewalld 规则。
    rc=0
    while read -r kind part range port; do
        [[ -n "${kind}" ]] || continue
        line="${kind} ${part} ${range}${port:+ ${port}}"
        _hopExists "${kind}" "${part}" "${range}" "${port}"; action=$?
        if ((action==2)); then rc=1; break; fi
        if ((action==1)); then
            printf 'add %s\n' "${line}" >>"${journal}/ops" && sync -f "${journal}/ops" && _hopChange add "${kind}" "${part}" "${range}" "${port}" || { rc=1; break; }
            [[ "${kind}" != firewalld* ]] || printf '%s%s %s\n' "$( [[ "${kind}" == firewalld6 ]] && printf 'ipv6-' )" "${part}" "${range}" >>"${tmp}/ledger" || { rc=1; break; }
        elif [[ "${kind}" == firewalld* ]] && grep -Fxq "${line}" "${tmp}/old"; then
            printf '%s%s %s\n' "$( [[ "${kind}" == firewalld6 ]] && printf 'ipv6-' )" "${part}" "${range}" >>"${tmp}/ledger" || { rc=1; break; }
        fi
    done <"${tmp}/desired"
    if ((rc==0)); then
        while read -r kind part range port; do
            [[ -n "${kind}" ]] || continue
            line="${kind} ${part} ${range}${port:+ ${port}}"
            printf 'del %s\n' "${line}" >>"${journal}/ops" && sync -f "${journal}/ops" && _hopChange del "${kind}" "${part}" "${range}" "${port}" || { rc=1; break; }
        done < <(comm -23 "${tmp}/old" "${tmp}/desired")
    fi
    if ((rc==0)); then
        chmod 600 "${tmp}/ledger" && mv -f "${tmp}/ledger" "${ATR_HOME}/hop_firewalld.list" && sync -f "${ATR_HOME}/hop_firewalld.list" || rc=1
    fi
    if ((rc)); then
        echoContent red " ---> 跳跃规则应用失败，正在撤销本次变更；配置不会报告成功。" >&2
        _hopRecover || true
    else
        rm -f "${journal}/ready" "${journal}/ops" "${journal}/ledger"; rmdir "${journal}" || rc=1
    fi
    rm -f "${tmp}/old" "${tmp}/desired" "${tmp}/ledger"; rmdir "${tmp}"
    return "${rc}"
}

hopRulesRemoveAll() {
    lockAcquire || return 1
    local st rc
    st=$(mktemp "${ATR_TMP}/hop-empty.XXXXXX") || { lockRelease; return 1; }
    printf '{"protocols":{}}\n' >"${st}"
    _hopSync "${st}"; rc=$?
    rm -f "${st}"
    lockRelease
    return "${rc}"
}

# 兼容独立调用；整批规则由 reconcileHopRules 统一提交。
hopRuleAdd() {
    local id=$1 range=$2 port=$3 st rc
    lockAcquire || return 1
    st=$(mktemp "${ATR_TMP}/hop-add.XXXXXX") || { lockRelease; return 1; }
    if stateExists; then cp "${ATR_STATE}" "${st}"; else printf '{"protocols":{}}\n' >"${st}"; fi
    jq --arg id "${id}" --arg range "${range}" --argjson p "${port}" '.protocols[$id] += {hop:$range,port:$p}' "${st}" >"${st}.new" && mv "${st}.new" "${st}" && _hopSync "${st}"; rc=$?
    rm -f "${st}" "${st}.new"; lockRelease
    return "${rc}"
}

reconcileHopRules() {
    lockAcquire || return 1
    local st=$1 rc=0 any
    _hopSync "${st}" || rc=1
    if ((rc==0)); then
        any=$(jq '[.protocols[]?|select((.hop // "")!="")]|length' "${st}") || rc=1
        if ((rc==0 && any>0)); then
            _writeUnitFile "${HOP_UNIT}" <<EOF
[Unit]
Description=Re-apply UDP port-hopping rules (${ATR_PROJECT_NAME})
After=network-online.target firewalld.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ATR_SCRIPT_PATH} apply-hop

[Install]
WantedBy=multi-user.target
EOF
            [[ $? == 0 ]] && serviceEnable "${HOP_UNIT}" || rc=1
        elif [[ -f "${ATR_SYSTEMD_DIR}/${HOP_UNIT}.service" ]]; then
            serviceDisable "${HOP_UNIT}" && rm -f "${ATR_SYSTEMD_DIR}/${HOP_UNIT}.service" && systemctl daemon-reload >/dev/null 2>&1 || rc=1
        fi
    fi
    lockRelease
    return "${rc}"
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
        else stagedDiscard; return 1; fi
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
        else stagedDiscard; return 1; fi
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
        if [[ "${id}" == hysteria2 ]]; then
            echoContent yellow "4.带宽模式（固定 / BBR 自适应）"
            echoContent yellow "5.obfs 混淆"
            echoContent yellow "6.未认证 HTTP/3 伪装"
            echoContent yellow "7.导出配置实连（保留 DNS / TLS / 跳跃范围）"
            echoContent yellow "8.宿主流量采样与本机阈值告警"
        fi
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
        if applyStaged "重新配置 ${name}"; then postChangeShow "" "${name} 参数已修改"; else stagedDiscard; return 1; fi
        ;;
    2)
        confirm "确认卸载 ${name} ？" n || return 0
        stagedBegin
        stagedEdit --arg id "${id}" 'del(.protocols[$id])' || return 1
        if applyStaged "卸载 ${name}"; then
            echoContent green " ---> ${name} 已卸载"
            regenClients
        else stagedDiscard; return 1; fi
        ;;
    3) portHoppingMenu "${id}" ;;
    4) [[ "${id}" == hysteria2 ]] && manageHY2Option bandwidth ;;
    5) [[ "${id}" == hysteria2 ]] && manageHY2Option obfs ;;
    6) [[ "${id}" == hysteria2 ]] && manageHY2Option masquerade ;;
    7) [[ "${id}" == hysteria2 ]] && selfCheckHY2Endpoint ;;
    8) [[ "${id}" == hysteria2 ]] && monitorMenu ;;
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
    local port ssl=false d
    ensureNginx || return 1
    d=$(S '.domain // ""')
    if [[ -n "${d}" ]] && tlsReusable "${d}"; then
        ssl=true
        echoContent green " ---> 使用域名 ${d} 的证书提供 HTTPS 订阅"
    else
        echoContent yellow " ---> 没有可用的域名证书，将使用 HTTP 明文订阅：订阅令牌和全部节点凭据会明文经过网络（可被中间人读取，也可能被运营商拦截），请注意风险"
        confirm "是否继续使用 HTTP 订阅？" n || return 1
    fi
    stagedBegin
    askPort port subscribe "订阅" tcp "$(randomFreePort "$(stagedUsedPorts | awk '{print $2}' | tr '\n' ' ')")" || return 1
    # 保留已有的对等密钥与远程条目（关闭后再启用不会丢）；旧版的全局 salt 不再使用
    stagedEdit --argjson p "${port}" --argjson s "${ssl}" '.nginx.subscribe = (((.nginx.subscribe // {}) | del(.salt)) + {enabled:true,port:$p,ssl:$s}) | .nginx.subscribe |= (. + {peer_key: (.peer_key // ""), remotes: (.remotes // [])})' || return 1
    [[ -s "${WEB_ROOT}/index.html" ]] || installFakeSite
    if applyStaged "启用订阅服务"; then
        regenClients && showSubscriptionLinks
    else stagedDiscard; return 1; fi
}

subscriptionMenu() {
    requireInstalled || return 1
    if [[ "$(S '.nginx.subscribe.enabled')" != "true" ]]; then
        echoContent yellow "\n订阅服务尚未启用（需要 nginx，用于一条链接导入全部节点）"
        confirm "是否现在启用？" y && enableSubscription
        return
    fi
    local c who
    echoContent skyBlue "\n---------- 订阅管理 ----------"
    echoContent yellow "1.查看订阅链接"
    echoContent yellow "2.更换订阅链接   [指定用户或全部用户，旧链接立即失效]"
    echoContent yellow "3.关闭订阅服务"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        regenClients && showSubscriptionLinks
        ;;
    2)
        pickUserOrAll "请选择要更换订阅链接的用户编号/用户名，输入 a 表示全部用户" || return 1
        who=${PICKED_USER}
        if rotateSubTokens "${who}"; then
            if regenClients; then
                echoContent yellow " ---> 旧订阅链接已失效，请在客户端重新导入下面的新链接:"
                showSubscriptionLinks "${who}"
            else
                echoContent red " ---> 旧订阅链接已失效（提交时已从发布目录清除），但新的订阅文件没能发布，暂时没有可用的订阅链接。请按上面的提示处理后再选「查看订阅链接」重试"
                return 1
            fi
        else
            return 1
        fi
        ;;
    3)
        stagedBegin
        stagedEdit '.nginx.subscribe.enabled=false' || return 1
        if applyStaged "关闭订阅服务"; then echoContent green " ---> 订阅服务已关闭"; else stagedDiscard; fi
        ;;
    esac
}

# 3.合并其他机器的订阅（见 _appendRemoteSubscriptions 的说明）
# 列出远程条目（不显示对等密钥本身）
_remoteList() {
    local n
    n=$(S '(.nginx.subscribe.remotes // []) | length')
    if [[ -z "${n}" || "${n}" == "0" ]]; then
        echoContent yellow " ---> 没有其他机器的订阅"
        return 1
    fi
    S '(.nginx.subscribe.remotes // []) | to_entries[] | "\(.key + 1). \(.value.alias)  \(.value.host):\(.value.port)  \(.value.scheme // "https")  对等密钥:\(if (.value.key // "") == "" then "【缺失，未生效】" else "已设置" end)\(if (.value.cacert // "") != "" then "  CA:" + .value.cacert else "" end)"'
}

# 旧版把远程机器写在 subscribe_remote/remoteSubscribeUrl 里，并要求两台机器共用同一个 salt；该机制已淘汰
_importLegacyRemotes() {
    [[ -s "${SUB_REMOTE_FILE}" ]] || return 0
    local line host port alias scheme n=0 skipped=0
    echoContent yellow "\n 发现旧版远程订阅文件（${SUB_REMOTE_FILE}）：旧机制要求各机器共用 salt，已被淘汰且不再生效。"
    confirm "把其中的条目导入为「待补充对等密钥」的新条目？（导入后旧文件改名为 .migrated）" y || return 0
    stagedBegin
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        host=$(cut -d: -f1 <<<"${line}")
        port=$(cut -d: -f2 <<<"${line}")
        alias=$(cut -d: -f3 <<<"${line}")
        scheme=https
        if [[ "$(cut -d: -f4 <<<"${line}")" == "http" ]]; then # 对等订阅只允许 HTTPS
            skipped=$((skipped + 1))
            continue
        fi
        _remoteFieldsOK "${host}" "${port}" "${alias}" "${scheme}" || continue
        stagedGet --arg a "${alias}" '(.nginx.subscribe.remotes // [])[]|select(.alias==$a)|.alias' | grep -q . && continue
        stagedEdit --arg h "${host}" --argjson p "$((10#${port}))" --arg a "${alias}" --arg s "${scheme}" \
            '.nginx.subscribe.remotes = ((.nginx.subscribe.remotes // []) + [{host:$h,port:$p,alias:$a,scheme:$s,key:"",cacert:""}])' || continue
        n=$((n + 1))
    done <"${SUB_REMOTE_FILE}"
    if ((n > 0)) && applyStaged "导入旧版远程订阅条目"; then
        mv -f "${SUB_REMOTE_FILE}" "${SUB_REMOTE_FILE}.migrated"
        echoContent green " ---> 已导入 ${n} 条，请用「4.修改某台机器的对等密钥」补充对方的对等密钥后才会生效"
        ((skipped > 0)) && echoContent yellow " ---> 另有 ${skipped} 条 HTTP 条目没有导入：对等订阅现在只支持 HTTPS（对等密钥不能明文传输）"
    else
        stagedDiscard
    fi
}

# 本机的对等密钥: 其他机器凭它合并本机订阅
_peerKeyMenu() {
    local c key gf=0
    key=$(S '.nginx.subscribe.peer_key // ""')
    echoContent skyBlue "\n---------- 本机对等密钥（供其他机器合并本机订阅）----------"
    echoContent yellow "# 对等密钥只用于服务器之间合并订阅；泄露它等于泄露本机所有用户的节点，请只告诉你自己的其他机器"
    echoContent yellow "当前状态: $([[ -n "${key}" ]] && echo 已启用 || echo 未启用)\n"
    echoContent yellow "1.查看（未启用则生成）"
    echoContent yellow "2.重置   [旧密钥立即失效]"
    echoContent yellow "3.关闭   [其他机器不能再合并本机订阅]"
    ask c "请选择:" || return 1
    case "${c}" in
    1 | 2)
        if [[ -z "${key}" || "${c}" == "2" ]]; then
            key=$(randHex 32)
            stagedBegin
            stagedEdit --arg k "${key}" '.nginx.subscribe.peer_key=$k' || return 1
            if ! applyStaged "$([[ "${c}" == "2" ]] && echo 重置 || echo 启用)对等密钥"; then
                stagedDiscard
                return 1
            fi
            regenClients || gf=1
        fi
        echoContent green "本机对等密钥: \c"
        printRaw green "${key}"
        echoContent yellow "在对方机器的 菜单 7→3→1 里添加本机时填写：域名或IP:端口:别名，以及这把密钥。"
        if ((gf)); then
            echoContent red " ---> 新密钥已在 nginx 中生效（旧密钥已立即失效），但本机的订阅文件没有全部发布成功，对方暂时可能取不到内容"
            return 1
        fi
        ;;
    3)
        stagedBegin
        stagedEdit '.nginx.subscribe.peer_key=""' || return 1
        if applyStaged "关闭对等密钥"; then
            echoContent green " ---> 已关闭，其他机器不能再合并本机订阅"
            regenClients
        else stagedDiscard; fi
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

otherSubscriptionMenu() {
    requireInstalled || return 1
    if [[ "$(S '.nginx.subscribe.enabled')" != "true" ]]; then
        echoContent yellow "\n 订阅服务尚未启用，请先在 7→2 里启用订阅服务"
        return 1
    fi
    local c line host port alias scheme key ca n cnt
    echoContent skyBlue "\n===================== 合并其他机器的订阅 ====================="
    echoContent yellow "# 对方机器要先在 菜单 7→3→5 里开启「对等密钥」；本机凭这把密钥取回同名用户在对方机器上的节点"
    echoContent yellow "# 两台机器的用户名需一致；证书会被严格校验（私有 CA/自签证书请提供证书文件）\n"
    _importLegacyRemotes
    echoContent yellow "1.添加其他机器"
    echoContent yellow "2.移除"
    echoContent yellow "3.查看"
    echoContent yellow "4.修改某台机器的对等密钥"
    echoContent yellow "5.本机的对等密钥（供其他机器合并本机订阅）"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        echoContent skyBlue "录入示例：www.example.com:443:vps1  (域名或IPv4:端口:机器别名)"
        ask line "请输入域名:端口:机器别名:" || return 1
        host=$(cut -d: -f1 <<<"${line}")
        port=$(cut -d: -f2 <<<"${line}")
        alias=$(cut -d: -f3 <<<"${line}")
        scheme=https
        if ! _remoteFieldsOK "${host}" "${port}" "${alias}" "${scheme}"; then
            echoContent red " ---> 格式不合法（域名或IPv4:端口:别名，别名只能含字母数字 . _ @ -）"
            return 1
        fi
        if S --arg a "${alias}" '(.nginx.subscribe.remotes // [])[]|select(.alias==$a)|.alias' | grep -q .; then
            echoContent red " ---> 别名已存在: ${alias}"
            return 1
        fi
        ask key "请输入对方机器的对等密钥:" || return 1
        if [[ ! "${key}" =~ ^[A-Za-z0-9]{16,64}$ ]]; then
            echoContent red " ---> 对等密钥格式不合法（16-64 位字母数字）"
            return 1
        fi
        ca=""
        if [[ "${scheme}" == "https" ]]; then
            ask ca "私有 CA / 自签证书文件的绝对路径（公共 CA 签发的证书直接回车）:" || return 1
            if [[ -n "${ca}" ]] && { [[ "${ca}" != /* ]] || ! openssl x509 -noout -in "${ca}" >/dev/null 2>&1; }; then
                echoContent red " ---> 需要证书文件的绝对路径，且必须是有效的 PEM 证书"
                return 1
            fi
        fi
        stagedBegin
        stagedEdit --arg h "${host}" --argjson p "$((10#${port}))" --arg a "${alias}" --arg s "${scheme}" --arg k "${key}" --arg c "${ca}" \
            '.nginx.subscribe.remotes = ((.nginx.subscribe.remotes // []) + [{host:$h,port:$p,alias:$a,scheme:$s,key:$k,cacert:$c}])' || return 1
        if applyStaged "添加远程订阅(${alias})"; then
            regenClients || return 1
            echoContent green " ---> 已添加并重新生成订阅"
        else
            stagedDiscard
            return 1
        fi
        ;;
    2)
        _remoteList || return 0
        ask n "请选择要删除的编号[仅支持单个删除]:" || return 1
        cnt=$(S '(.nginx.subscribe.remotes // [])|length')
        if ! isInt "${n}" || ((10#${n} < 1 || 10#${n} > cnt)); then
            echoContent red " ---> 选择错误"
            return 1
        fi
        stagedBegin
        stagedEdit --argjson i "$((10#${n} - 1))" 'del(.nginx.subscribe.remotes[$i])' || return 1
        if applyStaged "移除远程订阅"; then
            regenClients || return 1
            echoContent green " ---> 已删除并重新生成订阅"
        else
            stagedDiscard
            return 1
        fi
        ;;
    3) _remoteList ;;
    4)
        _remoteList || return 0
        ask n "请选择要修改对等密钥的编号:" || return 1
        cnt=$(S '(.nginx.subscribe.remotes // [])|length')
        if ! isInt "${n}" || ((10#${n} < 1 || 10#${n} > cnt)); then
            echoContent red " ---> 选择错误"
            return 1
        fi
        ask key "请输入新的对等密钥:" || return 1
        if [[ ! "${key}" =~ ^[A-Za-z0-9]{16,64}$ ]]; then
            echoContent red " ---> 对等密钥格式不合法（16-64 位字母数字）"
            return 1
        fi
        stagedBegin
        stagedEdit --argjson i "$((10#${n} - 1))" --arg k "${key}" '.nginx.subscribe.remotes[$i].key=$k' || return 1
        if applyStaged "修改远程订阅的对等密钥"; then
            regenClients || return 1
            echoContent green " ---> 已更新并重新生成订阅"
        else
            stagedDiscard
            return 1
        fi
        ;;
    5) _peerKeyMenu ;;
    *) echoContent red " ---> 选择错误" ;;
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

# 解析 Socks5「来源 IP 白名单」，成功时在 stdout 输出 JSON 数组（至少一项）；没有任何有效的 IP/CIDR 时失败。
# 绝不返回空数组: 空数组交给 sing-box 的 source_ip_cidr 会被当作"不限制来源"，等于对所有来源放行。
# （parseIPList 没有有效项时返回 1，但放进 `a | b | c` 管道后会被最后一个命令的成功退出码掩盖，所以单独处理）
parseSourceIPs() { # parseSourceIPs <输入>
    local out ips
    out=$(parseIPList "${1:-}") || true
    ips=$(printf '%s\n' "${out}" | sed -n 's/^ip://p')
    if [[ -z "${ips}" ]]; then
        echoContent red " ---> 来源 IP 不能为空：没有任何有效的 IP/CIDR（来源白名单只支持 IP/CIDR，不支持 geoip）" >&2
        return 1
    fi
    if printf '%s\n' "${out}" | grep -q '^geoip:'; then
        echoContent yellow " ---> 来源白名单不支持 geoip 条目，已忽略" >&2
    fi
    printf '%s\n' "${ips}" | jq -R . | jq -sc .
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
        arr=$(parseSourceIPs "${ips}") || {
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
        arr2=$(parseSourceIPs "${ips}") || return 1 # 输入无效时保留原配置，绝不变成"不限制来源"
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
# 出口访问模式（决定客户端能不能经节点访问本机和内网）。选择结果放在 EGRESS_PICK，不改状态；输入结束返回 1
EGRESS_PICK=""
pickEgressMode() { # pickEgressMode [当前值] [回车默认: 1|2]
    local cur=${1:-} def=${2:-} c
    [[ -z "${def}" ]] && { [[ "${cur}" == "full" ]] && def=2 || def=1; }
    EGRESS_PICK=""
    echoContent skyBlue "\n---------------- 出口访问模式 ----------------"
    echoContent yellow "决定通过节点连进来的客户端，能不能访问这台服务器本机和内网里的服务："
    echoContent yellow "1.公网出口【推荐】  客户端只能访问公网。禁止：本机回环(127.0.0.0/8、::1)、内网/私网、链路本地(含云厂商元数据"
    echoContent yellow "                   169.254.169.254)、本机自己所有网卡的地址(含公网 IP)；域名解析到这些地址时同样会被拦截（已用 DNS rebinding 实测，详见 README）"
    echoContent yellow "2.允许内网访问       不做任何限制。仅当你信任所有节点用户、并且确实需要经节点访问本机/内网服务时选择"
    echoContent yellow "之后可以在 11.分流工具 → 6.出口访问模式 里随时切换。"
    ask c "请选择[回车默认 ${def}]:" || return 1
    case "${c:-${def}}" in
    1) EGRESS_PICK=public ;;
    2) EGRESS_PICK=full ;;
    *)
        echoContent red " ---> 选择错误"
        return 1
        ;;
    esac
}

egressModeLabel() { # egressModeLabel <mode>
    case "${1:-}" in
    public) echo "公网出口（禁止访问本机与内网）" ;;
    full) echo "允许内网访问（不限制）" ;;
    *) echo "未选择（当前等同于允许内网访问）" ;;
    esac
}

# 11.分流工具 → 6.出口访问模式
egressMenu() {
    requireInstalled || return 1
    local cur c det pub extra v out ips arr at when=""
    cur=$(S '.egress.mode // ""')
    det=$(S '.egress.public_detect != false') # true = 开启（没设置过也算开启）
    echoContent skyBlue "\n功能 1/1 : 出口访问模式"
    echoContent yellow "当前: $(egressModeLabel "${cur}")"
    pub=$(S '(.egress.public_ips // []) | join(", ")')
    extra=$(S '(.egress.extra_ips // []) | join(", ")')
    at=$(S '.egress.public_ips_at // 0')
    if [[ "${det}" == "false" ]]; then
        echoContent yellow "本机公网地址自动探测: 已关闭"
    else
        [[ "${at}" =~ ^[0-9]+$ ]] && ((at > 0)) && when="，$(date -d "@${at}" '+%F %T' 2>/dev/null)"
        echoContent yellow "本机公网地址（自动探测${when}）: ${pub:-（无）}"
    fi
    echoContent yellow "手动补充的本机地址: ${extra:-（无）}"
    [[ "${cur}" == "public" ]] || echoContent yellow "（本机地址只在「公网出口」模式下起作用）"
    echoContent yellow "1.切换出口访问模式"
    echoContent yellow "2.重新探测本机公网地址"
    echoContent yellow "3.手动补充本机地址（NAT、CDN/反代后面、出站经代理/隧道等探测不准的场景）"
    echoContent yellow "4.$([[ "${det}" == "false" ]] && echo 开启 || echo 关闭)本机公网地址自动探测"
    ask c "请选择:" || return 1
    case "${c}" in
    1)
        pickEgressMode "${cur}" || return 1
        if [[ "${EGRESS_PICK}" == "${cur}" ]]; then
            echoContent green " ---> 没有变化"
            return 0
        fi
        stagedBegin
        stagedEdit --arg m "${EGRESS_PICK}" '.egress.mode=$m' || return 1
        stagedRefreshEgressPublicIPs
        if applyStaged "出口访问模式: $(egressModeLabel "${EGRESS_PICK}")"; then
            echoContent green " ---> 已切换为: $(egressModeLabel "${EGRESS_PICK}")（新连接立即生效）"
        else
            stagedDiscard
            return 1
        fi
        ;;
    2)
        [[ "${det}" != "false" ]] || {
            echoContent yellow " ---> 自动探测已关闭（选 4 开启）"
            return 0
        }
        if ! ips=$(egressDetectPublicIPs); then
            egressDetectFailedHint
            return 1
        fi
        stagedBegin
        stagedEdit --argjson ips "${ips}" --argjson t "$(date +%s)" '.egress.public_ips=$ips | .egress.public_ips_at=$t' || return 1
        if applyStaged "刷新本机公网地址"; then
            echoContent green " ---> 本机公网地址: $(jq -r 'join(", ")' <<<"${ips}")"
            echoContent yellow "      ${EGRESS_CDN_NOTE}"
        else
            stagedDiscard
            return 1
        fi
        ;;
    3)
        ask v "请输入本机地址（IP 或 CIDR，多个用英文逗号分隔；直接回车清空）:" || return 1
        if [[ -z "$(trim "${v}")" ]]; then
            arr='[]'
        else
            out=$(parseIPList "${v}") || true
            ips=$(printf '%s\n' "${out}" | sed -n 's/^ip://p')
            [[ -n "${ips}" ]] || {
                echoContent red " ---> 没有有效的 IP/CIDR（这里不支持 geoip），没有修改"
                return 1
            }
            arr=$(printf '%s\n' "${ips}" | jq -R . | jq -sc 'unique')
        fi
        stagedBegin
        stagedEdit --argjson ips "${arr}" '.egress.extra_ips=$ips' || return 1
        if applyStaged "手动补充本机地址"; then
            echoContent green " ---> 手动补充的本机地址: $(jq -r 'if length == 0 then "（无）" else join(", ") end' <<<"${arr}")"
        else
            stagedDiscard
            return 1
        fi
        ;;
    4)
        stagedBegin
        if [[ "${det}" == "false" ]]; then
            stagedEdit '.egress.public_detect=true' || return 1
            stagedRefreshEgressPublicIPs
        else
            stagedEdit '.egress.public_detect=false | .egress.public_ips=[] | del(.egress.public_ips_at)' || return 1
        fi
        if applyStaged "本机公网地址自动探测: $([[ "${det}" == "false" ]] && echo 开启 || echo 关闭)"; then
            echoContent green " ---> 已$([[ "${det}" == "false" ]] && echo 开启 || echo 关闭)自动探测"
        else
            stagedDiscard
            return 1
        fi
        ;;
    *) echoContent red " ---> 选择错误" ;;
    esac
}

# 老安装（升级前没有这个选项）打开菜单时问一次；回车 = 保持现状，所以不选也不会改变任何行为
egressModeNotice() {
    stateExists && [[ -n "$(installedProtocols)" ]] || return 0
    [[ -z "$(S '.egress.mode // ""')" ]] || return 0
    echoContent yellow "\n 出口访问模式: 这台服务器还没有选择过。目前不限制客户端访问本机和内网（等同于「允许内网访问」）。"
    pickEgressMode "" 2 || return 0
    stagedBegin
    stagedEdit --arg m "${EGRESS_PICK}" '.egress.mode=$m' || return 0
    if applyStaged "出口访问模式: $(egressModeLabel "${EGRESS_PICK}")"; then
        echoContent green " ---> 已设置为: $(egressModeLabel "${EGRESS_PICK}")"
    else
        stagedDiscard
    fi
}

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
    echoContent yellow "6.出口访问模式【决定客户端能不能访问本机和内网】"
    echoContent yellow "7.SNI反向代理分流"
    ask c "请选择:" || return 1
    case "${c}" in
    1) warpMenu v4 ;;
    2) warpMenu v6 ;;
    3) ipv6Menu ;;
    4) socks5Menu ;;
    5) dnsRoutingMenu ;;
    6) egressMenu ;;
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
    echoContent yellow "Reality 配置方式: $(realityMode)"
    echoContent yellow "出口访问模式: $(egressModeLabel "$(S '.egress.mode // ""')")"
    echoContent yellow "订阅状态: $(S 'if .nginx.subscribe.enabled == true then "已启用（配置）" else "未启用" end')"
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
    realityStatusExtras
    if protoInstalled hysteria2; then
        echoContent yellow "HY2: $(S 'if (.protocols.hysteria2.obfs.type // "")!="" then "混淆模式；HTTP/3 伪装未生效" else "标准 HTTP/3，页面模式: "+(.protocols.hysteria2.masquerade.mode // "默认404") end')"
    fi
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
    echoContent yellow " ---> 新脚本 SHA256: $(sha256sum "${f}" | awk '{print $1}')"
    echoContent yellow "      语法与名称检查只能发现损坏的文件，不能证明来源可信；请确认下载地址是你自己的仓库。"
    confirm "确认更新？" n || return 0
    printf '%s' "${url}" >"${ATR_HOME}/script_url"
    [[ -f "${ATR_SCRIPT_PATH}" ]] && cp -f "${ATR_SCRIPT_PATH}" "${ATR_SCRIPT_PATH}.prev"
    install -m 700 "${f}" "${ATR_SCRIPT_PATH}.new" && mv -f "${ATR_SCRIPT_PATH}.new" "${ATR_SCRIPT_PATH}"
    echoContent green " ---> 更新完毕，请重新执行 [${ATR_CMD}] 打开脚本（旧版本已备份为 ${ATR_SCRIPT_PATH}.prev）"
    exit 0
}

# ----------------------------- 20. 卸载 ---------------------------------------
uninstallAll() {
    local fwCleanupRC=0
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
        fwApplyList close < <(desiredFirewallPorts "${ATR_STATE}") || fwCleanupRC=1
    fi
    if ! hopRulesRemoveAll; then
        echoContent red " ---> 跳跃规则未能回收，已保留安装目录与规则恢复记录；排除防火墙故障后重试卸载。"
        return 1
    fi
    systemctl disable --now atr-monitor.timer >/dev/null 2>&1 || true
    rm -f "${ATR_SYSTEMD_DIR}/atr-monitor.timer" "${ATR_SYSTEMD_DIR}/atr-monitor.service"
    local u
    for u in "${SB_UNIT}" "${XRAY_UNIT}" "${NGX_UNIT}" "${HOP_UNIT}" "${TLS_RECOVERY_UNIT}"; do
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
    removeNginxAccount
    rm -f "${ATR_BIN_DIR}/${ATR_CMD}"
    rm -rf "${ATR_HOME}"
    if ((fwCleanupRC)); then
        echoContent yellow " ---> 安装内容已卸载，但部分防火墙规则未能自动回收，请按上方提示手动清理"
    else
        echoContent green " ---> 卸载完成"
    fi
    exit "${fwCleanupRC}"
}

# =============================================================================
#  17  主菜单 / 命令行入口 / main
# =============================================================================

usage() {
    echo "诊断: site-check URL；selfcheck --protocol ID --client sing-box|mihomo|xray [--endpoint]；client-test --node FILE --client CORE --binary PATH [--external]"
    cat <<EOF
${ATR_PROJECT_NAME} ${ATR_VERSION} —— sing-box / Xray 管理脚本 (AnyTLS+Reality)

用法: ${ATR_CMD} [命令]

  (无命令)                         打开交互式管理菜单
  install-anytls-reality [选项]    非交互一键安装 AnyTLS+Reality
        --port N        监听端口(默认 443，被占用则随机)
        --sni host[:p]  Reality 目标域名(省略沿用已有配置，新配置默认 www.microsoft.com)
        --user name     首个用户名(默认随机)
        --reality-mode shared|independent  共享或按协议独立配置（省略沿用当前方式，新安装默认共享）
        --egress MODE   出口访问模式: public 公网出口(默认，禁止客户端访问本机与内网) | full 允许内网访问
  status                           查看服务与端口状态
  show [用户] [1]                  查看账号(第二个参数 1 同时显示二维码)
  sub [用户]                       查看订阅链接
  selfcheck                        按节点所属核心做真实回环握手测试
  reality-capabilities [选项]      检测 REALITY 客户端 / 服务端 / 实际协商（--help 查看）
  reality-mode shared|independent [--from 协议ID]  切换 Reality 参数方式
  sni <host[:port]> [--protocol 协议ID] [--force]      修改 Reality 目标域名(SNI)
  passwd <用户> [新密码] [--keep-sub]  重置密码(不给则随机)；订阅已启用时默认同时更换订阅链接，--keep-sub 保留旧链接
  adduser <用户> [uuid] [密码]     添加用户
        (密码参数写成 - 表示从标准输入读取，避免密码出现在 ps / shell 历史里；passwd 同理)
  deluser <用户>                   删除用户(至少保留一个)
  recover [--abandon]              上次操作没有恢复完成时: 重试恢复；--abandon 放弃恢复(备份目录保留)
  restart                          重启全部服务
  log [sing-box|xray|nginx|acme]   查看日志(Ctrl+C 返回)
  renew-tls | update-geo | reload-core | apply-hop   (定时任务/钩子使用)
  uninstall                        卸载
  version | help
EOF
}

# atr recover: 重试未完成事务的恢复；--abandon 放弃恢复（见 abandonTransaction）
cliRecover() { # cliRecover [--abandon]
    case "${1:-}" in
    "")
        if [[ ! -e "${TXN_MARK}" && ! -L "${TXN_MARK}" && ! -e "${TLS_TXN_MARK}" && ! -L "${TLS_TXN_MARK}" ]]; then
            echoContent green " ---> 没有未完成的事务"
        else
            recoverIfNeeded || return 1
        fi
        reconcileSubscription strict
        ;;
    --abandon) abandonTransaction ;;
    *)
        echoContent red " ---> 用法: ${ATR_CMD} recover [--abandon]"
        return 1
        ;;
    esac
}

# ----------------------------- 命令行子命令 ----------------------------------
cliRealityMode() { # reality-mode shared|independent [--from protocol]
    local mode=${1:-} anchor=""
    [[ $# -gt 0 ]] && shift
    if [[ $# -gt 0 ]]; then
        [[ $# == 2 && "$1" == --from ]] || { echoContent red " ---> 用法: ${ATR_CMD} reality-mode shared|independent [--from 协议ID]"; return 1; }
        anchor=$2
    fi
    [[ "${mode}" == shared || "${mode}" == independent ]] || { echoContent red " ---> 配置方式只能是 shared 或 independent"; return 1; }
    requireInstalled || return 1
    [[ -n "$(installedRealityProtocols)" ]] || return 1
    if [[ -n "${anchor}" ]]; then
        installedRealityProtocols | grep -Fxq "${anchor}" || { echoContent red " ---> --from 必须是已安装的 Reality 协议"; return 1; }
    fi
    stagedBegin
    stagedRealityMode "${mode}" "${anchor}" || return 1
    if applyStaged "Reality ${mode}"; then
        postChangeShow "" "Reality 已切换为 ${mode}；切回共享时请同步客户端参数" || return 1
        selfCheckAll
    else stagedDiscard; return 1; fi
}



# 命令行参数会出现在 ps 与 shell 历史里。密码参数写成 "-" 表示改从标准输入读取一行
_secretArg() { # _secretArg <值>
    local s
    if [[ "${1:-}" == "-" ]]; then
        IFS= read -r s || s=""
        printf '%s' "${s}"
    else
        printf '%s' "${1:-}"
    fi
}

cliAddUser() { # cliAddUser <name> [uuid] [password]
    local name=${1:-} uuid=${2:-} pass=${3:-}
    requireInstalled || return 1
    pass=$(_secretArg "${pass}")
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
        local gr=0
        regenClients || gr=1
        echoContent green " ---> 已删除用户 ${1}"
        return "${gr}"
    else
        stagedDiscard
        return 1
    fi
}

cliPasswd() { # cliPasswd <用户> [新密码] [--keep-sub]
    local args=() a rotate=""
    for a in "$@"; do
        if [[ "${a}" == "--keep-sub" ]]; then rotate=0; else args+=("${a}"); fi
    done
    args[1]=$(_secretArg "${args[1]:-}")
    userResetFlow "${args[0]:-}" "${args[1]:-}" password "${rotate}"
}

# 旧版安装（nginx 仍以发行版默认账号运行、订阅文件对本机所有用户可读）升级到专用账号模型
securityUpgradeNotice() {
    stateExists && stateNeedsNginx "${ATR_STATE}" || return 0
    nginxModelCurrent && return 0
    echoContent yellow "\n 安全升级: 检测到旧版 nginx 权限模型（订阅文件对本机所有用户可读，nginx 以发行版默认账号运行）。"
    echoContent yellow "           升级会创建专用账号 ${NGX_USER}、收紧订阅目录权限，并重启 nginx（sing-box / Xray 不受影响）。"
    echoContent yellow "           现在不升级也可以；但之后任何一次发布订阅（含 ${ATR_CMD} sub / ${ATR_CMD} restart）都会先自动完成升级，不会再以公开可读的权限写出订阅文件。"
    confirm "是否现在升级？" y || return 0
    stagedBegin
    if applyStaged "安全升级: nginx 专用账号与订阅权限"; then
        regenClients
    else
        stagedDiscard
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
    client-test) shift; clientTestCLI "$@"; return $? ;;
    site-check) shift; atrTools site-check "$@"; return $? ;;
    monitor-sample) stateExists || return 1; [[ "$(S '.monitor.enabled // false')" == true ]] || return 0; monitorSample; return $? ;;
    reality-capabilities)
        shift
        realityCapabilities "$@"
        return $?
        ;;
    recover-tls)
        # 开机依赖单元：只恢复证书，不启动服务、不迁移订阅，避免服务依赖递归。
        checkRoot
        recoverTLSIfNeeded
        return $?
        ;;
    esac
    # 先校验命令是否合法: 输错命令不应该产生任何副作用（装 atr、建目录、装依赖）
    case "${cmd}" in
    menu | install-anytls-reality | reload-core | restart | renew-tls | update-geo | apply-hop | status | show | sub | selfcheck | sni | reality-mode | passwd | adduser | deluser | log | uninstall | recover) ;;
    *)
        usage
        exit 1
        ;;
    esac
    checkRoot
    checkSystem
    checkCPU
    # 新建的目录只有 root 能进入；需要 nginx 时再由 applyHomePerms 对 nginx 专用组开放"仅穿越"（710）
    if [[ ! -d "${ATR_HOME}" ]]; then
        mkdir -p "${ATR_HOME}"
        chmod 700 "${ATR_HOME}"
    fi
    ensureJq || exit 1
    # 未完成的事务恢复失败时只放行只读命令（status / show / log），其余一律拒绝；recover 自己处理恢复
    if [[ "${cmd}" != recover ]]; then
        local degraded=0
        if ! recoverIfNeeded; then
            case "${cmd}" in
            status | show | log)
                degraded=1
                echoContent yellow " ---> 存在尚未恢复完成的事务，下面只显示当前状态，任何修改都会被拒绝。排除问题后执行 ${ATR_CMD} recover 重试，或 ${ATR_CMD} recover --abandon 放弃这次恢复"
                ;;
            *)
                echoContent red " ---> 存在尚未恢复完成的事务，已停止。只读命令 status / show / log 仍可使用；排除问题后执行 ${ATR_CMD} recover 重试，或 ${ATR_CMD} recover --abandon 放弃这次恢复"
                return 1
                ;;
            esac
        fi
        if ((!degraded)) && ! reconcileSubscription "$([[ "${cmd}" == apply-hop ]] && echo no-republish)"; then
            case "${cmd}" in
            status | show | log) echoContent yellow " ---> 订阅目录对账没有完成（见上面的提示），下面只显示当前状态" ;;
            *) return 1 ;;
            esac
        fi
    fi
    aliasInstall
    if [[ ! -x "${ATR_SCRIPT_PATH}" ]]; then
        echoContent yellow "\n 提示: 脚本没有保存到本机文件(可能是通过管道 curl | bash 运行的)，${ATR_CMD} 命令与证书自动续签后的重载钩子将不可用。"
        echoContent yellow "       请先下载保存为文件再运行:  wget -O anytls-reality.sh ${ATR_SCRIPT_URL_DEFAULT:-<脚本地址>} && bash anytls-reality.sh"
    fi
    shift || true
    case "${cmd}" in
    menu)
        warnV2rayAgentConflict
        securityUpgradeNotice
        egressModeNotice
        egressPublicStaleNotice
        menuLoop
        ;;
    install-anytls-reality) cliInstallAnyTLSReality "$@" ;;
    reload-core | restart) reloadAll ;;
    renew-tls) renewTLSNow ;;
    update-geo) updateGeoAll ;;
    apply-hop) reconcileHopRules "${ATR_STATE}" ;;
    status)
        showStatusCLI
        egressPublicStaleNotice
        ;;
    show) showAccounts "${1:-}" "${2:-0}" ;;
    sub) showSubscriptionLinks "${1:-}" ;;
    selfcheck) selfCheckCLI "$@" ;;
    sni) cliSetSNI "$@" ;;
    reality-mode) cliRealityMode "$@" ;;
    passwd) cliPasswd "$@" ;;
    adduser) cliAddUser "${1:-}" "${2:-}" "${3:-}" ;;
    deluser) cliDelUser "${1:-}" ;;
    log) viewLog "${1:-sing-box}" ;;
    uninstall) uninstallAll ;;
    recover) cliRecover "${1:-}" ;;
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
