# AnyTLS-Reality

> 本目录是尚未发布到 GitHub 的 v1.2.8 本地版本包。请上传本包的 `anytls-reality.sh` 到 VPS 后执行 `bash ./anytls-reality.sh`；下方 GitHub 下载命令对应仓库已发布版本。

sing-box / Xray-core 一键管理脚本，**支持 AnyTLS + Reality**。

界面、菜单编号和操作习惯参考并派生自 [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)（v2ray-agent 目前没有 AnyTLS + Reality 这个组合），安装后直接输入 `atr` 进入管理菜单。本项目是独立的派生作品，与 v2ray-agent 官方无关联。

> **项目状态**：开发期间在隔离沙箱中，用真实的 sing-box / Xray / mihomo / nginx 二进制做过端到端验证（包括 AnyTLS + Reality 的回环握手）。2026-10-25 又在一台全新的 Debian 13 VPS（systemd 257、nginx 1.26）上做过一次完整的实机审计（v1.2.5）：真实 systemd 服务管理与沙箱、nginx 降权到 `atr-nginx`、真实 iptables 端口跳跃、各协议的真实数据转发（含 Windows 上的 sing-box 客户端经公网连接、官方 NaiveProxy 客户端、Xray 原生 XHTTP 客户端）、事务回滚与恢复、订阅撤销、DNS rebinding 对照实验，以及用 `strace` 核对凭据不出现在命令行上；v1.2.6 增加了相关修复；v1.2.7 进一步修复证书崩溃恢复和防火墙事务边界；v1.2.8 增加同核心自检与 Reality 共享/独立配置，并在原 Debian 13 VPS 上重新回归。详见 CHANGELOG.md 和随版本提供的测试报告。**仍未在真实服务器上验证**的：acme.sh 真实签发与 DNS API、WARP 注册、IPv6 专属流程与 NAT64、RHEL 系 + SELinux、arm64、BBR/DD、长时间压力测试。建议先在测试机上试用，遇到问题请到 Issues 反馈。

## 特性

- **5 个预设组合排在最前**：VLESS+Reality+Vision、AnyTLS+Reality、Tuic、Hysteria2、Naive；v2ray-agent 支持的其他协议在「任意组合安装」里列出
- **sing-box 排第一，Xray-core 排第二**
- **AnyTLS + Reality 一键安装**：安装 sing-box → 询问端口与 Reality SNI（推荐列表 / 自定义输入 / TLS 1.3 可达性检测）→ 生成密钥对 → 配置 AnyTLS 入站使用 Reality → systemd 服务 → 防火墙放行 → 回环握手自检
- **只用正式发布的稳定版内核**：候选版本依次来自 GitHub `releases/latest` API → 重定向探测 → 手动输入；不论来自哪一层，都要再向 GitHub API 核对这个 tag 是正式发布（不是 draft / prerelease）才会下载，核对不了就中止（需要能直连 `api.github.com`，见「安全模型」）。也可以用 `ATR_XRAY_VERSION` / `ATR_SINGBOX_VERSION` 固定版本（同样要核对）。下载后做 SHA256 校验；换内核后做回环握手的互通检查，握手失败自动恢复旧内核
- **配置一致性保护**
  - 所有配置由 `state.json` 经 jq 渲染生成（密码含特殊字符也不会破坏 JSON）
  - 每次改动：渲染 → `sing-box check` / `xray run -test` / `nginx -t` → 备份 → 落盘 → 重启 → 验证端口监听，失败自动回滚
  - 密钥文件只在配置校验通过、事务提交时才落盘，避免「客户端公钥与服务端私钥不匹配」
- **客户端配置自动生成**：安装、改密、添加用户、改 SNI / 端口 / 密钥后自动重新生成全部客户端文件，并提示需要同步到客户端
- **安全默认值**（详见下文「安全模型」）：
  - SOCKS5 入站的来源 IP 白名单不能为空，空白名单不会变成「不限制来源」；白名单在协议嗅探和 DNS 劫持之前检查，非白名单来源的 DNS 请求同样被拒绝
  - 订阅目录只对 root 和 nginx 专用账号 `atr-nginx` 开放，本机其他用户读不到
  - 每个用户一个独立的随机订阅令牌，可单独更换；重置密码时可同时更换订阅链接
  - 内核二进制必须通过 SHA256 校验才会被解压运行，取不到校验值就中止
  - 合并其他机器的订阅时只允许 HTTPS，强制校验 TLS 证书，并校验取回内容的格式
  - sing-box / Xray 的 systemd 单元只保留 `CAP_NET_BIND_SERVICE`，整个系统（含安装目录）对服务只读，服务不能创建 Unix 套接字（连不上 systemd / D-Bus），并开启其他沙箱选项
  - **出口访问模式**：部署时第一个问题就让你选「公网出口」（默认，客户端不能经节点访问本机和内网）还是「允许内网访问」
  - 密码、UUID、私钥、令牌、合并远程订阅用的对等密钥等不会出现在任何进程的命令行上（同机其他用户用 `ps` 看不到）；无法保证这一点时操作直接失败，不会换一种暴露的方式继续
  - 所有会改配置、发布订阅的操作互斥执行（`flock`），拿不到锁就不动；基于过期快照的修改会被拒绝，不会覆盖另一个终端刚提交的内容
  - 配置落盘的每一步（备份、事务标记、核心/nginx 配置、state）和服务的重启/停止都检查结果并核对内容，任何一步失败都不会报告「配置已生效」；回滚本身失败时保留恢复依据，恢复依据还在时拒绝任何新的修改（`status` / `show` / `log` 仍可用，`atr recover` 重试，`atr recover --abandon` 放弃）
  - 撤销（更换订阅链接、重置/关闭对等密钥、删除用户、关闭订阅）在配置提交的同一把锁里生效，不依赖随后的文件发布成不成功；被撤销的令牌同样不会出现在任何命令行上
  - 客户端完整配置里的本地控制接口带随机 secret，secret 为空时干脆不生成控制接口；不再自动下载面板
