# xc — Xray 节点切换与分流管理器

`xc` 是运行在 OpenWrt/ImmortalWrt 路由器上的轻量级 Xray 客户端管理器。它把多个 VLESS REALITY 和本地 NaiveProxy SOCKS 节点统一为固定编号，通过一个 Lua 命令完成节点测速、切换、健康检查和失败回滚。

项目目标：

- 使用官方 Xray-core 独立运行，不依赖 v2rayA、PassWall 或 sing-box 控制面板。
- 保留 REALITY 与 NaiveProxy 两类出站节点。
- `reality-uk` 固定承担指定 geosite 分流。
- `xc` 当前选择节点承担普通海外流量和最终 fallback。
- DoH 查询经代理发送，禁用本地 DNS fallback。
- 切换失败时恢复上一份配置。

## 端口

Xray 没有 sing-box 的 `mixed` 入站，因此使用两个端口：

| 地址 | 协议 | 用途 |
| --- | --- | --- |
| `LAN_IP:7890` | SOCKS5 | 支持 TCP/UDP，客户端应使用 SOCKS5h |
| `LAN_IP:10809` | HTTP proxy | 浏览器或 HTTP 客户端 |

端口绑定地址、探测地址和健康检查地址由 `/etc/xc/settings.json` 控制。

## 命令

```sh
xc -l          # 列出固定编号、类型和完整代理链延迟
xc 1           # 切换 proxy-selected 到节点 1
xc current     # 显示当前节点
xc test        # 检查 SOCKS5/HTTP 出口
xc rollback    # 恢复上一份配置
```

示例输出：

```text
ID  TYPE                 NODE                          LATENCY
*  1  [VLESS REALITY     ] reality-uk                   582
  9  [NaiveProxy SOCKS5 ] Naive-na217                   550
```

延迟测试会为每个节点生成临时 Xray 配置、临时监听端口，并通过该端口访问 `generate_204`。因此测量的是完整代理链，而非单纯 TCP ping。

## 分流顺序

1. DNS 查询进入 `dns-proxy`，发送到 `proxy-selected`。
2. 广告域名进入 `block`。
3. 私网、局域网和国内地址进入 `direct`。
4. OpenAI、YouTube、Twitter、Telegram、TikTok、Netflix、Google、Facebook 等 geosite 固定走 `reality-uk`。
5. `geosite:geolocation-!cn` 走当前选择节点。
6. 自定义海外例外和未命中流量最终走当前选择节点。

切换节点只改变 `proxy-selected`，不会改变 `reality-uk` 固定分流。

## DNS 防泄露

默认模板使用：

```json
{
  "dns": {
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query",
        "tag": "dns-proxy",
        "skipFallback": true
      }
    ],
    "disableFallback": true,
    "queryStrategy": "UseIPv4"
  }
}
```

不要把 DNS 地址改成 `localhost` 或 `https+local://`，也不要启用本地 fallback。客户端应使用 `SOCKS5h`，浏览器应关闭 QUIC，浏览器内置 DoH 应关闭或配置为代理化。

## 目标机文件

```text
/usr/bin/xray
/usr/bin/xc
/etc/init.d/xc-xray
/etc/xc/config.json
/etc/xc/nodes.json
/etc/xc/settings.json
/etc/xc/current
/etc/xc/config.previous
/etc/xc/current.previous
/usr/share/xray/geoip.dat
/usr/share/xray/geosite.dat
```

## 节点清单格式

不要把真实节点清单提交到公开仓库。使用 `examples/nodes.example.json` 作为模板：

```json
{
  "version": 1,
  "reality_uk_id": 1,
  "nodes": [
    {
      "id": 1,
      "name": "reality-example",
      "type": "VLESS REALITY",
      "server": "example.invalid",
      "port": 443,
      "uuid": "REPLACE_ME",
      "sni": "example.invalid",
      "public_key": "REPLACE_ME",
      "short_id": "REPLACE_ME",
      "fingerprint": "chrome",
      "flow": "xtls-rprx-vision"
    },
    {
      "id": 2,
      "name": "Naive-example",
      "type": "NaiveProxy SOCKS5",
      "server": "127.0.0.1",
      "port": 45321
    }
  ]
}
```

节点编号必须稳定。新增、删除节点时应重新生成完整清单，不要复用旧编号指向不同节点。

## 安装步骤

1. 安装 OpenWrt/ImmortalWrt 依赖：Xray、Lua、`luci.jsonc`、curl、netstat、procd。
2. 将 `src/xc.lua` 安装到 `/usr/bin/xc`。
3. 将 `openwrt/xc-xray.init` 安装到 `/etc/init.d/xc-xray`，并设置可执行权限。
4. 创建 `/etc/xc/config.json`、`nodes.json`、`settings.json`。
5. 安装匹配架构的 Xray 二进制和 `geoip.dat/geosite.dat`。
6. 校验配置并启用服务：

```sh
xray run -test -c /etc/xc/config.json
/etc/init.d/xc-xray enable
/etc/init.d/xc-xray start
xc test
xc -l
```

## 安全注意事项

- 不提交真实 UUID、REALITY public key、short ID、NaiveProxy 密码、SSH 密码、私钥或生产 IP。
- 不提交 `/etc/xc/nodes.json`、生产 `config.json` 或部署日志；使用 `.gitignore` 中的本地文件规则。
- 公开项目只包含通用脚本和占位符示例。
- Xray 与 NaiveProxy 二进制应通过官方发布页获取，并校验 SHA256。
- `xc rollback` 依赖当前配置和上一份配置均存在；首次安装后应先完成一次健康检查。

## 已知限制

- Xray 不提供 sing-box 的 mixed 入站，必须分别配置 SOCKS 和 HTTP 端口。
- geosite 分类名称必须存在于所安装的 `geosite.dat`；缺失分类会导致 `xray run -test` 失败。
- `xc -l` 会串行探测节点，节点较多时耗时可能较长。
- NaiveProxy 出站要求本机对应的 45321–45325 SOCKS 监听已经运行。

## 项目结构

```text
xc/
├── src/xc.lua                 # 节点列表、测速、切换、回滚
├── openwrt/xc-xray.init       # OpenWrt procd 服务脚本
├── examples/settings.example.json
├── examples/nodes.example.json
├── docs/architecture.md
├── README.md
├── LICENSE
└── .gitignore
```

