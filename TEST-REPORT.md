# AnyTLS-Reality v1.4.1 测试报告

日期：2026-10-29。基线：已交付的 v1.4.0。脚本 SHA256：`e92f0ce7f381766a4781e19a5fea986e50df08f6bafdaab31d2c4b755547a474`。

## 结果

本轮 **64 项 VPS 针对性检查及 3 项 Windows PNG 解码检查全部通过**。Bash 语法、ShellCheck 0.10.0 warning 级、所有 Python AST、三段内嵌 Python 与 tools 源码一致性、发布补丁应用及 ZIP 校验通过。

此前用户在同一 VPS 节点上已实机确认 Exclave、Shadowrocket 二维码可正常使用。本轮在内存中将 v1.4.1 的两种载荷与该已验证样本比较：除节点显示名称外，Exclave 的连接字段与 Shadowrocket 的地址、认证、查询参数完全一致。生产凭据和实际节点二维码不包含在发布包内。Stash 尚无用户实机验证，本版未加入。

## 本版覆盖

- Exclave：精简单个 sing-box AnyTLS outbound 的 JSON；保留 Reality、公钥、Short ID、SNI，不关闭身份验证。
- Shadowrocket：已验证的 anytls URI 形式，包含 peer/sni、security=reality、pbk/sid、fp、tls=1、insecure=0、udp=1；密码、IPv6、中文/特殊字符名称正确编码。
- 仅为 AnyTLS+Reality 新增两种专用格式，通用 URI 仍为 null；VLESS 等原有通用二维码载荷保持不变，未为无可用格式的协议制造假二维码。
- 本地生成真实 PNG，注册表仅记录摘要和元数据，不保存明文载荷；qrencode 通过 stdin 接收凭据。原始 PNG/注册表 0600、用户图片目录 0700；web 副本仅供 Nginx 工作组读取。
- 兼容 v1.4.0 没有 client 字段的通用图片记录；同凭据不同节点名也使用不同图片，避免覆盖。重复生成可复用未变资源，CLI regenerate 则撤销并更换 ID。
- 实际 Bash 客户端生成入口覆盖 AnyTLS+Reality、Xray VLESS+Reality+Vision、HY2 混合部署。账号输出、终端二维码及 CLI 分别标注客户端；无可信 HTTPS 条件时不打印下载网址。
- 同一用户撤销同时删除两种客户端的本地/web 图片，保留其他用户；全局撤销覆盖全部。真实 _commitLive 状态提交边界删除旧图，不变状态保留图片。第二张图片编码中途失败时清除旧图和部分新图，不留下“生成成功”的残余资源。
- 原生 Nginx、真实非 root 工作进程、仅回环 TLS 监听：两种 PNG 都能通过签名获取；缺签名/缺期限/篡改期限返回 403，合法但过期签名返回 410；撤销后两种链接均为 404，无需重载 Nginx。
- 下载响应包含 no-store/no-referrer/noindex/nosniff，目录和本地原图路径不能通过该入口访问；签名图片路径不写入访问日志。两种网址使用独立图片 ID、300 秒期限，不含节点 URI 或密码。
- Windows 使用固定版本 zxing-cpp 2.3.0 对 VPS 生成的 Exclave、Shadowrocket、原通用三张 PNG 真正解码，结果分别与原载荷逐字一致。测试依赖仅放在本地工作目录，没有安装到生产 VPS。

## 环境与隔离

VPS：Debian GNU/Linux 13.7 amd64，Python 3.13.5，sing-box 1.14.4、Xray 26.10.21、系统 Nginx 和 qrencode。测试目录为 `/root/anytls-audit-v141`，使用合成测试凭据；HTTPS 使用 `/tmp` 临时目录、回环随机端口和显式信任的测试 CA，不向系统安装根证书。

ShellCheck 下载并解包在私有审计目录中运行，未通过包管理器安装或升级系统软件。已有服务始终保持运行。核对正式安装的 state.json、脚本及核心配置未被本轮测试改写；正式脚本仍为 v1.4.0，没有代替用户执行升级。此前仅供 Stash 实机测试的临时 HTTPS 配置入口已删除，网站配置字节恢复至测试前备份；正式三项服务保持 active，临时 Nginx 测试进程均已退出。

## 范围与限制

本轮未重新执行 v1.4.0 的完整 386 项历史回归，也未把历史检查重复计入本版 67 项。发布包保留原有测试源码；这些历史测试需要各自声明的隔离夹具环境。未新增手机 GUI 自动化或重新测试所有客户端版本；用户实机确认与本轮格式一致性检查分别记录，不把扫码解析当成新的手机网络验收。

没有部署新的公网 QR 服务、申请证书或更改防火墙。原生 HTTPS 请求验收位于回环测试入口，可信公网证书/直连 DNS 等资格判断逻辑沿用 v1.4.0。AnyTLS+Reality 专用 URI 不保证被 Exclave/Shadowrocket 之外的客户端识别；v2rayNG 仍不支持。已下载图片或已导入节点不能通过撤销图片链接收回，需更换节点凭据才能撤销其连接权限。

升级：备份并替换安装目录中的脚本后，执行 `atr qr regenerate [用户]`，即可为现有 AnyTLS+Reality 生成两种 PNG 及符合条件时的 5 分钟图片链接，无需重启代理服务、重装节点或轮换端口/密钥。
