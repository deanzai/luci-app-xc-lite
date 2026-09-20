# luci-app-xc-lite 核心业务模块全库深度解析与架构知识沉淀

> **文档版本**: 1.0.0  
> **解析分支/提交**: `main` (commit: `b4794a0`)  
> **适用目标环境**: OpenWrt / ImmortalWrt 21.02 ~ 24.10 (纯 Lua 5.1 运行时)  
> **对应仓库**: `https://github.com/deanzai/luci-app-xc-lite.git`  
> **生成工具/规范**: deep-code-read 架构认知规范

---

## 一、系统全景与设计哲学 (System Overview & Philosophy)

`luci-app-xc-lite` 是专为资源受限型路由器（OpenWrt/ImmortalWrt 21.02–24.10）量身打造的高可靠、低内存开销、强事务保证的 **Xray 节点管理与分流控制器**。

### 1.1 核心设计原则
1. **纯 Lua 5.1 运行时**：
   - 杜绝 Lua 5.2/5.3 特性（无 `//` 整除、无 `goto`、无 `continue`、不滥用对 table 的 `#` 取长操作），保证跨 OpenWrt 21.02 至 24.10 的极致二进制与字节码兼容。
2. **读写分离与 Flash 磨损防护 (Tmpfs First)**：
   - 运行态高频变化的动态配置与日志写在 `/var/etc/xc/` 与 `/var/log/xc.log`（基于 RAM tmpfs），绝不频繁写入 Flash 存储；
   - 权威持久化配置落盘在 `/etc/config/xc`（UCI）与 `/etc/xc/`，保障断电不丢失与重启秒级还原。
3. **零容忍崩溃的事务回滚机制 (Two-Phase Commit & Rollback Generations)**：
   - 任何节点切换与核心更新均遵循「预校验（Validation）→ 备份快照（Snapshot）→ 写入候选（Candidate）→ 进程就绪探测（Readiness）→ 真实端到端健康检查（Health Check）→ 最终提交（Commit）」的标准流程。遇错立即自动恢复旧世代，绝不让路由器处于断网或死机状态。
4. **无缝动态节点切换 (Dynamic Balancer Fast-Switch)**：
   - Xray 动态监听环回 gRPC/HTTP API 端口（`10085`），节点切换仅需通过 API 调整 `xc-balancer` 出站策略，秒级生效且已有 TCP 连接不强行中断；仅当动态切换不可用时，才平滑降级执行守护进程热重启。
5. **绝对的敏感凭证脱敏安全 (Strict Secrets Redaction)**：
   - 无论是 Web 前端响应、系统日志（`/var/log/xc.log`）、还是异常堆栈捕获，UUID、密码、Private Key、真实订阅 URL、Raw JSON 等一律严密遮蔽或自动脱敏，杜绝日志泄露。

---

## 二、系统总体架构与模块关系 (Architecture Matrix)

```mermaid
graph TD
    subgraph Browser ["Web 浏览器客户端"]
        UI["LuCI 现代 SPA 界面 (overview.js)"]
    end

    subgraph LuCI_Framework ["LuCI Web 服务框架"]
        RPCD["RPCD 微服务 (/usr/libexec/rpcd/luci.xc)"]
        Ctrl["HTTP 控制器 (luasrc/controller/xc.lua)"]
        CBI["兼容旧版 CBI (luasrc/model/cbi/xc/*)"]
    end

    subgraph Core_Runtime ["XC 核心业务引擎 (Lua 5.1 / root/usr/lib/lua/xc/)"]
        Runtime["运行时控制器 (runtime.lua)"]
        Generator["配置渲染引擎 (generator.lua)"]
        Schema["数据规范与协议注册 (schema.lua)"]
        CoreMgr["核心管理器 (coremanager.lua / core.lua)"]
        AssetMgr["规则库升级管理器 (assetmanager.lua / assetjob.lua)"]
        Probe["网络握手探针 (probe.lua)"]
        Logview["日志脱敏与聚合 (logview.lua)"]
        Importer["订阅与节点解析器 (importer.lua)"]
        Platform["底层适配抽象层 (platform.lua)"]
    end

    subgraph System_Daemon ["系统与进程守护层"]
        Procd["OpenWrt procd 守护进程 (/etc/init.d/xc)"]
        CLI["命令行工具 (/usr/bin/xc)"]
        XrayProcess["Xray-core 进程 (/etc/xc/bin/xray 或 /usr/bin/xray)"]
        UCI_Config["UCI 配置中心 (/etc/config/xc)"]
        Var_Tmpfs["运行态内存盘 (/var/etc/xc/, /tmp/)"]
    end

    UI -->|JSON-RPC ubus| RPCD
    UI -->|Multipart Upload| Ctrl
    RPCD -->|invoke| CLI
    RPCD -->|UCI Cursor| UCI_Config
    Ctrl -->|Adapters| Platform
    CLI --> Runtime
    Runtime --> Generator
    Runtime --> Schema
    Runtime --> Probe
    Runtime --> Logview
    Runtime --> CoreMgr
    Runtime --> AssetMgr
    Runtime --> Platform
    Platform --> UCI_Config
    Platform --> Procd
    Platform --> Var_Tmpfs
    Generator --> Schema
    Procd -->|spawn & guard| XrayProcess
```

