#!/bin/sh
# pm-batch.sh SECONDS SCENARIO... - several pm-run.sh measurements in one window with the USB gadget soft-disconnected
# (FINDINGS 239), each scenario undone before the next. A computer on the gadget routes its own traffic through the
# device and is part of the draw (481 mA with a PC using it as its uplink), and the cable carries the SSH session, so:
# run it detached and collect /tmp/pm afterwards:
#   setsid sh /tmp/pm/pm-batch.sh 120 ntpstop base kc_sa tolte kc_lte tosa ntpstart </dev/null >/tmp/pm/batch.out 2>&1 &
# mu300-power is stopped for the window (its self-check undoes scenarios) and started again; the gadget is connected
# again at the end, and after 75 min by a failsafe whatever happens. The log is /tmp/pm/batch.log (uptime seconds).
#
# Scenarios (each is measured unless it says otherwise):
#   base*, idle_*   as the device is            wifioff         hotspot down for the run (`wifi down`/`wifi up`)
#   wifidown/wifiup hotspot down/up, no run     woff            a run, nothing changed (between wifidown and wifiup)
#   vht20 vht40 g24 hotspot width or 2.4 GHz HT20 ch 6 for the run, back to the saved band/channel/width after
#   ddrperf ddrsave DDR pinned at 1866 / 384 MHz (devfreq scene-frequency), back to sprd_ddr_auto
#   woffperf        DDR pinned at 1866 MHz, for use with the hotspot down
#   cpurt           kernel.sched_util_clamp_min_rt_default 0 for the run
#   cpd             cpu0's cluster-pd idle state allowed for the run
#   bigoff          cpu4-7 offline for the run
#   radiooff        AT+CFUN=4 (the watcher held off by /run/mu300-mobile-data-down), then CFUN=1 and the bearer back
#   ka_*  kc_*      a ping to 223.5.5.5 over the bearer every 30 s / every 5 s: sparse and continuous small traffic
#   etrun etlazy    EasyTier from /etc/easytier/config.toml, as it is / with lazy_p2p (a copy), killed after the run
#   ntpstop ntpstart sysntpd stopped / started, no run
#   tolte tonsa tosa the data SIM's work mode to LTE only (3), to NSA (131 with AT+SP5GRAN=0), or back to what it was
#                   (read once, kept in /tmp/pm/modes0 and gran0), with the stack restart mu300-sim2-start uses (SFUN=5,
#                   SPTESTMODEM, SFUN=4 on the SIM's data channel) and `ifdown`/`ifup wan` around it; no run. The work
#                   mode is in the modem's NV and survives a reboot: always end a batch with tosa. Run on SIM2 only.
T=${1:-120}; shift
D=${PM_DIR:-/tmp/pm}; U=/sys/class/udc/$(ls /sys/class/udc | head -1)
B=/opt/mu300/bin; AT="$B/mu300-at -t 8"
TO=$(command -v timeout || echo "$B/busybox timeout")
G=/sys/class/devfreq/scene-frequency/governor
trap '' HUP
log() { read u _ < /proc/uptime; echo "$u $*" >> $D/batch.log; }
cp0=/sys/devices/system/cpu
snap() { log "[$1] $(iw dev wlan0 info 2>/dev/null | grep -E 'channel' | tr -s '\t ' ' ') sta=$(iw dev wlan0 station dump 2>/dev/null | grep -c ^Station)" \
	"$($TO 10 $AT 'AT+CEREG?' 2>/dev/null | grep CEREG) $($TO 10 $AT 'AT+CSCON?' 2>/dev/null | grep CSCON)" \
	"cpus=$(cat $cp0/online) f4=$(cat $cp0/cpufreq/policy4/scaling_cur_freq 2>/dev/null)"; }
