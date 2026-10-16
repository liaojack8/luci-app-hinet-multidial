#!/bin/sh
# Run with: sh tests/test-lan-wireguard.sh
# Pure shell; works with Git Bash sh and Linux /bin/sh (dash/BusyBox ash).
# Never source the host's OpenWrt libraries, invoke real network commands, or
# write under /etc, /var/run, /sys. Only staged temporary copies are executed.

set -u
TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" || exit 1
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/.." && pwd)" || exit 1
SOURCE_ROOT="$REPO_ROOT/luci-app-hinet-multidial/root"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmd-lan-test.XXXXXX")" || exit 1
trap 'rm -rf "$TEST_TMP"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
	printf '    FAIL: %s\n' "$*" >&2
	# A failed mock inside a command substitution/background subshell may have
	# its exit status swallowed by production code. Persist a failure sentinel
	# so the outer test can never accidentally report that case as passing.
	if [ -n "${TEST_CASE_ROOT:-}" ] && [ -d "$TEST_CASE_ROOT" ]; then
		: > "$TEST_CASE_ROOT/.failed"
	fi
	exit 1
}
assert_eq() { [ "$1" = "$2" ] || fail "${3:-values differ} (expected <$1>, got <$2>)"; }
assert_file() { [ -f "$1" ] || fail "${2:-expected file to exist}"; }
assert_absent() { [ ! -e "$1" ] || fail "${2:-expected path to be absent}"; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "${3:-expected file content missing}"; }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "${3:-unexpected file content}"; }
assert_lines() {
	local actual
	actual="$(wc -l < "$2" | tr -d '[:space:]')"
	assert_eq "$1" "$actual" "${3:-wrong line count}"
}
assert_ops() {
	local actual
	actual="$(grep -Fxc -- "$2" "$MOCK_OPS" || :)"
	assert_eq "$1" "$actual" "unexpected number of $2 operations"
}
expect_failure() {
	if "$@"; then fail "expected command to fail: $1"; fi
}

# sed affects only the temporary copies. Replace *all* absolute runtime paths
# needed by these tests, including strings inside detached sh -c commands. A
# final audit fails closed if any live OpenWrt path remains in a staged script.
# Normalize CRLF in staged copies as well (Windows autocrlf checkouts in WSL).
stage_script() {
	sed \
		-e "s/$(printf '\r')\$//" \
		-e 's@/lib/functions/network\.sh@"$TEST_NETWORK"@g' \
		-e 's@/lib/functions\.sh@"$TEST_FUNCTIONS"@g' \
		-e 's@/usr/share/hinet-multidial/lib\.sh@"$TEST_LIB"@g' \
		-e 's@/etc/init\.d/firewall@mock_firewall@g' \
		-e 's@/etc/init\.d/network@mock_network@g' \
		-e 's@/etc/init\.d/hinet-multidial@mock_init@g' \
		-e 's@/etc/rc\.common@$TEST_RC_COMMON@g' \
		-e 's@/var/run/hinet-multidial\.pid@$TEST_CASE_ROOT/worker.pid@g' \
		-e 's@/var/run/hinet-multidial-hairpin@$TEST_TMP/staged-hairpin@g' \
		-e 's@/etc/nftables\.d@$TEST_TMP/staged-nftables.d@g' \
		-e 's@/etc/config@$TEST_TMP/staged-config@g' \
		-e 's@/sys/class/net@$TEST_TMP/staged-sys-net@g' \
		"$1" > "$2" || fail "cannot stage test copy"
	if grep -E '(/etc/|/var/run/|/lib/functions|/usr/share/hinet-multidial|/sys/class/net)' "$2" >/dev/null; then
		fail "unstubbed absolute OpenWrt path in staged script: ${1##*/}"
	fi
	sh -n "$2" || fail "staged script has invalid shell syntax"
}

TEST_REAL_FLOCK=0
if command -v flock >/dev/null 2>&1; then TEST_REAL_FLOCK=1; fi
TEST_FUNCTIONS="$TEST_DIR/fixtures/openwrt-functions.sh"
TEST_NETWORK="$TEST_DIR/fixtures/network.sh"
TEST_RC_COMMON="$TEST_TMP/rc.common"
TEST_LIB="$TEST_TMP/lib.sh"
TEST_INIT="$TEST_TMP/init.sh"
TEST_HOTPLUG="$TEST_TMP/hotplug.sh"
TEST_DEFAULTS="$TEST_TMP/defaults.sh"
: > "$TEST_RC_COMMON" # rc.common is never read from the host or executed.
stage_script "$SOURCE_ROOT/usr/share/hinet-multidial/lib.sh" "$TEST_LIB"
stage_script "$SOURCE_ROOT/etc/init.d/hinet-multidial" "$TEST_INIT"
stage_script "$SOURCE_ROOT/etc/hotplug.d/iface/26-hinet-multidial-lan" "$TEST_HOTPLUG"
stage_script "$SOURCE_ROOT/etc/uci-defaults/41-hinet-multidial-lan" "$TEST_DEFAULTS"