- 证书：acme.sh HTTP-01、Cloudflare / 阿里云 DNS API、导入已有证书
- 完整的 nginx 架构（独立实例，不修改系统自带 nginx 的配置）：Xray Vision 回落、伪装站 / 302、HTTPUpgrade、订阅、CDN
- 周边功能：用户管理（删除用户至少保留一个）、端口跳跃、添加新端口、alpn 切换、BT 与域名黑名单、分流工具（WARP / IPv6 / Socks5 / DNS / SNI 反向代理）
- 实时日志按 `Ctrl+C` 优雅返回菜单
- BBR / DD：与 v2ray-agent 一样可调用 [ylx2016/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed)，另提供内置的「仅启用原版 BBR+FQ」

## 环境要求

- root 权限，systemd
- Debian / Ubuntu 系，或 RHEL 系（CentOS / Rocky / AlmaLinux / Fedora 等）；**不支持 Alpine**，也不支持不带 systemd 的容器
- amd64 或 arm64
- 能访问 GitHub（下载内核、规则集）
- 界面语言为中文

## 安装

```bash
wget -P /root -N "https://raw.githubusercontent.com/chaos14sm/AnyTLS-Reality/main/anytls-reality.sh" && chmod 700 /root/anytls-reality.sh && /root/anytls-reality.sh
```

没有 wget 时用 curl：

```bash
curl -fsSL -o /root/anytls-reality.sh "https://raw.githubusercontent.com/chaos14sm/AnyTLS-Reality/main/anytls-reality.sh" && chmod 700 /root/anytls-reality.sh && /root/anytls-reality.sh
```

首次运行会把脚本保存到 `/etc/anytls-reality/anytls-reality.sh` 并注册 `atr` 命令，之后直接输入：

```bash
atr
```

> **不要用 `curl ... | bash` 运行。** 脚本是交互式菜单，管道运行时 stdin 被占用；脚本也不会保存到本机，`atr` 命令和证书续签后的重载钩子都不可用。
>
> `raw.githubusercontent.com` 带有约 5 分钟的缓存，仓库更新后可能要等几分钟才能下载到新版本。
>
> 本脚本以 root 身份运行并会安装内核二进制，请只从你信任的地址下载；通过第三方下载代理获取脚本等于信任该代理。

## 主菜单

菜单编号与 v2ray-agent 保持一致：

| 编号 | 功能 | 说明 |
| --- | --- | --- |
| 1 | 安装 / 重新安装 | 先选内核（1.sing-box 2.Xray-core），再在 5 个预设组合里多选（回车默认 `1,2`）。Xray 只有 VLESS+Reality+Vision 属于预设 |
| 2 | 任意组合安装 | 列出全部协议，前 5 个预设仍排在最前 |
| 3 | 一键无域名 AnyTLS+Reality | 只装 sing-box 与 AnyTLS+Reality，不需要域名和证书 |
| 4 | Hysteria2 管理 | 重新配置、卸载、端口跳跃 |
| 5 | REALITY 管理 | 查看各协议参数、修改 SNI/端口、按协议重置密钥与 Short ID、自检、切换共享/独立配置 |
| 6 | Tuic 管理 | 重新配置、卸载、端口跳跃 |
| 7 | 用户管理 | 查看账号 / 订阅、更换订阅链接、合并其他机器的订阅、添加 / 删除用户、重置密码或 UUID、重新生成全部客户端配置 |
| 8 | 伪装站管理 | 模板站点、302 重定向（需要 nginx） |
| 9 | 证书管理 | 立即续签、重新申请（HTTP-01 / DNS API）、导入已有证书、acme 日志 |
| 10 | CDN 节点管理 | |
| 11 | 分流工具 | WARP（IPv4 / IPv6）、IPv6、Socks5、DNS、**出口访问模式**、SNI 反向代理 |
| 12 | 添加新端口 | 仅 Xray 的 VLESS+TLS_Vision 前置 |
| 13 | BT 下载管理 | 禁止 / 允许 BT |
| 14 | 切换 alpn | 仅 Xray 的 VLESS+TLS_Vision 前置 |
| 15 | 域名黑名单 | 屏蔽域名、屏蔽大陆域名 + IP、白名单 |
| 16 | core 管理 | 升级 / 回退 / 启停 / 重启 sing-box 与 Xray，更新 geo 文件，调试日志 |
| 17 | 更新脚本 | 从本仓库的 raw 地址更新（见下文） |
| 18 | 安装 BBR、DD 脚本 | 第三方 tcpx.sh，或内置的原版 BBR+FQ |
| 19 | 查看日志 | sing-box / Xray / nginx / acme 实时日志，脚本操作日志 |
| 20 | 卸载脚本 | |

## 支持的协议

| 协议 | sing-box | Xray | 需要域名 + 证书 |
| --- | :---: | :---: | :---: |
| VLESS+Reality+Vision | ✓ | ✓ | 否 |
| **AnyTLS+Reality** | ✓ | | 否 |
| Tuic | ✓ | | 是 |
| Hysteria2 | ✓ | | 是 |
| Naive | ✓ | | 是 |
| VLESS+TLS_Vision+TCP | ✓ | ✓ | 是 |
| VLESS+TLS+WS | ✓ | ✓ | 是（可走 CDN） |
| VMess+TLS+WS | ✓ | ✓ | 是（可走 CDN） |
| Trojan+TLS | ✓ | ✓ | 是 |
| VLESS+Reality+gRPC | ✓ | | 否 |
| VMess+TLS+HTTPUpgrade | ✓ | | 是（可走 CDN，经 nginx） |
| AnyTLS+TLS（证书） | ✓ | | 是 |
| VLESS+Reality+XHTTP | | ✓ | 否 |
| VLESS+XHTTP+TLS | | ✓ | 是（可走 CDN） |

只选 Reality 类协议时不需要域名。

## AnyTLS + Reality

交互安装：菜单 `3`，或菜单 `1` 选 sing-box 后选 `2`。

非交互安装（`--port` 缺省为 443，被占用则随机；`--sni` 省略时沿用已有配置，新配置缺省为 `www.microsoft.com`；`--user` 缺省为随机名）：

```bash
atr install-anytls-reality --port 443 --sni dl.google.com --user alice
```

要点：

