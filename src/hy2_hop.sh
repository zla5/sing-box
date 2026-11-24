#!/bin/bash

# Hysteria2 UDP port hopping helpers.
# Server still listens on a single port; OS NAT redirects the hop range to it.
# Default range sits below Linux ephemeral ports and away from common panel ranges.
is_hy2_hop_base=26800
is_hy2_hop_span=1000
is_hy2_hop_ports_default="${is_hy2_hop_base}-$((is_hy2_hop_base + is_hy2_hop_span - 1))"
is_hy2_hop_comment_prefix=sing-box-hy2-hop
is_hy2_hop_nft_table=singbox_hy2_hop

hy2_hop_parse_range() {
    local range=$1
    [[ $range =~ ^([1-9][0-9]{0,4})-([1-9][0-9]{0,4})$ ]] || return 1
    hy2_hop_start=${BASH_REMATCH[1]}
    hy2_hop_end=${BASH_REMATCH[2]}
    [[ $(is_test port $hy2_hop_start) && $(is_test port $hy2_hop_end) ]] || return 1
    [[ $hy2_hop_start -lt $hy2_hop_end ]] || return 1
    # allow wide ranges (e.g. 30000-50999); reject full 1-65535 style mistakes
    [[ $((hy2_hop_end - hy2_hop_start)) -le 40000 ]] || return 1
}

hy2_hop_port_in_range() {
    local port=$1 range=$2
    hy2_hop_parse_range "$range" || return 1
    [[ $port -ge $hy2_hop_start && $port -le $hy2_hop_end ]]
}

hy2_hop_file_of() {
    echo "$is_conf_dir/${1}.hop"
}

hy2_hop_list_used_ranges() {
    local f
    for f in "$is_conf_dir"/*.hop; do
        [[ -f $f ]] || continue
        [[ $1 && ${f##*/} == "${1}.hop" ]] && continue
        awk -F= '/^ports=/{print $2}' "$f"
    done
}

hy2_hop_range_overlap() {
    local a=$1 b=$2 a1 a2 b1 b2
    hy2_hop_parse_range "$a" || return 1
    a1=$hy2_hop_start a2=$hy2_hop_end
    hy2_hop_parse_range "$b" || return 1
    b1=$hy2_hop_start b2=$hy2_hop_end
    [[ $a1 -le $b2 && $b1 -le $a2 ]]
}

hy2_hop_pick_range() {
    local used start end candidate skip
    start=$is_hy2_hop_base
    while [[ $((start + is_hy2_hop_span - 1)) -lt 32768 ]]; do
        end=$((start + is_hy2_hop_span - 1))
        candidate="${start}-${end}"
        skip=
        for used in $(hy2_hop_list_used_ranges "$1"); do
            hy2_hop_range_overlap "$candidate" "$used" && skip=1 && break
        done
        [[ ! $skip ]] && {
            is_hy2_hop_ports=$candidate
            return
        }
        start=$((start + is_hy2_hop_span))
    done
    err "无法自动分配 Hysteria2 端口跳跃范围, 请手动指定: $is_core add hy2 [port] [password] [start-end]"
}

hy2_hop_validate_or_pick() {
    local used
    if [[ $is_hy2_hop_off ]]; then
        unset is_hy2_hop_ports
        return
    fi
    if [[ $is_hy2_hop_ports ]]; then
        hy2_hop_parse_range "$is_hy2_hop_ports" || err "无效的端口跳跃范围 ($is_hy2_hop_ports), 格式: 26800-27799"
        for used in $(hy2_hop_list_used_ranges "$is_config_file"); do
            hy2_hop_range_overlap "$is_hy2_hop_ports" "$used" && {
                err "端口跳跃范围 ($is_hy2_hop_ports) 与已有配置冲突 ($used)"
            }
        done
        return
    fi
    hy2_hop_pick_range "$is_config_file"
}