setup_case() {
	TEST_CASE_ROOT="$TEST_TMP/$1"
	mkdir -p "$TEST_CASE_ROOT/uci" "$TEST_CASE_ROOT/nftables.d" || fail "cannot create sandbox"
	MOCK_UCI="$TEST_CASE_ROOT/uci"
	MOCK_UCI_WRITES="$TEST_CASE_ROOT/uci-writes"
	MOCK_OPS="$TEST_CASE_ROOT/operations"
	MOCK_INTERFACES="$TEST_CASE_ROOT/interfaces"
	MOCK_INIT_CALLS="$TEST_CASE_ROOT/init-calls"
	MOCK_WRITES="$TEST_CASE_ROOT/file-writes"
	MOCK_RUNTIME="$TEST_CASE_ROOT/runtime-chain"
	HMD_HAIRPIN_NFT="$TEST_CASE_ROOT/nftables.d/20-hmd-wg-hairpin.nft"
	HMD_HAIRPIN_ACTIVE="$TEST_CASE_ROOT/active"
	HMD_HAIRPIN_LOCK="$TEST_CASE_ROOT/lock"
	: > "$MOCK_UCI_WRITES"; : > "$MOCK_OPS"; : > "$MOCK_INTERFACES"
	: > "$MOCK_WRITES"; : > "$MOCK_INIT_CALLS"
	MOCK_LAN_UP=1 MOCK_LAN_DEV=br-lan MOCK_LAN_IP=192.168.58.254
	MOCK_FW4_STATUS=0 MOCK_FIREWALL_STATUS=0 MOCK_NETWORK_STATUS=0 MOCK_FLOCK_STATUS=0
	PKG_UPGRADE=0 IPKG_INSTROOT=""
	. "$TEST_LIB"
	. "$TEST_INIT"
	# Most sync tests replace LAN discovery with a deterministic runtime state.
	# A separate test below exercises the real validation and mocked network.sh.
	hmd_hairpin_lan() {
		[ "$MOCK_LAN_UP" = 1 ] || return 1
		HMD_LAN_DEV="$MOCK_LAN_DEV" HMD_LAN_IP="$MOCK_LAN_IP"
	}
	mock_put hinet_multidial.main controller
	mock_put hinet_multidial.main.count 1
	mock_put hinet_multidial.main.wg_enabled 1
	mock_put hinet_multidial.main.enabled 0
	mock_put hinet_multidial.main.wg_port_base 51820
	# The user's PPPoE WAN is deliberately tagged too: name checking, not only
	# proto/marker checking, must still prevent its use by the controller.
	mock_put network.wan interface
	mock_put network.wan.proto pppoe
	mock_put network.wan.managed_by hinet-multidial
	mock_put network.wan.auto 1
	mock_put network.wan.private_key synthetic-wan-secret
	printf 'active\n' > "$HMD_HAIRPIN_ACTIVE"
}

seed_slot() {
	local i="$1" port="${2:-51821}"
	mock_put "network.wanp$i" interface
	mock_put "network.wanp$i.proto" pppoe
	mock_put "network.wanp$i.managed_by" hinet-multidial
	mock_put "network.wanp$i.auto" 1
	mock_put "network.wg$i" interface
	mock_put "network.wg$i.proto" wireguard
	mock_put "network.wg$i.private_key" "synthetic-private-$i"
	mock_put "hinet_multidial.wg$i.private_key" "synthetic-private-$i"
	mock_put "network.wg$i.listen_port" "$port"
}

reset_observations() {
	: > "$MOCK_OPS"; : > "$MOCK_WRITES"; : > "$MOCK_UCI_WRITES"
	: > "$MOCK_INTERFACES"; : > "$MOCK_INIT_CALLS"
}

assert_no_wan_changes() {
	assert_eq 1 "$(uci get network.wan.auto)" "WAN auto flag must be unchanged"
	assert_eq pppoe "$(uci get network.wan.proto)" "WAN protocol must be unchanged"
	assert_eq synthetic-wan-secret "$(uci get network.wan.private_key)" "WAN data must be unchanged"
	if grep -E '^(up|down) wan([[:space:]]|$)|^(up|down) wanp[78]([[:space:]]|$)' "$MOCK_INTERFACES" >/dev/null; then
		fail "controller touched an unmanaged WAN interface"
	fi
	if grep -E '^(set|delete|add_list|del_list) network\.wan(\.|$)' "$MOCK_UCI_WRITES" >/dev/null; then
		fail "controller changed the user's WAN UCI configuration"
	fi
}

