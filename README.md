# AnyTLS-Reality

sing-box / Xray-core 一键管理脚本，**支持 AnyTLS + Reality**。

界面、菜单编号和操作习惯参考并派生自 [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)（v2ray-agent 目前没有 AnyTLS + Reality 这个组合），安装后直接输入 `atr` 进入管理菜单。本项目是独立的派生作品，与 v2ray-agent 官方无关联。

> **项目状态**：开发期间在隔离沙箱中，用真实的 sing-box / Xray / mihomo / nginx 二进制做过端到端验证（包括 AnyTLS + Reality 的回环握手）。下列环节在沙箱里是用桩替代的，**尚未逐项在真实服务器上验证**：systemd 服务管理、ufw / firewalld / iptables 放行与端口跳跃、cron 定时任务、acme.sh 真实签发与 DNS API、WARP 注册、IPv6 专属流程、RHEL 系 + SELinux、arm64。建议先在测试机上试用，遇到问题请到 Issues 反馈。

## 特性

- **5 个预设组合排在最前**：VLESS+Reality+Vision、AnyTLS+Reality、Tuic、Hysteria2、Naive；v2ray-agent 支持的其他协议在「任意组合安装」里列出
- **sing-box 排第一，Xray-core 排第二**
- **AnyTLS + Reality 一键安装**：安装 sing-box → 询问端口与 Reality SNI（推荐列表 / 自定义输入 / TLS 1.3 可达性检测）→ 生成密钥对 → 配置 AnyTLS 入站使用 Reality → systemd 服务 → 防火墙放行 → 回环握手自检
- **只用稳定版内核**：`GitHub releases/latest` API（自动排除 alpha / beta / rc）→ 失败时降级为重定向探测 → 再失败则手动输入版本号；下载后做 SHA256 校验
- **配置一致性保护**
  - 所有配置由 `state.json` 经 jq 渲染生成（密码含特殊字符也不会破坏 JSON）
  - 每次改动：渲染 → `sing-box check` / `xray run -test` / `nginx -t` → 备份 → 落盘 → 重启 → 验证端口监听，失败自动回滚
  - 密钥文件只在配置校验通过、事务提交时才落盘，避免「客户端公钥与服务端私钥不匹配」
- **客户端配置自动生成**：安装、改密、添加用户、改 SNI / 端口 / 密钥后自动重新生成全部客户端文件，并提示需要同步到客户端
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
| 5 | REALITY 管理 | 查看参数、修改 SNI、修改端口、重置密钥对与 Short ID、自检 |
| 6 | Tuic 管理 | 重新配置、卸载、端口跳跃 |
| 7 | 用户管理 | 查看账号 / 订阅、添加 / 删除用户、重置密码或 UUID、重新生成全部客户端配置 |
| 8 | 伪装站管理 | 模板站点、302 重定向（需要 nginx） |
| 9 | 证书管理 | 立即续签、重新申请（HTTP-01 / DNS API）、导入已有证书、acme 日志 |
| 10 | CDN 节点管理 | |
| 11 | 分流工具 | WARP（IPv4 / IPv6）、IPv6、Socks5、DNS、SNI 反向代理 |
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

非交互安装（`--port` 缺省为 443，被占用则随机；`--sni` 缺省为 `www.microsoft.com`；`--user` 缺省为随机名）：

```bash
atr install-anytls-reality --port 443 --sni dl.google.com --user alice
```

要点：

- **客户端必须开启 uTLS**，否则 sing-box 会报 `uTLS is required by reality client`。脚本生成的 sing-box 配置已默认开启。
- 公钥、Short ID、SNI 必须与服务端一致；公钥填错时客户端会报 `reality verification failed`。`atr selfcheck`（菜单 5 → 5）会用 sing-box 客户端对本机做一次回环握手来检测这类问题。
- **mihomo / Clash.Meta 官方不支持 AnyTLS + Reality**，所以这个协议只输出 sing-box JSON 和参数说明，没有分享链接，也没有 mihomo YAML。
- Reality 目标域名（SNI）：推荐列表前 5 个（`dl.google.com`、`www.apple.com`、`download-installer.cdn.mozilla.net`、`www.python.org`、`www.amd.com`）证书链较短，sing-box 与 Xray 作服务端都能完成握手。其余域名（如 `www.microsoft.com`、`addons.mozilla.org`）在 **Xray 作服务端**时可能握手失败，脚本会在检测时给出提示；sing-box 作服务端不受影响。
- 修改 SNI：菜单 `5` → `2`，或 `atr sni <域名[:端口]>`。只改目标域名，密钥对保留，所有客户端需同步新的 SNI。

## 命令行

