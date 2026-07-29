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
	gu="$(hmd_global_user)"; gp="$(hmd_global_pass)"
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