assert_rule_text() {
	local expected="$TEST_CASE_ROOT/expected.nft"
	cat > "$expected" <<EOF
$HMD_HAIRPIN_HEADER
chain hmd_wg_hairpin {
	type nat hook prerouting priority -105; policy accept;
	iifname "$1" fib daddr type local ip daddr != $2 udp dport { $3 } counter dnat ip to $2
}
EOF
	cmp -s "$expected" "$HMD_HAIRPIN_NFT" || fail "generated DNAT differs from exact expected rule"
}

case_disabled_empty() {
	seed_slot 1
	mock_put hinet_multidial.main.wg_enabled 0
	hmd_hairpin_sync || fail "WG-off sync"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_ops 0 'firewall reload'
	mock_put hinet_multidial.main.wg_enabled 1
	MOCK_LAN_UP=0
	hmd_hairpin_sync || fail "no-LAN sync"
	assert_absent "$HMD_HAIRPIN_NFT"
	MOCK_LAN_UP=1
	uci delete network.wg1 >/dev/null
	hmd_hairpin_sync || fail "empty-WG sync"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_ops 0 'firewall reload'
	assert_lines 0 "$MOCK_WRITES"
}

case_one_slot() {
	seed_slot 1 60042
	# Actual configured listen_port wins over the application's default base.
	hmd_hairpin_sync || fail "one-slot sync"
	assert_rule_text br-lan 192.168.58.254 60042
	hmd_hairpin_file_owned || fail "generated file must be owned"
	assert_ops 1 'fw4 check'
	assert_ops 1 'firewall reload'
	assert_file "$MOCK_RUNTIME"
	assert_lines 1 "$MOCK_WRITES"
	assert_file "$HMD_HAIRPIN_LOCK" "flock lockfile should remain after descriptor release"
	set -- "$HMD_HAIRPIN_NFT".tmp.*
	assert_absent "$1" "atomic write left a temporary include"
	assert_no_wan_changes
}

case_six_ports_sorted() {
	mock_put hinet_multidial.main.count 6
	seed_slot 1 65000; seed_slot 2 9; seed_slot 3 51823
	seed_slot 4 9; seed_slot 5 00009; seed_slot 6 65535
	assert_eq '9, 51823, 65000, 65535' "$(hmd_hairpin_ports)" "ports must be numeric-sorted, normalized and unique"
	hmd_hairpin_sync || fail "six-slot sync"
	assert_rule_text br-lan 192.168.58.254 '9, 51823, 65000, 65535'
	assert_no_wan_changes
}

case_invalid_ports() {
	seed_slot 1
	local port
	for port in '' 0 65536 999999999999999999999999 -1 1.5 51821x '51821;reboot' ' 53'; do
		mock_put network.wg1.listen_port "$port"
		assert_eq '' "$(hmd_hairpin_ports)" "invalid port must be excluded"
		hmd_hairpin_sync || fail "invalid-port sync"
		assert_absent "$HMD_HAIRPIN_NFT"
	done
	for port in 1 65535; do
		mock_put network.wg1.listen_port "$port"
		assert_eq "$port" "$(hmd_hairpin_ports)" "valid boundary port"
	done
	assert_ops 0 'firewall reload'
	assert_lines 0 "$MOCK_WRITES"
	assert_not_contains "$MOCK_OPS" synthetic-private "private keys leaked to logs"
	assert_not_contains "$MOCK_UCI_WRITES" synthetic-private "private keys leaked to mutation log"
}

case_ownership_and_count() {
	mock_put hinet_multidial.main.count 6
	seed_slot 1 51001; seed_slot 2 51002; seed_slot 3 51003
	seed_slot 4 51004; seed_slot 5 51005; seed_slot 6 51006
	mock_put network.wanp2.managed_by someone-else
	mock_put network.wanp3.proto dhcp
	mock_put network.wg4.proto static
	mock_put network.wg5.private_key synthetic-different-key
	mock_put hinet_multidial.wg6.private_key ''
	# Names outside wanp1..wanp6 are never eligible, even with matching tags.
	seed_slot 7 51007
	mock_put network.wg0 interface
	mock_put network.wg0.proto wireguard
	mock_put network.wg0.listen_port 51000
	assert_eq 51001 "$(hmd_hairpin_ports)" "only owned, paired PPPoE/WG slots are eligible"
	seed_slot 2 51002
	mock_put hinet_multidial.main.count 1
	assert_eq 51001 "$(hmd_hairpin_ports)" "slots above configured count must be excluded"
	hmd_hairpin_sync || fail "ownership-filtered sync"
	assert_rule_text br-lan 192.168.58.254 51001
	assert_no_wan_changes
}