---

## 三、核心业务模块深度解析 (Deep Module Breakdown)

### 3.1 运行时状态机与安全事务：`xc.runtime` (`root/usr/lib/lua/xc/runtime.lua`)
- **定位**：整个插件的中枢神经系统，负责节点切换、事务控制、进程健康检查与多世代故障回滚。
- **关键常数与路径**：
  - `LOCK_PATH = "/var/lock/xc.lock"`：全局排它文件锁，避免 Web/CLI 并发操作冲突。
  - `DYNAMIC_API_PORT = 10085` / `DYNAMIC_BALANCER_TAG = "xc-balancer"`：Xray 动态控制环回接口。
  - `ROLLBACK_PATH = "/etc/xc/rollback/"`：配置备份与回滚清单，世代文件格式为 `generation-<ID>.config`。
- **状态机事务协议 (`xc-transaction-v2`)**：
  采用预写式事务日志，阶段严格划分：
  1. `install_intent`：记录变更意图与旧版本 Checksum 摘要；
  2. `candidate_healthy`：新配置经 Xray 验证、启动、端口监听探测、双向 HTTP/SOCKS 真实端到端连接验证均通过；
  3. `uci_committed`：配置正式写入 UCI 权威存储；
  4. `cleanup_pending`：准备清除过期的旧世代临时文件；
  5. `recovery_intent` / `recovery_done`：异常触发时的原子自动恢复流程；
  6. `finalize`：事务完整收口。
- **动态无缝切换 (`fast_switch`)**：
  当目标节点已经在运行中的 `xc-balancer` 出站列表中时，直接通过动态 API 发送指令切换路由出站标签，成功后写入持久化标记，耗时仅几十毫秒，实现 0 秒断流切换。

### 3.2 配置文件渲染引擎：`xc.generator` (`root/usr/lib/lua/xc/generator.lua`)
- **定位**：将 UCI 中的抽象节点参数转换为标准合规的 Xray `config.json`。
- **输入输出**：
  - 输入：UCI 全局设置（SOCKS/HTTP 端口、监听地址、日志等级、分流配置）及标准化节点列表。
  - 输出：符合 Xray 规范的 JSON 文本字符串。
- **核心技术特性**：
  1. **无损 Raw JSON 混入技术**：
     通过独创的 `RAW_FRAGMENT` 标记机制与占位符，如果用户配置了高阶自定义 `raw_outbound`，能在经过 Lua table 处理时保护原始 JSON 字段，避免二次序列化导致的字段丢失或浮点精度失真。
  2. **内置分流拓扑**：
     - `direct`（直连出站）：匹配私有内网网段（`PRIVATE_CIDRS`）、中国域名（`geosite:cn`）、中国大陆 IP（`geoip:cn`）；
     - `block`（拦截出站）：广告或威胁拦截；
     - `xc-balancer` / `xc-node-<id>`：代理节点出站；
     - `sniffing`：强制嗅探 TLS/HTTP 真实域名，避免 DNS 污染导致的流量分流错乱。