run() { snap $1; sh $D/pm-run.sh $1 $T 2; }
wait_sta() { n=0; while [ $n -lt ${1:-90} ]; do [ "$(iw dev wlan0 station dump 2>/dev/null | grep -c ^Station)" -ge 1 ] && return 0; sleep 3; n=$((n + 3)); done; return 1; }
wait_data() { n=0; while [ $n -lt ${1:-150} ]; do ping -c1 -W3 -I sipa_eth8 223.5.5.5 >/dev/null 2>&1 && return 0; sleep 5; n=$((n + 5)); done; return 1; }
wifi_ht() { uci -q set wireless.radio0.htmode=$1; [ -n "$2" ] && uci -q set wireless.radio0.band=$2 && uci -q set wireless.radio0.channel=$3
	uci -q commit wireless; $TO 40 wifi reload; sleep 15; wait_sta 120; }
pinger() { ( while :; do ping -c1 -W3 -I sipa_eth8 223.5.5.5 >/dev/null 2>&1; sleep $1; done ) & KA=$!; }

setsid sh -c "sleep 4500; echo connect > $U/soft_connect; v=\$(i2cget -f -y 6 0x1a 0x00); i2cset -f -y 6 0x1a 0x00 \$((v & 0x7f))" \
	</dev/null >/dev/null 2>&1 &
sleep 3
: > $D/batch.log
$TO 160 /etc/init.d/mu300-power stop; log "mu300-power stopped"
HT0=$(uci -q get wireless.radio0.htmode); BAND0=$(uci -q get wireless.radio0.band); CH0=$(uci -q get wireless.radio0.channel)
CHL0=$(uci -q get wireless.radio0.channels); DFS0=$(uci -q get wireless.radio0.acs_exclude_dfs)
log "wifi was $BAND0 ch$CH0 $HT0"
echo disconnect > $U/soft_connect
sleep 10