case_lan_changes_noop() {
	seed_slot 1
	hmd_hairpin_sync || fail "initial sync"
	cp "$HMD_HAIRPIN_NFT" "$TEST_CASE_ROOT/before.nft"
	# A hardlink also detects an unnoticed replacement where mtime granularity
	# is too coarse. The rename spy is the portable primary no-write assertion.
	if ln "$HMD_HAIRPIN_NFT" "$TEST_CASE_ROOT/same-inode.nft" 2>/dev/null; then
		HAVE_HARDLINK=1
	else
		HAVE_HARDLINK=0
	fi
	reset_observations
	hmd_hairpin_sync || fail "unchanged sync"
	assert_lines 0 "$MOCK_WRITES" "same content must not be rewritten"
	assert_ops 0 'firewall reload'
	cmp -s "$TEST_CASE_ROOT/before.nft" "$HMD_HAIRPIN_NFT" || fail "same-content sync changed bytes"
	if [ "$HAVE_HARDLINK" = 1 ]; then
		[ "$TEST_CASE_ROOT/same-inode.nft" -ef "$HMD_HAIRPIN_NFT" ] || fail "same-content sync replaced the file"
	fi
	MOCK_LAN_IP=192.168.99.1
	hmd_hairpin_sync || fail "LAN-IP-change sync"
	assert_rule_text br-lan 192.168.99.1 51821
	assert_lines 1 "$MOCK_WRITES"
	assert_ops 1 'firewall reload'
	MOCK_LAN_DEV=br-home
	hmd_hairpin_sync || fail "LAN-device-change sync"
	assert_rule_text br-home 192.168.99.1 51821
	assert_lines 2 "$MOCK_WRITES"
	assert_ops 2 'firewall reload'
	assert_ops 0 'network reload'
}

case_runtime_missing() {
	seed_slot 1
	hmd_hairpin_sync || fail "initial sync"
	rm -f "$MOCK_RUNTIME"
	reset_observations
	hmd_hairpin_sync || fail "restore missing runtime chain"
	assert_lines 0 "$MOCK_WRITES"
	assert_ops 1 'firewall reload'
	assert_file "$MOCK_RUNTIME"
}

case_gate_and_down() {
	seed_slot 1
	hmd_hairpin_sync || fail "initial sync"
	rm -f "$HMD_HAIRPIN_ACTIVE"
	hmd_hairpin_sync || fail "closed-gate sync"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_absent "$MOCK_RUNTIME"
	reset_observations
	hmd_hairpin_sync || fail "closed-gate repeat sync"
	assert_ops 0 'firewall reload'
	printf 'active\n' > "$HMD_HAIRPIN_ACTIVE"
	hmd_hairpin_sync || fail "reactivate sync"
	# ifdown must override deliberately stale discovery reporting LAN is up.
	hmd_hairpin_sync reload down || fail "explicit LAN-down sync"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_absent "$MOCK_RUNTIME"
	assert_file "$HMD_HAIRPIN_ACTIVE" "LAN down must not stop the whole service"
	reset_observations
	printf 'stale\n' > "$MOCK_RUNTIME"
	rm -f "$HMD_HAIRPIN_ACTIVE"
	hmd_hairpin_sync || fail "runtime-only closed-gate cleanup"
	assert_absent "$MOCK_RUNTIME"
	assert_ops 1 'firewall reload'
}

case_empty_clears_previous() {
	seed_slot 1
	local reason
	for reason in disabled lan-down empty-wg; do
		mock_put hinet_multidial.main.wg_enabled 1
		MOCK_LAN_UP=1
		seed_slot 1
		hmd_hairpin_sync || fail "seed rule for empty-data removal"
		case "$reason" in
			disabled) mock_put hinet_multidial.main.wg_enabled 0 ;;
			lan-down) MOCK_LAN_UP=0 ;;
			empty-wg) uci delete network.wg1 >/dev/null ;;
		esac
		hmd_hairpin_sync || fail "empty-data cleanup"
		assert_absent "$HMD_HAIRPIN_NFT" "empty data left include behind"
		assert_absent "$MOCK_RUNTIME" "empty data left runtime rule behind"
	done
}

case_defer_apply() {
	seed_slot 1
	hmd_hairpin_sync defer || fail "deferred create"
	assert_rule_text br-lan 192.168.58.254 51821
	assert_ops 0 'fw4 check'
	assert_ops 0 'firewall reload'
	assert_absent "$MOCK_RUNTIME"
	hmd_hairpin_sync apply || fail "scheduled apply"
	assert_ops 1 'firewall reload'
	assert_lines 1 "$MOCK_WRITES"
	reset_observations
	# apply forces exactly one reload even when a hotplug reload already applied
	# unchanged hairpin content: reconcile may have changed other WG/fw4 rules.
	hmd_hairpin_sync apply || fail "unchanged forced apply"
	assert_ops 1 'firewall reload'
	assert_lines 0 "$MOCK_WRITES"
	reset_observations
	hmd_hairpin_sync defer down || fail "deferred removal"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_absent "$MOCK_RUNTIME"
	assert_ops 0 'firewall reload'
	assert_ops 1 'nft flush chain inet fw4 hmd_wg_hairpin'
	assert_ops 1 'nft delete chain inet fw4 hmd_wg_hairpin'
	rm -f "$HMD_HAIRPIN_ACTIVE"
	reset_observations
	hmd_hairpin_sync apply || fail "empty apply still reloads once"
	assert_ops 1 'firewall reload'
}