### 3.3 节点校验与协议注册中心：`xc.schema` (`root/usr/lib/lua/xc/schema.lua`)
- **定位**：全协议入参强类型校验与规范化网关。
- **支持协议矩阵**：
  - `vless`：支持 REALITY（public_key, short_id, sni, fingerprint, flow: xtls-rprx-vision）及 TLS；
  - `vmess`：支持 alter_id、加密方式、TLS；
  - `trojan`：密码、SNI、传输层配置；
  - `shadowsocks`：支持 2022-blake3、AEAD 多种加解密算法；
  - `socks`：纯 SOCKS5 代理对接（支持 NaiveProxy 本地中继端口）；
  - `raw`：原生自写 Xray outbound 片段。
- **安全过滤与防御**：
  - `safe_section_id`：严格只允许 `^[A-Za-z0-9_]+$`，彻底封杀 UCI 注入风险；
  - 控制字符检查：`value:find("[%z\1-\31\127]")`，严防二进制截断与脏数据注入；
  - 密码与凭据完整性检查：确保 SOCKS 用户名密码必须成对出现，REALITY 必须提供公钥与 short_id 等。

### 3.4 核心版本管理与 ELF 校验：`xc.coremanager` (`root/usr/lib/lua/xc/coremanager.lua`)
- **定位**：负责自定义 Xray 核心文件的热上传、机器架构校验、多版本管理与故障还原。
- **架构智能检测算法 (`elf_arch`)**：
  - 深入二进制文件头第 1 到 64 字节，检查 `\127ELF` 魔数；
  - 解析 Class（32位/64位）与 Data 序（小端/大端）；
  - 提取 `e_machine` 字段精确匹配：`3 -> i386`、`8 -> mipsel/mips`、`40 -> arm`、`62 -> x86_64`、`183 -> aarch64`；
  - 杜绝用户误将 x86 核心上传到 ARM 路由器导致开机崩溃。
- **防爆盘空间检查 (`available_space`)**：
  - 在解压与写入前，严格检查目标分区可用 Flash 空间，至少保留 `上传体积 + 1MB` 的安全缓冲，避免写满 Flash 导致整个路由器系统无法启动。

### 3.5 路由规则与资源更新：`xc.assetmanager` (`root/usr/lib/lua/xc/assetmanager.lua`)
- **定位**：管理 `geoip.dat` 与 `geosite.dat` 规则文件的在线拉取与多镜像切换。
- **镜像加速策略**：
  - 官方源：`GitHub Releases (Loyalsoldier/v2ray-rules-dat)`；
  - 加速镜像源：集成 `gh-proxy.net` 与 `testingcf.jsdelivr.net`，解决国内环境下直连 GitHub 超时失败的问题。
- **增量拉取与元数据缓存**：
  - 缓存 `ETag` 与 `Last-Modified`，对比未发生变化时直接跳过下载，极致节约路由带宽与 Flash 擦写寿命。
  - 配合 `xc.assetjob` 实现非阻塞后台下载与进度状态轮询。

### 3.6 探针与延迟测速：`xc.probe` (`root/usr/lib/lua/xc/probe.lua`)
- **定位**：对节点进行真实网络连通性与 RTT 延迟探测。
- **分层探测技术**：
  1. **TCP 握手探针**：非阻塞 `nixio.socket` + `nixio.poll` 精确测算网络往返时延（RTT）；
  2. **TLS 握手探针**：基于 `nixio.tls` 执行标准 Client Hello 与证书握手；
  3. **WebSocket 探针**：发送 `Upgrade: websocket` 并校验服务端返回 `HTTP/1.1 101 Switching Protocols`。
- **保护设计**：
  - 全局超时限制在 1~10 秒；
  - 探测结果安全入库 `/tmp/xc-probe-cache.json`，使用排它锁 `xc-probe-cache.lock`，防止高并发测速击垮单核 CPU。

