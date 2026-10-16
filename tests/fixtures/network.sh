# Safe replacement for /lib/functions/network.sh in staged test copies.
network_flush_cache() { :; }
network_is_up() { [ "$1" = lan ] && [ "$MOCK_LAN_UP" = 1 ]; }
network_get_device() { [ "$2" = lan ] || return 1; eval "$1=\$MOCK_LAN_DEV"; }
network_get_ipaddr() { [ "$2" = lan ] || return 1; eval "$1=\$MOCK_LAN_IP"; }