case_reload_failure() {
	seed_slot 1
	hmd_hairpin_sync || fail "initial sync"
	MOCK_FW4_STATUS=1
	MOCK_LAN_IP=192.168.59.1
	reset_observations
	expect_failure hmd_hairpin_sync
	assert_absent "$MOCK_RUNTIME"
	assert_absent "$HMD_HAIRPIN_NFT" "failed fw4 validation must discard the generated include"
	assert_ops 1 'fw4 check'
	assert_ops 0 'firewall reload'
	assert_ops 1 'nft flush chain inet fw4 hmd_wg_hairpin'
	assert_ops 1 'nft delete chain inet fw4 hmd_wg_hairpin'
	assert_file "$HMD_HAIRPIN_LOCK"
	MOCK_FW4_STATUS=0
	hmd_hairpin_sync || fail "retry after validation failure"
	MOCK_FIREWALL_STATUS=1
	MOCK_LAN_IP=192.168.60.1
	reset_observations
	expect_failure hmd_hairpin_sync
	assert_ops 1 'firewall reload'
	assert_absent "$MOCK_RUNTIME"
	# Removing an include must report a failed reload, not falsely succeed.
	MOCK_FIREWALL_STATUS=0
	hmd_hairpin_sync || fail "restore before removal failure"
	MOCK_FW4_STATUS=1
	rm -f "$HMD_HAIRPIN_ACTIVE"
	expect_failure hmd_hairpin_sync
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_absent "$MOCK_RUNTIME"
}

case_foreign_file() {
	seed_slot 1
	printf '# administrator-owned\nchain keep_me {}\n%s\n' "$HMD_HAIRPIN_HEADER" > "$HMD_HAIRPIN_NFT"
	cp "$HMD_HAIRPIN_NFT" "$TEST_CASE_ROOT/foreign.nft"
	expect_failure hmd_hairpin_file_owned
	expect_failure hmd_hairpin_sync
	expect_failure hmd_hairpin_sync defer down
	cmp -s "$HMD_HAIRPIN_NFT" "$TEST_CASE_ROOT/foreign.nft" || fail "foreign file overwritten"
	assert_ops 0 'firewall reload'
	assert_lines 0 "$MOCK_WRITES"
	PKG_UPGRADE=1
	hmd_lan_cleanup || fail "upgrade cleanup with foreign file"
	cmp -s "$HMD_HAIRPIN_NFT" "$TEST_CASE_ROOT/foreign.nft" || fail "foreign file deleted by cleanup"
	assert_absent "$HMD_HAIRPIN_ACTIVE"
	assert_file "$HMD_HAIRPIN_LOCK"
}

case_rule_install() {
	mock_put network.manual_lan rule
	mock_put network.manual_lan.priority 9000
	mock_put network.manual_lan.lookup main
	hmd_lan_rule_install || fail "install named LAN rule"
	assert_eq 1 "$HMD_LAN_RULE_CHANGED"
	hmd_lan_rule_owned || fail "installed LAN rule must be owned"
	assert_eq rule "$(uci get network.hmd_lan_main)"
	assert_eq hinet-multidial "$(uci get network.hmd_lan_main.managed_by)"
	assert_eq main "$(uci get network.hmd_lan_main.lookup)"
	assert_eq 0 "$(uci get network.hmd_lan_main.suppress_prefixlength)"
	assert_eq 9000 "$(uci get network.hmd_lan_main.priority)"
	assert_eq 9000 "$HMD_LAN_PREF"
	[ "$HMD_LAN_PREF" -lt 10000 ] || fail "LAN rule must precede netifd source rules"
	assert_contains "$MOCK_UCI_WRITES" 'commit network'
	assert_eq rule "$(uci get network.manual_lan)" "manual rule must be preserved"
	reset_observations
	hmd_lan_rule_install || fail "idempotent named-rule install"
	assert_eq 0 "$HMD_LAN_RULE_CHANGED"
	assert_lines 0 "$MOCK_UCI_WRITES" "repeated install must not set or commit UCI"
	assert_no_wan_changes
}