### 3.7 日志安全脱敏引擎：`xc.logview` (`root/usr/lib/lua/xc/logview.lua`)
- **定位**：汇总系统守护日志与 Xray 核心运行日志，在对外提供前做严格的敏感隐私脱敏。
- **脱敏特征集**：
  - 自动遮蔽 UUID 正则 (`%x%x%x%x%x%x%x%x%-%x%x%x%x-...` -> `[redacted]`)；
  - 自动遮蔽私钥块 (`-----BEGIN PRIVATE KEY-----...` -> `[redacted]`)；
  - 自动遮蔽敏感键赋值 (`password`, `token`, `secret`, `api_key`, `credential` 等)；
  - 限制日志单行长度与返回最大字节（256KB），保护低内存设备不发生 OOM。

### 3.8 适配抽象层：`xc.platform` (`root/usr/lib/lua/xc/platform.lua`)
- **定位**：实现系统调用（IO、文件系统、UCI、子进程、系统时间）的依赖注入隔离。
- **测试友好设计**：
  - 所有核心模块不直接调用原生 `os.execute` 或 `io.open`，而是通过 `adapters` 适配器注入。测试环境可以注入 Mock 适配器在不需要真实路由器硬件的宿主机上执行数百项单元自动化测试。

### 3.9 RPCD 与 Web 交互中心：`luci.xc` (`root/usr/libexec/rpcd/luci.xc`)
- **定位**：OpenWrt `rpcd` 专有插件，向 LuCI 前端暴露基于 JSON 的 ubus RPC API。
- **提供接口**：
  - `get_status`：获取当前服务运行状态、核心版本、出口 IP、当前激活节点；
  - `get_nodes`：读取并返回节点列表；
  - `switch_node`：执行快速切换节点；
  - `probe_node`：按节点 ID 进行探测测速；
  - `save_node` / `delete_node`：节点增删改查并原子同步至 UCI 与兼容 nodes.json；
  - `switch_source`：核心与规则来源（系统内置 vs 自定义）一键热切换；
  - `save_settings`：保存端口、监听地址与自启配置。

### 3.10 前端现代单页视图：`overview.js` (`htdocs/luci-static/resources/view/xc/overview.js`)
- **定位**：基于 LuCI-21/23+ 现代纯原生 JavaScript 架构（`view.extend`、`rpc.declare`）构建的单页控制台。
- **设计亮点**：
  - **无死锁异步刷新**：采用 Promise + poll 机制解耦，长耗时测速不卡顿整个页面；
  - **直观动态进度**：上传 ZIP 核心包时具备实时进度百分比、动态速率展示与服务端部署解压日志反馈；
  - **组件就绪警报**：当核心或规则缺失时，顶部自动浮现醒目的状态告警卡片，引导用户上传对应组件。

---

## 四、关键业务数据与控制流 (Critical Business Flows)

### 4.1 节点安全切换执行流 (Switch Node Flow)

```mermaid
sequenceDiagram
    autonumber
    actor User as 用户 (Web UI / CLI)
    participant RPCD as RPCD / CLI
    participant Runtime as xc.runtime
    participant XrayAPI as Xray 动态 API (10085)
    participant Generator as xc.generator
    participant Procd as procd (/etc/init.d/xc)
    participant UCI as UCI 配置中心

    User->>RPCD: 请求切换到节点 Node ID
    RPCD->>Runtime: runtime:switch_node(node_id)
    Runtime->>Runtime: 获取全局文件锁 (/var/lock/xc.lock)
    
    alt 支持 Fast-Switch (动态出站切换)
        Runtime->>XrayAPI: gRPC/HTTP: 调整 xc-balancer 目标为 xc-node-<id>
        XrayAPI-->>Runtime: 切换成功
        Runtime->>UCI: 更新当前激活节点 (xc.main.current_id)
        Runtime->>Runtime: 释放全局锁
        Runtime-->>User: 毫秒级切换完成 (零断流)
    else 降级为冷重启 / 完整事务切换
        Runtime->>Generator: 生成候选配置 candidate.json
        Runtime->>Runtime: 写入事务 intent (/etc/xc/rollback/transaction)
        Runtime->>Procd: 重启 Xray 进程
        Runtime->>Runtime: 监听端口就绪探测 (Listener Ready)
        Runtime->>Runtime: 真实代理连通性健康检查 (Health Check)
        alt 检查成功
            Runtime->>UCI: 提交并持久化配置 (commit)
            Runtime->>Runtime: 归档新的 Rollback Generation
            Runtime-->>User: 切换成功
        else 检查超时或失败
            Runtime->>Runtime: 触发自动回滚 (rollback)
            Runtime->>Procd: 恢复上一可用世代配置并重启
            Runtime-->>User: 切换失败已安全回滚
        end
        Runtime->>Runtime: 释放全局锁
    end
```