```text
atr                                打开交互式管理菜单
atr install-anytls-reality [选项]  非交互一键安装 AnyTLS+Reality
      --port N        监听端口(默认 443，被占用则随机)
      --sni host[:p]  Reality 目标域名(默认 www.microsoft.com)
      --user name     首个用户名(默认随机)
atr status                         查看服务与端口状态
atr show [用户] [1]                查看账号(第二个参数 1 同时显示二维码)
atr sub [用户]                     查看订阅链接
atr selfcheck                      自检(回环握手测试)
atr sni <host[:port]> [--force]    修改 Reality 目标域名(SNI)
atr passwd <用户> [新密码]         重置密码(不给则随机)
atr adduser <用户> [uuid] [密码]   添加用户
atr deluser <用户>                 删除用户(至少保留一个)
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
| `sing-box-full.json` | 带分流规则的 sing-box 完整配置 |
| `mihomo-proxies.yaml` | mihomo / Clash.Meta 的 `proxies` 片段 |
| `mihomo-full.yaml` | mihomo / Clash.Meta 完整配置 |
| `naive-client.json` | NaiveProxy 官方客户端配置（安装了 Naive 时） |

Naive 说明：sing-box 的 naive 出站需要 `libcronet.so` 与二进制放在同一目录（官方压缩包里带有；本脚本只安装单个二进制，服务端的 naive 入站不依赖它）。客户端是否带这个库因人而异，所以脚本对 Naive 只提供 `naive+https://` 链接和 NaiveProxy 官方客户端 JSON，不生成 sing-box 出站；mihomo 不支持 Naive。

订阅：菜单 `7` → `2` 启用后（需要 nginx）可用一条链接导入全部节点；订阅令牌可重置，旧链接立即失效。

## 更新与卸载

- **更新脚本**（菜单 `17`）默认从本仓库的 raw 地址下载，下载后会检查 `bash -n` 语法和脚本标识，通过后才替换，并把旧版本备份为 `anytls-reality.sh.prev`。在菜单里改过的地址会被记住（保存在 `/etc/anytls-reality/script_url`），优先于默认值。
- **fork 后使用自己的地址**：修改脚本开头的 `ATR_SCRIPT_URL_DEFAULT`，或在菜单 `17` 里输入你自己的 raw 地址。
- **更新内核**：菜单 `16`，只会升级到稳定版，也可以回退。
- **卸载**（菜单 `20`）会停止并删除 sing-box / Xray / nginx 服务、全部配置、用户与客户端文件、防火墙放行规则、端口跳跃规则和 `atr` 命令。不会删除：acme.sh 及其证书记录（卸载时可选择删除）、BBR 的 sysctl 配置、系统里已装的软件包。

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

systemd 服务：`atr-sing-box`、`atr-xray`、`atr-nginx`，以及启用端口跳跃时用于开机恢复规则的 `atr-hop`。

nginx 是脚本自带的独立实例（配置在 `/etc/anytls-reality/nginx/`，由 `atr-nginx` 服务运行），不会修改系统自带 nginx 的配置。需要用到 nginx 但系统里没有时，脚本会通过包管理器安装它；刚装好的发行版 nginx 会自动启动并占用 80 端口，脚本会随即停止并取消它的开机自启。如果你的系统里本来就装有并在使用 nginx，不受影响。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `GITHUB_PROXY` | 给 `https://github.com/` 开头的下载地址加代理前缀（如 `https://example.com/`），默认直连；不影响 `api.github.com` 与 `raw.githubusercontent.com`。使用第三方代理等于信任该代理 |
| `ATR_RULESET_MIRROR` | 生成的 sing-box / mihomo 完整配置里，规则集等 GitHub 资源的下载镜像前缀。默认是第三方镜像 `https://gh-proxy.com/`（与 v2ray-agent 一致），客户端会经它下载规则集；介意的话设为空字符串，客户端将直连 GitHub |
| `ATR_SKIP_FIREWALL=1` | 不修改防火墙，端口需要自行放行 |

防火墙会自动识别：已启用的 ufw、运行中的 firewalld，或默认策略为 DROP / REJECT 的 iptables。

## 已知限制与注意事项

- 与 v2ray-agent 的服务名和目录互相独立，但同机使用时端口会冲突（443、申请证书用的 80 等），请为本脚本选择不同端口；依赖 nginx 的协议无法与 v2ray-agent 真正共存。
- 菜单 `18` 的第三方 `tcpx.sh` 包含 DD 重装系统功能（会清空整块磁盘），脚本会在运行前二次确认；不需要时选择「仅启用原版 BBR+FQ」即可。
- 容器或受限虚拟化环境通常不允许修改内核参数，内置 BBR 会在读回验证失败时撤销写入并提示。

## 致谢

- [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)：界面、菜单结构与交互逻辑的来源
- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)、[XTLS/Xray-core](https://github.com/XTLS/Xray-core)、[acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh)、[ylx2016/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed)

## 许可证

本项目派生自以 AGPL-3.0 发布的 v2ray-agent，因此同样以 [GNU AGPL-3.0](LICENSE) 授权。

## 免责声明

本项目仅供学习与技术研究。使用者应遵守所在地区的法律法规，因使用本项目产生的一切后果由使用者自行承担。