case_rule_conflict() {
	local field value
	for field in managed_by lookup suppress_prefixlength priority type; do
		uci delete network.hmd_lan_main >/dev/null 2>&1 || :
		hmd_lan_rule_install || fail "seed rule for conflict"
		case "$field" in
			managed_by) value=administrator ;;
			lookup) value=101 ;;
			suppress_prefixlength) value=1 ;;
			priority) value=8999 ;;
			type) value=interface ;;
		esac
		if [ "$field" = type ]; then
			mock_put network.hmd_lan_main "$value"
		else
			mock_put "network.hmd_lan_main.$field" "$value"
		fi
		reset_observations
		expect_failure hmd_lan_rule_install
		assert_eq 0 "$HMD_LAN_RULE_CHANGED"
		expect_failure hmd_lan_rule_owned
		assert_lines 0 "$MOCK_UCI_WRITES" "conflicting named rule must never be overwritten or committed"
		hmd_lan_cleanup || fail "cleanup must tolerate foreign named rule"
		assert_file "$MOCK_UCI/network.hmd_lan_main" "cleanup deleted foreign named rule"
		assert_lines 0 "$MOCK_UCI_WRITES"
		assert_ops 0 'network reload'
	done
}

case_upgrade_remove() {
	seed_slot 1
	hmd_lan_rule_install || fail "seed owned UCI rule"
	mock_put network.manual_lan rule
	mock_put network.manual_lan.priority 9000
	hmd_hairpin_sync || fail "seed runtime rule"
	reset_observations
	PKG_UPGRADE=1
	hmd_lan_cleanup || fail "upgrade cleanup"
	hmd_lan_rule_owned || fail "upgrade deleted owned UCI rule"
	assert_absent "$HMD_HAIRPIN_ACTIVE"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_absent "$MOCK_RUNTIME"
	assert_lines 0 "$MOCK_UCI_WRITES" "upgrade must preserve UCI without committing"
	assert_ops 0 'network reload'
	reset_observations
	PKG_UPGRADE=0
	hmd_lan_cleanup || fail "package removal cleanup"
	assert_absent "$MOCK_UCI/network.hmd_lan_main"
	assert_file "$MOCK_UCI/network.manual_lan" "removal deleted manual priority-9000 rule"
	assert_lines 2 "$MOCK_UCI_WRITES" "remove should delete only the owned section and commit once"
	assert_ops 1 'network reload'
	reset_observations
	hmd_lan_cleanup || fail "idempotent package removal"
	assert_lines 0 "$MOCK_UCI_WRITES"
	assert_ops 0 'network reload'
	assert_no_wan_changes
}

case_cleanup_reload_failure() {
	seed_slot 1
	hmd_lan_rule_install || fail "seed LAN rule for failed cleanup reload"
	hmd_hairpin_sync || fail "seed hairpin for failed cleanup reload"
	reset_observations
	MOCK_NETWORK_STATUS=1
	expect_failure hmd_lan_cleanup
	assert_absent "$MOCK_UCI/network.hmd_lan_main" "UCI removal should precede failed reload"
	assert_lines 2 "$MOCK_UCI_WRITES" "failed network reload must not undo or duplicate UCI changes"
	assert_ops 1 'network reload'
	assert_absent "$HMD_HAIRPIN_ACTIVE"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_absent "$MOCK_RUNTIME"
	assert_no_wan_changes
}

run_hotplug() { ( INTERFACE="$1" ACTION="$2"; . "$TEST_HOTPLUG" ); }

case_init_hotplug() {
	seed_slot 1
	seed_slot 2 51822
	mock_put hinet_multidial.main.count 2
	rm -f "$HMD_HAIRPIN_ACTIVE"
	case " $EXTRA_COMMANDS " in *' hairpin '*) ;; *) fail "init lacks the hairpin extra command" ;; esac
	start_service || fail "init start"
	assert_file "$HMD_HAIRPIN_ACTIVE"
	assert_file "$HMD_HAIRPIN_NFT"
	assert_lines 0 "$MOCK_INTERFACES" "disabled autostart must not dial interfaces"
	assert_eq 0 "$(uci get network.wanp1.auto)"
	assert_no_wan_changes
	reset_observations
	MOCK_LAN_IP=192.168.70.1
	run_hotplug lan ifupdate || fail "LAN ifupdate hotplug"
	assert_rule_text br-lan 192.168.70.1 '51821, 51822'
	assert_eq hairpin "$(cat "$MOCK_INIT_CALLS")"
	assert_ops 1 'firewall reload'
	assert_ops 0 'network reload'
	assert_lines 0 "$MOCK_UCI_WRITES"
	reset_observations
	run_hotplug lan ifdown || fail "LAN ifdown hotplug"
	assert_eq 'hairpin down' "$(cat "$MOCK_INIT_CALLS")"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_absent "$MOCK_RUNTIME"
	run_hotplug lan ifup || fail "LAN ifup hotplug"
	assert_file "$HMD_HAIRPIN_NFT"
	reset_observations
	stop_service || fail "init stop"
	assert_absent "$HMD_HAIRPIN_ACTIVE"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_absent "$MOCK_RUNTIME"
	assert_contains "$MOCK_INTERFACES" 'down wanp1 gate=off' "stop must close gate before hanging up sessions"
	assert_contains "$MOCK_INTERFACES" 'down wanp2 gate=off'
	reset_observations
	run_hotplug lan ifup || fail "post-stop ifup"
	run_hotplug lan ifupdate || fail "post-stop ifupdate"
	assert_absent "$HMD_HAIRPIN_ACTIVE"
	assert_absent "$HMD_HAIRPIN_NFT" "post-stop hotplug resurrected include"
	assert_absent "$MOCK_RUNTIME" "post-stop hotplug resurrected runtime chain"
	assert_ops 0 'firewall reload'
	assert_lines 0 "$MOCK_INTERFACES"
	assert_no_wan_changes
}

