# AnyTLS-Reality v1.4.0 测试报告

日期：2026-10-29。基线 v1.3.2。脚本 SHA256：`c1f25c712b1c18ab4a1a3a2a6d2bef15833cdcce1636294b8d607bbe54d01b68`。

## 结果

VPS 上 386 个具名断言通过，其中 278 个是已有回归、108 个覆盖本次菜单/导出/网站/二维码改动。Windows 外部主机另有 4 项检查通过：两个真实导出配置完成公网认证转发，两个错误凭据被拒绝。断言通过包含预期负向结果，不表示所有跨核心组合都兼容。

静态检查：Bash 语法、ShellCheck warning 级、全部 Python AST、三段嵌入 Python 与 tools 源文件一致。发布补丁另做基线应用与字节比对；所有文本 UTF-8 无 BOM、LF，ZIP 内容与 SHA256SUMS 核对。

## 环境与隔离

原授权审计 VPS：Debian 13.7 amd64、Linux 6.12.113、systemd 257、Nginx 1.26、OpenSSL 3.5.7、Python 3.13.5。真实核心：sing-box 1.14.4、Xray 26.10.21、mihomo 1.19.33、Hysteria 2.13.0；真实 firewalld 2.3.1 在私有命名空间运行。二维码由 qrencode 生成、zbarimg 解码检查。

测试目录 `/root/anytls-audit-v140`。80/443 与防火墙场景使用独立网络/挂载命名空间；主机正式安装目录保持不存在。事务夹具替换 systemctl、防火墙与建账号接口，但启动真实核心和 Nginx，完整网站/二维码事务实际使用 www-data worker，未把生产服务安装到系统。低层 file/string 网站模式使用 root 测试实例；公开目录权限另有 runuser 守卫。

## 汇总

| 测试组 | 断言 | 结果 |
|---|---:|---|
| guards140-results.json | 16 | 全部通过 |
| time-monitor-results.json | 12 | 全部通过 |
| v140-results.json | 58 | 全部通过 |
| fault-results.json | 17 | 全部通过 |
| native140-results.json | 13 | 全部通过 |
| transaction-results.json | 8 | 全部通过 |
| integration-results.json | 35 | 全部通过 |
| web-modes-results.json | 12 | 全部通过 |
| v132-results.json | 83 | 全部通过 |
| hy2-results.json | 80 | 全部通过 |
| workflow-results.json | 12 | 全部通过 |
| web-transaction-results.json | 9 | 全部通过 |
| real-firewalld-results.json | 15 | 全部通过 |
| v129-regression.json | 16 | 全部通过 |
| Windows 公网导出配置与错误凭据 | 4 | 全部通过，单独记录 |

## 本版重点

### 安装与端口

sing-box 12 项和 Xray 7 项、顺序、直接入口、多选、提前兼容提示、运行界面去除来源说明通过。新 Reality 随机 TCP、HY2 UDP443、交互/非交互重配旧端口保留通过。新 Xray WS/VMess-WS/Trojan 单选只创建该协议、原生配置检查通过；旧 Vision 前置结构及其客户端端口保留。显式共享模式参数通过。

### v2rayN 自定义配置与选择导出

19 种协议/服务端核心组合逐节点生成客户端文件，Xray 7 种、sing-box 可用组合通过相应核心原生配置检查；Naive 检查专用 JSON 结构和标准 proxy URL，未在本轮做 Naive GUI/转发测试。默认输出不再打印所有聚合配置。

新导出器的 7 种 Xray 客户端和 AnyTLS+Reality sing-box 客户端完成真实认证、取得受控 HTTP 响应；独立 Xray TLS WS/VMess/Trojan 均实际传输。测试显式给本地测试证书建立信任；未把关闭验证当成验收。Xray 对测试网段仅设置目标/端口范围的夹具放行，不修改正式状态。

选定 sing-box 单节点/双节点与 mihomo 片段数量正确；导出阶段拿锁，并拒绝用户选择期间已改变的状态。辅助程序失败不会生成空 JSON 再报告成功。JSON 使用公网地址、Core 对应格式和 127.0.0.1:10818，不带 VPS 私有证书文件路径。

### 本地二维码与短链

PNG 由本机 qrencode 离线生成，数据通过 stdin，zbarimg 解码与原 URI 一致。本地图片 0600，原始目录/元数据私有；图片 ID 独立随机。新增同协议节点不会覆盖另一个节点的本地图片。

