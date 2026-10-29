#!/bin/sh
# pm-rrc-diag.sh LABEL [SECONDS] - what wakes the bearer (FINDINGS 239): every packet of the device's own on the cellular
# interface (nft log: PMOUT/PMIN, and PMFWU/PMFWD for forwarded ones) on the uptime clock in LABEL.pkt, while pm-run.sh
# samples the current, with the USB gadget soft-disconnected; a burst in LABEL.csv that no packet precedes is the
# modem's own. +CSCON URCs are asked for and listened to on ubus (LABEL.urc), though this firmware sent none.
# Run detached: setsid sh /tmp/pm/pm-rrc-diag.sh diag 240 </dev/null >/tmp/pm/diag.out 2>&1 &
L=${1:-diag}; T=${2:-240}
D=${PM_DIR:-/tmp/pm}; U=/sys/class/udc/$(ls /sys/class/udc | head -1); AT="/opt/mu300/bin/mu300-at -t 8"
trap '' HUP
ts() { while IFS= read -r l; do read u _ < /proc/uptime; echo "$u $l"; done; }
sleep 3
nft -f - <<EOF
table inet pmlog {
  chain out { type filter hook output priority 0; policy accept; oifname "sipa_eth*" log prefix "PMOUT " level info; }
  chain in { type filter hook input priority 0; policy accept; iifname "sipa_eth*" log prefix "PMIN " level info; }
  chain fw { type filter hook forward priority 0; policy accept; iifname "sipa_eth*" log prefix "PMFWD " level info; oifname "sipa_eth*" log prefix "PMFWU " level info; }
}
EOF
$AT 'AT+CSCON=1' > $D/$L.at 2>&1
sh -c "echo \$\$ > $D/$L.upid; exec ubus -S listen mu300.modem.urc" 2>&1 | ts > $D/$L.urc &
dmesg -c > /dev/null
echo disconnect > $U/soft_connect
sh $D/pm-run.sh "$L" "$T" 2
dmesg | grep -E "PMOUT|PMIN|PMFW" > $D/$L.pkt
$AT 'AT+CSCON=0' >> $D/$L.at 2>&1
kill $(cat $D/$L.upid) 2>/dev/null
nft delete table inet pmlog
for try in 1 2 3; do
	echo connect > $U/soft_connect
	w=0; while [ $w -lt 30 ]; do [ "$(cat $U/state)" = configured ] && break; sleep 2; w=$((w + 2)); done
	[ "$(cat $U/state)" = configured ] && break
	[ $try -lt 3 ] && { echo disconnect > $U/soft_connect; sleep 3; }
done
echo connect > $U/soft_connect
echo done > $D/$L.done