hy2_hop_find_bin() {
    local name=$1 p
    for p in $(type -P "$name" 2>/dev/null) /usr/sbin/"$name" /sbin/"$name" /usr/bin/"$name" /bin/"$name"; do
        [[ -x $p ]] && {
            echo "$p"
            return
        }
    done
    return 1
}

hy2_hop_resolve_bins() {
    hy2_hop_nft_bin=$(hy2_hop_find_bin nft)
    hy2_hop_ipt_bin=$(hy2_hop_find_bin iptables)
    [[ ! $hy2_hop_ipt_bin ]] && hy2_hop_ipt_bin=$(hy2_hop_find_bin iptables-nft)
    [[ ! $hy2_hop_ipt_bin ]] && hy2_hop_ipt_bin=$(hy2_hop_find_bin iptables-legacy)
    hy2_hop_ip6t_bin=$(hy2_hop_find_bin ip6tables)
    [[ ! $hy2_hop_ip6t_bin ]] && hy2_hop_ip6t_bin=$(hy2_hop_find_bin ip6tables-nft)
    [[ ! $hy2_hop_ip6t_bin ]] && hy2_hop_ip6t_bin=$(hy2_hop_find_bin ip6tables-legacy)
}

hy2_hop_install_tools() {
    local pkgs
    [[ $hy2_hop_tools_tried ]] && return 1
    hy2_hop_tools_tried=1
    msg "正在安装 iptables/nftables 以启用 Hysteria2 端口跳跃..."
    if [[ $cmd =~ apt-get ]]; then
        $cmd update -y &>/dev/null
        $cmd install -y iptables iptables-persistent &>/dev/null || $cmd install -y iptables &>/dev/null
    elif [[ $cmd =~ yum || $cmd =~ dnf ]]; then
        $cmd install -y iptables iptables-nft &>/dev/null || $cmd install -y iptables &>/dev/null
    elif [[ $cmd =~ zypper ]]; then
        $cmd install -y iptables &>/dev/null
    elif [[ $cmd =~ apk ]]; then
        $cmd add iptables iptables-legacy &>/dev/null || $cmd add iptables &>/dev/null
        $cmd add nftables &>/dev/null
    else
        return 1
    fi
    # ensure PATH can see sbin tools for later calls
    export PATH="/usr/sbin:/sbin:$PATH"
    hy2_hop_resolve_bins
    [[ $hy2_hop_ipt_bin || $hy2_hop_nft_bin ]]
}

hy2_hop_ensure_tools() {
    hy2_hop_resolve_bins
    [[ $hy2_hop_ipt_bin || $hy2_hop_nft_bin ]] && return
    hy2_hop_install_tools || return 1
    hy2_hop_resolve_bins
    [[ $hy2_hop_ipt_bin || $hy2_hop_nft_bin ]]
}

hy2_hop_backend() {
    hy2_hop_resolve_bins
    # prefer iptables REDIRECT (matches official Hysteria docs); nft as fallback
    if [[ $hy2_hop_ipt_bin ]]; then
        echo iptables
    elif [[ $hy2_hop_nft_bin ]]; then
        echo nft
    else
        echo none
    fi
}

hy2_hop_modprobe_nat() {
    modprobe iptable_nat &>/dev/null
    modprobe ip6table_nat &>/dev/null
    modprobe xt_REDIRECT &>/dev/null
    modprobe nf_nat &>/dev/null
}

