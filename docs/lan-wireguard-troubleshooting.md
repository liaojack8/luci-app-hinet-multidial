# OpenWrt 多撥環境：區網無法用公網 IP / DDNS 連線 WireGuard

> 本文保留原始排障紀錄與修正構想；實際公網位址已替換為文件專用範例 IP。
> 範例 LAN 位址與介面名稱請依環境調整。套件 v1.5.2 的實際安裝、升級與自動維護方式以 [README](../README.md#wireguard-from-lan-via-the-public-endpoint) 為準，不需再照本文手動加入相同規則。

## 環境

- OpenWrt（fw4 / nftables）
- 主線 `pppoe-wan`（固定 IP）＋ PPPoE 多撥 `pppoe-wanp1` ~ `pppoe-wanp5`（浮動 IP）
- 多撥以策略路由分流：`ip rule` priority 10000 `from <多撥IP> lookup 101~105`，各表只有 `default dev pppoe-wanpX`
- WireGuard server `wg1` ~ `wg5`，監聽 UDP `51821` ~ `51825`
- LAN：`br-lan`，`192.168.58.0/24`，路由器 `192.168.58.254`

## 問題

- 從外網用公網 IP / DDNS 連 WireGuard：正常
- 從區網用公網 IP / DDNS 連 WireGuard：無法握手
- 從區網把 endpoint 改成路由器 LAN IP（`192.168.58.254`）：正常

需求：同一份客戶端設定，不論在 WAN 或 LAN 都能連線。

## 原因

### 1. 多撥策略路由讓回程走錯介面

區網連到多撥 IP 時，WireGuard 以該多撥 IP 為來源回覆，命中 `from <多撥IP> lookup 10x`。
該表只有 PPPoE 預設路由，沒有 LAN 路由，回覆被送往 `pppoe-wanpX` 上游，客戶端收不到。

```
# ip route get 192.168.58.100 from 203.0.113.7
192.168.58.100 from 203.0.113.7 dev pppoe-wanp1 table 101   ← 錯誤
```

### 2. WireGuard 回覆的來源 IP 是 LAN IP，而非客戶端連線的公網 IP

修正路由後，抓包顯示回覆已經走 `br-lan`，但來源 IP 錯誤：

```
br-lan In   192.168.58.149:53584 > 198.51.100.214:51821   ← 客戶端連公網 IP
br-lan Out  192.168.58.254:51821 > 192.168.58.149:53584    ← 伺服器以 LAN IP 回覆
```

客戶端（尤其經過 Surge / Mihomo 的連線）只接受來自原目的 IP 的回覆，來源不符即丟棄，因此握手失敗。

已排除：wg 介面無 `fwmark`、無 Port Forward / NAT reflection、fw4 masquerade 不作用於 `br-lan`、Docker 的 iptables 規則無影響。
WireGuard 選用 LAN IP 作為來源的確切原因未查明，改以 DNAT 方式繞過。

## 解決方法

### 1. DNAT hairpin（解決 WireGuard 握手問題）

區網送往「路由器自己的 IP」的 WireGuard 流量，在 prerouting 階段 DNAT 到 LAN IP。
WireGuard 以 LAN IP 回覆，conntrack 自動把回覆來源還原成客戶端原本連線的公網 IP。

`fib daddr type local` 由核心即時判斷是否為本機 IP，涵蓋主線與所有多撥 IP，**重新撥號換 IP 不需修改**。

`/etc/nftables.d/20-wg-hairpin.nft`（fw4 會自動載入至 `table inet fw4`）：

```nft
chain wg_hairpin {
        type nat hook prerouting priority -105; policy accept;
        iifname "br-lan" fib daddr type local ip daddr != 192.168.58.254 udp dport 51821-51825 counter dnat ip to 192.168.58.254
}
```

```sh
/etc/init.d/firewall reload
nft list chain inet fw4 wg_hairpin
```

### 2. 優先查 main 表的 ip rule（修正多撥 IP 的區網回程）

在多撥規則（10000）之前插入：只要 main 表有明確路由（LAN、wg 子網、docker 等）就走 main；
預設路由被 `suppress_prefixlength 0` 排除，外網流量仍交給多撥規則，**不影響分流**。規則不含任何 IP，**多撥 IP 浮動不受影響**。

WireGuard 本身靠第 1 項即可運作；此規則用於區網連多撥 IP 上的其他服務（如 Snell），建議一併保留。

`/etc/config/network`：

```
config rule
        option lookup 'main'
        option suppress_prefixlength '0'
        option priority '9000'
```

```sh
/etc/init.d/network reload
ip rule | grep 9000
```

若 netifd 不支援 `suppress_prefixlength`，改用：

```
config rule
        option dest '192.168.58.0/24'
        option lookup 'main'
        option priority '9000'
```

### 驗證

```sh
# 回程路由：所有多撥線路都應為 dev br-lan
for i in 1 2 3 4 5; do
  ip=$(ip -4 -o addr show pppoe-wanp$i | awk '{print $4}' | cut -d/ -f1)
  echo -n "wanp$i ($ip): "; ip route get 192.168.58.100 from $ip | head -1
done

# WireGuard 回覆來源應為公網 IP，而非 192.168.58.254
tcpdump -ni br-lan udp portrange 51821-51825
```

> **注意：** 修改規則後，客戶端需先關閉 WireGuard 約 1 分鐘再重連。
> 客戶端持續重試會不斷刷新舊的 conntrack 紀錄，使新 NAT 規則不生效。

客戶端若使用 Surge / Mihomo：確認 DDNS 網域未被 fake-ip 解析為 `198.18.x.x`，並將公網 IP / DDNS 網域設為 `DIRECT`。

## 多撥軟體包應修正的方式

上述兩項由套件負責建立與清除，而非手動維護。

| 修正 | 特性 | 放置位置 |
|---|---|---|
| ip rule 9000 | 固定、無參數 | uci-defaults 安裝時寫入具名 `config rule`，交由 netifd 管理 |
| WireGuard DNAT | 依 LAN IP、wg 埠號產生 | init 腳本 `start_service` 產生、`stop_service` 移除 |

### 1. uci-defaults：寫入 ip rule

`/etc/uci-defaults/99-hmd-lan-rule`：

```sh
#!/bin/sh
# 有明確路由的目的地（LAN、wg 子網）優先查 main 表，default 交回多撥規則
uci -q get network.hmd_lan_main >/dev/null && exit 0
uci set network.hmd_lan_main=rule
uci set network.hmd_lan_main.lookup='main'
uci set network.hmd_lan_main.suppress_prefixlength='0'
uci set network.hmd_lan_main.priority='9000'
uci commit network
exit 0
```

- `priority` 必須小於套件建立的 `from <多撥IP>` 規則（10000），兩者建議在套件中定義為相鄰常數。
- postinst 執行 uci-defaults 後需 `/etc/init.d/network reload` 才會生效。

> 替代作法：建表時同時加入 LAN 路由（`ip route add 192.168.58.0/24 dev br-lan table 10$i`）。
> 但需列舉所有網段，新增網段時容易遺漏，故採 `suppress_prefixlength` 方式。

### 2. init 腳本：動態產生 DNAT 規則

```sh
HAIRPIN_NFT=/etc/nftables.d/20-hmd-wg-hairpin.nft

hairpin_update() {
	local lan_dev lan_ip ports new

	lan_dev=$(ifstatus lan | jsonfilter -e '@.l3_device')
	lan_ip=$(ifstatus lan | jsonfilter -e '@["ipv4-address"][0].address')
	# 改為從套件自身設定讀取 wg 埠號清單
	ports=$(uci show network | sed -n "s/^network\.wg[0-9]*\.listen_port='\([0-9]*\)'$/\1/p" | tr '\n' ',' | sed 's/,$//')

	if [ -z "$lan_dev" ] || [ -z "$lan_ip" ] || [ -z "$ports" ]; then
		hairpin_remove
		return
	fi

	# 區網連路由器自己的公網 IP 時 DNAT 到 LAN IP，讓 conntrack 修正回覆的來源 IP
	new="chain hmd_wg_hairpin {
	type nat hook prerouting priority -105; policy accept;
	iifname \"$lan_dev\" fib daddr type local ip daddr != $lan_ip udp dport { $ports } counter dnat ip to $lan_ip
}"

	# 內容未變則略過，避免重複寫 flash 與重載防火牆
	[ "$new" = "$(cat "$HAIRPIN_NFT" 2>/dev/null)" ] && return
	echo "$new" > "$HAIRPIN_NFT"
	/etc/init.d/firewall reload
}

hairpin_remove() {
	[ -f "$HAIRPIN_NFT" ] || return
	rm -f "$HAIRPIN_NFT"
	/etc/init.d/firewall reload
}

start_service() {
	# ... 原本的多撥與 wg 建立流程 ...
	hairpin_update
}

stop_service() {
	# ... 原本的流程 ...
	hairpin_remove
}
```

LAN IP 可能變動時，加上 hotplug 重新產生（init 腳本需以 `EXTRA_COMMANDS="hairpin"` 提供 `hairpin` 指令呼叫 `hairpin_update`）：

```sh
# /etc/hotplug.d/iface/99-hmd-hairpin
[ "$ACTION" = ifup ] && [ "$INTERFACE" = lan ] && /etc/init.d/hmd hairpin
```

### 3. prerm：解除安裝時清理

```sh
rm -f /etc/nftables.d/20-hmd-wg-hairpin.nft
uci -q delete network.hmd_lan_main && uci commit network
/etc/init.d/firewall reload
/etc/init.d/network reload
```

### 4. 已手動修正過的路由器

改用套件版本前，先移除手動規則，避免重複：

```sh
rm -f /etc/nftables.d/20-wg-hairpin.nft
# 並從 /etc/config/network 刪除手動加入的 priority 9000 匿名 config rule
```

安裝後確認：

```sh
nft list chain inet fw4 hmd_wg_hairpin
ip rule | grep 9000    # 應只有一條
```