- **客户端必须开启 uTLS**，否则 sing-box 会报 `uTLS is required by reality client`。脚本生成的 sing-box 配置已默认开启。
- 公钥、Short ID、SNI 必须与服务端一致；公钥填错时客户端会报 `reality verification failed`。`atr selfcheck`（菜单 5 → 5）会用 sing-box 客户端对本机做一次回环握手来检测这类问题。
- **mihomo / Clash.Meta 官方不支持 AnyTLS + Reality**，所以这个协议只输出 sing-box JSON 和参数说明，没有分享链接，也没有 mihomo YAML。
- Reality 目标域名（SNI）：推荐列表前 5 个（`dl.google.com`、`www.apple.com`、`download-installer.cdn.mozilla.net`、`www.python.org`、`www.amd.com`）证书链较短，sing-box 与 Xray 作服务端都能完成握手。其余域名（如 `www.microsoft.com`、`addons.mozilla.org`）在 **Xray 作服务端**时可能握手失败，脚本会在检测时给出提示；sing-box 作服务端不受影响。
- 修改 SNI：菜单 `5` → `2`；独立模式先选协议。命令行见下方，只改 SNI 会保留该配置的密钥和 Short ID，相关客户端需同步。

## 双核心与 Reality 配置方式（v1.2.8）

先在安装菜单选择 Xray，安装 VLESS+Reality+Vision；再选择 sing-box，追加 AnyTLS+Reality。两种协议必须使用不同监听端口。每次安装 Reality 协议会询问配置方式，回车沿用当前方式，新安装默认为共享：

- **共享**：所有 Reality 协议使用同一套 SNI、X25519 密钥对与 Short ID。SNI 检测会同时考虑已安装的 Xray Reality 协议。
- **独立**：每个 Reality 协议单独保存配置，可以使用不同 SNI、密钥对和 Short ID，也允许部分值恰好相同。新加入的协议单独选择 SNI并生成密钥；已存在的协议可保留当前参数。菜单 `5 → 2` 单独改 SNI，`5 → 4` 单独重新生成密钥对与 Short ID。

菜单 `5 → 6` 随时切换。共享转独立时复制当前参数，切换本身不会使原客户端失效；之后可分别修改。独立转共享时必须选择一个协议作为参数来源，确认后其他 Reality 节点的客户端需同步该套参数。

```bash
atr reality-mode independent
atr sni www.python.org --protocol anytls_reality
atr sni www.apple.com --protocol vless_reality_vision
# 将所有 Reality 协议统一为 VLESS 节点当前的一套配置
atr reality-mode shared --from vless_reality_vision
```

独立模式的 `sni` 命令必须指定已安装的 Reality 协议，避免误改全部节点；共享模式请省略 `--protocol`。非交互安装可用 `--reality-mode independent`，省略时沿用当前方式；不能用安装命令隐式覆盖已有的独立配置，应先用 `reality-mode shared --from ...` 选择来源。

状态缺少 `reality_mode` 时按旧版共享配置处理。独立配置保存在 `protocols.<协议ID>.reality`，客户端链接、sing-box JSON、mihomo YAML和订阅均读取对应协议的参数。需要回退旧脚本时，先切回共享或恢复旧版完整备份，旧版无法识别独立配置。

`atr selfcheck` 会按服务端核心选择探针：Xray 节点使用本机 Xray，sing-box 节点使用本机 sing-box；输出明确显示 `xray → xray` 或 `sing-box → sing-box`。Xray 的 Reality XHTTP 和 TLS XHTTP 现在也能自动检查。内核升级/回退验收复用同一检查逻辑，真实握手失败仍会回滚。

自检通过证明当前同核心客户端能完成回环握手及访问测试站点，不能证明所有第三方或旧版客户端兼容，也不能证明公网防火墙已经正确放行。Xray 与 sing-box 的跨核心 Reality 兼容问题仍应按实际客户端组合确认；共享密钥不会消除该差异。Naive 仍需其专用客户端验证。Xray TLS 探针信任本机已配置证书，sing-box 非 Reality TLS 探针仍跳过证书链验证，均不等同于公众 CA 信任验证。

## 命令行

```text
atr                                打开交互式管理菜单
atr install-anytls-reality [选项]  非交互一键安装 AnyTLS+Reality
      --port N        监听端口(默认 443，被占用则随机)
      --sni host[:p]  Reality 目标域名(省略沿用已有配置，新配置默认 www.microsoft.com)
      --user name     首个用户名(默认随机)
      --reality-mode shared|independent  共享/按协议独立（省略沿用当前方式）
      --egress MODE   出口访问模式: public 公网出口(默认，禁止客户端访问本机与内网) | full 允许内网访问
atr status                         查看服务与端口状态
atr show [用户] [1]                查看账号(第二个参数 1 同时显示二维码)
atr sub [用户]                     查看订阅链接
atr selfcheck                      按节点所属核心做真实回环握手测试（Naive 需专用客户端）
atr sni <host[:port]> [--protocol ID] [--force]  修改对应 Reality SNI
atr reality-mode shared|independent [--from ID]  切换参数方式
atr passwd <用户> [新密码] [--keep-sub]  重置密码(不给则随机)；订阅已启用时默认同时更换订阅链接，--keep-sub 保留旧链接
atr adduser <用户> [uuid] [密码]   添加用户
      (密码参数写成 - 表示从标准输入读取，避免密码出现在 ps / shell 历史里；passwd 同理)
atr deluser <用户>                 删除用户(至少保留一个)
atr recover [--abandon]            上次操作没有恢复完成时: 重试恢复；--abandon 放弃恢复(备份目录保留)
atr restart                        重启全部服务
atr log [sing-box|xray|nginx|acme] 查看日志(Ctrl+C 返回)
atr uninstall                      卸载
atr version | atr help
```

`renew-tls`、`update-geo`、`reload-core`、`apply-hop` 供定时任务和钩子调用，一般不需要手动执行。

## 客户端配置

每个用户的文件保存在 `/etc/anytls-reality/clients/<用户>/`：

