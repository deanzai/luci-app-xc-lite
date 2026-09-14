# luci-app-xc — Xray 节点切换与分流管理器 (OpenWrt LuCI Web 插件)

`luci-app-xc` 是运行在 OpenWrt / ImmortalWrt 路由器上的轻量级 Xray 客户端 Web 管理插件。它严格遵循 OpenWrt 官方现代 LuCI 规范开发，把多个 VLESS REALITY 和本地 NaiveProxy SOCKS 节点统一管理，提供直观的 Web 控制面板与强大的命令行工具。

## 核心特性

- **现代 LuCI Web 控制台**：基于 OpenWrt 21.02+ / 22.03+ / 23.05+ / 24.10 现代 JavaScript 视图与 rpcd 架构，无需刷新页面即可实现实时动态交互；主界面直观展示插件版本号。
- **全体系 UCI 统筹持久化**：遵循 OpenWrt 官方标准配置规范，将节点与全局运行参数收敛于 `/etc/config/xc`，支持固件升级无损保留配置 (`sysupgrade`)。
- **保护 Flash 寿命 (tmpfs 内存盘)**：生成的 Xray 运行时配置直接写入内存盘 `/var/etc/xc/config.json`，消除频繁切换节点造成的闪存磨损隐患，同时提供兼容软链接。
- **系统日志级别与连接流水智能控制**：
  - 深度联动 Xray 的 `access` 与 `loglevel` 机制；
  - 日常使用选择 `warning` 自动静默连接流水，彻底消除系统日志 (`logread`) 刷屏；
  - 故障排查时选择 `info` 实时捕获每笔连接来源、域名嗅探与路由分流走向 (`[socks-in -> proxy]`)；
  - 保存全局配置自动平滑重载 Xray 核心生效，无需手动重启。
- **手动切换指定节点**：一键切换出口节点，自动执行 Xray 配置校验、平滑重启服务、双端口健康检查；遇异常自动回滚上一配置。
- **可视化节点管理**：
  - 支持 **VLESS REALITY**（SNI、Public Key、Short ID、Fingerprint、Flow xtls-rprx-vision）及 **NaiveProxy SOCKS5** 协议节点。
  - 在 Web 界面直接**添加新节点**、编辑参数与删除节点。
- **全链路代理测速**：
  - 支持**手动刷新全部测速**及**单节点独立测速**。
  - 为节点生成独立临时监听并向真实目标（默认 `gstatic.com/generate_204`）请求，测量真实代理链毫秒级延迟，非单纯 TCP ping。
- **固定分流与兜底机制**：
  - `proxy` 固定承担 OpenAI, YouTube, Twitter, Telegram, Google, Netflix 等 geosite 分流。
  - 当前手动选择的节点（`proxy-selected`）承担普通海外流量与最终 fallback。
  - 严格的 DNS 防泄露：DoH (1.1.1.1) 查询经代理发送，禁用本地 DNS fallback。
- **双入站端口支持**：
  - `0.0.0.0:7890` (SOCKS5 / SOCKS5h)
  - `0.0.0.0:10809` (HTTP 代理)

---

## 插件界面效果预览

可以在本地双击打开项目中的 `preview.html` 文件，直接体验 Web 交互效果。

---

## 项目结构 (标准 LuCI 规范)

```text
luci-app-xc-lite/
├── Makefile                               # OpenWrt 官方包构建规则 (v1.0.16-1)
├── build.sh                               # 自动化构建打包脚本 (生成 IPK 与 APK)
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
│   │   │   └── xc                         # UCI 配置文件 (全局参数与节点配置中枢)
│   │   ├── init.d/
│   │   │   └── xc                         # OpenWrt procd 守护进程管理脚本
│   │   ├── uci-defaults/
│   │   │   └── 80_luci-app-xc             # 安装后初始化、权限与自动迁移脚本
│   │   └── xc/
│   │       ├── settings.example.json      # 运行设置模板
│   │       └── nodes.example.json         # 节点清单模板
│   └── usr/
│       ├── bin/
│       │   └── xc                         # 核心 CLI 管理脚本 (支持内存盘配置生成与平滑回滚)
│       ├── lib/
│       │   └── lua/
│       │       └── luci/
│       │           ├── controller/
│       │           │   └── xc.lua         # LuCI 控制器与无阻塞无死锁管道保护
│       │           └── view/
│       │               └── xc/
│       │                   └── overview.htm # LuCI 模板视图 (老版本兼容与现代化防遮挡)
│       ├── libexec/
│       │   └── rpcd/
│       │       └── luci.xc                # rpcd 后端微服务脚本 (提供 Web RPC 接口与平滑重载)
│       └── share/
│           ├── acl.d/
│           │   └── luci-app-xc.json       # LuCI ACL 安全权限声明
│           └── luci/
│               └── menu.d/
│                   └── luci-app-xc.json   # LuCI Web 菜单项声明 (挂载至 服务 > xc 节点分流)
├── scripts/
│   ├── verify.sh                          # 自动化先验后发质量门禁脚本 (本地 + Staging 双道门禁)
│   └── release.sh                         # 全量灰度发布与生产同步流水线脚本
├── po/                                    # 国际化语言包 (i18n)
├── examples/                              # 配置示例
├── docs/                                  # 架构文档与测试规范
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

## 质量自测套件与先验后发门禁 (Quality Gate & Testing)

本项目建立了严密的分层自测与发布门禁工作流，严格禁止未经测试的代码直接发布上线：

```text
[代码修改] ──► [本地规范与沙箱自测 (verify.sh --local)] ──► [自动构建编译 (build.sh)]
                  │ (全部 PASS)                               │
                  ▼                                           ▼
