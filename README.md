# luci-app-xc — Xray 节点切换与分流管理器 (OpenWrt LuCI Web 插件)

`luci-app-xc` 是运行在 OpenWrt / ImmortalWrt 路由器上的轻量级 Xray 客户端 Web 管理插件。它严格遵循 OpenWrt 官方现代 LuCI 规范开发，把多个 VLESS REALITY 和本地 NaiveProxy SOCKS 节点统一管理，提供直观的 Web 控制面板与强大的命令行工具。

## 核心特性

- **现代 LuCI Web 控制台**：基于 OpenWrt 21.02+ / 22.03+ / 23.05+ / 24.10 现代 JavaScript 视图与 rpcd 架构，无需刷新页面即可实现实时动态交互。
- **手动切换指定节点**：一键切换出口节点，自动执行 Xray 配置校验、平滑重启服务、双端口健康检查；遇异常自动回滚上一配置。
- **可视化节点管理**：
  - 支持 **VLESS REALITY**（SNI、Public Key、Short ID、Fingerprint、Flow xtls-rprx-vision）及 **NaiveProxy SOCKS5** 协议节点。
  - 在 Web 界面直接**添加新节点**、编辑参数与删除节点，持久化维护 `/etc/xc/nodes.json`。
- **全链路代理测速**：
  - 支持**手动刷新全部测速**及**单节点独立测速**。
  - 为节点生成独立临时监听并向真实目标（默认 `gstatic.com/generate_204`）请求，测量真实代理链毫秒级延迟，非单纯 TCP ping。
- **固定分流与兜底机制**：
  - `proxy` 固定承担 OpenAI, YouTube, Twitter, Telegram, Google, Netflix 等 geosite 分流。
  - 当前手动选择的节点（`proxy-selected`）承担普通海外流量与最终 fallback。
  - 严格的 DNS 防泄露：DoH (1.1.1.1) 查询经代理发送，禁用本地 DNS fallback。
- **双入站端口支持**：
  - `LAN_IP:7890` (SOCKS5 / SOCKS5h)
  - `LAN_IP:10809` (HTTP 代理)

---

## 插件界面效果预览

可以在本地双击打开项目中的 `preview.html` 文件，直接体验 Web 交互效果。

---

## 项目结构 (标准 LuCI 规范)

```text
luci-app-xc-lite/
├── Makefile                               # OpenWrt 官方包构建规则
├── preview.html                           # 交互式 Web UI 原型预览
├── htdocs/
│   └── luci-static/
│       └── resources/
│           └── view/
│               └── xc/
│                   └── overview.js        # 现代 LuCI JS 客户端前端渲染视图
├── root/
│   ├── etc/
│   │   ├── config/
│   │   │   └── xc                         # UCI 配置文件
│   │   ├── init.d/
│   │   │   └── xc-xray                    # OpenWrt procd 守护进程管理脚本
│   │   ├── uci-defaults/
│   │   │   └── 80_luci-app-xc             # 安装后初始化与权限配置脚本
│   │   └── xc/
│   │       ├── settings.example.json      # 运行设置模板
│   │       └── nodes.example.json         # 节点清单模板
│   └── usr/
│       ├── bin/
│       │   └── xc                         # 核心 CLI 管理脚本 (支持 JSON/RPC 模式与命令行模式)
│       ├── libexec/
│       │   └── rpcd/
│       │       └── luci.xc                # rpcd 后端微服务脚本 (提供 Web RPC 接口)
│       └── share/
│           ├── acl.d/
│           │   └── luci-app-xc.json       # LuCI ACL 安全权限声明
│           └── luci/
│               └── menu.d/
│                   └── luci-app-xc.json   # LuCI Web 菜单项声明 (挂载至 服务 > xc 节点分流)
├── po/                                    # 国际化语言包 (i18n)
│   ├── templates/
│   │   └── xc.pot
│   └── zh_Hans/
│       └── xc.po
├── examples/                              # 配置示例
├── docs/                                  # 架构文档
└── README.md
```

---

## 编译与安装指南

### 方式一：在 OpenWrt 源码树中编译

1. 将本仓库下载或克隆至 OpenWrt 源码的 `package` 目录：
   ```sh
   git clone https://github.com/deanzai/luci-app-xc-lite.git package/luci-app-xc
   ```
2. 进入 OpenWrt 编译配置：
   ```sh
   make menuconfig
   ```
3. 在菜单中勾选：
   ```text
   LuCI --->
     3. Applications --->
       <*> luci-app-xc......... LuCI Web interface for xc (Xray node switcher)
   ```
4. 执行编译：
   ```sh
   make package/luci-app-xc/compile V=s
   ```
5. 将编译生成的 `.ipk` 或 `.apk` 包传输至路由器并安装。

### 方式二：手动直接部署至路由器

将仓库中的文件按层级拷贝至路由器的对应目录：
```sh
# 复制控制与服务文件
cp -r root/* /
cp -r htdocs/* /

# 设置执行权限
chmod +x /usr/bin/xc /usr/libexec/rpcd/luci.xc /etc/init.d/xc-xray

# 重启 rpcd 与 uhttpd
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

---

## 命令行用法 (CLI)

除了在 LuCI 网页端操作外，底层的 `xc` 命令依然完整保留并获得增强：

```sh
xc status        # 输出当前服务运行状态 (JSON)
xc list          # 列出所有节点、类型及完整代理链延迟
xc <id>          # 切换出口到指定编号节点 (例如: xc 1)
xc switch <id>   # 同上
xc probe <id>    # 独立探测指定节点的延迟 (输出 JSON)
xc current       # 查看当前生效的节点
xc test          # 检查 SOCKS5h 和 HTTP 出口连通性
xc rollback      # 恢复上一份配置
```

---

## 许可证

[MIT License](LICENSE)