| 文件 | 内容 |
| --- | --- |
| `links.txt` | 分享链接（Reality + AnyTLS 没有标准链接，不在其中） |
| `sing-box.json` | 最小可运行的 sing-box 客户端配置 |
| `sing-box-full.json` | 带分流规则的 sing-box 完整配置（本地控制接口 `127.0.0.1:9090`，带每用户独立的随机 `secret`） |
| `mihomo-proxies.yaml` | mihomo / Clash.Meta 的 `proxies` 片段 |
| `mihomo-full.yaml` | mihomo / Clash.Meta 完整配置（控制接口同样带随机 `secret`） |
| `naive-client.json` | NaiveProxy 官方客户端配置（安装了 Naive 时） |

控制接口与面板：完整配置里的控制接口只监听回环地址，并且必须带 `secret`（在配置文件的 `experimental.clash_api.secret` / `secret:` 里，每个用户不同）。**不再自动下载面板**：面板代码与控制接口同源，经镜像下载的面板无法验证完整性，被篡改后能直接操作代理。需要面板时，请自己下载并核对发布包，再在配置里加上 `external_ui`，或使用你信任的客户端自带的界面。

Naive 说明：sing-box 的 naive 出站需要 `libcronet.so` 与二进制放在同一目录（官方压缩包里带有；本脚本只安装单个二进制，服务端的 naive 入站不依赖它）。客户端是否带这个库因人而异，所以脚本对 Naive 只提供 `naive+https://` 链接和 NaiveProxy 官方客户端 JSON，不生成 sing-box 出站；mihomo 不支持 Naive。

订阅：菜单 `7` → `2` 启用后（需要 nginx）可用一条链接导入某个用户的全部节点。

- 每个用户有自己的随机订阅令牌（128 位，存在 `state.json` 里），和节点密码 / UUID 没有任何关系。**重置节点密码并不会让已泄露的订阅链接失效**（旧链接仍然能取到新密码），所以重置时会询问是否同时更换订阅链接；也可以在 `7` → `2` → `2` 里单独更换某个用户或全部用户的订阅链接，旧链接立即失效。
- **合并其他机器的订阅**（`7` → `3`）：对方机器先在 `7` → `3` → `5` 开启「对等密钥」，本机添加对方时填写 `域名或IPv4:端口:别名` 和这把密钥，之后本机每个用户的订阅里会带上同名用户在对方机器上的节点（名称加别名后缀）。对等密钥只用于服务器之间合并，和各用户的订阅令牌互相独立，泄露它等于泄露那台机器所有用户的节点；对方用私有 CA 或自签证书时，在添加时提供证书文件路径。证书一律严格校验，取回的内容必须通过格式校验才会合并。
- 从 v1.0.0 升级：旧版靠两台机器共用同一个 salt 来合并订阅，该机制已淘汰。升级后会为每个用户生成新的随机令牌（旧订阅链接失效，需要在客户端重新导入），旧的远程订阅条目可在 `7` → `3` 里导入，补上对方的对等密钥后才会生效。

## 更新与卸载

- **更新脚本**（菜单 `17`）默认从本仓库的 raw 地址下载，下载后会检查 `bash -n` 语法和脚本标识，显示新脚本的 SHA256，确认后才替换（确认默认是 N），并把旧版本备份为 `anytls-reality.sh.prev`。语法与标识检查只能发现损坏的文件，不能证明来源可信，请确认地址是你自己的仓库。在菜单里改过的地址会被记住（保存在 `/etc/anytls-reality/script_url`），优先于默认值。
- **fork 后使用自己的地址**：修改脚本开头的 `ATR_SCRIPT_URL_DEFAULT`，或在菜单 `17` 里输入你自己的 raw 地址。
- **更新内核**：菜单 `16`，只会升级到正式发布的稳定版，也可以回退。换内核后会用本机 sing-box 作客户端，对这个内核承载的协议逐个做回环握手：任何一个握手失败就自动恢复旧内核。Naive、VLESS+Reality+XHTTP、VLESS+XHTTP+TLS（sing-box 客户端不支持，由协议表声明），以及本机没有 sing-box 时的全部协议，无法自动验证：确认之前会列出来，换内核后只确认服务启动与端口监听，请用实际客户端确认。其余协议如果连自检用的客户端配置都生成不出来，按握手失败处理（同样恢复旧内核），不会被当成「无法自动验证」放过。升级 sing-box 时，作客户端的就是新版 sing-box 本身，所以这项检查只能证明新内核自洽，不能证明旧版客户端、mihomo 或 Xray 客户端仍然兼容。
- **卸载**（菜单 `20`）会停止并删除 sing-box / Xray / nginx 服务、nginx 专用账号 `atr-nginx`、全部配置、用户与客户端文件、防火墙放行规则、端口跳跃规则和 `atr` 命令。不会删除：acme.sh 及其证书记录（卸载时可选择删除）、BBR 的 sysctl 配置、系统里已装的软件包。

## 目录与服务

```text
/etc/anytls-reality/
├── state.json            唯一事实来源（权限 600），所有配置由它渲染
├── anytls-reality.sh     脚本本体，/usr/bin/atr 指向这里
├── sing-box/  xray/      内核与配置
├── nginx/                独立 nginx 实例的配置
├── tls/                  证书
├── clients/  subscribe/  客户端配置与订阅文件
├── www/                  伪装站
├── backup/               每次变更前的备份
└── atr.log               脚本操作日志（安装、变更、回滚记录）
```

systemd 服务：`atr-sing-box`、`atr-xray`、`atr-nginx`，以及启用端口跳跃时用于开机恢复规则的 `atr-hop`。v1.2.7 增加 `atr-tls-recover` 依赖单元，在核心/nginx 启动前恢复中断的证书导入；该单元正常完成后显示 inactive (dead)，属于正常的一次性任务。sing-box / Xray 仍以 root 运行，但单元里只保留 `CAP_NET_BIND_SERVICE`，开启了 `NoNewPrivileges`、`PrivateTmp`、`ProtectHome`、`ProtectSystem=strict`，并且**整个安装目录 `/etc/anytls-reality` 对服务只读**（脚本、二进制、配置、state 都改不了；Xray 的日志也不再写文件而是进 journal，`atr log xray` 本来就读那里）。

