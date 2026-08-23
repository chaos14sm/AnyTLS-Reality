#!/usr/bin/env bash
# -------------------------------------------------------------
# AnyTLS + Reality 管理脚本
#
# 功能：仅做一件事 —— 安装 sing-box（稳定版），并配置 AnyTLS inbound 使用 Reality TLS
# 风格：交互式菜单，UI 参考 mack-a/v2ray-agent
# 快捷命令：atr（等同 v2ray-agent 的 vasma）
#
# 使用方法：
#   wget -P /root -N --no-check-certificate "脚本地址" && chmod 700 /root/anytls-reality.sh && /root/anytls-reality.sh
#   安装完成后，直接输入 [atr] 即可重新打开管理菜单
#
# 客户端要求：sing-box 1.12+ 或 mihomo(Clash Meta) 最新版
# -------------------------------------------------------------

export LANG=en_US.UTF-8

# 全局配置
agentPath="/etc/anytls-reality"
singBoxPath="${agentPath}/sing-box"
singBoxBin="${singBoxPath}/sing-box"
singBoxConfigPath="${singBoxPath}/config.json"
clientPath="${agentPath}/client"
realityKeyFile="${agentPath}/reality_key"
scriptSavePath="${agentPath}/anytls-reality.sh"
atrLink="/usr/bin/atr"
serviceName="anytls-reality"
singBoxGitHub="SagerNet/sing-box"
scriptVersion="v1.0.0"

# 运行时变量
release=""
installType=""
updateReleaseInfoChange=""
cpuVendor=""
serverIP=""
totalProgress=6
installUserName=""
installUserPassword=""
selectedUserName=""
currentInstallStatus=""
currentPort=""
currentSNI=""
currentHandshakePort=""
currentShortID=""
currentPrivateKey=""
currentPublicKey=""
currentUsers=()

echoType='echo -e'
printN=''

# -------------------------------------------------------------
# 输出工具（与 v2ray-agent 保持一致）
# -------------------------------------------------------------
echoContent() {
    case $1 in
    # 红色
    "red")
        ${echoType} "\033[31m${printN}$2 \033[0m"
        ;;
        # 天蓝色
    "skyBlue")
        ${echoType} "\033[1;36m${printN}$2 \033[0m"
        ;;
        # 绿色
    "green")
        ${echoType} "\033[32m${printN}$2 \033[0m"
        ;;
        # 白色
    "white")
        ${echoType} "\033[37m${printN}$2 \033[0m"
        ;;
        # 黄色
    "yellow")
        ${echoType} "\033[33m${printN}$2 \033[0m"
        ;;
    esac
}

# 返回菜单并终止当前流程
abortToMenu() {
    menu
    exit 0
}

# -------------------------------------------------------------
# 检测区
# -------------------------------------------------------------
# 检查root权限
checkRoot() {
    if [[ ! $(id -u) == 0 ]]; then
        echoContent red "\n请使用root用户运行本脚本"
        exit 0
    fi
}

# 检查SELinux状态
checkCentosSELinux() {
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
        echoContent yellow "# 注意事项"
        echoContent yellow "检测到SELinux已开启，请手动关闭后重试"
        exit 0
    fi
}

# 检查系统
checkSystem() {
    if [[ -n $(find /etc -name "redhat-release" 2>/dev/null) ]] || grep </proc/version -q -i "centos"; then
        release="centos"
        installType='yum -y install'
        checkCentosSELinux
    elif grep -qi "ID=debian" /etc/os-release 2>/dev/null || grep </proc/version -q -i "debian"; then
        release="debian"
        installType='apt -y install'
        updateReleaseInfoChange='apt-get --allow-releaseinfo-change update'
    elif grep -qi "ID=ubuntu" /etc/os-release 2>/dev/null || grep </proc/version -q -i "ubuntu"; then
        release="ubuntu"
        installType='apt -y install'
        updateReleaseInfoChange='apt-get --allow-releaseinfo-change update'
    fi

    if [[ -z ${release} ]]; then
        echoContent red "\n本脚本仅支持 Debian/Ubuntu/CentOS 系统，请将下方日志反馈给开发者\n"
        echoContent yellow "$(cat /etc/issue 2>/dev/null)"
        echoContent yellow "$(cat /proc/version 2>/dev/null)"
        exit 0
    fi
}

# 检查CPU架构
checkCPUVendor() {
    if [[ "$(uname)" == "Linux" ]]; then
        case "$(uname -m)" in
        'amd64' | 'x86_64')
            cpuVendor="-linux-amd64"
            ;;
        'armv8' | 'aarch64')
            cpuVendor="-linux-arm64"
            ;;
        'armv7' | 'armv7l')
            cpuVendor="-linux-armv7"
            ;;
        *)
            echoContent red "\n不支持的CPU架构：$(uname -m)"
            exit 0
            ;;
        esac
    fi
}

