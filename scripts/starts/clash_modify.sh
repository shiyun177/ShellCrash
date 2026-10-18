#!/bin/sh
# Copyright (C) Juewuy

#提取源配置中的顶层YAML锚点定义块
#部分第三方配置(如Surfing)会在顶层用 &锚点 定义可复用的配置块，并在
#proxy-groups、rule-providers等分段中用 <<: *锚点 合并引用。
#配置拆分/重组流程会丢弃这些顶层自定义块，若不保留，重组后的配置会报
#“yaml: unknown anchor 'xxx' referenced”而无法启动，进而导致断网。
extract_yaml_anchors() {
    awk '
    function keepable(k) {
        return k !~ /^(proxies|proxy-groups|proxy-providers|rules|rule-providers|sub-rules|listeners|dns|hosts|tun|sniffer|profile|mode|allow-lan|log-level|ipv6|mixed-port|redir-port|tproxy-port|external-controller|external-ui|external-ui-url|secret|authentication|experimental|routing-mark|unified-delay|find-process-mode)$/
    }
    function flush() {
        if (keep && keepable(key)) printf "%s", buf
        buf = ""
        keep = 0
        key = ""
    }
    function has_anchor(s) {
        return s ~ /(^|[[:space:]])&[A-Za-z0-9_-]+([[:space:]]|$)/
    }
    {
        line = $0
        if (line ~ /^[A-Za-z_][A-Za-z0-9_.-]*:/) {
            flush()
            key = line
            sub(/:.*/, "", key)
            buf = line "\n"
            if (has_anchor(line)) keep = 1
        } else if (buf != "") {
            buf = buf line "\n"
            if (has_anchor(line)) keep = 1
        }
    }
    END { flush() }
    ' "$1"
}

prepare_clash_base_config() {
    ##########需要变更的配置###########
    [ "$ipv6_dns" != "OFF" ] && dns_v6='true' || dns_v6='false'
    external="external-controller: 0.0.0.0:$db_port"
    if [ "$redir_mod" = "Mix" -o "$redir_mod" = "Tun" ]; then
        [ "$crashcore" = 'meta' ] && tun_meta=', device: utun, auto-route: false, auto-detect-interface: false'
        tun="tun: {enable: true, stack: system$tun_meta}"
    else
        tun='tun: {enable: false}'
    fi
    exper='experimental: {ignore-resolve-fail: true, interface-name: en0}'
    #Meta内核专属配置
    [ "$crashcore" = 'meta' ] && {
        [ -z "$(grep 'PROCESS' "$CRASHDIR"/yamls/*.yaml)" ] && find_process='find-process-mode: "off"'
        #ecs优化
        [ "$ecs_subnet" = ON ] && {
            . "$CRASHDIR"/libs/get_ecsip.sh
            if [ -n "$ecs_address" ];then
                dns_fallback=$(echo "$dns_fallback, " | sed "s|, |#ecs-override=true\&ecs=$ecs_address, |g" | sed 's|, $||')
            else
                logger "自动获取ecs网段失败！" 33
            fi
        }
    }
    #dns配置
    [ -z "$(cat "$CRASHDIR"/yamls/user.yaml 2>/dev/null | grep '^dns:')" ] && {
        [ "$crashcore" != meta ] && dns_resolver='223.5.5.5'
        cat >"$TMPDIR"/dns.yaml <<EOF
dns:
  enable: true
  listen: :$dns_port
  use-hosts: true
  ipv6: $dns_v6
  default-nameserver: [ $dns_resolver ]
  direct-nameserver: [ $dns_nameserver ]
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.0/15
  fake-ip-range6: fc00::/16
  fake-ip-filter:
EOF
        if [ "$dns_mod" = "mix" ] || [ "$dns_mod" = "fake-ip" ]; then
            cat "$CRASHDIR"/configs/fake_ip_filter "$CRASHDIR"/configs/fake_ip_filter.list 2>/dev/null | grep -v '#' | sed "s/^/    - '/" | sed "s/$/'/" >>"$TMPDIR"/dns.yaml
        else
            echo "    - '+.*'" >>"$TMPDIR"/dns.yaml #使用fake-ip模拟redir_host
        fi
        #mix模式fakeip绕过cn
        [ "$dns_mod" = "mix" ] && echo '    - "rule-set:cn"' >>"$TMPDIR"/dns.yaml
        #mix模式和route模式插入分流设置
        if [ "$dns_mod" = "mix" ] || [ "$dns_mod" = "route" ]; then
            [ "$dns_protect" != "OFF" ] && dns_final="$dns_fallback" || dns_final="$dns_nameserver"
            cat >>"$TMPDIR"/dns.yaml <<EOF
  respect-rules: true
  nameserver-policy: {'rule-set:cn': [ $dns_nameserver ]}
  proxy-server-nameserver : [ $dns_proxy_server ]
  nameserver: [ $dns_final ]
EOF
        else
            cat >>"$TMPDIR"/dns.yaml <<EOF
  nameserver: [ $dns_nameserver ]
EOF
        fi
    }
    #域名嗅探配置
    [ "$sniffer" = "ON" ] && [ "$crashcore" = "meta" ] && sniffer_set="sniffer: {enable: true, parse-pure-ip: true, skip-domain: ['+.push.apple.com', 'Mijia Cloud'], sniff: {http: {ports: [80, 8080-8880], override-destination: true}, tls: {ports: [443, 8443]}, quic: {ports: [443, 8443]}}}"
    [ "$crashcore" = "clashpre" ] && [ "$dns_mod" = "redir_host" -o "$sniffer" = "ON" ] && exper="experimental: {ignore-resolve-fail: true, interface-name: en0,sniff-tls-sni: true}"
}

