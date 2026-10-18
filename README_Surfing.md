# ShellCrash × Surfing 配置兼容说明

本仓库（`shiyun177/ShellCrash`）在官方 ShellCrash 的基础上，增加了对
[Surfing](https://github.com/GitMetaio/Surfing) 项目
`box_bll/clash/config.yaml` 的直接导入支持，目标是在**小米万兆路由器（RC01，官方固件，
已解锁 SSH）**上使用 Surfing 的代理组/节点/规则，同时不出现导入后无法上网的问题。

## 一、修改内容

### 1. 保留 YAML 锚点（核心修复）

Surfing 的配置在顶层使用 `&锚点` 定义可复用配置块，例如：

```yaml
updatetime: &Time 86400
p: &p
  type: http
  interval: *Time
A: &A
  filter: "..."
  use: ["1.主要地址", "2.备用地址", "3.额外地址"]
All: &All
  type: url-test
  use: ["1.主要地址", "2.备用地址", "3.额外地址"]
proxy_groups: &proxy_groups
  type: select
  proxies: [...]
  <<: *A
rule-anchor:
  Local: &Local {type: file, behavior: classical, format: text}
  Domain: &Domain {type: http, behavior: domain, format: mrs, interval: *Time}
```

`proxy-groups`、`rule-providers` 等分段里大量使用 `<<: *A`、`<<: *All`、
`<<: *proxy_groups`、`<<: *Domain`。原版 ShellCrash 会把配置拆成
`proxies`、`proxy-groups`、`rules` 等分段再重新拼接，顶层的锚点定义块被丢弃，
mihomo 启动时报：

```
yaml: unknown anchor 'proxy_groups' referenced
```

随后 ShellCrash 回退到基础配置，核心无法启动，表现为断网。

现在 `scripts/starts/clash_modify.sh` 增加了 `extract_yaml_anchors()`：在拆分配置前，
用 awk 把源配置中所有“定义了 `&锚点` 的顶层配置块”按原顺序提取出来，放到重组后
配置文件的最前面。锚点定义和引用仍在同一个 YAML 文档内，mihomo 可以正常解析。

### 2. “禁用配置覆写”时的自动兼容检查

原版在开启“禁用配置文件覆写”后，会把导入的配置直接软链接给内核。Surfing 配置使用：

| 项目 | Surfing 默认 | ShellCrash 默认 |
| --- | --- | --- |
| mixed-port | 7890 | 7890 |
| redir-port | 7891 | 7892 |
| tproxy-port | 1536 | 7893 |
| external-controller | 9090 | 9999 |
| routing-mark | 未设置 | 7894 |

直接使用会出现“核心正常运行，但 iptables 把流量转发到了 7892/7893 等错误端口”
或者“核心自身流量没有 `routing-mark` 标记而反复回环”，最终无法上网。

现在 `bfstart.sh` 在禁用覆写时会先调用 `clash_config_compatible()` 检查：

- `mixed-port` / `redir-port` / `tproxy-port` 是否与防火墙一致；
- `external-controller` 端口是否与面板一致；
- `dns.listen` 端口是否与 DNS 劫持端口一致；
- `routing-mark` 是否存在且一致；
- `tun.enable` 是否与当前代理模式匹配。

全部匹配才直接使用原始配置；否则记录日志并自动改用 ShellCrash 的覆写流程，
保证网络可用。`firewall_area=4`（纯净模式，不做流量劫持）时跳过检查。

### 3. 避免 mix/route DNS 与 `DST-PORT,53` 规则互相劫持

ShellCrash 的 `dns_mod=mix/route` 会生成 `respect-rules: true`，即核心发往上游
DNS 的请求也要按规则分流。Surfing 配置的规则列表开头有：

```yaml
- DST-PORT,53,🌐 DNS_Hijack
```

`🌐 DNS_Hijack` 是一个 `type: dns` 的代理，会把 DNS 请求再次交给 mihomo 的 DNS
处理。于是出现：

```
mihomo 查询 223.5.5.5:53
  -> 命中 DST-PORT,53,🌐 DNS_Hijack
  -> 交给 mihomo DNS
  -> 再次查询 223.5.5.5:53 ...
```

DNS 解析死循环，客户端表现为“能连上 Wi-Fi 但打不开网页”。现在在
`dns_mod=mix/route` 时，`clash_modify.sh` 会移除 `DST-PORT,53` 规则；上游 DNS
请求随后按 `CN_IP` / `MATCH` 正常分流（国内直连、国外走代理），不再回环。
`dns_mod=fake-ip/redir_host` 不使用 `respect-rules`，不会回环，因此保留该规则。

### 4. 校验失败时回退到“可上网”的基础配置

原版 `test_yaml()` 校验失败后，会用仍然包含损坏分段（例如未知锚点）的内容重新
拼接“基础配置”，核心还是启动失败。现在失败时会：

1. 把错误配置保存到 `/tmp/ShellCrash/error.yaml`；
2. 丢弃节点、策略组、规则、rule-providers 等分段；
3. 重新生成一份不依赖 `rule-set` 的 DNS 配置（避免 mix 模式引用不存在的
   `rule-set:cn`）；
4. 只保留 `set.yaml` + 基础 DNS + hosts，重新校验。

这样即使导入的配置有语法错误，内核也能以直连方式启动，路由器不会断网；
用户可以从 `error.yaml` 和日志中排查问题。

### 5. 订阅占位符提醒

Surfing 仓库自带的配置中，三个 `proxy-providers` 的 `url` 都是占位符
“此处引入您的Clash订阅链接地址”。加载时会在日志中提示先填写订阅地址，
避免误以为配置已经可用。

## 二、小米万兆路由器（RC01）使用步骤

> 目标环境：小米万兆路由器 RC01，官方固件（OpenWrt 18.06，kernel 5.4，aarch64），
> 已解锁 SSH。该固件的 TProxy 路径有已知问题（规则计数增长但数据包不能投递到
> 透明 socket），推荐使用 **Tun 模式**；Redir 模式可用，但只覆盖 TCP。

1. 安装 ShellCrash（本仓库已把安装源改为 `shiyun177/ShellCrash@master`）：
   ```sh
   sh -c "$(curl -kfsSL https://testingcf.jsdelivr.net/gh/shiyun177/ShellCrash@master/install.sh)"
   ```
   确认内核为 **meta（Mihomo）**，`crash` 命令可用。`install.sh` 会把
   `ShellCrash.tar.gz`（已包含本仓库的修改）解压到安装目录。
2. 编辑 Surfing 的 `box_bll/clash/config.yaml`，把 `proxy-providers` 中
   `1.主要地址` / `2.备用地址` / `3.额外地址` 的 `url` 改成自己的订阅地址；
   只用一个订阅时，建议删除另外两个 provider 以及 `proxy-groups` 中的对应引用，
   避免启动时出现无意义的下载错误。
3. 把文件改名为 `config.yaml`，用 WinSCP/SCP 上传到路由器 `/tmp/config.yaml`。
4. 执行 `crash`，菜单会提示发现 `/tmp/config.yaml`，选择 `1) 立即加载`。
   （也可以手动放到 `/etc/ShellCrash/yamls/config.yaml`，以实际安装目录为准。）
5. 建议设置：
   - 内核：`meta`
   - 代理模式：`Tun`（推荐）或 `Redir`
   - DNS：`fake-ip`（推荐，与 RC01 实测一致）；`mix` 也可以（已修复
     `DST-PORT,53` 导致的 DNS 回环）
   - IPv6：`ipv6_redir=ON`、`ipv6_dns=OFF`（与 RC01 官方固件实测一致）
   - 防火墙：`iptables`（RC01 实测稳定；若被自动识别为 nftables，可手动切回）
   - 常见端口过滤：`OFF`（Tun 模式下覆盖全部端口，可选）
6. **不要开启“禁用配置文件覆写”**；若已开启，脚本会自动检测端口/routing-mark
   不匹配并回退到覆写模式，日志中会有提示。
7. 启动后访问 `http://路由器IP:9999/ui/` 查看面板，并在 `crash` 菜单中确认
   服务状态和日志。

## 三、兼容性说明

- ShellCrash 会用自己的 **DNS、TUN、端口、面板、routing-mark** 顶层配置替换
  Surfing 配置中的对应段，这是路由器透明代理和防火墙联动所必需的。
- Surfing 的 `proxies`、`proxy-groups`、`proxy-providers`、`rules`、
  `rule-providers` 会完整保留（包括其中的锚点引用）。
- Surfing 的 `rule-providers` 使用 `./rules/*.mrs` 相对路径，mihomo 首次启动时
  会从 jsDelivr 下载到 `$CRASHDIR/rules/`（小闪存模式下是 `$BINDIR/rules/`）。
  首次启动会稍慢；下载失败只会导致对应规则不生效，`MATCH` 仍会走代理组。
- Surfing 配置中的 `PROCESS-NAME`（Android 包名）规则在路由器上不会匹配，
  属于正常现象。
- 如果订阅节点全部不可用，mihomo 会把空策略组回退为 `COMPATIBLE`（直连）。
  这样能保证不断网，但不会走代理，请检查订阅是否过期/被墙。

## 四、验证记录

在 Windows 上使用 Surfing 自带的 mihomo v1.19.16，对按 ShellCrash 流程拆分、
重组后的配置执行 `-t`：
- 不保留锚点：`yaml: unknown anchor 'proxy_groups' referenced`（复现原问题）
- 保留锚点后：`configuration file ... test is successful`
- `dns_mod=mix` 且保留 `DST-PORT,53` 规则：DNS 查询超时（复现劫持死循环）
- `dns_mod=mix` 且移除 `DST-PORT,53` 规则：DNS 正常返回、HTTP 代理访问百度返回 `200`
- 基础回退配置：`test is successful`，DNS 正常返回，HTTP 代理返回 `200`
- 运行时：核心启动成功，HTTP 代理访问 `http://www.baidu.com` 返回 `200`，
  DNS 监听端口正常响应。

路由器上的最终效果请在设备上执行 `crash` 启动后，用面板和实际设备访问验证。

## 五、维护提示

`install.sh` / 在线更新实际解压的是仓库根目录的 `ShellCrash.tar.gz`，不是
`scripts/` 源码目录。修改 `scripts/starts/*.sh` 后，需要重新打包
`ShellCrash.tar.gz`（保持原有文件列表，只替换对应脚本），否则新安装或在线更新
仍会得到旧代码。本仓库当前的 `ShellCrash.tar.gz` 已包含上述修改。