for s in "$@"; do
	log "== $s"
	case $s in
	base*|idle_*|woff) run $s ;;
	wifidown) $TO 40 wifi down; sleep 10; continue ;;
	wifiup)	$TO 40 wifi up; sleep 15; continue ;;
	wifioff) $TO 40 wifi down; sleep 10; run $s; $TO 40 wifi up; sleep 15; wait_sta 120 || log "no station after wifi up" ;;
	vht20|vht40) wifi_ht $(echo $s | tr a-z A-Z) || log "no station on $s"; run $s; wifi_ht $HT0 || log "no station after restore" ;;
	g24)	uci -q delete wireless.radio0.channels; wifi_ht HT20 2g 6 || log "no station on 2.4"; run $s
		[ -n "$CHL0" ] && uci -q set wireless.radio0.channels="$CHL0"; [ -n "$DFS0" ] && uci -q set wireless.radio0.acs_exclude_dfs=$DFS0
		wifi_ht $HT0 $BAND0 $CH0 || log "no station after restore" ;;
	ddrperf|ddrsave|woffperf) g=performance; [ $s = ddrsave ] && g=powersave; echo $g > $G; sleep 5
		log "ddr governor $(cat $G) cur=$(cat ${G%/*}/cur_freq 2>/dev/null)"; run $s; echo sprd_ddr_auto > $G ;;
	cpurt)	o=$(cat /proc/sys/kernel/sched_util_clamp_min_rt_default 2>/dev/null)
		if [ -n "$o" ]; then echo 0 > /proc/sys/kernel/sched_util_clamp_min_rt_default; run $s
			echo $o > /proc/sys/kernel/sched_util_clamp_min_rt_default; else log "no uclamp sysctl"; fi ;;
	cpd)	o=$(cat $cp0/cpu0/cpuidle/state2/disable); echo 0 > $cp0/cpu0/cpuidle/state2/disable; run $s
		log "cpu0 cluster-pd usage $(cat $cp0/cpu0/cpuidle/state2/usage)"; echo $o > $cp0/cpu0/cpuidle/state2/disable ;;
	bigoff)	for c in 4 5 6 7; do echo 0 > $cp0/cpu$c/online; done; run $s
		for c in 4 5 6 7; do echo 1 > $cp0/cpu$c/online; done ;;
	radiooff) touch /run/mu300-mobile-data-down; $TO 20 $AT 'AT+CFUN=4' >> $D/batch.log 2>&1; sleep 15; run $s
		$TO 20 $AT 'AT+CFUN=1' >> $D/batch.log 2>&1; rm -f /run/mu300-mobile-data-down; wait_data 240 || log "no data after radio on" ;;
	ka_*)	pinger 30; run $s; kill $KA 2>/dev/null ;;
	kc_*)	pinger 5; sleep 10; run $s; kill $KA 2>/dev/null ;;
	etrun|etlazy) c=/etc/easytier/config.toml
		[ $s = etlazy ] && { sed '/^\[flags\]/a lazy_p2p = true' $c > $D/et-lazy.toml; c=$D/et-lazy.toml; }
		( cd /tmp; setsid /usr/bin/easytier-core -c $c --console-log-level off </dev/null >$D/$s.et 2>&1 & )
		sleep 45; run $s; killall easytier-core 2>/dev/null ;;
	ntpstop) $TO 20 /etc/init.d/sysntpd stop; continue ;;
	ntpstart) $TO 20 /etc/init.d/sysntpd start; continue ;;
	tolte|tonsa|tosa)
		[ "$(cat /run/mu300/sim-slot 2>/dev/null)" = 1 ] || { log "$s: only written for SIM2 (sim-slot 1)"; continue; }
		A1="env MU300_AT_DIR=/run/mu300-at5 $B/mu300-at -t 25"; A4="env MU300_AT_DIR=/run/mu300-at4 $B/mu300-at -t 8"
		[ -s $D/modes0 ] || $TO 15 $AT 'AT+SPTESTMODE?' | sed -n 's/^+SPTESTMODE: *\([0-9]*\), *\([0-9]*\).*/\1,\2/p' | head -1 > $D/modes0
		m0=$(cat $D/modes0); case $m0 in [0-9]*,[0-9]*) ;; *) log "modes unreadable ($m0): no switch"; continue ;; esac
		[ -s $D/gran0 ] || $TO 15 $A1 'AT+SP5GRAN?' | sed -n 's/^+SP5GRAN: *\([0-9]\).*/\1/p' | head -1 > $D/gran0
		g0=$(cat $D/gran0); g=$g0
		case $s in tolte) new=${m0%,*},3 ;; tonsa) new=${m0%,*},131; g=0 ;; *) new=$m0 ;; esac
		log "switch $s: modes $m0 -> $new, SP5GRAN $g0 -> $g"
		touch /run/mu300-mobile-data-down; $TO 60 ifdown wan; sleep 3
		log "SFUN=5: $($TO 30 $A1 'AT+SFUN=5' 2>&1 | tr -d '\r' | tail -1)"; sleep 2
		log "SPTESTMODEM=$new: $($TO 30 $A1 "AT+SPTESTMODEM=$new" 2>&1 | tr -d '\r' | tail -1)"
		[ -n "$g" ] && log "SP5GRAN=$g: $($TO 30 $A1 "AT+SP5GRAN=$g" 2>&1 | tr -d '\r' | tail -1)"
		log "SFUN=4: $($TO 30 $A1 'AT+SFUN=4' 2>&1 | tr -d '\r' | tail -1)"
		n=0; while [ $n -lt 120 ]; do r=$($TO 10 $A4 'AT+CEREG?' 2>/dev/null | grep CEREG); case "$r" in *,1,*|*,5,*) break ;; esac; sleep 4; n=$((n + 4)); done
		log "registered after ${n}s: $r; mode now $($TO 10 $AT 'AT+SPTESTMODE?' | grep SPTESTMODE)"
		rm -f /run/mu300-mobile-data-down; $TO 90 ifup wan; wait_data 180 || log "no data after $s"; sleep 15; continue ;;
	*)	log "unknown scenario $s"; continue ;;
	esac
	log "-- $s done: $(head -2 $D/$s.sum 2>/dev/null | tr '\n' ' ')"
done

$TO 160 /etc/init.d/mu300-power start; log "mu300-power started"
for try in 1 2 3 4 5; do
	echo connect > $U/soft_connect
	w=0; while [ $w -lt 40 ]; do [ "$(cat $U/state)" = configured ] && break; sleep 2; w=$((w + 2)); done
	log "udc try $try: $(cat $U/state) after ${w}s"
	[ "$(cat $U/state)" = configured ] && break
	[ $try -lt 5 ] && { echo disconnect > $U/soft_connect; sleep 3; }
done
echo connect > $U/soft_connect
log "batch done"