case_hotplug_filters() {
	seed_slot 1
	local iface action
	for iface in wan wanp1 wg1 loopback ''; do
		for action in ifup ifupdate ifdown; do
			run_hotplug "$iface" "$action" || fail "ignored-interface hotplug failed"
		done
	done
	for action in iflink ifstatus config '' unknown; do
		run_hotplug lan "$action" || fail "ignored-action hotplug failed"
	done
	assert_lines 0 "$MOCK_INIT_CALLS" "hotplug must only handle LAN up/update/down"
	assert_lines 0 "$MOCK_UCI_WRITES"
	assert_lines 0 "$MOCK_INTERFACES"
	assert_ops 0 'firewall reload'
	assert_absent "$HMD_HAIRPIN_NFT"
}

case_dial_never_wan() {
	mock_put hinet_multidial.main.count 6
	seed_slot 1; seed_slot 2; seed_slot 3; seed_slot 6
	seed_slot 7
	mock_put network.wanp2.managed_by administrator
	mock_put network.wanp3.proto dhcp
	_stagger_worker 0 0 || fail "stagger worker"
	assert_lines 2 "$MOCK_INTERFACES"
	assert_contains "$MOCK_INTERFACES" 'up wanp1'
	assert_contains "$MOCK_INTERFACES" 'up wanp6'
	dial_one wan >/dev/null 2>&1 && fail "dial_one accepted user's WAN"
	stop_one wan >/dev/null 2>&1 && fail "stop_one accepted user's WAN"
	dial_one wanp2 >/dev/null 2>&1 && fail "dial_one accepted foreign PPPoE"
	stop_one wanp3 >/dev/null 2>&1 && fail "stop_one accepted non-PPPoE interface"
	stop_all || fail "stop_all"
	assert_lines 4 "$MOCK_INTERFACES"
	assert_no_wan_changes
}

case_lan_validation() {
	# Re-source to exercise the real helper, with only its absolute source path
	# substituted for a fixture (never read /lib/functions/network.sh on host).
	. "$TEST_LIB"
	seed_slot 1
	hmd_hairpin_lan || fail "valid runtime LAN should be accepted"
	assert_eq br-lan "$HMD_LAN_DEV"
	assert_eq 192.168.58.254 "$HMD_LAN_IP"
	local dev address
	for dev in '' 'bad device' 'br-lan";reboot' '0123456789abcdef'; do
		MOCK_LAN_DEV="$dev"
		expect_failure hmd_hairpin_lan
	done
	MOCK_LAN_DEV=br-lan
	for address in '' 192.168.1 192.168.1.256 127.0.0.1 0.1.2.3 224.0.0.1 '192.168.1.1;reboot' 192.168.1.0001; do
		MOCK_LAN_IP="$address"
		expect_failure hmd_hairpin_lan
	done
	MOCK_LAN_IP=192.168.58.254
	MOCK_LAN_UP=0
	expect_failure hmd_hairpin_lan
}

case_port_base_abort() {
	seed_slot 1
	mock_put hinet_multidial.main.count 6
	local base
	for base in 0 -1 65530 65535 abc '51820;reboot' 12345678901234567890; do
		mock_put hinet_multidial.main.wg_port_base "$base"
		reset_observations
		if hmd_reconcile > "$TEST_CASE_ROOT/reconcile-output" 2>&1; then
			fail "invalid WireGuard base must abort reconcile before side effects"
		fi
		assert_contains "$TEST_CASE_ROOT/reconcile-output" ABORT
		assert_lines 0 "$MOCK_UCI_WRITES"
		assert_lines 0 "$MOCK_INTERFACES"
		assert_lines 0 "$MOCK_OPS"
		assert_absent "$HMD_HAIRPIN_NFT"
		assert_no_wan_changes
	done
	mock_put hinet_multidial.main.wg_port_base 65529
	assert_eq 65535 "$(hmd_wg_port 6)" "maximum valid base+count"
	mock_put hinet_multidial.main.wg_port_base 00009
	assert_eq 10 "$(hmd_wg_port 1)" "leading zeros must be decimal, not shell octal"
	mock_put hinet_multidial.main.wg_port_base ''
	assert_eq 51821 "$(hmd_wg_port 1)" "empty base uses default"
}