[同步生产路由器 (93.94, 13.1)] ◄── (全部 PASS) ── [Staging 验证机真机回归 (verify.sh --staging)]
```

### 1. 运行本地自动化自测 (Local Tests)
在开发过程中随时执行本地快速检查（包含 CRLF 换行校验、Lua 语法编译、依赖项静态检查、模态框防遮挡规则、RPCD 沙箱模拟）：
```sh
./scripts/verify.sh --local
```

### 2. 运行 Staging 预发布机真机回归测试 (Staging Live Tests)
对预发布测试路由器（`192.168.6.1`）执行真实网络探活与组件回归测试：
```sh
./scripts/verify.sh --staging
```

### 3. 一键流水线发布 (Release Pipeline)
通过受控脚本完成「本地检查 -> 构建打包 -> Staging 预演验收 -> 生产同步」全流程：
```sh
./scripts/release.sh
```

---

## 版本历史与更新日志 (Changelog)

### [v1.0.16-1] - 2026-09-14
#### 新增特性 & 架构重构
- **开机自启与配置动态自愈引擎**：
  - 修复设备重启后因 `/var` 内存盘（tmpfs）清空导致的软链接死链与 Procd 启动失败问题；
  - CLI 新增 `xc generate [path] [id]` 核心命令，设备冷启动无配置时自动从持久化 UCI 配置渲染出标准 Xray `config.json`；
  - CLI 新增 `xc enable` 与 `xc disable` 服务自启注册与注销命令；
  - 完善 `/etc/init.d/xc` 守护脚本，增加死链自动清理、无配置自愈拉起保底机制，并规范 Procd 触发器为 `procd_add_reload_trigger "xc"`；
  - 修复 `80_luci-app-xc` 与 `95-xc` 接口热插拔脚本中的 UCI 变量路径（统一收敛至 `xc.main.enabled`）。
- **前端选项卡纯原生重构与防卡死加固**：
  - 彻底废弃传统 LuCI 的 `<a>` 标签与 `.cbi-tabmenu` 结构，重构为独立的纯原生 `<button type="button" class="xc-tab-btn">` 组件；
  - 彻底杜绝 Argon 等现代 LuCI 主题全局页面跳转 Loading 遮罩层对快速 Tab 切换的误拦截，根治多次点击选项卡导致界面假死、必须按 Ctrl+F5 刷新的严重体验缺陷；
  - 在选项卡切换逻辑中增加事件冒泡阻断 (`stopPropagation`) 与防御性残留遮罩层清退机制；
  - 对全局模态框与隐藏容器强化 `pointer-events: none !important;` 样式，消除隐形遮罩拦截。
- **全局自启 Web 开关**：
  - 在 Web 界面「全局基础设置」表单首项增加「**启用服务与开机自启**」复选框，保存时直接联动系统自启软链接 (`/etc/rc.d/S95xc`) 与后台运行状态。

---

### [v1.0.15-1] - 2026-09-09
- **UCI 统筹持久化规范**：将节点配置与全局运行参数统一收敛至 `/etc/config/xc`，原生支持 OpenWrt `sysupgrade` 固件升级无损保留配置；
- **Flash 闪存寿命保护**：运行时配置落盘于 `/var/etc/xc/config.json` 内存盘（tmpfs），杜绝频繁切节点磨损路由存储芯片；
- **版本标识直观呈现**：Web 头部与状态面板引入插件版本标识（Badge 与运行状态统计）；
- **系统日志智能联动**：联动 Xray 日志级别，`warning` 消除 `logread` 刷屏，`info` 输出完整路由分流与域名嗅探走向。

---

### [v1.0.14-1] - 2026-09-07
- **测速性能与并发优化**：支持单节点独立测速与全局并发测速，优化测速任务响应与临时入站端口回收；
- **自动化测试门禁体系**：引入 `verify.sh` 本地语法/沙箱自测与 Staging 真机（192.168.6.1）端到端自动化验收流水线。

---

### [v1.0.8-1] ~ [v1.0.13-1] - 2026-09-05
- **核心与规则资产管理**：支持 Web 界面上传自定义 Xray-core 二进制与 GeoIP/GeoSite 规则文件；
- **多格式归档支持**：新增对 `.zip` 与 `.tar.gz` 压缩包的自动解压、架构校验与软链接挂载能力。

---

### [v1.0.7-1] - 2026-09-03
- **多核心来源切换**：支持系统内置核心与自定义核心一键切换；
- **生命周期控制**：完善后台进程守护与服务热重启管理。

---

### [v1.0.0-1] ~ [v1.0.6-1] - 2026-09-01
- **项目初始化**：底层 `xc` CLI 核心演进为标准 OpenWrt LuCI Web 插件（支持现代 JavaScript 视图与经典 21.02/QWRT 视图兼容）。

---

## 许可证

[MIT License](LICENSE)

