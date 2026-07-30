#!/bin/sh
# Shared helpers for luci-app-hinet-multidial.
# Sourced by /etc/init.d/hinet-multidial and /usr/libexec/rpcd/luci.hinet-multidial.
#
# INVARIANT: this code only ever manipulates interfaces named wanp1..wanp6 that
# carry proto=pppoe AND the marker option `managed_by=hinet-multidial`. The DHCP
# WAN lifeline (network.wan, proto=dhcp) can never be matched, so SSH is safe.

. /lib/functions.sh

HMD_WAN_DEV="${HMD_WAN_DEV:-eth1}"   # physical uplink shared by every session
HMD_MTU=1492                         # 1500 - 8B PPPoE/PPP overhead
HMD_ZONE_NAME="wanppp"               # firewall zone that owns all sessions
HMD_TAG="hinet-multidial"            # ownership marker on managed interfaces
HMD_MAX=6
HMD_DEFAULT_DOMAIN="@hinet.net"      # appended to a bare HN account number

# ---- WireGuard egress ------------------------------------------------------
HMD_WG_ZONE="wg"                     # firewall zone owning wg1..wg6
HMD_WG_SUBNET_BASE=200               # wg<i> uses 10.(200+i).0.0/24
HMD_WG_MTU=1420
HMD_MARK_MASK="0xff00"               # fwmark mask (mark i = i<<8)
HMD_MARK_PREF_BASE=21000             # ip-rule preference base for fwmark rules
HMD_MARK_NFT="/etc/nftables.d/25-hinet-mark.nft"

# Resolve a stored account into a full PPPoE username: a bare HN number gets
# @hinet.net appended; anything already containing '@' is used verbatim (so
# other ISPs still work). Empty stays empty.
hmd_resolve_user() {
	local u="$1"
	case "$u" in
		''|*@*) echo "$u" ;;
		*)      echo "${u}${HMD_DEFAULT_DOMAIN}" ;;
	esac
}

# Echo the section names of every proto=pppoe interface, sorted.
hmd_managed_ifaces() {
	local list=""
	config_load network
	_c() { local p; config_get p "$1" proto; [ "$p" = "pppoe" ] && list="$list $1"; }
	config_foreach _c interface
	# shellcheck disable=SC2086
	printf '%s\n' $list | sort
}

# Persist auto=0 on every proto=pppoe interface (never the dhcp wan).
hmd_autostart_off() {
	local changed=0
	config_load network
	_o() {
		local p a
		config_get p "$1" proto; [ "$p" = "pppoe" ] || return 0
		config_get a "$1" auto 1
		[ "$a" = "0" ] || { uci -q set network."$1".auto='0'; changed=1; }
	}
	config_foreach _o interface
	[ "$changed" = 1 ] && uci -q commit network
	return 0
}

hmd_global_user() { uci -q get hinet_multidial.main.username 2>/dev/null; }
hmd_global_pass() { uci -q get hinet_multidial.main.password 2>/dev/null; }

# The chosen number of sessions to dial (1..HMD_MAX), clamped.
hmd_count() {
	local c; c="$(uci -q get hinet_multidial.main.count 2>/dev/null)"
	case "$c" in ''|*[!0-9]*) c=1 ;; esac
	[ "$c" -ge 1 ] 2>/dev/null || c=1
	[ "$c" -le "$HMD_MAX" ] || c="$HMD_MAX"
	echo "$c"
}

# Emit the desired sessions as TAB-separated "index<TAB>user<TAB>pass" lines:
# wanp1..wanp<count>, all sharing the single global PPPoE account.
hmd_desired() {
	local gu gp cnt i
	gu="$(hmd_resolve_user "$(hmd_global_user)")"; gp="$(hmd_global_pass)"
	cnt="$(hmd_count)"
	i=1
	while [ "$i" -le "$cnt" ]; do
		printf '%s\t%s\t%s\n' "$i" "$gu" "$gp"
		i=$((i + 1))
	done
}

# Find the sid of the firewall zone named $HMD_ZONE_NAME, creating a named one
# if none exists. Echoes the sid.
hmd_zone_sid() {
	local sid=""
	config_load firewall
	_z() { local n; config_get n "$1" name; [ "$n" = "$HMD_ZONE_NAME" ] && sid="$1"; }
	config_foreach _z zone
	if [ -z "$sid" ]; then
		sid="zone_${HMD_ZONE_NAME}"
		uci -q set firewall."$sid"='zone'
		uci -q set firewall."$sid".name="$HMD_ZONE_NAME"
	fi
	echo "$sid"
}