原生 Nginx + TLS 请求验证：正确签名取得相同 PNG、缺签名 403、修改期限 403、换资源 ID 403、有效但过期签名 410、目录 404、禁止缓存与 referrer、访问日志不含 ID/签名。请求时检查过期，未以“延迟删除图片”冒充有效期限制。撤销后不重载 Nginx 即 404，重新生成更换资源 ID。

HTTPS 前提守卫验证：默认不信任的自签名证书不提供网址；显式测试 CA 信任后可通过链检查；A/AAAA 混入非本机地址被拒绝；没有 secure_link 模块时不提供在线路径。正向资格测试替换测试域名解析，并通过 SSL_CERT_FILE 显式信任测试 CA；没有往系统安装根证书，也没有申请真实公共证书。

完整事务证明：真实非特权 Nginx worker 能读取受保护 web 副本，无法依靠公开网站根目录访问原始文件。提交配置后旧二维码图片删除、原网址 404；回滚不恢复已删除旧图。PNG/注册表/签名配置权限与独立 URI/随机路径设计经过核对。

### HY2 完整网站、续签与回滚

原生 TCP80 返回 HTTPS 跳转；TCP443 与 UDP443 HTTP/3 返回同一受控内容，私有网关不加入公网防火墙放行列表。file、string、302、404 两种传输均通过；string 含美元符号、引号、反斜线、换行和中文，页面内容保持一致。

现有网关限流/缓存/robots、严格上游证书验证、真实 HTTPS SQLite 展示、不可信上游拒绝回归通过。首次应用在运行验证阶段故意失败后，新建 gateway/web 配置删除，原状态恢复；正常提交、再次变更失败回滚、回滚后继续服务通过。

HTTP-01 钩子记录的 base64 编码、0600 权限、已有自定义/未知格式钩子不覆盖、仅停/恢复本脚本 Nginx、ACME 记录纳入备份并可字节一致还原通过。此项是私有元数据与模拟服务接口测试，未向 CA 实际签发或执行真实定期续签。

### 原有安全与协议回归

双栈真实 iptables/firewalld 跳跃、事务撤销日志/故障恢复、管理员规则保留、自适应/固定带宽、标准多端口 URI、混淆/认证/SNI/不可信证书拒绝通过。Reality 复制/独立目标/持久标签、自定义 AnyTLS padding、时间差、受控 MLKEM 能力探针、报告保护和中断清理通过。时间测试只影响应用上下文，未改变主机时钟。

所测 sing-box 1.14.4 / mihomo 1.19.33 → Xray 26.10.21 的 VLESS+Reality+Vision 组合仍失败，结果正确保留为 failed。附加导出不把“有配置”当成“已兼容”；默认 v2rayN 文件按同核心生成。

## Windows 公网证据

在授权 VPS 临时启动 Xray VLESS+Reality+Vision、sing-box AnyTLS+Reality，随机凭据、公网出口保护、180 秒看门狗，不修改正式服务/防火墙。本机 Windows 使用实际生成的两个自定义客户端 JSON（未替换目标为回环、未关闭证书/公钥校验），分别取得预期 HTTPS trace，确认出口为测试 VPS；错 UUID/密码均不能转发。

二进制和导出文件哈希见 test-results.json。分批测试保留当时的样本源码哈希；最终源码再次生成相同状态的两个客户端 JSON，字节哈希与 Windows 测试样本完全相同。没有把“从 VPS 自己回连”当成外部公网位置证明。

## 清理与限制

临时公网服务和客户端已停止；TCP 只剩原 SSH22，UDP 只剩原 DHCP/chrony，主网络命名空间 IPv4/IPv6 PREROUTING 无新增规则。正式 `/etc/anytls-reality` 不存在；私有审计证据保留，短期公网样本凭据另行清除。

未覆盖：v2rayN GUI 自动导入、所有第三方客户端版本、公共 CA 真实签发/续签、二维码的真实公共域名入口、完整正式 systemd 安装流程、RHEL/SELinux、arm64、IPv6-only/NAT64、长期洪泛与流量、WARP 注册。公网样本只验证两个 IPv4 TCP 协议，不扩展为公网 HY2 UDP 或 IPv6 验收。HTTP 限流不防 QUIC 握手洪泛，已下载二维码不可撤回。

升级保留旧端口/密钥，旧 HY2 不自动开 TCP 网站。回退旧脚本必须恢复兼容配置和相关 ACME 记录；仅替换旧脚本可能误读独立 Xray 监听或失去续签钩子。
