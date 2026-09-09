# luci-app-xc-lite 自测环境与先验后发质量门禁规范

本文档定义了 `luci-app-xc-lite` 项目的标准自测环境、自动化测试门禁及「先验后发」的发布流程规范。任何代码迭代必须严格遵循此规范，确保上线零崩溃、零死锁、零界面遮挡。

---

## 一、环境矩阵 (Environment Matrix)

| 环境层级 | 设备 / 宿主 | IP 地址 | 作用与职责 |
| :--- | :--- | :--- | :--- |
| **本地沙箱 (Local Sandbox)** | WSL (Ubuntu-22.04) | 本地 | 代码开发、CRLF 规范检测、Lua 语法预编译、RPCD 本地 Mock 沙箱模拟 |
| **预发布机 (Staging Router)** | 真实 OpenWrt 路由器 | `192.168.6.1` | **真机验收环境**：新版本首发测试、真实网络探针延时测试、接口并发死锁校验、前端 DOM 渲染与防遮挡真机验收 |
| **生产集群 (Production)** | 生产路由器 A / B | `192.168.93.94`<br>`192.168.13.1` | **全量正式环境**：只有在 Staging 验收 100% 通过后，才允许由流水线自动同步部署 |

- **设备管理凭据**：统一为 `root` / `ljx@0931`。
- **特定网络参数**：`192.168.93.94` 需要显式启用 `-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa`。

---

## 二、核心自动化工具链

项目提供两套核心自动化脚本（位于 `scripts/` 目录下）：

### 1. `scripts/verify.sh`（全自动自测与验收门禁）
具备 24 项严格的自动化检查，分为本地静态测试与真机动态回归测试两大级别：

```bash
# 1. 仅在本地运行语法、代码规范与沙箱 Mock 测试 (适合编码过程中频繁执行)
./scripts/verify.sh --local

# 2. 对 Staging 验证机 (192.168.6.1) 进行真机全量回归与烟雾测试
./scripts/verify.sh --staging

# 3. 运行本地 + 真机全量 24 项测试
./scripts/verify.sh --all
```

#### 覆盖的 24 项测试清单：
1. **源码规范**：全目录扫描，绝对禁止 Windows CRLF 换行符污染。
2. **Lua 语法编译**：对 `controller/xc.lua`、`rpcd/luci.xc`、`/usr/bin/xc` 执行 `luac -p` 字节码编译检验。
3. **依赖与死锁防护**：
   - 验证 `controller/xc.lua` 是否显式 `require "luci.http"`（防止返回 500 nil 崩溃）。
   - 验证无参接口调用是否附带 `echo '' |` 管道重定向（防止子进程等待 stdin 阻塞死锁）。
   - 验证 `rpcd/luci.xc` 是否仅在带参调用时读取 stdin。
   - 验证 `controller/xc.lua` 的 `index()` 闭包在经过 LuCI indexcache 字节码序列化反序列化后无外部 local upvalue，杜绝老版本 LuCI 缓存机制下的 `attempt to index upvalue 'nixio' (a nil value)` 崩溃。
4. **前端防遮挡与 Tab 结构**：
   - 验证 `overview.htm` 包含 `.xc-hidden { display:none !important; }`。
   - 验证节点编辑模态框与文件上传模态框带有内联 `style="display:none;"`（根除首屏弹窗遮挡）。
   - 验证 Tab 容器及 `sec-nodes`、`sec-settings`、`sec-core` 关键节点。
   - 验证超时与并发设置项输入控件完整性。
5. **本地 RPCD 沙箱模拟**：本地隔离运行 RPCD，验证 JSON 返回有效性及无卡顿。
6. **真机连通性**：Staging 路由器的 ICMP Ping 及 SSH 通信连通性。
7. **真机权限**：`/usr/bin/xc`、`rpcd/luci.xc` 与 UI 模板的存在性与 0755/0644 权限就绪。
8. **真机探活实测**：在真实路由器上直接执行极速探针，测量境外目标（Google 204）真实延时，确保探活在 1 秒以内。
9. **真机后端接口**：向真机发起实际 RPCD 调用，验证 0 秒返回与 JSON 合规。
10. **真机前端渲染**：抓取真机 LuCI 模板，校验 Tab 与模态框防御属性均已正确部署。

---

### 2. `scripts/release.sh`（先验后发自动化流水线）
实现严格的 5 步先验后发流水线。任何一步失败，流水线立即阻断，严禁向生产机发布！

```bash
./scripts/release.sh
```

#### 流水线五步门禁逻辑：
```text
[步骤 1/5] 本地自检门禁 (verify.sh --local)
    ↓ (通过)
[步骤 2/5] 编译打包 (build.sh 生成最新 IPK)
    ↓ (通过)
[步骤 3/5] 灰度预发布 (仅推送并安装至 Staging 192.168.6.1)
    ↓ (通过)
[步骤 4/5] 真机全自动回归验收 (verify.sh --staging)
    ↓ (通过)
[步骤 5/5] 同步部署生产集群 (全量推送到 192.168.93.94 和 192.168.13.1)
```

---

## 三、日常开发与发布 SOP (开发者守则)

每次修改代码或修复 Bug，请务必遵照以下操作流程：

### 第一步：本地修改代码
- 修改前端界面时：必须在 `root/usr/lib/lua/luci/view/xc/overview.htm` 和 `htdocs/luci-static/resources/view/xc/overview.js` 中保持同步，所有弹窗容器必须带有 `.xc-hidden` 及内联 `style="display:none;"`。
- 修改后端与接口时：严禁在 `io.popen` 中省略 stdin EOF 保护，严禁使用非 Lua 5.1 语法。
- 确保保存时使用 POSIX LF 换行。

### 第二步：运行本地自检
在 WSL 中执行：
```bash
./scripts/verify.sh --local
```
确保全项显示 `[PASS]`。若有 `[FAIL]`，根据终端红字提示立即修正。

### 第三步：一键先验后发
在 WSL 中执行：
```bash
./scripts/release.sh
```
- 观察控制台日志依次执行：本地自检 -> 构建打包 -> Staging 安装 -> 自动化真机回归测试。
- 当且仅当 Staging 验收 100% 通过后，脚本会自动把版本推送到 `192.168.93.94` 和 `192.168.13.1`。

### 第四步：浏览器最终验收
打开浏览器访问预发布机 `http://192.168.6.1`：
1. 按 `Ctrl + F5` 强制刷新，清理浏览器旧静态资源缓存。
2. 检查首屏无弹窗遮挡。
3. 检查顶部 Tab（节点管理、全局设置、核心与分流）切换流畅。
4. 点击「⚡ 全部测速」，观察测速在秒级完成。