generate_set_and_hosts_yaml() {
    #生成set.yaml
    cat >"$TMPDIR"/set.yaml <<EOF
mixed-port: $mix_port
redir-port: $redir_port
tproxy-port: $tproxy_port
authentication: ["$authentication"]
allow-lan: true
mode: Rule
log-level: info
ipv6: true
external-controller: :$db_port
external-ui: ui
external-ui-url: "$external_ui_url"
secret: $secret
$tun
$exper
$sniffer_set
$find_process
routing-mark: $routing_mark
unified-delay: true
EOF
    #读取本机hosts并生成配置文件
    if [ "$hosts_opt" != "OFF" ] && [ -z "$(grep -aE '^hosts:' "$CRASHDIR"/yamls/user.yaml 2>/dev/null)" ]; then
        #NTP劫持
        cat >"$TMPDIR"/hosts.yaml <<EOF
use-system-hosts: true
hosts:
  'time.android.com': 203.107.6.88
  'time.facebook.com': 203.107.6.88
EOF
        if [ "$crashcore" = "meta" ]; then
            echo "  'services.googleapis.cn': services.googleapis.com" >>"$TMPDIR"/hosts.yaml
        fi
        #加载本机hosts
        sys_hosts=/etc/hosts
        [ -f /data/etc/custom_hosts ] && sys_hosts='/etc/hosts /data/etc/custom_hosts'
        cat $sys_hosts | while read line; do
            [ -n "$(echo "$line" | grep -oE "([0-9]{1,3}[\.]){3}")" ] &&
                [ -z "$(echo "$line" | grep -oE '^#')" ] &&
                hosts_ip=$(echo $line | awk '{print $1}') &&
                hosts_domain=$(echo $line | awk '{print $2}') &&
                [ -z "$(cat "$TMPDIR"/hosts.yaml | grep -oE "$hosts_domain")" ] &&
                echo "  '$hosts_domain': $hosts_ip" >>"$TMPDIR"/hosts.yaml
        done
    fi
}

