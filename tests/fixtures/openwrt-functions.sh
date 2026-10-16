# Isolated OpenWrt/UCI mocks. Sourced only by tests/test-lan-wireguard.sh.
# The database and every log live inside TEST_CASE_ROOT. Mutation logs contain
# option names, never option values (in particular, never private keys).

mock_put() {
	case "$1" in ''|*/*|*..*) fail "unsafe mock UCI key" ;; esac
	printf '%s\n' "$2" > "$MOCK_UCI/$1" || fail "cannot seed mock UCI"
}

uci() {
	[ "${1-}" != -q ] || shift
	local mock_op="${1-}" mock_arg="${2-}" mock_key mock_value mock_line mock_found
	case "$mock_op" in
		get)
			[ -f "$MOCK_UCI/$mock_arg" ] || return 1
			cat "$MOCK_UCI/$mock_arg"
			;;
		set|add_list|del_list)
			mock_key="${mock_arg%%=*}"
			mock_value="${mock_arg#*=}"
			case "$mock_value" in
				\'*) mock_value="${mock_value#\'}"; mock_value="${mock_value%\'}" ;;
			esac
			printf '%s %s\n' "$mock_op" "$mock_key" >> "$MOCK_UCI_WRITES"
			case "$mock_op" in
				set) mock_put "$mock_key" "$mock_value" ;;
				add_list)
					[ ! -f "$MOCK_UCI/$mock_key" ] || mock_value="$(cat "$MOCK_UCI/$mock_key") $mock_value"
					mock_put "$mock_key" "$mock_value"
					;;
				del_list) : ;; # No list mutation is needed by the tested lifecycle.
			esac
			;;
		delete)
			mock_found=0
			for mock_key in "$MOCK_UCI/$mock_arg" "$MOCK_UCI/$mock_arg".*; do
				[ -f "$mock_key" ] || continue
				rm -f "$mock_key" || return 1
				mock_found=1
			done
			[ "$mock_found" = 1 ] || return 1
			printf 'delete %s\n' "$mock_arg" >> "$MOCK_UCI_WRITES"
			;;
		batch)
			while IFS= read -r mock_line || [ -n "$mock_line" ]; do
				[ -n "$mock_line" ] || continue
				uci "${mock_line%% *}" "${mock_line#* }" || return 1
			done
			;;
		commit)
			printf 'commit %s\n' "$mock_arg" >> "$MOCK_UCI_WRITES"
			;;
		*) fail "unsupported mock UCI operation: $mock_op" ;;
	esac
}

config_load() { MOCK_CONFIG="$1"; }

config_get() {
	local mock_dest="$1" mock_section="$2" mock_option="$3" mock_default="${4-}" mock_result
	mock_result="$(uci -q get "$MOCK_CONFIG.$mock_section.$mock_option")" || mock_result="$mock_default"
	# Only the destination is shell syntax; the value is expanded as data in an
	# assignment, so a mock option value cannot become executable shell syntax.
	eval "$mock_dest=\$mock_result"
}

config_get_bool() {
	local mock_bool
	config_get mock_bool "$2" "$3" "${4:-0}"
	case "$mock_bool" in 1|on|true|yes|enabled) mock_bool=1 ;; *) mock_bool=0 ;; esac
	eval "$1=\$mock_bool"
}

config_foreach() {
	local mock_callback="$1" mock_type="$2" mock_path mock_section
	for mock_path in "$MOCK_UCI/$MOCK_CONFIG".*; do
		[ -f "$mock_path" ] || continue
		mock_section="${mock_path##*/}"
		mock_section="${mock_section#"$MOCK_CONFIG."}"
		case "$mock_section" in *.*) continue ;; esac
		[ "$(cat "$mock_path")" = "$mock_type" ] || continue
		"$mock_callback" "$mock_section"
	done
	return 0
}

