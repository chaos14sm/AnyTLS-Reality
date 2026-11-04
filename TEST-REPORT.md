# AnyTLS-Reality v1.4.2 测试报告

日期：2026-11-04。基线：已交付的 v1.4.1。脚本 SHA256：`809a827b9d90729ec33fe98c973e38506e6e1edfc8f58fdca7e44d7ca03f66d1`。

## 结果与范围

本轮 **89 项 VPS 隔离回归、7 项 Windows PNG 解码/YAML 检查、5 项维护刷新检查、4 项真实部署只读比对，共 105 项针对性检查全部通过**。另通过 Bash 语法、ShellCheck 0.10.0 warning 级、所有 Python AST、四段内嵌 Python 与工具源码一致性、发布补丁应用/逐文件比较、离线重建和 ZIP 校验。没有把历史版本检查或重复运行次数计入本次总数。

用户已在 Stash 实机确认三协议配置和本版采用的完整分流方案可用。当前生成器与该已验证配置的规则数组逐条一致，当前 VPS 三个协议的连接字段在内存中比对完全一致；名称由脚本统一生成。Exclave、Shadowrocket 两种载荷与 v1.4.1 逐字一致。未新增手机 GUI 自动化，也未宣称所有协议均完成 Stash 真机网络测试。

## 验证内容

- 默认构建真实联网获取 release 最新引用，固定到 `24dd572ab5c2ba577bb96723d7cf3d9d3eb0af76`；原文件 SHA256 `fbe280180e01ea34e96d7bb29306a5e3eebd562aac84c6cec23ffdd30ab04375`。原 53,206 条规则，经绕过/明确域名保证转换为 53,262 条；原文件、编译 JSON、运行时压缩模板三者相符，保留 CC BY-SA 4.0 署名。
- 国内网站、Apple 国内外、Google/YouTube/Facebook、JD 广告域名、国内 GeoIP 及最终代理样例符合用户验证的策略；广告优先、全部原规则顺序和单一 PROXY 组保留。无远程规则下载依赖、不启用 MitM。
- 12 种可表达协议的映射覆盖 TLS/Reality、公钥、端口、SNI；HY2 auth / 自动与固定带宽 / 跳跃 / obfs，TUIC v5，Xray Reality 混合交换标志。Naive/HTTPUpgrade 明确排除，不制造不可用节点。
- 实际 Bash 生成入口处理 AnyTLS+Reality、HY2、Xray VLESS+Reality+Vision 的混合部署。超过 2 MB 的配置经 stdin 传递，避免 argv 长度限制。无 HTTPS 时只显示本地 YAML；旧 v1.4.1 只有 PNG 路由时不输出 Stash 链接；运行中端点检查失败清除新图片、不发布网址。
- 配置/注册表及本地 PNG 为 0600，用户目录 0700；web 副本只供 Nginx 组读取。注册表只保存摘要、资源标识和非敏感元数据，无节点密码/公钥正文。节点 QR 更新保留 Stash 资源，用户撤销不影响其他用户，配置内容变化删除旧 YAML/图片；状态提交边界撤销全部旧资源。
- Stash QR 内为原始 HTTPS YAML 地址，图片网址与内含地址共用同一个 300 秒截止时间。刷新撤销前一张导入图片；不承诺撤销已下载 YAML、截图或手机内已保存的节点。
- 使用真实 Nginx 非 root 工作进程、随机回环 TLS 入口和显式信任的临时测试证书：完整 gzip YAML 下载与源字节一致，PNG 可下载；缺签名/篡改 403、合法过期 410、撤销后 YAML/PNG 立即 404，POST 405，目录/本地原件不能访问。响应包含 no-store/no-referrer/noindex/nosniff；签名路径不写访问日志。实际 Bash HEAD 端点探测也通过。
- Windows 使用 zxing-cpp 2.3.0 真正解码 Stash、Exclave、Shadowrocket 三张 PNG，内容分别与原载荷完全一致；使用 PyYAML 6.0.2 解析完整 YAML，核对三节点、单一组、规则数、HY2 auth 及 Reality 严格验证。
- 维护工具模拟最新引用变化/固定 SHA 下载、网络故障、未知语法和第二次文件替换失败；错误停止并保留/恢复原模板，未悄悄沿用旧规则冒充新快照。

## 隔离与清理

VPS：Debian 13.7 amd64、Python 3.13.5、系统 Nginx 1.26.3、qrencode，已有 sing-box 1.14.4 / Xray 26.10.21。本轮回归目录 `/root/anytls-audit-v142`；纯合成凭据，临时 Nginx 只监听回环地址。ShellCheck 下载解包在私有审计目录，未安装或升级系统包；测试 CA 没有加入系统信任。

正式脚本仍为 v1.4.1，state.json 及核心配置未修改、三项服务保持 active。此前供用户扫码的临时 Stash HTTPS 入口已移除，网站配置字节恢复为测试前备份；临时 Nginx 测试进程已退出。发布包不包含真实节点 YAML、真实二维码、生产密钥或临时有效网址。

## 使用限制与升级

新旧路由变更需应用后才能使用 Stash HTTPS：备份并替换脚本，有受管理可信 HTTPS 时执行 `atr restart`，再 `atr qr stash [用户]`；这会重载受管理服务，未代替用户执行生产升级。没有可信 HTTPS 时可 SSH 下载本地 YAML，完整规则无法塞入离线二维码，脚本不新增明文入口。

短期配置 URL 只用于导入，应关闭该配置自动更新；以后重新生成、重新导入。新增其他协议的 Stash 映射只做字段/结构检查，未重新跑全部代理公网吞吐、不同移动客户端版本、IPv6/RHEL/arm64、ACME 真签发和历史所有协议回归。原有客户端专用格式不等于通用 URI。
