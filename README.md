# luci-app-hinet-multidial

[![Build](https://github.com/liaojack8/luci-app-hinet-multidial/actions/workflows/build.yml/badge.svg)](https://github.com/liaojack8/luci-app-hinet-multidial/actions/workflows/build.yml)

A LuCI application for OpenWrt that dials **multiple PPPoE sessions over a single
physical WAN port**, each obtaining its own public IP — controlled entirely from
the web UI.

Built for HiNet (Chunghwa Telecom), whose BRAS distinguishes concurrent sessions
by PPP session ID and therefore allows several simultaneous dials on one account.
It works on any provider that permits multi-session PPPoE.

## Features

- **Pick the number of sessions (1–6)** from a dropdown. Each becomes interface
  `wanp<n>` on its own private routing table (`100 + n`), with its own public IP.
- **One shared PPPoE account** configured in the UI (no credentials in code).
- **Staggered dialing** — sessions are brought up one at a time with a
  configurable gap, so boot never fires a burst of simultaneous PPPoE PADI frames.
- **Live status** with per-session **Dial / Redial / Stop**, plus global controls.
- **Auto-dial at boot** toggle.
- **Server-side reconcile**: changing the count and hitting *Save & Apply*
  creates or removes the interfaces automatically via a procd `config.change`
  trigger — no dependence on browser state.
- **Per-session WireGuard egress** (optional): one tunnel per active session
  (`wg<i>` → `wanp<i>`). Clients connect to the **stable wan0 IP** on a per-tunnel
  port; their internet traffic exits via **that session's public IP** (fwmark →
  routing table `100+i`), while ordinary LAN users keep using wan0 and WG clients
  can still reach the LAN. Fixed keypairs (stable client configs), editable
  pre-shared key per tunnel, one-click **client config download + QR**.
- **WireGuard LAN hairpin (v1.5.2)**: the same stable public-IP/DDNS endpoint
  works from the LAN and from the Internet. A small IPv4-only rule follows the
  real LAN device and address at boot and on LAN changes, without a cron job,
  and only touches this package's own nftables chain.

## Safety by design

- The controller only ever touches interfaces named `wanp1..wanp6` that carry
  `proto=pppoe` **and** the marker `managed_by=hinet-multidial`. A `proto=dhcp`
  WAN (a common SSH/management lifeline) can never be matched or disturbed.
- Every session's default route is confined to its **private routing table**
  (`defaultroute=0` + `ip4table`), so a session can never hijack the main table
  or LAN traffic.
- Sessions live in a dedicated firewall zone (`wanppp`) with `input=DROP` and
  masquerading — they never expose management services on their public IPs.

## Install

Drop the package into an OpenWrt build tree under `package/` and select it:

```
CONFIG_PACKAGE_luci-app-hinet-multidial=y
```

It depends on `luci-base`, `ppp`, `ppp-mod-pppoe`, `kmod-wireguard`,
`wireguard-tools`, `firewall4`, and `qrencode`.

To hot-install on a running device without a rebuild, copy `root/` to `/` and
`htdocs/luci-static` to `/www/luci-static`, then run the LAN rule initializer and
make the service and hotplug scripts executable:

```sh
sh /etc/uci-defaults/41-hinet-multidial-lan
chmod +x /etc/init.d/hinet-multidial /usr/libexec/rpcd/luci.hinet-multidial \
         /etc/hotplug.d/iface/25-hinet-multidial \
         /etc/hotplug.d/iface/26-hinet-multidial-lan
/etc/init.d/hinet-multidial enable
/etc/init.d/hinet-multidial start
/etc/init.d/rpcd restart
```

## Usage

Open **Network → HiNet Multi-Dial**:

1. Enter the **PPPoE account** and **password**.
2. Choose the **number of sessions (IPs)**.
3. **Save & Apply** — the `wanp<n>` interfaces are created and appear in the
   live table within a few seconds.
4. Dial / stop sessions individually or all at once from the status table.

## WireGuard from LAN via the public endpoint

Starting with **v1.5.2**, a WireGuard client can use the same public IP or DDNS
endpoint from both the Internet and the LAN. At boot, and on `ifup`, `ifupdate`,
or `ifdown` for the logical `lan` network, the service reads the real LAN
L3 device and IPv4 address and synchronizes a small IPv4-only hairpin rule. No
cron job is used. It does not cover guest VLANs or other networks.

The generated `/etc/nftables.d/20-hmd-wg-hairpin.nft` contains only the package's
`hmd_wg_hairpin` chain (`nat prerouting`, priority `-105`). It accepts traffic
only when it enters through the current LAN device, the destination is a local
router IPv4 address, the UDP port is one of the currently managed WireGuard
ports, and the destination is not the current LAN address; it then DNATs to the
current LAN IPv4 address. WAN ingress remains unchanged, and this does not open
`wanppp` to the Internet. Existing WireGuard keys, endpoints, and client
configuration format are unchanged.

The package also installs the named UCI rule `network.hmd_lan_main`:
`priority 9000`, `lookup main`, and `suppress_prefixlength 0`. Thus every
non-default route already in `main` (not only the LAN route) is preferred before
the per-session rules, while the default route still selects the configured
WAN session. Disabling `wg_enabled` does not remove this rule; it is removed
only when the package is uninstalled.

The rule also gives any custom public host/VPN routes in `main` priority over
per-session policy rules. Review this ordering if you use another PBR setup.

On a running device, manually resynchronize the rule after a network change with:

```sh
/etc/init.d/hinet-multidial hairpin
```

If old state remains after changing the LAN address, run that command and
reconnect the client. After changing the nftables rule, stop an existing client
connection for about one minute before reconnecting so stale conntrack state can
expire. With Surge or Mihomo, resolve the public IP/DDNS endpoint as `DIRECT`,
not a `198.18.x.x` fake-IP address.

The automatic `suppress_prefixlength` rule targets the official OpenWrt 24.10
netifd behavior. Older vendor builds that do not support it must use a static
LAN CIDR rule instead (replace the CIDR below with the actual LAN subnet).
First remove the package-owned `network.hmd_lan_main` section, then add this
replacement and reload network. Do **not** merely remove its suppression option:
that would let `main`'s default route override the per-session rules. The package
does not add an automatic compatibility layer:

```uci
config rule
        option dest '192.168.1.0/24'
        option lookup 'main'
        option priority '9000'
```

### Upgrade notes from v1.5.1

The package does not automatically delete rules or nftables files that were
created manually. If v1.5.1 was previously fixed by hand, remove the old
`/etc/nftables.d/20-wg-hairpin.nft` and the anonymous `priority 9000` rule from
`/etc/config/network` yourself, then reload the relevant service. Keep the
package-owned chain and named rule; there should be one `9000` rule and one
`hmd_wg_hairpin` chain.

### Service stop and removal

Stopping the service removes its generated hairpin rule; a later LAN event does
not recreate it until the service is started again. The UI's **Stop all** button
only hangs up PPPoE sessions and does not stop the service or disable WireGuard.
Turning off auto-dial likewise does not disable LAN hairpin.

Package removal deletes only this package's generated hairpin and owned named
LAN rule. An upgrade preserves the named rule and recreates hairpin on start.
Manual copy-based installations do not run package removal hooks; use the shared
cleanup before deleting the service/library:

```sh
/etc/init.d/hinet-multidial stop
( . /usr/share/hinet-multidial/lib.sh; PKG_UPGRADE=0; hmd_lan_cleanup )
```

### Verification

Do not treat this documentation as a claim that a real device has already been
tested. On the target router, check the generated rules and routes:

```sh
fw4 check
nft list chain inet fw4 hmd_wg_hairpin
ip -4 rule show | grep 9000

# Each active WG tunnel must retain its matching PPPoE egress table.
for i in 1 2 3 4 5 6; do
        ip route show table $((100 + i))
done
```

The rule listing should show `lookup main` with `suppress_prefixlength 0` and
the hairpin chain should show the current LAN ingress, local-destination check,
managed WireGuard ports, and DNAT target. Some BusyBox `ip` builds omit
`suppress_prefixlength` when printing an otherwise valid rule; that display
omission alone does not mean the feature is unsupported. Confirm that each
active `wg<i>` still exits through its corresponding `wanp<i>` public IP.

## Development checks

```sh
sh tests/test-lan-wireguard.sh
```

The shell regression suite stages temporary copies with mocked UCI, netifd, and
firewall commands; it does not change the host network. Linux uses real `flock`,
while hosts without it explicitly report mocked locking. CI runs these checks
before the OpenWrt SDK build. Passing mocks is not a substitute for the on-router
handshake, packet-source, and egress-IP checks above.

## Layout

```
Makefile                                    OpenWrt/luci.mk package definition
root/etc/config/hinet_multidial             defaults (empty account, count=1)
root/etc/init.d/hinet-multidial             procd service: staggered dial + reconcile trigger
root/etc/hotplug.d/iface/25-hinet-multidial per-session default route in its private table
root/etc/hotplug.d/iface/26-hinet-multidial-lan LAN IPv4/device hairpin synchronization
root/etc/uci-defaults/41-hinet-multidial-lan owned main-table suppression rule
root/usr/share/hinet-multidial/lib.sh       shared reconcile/dial engine
root/usr/libexec/rpcd/luci.hinet-multidial  rpcd backend (status / dial / stop / apply)
root/usr/share/rpcd/acl.d/…                  ACL grants
root/usr/share/luci/menu.d/…                menu entry
htdocs/luci-static/resources/view/…         client-side JS view
```

## License

MIT — see [LICENSE](LICENSE).