nginx 是脚本自带的独立实例（配置在 `/etc/anytls-reality/nginx/`，由 `atr-nginx` 服务运行），不会修改系统自带 nginx 的配置。nginx 的 worker 进程以专用系统账号 `atr-nginx`（无登录、无家目录）运行；需要用到 nginx 但系统里没有时，脚本会通过包管理器安装它；刚装好的发行版 nginx 会自动启动并占用 80 端口，脚本会随即停止并取消它的开机自启。如果你的系统里本来就装有并在使用 nginx，不受影响。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `GITHUB_PROXY` | 给 `https://github.com/` 开头的下载地址加代理前缀（如 `https://example.com/`），默认直连；不影响 `api.github.com` 与 `raw.githubusercontent.com`。使用第三方代理等于信任该代理 |
| `ATR_RULESET_MIRROR` | 生成的 sing-box / mihomo 完整配置里，规则集等 GitHub 资源的下载镜像前缀。默认是第三方镜像 `https://gh-proxy.com/`（与 v2ray-agent 一致），客户端会经它下载规则集；介意的话设为空字符串，客户端将直连 GitHub |
| `ATR_SKIP_FIREWALL=1` | 不修改防火墙，端口需要自行放行 |
| `ATR_XRAY_VERSION=v26.3.27`、`ATR_SINGBOX_VERSION=v1.14.2` | 安装内核时固定版本，不取最新版。仍然要通过 GitHub API 的正式发布核对和 SHA256 校验 |
| `ATR_EXPECTED_SHA256=<64 位十六进制>` | 安装内核时用你自己从可信渠道核对得到的 SHA256 代替自动获取的校验值（API 返回的数据里没有该文件的校验值时使用）。它只补充校验值，不能代替正式发布核对，仍然需要能直连 `api.github.com` |
| `ATR_PUBLIC_IP=<IP>` | 指定本机公网地址：订阅链接用它，「公网出口」模式也直接用它禁止访问本机（不再联网探测）。探测不准时（NAT、CDN/反代、出站经代理）可以用它，或者在菜单 `11` → `6` 里手动补充 |
| `ATR_ALLOW_UNVERIFIED=1` | 取不到校验值时仍然安装（**不推荐**，下载内容的完整性与来源将无法保证）。默认行为是中止 |

防火墙会自动识别：已启用的 ufw、运行中的 firewalld，或默认策略为 DROP / REJECT 的 iptables。放行后会复核规则确实存在；识别到这三种防火墙、却放行失败（命令出错或复核不到规则）时，本次修改自动回滚，因为配置即使生效客户端也连不上，会明确提示失败；也可以用 `ATR_SKIP_FIREWALL=1` 自己管理防火墙。回滚按后端及 IPv4/IPv6（firewalld 则按永久/运行时）记录和删除本次操作前不存在的部分，原有部分保持不变；撤销日志在修改前同步到事务备份目录，进程中断后由 `atr recover` 重放。自动端口操作分别修改 firewalld 的永久和运行时配置，不做全局 reload。没有防火墙时不做任何提示。原生 nftables 的默认拒绝策略不在自动放行的支持范围内：配置照常生效，并给出可以直接执行的 `nft insert rule …` 命令。回收端口失败会明确报错并返回非零；如果新配置已经提交，会说明“配置已生效，但旧规则未完整回收”，需要管理员处理，不报告全部成功。

## 安全模型

- **内核下载**：下载之前先向 GitHub API 核对版本 tag 是正式发布（`draft` 与 `prerelease` 都是 false），不论这个版本来自 releases/latest、网页重定向、手动输入还是 `ATR_*_VERSION`；核对不了就中止，不会退回到「只看版本号格式」。这一步必须直连 `api.github.com`（不经过 `GITHUB_PROXY`，也没有跳过的开关）：纯 IPv6 的机器（2026-10-24 查询，`api.github.com` 没有 AAAA 记录）和出口 IP 被 GitHub API 限流（未认证每小时 60 次）的机器会装不上、也升级不了内核，需要先解决到 `api.github.com` 的连通性。校验值优先取自 GitHub API 的 `assets[].digest`（`api.github.com` 不经过 `GITHUB_PROXY`，即使下载代理不可信，校验值仍来自独立渠道），并且在解压、运行之前完成校验。取不到校验值时中止安装，不会运行未经校验的程序。jq 的引导下载固定为 1.7.1 并校验写死在脚本里的 SHA256。acme.sh 仍按其官方推荐的方式安装（`curl https://get.acme.sh | sh`），这一步信任 acme.sh 上游。
- **SOCKS5 入站**是明文代理：只放行来源白名单内的 IP 访问指定目标，其余一律拒绝；白名单为空会被拒绝，渲染时也不会生成放行规则。
- **进程命令行**：Linux 默认允许任何本机用户读取其他进程的命令行。脚本把全部 `jq` 调用接管了，`--arg` / `--argjson` 的值经由只有 root 能进入的私有临时文件交给 jq，命令行上只剩文件路径；私有临时目录建不出来、参数文件写不进去、或遇到无法这样转换的调用形式时，调用直接失败（返回非零），**不会**退回到把值放在命令行上执行。合并其他机器的订阅时，URL 里带着对等密钥，所以 curl 的 URL 经标准输入（`--config -`）交给它，命令行上只剩 `-fsS -m 15 --proto …` 这类不敏感的选项（URL 里的换行等控制字符会被拒绝，引号和反斜杠会被转义）。订阅目录里的文件名就是令牌，所以发布时复制文件用 shell 重定向而不是 `cp`，设置权限用只带目录路径的递归 `chmod`，结构校验用标准输入读文件，令牌不会出现在这些命令的命令行上；撤销时也不逐个删除以令牌命名的文件，而是按白名单重建目录（见「撤销收口」），被撤销的令牌同样不会出现。对等密钥更是根本不进文件系统路径：本机作为被合并方时，密钥写在 nginx 配置里（`atr_subscribe.conf`，权限 600），由 nginx 自己核对；文件按 `peer/<用户名>/<类型>` 存放，路径里没有密钥，所以创建目录也不需要把它交给任何外部命令（测试里对每一条外部命令的参数做了记录并核对）。Reality 公钥改用 openssl 推导，不再执行 `xray x25519 -i <私钥>`。命令行里直接写密码（`atr passwd 用户 新密码`）仍会出现在 `ps` 和 shell 历史里，请把密码参数写成 `-` 从标准输入读取。
  发布与撤销这条路径上，令牌和对等密钥不会出现在任何外部命令的参数里（测试里对每一条外部命令的参数做了记录并核对），这一项到此关闭。这条线之外还有三项已知、已接受的残留：① acme.sh 用 DNS API 签发或续签证书时，会在它自己调用的 curl / openssl 命令行里带上 Cloudflare Token 或阿里云密钥（第三方代码，本脚本改不了；请使用只授权单个域名 DNS 编辑的 Token、只有 DNS 权限的 RAM 子账号，能用 HTTP-01 时优先用 HTTP-01）；② 管理员自己写在命令行里的密码或 UUID（见上一句；`atr adduser 名 uuid` 的 UUID 目前不能从标准输入读取）；③ v1.2.1 及更早的版本每次发布订阅都会把对等密钥放进 `mkdir` 的命令行，升级不会自动更换它——如果当时服务器上有不受信任的本机用户，建议在菜单里重置一次对等密钥，再把新密钥告诉对端。