# 检查并安装依赖
checkDependencies() {
    local dependPackages=(curl wget jq tar openssl)
    local missingPackages=()
    local package

    for package in "${dependPackages[@]}"; do
        if ! command -v "${package}" >/dev/null 2>&1; then
            missingPackages+=("${package}")
        fi
    done

    if [[ ${#missingPackages[@]} -eq 0 ]]; then
        return 0
    fi

    echoContent skyBlue "\n检测到缺少依赖：${missingPackages[*]}，开始安装"
    if [[ -n "${updateReleaseInfoChange}" ]]; then
        ${updateReleaseInfoChange} >/dev/null 2>&1
    fi
    if ! ${installType} "${missingPackages[@]}" >/dev/null 2>&1; then
        if [[ "${release}" == "centos" ]]; then
            ${installType} epel-release >/dev/null 2>&1
        fi
        if ! ${installType} "${missingPackages[@]}" >/dev/null 2>&1; then
            echoContent red " ---> 依赖安装失败，请手动安装后重试：${missingPackages[*]}"
            exit 1
        fi
    fi
    echoContent green " ---> 依赖安装成功"
}

# 创建目录
mkdirTools() {
    mkdir -p "${agentPath}" "${singBoxPath}" "${clientPath}"
}

# 检查端口占用（排除本脚本管理的sing-box）
checkPortUsed() {
    local port=$1
    local listenResult

    if command -v ss >/dev/null 2>&1; then
        listenResult=$(ss -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | grep -v "sing-box")
    elif command -v netstat >/dev/null 2>&1; then
        listenResult=$(netstat -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | grep -v "sing-box")
    else
        return 1
    fi
    [[ -n "${listenResult}" ]]
}

# 获取服务器公网IP
getServerIP() {
    if [[ -n "${serverIP}" ]]; then
        return 0
    fi
    serverIP=$(curl -s4 -m 6 https://api.ipify.org 2>/dev/null)
    if [[ -z "${serverIP}" ]]; then
        serverIP=$(curl -s4 -m 6 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')
    fi
    if [[ -z "${serverIP}" ]]; then
        echoContent yellow "\n无法自动获取服务器公网IPv4，请手动输入"
        read -r -p "服务器IP:" serverIPInput || exit 0
        serverIP="${serverIPInput}"
    fi
}

# -------------------------------------------------------------
# sing-box 核心
# -------------------------------------------------------------
# 获取本地sing-box版本
getSingBoxVersion() {
    if [[ -x "${singBoxBin}" ]]; then
        "${singBoxBin}" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.-]*' | head -1
    fi
}

# 获取sing-box最新稳定版本（GitHub releases/latest 不包含beta/rc预发布版本）
getLatestSingBoxVersion() {
    local latestVersion
    latestVersion=$(curl -sL -m 10 "https://api.github.com/repos/${singBoxGitHub}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    if [[ -z "${latestVersion}" ]]; then
        latestVersion=$(curl -sIL -m 10 -o /dev/null -w '%{url_effective}' "https://github.com/${singBoxGitHub}/releases/latest" 2>/dev/null | grep -oE 'tag/[^/]+$' | cut -d'/' -f2 | sed 's/^v//')
    fi
    echo "${latestVersion}"
}

# 下载并安装sing-box
downloadSingBox() {
    local version=$1
    local downloadURL="https://github.com/${singBoxGitHub}/releases/download/v${version}/sing-box-${version}${cpuVendor}.tar.gz"
    local tmpDir binFile
    tmpDir=$(mktemp -d) || return 1

    echoContent skyBlue "\n开始下载 sing-box v${version}"
    echoContent yellow " ${downloadURL}"

    if ! wget --no-check-certificate -q -T 30 -t 2 -O "${tmpDir}/sing-box.tar.gz" "${downloadURL}"; then
        echoContent yellow " ---> wget下载失败，尝试curl下载"
        if ! curl -sL --connect-timeout 30 -m 300 -o "${tmpDir}/sing-box.tar.gz" "${downloadURL}"; then
            rm -rf "${tmpDir}"
            echoContent red " ---> sing-box下载失败，请检查网络后重试"
            return 1
        fi
    fi

    if ! tar -xzf "${tmpDir}/sing-box.tar.gz" -C "${tmpDir}" 2>/dev/null; then
        rm -rf "${tmpDir}"
        echoContent red " ---> sing-box解压失败"
        return 1
    fi

    binFile=$(find "${tmpDir}" -type f -name "sing-box" | head -1)
    if [[ -z "${binFile}" ]]; then
        rm -rf "${tmpDir}"
        echoContent red " ---> 未找到sing-box二进制文件"
        return 1
    fi

    chmod +x "${binFile}"
    mv -f "${binFile}" "${singBoxBin}"
    chmod +x "${singBoxBin}"
    rm -rf "${tmpDir}"
    echoContent green " ---> sing-box v$(getSingBoxVersion) 安装成功"
}

# -------------------------------------------------------------
# 配置读取
# -------------------------------------------------------------
# 读取当前已安装的配置
readCurrentConfig() {
    if [[ -f "${singBoxConfigPath}" ]]; then
        currentInstallStatus="installed"
        currentPort=$(jq -r '.inbounds[0].listen_port // empty' "${singBoxConfigPath}")
        currentSNI=$(jq -r '.inbounds[0].tls.server_name // empty' "${singBoxConfigPath}")
        currentHandshakePort=$(jq -r '.inbounds[0].tls.reality.handshake.server_port // empty' "${singBoxConfigPath}")
        currentShortID=$(jq -r '.inbounds[0].tls.reality.short_id[0] // empty' "${singBoxConfigPath}")
        currentPrivateKey=$(jq -r '.inbounds[0].tls.reality.private_key // empty' "${singBoxConfigPath}")
        if [[ -f "${realityKeyFile}" ]]; then
            currentPublicKey=$(grep -oE 'PublicKey: *[^ ]+' "${realityKeyFile}" | awk '{print $2}')
        fi
        mapfile -t currentUsers < <(jq -r '.inbounds[0].users[] | "\(.name)\t\(.password)"' "${singBoxConfigPath}" 2>/dev/null)
    else
        currentInstallStatus=""
    fi
}

# 检查是否已安装
checkInstalled() {
    if [[ "${currentInstallStatus}" != "installed" ]]; then
        echoContent red "\n ---> 未安装，请先选择 [1.安装 AnyTLS + Reality]"
        abortToMenu
    fi
}

# 显示用户列表
listUsers() {
    local userLine
    for userLine in "${currentUsers[@]}"; do
        echoContent green "   用户名:$(echo "${userLine}" | cut -f1)  密码:$(echo "${userLine}" | cut -f2)"
    done
}

# 选择用户
selectUserIndex() {
    local index=1 userLine userIndexInput userIndex
    echoContent yellow "\n当前用户列表："
    for userLine in "${currentUsers[@]}"; do
        echoContent yellow " ${index}.用户名:$(echo "${userLine}" | cut -f1)"
        index=$((index + 1))
    done
    read -r -p "请选择用户序号:" userIndexInput || exit 0
    if ! [[ "${userIndexInput}" =~ ^[0-9]+$ ]] || ((10#${userIndexInput} < 1)) || ((10#${userIndexInput} > ${#currentUsers[@]})); then
        echoContent red " ---> 序号无效，请重新选择"
        selectUserIndex
        return
    fi
    userIndex=$((10#${userIndexInput}))
    selectedUserName=$(echo "${currentUsers[$((userIndex - 1))]}" | cut -f1)
}

# -------------------------------------------------------------
# 安装交互
# -------------------------------------------------------------
# 生成Reality密钥对（仅设置变量，不写文件）
generateRealityKeypair() {
    local keypairOutput
    keypairOutput=$("${singBoxBin}" generate reality-keypair 2>/dev/null)
    if echo "${keypairOutput}" | jq -e . >/dev/null 2>&1; then
        currentPrivateKey=$(echo "${keypairOutput}" | jq -r '.PrivateKey // .private_key // empty')
        currentPublicKey=$(echo "${keypairOutput}" | jq -r '.PublicKey // .public_key // empty')
    else
        currentPrivateKey=$(echo "${keypairOutput}" | awk '/PrivateKey/{print $NF}' | tr -d ' ",{}')
        currentPublicKey=$(echo "${keypairOutput}" | awk '/PublicKey/{print $NF}' | tr -d ' ",{}')
    fi

    if [[ -z "${currentPrivateKey}" || -z "${currentPublicKey}" ]]; then
        echoContent red " ---> Reality密钥生成失败"
        return 1
    fi
    echoContent green " ---> Reality密钥生成成功"
}

# 保存Reality密钥到文件（供读取public_key使用，需在配置写入成功后调用）
saveRealityKeyFile() {
    echo "PrivateKey: ${currentPrivateKey}" >"${realityKeyFile}"
    echo "PublicKey: ${currentPublicKey}" >>"${realityKeyFile}"
    chmod 600 "${realityKeyFile}"
}

# 检测SNI目标是否支持TLS1.3（仅提示，不阻断安装）
checkSNITLS13() {
    local sni=$1
    local checkResult
    checkResult=$(echo | timeout 8 openssl s_client -connect "${sni}:443" -servername "${sni}" -tls1_3 2>/dev/null | grep -c "TLSv1.3")
    if [[ "${checkResult}" -gt 0 ]]; then
        echoContent green " ---> 目标域名 ${sni} 支持 TLSv1.3"
    else
        echoContent yellow " ---> 警告：无法确认 ${sni} 是否支持 TLSv1.3，建议更换目标域名（不影响继续安装）"
    fi
}

# 输入端口
readRealityPort() {
    local realityPortInput
    while true; do
        echoContent yellow "\n请输入AnyTLS端口 [默认: 443]，仅支持TCP"
        read -r -p "端口:" realityPortInput || exit 0
        realityPortInput=$(echo "${realityPortInput}" | tr -d '[:space:]')
        [[ -z "${realityPortInput}" ]] && realityPortInput=443
        if ! [[ "${realityPortInput}" =~ ^[0-9]+$ ]] || ((10#${realityPortInput} < 1)) || ((10#${realityPortInput} > 65535)); then
            echoContent red " ---> 端口无效，请输入1-65535之间的数字"
            continue
        fi
        if checkPortUsed "${realityPortInput}"; then
            echoContent red " ---> 端口 ${realityPortInput} 已被其他程序占用，请更换端口"
            continue
        fi
        currentPort=$((10#${realityPortInput}))
        break
    done
}

# 输入SNI/Reality目标
readRealitySNI() {
    local sniSelect customSNI
    echoContent skyBlue "\n请选择Reality的SNI目标网站"
    echoContent yellow "要求：国外网站、支持TLSv1.3 + H2、非CDN泛播域名效果更佳\n"
    echoContent yellow "1.www.bing.com【推荐】"
    echoContent yellow "2.www.microsoft.com"
    echoContent yellow "3.www.tesla.com"
    echoContent yellow "4.www.samsung.com"
    echoContent yellow "5.www.lovelive-anime.jp"
    echoContent yellow "6.自定义SNI目标域名"
    read -r -p "请选择:" sniSelect || exit 0
    case ${sniSelect} in
    1) currentSNI="www.bing.com" ;;
    2) currentSNI="www.microsoft.com" ;;
    3) currentSNI="www.tesla.com" ;;
    4) currentSNI="www.samsung.com" ;;
    5) currentSNI="www.lovelive-anime.jp" ;;
    6)
        echoContent yellow "请输入自定义SNI目标域名 [例如: www.example.com]"
        read -r -p "域名:" customSNI || exit 0
        if [[ -z "${customSNI}" ]] || ! [[ "${customSNI}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            echoContent red " ---> 域名格式错误，请重新选择"
            readRealitySNI
            return
        fi
        currentSNI="${customSNI}"
        ;;
    *)
        echoContent red " ---> 请输入正确的数字"
        readRealitySNI
        return
        ;;
    esac
    currentHandshakePort=443
    checkSNITLS13 "${currentSNI}"
}

# 输入用户名
readUserName() {
    local userNameInput
    while true; do
        echoContent yellow "\n请输入用户名 [默认: user]"
        read -r -p "用户名:" userNameInput || exit 0
        [[ -z "${userNameInput}" ]] && userNameInput="user"
        if ! [[ "${userNameInput}" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
            echoContent red " ---> 用户名仅支持字母、数字、下划线、横杠，长度1-32"
            continue
        fi
        if [[ -f "${singBoxConfigPath}" ]] && jq -e --arg n "${userNameInput}" '.inbounds[0].users[] | select(.name==$n)' "${singBoxConfigPath}" >/dev/null 2>&1; then
            echoContent red " ---> 用户 ${userNameInput} 已存在，请重新输入"
            continue
        fi
        break
    done
    installUserName="${userNameInput}"
}

# 输入密码
readUserPassword() {
    local passwordInput
    echoContent yellow "\n请输入 ${installUserName} 的密码 [默认: 随机生成]"
    read -r -p "密码:" passwordInput || exit 0
    if [[ -z "${passwordInput}" ]]; then
        installUserPassword=$(openssl rand -hex 16)
        echoContent green " ---> 已生成随机密码：${installUserPassword}"
    else
        installUserPassword="${passwordInput}"
    fi
}

# -------------------------------------------------------------
# 配置生成与服务
# -------------------------------------------------------------
# 生成sing-box服务端配置
writeSingBoxConfig() {
    jq -n \
        --arg userName "${installUserName}" \
        --arg password "${installUserPassword}" \
        --arg sni "${currentSNI}" \
        --arg privateKey "${currentPrivateKey}" \
        --arg shortID "${currentShortID}" \
        --argjson listenPort "${currentPort}" \
        --argjson handshakePort "${currentHandshakePort}" \
        '{
            log: {level: "info", timestamp: true},
            inbounds: [{
                type: "anytls",
                tag: "anytls-in",
                listen: "::",
                listen_port: $listenPort,
                users: [{name: $userName, password: $password}],
                tls: {
                    enabled: true,
                    server_name: $sni,
                    reality: {
                        enabled: true,
                        handshake: {server: $sni, server_port: $handshakePort},
                        private_key: $privateKey,
                        short_id: [$shortID]
                    }
                }
            }],
            outbounds: [{type: "direct", tag: "direct"}]
        }' >"${singBoxConfigPath}" || return 1
    echoContent green " ---> 配置文件生成成功：${singBoxConfigPath}"
}

# 更新sing-box配置JSON（jq表达式 + 参数）
updateSingBoxJSON() {
    local jqExpr=$1
    shift
    if ! jq "$@" "${jqExpr}" "${singBoxConfigPath}" >"${singBoxConfigPath}.tmp" 2>/dev/null; then
        rm -f "${singBoxConfigPath}.tmp"
        echoContent red " ---> 配置更新失败"
        return 1
    fi
    mv -f "${singBoxConfigPath}.tmp" "${singBoxConfigPath}"
    return 0
}

# 创建systemd服务
createSystemService() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echoContent red " ---> 未检测到systemctl，无法创建系统服务"
        exit 1
    fi
    cat >"/etc/systemd/system/${serviceName}.service" <<EOF
[Unit]
Description=${serviceName} service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
Type=simple
ExecStart=${singBoxBin} run -D ${singBoxPath} -c ${singBoxConfigPath}
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable "${serviceName}" >/dev/null 2>&1
    echoContent green " ---> systemd服务创建成功：${serviceName}"
}

# 防火墙放行/移除端口
handleFirewall() {
    local port=$1 action=$2
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if [[ "${action}" == "add" ]]; then
            ufw allow "${port}/tcp" >/dev/null 2>&1
            echoContent green " ---> ufw已放行端口 ${port}/tcp"
        else
            ufw delete allow "${port}/tcp" >/dev/null 2>&1
            echoContent yellow " ---> ufw已移除端口 ${port}/tcp规则"
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        if [[ "${action}" == "add" ]]; then
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1
            echoContent green " ---> firewalld已放行端口 ${port}/tcp"
        else
            firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1
            echoContent yellow " ---> firewalld已移除端口 ${port}/tcp规则"
        fi
    fi
}

# 校验配置并重启服务
restartService() {
    if ! "${singBoxBin}" check -c "${singBoxConfigPath}" >/dev/null 2>&1; then
        echoContent red " ---> 配置文件校验失败："
        "${singBoxBin}" check -c "${singBoxConfigPath}" 2>&1 | head -5
        return 1
    fi
    systemctl restart "${serviceName}"
    sleep 2
    if [[ "$(systemctl is-active "${serviceName}" 2>/dev/null)" == "active" ]]; then
        echoContent green " ---> ${serviceName}已启动"
        return 0
    fi
    echoContent red " ---> 服务启动失败，最近日志如下："
    journalctl -u "${serviceName}" --no-pager -n 15 2>/dev/null
    return 1
}

# 注册atr快捷命令
registerAtrCommand() {
    local selfPath
    selfPath=$(readlink -f "$0" 2>/dev/null)

    # 仅当脚本以文件方式运行时复制自身，避免管道执行误注册
    if [[ "$0" == *.sh && -n "${selfPath}" && "${selfPath}" != "${scriptSavePath}" && -f "${selfPath}" ]]; then
        cp -f "${selfPath}" "${scriptSavePath}"
    fi

    if [[ ! -f "${scriptSavePath}" ]]; then
        echoContent yellow " ---> 无法注册快捷命令，请以文件方式运行本脚本"
        return 1
    fi
    chmod 700 "${scriptSavePath}"
    if [[ "$(readlink "${atrLink}" 2>/dev/null)" != "${scriptSavePath}" ]]; then
        rm -rf "${atrLink}"
        ln -s "${scriptSavePath}" "${atrLink}"
    fi
    echoContent green " ---> 快捷命令注册成功，可执行[atr]重新打开脚本"
}

# -------------------------------------------------------------
# 客户端配置生成
# -------------------------------------------------------------
# 生成单个用户的客户端配置（sing-box JSON + mihomo YAML）
generateClientConfig() {
    local userName=$1 password=$2 display=${3:-"true"}
    getServerIP

    local singBoxClientFile="${clientPath}/sing-box-${userName}.json"
    local mihomoClientFile="${clientPath}/mihomo-${userName}.yaml"

    jq -n \
        --arg server "${serverIP}" \
        --argjson port "${currentPort}" \
        --arg userName "${userName}" \
        --arg password "${password}" \
        --arg sni "${currentSNI}" \
        --arg publicKey "${currentPublicKey}" \
        --arg shortID "${currentShortID}" \
        '{
            log: {level: "info", timestamp: true},
            inbounds: [{type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080}],
            outbounds: [
                {
                    type: "anytls",
                    tag: "proxy",
                    server: $server,
                    server_port: $port,
                    password: $password,
                    idle_session_check_interval: "30s",
                    idle_session_timeout: "30s",
                    min_idle_session: 5,
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        utls: {enabled: true, fingerprint: "chrome"},
                        reality: {enabled: true, public_key: $publicKey, short_id: $shortID}
                    }
                },
                {type: "direct", tag: "direct"}
            ],
            route: {final: "proxy"}
        }' >"${singBoxClientFile}"

    cat <<EOF >"${mihomoClientFile}"
proxies:
  - name: "${userName}"
    type: anytls
    server: ${serverIP}
    port: ${currentPort}
    password: "${password}"
    udp: true
    sni: ${currentSNI}
    client-fingerprint: chrome
    skip-cert-verify: false
    reality-opts:
      public-key: ${currentPublicKey}
      short-id: "${currentShortID}"
EOF

    echoContent green " ---> 客户端配置已生成：${singBoxClientFile}"
    echoContent green " ---> 客户端配置已生成：${mihomoClientFile}"

    if [[ "${display}" == "true" ]]; then
        echoContent skyBlue "\n============ sing-box客户端配置 [${userName}] ============"
        echoContent white "$(cat "${singBoxClientFile}")"
        echoContent skyBlue "============ mihomo(Clash Meta)客户端配置 [${userName}] ============"
        echoContent white "$(cat "${mihomoClientFile}")"
        echoContent skyBlue "=========================================================="
    fi
}

# 为所有用户重新生成客户端配置
updateClientConfigs() {
    local display=${1:-"true"}
    local userLine
    for userLine in "${currentUsers[@]}"; do
        generateClientConfig "$(echo "${userLine}" | cut -f1)" "$(echo "${userLine}" | cut -f2)" "${display}"
    done
}

# -------------------------------------------------------------
# 功能：安装
# -------------------------------------------------------------
installAnyTLSReality() {
    totalProgress=6

    if [[ "${currentInstallStatus}" == "installed" ]]; then
        echoContent yellow "\n检测到已安装 AnyTLS + Reality，重新安装将重置全部配置（含密钥与用户）"
        read -r -p "是否继续？[y/n]:" reinstallConfirm || exit 0
        if [[ "${reinstallConfirm}" != "y" ]]; then
            abortToMenu
        fi
        systemctl stop "${serviceName}" >/dev/null 2>&1
        rm -rf "${clientPath}"
        mkdir -p "${clientPath}"
    fi

    echoContent skyBlue "\n进度 1/${totalProgress} : 安装sing-box（仅稳定版，已排除beta/rc预发布版本）"
    local latestVersion
    latestVersion=$(getLatestSingBoxVersion)
    if [[ -z "${latestVersion}" ]]; then
        echoContent yellow " ---> 无法自动获取最新稳定版本号"
        read -r -p "请手动输入sing-box稳定版版本号 [例如: 1.13.19]:" latestVersion || exit 0
        if [[ -z "${latestVersion}" ]]; then
            echoContent red " ---> 未输入版本号，安装失败"
            abortToMenu
        fi
    fi
    if [[ "$(getSingBoxVersion)" == "${latestVersion}" ]]; then
        echoContent green " ---> 已安装最新稳定版 sing-box v${latestVersion}，跳过下载"
    else
        if ! downloadSingBox "${latestVersion}"; then
            abortToMenu
        fi
    fi

    echoContent skyBlue "\n进度 2/${totalProgress} : 配置AnyTLS"
    readRealityPort
    readRealitySNI
    if ! generateRealityKeypair; then
        abortToMenu
    fi
    currentShortID=$(openssl rand -hex 8)
    echoContent green " ---> 已生成short_id：${currentShortID}"
    readUserName
    readUserPassword

    echoContent skyBlue "\n进度 3/${totalProgress} : 生成配置文件"
    if ! writeSingBoxConfig; then
        echoContent red " ---> 配置文件生成失败"
        abortToMenu
    fi
    saveRealityKeyFile

    echoContent skyBlue "\n进度 4/${totalProgress} : 配置systemd服务"
    createSystemService

    echoContent skyBlue "\n进度 5/${totalProgress} : 配置防火墙"
    handleFirewall "${currentPort}" "add"

    echoContent skyBlue "\n进度 6/${totalProgress} : 启动服务"
    if ! restartService; then
        abortToMenu
    fi

    registerAtrCommand
    readCurrentConfig

    echoContent green "\n================== AnyTLS + Reality 安装成功 =================="
    echoContent yellow " 端口：${currentPort}"
    echoContent yellow " SNI/Reality目标：${currentSNI}:${currentHandshakePort}"
    echoContent yellow " short_id：${currentShortID}"
    echoContent yellow " PublicKey：${currentPublicKey}"
    echoContent yellow " 管理命令：atr"
    echoContent green "=============================================================="

    generateClientConfig "${installUserName}" "${installUserPassword}" "true"
}

# -------------------------------------------------------------
# 功能：查看当前配置
# -------------------------------------------------------------
showCurrentConfig() {
    checkInstalled
    getServerIP
    echoContent skyBlue "\n================= AnyTLS + Reality 当前配置 ================="
    echoContent yellow " 服务器IP：${serverIP}"
    echoContent yellow " 端口：${currentPort}"
    echoContent yellow " SNI/Reality目标：${currentSNI}:${currentHandshakePort}"
    echoContent yellow " short_id：${currentShortID}"
    echoContent yellow " PublicKey：${currentPublicKey}"
    echoContent yellow " PrivateKey：${currentPrivateKey}"
    echoContent yellow " sing-box版本：$(getSingBoxVersion)"
    echoContent yellow " 服务状态：$(systemctl is-active "${serviceName}" 2>/dev/null)"
    echoContent yellow " 用户列表："
    listUsers
    echoContent skyBlue "============================================================="
    echoContent yellow "\n是否生成/更新并显示客户端配置文件？[y/n]"
    read -r -p "请选择:" clientConfirm || exit 0
    if [[ "${clientConfirm}" == "y" ]]; then
        updateClientConfigs "true"
    fi
}

# -------------------------------------------------------------
# 功能：修改SNI / Reality目标
# -------------------------------------------------------------
changeSNI() {
    checkInstalled
    echoContent skyBlue "\n功能 1/1 : 修改SNI / Reality目标"
    readRealitySNI
    # shellcheck disable=SC2016
    if ! updateSingBoxJSON '.inbounds[0].tls.server_name = $sni | .inbounds[0].tls.reality.handshake.server = $sni' --arg sni "${currentSNI}"; then
        readCurrentConfig
        abortToMenu
    fi
    readCurrentConfig
    if ! restartService; then
        abortToMenu
    fi
    echoContent green " ---> SNI已更新为 ${currentSNI}"
    echoContent yellow " ---> 所有客户端需同步修改 server_name/SNI"
    updateClientConfigs "true"
}

# -------------------------------------------------------------
# 功能：修改端口
# -------------------------------------------------------------
changePort() {
    checkInstalled
    echoContent skyBlue "\n功能 1/1 : 修改端口"
    local oldPort="${currentPort}"
    readRealityPort
    if [[ "${currentPort}" == "${oldPort}" ]]; then
        echoContent yellow " ---> 端口未发生变化"
        return 0
    fi
    # shellcheck disable=SC2016
    if ! updateSingBoxJSON '.inbounds[0].listen_port = $port' --argjson port "${currentPort}"; then
        readCurrentConfig
        abortToMenu
    fi
    handleFirewall "${oldPort}" "remove"
    handleFirewall "${currentPort}" "add"
    readCurrentConfig
    if ! restartService; then
        abortToMenu
    fi
    echoContent green " ---> 端口已由 ${oldPort} 更新为 ${currentPort}"
    updateClientConfigs "true"
}

# -------------------------------------------------------------
# 功能：修改AnyTLS密码
# -------------------------------------------------------------
changePassword() {
    checkInstalled
    echoContent skyBlue "\n功能 1/1 : 修改AnyTLS密码"
    selectUserIndex
    echoContent yellow "\n请输入用户 ${selectedUserName} 的新密码 [默认: 随机生成]"
    read -r -p "密码:" newPasswordInput || exit 0
    if [[ -z "${newPasswordInput}" ]]; then
        newPasswordInput=$(openssl rand -hex 16)
        echoContent green " ---> 已生成随机密码：${newPasswordInput}"
    fi
    # shellcheck disable=SC2016
    if ! updateSingBoxJSON '.inbounds[0].users = (.inbounds[0].users | map(if .name == $name then .password = $password else . end))' --arg name "${selectedUserName}" --arg password "${newPasswordInput}"; then
        abortToMenu
    fi
    readCurrentConfig
    if ! restartService; then
        abortToMenu
    fi
    echoContent green " ---> 用户 ${selectedUserName} 密码修改成功"
    generateClientConfig "${selectedUserName}" "${newPasswordInput}" "true"
}

# -------------------------------------------------------------
# 功能：重新生成Reality密钥
# -------------------------------------------------------------
regenerateRealityKey() {
    checkInstalled
    echoContent skyBlue "\n功能 1/1 : 重新生成Reality密钥"
    echoContent yellow "\n重新生成后所有客户端必须更新public_key才能连接，是否继续？[y/n]"
    read -r -p "请选择:" regenConfirm || exit 0
    if [[ "${regenConfirm}" != "y" ]]; then
        abortToMenu
    fi
    if ! generateRealityKeypair; then
        abortToMenu
    fi
    # shellcheck disable=SC2016
    if ! updateSingBoxJSON '.inbounds[0].tls.reality.private_key = $key' --arg key "${currentPrivateKey}"; then
        readCurrentConfig
        abortToMenu
    fi
    saveRealityKeyFile
    readCurrentConfig
    if ! restartService; then
        abortToMenu
    fi
    echoContent green " ---> 新PublicKey：${currentPublicKey}"
    echoContent yellow " ---> 请将新的public_key同步到所有客户端"
    updateClientConfigs "true"
}

# -------------------------------------------------------------
# 功能：添加用户
# -------------------------------------------------------------
addUser() {
    checkInstalled
    echoContent skyBlue "\n功能 1/1 : 添加用户"
    readUserName
    readUserPassword
    # shellcheck disable=SC2016
    if ! updateSingBoxJSON '.inbounds[0].users += [{name: $name, password: $password}]' --arg name "${installUserName}" --arg password "${installUserPassword}"; then
        abortToMenu
    fi
    readCurrentConfig
    if ! restartService; then
        abortToMenu
    fi
    echoContent green " ---> 用户 ${installUserName} 添加成功"
    generateClientConfig "${installUserName}" "${installUserPassword}" "true"
}

# -------------------------------------------------------------
# 功能：删除用户
# -------------------------------------------------------------
removeUser() {
    checkInstalled
    if [[ ${#currentUsers[@]} -le 1 ]]; then
        echoContent red "\n ---> 至少需要保留一个用户，无法删除"
        return 0
    fi
    echoContent skyBlue "\n功能 1/1 : 删除用户"
    selectUserIndex
    local removeUserName="${selectedUserName}"
    # shellcheck disable=SC2016
    if ! updateSingBoxJSON '.inbounds[0].users |= map(select(.name != $name))' --arg name "${removeUserName}"; then
        abortToMenu
    fi
    rm -f "${clientPath}/sing-box-${removeUserName}.json" "${clientPath}/mihomo-${removeUserName}.yaml"
    readCurrentConfig
    if ! restartService; then
        abortToMenu
    fi
    echoContent green " ---> 用户 ${removeUserName} 删除成功"
}

# -------------------------------------------------------------
# 功能：查看运行状态
# -------------------------------------------------------------
showServiceStatus() {
    checkInstalled
    echoContent skyBlue "\n功能 1/1 : 查看运行状态"
    systemctl status "${serviceName}" --no-pager -l
}

# -------------------------------------------------------------
# 功能：查看实时日志
# -------------------------------------------------------------
showServiceLogs() {
    checkInstalled
    echoContent skyBlue "\n功能 1/1 : 查看实时日志"
    echoContent yellow "\n ---> 实时日志输出中，按Ctrl+C返回主菜单\n"
    trap 'echo; echoContent yellow "\n ---> 已停止日志查看"; return 0' INT
    journalctl -u "${serviceName}" -f -n 50 --no-pager
    trap - INT
}

# -------------------------------------------------------------
# 功能：更新sing-box（仅稳定版）
# -------------------------------------------------------------
updateSingBox() {
    checkInstalled
    echoContent skyBlue "\n功能 1/1 : 更新sing-box（仅稳定版，已排除beta/rc预发布版本）"
    local latestVersion currentVersion
    currentVersion=$(getSingBoxVersion)
    latestVersion=$(getLatestSingBoxVersion)
    if [[ -z "${latestVersion}" ]]; then
        echoContent red " ---> 无法获取最新稳定版本号，请检查网络后重试"
        abortToMenu
    fi
    echoContent yellow " 当前版本：v${currentVersion}"
    echoContent yellow " 最新稳定版：v${latestVersion}"
    if [[ "${currentVersion}" == "${latestVersion}" ]]; then
        echoContent green " ---> 已是最新稳定版本"
        return 0
    fi
    read -r -p "是否更新到 v${latestVersion}？[y/n]:" updateConfirm || exit 0
    if [[ "${updateConfirm}" != "y" ]]; then
        abortToMenu
    fi
    systemctl stop "${serviceName}" >/dev/null 2>&1
    if ! downloadSingBox "${latestVersion}"; then
        restartService >/dev/null 2>&1
        abortToMenu
    fi
    if ! restartService; then
        abortToMenu
    fi
    echoContent green " ---> sing-box已更新至 v$(getSingBoxVersion)"
}

# -------------------------------------------------------------
# 功能：卸载
# -------------------------------------------------------------
uninstall() {
    checkInstalled
    echoContent yellow "\n卸载将停止服务并删除 ${agentPath} 下所有配置、密钥与客户端文件"
    read -r -p "确认卸载？[y/n]:" uninstallConfirm || exit 0
    if [[ "${uninstallConfirm}" != "y" ]]; then
        abortToMenu
    fi
    systemctl stop "${serviceName}" >/dev/null 2>&1
    systemctl disable "${serviceName}" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${serviceName}.service"
    systemctl daemon-reload >/dev/null 2>&1
    handleFirewall "${currentPort}" "remove"
    rm -f "${atrLink}" /usr/sbin/atr
    rm -rf "${agentPath}"
    currentInstallStatus=""
    echoContent green " ---> AnyTLS + Reality卸载完成"
}

# -------------------------------------------------------------
# 菜单
# -------------------------------------------------------------
# 显示安装状态
showInstallStatus() {
    if [[ "${currentInstallStatus}" == "installed" ]]; then
        if [[ "$(systemctl is-active "${serviceName}" 2>/dev/null)" == "active" ]]; then
            echoContent green "\n安装状态：已安装并运行中 [端口:${currentPort}]"
        else
            echoContent yellow "\n安装状态：已安装但未运行 [端口:${currentPort}]"
        fi
    else
        echoContent yellow "\n安装状态：未安装"
    fi
}

# 主菜单
menu() {
    cd "${HOME}" || exit

    # 已安装时确保快捷命令可用
    if [[ "${currentInstallStatus}" == "installed" && -f "${scriptSavePath}" ]]; then
        if [[ "$(readlink "${atrLink}" 2>/dev/null)" != "${scriptSavePath}" ]]; then
            ln -sf "${scriptSavePath}" "${atrLink}"
        fi
    fi

    echoContent red "\n=============================================================="
    echoContent green "描述：AnyTLS + Reality 管理脚本"
    echoContent green "核心：sing-box（仅使用稳定版）"
    echoContent green "脚本版本：${scriptVersion}"
    echoContent green "参考：https://github.com/mack-a/v2ray-agent"
    echoContent green "文档：https://sing-box.sagernet.org\c"
    showInstallStatus
    echoContent red "=============================================================="
    if [[ "${currentInstallStatus}" == "installed" ]]; then
        echoContent yellow "1.重新安装"
    else
        echoContent yellow "1.安装 AnyTLS + Reality"
    fi
    echoContent yellow "2.查看当前配置"
    echoContent skyBlue "-------------------------配置管理-----------------------------"
    echoContent yellow "3.修改 SNI / Reality 目标"
    echoContent yellow "4.修改端口"
    echoContent yellow "5.修改 AnyTLS 密码"
    echoContent yellow "6.重新生成 Reality 密钥"
    echoContent skyBlue "-------------------------用户管理-----------------------------"
    echoContent yellow "7.添加用户"
    echoContent yellow "8.删除用户"
    echoContent skyBlue "-------------------------服务管理-----------------------------"
    echoContent yellow "9.查看运行状态"
    echoContent yellow "10.查看实时日志"
    echoContent skyBlue "-------------------------版本管理-----------------------------"
    echoContent yellow "11.更新 sing-box"
    echoContent skyBlue "-------------------------脚本管理-----------------------------"
    echoContent yellow "12.卸载"
    echoContent red "=============================================================="
    echoContent yellow "0.退出"
    read -r -p "请选择:" selectMenuType || exit 0
    case ${selectMenuType} in
    1)
        installAnyTLSReality
        ;;
    2)
        showCurrentConfig
        ;;
    3)
        changeSNI
        ;;
    4)
        changePort
        ;;
    5)
        changePassword
        ;;
    6)
        regenerateRealityKey
        ;;
    7)
        addUser
        ;;
    8)
        removeUser
        ;;
    9)
        showServiceStatus
        ;;
    10)
        showServiceLogs
        ;;
    11)
        updateSingBox
        ;;
    12)
        uninstall
        ;;
    0)
        exit 0
        ;;
    *)
        echoContent red " ---> 请输入正确的数字"
        ;;
    esac
    menu
}

# -------------------------------------------------------------
# 入口
# -------------------------------------------------------------
initVar() {
    checkRoot
    checkSystem
    checkCPUVendor
    checkDependencies
    mkdirTools
    readCurrentConfig
    menu
}

initVar "$@"
