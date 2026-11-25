#!/bin/sh
set -eu

if [ "$#" -ne 2 ] || { [ "$1" != up ] && [ "$1" != down ]; }; then
    echo 'Usage: hotspot-firewall.sh up|down <hotspot interface>' >&2
    exit 2
fi

action=$1
interface=$2
case "$interface" in
    ''|*[!a-zA-Z0-9_.-]*) exit 2 ;;
esac

port=16415
mark=0x4257
table=186
priority=10418
chain=BYWAY_HOTSPOT

iptables_rule() {
    iptables -w 5 "$@"
}

ip6tables_rule() {
    ip6tables -w 5 "$@"
}

add_rule() {
    command=$1 ruleset=$2 parent=$3
    shift 3
    "$command" -t "$ruleset" -C "$parent" "$@" 2>/dev/null ||
        "$command" -t "$ruleset" -I "$parent" 1 "$@"
}

delete_rule() {
    command=$1 ruleset=$2 parent=$3
    shift 3
    if "$command" -t "$ruleset" -C "$parent" "$@" 2>/dev/null; then
        "$command" -t "$ruleset" -D "$parent" "$@"
    fi
}

if [ "$action" = down ]; then
    delete_rule iptables_rule mangle PREROUTING -i "$interface" -j "$chain"
    if iptables_rule -t mangle -S "$chain" >/dev/null 2>&1; then
        iptables_rule -t mangle -F "$chain"
        iptables_rule -t mangle -X "$chain"
    fi
    ip -4 rule del priority "$priority" fwmark "$mark" lookup "$table" 2>/dev/null || true
    ip -4 route del local default dev lo table "$table" 2>/dev/null || true
    for protocol in tcp udp; do
        delete_rule iptables_rule filter INPUT -p "$protocol" --dport "$port" -m mark ! --mark "$mark" -m comment --comment "$chain" -j DROP
    done
    delete_rule ip6tables_rule filter FORWARD -i "$interface" -m comment --comment "$chain" -j DROP
    delete_rule iptables_rule filter FORWARD -i "$interface" -m comment --comment "$chain" -j DROP
    exit 0
fi

existing_rule=$(ip -4 rule show priority "$priority")
case "$existing_rule" in
    ''|*"fwmark $mark lookup $table") ;;
    *) echo "Routing rule priority $priority is already in use." >&2; exit 1 ;;
esac
existing_route=$(ip -4 route show table "$table" 2>/dev/null || true)
case "$existing_route" in
    ''|'local default dev lo scope host') ;;
    *) echo "Routing table $table is already in use." >&2; exit 1 ;;
esac

# The forwarding guard stays in place when the proxy process stops.
add_rule iptables_rule filter FORWARD -i "$interface" -m comment --comment "$chain" -j DROP
add_rule ip6tables_rule filter FORWARD -i "$interface" -m comment --comment "$chain" -j DROP
for protocol in tcp udp; do
    add_rule iptables_rule filter INPUT -p "$protocol" --dport "$port" -m mark ! --mark "$mark" -m comment --comment "$chain" -j DROP
done

[ -n "$existing_rule" ] || ip -4 rule add priority "$priority" fwmark "$mark" lookup "$table"
ip -4 route replace local default dev lo table "$table"

if ! iptables_rule -t mangle -S "$chain" >/dev/null 2>&1; then
    iptables_rule -t mangle -N "$chain"
fi
iptables_rule -t mangle -F "$chain"
iptables_rule -t mangle -A "$chain" -p udp --dport 67 -j RETURN
for protocol in tcp udp; do
    iptables_rule -t mangle -A "$chain" -p "$protocol" --dport 53 -j TPROXY --on-port "$port" --tproxy-mark "$mark"
done
iptables_rule -t mangle -A "$chain" -m addrtype ! --dst-type UNICAST -j RETURN
for protocol in tcp udp; do
    iptables_rule -t mangle -A "$chain" -p "$protocol" -j TPROXY --on-port "$port" --tproxy-mark "$mark"
done
add_rule iptables_rule mangle PREROUTING -i "$interface" -j "$chain"