split_and_customize_yaml_parts() {
    #分割配置文件
    yaml_char='proxies proxy-groups proxy-providers rules rule-providers sub-rules listeners'
    for char in $yaml_char; do
        sed -n "/^$char:/,/^[a-z]/ { /^[a-z]/d; p; }" "${core_config_src:-$core_config}" >"$TMPDIR"/${char}.yaml
    done
    #跳过本地tls证书验证
    [ "$skip_cert" != "OFF" ] && sed -i 's/skip-cert-verify: false/skip-cert-verify: true/' "$TMPDIR"/proxies.yaml ||
        sed -i 's/skip-cert-verify: true/skip-cert-verify: false/' "$TMPDIR"/proxies.yaml
    #插入自定义策略组
    sed -i "/#自定义策略组开始/,/#自定义策略组结束/d" "$TMPDIR"/proxy-groups.yaml
    sed -i "/#自定义策略组/d" "$TMPDIR"/proxy-groups.yaml
    [ -n "$(grep -Ev '^#' "$CRASHDIR"/yamls/proxy-groups.yaml 2>/dev/null)" ] && {
        #获取空格数
        space_name=$(grep -aE '^ *- \{?name: ' "$TMPDIR"/proxy-groups.yaml | head -n 1 | grep -oE '^ *')
        space_proxy="$space_name    "
        #合并自定义策略组到proxy-groups.yaml
        cat "$CRASHDIR"/yamls/proxy-groups.yaml | sed "/^#/d" | sed "s/#.*//g" | sed '1i\ #自定义策略组开始' | sed '$a\ #自定义策略组结束' | sed "s/^ */${space_name}  /g" | sed "s/^ *- /${space_proxy}- /g" | sed "s/^ *- name: /${space_name}- name: /g"  | sed "s/^ *- {name: /${space_name}- {name: /g" >"$TMPDIR"/proxy-groups_add.yaml
        cat "$TMPDIR"/proxy-groups.yaml >>"$TMPDIR"/proxy-groups_add.yaml
        mv -f "$TMPDIR"/proxy-groups_add.yaml "$TMPDIR"/proxy-groups.yaml
        oldIFS="$IFS"
        grep "\- name: " "$CRASHDIR"/yamls/proxy-groups.yaml | sed "/^#/d" | while read line; do #将自定义策略组插入现有的proxy-group
            new_group=$(echo $line | grep -Eo '^ *- name:.*#' | cut -d'#' -f1 | sed 's/.*name: //g')
            proxy_groups=$(echo $line | grep -Eo '#.*' | sed "s/#//")
            IFS="#"
            for name in $proxy_groups; do
                line_a=$(grep -n "\- name: $name" "$TMPDIR"/proxy-groups.yaml | head -n 1 | awk -F: '{print $1}') #获取group行号
                [ -n "$line_a" ] && {
                    line_b=$(grep -A 8 "\- name: $name" "$TMPDIR"/proxy-groups.yaml | grep -n "proxies:$" | head -n 1 | awk -F: '{print $1}') #获取proxies行号
                    line_c=$((line_a + line_b - 1))                                                                                           #计算需要插入的行号
                    space=$(sed -n "$((line_c + 1))p" "$TMPDIR"/proxy-groups.yaml | grep -oE '^ *')                                           #获取空格数
                    [ "$line_c" -gt 2 ] && sed -i "${line_c}a\\${space}- ${new_group} #自定义策略组" "$TMPDIR"/proxy-groups.yaml
                }
            done
            IFS="$oldIFS"
        done
    }
    #插入自定义代理
    sed -i "/#自定义代理/d" "$TMPDIR"/proxies.yaml
    sed -i "/#自定义代理/d" "$TMPDIR"/proxy-groups.yaml
    [ -n "$(grep -Ev '^#' "$CRASHDIR"/yamls/proxies.yaml 2>/dev/null)" ] && {
        space_proxy=$(cat "$TMPDIR"/proxies.yaml | grep -aE '^ *- ' | head -n 1 | grep -oE '^ *')                                                            #获取空格数
        cat "$CRASHDIR"/yamls/proxies.yaml | sed "s/^ *- /${space_proxy}- /g" | sed "/^#/d" | sed "/^ *$/d" | sed 's/#.*/ #自定义代理/g' >>"$TMPDIR"/proxies.yaml #插入节点
        oldIFS="$IFS"
        cat "$CRASHDIR"/yamls/proxies.yaml | sed "/^#/d" | while read line; do #将节点插入proxy-group
            proxy_name=$(echo $line | grep -Eo 'name: .+, ' | cut -d',' -f1 | sed 's/name: //g')
            proxy_groups=$(echo $line | grep -Eo '#.*' | sed "s/#//")
            IFS="#"
            for name in $proxy_groups; do
                line_a=$(grep -n "\- name: $name" "$TMPDIR"/proxy-groups.yaml | head -n 1 | awk -F: '{print $1}') #获取group行号
                [ -n "$line_a" ] && {
                    line_b=$(grep -A 8 "\- name: $name" "$TMPDIR"/proxy-groups.yaml | grep -n "proxies:$" | head -n 1 | awk -F: '{print $1}') #获取proxies行号
                    line_c=$((line_a + line_b - 1))                                                                                           #计算需要插入的行号
                    space=$(sed -n "$((line_c + 1))p" "$TMPDIR"/proxy-groups.yaml | grep -oE '^ *')                                           #获取空格数
                    [ "$line_c" -gt 2 ] && sed -i "${line_c}a\\${space}- ${proxy_name} #自定义代理" "$TMPDIR"/proxy-groups.yaml
                }
            done
            IFS="$oldIFS"
        done
    }
}