# Ensure the sessions' firewall zone has safe policy (input DROP, masquerade).
hmd_ensure_zone() {
	local sid; sid="$(hmd_zone_sid)"
	uci -q set firewall."$sid".input='DROP'
	uci -q set firewall."$sid".output='ACCEPT'
	uci -q set firewall."$sid".forward='DROP'
	uci -q set firewall."$sid".masq='1'
	uci -q set firewall."$sid".mtu_fix='1'
	echo "$sid"
}

# Reconcile network + firewall from the desired session list in hinet_multidial.
# Creates/updates wanp<i>, deletes managed wanp<j> no longer wanted, keeps them
# all confined to private routing tables 100+i. Reloads network + firewall.
hmd_reconcile() {
	local wp wd
	wp="$(uci -q get network.wan.proto)"; wd="$(uci -q get network.wan.device)"
	[ "$wp" = "dhcp" ] || { echo "ABORT: network.wan.proto='$wp' (expected dhcp) — refusing to touch network"; return 1; }

	local desired ids zsid i u p
	desired="$(hmd_desired | sort -n)"
	ids="$(printf '%s\n' "$desired" | awk -F'\t' 'NF>=1 && $1!="" && !seen[$1]++ {print $1}')"

	zsid="$(hmd_ensure_zone)"

	# 1) drop managed sessions whose index is no longer desired
	config_load network
	_del() {
		local name="$1" proto tag n
		case "$name" in wanp[1-6]) ;; *) return 0 ;; esac
		config_get proto "$name" proto; [ "$proto" = "pppoe" ] || return 0
		config_get tag "$name" managed_by ""; [ "$tag" = "$HMD_TAG" ] || return 0
		n="${name#wanp}"
		if ! printf '%s\n' $ids | grep -qx "$n"; then
			ifdown "$name" 2>/dev/null
			uci -q delete network."$name"
			uci -q del_list firewall."$zsid".network="$name"
			logger -t hinet-multidial "reconcile: removed $name"
		fi
	}
	config_foreach _del interface

	# 2) create/update desired sessions
	for i in $ids; do
		[ -n "$i" ] || continue
		u="$(printf '%s\n' "$desired" | awk -F'\t' -v k="$i" '$1==k{print $2; exit}')"
		p="$(printf '%s\n' "$desired" | awk -F'\t' -v k="$i" '$1==k{print $3; exit}')"
		local ifc="wanp$i" tbl=$((100 + i))
		uci -q batch <<EOF
set network.$ifc=interface
set network.$ifc.proto=pppoe
set network.$ifc.device=$HMD_WAN_DEV
set network.$ifc.username=$u
set network.$ifc.password=$p
set network.$ifc.mtu=$HMD_MTU
set network.$ifc.ipv6=0
set network.$ifc.auto=0
set network.$ifc.defaultroute=0
set network.$ifc.peerdns=0
set network.$ifc.keepalive=5 20
set network.$ifc.ip4table=$tbl
set network.$ifc.managed_by=$HMD_TAG
EOF
		uci -q del_list firewall."$zsid".network="$ifc"
		uci -q add_list firewall."$zsid".network="$ifc"
		logger -t hinet-multidial "reconcile: ensured $ifc (table $tbl)"
	done

	# 3) WireGuard egress tunnels (optional): wg<i> bound to session i.
	if [ "$(uci -q get hinet_multidial.main.wg_enabled)" = "1" ]; then
		hmd_wg_ensure_keys
		hmd_wg_reconcile "$ids"
	else
		hmd_wg_teardown
	fi

	uci -q commit network
	uci -q commit firewall

	# Detach the reload into its own session so an rpcd-invoked apply returns
	# immediately. A synchronous reload here can exceed the ubus timeout AND the
	# ucitrack reload cascade can disrupt rpcd while it is blocked handling the
	# request, wedging it. setsid fully decouples it from rpcd's process group.
	setsid sh -c 'sleep 1; /etc/init.d/network reload; /etc/init.d/firewall reload' \
		</dev/null >/dev/null 2>&1 &

	echo "OK: $(printf '%s' "$ids" | wc -w | tr -d ' ') session(s) reconciled; reload scheduled"
}