- **出口访问模式**（默认「公网出口」）：客户端经节点发出的连接，如果目的地是回环、私网、CGNAT、链路本地（含云厂商元数据 169.254.169.254）、组播/保留地址、IPv4 映射的 IPv6、ULA，或这台服务器自己所有网卡的地址（含公网 IP），一律拒绝；对域名目标，sing-box 先 `resolve` 再匹配（Xray 见下面的限制）。TCP 和 UDP 都生效，且排在 Socks5 入站的放行规则之前。本机网卡地址在每次应用配置时刷新；`atr restart` 发现网卡地址与记录的不一致（换了 IP、加了网卡）时，会先按新地址重新应用一次配置。**NAT 型 VPS**（腾讯云、阿里云、AWS、GCP 等）的公网地址不在网卡上，所以安装、`atr restart` 和菜单 `11` → `6` 会用 Cloudflare trace 探测本机公网地址（只接受合法 IP，失败时保留上次的结果），把它也列入禁止访问；探测超过 7 天没刷新时，打开菜单或执行 `atr status` 会提示一次。在 CDN/反代后面、或出站经过代理/隧道时探测值可能不对，请在菜单 `11` → `6` → `3` 手动补充本机地址（也可以用 `ATR_PUBLIC_IP` 指定，或在 `11` → `6` → `4` 关闭自动探测）。副作用：经由节点访问本机自己的公网 IP 或域名（订阅、伪装站）会被拒绝，这和非 NAT 机器上原有的行为一致。**DNS rebinding 已实测**（私有网络命名空间里用一个会改口的 DNS 服务器：第一次回答公网地址，之后回答 127.0.0.1，TTL 为 0）：sing-box 只解析一次，并且就用这次的结果拨号，不受影响；**Xray 原先的配置会被绕过**（路由检查解析一次，freedom 出站拨号前再解析一次，第二次拿到 127.0.0.1，请求直接打到了本机服务）。现在公网出口模式下 Xray 额外做两件事：① 它的**所有** DNS 服务器（包括「DNS 解锁」里自定义的那台）都带 `unexpectedIPs`（与路由规则同一份地址段），落在这些地址段里的解析结果在 DNS 层就被丢弃，路由检查和拨号前的再解析都经过它；② 直连出站用 `ForceIP`（写在 `streamSettings.sockopt.domainStrategy`，不再用已弃用的 `freedom.domainStrategy`），解析失败就直接失败，不再退回去按域名拨号（退回去等于交给系统解析器再解析一次，绕过过滤）。测试里保留了反例，用来证明新配置的拒绝不是空转：旧配置形态仍然会被绕过；DNS 解锁服务器不带过滤（v1.2.2 的写法）时，解锁规则命中的域名仍然会被绕过；过滤还在、但去掉 sockopt 的 `ForceIP` 时同样会被绕过——过滤和 `ForceIP` 缺一不可。以上在 Xray 26.3.27 与 26.10.21 上都测过；测 DNS 解锁时关掉了 Xray 的 DNS 缓存（它对 TTL 为 0 的回答也会缓存，攻击者可以去赌缓存过期的时机，过滤必须在最坏情况下也成立）。同时覆盖了 IPv4 映射的 IPv6 回答、回环地址排在前面的混合回答、`[::1]` 和只有 AAAA 记录的名字。需要强边界（共享账号、不可信用户）时，仍建议再用防火墙或网络命名空间限制出站。需要经节点访问本机或内网服务时选「允许内网访问」，只在信任所有节点用户时这样做。
- **订阅文件**含全部用户的节点凭据：`/etc/anytls-reality` 为 `root:atr-nginx` 710，`subscribe/` 为 750，文件 640，本机其他用户既不能列目录也不能读文件；没有 nginx 需求时整个目录只有 root 能进入。发布订阅文件的顺序是固定的：先清除已被撤销的内容 → 令牌落到 state → 确认 nginx 已是专用账号模型和当前的订阅配置格式（旧安装会先迁移/重新应用，失败就不发布，绝不降级成「所有人可读」）→ 在每次运行独立的 `mktemp` staging 目录里生成全部文件，逐步检查退出状态 → 校验每个用户的文件齐全、JSON 结构合法 → 设好属主与权限 → 整体换入，旧令牌对应的文件随旧目录一起消失。`atr sub`、`atr restart`、更换订阅链接都走这条路径，所以显示出来的链接一定是已经生效的，被更换的旧链接一定已经失效。
- **并发与失败处理**：改配置（`applyStaged`）、发布订阅、补发令牌、崩溃恢复共用同一把 `flock` 事务锁，锁是可重入的（外层已持锁时内层不会死锁）；拿不到锁、没有 `flock`、锁文件打不开时一律中止，不会在没有锁的情况下修改。交互提示期间不占着锁，而是在提交时核对 `state.json` 的指纹：从读取快照到提交之间如果别的操作改过配置，本次操作会被拒绝并提示重新来过，而不是用旧快照覆盖对方刚改的密码和令牌。订阅发布期间持有同一把锁，所以所有文件来自同一份 state，两个发布进程不会共用暂存目录。发布过程中任何一步失败（磁盘写满、复制/编码/渲染失败、校验不通过、换入失败、令牌写不进 state）都不会发布残缺的文件，并且会关闭订阅；关闭后会再确认目录里确实没有文件了（复查本身失败也按「没删干净」处理，不会当成已经清空），删不掉（例如文件系统只读）时改为停止 `atr-nginx`，确保旧订阅不会继续被提供，停不掉则明确报错。
- **配置事务**（R-02）：落盘前先完整备份当前配置并逐字节核对，再写事务标记，两者没有确认成功就不动 live 文件；核心/nginx 配置和 state 都是「同目录临时文件 + rename」并核对内容；服务和端口验证通过之后，还要再核对一遍落盘的 state/配置确实就是候选内容。任何一步失败就回滚；回滚（逐个文件恢复并核对）本身失败时**保留**事务标记和备份，下次运行脚本会再次尝试恢复，而不是报告成功。标记在成功提交后删不掉时同样明确报错（否则下次运行会把配置回滚到旧版本）。重启服务失败、应该停止的服务没有停下，都算失败，并显示该服务最近的日志。事务标记还在时，任何修改、重启和发布都会被拒绝，新事务不会覆盖它；只读命令 `atr status` / `atr show` / `atr log` 照常可用。排除问题后用 `atr recover` 重试恢复；确认不再需要时用 `atr recover --abandon` 放弃（事务标记改名归档为 `.txn.abandoned.<时间>`，备份目录保留，之后以磁盘上现有的配置为准）。
- **撤销收口**（R-03）：配置提交之后、仍持有同一把锁时，脚本立刻按新的 state 清除发布目录里已失效的内容（旧令牌对应的文件、已删除用户的文件、关闭对等密钥后的 `peer/`、订阅关闭后的整个目录），这一步按白名单重建发布目录：只把仍然有效的文件复制进一个新目录再整体换入，旧目录按固定路径删除，所以被撤销的令牌（以及旧版布局里以对等密钥命名的目录）不会出现在任何命令的命令行上，仍然有效的文件也不会被先删掉；不渲染、不联网，不依赖随后的文件发布。对等密钥由 nginx 配置核对，配置提交并重启 nginx 的那一刻旧密钥就失效。重建失败就清空整个发布目录（下一次发布再恢复有效的链接），连清空也做不到就停止 nginx；nginx 也停不掉，才报告「撤销未完成」。后面的客户端/订阅文件生成失败，只会让**新**链接暂时不可用，不会让**旧**链接复活，并且失败会一路返回到命令行/菜单顶层，不再显示「已重新生成」。进程在提交与清理之间被中断的话，下次启动脚本时会对账并补做清除。每次启动还会按磁盘上的实际状态检查已发布的内容是否完整（每个用户应有的全部订阅类型——sing-box 完整配置只在该用户有 sing-box 节点时才有、对等分享开着时的全部 peer 文件、nginx 订阅配置的格式）：发布失败、换入目录的两步之间被中断、或者刚从旧版 `peer/<密钥>/` 布局升级，都会在同一把锁里按当前配置重新发布；失败只提示，下一次运行会再试（开机时的 `apply-hop` 只清除不发布，留给下一次运行）。订阅或对等分享已关闭时，不会因此被重新打开。也不会把换入时留下的旧目录挪回来——它可能正装着刚被撤销的令牌。
- **以 root 运行的内核**：服务的沙箱阻止它直接改写安装目录（也就改不了管理脚本）和系统目录（`ProtectSystem=strict`，cron 等也写不了），也不能创建 Unix 套接字（`RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK`），所以连不上 systemd / D-Bus 去启动沙箱之外的任务——2026-10-25 的实机审计证明，只有只读目录时，root 服务仍能请宿主的 systemd 代它写入安装目录，v1.2.6 因此加了这两项。但它仍以 root 运行，能读取宿主上的大多数文件：内核一旦被攻陷，仍应按已获得 root 权限处理，这不能替代及时升级内核（菜单 `16`）。sing-box 需要 AF_NETLINK（监控网卡），两个内核都不需要 AF_UNIX（用 `strace` 实测）。改用独立的低权限服务账号要处理低端口、TLS 私钥读取、内核更新和证书续签的权限，改动面大，对单人自用的脚本风险大于收益，暂不做。
- **导入已有证书（v1.2.7）**：新旧文件和 manifest 先写入私有暂存目录并核对、同步，再持久化 `.tls-txn` 撤销标记，之后才替换 live 私钥和证书。普通失败立即恢复；SIGKILL 中断后，下次运行 `atr` 或开机时的 `atr-tls-recover` 依赖单元恢复旧文件，完成前不启动需要证书的管理服务。恢复失败保留标记和备份并阻止修改，`atr recover` 可重试；证书事务不支持 `recover --abandon`。证书指纹写入 state，路径不变而证书改变时也会重启核心。导入文件事务与之后的配置事务分别提交；之后的配置变更失败不撤销已经成功提交的证书导入。这是两文件的可恢复事务，不是双文件原子 rename，写入两者之间存在暂态窗口；非脚本管理的其他证书读取者须自行协调。这项事务只覆盖本脚本导入，acme.sh 自身的证书写入仍由上游负责。