add_custom_inbounds_and_rules() {
    #添加自定义入站
    [ "$vms_service" = ON ] || [ "$sss_service" = ON ] && {
        . "$CRASHDIR"/configs/gateway.cfg
        . "$CRASHDIR"/libs/meta_listeners.sh
    }
    #节点绕过功能支持
    sed -i "/#节点绕过/d" "$TMPDIR"/rules.yaml
    [ "$proxies_bypass" = "ON" ] && {
        cat "$TMPDIR"/proxies.yaml | sed '/^proxy-/,$d' | sed '/^rule-/,$d' | grep -v '^\s*#' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | awk '!a[$0]++' | sed 's/^/\ -\ IP-CIDR,/g' | sed 's|$|/32,DIRECT,no-resolve #节点绕过|g' >>"$TMPDIR"/proxies_bypass
        cat "$TMPDIR"/proxies.yaml | sed '/^proxy-/,$d' | sed '/^rule-/,$d' | grep -v '^\s*#' | grep -vE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -oE '[a-zA-Z0-9][-a-zA-Z0-9]{0,62}(\.[a-zA-Z0-9][-a-zA-Z0-9]{0,62})+\.?' | awk '!a[$0]++' | sed 's/^/\ -\ DOMAIN,/g' | sed 's/$/,DIRECT #节点绕过/g' >>"$TMPDIR"/proxies_bypass
        cat "$TMPDIR"/rules.yaml >>"$TMPDIR"/proxies_bypass
        mv -f "$TMPDIR"/proxies_bypass "$TMPDIR"/rules.yaml
    }
    #插入自定义规则
    sed -i "/#自定义规则/d" "$TMPDIR"/rules.yaml
    [ -s "$CRASHDIR"/yamls/rules.yaml ] && {
        cat "$CRASHDIR"/yamls/rules.yaml | sed "/^#/d" | sed '$a\' | sed 's/$/ #自定义规则/g' >"$TMPDIR"/rules.add
        cat "$TMPDIR"/rules.yaml >>"$TMPDIR"/rules.add
        mv -f "$TMPDIR"/rules.add "$TMPDIR"/rules.yaml
    }
    #mix/route模式会启用respect-rules，此时配置里的DST-PORT,53劫持规则
    #会把核心自身发往上游的DNS请求再次劫持(如Surfing的🌐 DNS_Hijack)，
    #造成DNS解析死循环，最终表现为无法上网，需要移除该规则
    if [ "$dns_mod" = "mix" ] || [ "$dns_mod" = "route" ]; then
        if grep -qE '^[[:space:]]*-[[:space:]]*DST-PORT,53,' "$TMPDIR"/rules.yaml 2>/dev/null; then
            sed -i "/^[[:space:]]*-[[:space:]]*DST-PORT,53,/d" "$TMPDIR"/rules.yaml
            logger "已移除配置中与ShellCrash DNS冲突的DST-PORT,53规则，避免DNS解析回环！" 33 off
        fi
    fi
}