# No command below delegates to real OpenWrt/network utilities.
flock() {
	[ "${MOCK_FLOCK_STATUS:-0}" = 0 ] || return "$MOCK_FLOCK_STATUS"
	if [ "$TEST_REAL_FLOCK" = 1 ]; then
		command flock "$@"
	else
		# Git Bash has no flock. The runner explicitly reports that its locking
		# coverage is mocked; Linux CI uses real flock and checks exclusivity.
		[ "$*" = '-x 9' ] || fail "unexpected flock invocation"
	fi
}
logger() { printf 'logger\n' >> "$MOCK_OPS"; }
ifup() { printf 'up %s\n' "$*" >> "$MOCK_INTERFACES"; }
ifdown() {
	local mock_gate=off
	[ ! -e "$HMD_HAIRPIN_ACTIVE" ] || mock_gate=on
	printf 'down %s gate=%s\n' "$*" "$mock_gate" >> "$MOCK_INTERFACES"
}
ip() {
	printf 'ip %s\n' "$*" >> "$MOCK_OPS"
	# End deletion loops; all other operations are harmless recorded successes.
	case "$*" in 'rule del '*) return 1 ;; esac
	return 0
}
fw4() {
	[ "$*" = check ] || fail "unexpected fw4 operation"
	printf 'fw4 check\n' >> "$MOCK_OPS"
	return "${MOCK_FW4_STATUS:-0}"
}
nft() {
	printf 'nft %s\n' "$*" >> "$MOCK_OPS"
	case "$*" in
		'list chain inet fw4 hmd_wg_hairpin') [ -f "$MOCK_RUNTIME" ] ;;
		'flush chain inet fw4 hmd_wg_hairpin')
			[ -f "$MOCK_RUNTIME" ] || return 1
			printf 'flushed\n' > "$MOCK_RUNTIME"
			;;
		'delete chain inet fw4 hmd_wg_hairpin') rm -f "$MOCK_RUNTIME" ;;
		*) fail "unexpected nft operation (must target only the owned chain)" ;;
	esac
}
mock_firewall() {
	[ "$*" = reload ] || fail "unexpected firewall operation"
	printf 'firewall reload\n' >> "$MOCK_OPS"
	[ "${MOCK_FIREWALL_STATUS:-0}" = 0 ] || return "$MOCK_FIREWALL_STATUS"
	if [ -f "$HMD_HAIRPIN_NFT" ]; then
		printf 'present\n' > "$MOCK_RUNTIME"
	else
		rm -f "$MOCK_RUNTIME"
	fi
}
mock_network() {
	[ "$*" = reload ] || fail "unexpected network operation"
	printf 'network reload\n' >> "$MOCK_OPS"
	return "${MOCK_NETWORK_STATUS:-0}"
}
mock_init() {
	printf '%s\n' "$*" >> "$MOCK_INIT_CALLS"
	[ "${1-}" = hairpin ] || fail "unexpected init command in hotplug"
	shift
	hairpin "$@"
}
procd_open_instance() { printf 'procd open\n' >> "$MOCK_OPS"; }
procd_set_param() { :; }
procd_close_instance() { :; }
procd_add_reload_trigger() { :; }
sleep() { printf 'sleep %s\n' "$*" >> "$MOCK_OPS"; }
setsid() { fail "a test attempted to launch a detached process"; }

# Observe atomic replacements without relying solely on timestamp granularity.
# This still performs a real rename, strictly inside the case's temp directory.
mv() {
	[ "${1-}" != -f ] || shift
	[ "$#" = 2 ] || fail "unexpected mv arguments"
	case "$1" in "$HMD_HAIRPIN_NFT".tmp.*) ;; *) fail "unexpected rename source" ;; esac
	[ "$2" = "$HMD_HAIRPIN_NFT" ] || fail "unexpected rename destination"
	case "$1" in *.nft) fail "temporary firewall include must not end in .nft" ;; esac
	command mv -f "$1" "$2" || return 1
	printf 'atomic replacement\n' >> "$MOCK_WRITES"
}