## 已知限制与注意事项

- 与 v2ray-agent 的服务名和目录互相独立，但同机使用时端口会冲突（443、申请证书用的 80 等），请为本脚本选择不同端口；依赖 nginx 的协议无法与 v2ray-agent 真正共存。
- 菜单 `18` 的第三方 `tcpx.sh` 包含 DD 重装系统功能（会清空整块磁盘），脚本会在运行前二次确认；不需要时选择「仅启用原版 BBR+FQ」即可。
- 容器或受限虚拟化环境通常不允许修改内核参数，内置 BBR 会在读回验证失败时撤销写入并提示。
- 没有域名证书时仍可以选择 HTTP 明文订阅（会二次确认，并提示风险）；服务器之间的对等订阅则只支持 HTTPS。
- Xray 的 geoip/geosite 数据文件是从 GitHub 下载的，没有做完整性校验（它们不是被执行的程序，但会影响路由）。
- 从 v1.2.0 升级到 v1.2.1：安装依赖时会自动补装 `flock`（util-linux，主流发行版默认自带）；如果它之后被卸载，所有会修改配置的操作都会拒绝执行，重新安装 util-linux 即可。如果提示「配置已被另一个操作修改过」，重新执行一次即可。完整客户端配置里的控制接口 `secret` 为空时不再生成控制接口（正常情况下 secret 总是有的）。
- 从 v1.2.6 升级到 v1.2.7：替换脚本后执行一次 `atr restart`，安装/更新 `atr-tls-recover` 依赖单元。已有配置和证书路径保持兼容；有未完成事务时先执行 `atr recover`。v1.2.6 及更早已发生的无日志证书中断不会自动猜测恢复，需要管理员核对旧 `.import.*` 备份。Xray 26.10.21 的上游互通问题仍然存在，本版本保留警告和升级失败自动回退。

