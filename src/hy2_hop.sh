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
    # keep ranges compact to reduce accidental collisions
    [[ $((hy2_hop_end - hy2_hop_start)) -le 10000 ]] || return 1
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

hy2_hop_backend() {
    if type -P nft &>/dev/null; then
        echo nft
    elif type -P iptables &>/dev/null; then
        echo iptables
    else
        echo none
    fi
}

hy2_hop_remove_rules() {
    local listen_port=$1 range=$2 tag start end
    [[ $listen_port && $range ]] || return
    hy2_hop_parse_range "$range" || return
    start=$hy2_hop_start
    end=$hy2_hop_end
    tag="${is_hy2_hop_comment_prefix}-${listen_port}"

    if type -P nft &>/dev/null; then
        nft delete chain inet $is_hy2_hop_nft_table "$tag" &>/dev/null
    fi
    if type -P iptables &>/dev/null; then
        while iptables -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null; do
            iptables -t nat -D PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null || break
        done
    fi
    if type -P ip6tables &>/dev/null; then
        while ip6tables -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null; do
            ip6tables -t nat -D PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null || break
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

    case $(hy2_hop_backend) in
    nft)
        nft add table inet $is_hy2_hop_nft_table &>/dev/null
        nft delete chain inet $is_hy2_hop_nft_table "$tag" &>/dev/null
        nft add chain inet $is_hy2_hop_nft_table "$tag" '{ type nat hook prerouting priority dstnat; policy accept; }' &>/dev/null || {
            warn "nftables 添加 Hysteria2 端口跳跃规则失败."
            return 1
        }
        nft add rule inet $is_hy2_hop_nft_table "$tag" udp dport ${start}-${end} redirect to :"$listen_port" comment \""$tag"\" &>/dev/null || {
            warn "nftables 添加 Hysteria2 端口跳跃规则失败."
            return 1
        }
        ;;
    iptables)
        iptables -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null || \
            iptables -t nat -A PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" || {
                warn "iptables 添加 Hysteria2 端口跳跃规则失败."
                return 1
            }
        if type -P ip6tables &>/dev/null; then
            ip6tables -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null || \
                ip6tables -t nat -A PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports "$listen_port" -m comment --comment "$tag" &>/dev/null
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
    # remove_for_config deletes file; re-add rules + save
    if hy2_hop_add_rules "$listen_port" "$range"; then
        hy2_hop_save "$name" "$listen_port" "$range"
        hy2_hop_ensure_persist
        msg "已启用端口跳跃: UDP $range -> $listen_port"
        warn "请确认云厂商安全组 / 系统防火墙已放行 UDP $range"
    else
        unset is_hy2_hop_ports
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
    if type -P nft &>/dev/null; then
        nft delete table inet $is_hy2_hop_nft_table &>/dev/null
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
