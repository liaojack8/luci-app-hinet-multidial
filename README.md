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

It depends on `luci-base`, `ppp`, and `ppp-mod-pppoe`.

To hot-install on a running device without a rebuild, copy `root/` to `/` and
`htdocs/luci-static` to `/www/luci-static`, then:

```sh
chmod +x /etc/init.d/hinet-multidial /usr/libexec/rpcd/luci.hinet-multidial \
         /etc/hotplug.d/iface/25-hinet-multidial
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

## Layout

```
Makefile                                    OpenWrt/luci.mk package definition
root/etc/config/hinet_multidial             defaults (empty account, count=1)
root/etc/init.d/hinet-multidial             procd service: staggered dial + reconcile trigger
root/etc/hotplug.d/iface/25-hinet-multidial per-session default route in its private table
root/usr/share/hinet-multidial/lib.sh       shared reconcile/dial engine
root/usr/libexec/rpcd/luci.hinet-multidial  rpcd backend (status / dial / stop / apply)
root/usr/share/rpcd/acl.d/…                  ACL grants
root/usr/share/luci/menu.d/…                menu entry
htdocs/luci-static/resources/view/…         client-side JS view
```

## License

MIT — see [LICENSE](LICENSE).
