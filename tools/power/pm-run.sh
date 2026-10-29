#!/bin/sh
# pm-run.sh LABEL [SECONDS] [INTERVAL] - the U30 Air's whole-system draw on its battery, with the USB cable still in
# (FINDINGS 239). Runs on the device, as root, from /tmp/pm (copy tools/power/*.sh there).
#
# The charger (an SGM41513 at I2C 6-0x1a, FINDINGS 33/#102) goes to HIZ, REG00 bit 7: VBUS stays (the gadget, the PMIC's
# detection), but the input is open, so the battery carries everything and the fuel gauge's current is the system's.
# Limiting the charge or input current (100 mA) is not the same: VBUS then still feeds an unknown share. The charger's
# watchdog is off on this board (REG05), so the bit stays until cleared; it is checked at every sample and set again
# if something cleared it (counted as hiz_reasserted). HIZ is cleared on every exit, and a detached failsafe clears it
# SECONDS+90 s later whatever happens to this script; the failsafe is killed at the end, or it would clear HIZ in the
# middle of the next run.
#
# Sampled every INTERVAL s: the FGU's current_now and voltage_now (LABEL.csv: uptime_cs,mA,uV,mW; discharge positive).
# At both ends: the coulomb counter (PMIC 0x868/0x86c through the regmap's debugfs; a seek to the two lines, the whole
# dump costs 2 s of system time), /proc/stat, /proc/interrupts and the byte counters of wlan0, sipa_eth8 and usb0
# (LABEL.sum, LABEL.irqd). Under 35 % capacity it refuses, under 30 % it stops.
L=${1:?label}; T=${2:-300}; I=${3:-2}
D=${PM_DIR:-/tmp/pm}; mkdir -p "$D"
F=/sys/class/power_supply/sc27xx-fgu
R=/sys/kernel/debug/regmap/spi4.0/registers
[ -s $D/clbline ] || grep -n "^0868:" $R | cut -d: -f1 > $D/clbline
N=$(cat $D/clbline)
CSV=$D/$L.csv; SUM=$D/$L.sum

hiz() { v=$(i2cget -f -y 6 0x1a 0x00) || return 1
	if [ "$1" = 1 ]; then i2cset -f -y 6 0x1a 0x00 $((v | 0x80)); else i2cset -f -y 6 0x1a 0x00 $((v & 0x7f)); fi; }
clb() { dd if=$R bs=15 skip=$((N - 1)) count=2 2>/dev/null | { read a h; read b l
	v=$(( ((0x$h & 0xffff) << 16) | (0x$l & 0xffff) )); [ $v -ge 2147483648 ] && v=$((v - 4294967296)); echo $v; }; }
cs() { read u _ < /proc/uptime; echo ${u%.*}${u#*.}; }
cpu() { read c us ni sy id io irq sirq rest < /proc/stat; echo "$((us + ni + sy + io + irq + sirq)) $id"; }
netb() { for n in wlan0 sipa_eth8 usb0; do read rx < /sys/class/net/$n/statistics/rx_bytes 2>/dev/null || rx=0
	read tx < /sys/class/net/$n/statistics/tx_bytes 2>/dev/null || tx=0; printf "%s:%s:%s " $n $rx $tx; done; }

read cap < $F/capacity
[ "$cap" -ge 35 ] || { echo "capacity $cap% < 35%, refusing" > $SUM; exit 1; }
setsid sh -c "sleep $((T + 90)); v=\$(i2cget -f -y 6 0x1a 0x00); i2cset -f -y 6 0x1a 0x00 \$((v & 0x7f))" \
	</dev/null >/dev/null 2>&1 &
FS=$!
trap 'hiz 0; kill $FS 2>/dev/null' EXIT
trap 'exit 1' INT TERM HUP
hiz 1 || { echo "HIZ set failed" > $SUM; exit 1; }
sleep 15

t0=$(cs); c0=$(clb); set -- $(cpu); b0=$1; i0=$2; n0=$(netb); cp /proc/interrupts $D/$L.irq0
ctx0=$(grep ^ctxt /proc/stat)
: > $CSV; rehiz=0; n=0; si=0; sp=0; mn=999999; mx=-999999
while :; do
	t=$(cs); [ $((t - t0)) -ge $((T * 100)) ] && break
	r=$(i2cget -f -y 6 0x1a 0x00 2>/dev/null) && [ $((r & 0x80)) -eq 0 ] && { hiz 1; rehiz=$((rehiz + 1)); sleep 1; continue; }
	read i < $F/current_now; read v < $F/voltage_now; read cap < $F/capacity
	i=$(( -i / 1000 )); p=$(( i * (v / 1000) / 1000 ))
	echo "$t,$i,$v,$p" >> $CSV
	n=$((n + 1)); si=$((si + i)); sp=$((sp + p)); [ $i -lt $mn ] && mn=$i; [ $i -gt $mx ] && mx=$i
	[ "$cap" -lt 30 ] && { echo "stopped: capacity $cap%" >> $SUM; break; }
	sleep $I
done
t1=$(cs); c1=$(clb); set -- $(cpu); b1=$1; i1=$2; n1=$(netb); cp /proc/interrupts $D/$L.irq1
ctx1=$(grep ^ctxt /proc/stat); r0=$(i2cget -f -y 6 0x1a 0x00); read vend < $F/voltage_now
hiz 0
dt=$((t1 - t0)); db=$((b1 - b0)); di=$((i1 - i0))
{
	echo "label=$L dur_cs=$dt samples=$n"
	echo "mean_mA=$((si / (n > 0 ? n : 1))) min_mA=$mn max_mA=$mx mean_mW=$((sp / (n > 0 ? n : 1))) vend_uV=$vend"
	echo "clb0=$c0 clb1=$c1 dclb=$((c1 - c0)) clb_per_s_x100=$(( (c1 - c0) * 10000 / dt ))"
	echo "cpu_busy_permille=$(( db * 1000 / (db + di) ))"
	echo "ctx: ${ctx0#ctxt } -> ${ctx1#ctxt }"
	echo "net0: $n0"; echo "net1: $n1"
	echo "reg00_at_end=$r0 cap_end=$cap hiz_reasserted=$rehiz"
} > $SUM
awk 'NR==FNR{ if(FNR>1){s=0; for(i=2;i<=9;i++) s+=$i; a[$1]=s}; next}
	FNR>1{s=0; for(i=2;i<=9;i++) s+=$i; d=s-a[$1]; if(d>0){ $2=$3=$4=$5=$6=$7=$8=$9=""; print d, $0}}' \
	$D/$L.irq0 $D/$L.irq1 | sort -rn | head -15 > $D/$L.irqd
