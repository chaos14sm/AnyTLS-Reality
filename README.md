# AnyTLS-Reality

安装目录结构(仿 v2ray-agent):

/etc/anytls-reality/
├── anytls-reality.sh     # 脚本本体(自动复制)
├── reality_key           # Reality 密钥对(600 权限)
├── sing-box/
│   ├── sing-box          # 稳定版核心
│   └── config.json       # AnyTLS + Reality 入站配置
└── client/               # 自动生成的客户端配置
    ├── sing-box-用户名.json
    └── mihomo-用户名.yaml

稳定版优先：通过 GitHub releases/latest API 获取版本(自动排除 beta/rc 预发布)，失败时依次降级为重定向探测 → 手动输入版本号
atr 注册：安装完成后自动复制脚本到 /etc/anytls-reality/ 并软链到 /usr/bin/atr,效果等同 vasma;管道方式执行(curl | bash)会安全跳过注册而不会误复制
客户端 JSON 生成：安装、改密、添加用户后自动生成并显示完整的 sing-box 客户端配置(mixed 入站 2080 + anytls 出站 + utls chrome 指纹 + reality 公钥)和 mihomo YAML 片段
一致性保护：每次改动配置先用 sing-box check 校验再重启；密钥文件只在配置写入成功后才落盘，避免“客户端公钥与服务端私钥不匹配”的坑
其他细节：修改 SNI/端口/密钥/用户后自动重新生成全部客户端配置并提示需同步；删除用户保留至少一个；实时日志 Ctrl+C 优雅返回菜单(SINGINT trap);配置全部用 jq 构建，密码含特殊字符不会破坏 JSON

使用方法
wget -P /root -N --no-check-certificate "https://github.com/chaos14sm/AnyTLS-Reality/raw/refs/heads/main/anytls-reality.sh"
chmod 700 /root/anytls-reality.sh
/root/anytls-reality.sh
# 安装后任意位置输入 atr 打开管理菜单