case_lock_and_trap() {
	seed_slot 1
	MOCK_FLOCK_STATUS=1
	expect_failure hmd_hairpin_sync
	assert_file "$HMD_HAIRPIN_ACTIVE"
	assert_absent "$HMD_HAIRPIN_NFT"
	assert_lines 0 "$MOCK_WRITES"
	MOCK_FLOCK_STATUS=0
	# sync must not replace or run the caller's EXIT trap when its subshell exits.
	trap 'printf "caller\n" > "$TEST_CASE_ROOT/caller-trap"' EXIT
	hmd_hairpin_sync || fail "sync after lock acquisition recovers"
	assert_absent "$TEST_CASE_ROOT/caller-trap" "sync ran the caller's EXIT trap"
	assert_file "$HMD_HAIRPIN_LOCK"
	trap - EXIT
	if [ "$TEST_REAL_FLOCK" = 1 ]; then
		# Another open descriptor cannot acquire the lock while sync owns it;
		# after sync returns the same lockfile must be immediately lockable.
		hmd_hairpin_lan() {
			( command flock -n 8 ) 8>"$HMD_HAIRPIN_LOCK" && fail "sync did not hold an exclusive lock"
			HMD_LAN_DEV="$MOCK_LAN_DEV" HMD_LAN_IP="$MOCK_LAN_IP"
		}
		hmd_hairpin_sync || fail "real flock synchronization"
		( command flock -n 8 ) 8>"$HMD_HAIRPIN_LOCK" || fail "sync leaked its kernel lock"
	fi
}

case_gate_closes_during_sync() {
	seed_slot 1
	hmd_hairpin_lan() {
		HMD_LAN_DEV="$MOCK_LAN_DEV" HMD_LAN_IP="$MOCK_LAN_IP"
		# Deterministically model stop racing an in-progress LAN discovery.
		rm -f "$HMD_HAIRPIN_ACTIVE"
	}
	hmd_hairpin_sync || fail "gate-closure race sync"
	assert_absent "$HMD_HAIRPIN_NFT" "sync resurrected rule after stop closed gate"
	assert_ops 0 'firewall reload'
}

case_defaults_idempotence() {
	# The install-time ubus gate is off here: no detached process can start.
	ubus() { return 1; }
	( . "$TEST_DEFAULTS" ) || fail "initial uci-defaults run"
	hmd_lan_rule_owned || fail "defaults did not install owned rule"
	reset_observations
	( . "$TEST_DEFAULTS" ) || fail "repeated uci-defaults run"
	assert_lines 0 "$MOCK_UCI_WRITES" "defaults should not recommit identical rule"
	uci delete network.hmd_lan_main >/dev/null
	reset_observations
	IPKG_INSTROOT="$TEST_CASE_ROOT/offline-root"
	( . "$TEST_DEFAULTS" ) || fail "offline image uci-defaults run"
	assert_lines 0 "$MOCK_UCI_WRITES" "offline defaults must not alter running host config"
}

CASES='disabled_empty one_slot six_ports_sorted invalid_ports ownership_and_count lan_changes_noop runtime_missing gate_and_down empty_clears_previous defer_apply reload_failure foreign_file rule_install rule_conflict upgrade_remove cleanup_reload_failure init_hotplug hotplug_filters dial_never_wan lan_validation port_base_abort lock_and_trap gate_closes_during_sync defaults_idempotence'
PASSED=0 FAILED=0
printf 'LAN/WireGuard isolated shell regression tests\n'
if [ "$TEST_REAL_FLOCK" = 1 ]; then
	printf 'Locking: real flock (exclusive acquisition/release tested).\n'
else
	printf 'Locking: mocked; real flock/concurrency not tested on this host.\n'
fi
for name in $CASES; do
	if ( setup_case "$name" && "case_$name" && assert_absent "$TEST_CASE_ROOT/.failed" "a mock failure was swallowed" ); then
		printf 'ok %s - %s\n' "$((PASSED + FAILED + 1))" "$name"
		PASSED=$((PASSED + 1))
	else
		printf 'not ok %s - %s\n' "$((PASSED + FAILED + 1))" "$name"
		FAILED=$((FAILED + 1))
	fi
done
printf '\n%s passed; %s failed; all state isolated in temporary fixtures.\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