hy2_hop_remove_rules() {
    local listen_port=$1 range=$2 tag start end
    [[ $listen_port && $range ]] || return
    hy2_hop_parse_range "$range" || return
    start=$hy2_hop_start
    end=$hy2_hop_end
    tag="${is_hy2_hop_comment_prefix}-${listen_port}"
    hy2_hop_resolve_bins

    if [[ $hy2_hop_nft_bin ]]; then
        "$hy2_hop_nft_bin" delete chain inet $is_hy2_hop_nft_table "$tag" &>/dev/null
    fi
    if [[ $hy2_hop_ipt_bin ]]; then
        while "$hy2_hop_ipt_bin" -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null; do
            "$hy2_hop_ipt_bin" -t nat -D PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null || break
        done
        # also try without comment match (older/busybox iptables)
        while "$hy2_hop_ipt_bin" -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" &>/dev/null; do
            "$hy2_hop_ipt_bin" -t nat -D PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" &>/dev/null || break
        done
    fi
    if [[ $hy2_hop_ip6t_bin ]]; then
        while "$hy2_hop_ip6t_bin" -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null; do
            "$hy2_hop_ip6t_bin" -t nat -D PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null || break
        done
        while "$hy2_hop_ip6t_bin" -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" &>/dev/null; do
            "$hy2_hop_ip6t_bin" -t nat -D PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" &>/dev/null || break
        done
    fi
}

hy2_hop_add_rules() {
    local listen_port=$1 range=$2 tag start end
    [[ $listen_port && $range ]] || return
    hy2_hop_parse_range "$range" || return
    start=$hy2_hop_start
    end=$hy2_hop_end
    tag="${is_hy2_hop_comment_prefix}-${listen_port}"

    hy2_hop_ensure_tools || {
        warn "未找到 nftables/iptables, 无法自动配置 Hysteria2 端口跳跃; 请手动安装: apt/yum/apk install iptables"
        warn "然后执行: $is_core hy2-hop-restore  或手动转发 UDP $range -> $listen_port"
        return 1
    }
    hy2_hop_modprobe_nat

    case $(hy2_hop_backend) in
    nft)
        "$hy2_hop_nft_bin" add table inet $is_hy2_hop_nft_table &>/dev/null
        "$hy2_hop_nft_bin" delete chain inet $is_hy2_hop_nft_table "$tag" &>/dev/null
        "$hy2_hop_nft_bin" add chain inet $is_hy2_hop_nft_table "$tag" '{ type nat hook prerouting priority dstnat; policy accept; }' &>/dev/null || {
            warn "nftables 添加 Hysteria2 端口跳跃规则失败."
            return 1
        }
        "$hy2_hop_nft_bin" add rule inet $is_hy2_hop_nft_table "$tag" udp dport ${start}-${end} redirect to :"$listen_port" comment \""$tag"\" &>/dev/null || {
            warn "nftables 添加 Hysteria2 端口跳跃规则失败."
            return 1
        }
        ;;
    iptables)
        if ! "$hy2_hop_ipt_bin" -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null && \
           ! "$hy2_hop_ipt_bin" -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" &>/dev/null; then
            if ! "$hy2_hop_ipt_bin" -t nat -A PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null; then
                # busybox / limited iptables may not support comment
                "$hy2_hop_ipt_bin" -t nat -A PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" || {
                    warn "iptables 添加 Hysteria2 端口跳跃规则失败 (可能是容器未开放 netfilter NAT)."
                    return 1
                }
            fi
        fi
        if [[ $hy2_hop_ip6t_bin ]]; then
            if ! "$hy2_hop_ip6t_bin" -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null && \
               ! "$hy2_hop_ip6t_bin" -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" &>/dev/null; then
                "$hy2_hop_ip6t_bin" -t nat -A PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null || \
                    "$hy2_hop_ip6t_bin" -t nat -A PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" &>/dev/null
            fi
        fi
        ;;
    *)
        warn "未找到 nftables/iptables, 无法自动配置 Hysteria2 端口跳跃; 请手动转发 UDP $range -> $listen_port"
        return 1
        ;;
    esac
}

hy2_hop_save() {
    local name=$1 listen_port=$2 range=$3 file
    file=$(hy2_hop_file_of "$name")
    cat >"$file" <<EOF
listen_port=${listen_port}
ports=${range}
EOF
}

