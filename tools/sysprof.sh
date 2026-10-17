#!/system/bin/sh
# per-process CPU over T seconds (includes kernel threads), plus irq/softirq and GPU freq residency
T=${1:-120}
snap() { for d in /proc/[0-9]*; do p=${d#/proc/}; s=$(cat $d/stat 2>/dev/null) || continue
  # comm may contain spaces: take fields after the last ')'
  rest=${s##*) }; set -- $rest; echo "$p $(( ${12} + ${13} )) $(( ${4} ))"; done; }
cpu() { awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat; }
G=/sys/class/devfreq/1800000.gpu/trans_stat
gpu() { awk '/^\*? *[0-9]+:/{gsub(/\*/,""); printf "%s=%s ", $1, $NF}' $G; }
snap > /data/local/tmp/s0; c0=$(cpu); g0=$(gpu)
sleep $T
snap > /data/local/tmp/s1; c1=$(cpu); g1=$(gpu)
echo "=== whole system, ${T}s (jiffies, 100/s per core, 4 cores = $((T*400)) max)"
set -- $c0; u0=$1 n0=$2 s0=$3 i0=$4 w0=$5 q0=$6 sq0=$7
set -- $c1; echo "user=$(($1-u0)) nice=$(($2-n0)) system=$(($3-s0)) idle=$(($4-i0)) iowait=$(($5-w0)) irq=$(($6-q0)) softirq=$(($7-sq0))"
echo "=== GPU freq residency delta (ms): before: $g0"; echo "                                   after:  $g1"
echo "=== top processes by CPU ticks (ticks / % of one core / pid / ppid / name)"
awk 'NR==FNR{a[$1]=$2; next} ($1 in a){d=$2-a[$1]; if(d>0) print d, $1, $3}' /data/local/tmp/s0 /data/local/tmp/s1 | sort -rn | head -40 | while read d p pp; do
  n=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ' | cut -c1-60); [ -z "$n" ] && n="[$(cat /proc/$p/comm 2>/dev/null)]"
  echo "$d $(( d*1000/(T*100) ))/1000 $p $pp $n"; done
