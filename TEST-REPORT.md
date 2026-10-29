# AnyTLS-Reality v1.3.2 测试报告

测试日期：2026-10-29。基线：v1.3.1；本版脚本 SHA256：`f917d1e44a728a1f995c93c8addc9b0837ab340e5969f26f460634a14b3daed9`。

## 结论与范围

278 个具名回归/功能断言全部通过；另有 2 项从本机 Windows 经真实公网连接 VPS 的同核心认证转发通过。负向测试中的预期拒绝也计为通过断言；这不表示所有客户端组合都兼容。`bash -n`、ShellCheck warning 级检查通过；嵌入式 Python 与 tools 源文件一致，Python 语法检查通过。

按用户要求删除 README 的旧本地版本包说明，今后不再添加。

## 环境

- 经重新核对的原审计 VPS：Debian 13.7 amd64，Linux 6.12.113，systemd 257，Nginx 1.26，OpenSSL 3.5.7，Python 3.13.5；不是先前被要求停用的另一主机。
- sing-box 1.14.4、Xray 26.10.21、mihomo 1.19.33、官方 Hysteria 2.13.0，真实 firewalld 2.3.1。
- VPS 私有目录 `/root/anytls-audit-v132`；网络/防火墙破坏性场景在独立网络/挂载命名空间内。完整配置事务使用原生核心和 Nginx 的真实 www-data worker，但 systemctl/建账号接口由夹具替代，没有覆盖安装到正式业务目录。
- 外部 Windows 客户端分别使用 sing-box 1.14.4 与 Xray 26.10.21。新下载 Xray Windows 发布包经 GitHub 官方 release.digest 校验；客户端可执行文件摘要见 test-results.json。

## 断言汇总

| 测试组 | 数量 | 结果 |
|---|---:|---|
| time-monitor-results.json | 12 | 全部通过 |
| fault-results.json | 17 | 全部通过 |
| transaction-results.json | 8 | 全部通过 |
| integration-results.json | 35 | 全部通过 |
| v132-results.json | 83 | 全部通过 |
| hy2-results.json | 80 | 全部通过 |
| workflow-results.json | 12 | 全部通过 |
| real-firewalld-results.json | 15 | 全部通过 |
| v129-regression.json | 16 | 全部通过 |
| Windows 公网同核心认证转发 | 2 | 全部通过，单独记录 |

## HY2 与网关

- 新装标准 HTTP/3 默认流程、显式 obfs 替代流程、obfs 时不渲染标准伪装、拒绝站点后重新选择/取消已验证。v1.3.1 的自适应/固定带宽、导出、官方多端口 URI、错误密码/混淆密码/SNI/不可信证书拒绝等回归通过。
- 站点检测覆盖 200、3xx 不跟随、CDN 标志、Cookie、CSP 提示、普通缓存头、超过 50 KiB 截断、挑战页、访问拒绝、私网地址、无响应、URL 元字符与 DNS 超时。DNS 在有时限的子进程解析，再固定已检查地址连接，防止卡住菜单和检测阶段 DNS 重绑定。
- 当前 VPS 的真实 GET 采样：SQLite 200 / 9008 字节，Lua 200 / 2036 字节，OpenBSD 200 / 3622 字节。它们是当时结果，安装仍重新检测与确认，不保证以后不变。
- 原生 Nginx → HTTP 上游及 HY2 HTTP/3 → 回环 Nginx 数据路径通过；robots、未开放路径 404、POST 405、小型 503 兜底通过。实际全局限流压力样本 50 请求：11 个 200、39 个 429。
- 原生 file/string 伪装配置与真实 HTTP/3 页面内容通过；file 的 robots.txt 实际响应通过。AnyTLS 专用 JSON 实际生成、0600 权限和 sing-box 原生校验通过。
- 测试发现并修复：本地限流 429 曾被兜底 error_page 改成 200；现在限流 429 保留。连接数限制也用 429，与上游故障兜底分开。
- 测试发现并修复：Nginx 默认上游 TLS 校验深度过小，导致 SQLite 合法证书被拒绝。现为显式深度 5，保留证书和主机名验证；真实 HTTPS SQLite 内容通过，另测不可信证书被拒绝、返回小型兜底页，没有关闭验证。
- 使用实际非特权 Nginx worker 的完整提交、私有监听、网关配置/状态回滚、回滚后继续返回原内容通过。网关端口未进入期望公网放行列表。
- IPv4/IPv6 iptables 跳跃真实数据转发、原生客户端认证、失败撤销、规则替换/幂等、保留管理员无关规则，以及真实 firewalld runtime/permanent/zone 变更回归通过。
- 网卡监控基线、阈值告警、私有状态和统计范围提示通过；定时器的配置事务接口由夹具验证，本次未把新定时器长期启用到正式 systemd。