merger_yaml() {
    #mix和route模式生成rule-providers
    [ "$dns_mod" = "mix" ] || [ "$dns_mod" = "route" ] && ! grep -Eq '^[[:space:]]*cn:' "$TMPDIR"/rule-providers.yaml && ! grep -q '^rule-providers' "$CRASHDIR"/yamls/others.yaml 2>/dev/null && {
        space=$(sed -n "1p" "$TMPDIR"/rule-providers.yaml | grep -oE '^ *') #获取空格数
        [ -z "$space" ] && space='  '
        echo "${space}cn: {type: http, behavior: domain, format: mrs, path: ./ruleset/cn.mrs, interval: 86400, url: https://testingcf.jsdelivr.net/gh/juewuy/ShellCrash@update/bin/geodata/mrs_geosite_cn.mrs}" >>"$TMPDIR"/rule-providers.yaml
    }
    #对齐rules中的空格
    sed -i 's/^ *-/ -/g' "$TMPDIR"/rules.yaml
    #合并文件
    [ -s "$CRASHDIR"/yamls/user.yaml ] && {
        yaml_user="$CRASHDIR"/yamls/user.yaml
        #set和user去重,且优先使用user.yaml
        cp -f "$TMPDIR"/set.yaml "$TMPDIR"/set_bak.yaml
        for char in mode allow-lan log-level tun experimental external-ui-url interface-name dns store-selected unified-delay; do
            [ -n "$(grep -E "^$char" $yaml_user)" ] && sed -i "/^$char/d" "$TMPDIR"/set.yaml
        done
    }
    [ -s "$TMPDIR"/dns.yaml ] && yaml_dns="$TMPDIR"/dns.yaml
    [ -s "$TMPDIR"/hosts.yaml ] && yaml_hosts="$TMPDIR"/hosts.yaml
    [ -s "$CRASHDIR"/yamls/others.yaml ] && yaml_others="$CRASHDIR"/yamls/others.yaml
    yaml_add=
    for char in $yaml_char; do #将额外配置文件合并
        [ -s "$TMPDIR"/${char}.yaml ] && {
            sed -i "1i\\${char}:" "$TMPDIR"/${char}.yaml
            yaml_add="$yaml_add $TMPDIR/${char}.yaml"
        }
    done
    #保留源配置中的YAML锚点定义块，避免分段重组后出现未知锚点错误
    yaml_anchors=
    [ -s "$TMPDIR"/anchors.yaml ] && yaml_anchors="$TMPDIR"/anchors.yaml
    #合并完整配置文件
    cut -c 1- $yaml_anchors "$TMPDIR"/set.yaml $yaml_dns $yaml_hosts $yaml_user $yaml_others $yaml_add >"$TMPDIR"/config.yaml
}

#检查“禁用配置覆写”时导入的完整配置是否与ShellCrash的端口及防火墙设置兼容
#不兼容时直接使用原始配置，会出现核心已启动但流量被转发到错误端口/缺少
#routing-mark导致回环等情况，表现为“无法连接到互联网”
clash_config_compatible() {
    [ -s "$core_config" ] || return 1
    #核心入站端口必须与防火墙劫持端口一致
    [ "$(sed -n 's/^mixed-port:[[:space:]]*//p' "$core_config" | head -n 1 | tr -d ' \r')" = "$mix_port" ] || return 1
    [ "$(sed -n 's/^redir-port:[[:space:]]*//p' "$core_config" | head -n 1 | tr -d ' \r')" = "$redir_port" ] || return 1
    [ "$(sed -n 's/^tproxy-port:[[:space:]]*//p' "$core_config" | head -n 1 | tr -d ' \r')" = "$tproxy_port" ] || return 1
    #面板端口必须一致，否则ShellCrash无法通过API检测启动状态
    cfg_db=$(sed -n 's/^external-controller:[[:space:]]*//p' "$core_config" | head -n 1 | tr -d ' \r')
    case "$cfg_db" in
    *":$db_port") ;;
    *) return 1 ;;
    esac
    #DNS监听端口必须与防火墙DNS劫持端口一致
    cfg_dns=$(sed -n '/^dns:/,/^[^[:space:]#]/s/^[[:space:]]*listen:[[:space:]]*//p' "$core_config" | head -n 1 | tr -d ' \r')
    [ -n "$cfg_dns" ] && [ "${cfg_dns##*:}" = "$dns_port" ] || return 1
    #routing-mark用于标记核心自身流量，避免Tproxy/Redir回环
    [ "$(sed -n 's/^routing-mark:[[:space:]]*//p' "$core_config" | head -n 1 | tr -d ' \r')" = "$routing_mark" ] || return 1
    #局域网代理必须开启
    [ "$(sed -n 's/^allow-lan:[[:space:]]*//p' "$core_config" | head -n 1 | tr -d ' \r')" = "true" ] || return 1
    #tun开关必须与当前代理模式匹配
    cfg_tun=$(sed -n '/^tun:/,/^[^[:space:]#]/s/^[[:space:]]*enable:[[:space:]]*//p' "$core_config" | head -n 1 | tr -d ' \r')
    [ -z "$cfg_tun" ] && {
        #兼容 tun: {enable: true} 这种单行写法
        grep -q '^tun:.*enable:[[:space:]]*true' "$core_config" && cfg_tun=true
        grep -q '^tun:.*enable:[[:space:]]*false' "$core_config" && cfg_tun=false
    }
    if [ "$redir_mod" = "Tun" -o "$redir_mod" = "Mix" ]; then
        [ "$cfg_tun" = "true" ] || return 1
    else
        [ "$cfg_tun" = "true" ] && return 1
    fi
    return 0
}