- 从 v1.2.5 升级到 v1.2.6：sing-box / Xray 的单元文件会更新，下一次应用配置或 `atr restart` 时两个内核会各重启一次。选了「公网出口」的 NAT 型 VPS，请执行一次 `atr restart`（或在菜单 `11` → `6` → `2` 里探测），把本机公网地址加进禁止列表；之后打开菜单时如果提示「还没有探测过」，也是这个原因。防火墙放行失败现在会回滚本次修改（见「环境变量」下面的防火墙说明）。
- 从 v1.2.4 升级到 v1.2.5：不需要手动处理。升级后第一次运行 `atr` 时，如果已发布的订阅不完整（例如 v1.2.4 在开机任务里撤下了旧布局、之后一直没有重新发布），会自动补发一次。
- 从 v1.2.2 升级到 v1.2.4：安装和升级内核需要能直连 `api.github.com`（见「安全模型」的「内核下载」）。有未完成的事务时只读命令仍可用，新增 `atr recover [--abandon]`。安装和换内核时，Naive、XHTTP 等无法自动验证的协议不算失败，只列出来（v1.2.3 曾把它们当作验收失败，这类节点的内核因此无法升级或回退；`ATR_ALLOW_UNTESTED_CORE` 已取消）。如果订阅还是 v1.2.1 及更早的 `peer/<密钥>/` 布局，第一次运行任何 `atr` 命令时就会按新布局重新发布一次（nginx 重启一次）；对其他机器的接口不变。
- 从 v1.2.1 升级到 v1.2.2：升级后第一次发布订阅时，如果订阅的 nginx 配置还是旧格式，会先按当前 state 重新应用一次配置（nginx 会重启一次），然后按新的目录布局（`peer/<用户名>/`）发布，旧布局 `peer/<密钥>/` 随旧目录一起消失。对等分享对其他机器的接口（`/s/peer/<密钥>/<用户>/<类型>`）没有变化，对方不需要改动。`/etc/anytls-reality/nginx/conf.d/atr_subscribe.conf` 现在是 600 权限（里面有对等密钥）。选了「公网出口」的 Xray 节点，DNS 与直连出站的写法改变了（见上面「出口访问模式」）。HTTP 明文订阅的两处提示现在明确写出「令牌和全部节点凭据会明文经过网络」。
- **Xray 26.10.21 与 sing-box 1.14.x 客户端握手失败**：26.10.21 于 2026-10-21 发布，2026-10-24 用 GitHub API 核对，它是正式发布（`prerelease` 为 false），也是 API 的 latest，所以正式发布核对拦不住它。我在沙箱里用该版本做 VLESS+Reality+Vision 回环自检（客户端是 sing-box 1.14.2），对所有目标都是 `reality verification failed`；同样的测试用 Xray 26.3.27 全部通过。发布说明里没有提到 Reality 的改动（这是一次紧急的根证书更新，用 Go 1.27.3 编译，作者说月底再发 stable），原因我没有追到上游；2026-10-25 的实机审计在 sing-box 1.14.4 上也复现了同样的失败。v1.2.6 起，选到这个版本时（安装、升级、回退）会先提示这个已知问题；自检失败的提示里也会说明可能是内核版本组合的问题。新装 Xray 节点建议固定版本：`ATR_XRAY_VERSION=v26.3.27 bash anytls-reality.sh`。已经在用 26.3.27 的节点升级到 26.10.21 时，换内核后的互通检查会握手失败并自动恢复旧内核（前提是本机有 sing-box 可以作自检客户端；纯 Xray 节点会提示「无法自动验证」，这时请不要确认升级）。已经装上 26.10.21 的，用菜单 16（core 管理）→ 2（回退）退到 26.3.27，或者先只用 sing-box 作服务端。
- 已在沙箱里用多个并发进程、故障注入（文件复制 / `base64` / `mktemp` / `mv` / `find` 失败、磁盘写满、渲染失败、令牌写入失败；事务里分别让 state 写入、备份、事务标记、核心配置写入失败，让恢复也失败，让写入「成功」但内容被悄悄写坏）测试过上述行为，并用真实的 nginx 核对撤销后旧链接/旧对等密钥确实返回 404；没有在真实多用户 VPS、真实 systemd 和 nginx 降权下验证。
- 从 v1.1.0 升级到 v1.2.0：老安装第一次打开菜单时会被问一次出口访问模式，回车 = 保持现状（允许内网访问），所以不选也不会改变任何行为；已经选过就不再问。控制接口的 `secret` 是新生成的，旧的客户端完整配置需要重新导入。对等订阅里的 HTTP 条目不再生效。

## 致谢

- [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)：界面、菜单结构与交互逻辑的来源
- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)、[XTLS/Xray-core](https://github.com/XTLS/Xray-core)、[acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh)、[ylx2016/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed)

## 许可证

本项目派生自以 AGPL-3.0 发布的 v2ray-agent，因此同样以 [GNU AGPL-3.0](LICENSE) 授权。

## 免责声明

本项目仅供学习与技术研究。使用者应遵守所在地区的法律法规，因使用本项目产生的一切后果由使用者自行承担。