## Reality、AnyTLS 与时间

- 旧 shared 状态无轮换迁移、A…AA 持久标签、完整复制、只复用 dest/SNI、全新配置、复制后不暗中联动、重新配置已有协议保留参数通过。
- 两种核心的独立 dest/SNI 渲染与原生配置检查通过；目标探针退出码非零、超时但含“成功”文本、缺链长度、缺 PQ 字段、格式改变、缺 OpenSSL 均不会显示通过。
- Xray → Xray 的 VLESS+Reality+Vision 与 sing-box → sing-box 的 AnyTLS+Reality 原生认证通过；错 Short ID 拒绝。自定义 AnyTLS padding 的校验、双协议渲染、认证和重连通过。
- **已知未通过组合**：本次 sing-box 1.14.4 → Xray 26.10.21，以及 mihomo 1.19.33 → Xray 26.10.21 的受测 VLESS+Reality+Vision 认证失败。脚本探针正确报告 failed；同核心成功或共享参数不能推导这些组合兼容。AnyTLS+Reality 的 mihomo 探针为不适用。
- sing-box 的 60 秒窗口接受 0、+30 秒应用时钟偏差，拒绝 ±120 秒；关闭窗口后 +120 秒可认证。使用应用内 NTP 响应测试，**未修改 VPS 系统时钟**。Xray 60000 ms 正常握手、1 ms 拒绝、0 关闭后正常握手。旧时间策略、秒/毫秒转换与明确关闭渲染通过。
- 能力检测旧回归继续通过：当前受测 sing-box 客户端 AnyTLS/VLESS 指纹样本未发送标准 MLKEM key share；同一核心的服务端在受控 X25519MLKEM768 目标和参考客户端下完成真实混合协商与认证转发。客户端发包、服务端能力与当前目标协商分别报告，不能合并成“整个核心没有抗量子能力”。
- 能力探针参考下载摘要验证、缺失参考为未知、错误参数、快速模式、报告不含凭据、0600 原子写入、状态文件不被覆盖、回退 ServerHello 不冒充认证、信号中断清理均通过。

## 真实公网验证

在已授权 VPS 临时启动由本版渲染的两个入站，随机凭据、公网出口保护，不修改正式服务/防火墙，180 秒看门狗兜底。本机 Windows 原生 Xray 客户端连接 VPS 的 VLESS+Reality+Vision，Windows sing-box 客户端连接 AnyTLS+Reality，均取得经过认证隧道的预期 HTTPS 测试响应。保留 Reality 公钥验证与真实目标，未替换成回环，也未用关闭 TLS 验证冒充公网验收。

探针 JSON 的 `external_ingress_verified` 仍为 false：通用脚本不能自行证明它运行在哪台机器；此处外部位置由实际执行工具所在 Windows 工作站与 SSH 目标分离的测试过程确认。`external_execution_claimed` 明确记录调用者声明。本次验证只覆盖这两个 IPv4 TCP 入口，不扩展成公网 IPv6、HY2 UDP 或全端口跳跃验收。

## 清理与剩余限制

测试结束时公网临时入站、客户端和网关测试进程已关闭。TCP 只剩原 SSH 22；UDP 只剩原 DHCP/chrony；主网络命名空间 IPv4/IPv6 PREROUTING 无新增规则；正式 `/etc/anytls-reality` 仍不存在。测试证据留在私有审计目录。

尚未本轮验证：真实 ACME/DNS API 签发、WARP 注册、IPv6-only/NAT64、arm64、RHEL/SELinux、长期流量/洪泛压力、所有第三方 GUI 导入、所有 Reality 传输组合的公网路径，以及完整正式安装和新监控定时器的长期运行。HTTP 层限流不防 QUIC 握手洪泛，缓存/robots/小首页不保证月流量上限；站点语义、长期可用性和滥用价值仍需人工判断。

测试脚本与可核对结果随包提供；核心二进制、临时节点凭据和测试私钥不包含在发布包内。升级或回退请按 README 的备份与状态兼容说明操作。