# Validate that a name is a currently-defined managed pppoe interface.
hmd_is_managed() {
	local want="$1" f
	for f in $(hmd_managed_ifaces); do [ "$f" = "$want" ] && return 0; done
	return 1
}

# ---- WireGuard helpers -----------------------------------------------------

# Listen port for tunnel i = wg_port_base + i.
hmd_wg_port() {
	local base; base="$(uci -q get hinet_multidial.main.wg_port_base 2>/dev/null)"
	case "$base" in ''|*[!0-9]*) base=51820 ;; esac
	echo $((base + $1))
}

# wan0's current IPv4 address (the stable client Endpoint host).
hmd_wan_ip() {
	local ip=""
	. /lib/functions/network.sh
	network_flush_cache
	network_get_ipaddr ip wan
	echo "$ip"
}

# Generate the fixed server+client keypairs and a PSK for any slot missing them.
# Idempotent; keys persist so client configs stay valid across reconciles.
hmd_wg_ensure_keys() {
	command -v wg >/dev/null 2>&1 || { logger -t hinet-multidial "wg tool missing — cannot generate keys"; return 1; }
	local i priv pub cpriv cpub psk changed=0
	i=1
	while [ "$i" -le "$HMD_MAX" ]; do
		priv="$(uci -q get hinet_multidial.wg$i.private_key)"
		if [ -z "$priv" ]; then
			priv="$(wg genkey)";  pub="$(printf '%s' "$priv"  | wg pubkey)"
			cpriv="$(wg genkey)"; cpub="$(printf '%s' "$cpriv" | wg pubkey)"
			psk="$(wg genpsk)"
			uci -q set hinet_multidial.wg$i='wg'
			uci -q set hinet_multidial.wg$i.private_key="$priv"
			uci -q set hinet_multidial.wg$i.public_key="$pub"
			uci -q set hinet_multidial.wg$i.client_key="$cpriv"
			uci -q set hinet_multidial.wg$i.client_pub="$cpub"
			uci -q set hinet_multidial.wg$i.psk="$psk"
			changed=1
			logger -t hinet-multidial "wg$i: generated fixed keypair + PSK"
		fi
		i=$((i + 1))
	done
	[ "$changed" = 1 ] && uci -q commit hinet_multidial
	return 0
}

# Ensure the 'wg' firewall zone exists with safe policy + forwardings.
# input ACCEPT: peers are key-authenticated (LAN access + router DNS).
# egress to LAN uses the main table; egress to the internet is steered to the
# session's PPPoE table by the fwmark chain and masqueraded by the wanppp zone.
hmd_wg_ensure_zone() {
	uci -q batch <<EOF
set firewall.zone_wg='zone'
set firewall.zone_wg.name='$HMD_WG_ZONE'
set firewall.zone_wg.input='ACCEPT'
set firewall.zone_wg.output='ACCEPT'
set firewall.zone_wg.forward='REJECT'
set firewall.zone_wg.masq='1'
set firewall.zone_wg.mtu_fix='1'
set firewall.fwd_wg_lan='forwarding'
set firewall.fwd_wg_lan.src='$HMD_WG_ZONE'
set firewall.fwd_wg_lan.dest='lan'
set firewall.fwd_wg_wanppp='forwarding'
set firewall.fwd_wg_wanppp.src='$HMD_WG_ZONE'
set firewall.fwd_wg_wanppp.dest='$HMD_ZONE_NAME'
EOF
}