hy2_hop_load_file() {
    local file=$1
    unset is_hy2_hop_ports is_hy2_hop_listen
    [[ -f $file ]] || return 1
    is_hy2_hop_listen=$(awk -F= '/^listen_port=/{print $2}' "$file")
    is_hy2_hop_ports=$(awk -F= '/^ports=/{print $2}' "$file")
    [[ $is_hy2_hop_ports ]]
}

hy2_hop_remove_for_config() {
    local name=$1 file listen_port range
    file=$(hy2_hop_file_of "$name")
    [[ -f $file ]] || return
    hy2_hop_load_file "$file"
    listen_port=${is_hy2_hop_listen:-$port}
    range=$is_hy2_hop_ports
    hy2_hop_remove_rules "$listen_port" "$range"
    rm -f "$file"
}

hy2_hop_apply_for_config() {
    local name=$1 listen_port=$2 range=$3
    [[ $is_gen || $is_test_json ]] && return
    [[ $range ]] || return
    hy2_hop_remove_for_config "$name"
    # always persist hop intent so share links keep mport; NAT rules are best-effort
    hy2_hop_save "$name" "$listen_port" "$range"
    if hy2_hop_add_rules "$listen_port" "$range"; then
        hy2_hop_ensure_persist
        msg "已启用端口跳跃: UDP $range -> $listen_port"
        warn "请确认云厂商安全组 / 系统防火墙已放行 UDP $range"
    else
        warn "端口跳跃链接已生成 (mport=$range), 但系统 NAT 规则未生效; 安装 iptables 后执行: $is_core hy2-hop-restore"
    fi
}

hy2_hop_restore_all() {
    local f name listen_port range
    for f in "$is_conf_dir"/*.hop; do
        [[ -f $f ]] || continue
        hy2_hop_load_file "$f" || continue
        name=${f##*/}
        name=${name%.hop}
        listen_port=$is_hy2_hop_listen
        range=$is_hy2_hop_ports
        [[ $listen_port && $range ]] || continue
        hy2_hop_remove_rules "$listen_port" "$range"
        hy2_hop_add_rules "$listen_port" "$range" &>/dev/null
    done
}

hy2_hop_clear_all() {
    local f name
    for f in "$is_conf_dir"/*.hop; do
        [[ -f $f ]] || continue
        name=${f##*/}
        name=${name%.hop}
        hy2_hop_remove_for_config "$name"
    done
    hy2_hop_resolve_bins
    if [[ $hy2_hop_nft_bin ]]; then
        "$hy2_hop_nft_bin" delete table inet $is_hy2_hop_nft_table &>/dev/null
    fi
}

hy2_hop_ensure_persist() {
    # keep service unit able to restore NAT rules after reboot
    [[ $is_hy2_hop_persist_ok ]] && return
    if [[ $is_systemd && -f /lib/systemd/system/$is_core.service ]]; then
        if ! grep -q 'hy2-hop-restore' /lib/systemd/system/$is_core.service; then
            load systemd.sh
            install_service $is_core
        fi
    elif [[ $is_openrc && -f /etc/init.d/$is_core ]]; then
        if ! grep -q 'hy2-hop-restore' /etc/init.d/$is_core; then
            load systemd.sh
            install_service $is_core
        fi
    fi
    is_hy2_hop_persist_ok=1
}

hy2_hop_prepare_listen_port() {
    # avoid placing listen_port inside the hop redirect range
    [[ $is_hy2_hop_ports && $port ]] || return
    hy2_hop_port_in_range "$port" "$is_hy2_hop_ports" || return
    if [[ $is_use_port ]]; then
        err "监听端口 ($port) 不能位于端口跳跃范围 ($is_hy2_hop_ports) 内"
    fi
    local tries=0
    while hy2_hop_port_in_range "$port" "$is_hy2_hop_ports"; do
        ((tries++))
        [[ $tries -ge 50 ]] && err "自动获取端口与跳跃范围 ($is_hy2_hop_ports) 冲突次数过多."
        get_port
        port=$tmp_port
    done
}