### 4.2 自定义 Xray 核心热部署流 (Core Upload & Deployment Flow)

```mermaid
sequenceDiagram
    autonumber
    actor Admin as 管理员
    participant Controller as 控制器 (controller/xc.lua)
    participant CoreMgr as xc.coremanager
    participant FileSys as 文件系统 (/etc/xc/bin/xray)

    Admin->>Controller: POST 上传核心包 (ZIP / tar.gz / ELF)
    Controller->>Controller: 流式接收写入 /tmp/xc_upload.tmp (上限 60MB)
    Controller->>Controller: 嗅探文件魔数 (PK.. 或 \127ELF)
    opt 是压缩包
        Controller->>Controller: 解压提取内部 xray 可执行程序
    end
    Controller->>CoreMgr: 校验架构与版本 (validate)
    CoreMgr->>CoreMgr: 读取 ELF Header 校验架构 (如 aarch64)
    CoreMgr->>CoreMgr: 执行 /tmp/xray version 校验合规版本号
    CoreMgr->>CoreMgr: 检查 Flash 分区剩余存储空间
    alt 校验完全合规
        Controller->>FileSys: 移动并赋予执行权限 (chmod 755 /etc/xc/bin/xray)
        Controller-->>Admin: 返回部署成功，提示一键切换或自动生效
    else 架构不符或空间不足
        Controller->>Controller: 清除临时文件
        Controller-->>Admin: 返回明确错误拦截原因
    end
```

---

## 五、核心配置与持久化规范 (Persistence & Compatibility)

| 文件路径 | 类型 | 存储介质 | 职责与生命周期 |
| :--- | :--- | :--- | :--- |
| `/etc/config/xc` | UCI 配置文件 | Flash | **系统权威持久化存储**。定义全局监听端口、分流规则、节点配置段（`config node`）及激活节点。权限严格为 `0600`。 |
| `/etc/xc/nodes.json` | JSON 节点快照 | Flash | **向后兼容与外部工具交换文件**。与 UCI 节点双向自动同步。 |
| `/etc/xc/settings.json` | JSON 设置快照 | Flash | **向后兼容设置文件**。与 UCI `xc.main` 双向自动同步。 |
| `/var/etc/xc/config.json` | Xray 运行时配置 | RAM (tmpfs) | **Xray-core 直接读取的生产配置文件**。开机自动从 UCI 渲染生成，断电不残留，保护 Flash。 |
| `/etc/xc/rollback/` | 事务与世代快照 | Flash | **灾难恢复目录**。保存前代 config、manifest 校验和以及事务恢复意图。权限严格为 `0700`。 |
| `/var/log/xc.log` | 脱敏聚合日志 | RAM (tmpfs) | 运行时事件与核心日志聚合体，严格执行长度截断与敏感信息屏蔽。 |

---

## 六、总结与演化路线 (Architecture Conclusion)

`luci-app-xc-lite` 展现了极高水平的嵌入式安全与稳定性设计：
1. **边界清晰**：数据模型（Schema）→ 逻辑控制（Runtime）→ 数据转换（Generator）→ 视图展现（Overview.js）高度解耦；
2. **容错极强**：具备完善的两阶段提交与回滚机制，即使在极端掉电、节点参数错误、核心损坏场景下也能保持网络通道可用；
3. **性能卓越**：动态 Balancer 结合环回 gRPC 控制，实现了近乎原生的无感热切换。