test_yaml() {
    #测试自定义配置文件
    "$TMPDIR"/CrashCore -t -d "$BINDIR" -f "$TMPDIR"/config.yaml >/dev/null
    if [ "$?" != 0 ]; then
        logger "$("$TMPDIR"/CrashCore -t -d "$BINDIR" -f "$TMPDIR"/config.yaml | grep -Eo 'error.*=.*')" 31
        logger "自定义配置文件校验失败！将使用基础配置文件启动！" 33
        logger "错误详情请参考 "$TMPDIR"/error.yaml 文件！" 33
        cp -f "$TMPDIR"/config.yaml "$TMPDIR"/error.yaml >/dev/null 2>&1
        #回退到仅包含ShellCrash基础配置的配置，丢弃无法解析的节点/规则分段
        #避免核心无法启动或流量被转发到错误端口，导致路由器断网
        sed -i "/#自定义策略组开始/,/#自定义策略组结束/d" "$TMPDIR"/proxy-groups.yaml
        mv -f "$TMPDIR"/set_bak.yaml "$TMPDIR"/set.yaml >/dev/null 2>&1
        #重新生成不依赖rule-set的DNS配置，确保基础配置可以独立通过校验
        cat >"$TMPDIR"/dns_fallback.yaml <<EOF
dns:
  enable: true
  listen: :$dns_port
  use-hosts: true
  ipv6: $dns_v6
  default-nameserver: [ $dns_resolver ]
  direct-nameserver: [ $dns_nameserver ]
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.0/15
  fake-ip-range6: fc00::/16
  fake-ip-filter:
    - '+.*'
  nameserver: [ $dns_nameserver ]
EOF
        cut -c 1- "$TMPDIR"/set.yaml "$TMPDIR"/dns_fallback.yaml $yaml_hosts >"$TMPDIR"/config.yaml
        rm -f "$TMPDIR"/dns_fallback.yaml
        sed -i "/#自定义/d" "$TMPDIR"/config.yaml
        "$TMPDIR"/CrashCore -t -d "$BINDIR" -f "$TMPDIR"/config.yaml >/dev/null 2>&1 &&
            logger "已回退为基础配置，未加载导入配置的节点和规则，当前可正常上网！" 33 ||
            logger "基础配置校验仍然失败，请检查ShellCrash设置！" 31
    fi
}

finalize_clash_yaml() {
    #建立软连接
    [ ""$TMPDIR"" = ""$BINDIR"" ] || ln -sf "$TMPDIR"/config.yaml "$BINDIR"/config.yaml 2>/dev/null || cp -f "$TMPDIR"/config.yaml "$BINDIR"/config.yaml
    #清理缓存
    for char in $yaml_char set set_bak dns hosts anchors; do
        rm -f "$TMPDIR"/${char}.yaml
    done
    rm -f "$TMPDIR"/core_config.lf
}

#修饰clash配置文件
modify_yaml() {
    rm -f "$TMPDIR"/anchors.yaml
    #删除上次运行可能遗留的软链接，避免写入时覆盖原始的导入配置
    rm -f "$TMPDIR"/config.yaml
    #统一换行符，兼容Windows编辑后上传的CRLF配置，避免锚点识别和分段异常
    tr -d '\r' <"$core_config" >"$TMPDIR"/core_config.lf 2>/dev/null
    [ -s "$TMPDIR"/core_config.lf ] && core_config_src="$TMPDIR"/core_config.lf || core_config_src="$core_config"
    #Surfing等第三方配置的订阅链接占位符提醒
    grep -q '此处引入您的Clash订阅链接地址' "$core_config_src" 2>/dev/null &&
        logger "检测到配置中的订阅链接仍为占位符，请先编辑配置文件填入订阅地址！" 33 off
    prepare_clash_base_config
    generate_set_and_hosts_yaml
    #提取源配置中的YAML锚点定义块(如Surfing配置)
    extract_yaml_anchors "$core_config_src" >"$TMPDIR"/anchors.yaml 2>/dev/null
    split_and_customize_yaml_parts
    add_custom_inbounds_and_rules
    merger_yaml
    test_yaml
    finalize_clash_yaml
}