# Create/update WireGuard interface wg<i> + its single client peer + firewall.
hmd_wg_add() {
	local i="$1" port subnet priv psk cpub
	port="$(hmd_wg_port "$i")"
	subnet="10.$((HMD_WG_SUBNET_BASE + i)).0"
	priv="$(uci -q get hinet_multidial.wg$i.private_key)"
	psk="$(uci -q get hinet_multidial.wg$i.psk)"
	cpub="$(uci -q get hinet_multidial.wg$i.client_pub)"
	[ -n "$priv" ] || return 0

	uci -q delete network.wg$i
	uci -q batch <<EOF
set network.wg$i='interface'
set network.wg$i.proto='wireguard'
set network.wg$i.private_key='$priv'
set network.wg$i.listen_port='$port'
set network.wg$i.mtu='$HMD_WG_MTU'
add_list network.wg$i.addresses='$subnet.1/24'
EOF
	# single client peer (recreate)
	while uci -q delete network.@wireguard_wg$i[0]; do :; done
	uci -q add network wireguard_wg$i >/dev/null
	uci -q set network.@wireguard_wg$i[-1].description='client'
	uci -q set network.@wireguard_wg$i[-1].public_key="$cpub"
	uci -q set network.@wireguard_wg$i[-1].preshared_key="$psk"
	uci -q add_list network.@wireguard_wg$i[-1].allowed_ips="$subnet.2/32"
	uci -q set network.@wireguard_wg$i[-1].persistent_keepalive='25'

	uci -q del_list firewall.zone_wg.network="wg$i"
	uci -q add_list firewall.zone_wg.network="wg$i"

	# open the listen port on wan0 (ingress rides the stable wan IP)
	uci -q batch <<EOF
set firewall.hmd_wgallow_$i='rule'
set firewall.hmd_wgallow_$i.name='Allow-wg$i'
set firewall.hmd_wgallow_$i.src='wan'
set firewall.hmd_wgallow_$i.proto='udp'
set firewall.hmd_wgallow_$i.dest_port='$port'
set firewall.hmd_wgallow_$i.target='ACCEPT'
EOF
	logger -t hinet-multidial "wg$i: ensured (udp $port, $subnet.1/24)"
}

# Remove WireGuard interface wg<i> + peer + firewall allow.
hmd_wg_del() {
	local i="$1"
	[ -d /sys/class/net/wg$i ] && ifdown "wg$i" >/dev/null 2>&1
	while uci -q delete network.@wireguard_wg$i[0]; do :; done
	uci -q delete network.wg$i
	uci -q delete firewall.hmd_wgallow_$i
	uci -q del_list firewall.zone_wg.network="wg$i"
}

# Reconcile WG tunnels to the given active session-index list.
hmd_wg_reconcile() {
	local active="$1" i
	hmd_wg_ensure_zone
	i=1
	while [ "$i" -le "$HMD_MAX" ]; do
		if printf '%s\n' $active | grep -qx "$i"; then
			hmd_wg_add "$i"
		else
			hmd_wg_del "$i"
		fi
		i=$((i + 1))
	done
	hmd_write_mark_nft "$active"
}

# Tear down every WG tunnel, the zone, and the mark chain.
hmd_wg_teardown() {
	local i=1
	while [ "$i" -le "$HMD_MAX" ]; do hmd_wg_del "$i"; i=$((i + 1)); done
	uci -q delete firewall.zone_wg
	uci -q delete firewall.fwd_wg_lan
	uci -q delete firewall.fwd_wg_wanppp
	rm -f "$HMD_MARK_NFT"
}

# (Re)write the fwmark chain: mark only public-bound traffic from wg<i> so it
# egresses via PPPoE session i; LAN/RFC1918 stays unmarked -> main table -> wan0.
hmd_write_mark_nft() {
	local active="$1" i mark body=""
	for i in $active; do
		[ -n "$i" ] || continue
		mark="$(printf '0x%02x00' "$i")"
		body="${body}	iifname \"wg$i\" ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } meta mark set $mark comment \"wg$i -> pppoe session $i\"
"
	done
	if [ -z "$body" ]; then rm -f "$HMD_MARK_NFT"; return 0; fi
	mkdir -p /etc/nftables.d
	cat > "$HMD_MARK_NFT" <<EOF
# Generated by hinet-multidial — do not edit. Steers WG client internet traffic
# to its PPPoE session (mark i = i<<8); LAN/RFC1918 is left on the main table.
chain hmd_mark_prerouting {
	type filter hook prerouting priority -140; policy accept;
$body}
EOF
}

# Emit a client .conf for tunnel i (Endpoint = wan0 IP:port).
hmd_wg_client_conf() {
	local i="$1" port subnet ckey spub psk ip
	port="$(hmd_wg_port "$i")"
	subnet="10.$((HMD_WG_SUBNET_BASE + i)).0"
	ckey="$(uci -q get hinet_multidial.wg$i.client_key)"
	spub="$(uci -q get hinet_multidial.wg$i.public_key)"
	psk="$(uci -q get hinet_multidial.wg$i.psk)"
	ip="$(hmd_wan_ip)"
	[ -n "$ckey" ] || return 1
	cat <<EOF
[Interface]
PrivateKey = $ckey
Address = $subnet.2/32
DNS = 1.1.1.1
MTU = $HMD_WG_MTU

[Peer]
PublicKey = $spub
PresharedKey = $psk
Endpoint = ${ip:-<wan-ip>}:$port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}
