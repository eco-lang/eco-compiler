#!/bin/bash
# mem-trace.sh: run a command under /usr/bin/time -v and sample its memory, threads and CPU
# (plans/frontend-heap-release.md §8.1).
#
# usage: mem-trace.sh -o <prefix> [-i <sec>=1] [-w <file-to-size>] -- <cmd> [args...]
# writes <prefix>.tsv .time .stdout .stderr .meta ; exit code = the command's
#
# TSV columns (one line per sample, appended immediately so the file survives a kill):
#   t_ms        milliseconds since the command started (bash arithmetic on `date +%s%N`)
#   rss_mb      VmRSS of the sampled process (the time wrapper's child)
#   hwm_mb      VmHWM (peak RSS so far)
#   threads     Threads
#   cpu_s       utime + stime of the whole process, seconds
#   majflt      major page faults of the process
#   memavail_mb MemAvailable (system)
#   swapfree_mb SwapFree (system)
#   out_mb      size of the -w file (0 when absent or not given)
#   gc_reports  number of "[gc-report]" lines in <prefix>.stderr so far (places each report on the
#               time axis; plan §8.1 lists no such column, see the plan's §11 "As built")
#   group_cpu   CPU seconds per thread group, "name:secs" separated by spaces; the group is the
#               thread's comm with any trailing "-<digits>" removed (eco, eco-gc, eco-mark,
#               eco-cmark, eco-tenure, llvm-worker, ...)
# Samples are taken at T0 + k*interval (no drift); a slow sample skips missed slots.
# The last line is "exit rc=<rc>".
set -u

usage() { sed -n '4,5p' "$0" | sed 's/^# //' >&2; exit 2; }

PREFIX= IVAL=1 WATCH=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) PREFIX=$2; shift 2 ;;
    -i) IVAL=$2; shift 2 ;;
    -w) WATCH=$2; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) echo "mem-trace.sh: unknown option $1" >&2; usage ;;
  esac
done
[ -n "$PREFIX" ] && [ $# -gt 0 ] || usage
[ -x /usr/bin/time ] || { echo "mem-trace.sh: /usr/bin/time not found" >&2; exit 2; }

# interval in ns (accepts fractions such as 0.5); awk, because bash has no floats and bc is absent
IVAL_NS=$(awk -v s="$IVAL" 'BEGIN { v = s * 1e9; if (v < 1e7) v = 1e7; printf "%d", v }')

LOG=$PREFIX.tsv TIME=$PREFIX.time OUT=$PREFIX.stdout ERR=$PREFIX.stderr META=$PREFIX.meta
HZ=$(getconf CLK_TCK)

{
  printf 'cmd='; printf '%q ' "$@"; echo
  echo "cwd=$PWD"
  echo "host=$(hostname)"
  echo "start=$(date -Iseconds)"
  echo "interval_s=$IVAL"
  echo "watch=$WATCH"
  echo "mem_total_mb=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo)"
  echo "swap_total_mb=$(awk '/^SwapTotal/{print int($2/1024)}' /proc/meminfo)"
  echo "nproc=$(nproc)"
  for v in $(env | grep -oE '^(ECO_[A-Z0-9_]*|NODE_OPTIONS)=' | tr -d =); do echo "env.$v=${!v}"; done
} > "$META"

printf 't_ms\trss_mb\thwm_mb\tthreads\tcpu_s\tmajflt\tmemavail_mb\tswapfree_mb\tout_mb\tgc_reports\tgroup_cpu\n' > "$LOG"

T0=$(date +%s%N)
/usr/bin/time -v -o "$TIME" "$@" > "$OUT" 2> "$ERR" &
TPID=$!
PID=
for _ in $(seq 1 100); do
  PID=$(pgrep -P "$TPID" | head -1)
  [ -n "$PID" ] && break
  kill -0 "$TPID" 2>/dev/null || break
  sleep 0.02
done

sample() {
  local now t rss= hwm= thr= cpu= mf= ma sf out=0 grp= ngc
  now=$(date +%s%N)
  t=$(( (now - T0) / 1000000 ))
  if [ -n "$PID" ] && [ -r "/proc/$PID/status" ]; then
    read -r rss hwm thr < <(awk '/^VmRSS/{r=int($2/1024)} /^VmHWM/{h=int($2/1024)} /^Threads/{n=$2}
                                  END {print r, h, n}' "/proc/$PID/status" 2>/dev/null)
    local st
    st=$(cat "/proc/$PID/stat" 2>/dev/null)
    if [ -n "$st" ]; then
      # fields after "comm)": state=1 ... majflt=10 utime=12 stime=13
      read -r cpu mf < <(echo "${st##*) }" | awk -v hz="$HZ" '{printf "%.1f %d\n", ($12+$13)/hz, $10}')
    fi
    grp=$(for d in /proc/$PID/task/*; do
            c=$(cat "$d/comm" 2>/dev/null) || continue
            s=$(cat "$d/stat" 2>/dev/null) || continue
            set -- ${s##*) }
            echo "${c// /_} ${12} ${13}"
          done 2>/dev/null |
          awk -v hz="$HZ" '{ g = $1; sub(/-[0-9]+$/, "", g); n[g] += ($2 + $3) / hz }
                           END { for (k in n) printf "%s:%.1f ", k, n[k] }' | sed 's/ $//')
  fi
  ma=$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)
  sf=$(awk '/^SwapFree/{print int($2/1024)}' /proc/meminfo)
  if [ -n "$WATCH" ] && [ -f "$WATCH" ]; then
    out=$(stat -c %s "$WATCH" 2>/dev/null | awk '{printf "%.1f", $1/1048576}')
  fi
  ngc=$(grep -c '^\[gc-report\]' "$ERR" 2>/dev/null); ngc=${ngc:-0}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$t" "$rss" "$hwm" "$thr" "$cpu" "$mf" "$ma" "$sf" "$out" "$ngc" "$grp" >> "$LOG"
}

k=0
while kill -0 "$TPID" 2>/dev/null; do
  sample
  # next slot T0 + k*IVAL strictly in the future (skip slots a slow sample overran)
  now=$(date +%s%N)
  k=$(( (now - T0) / IVAL_NS + 1 ))
  wait_ns=$(( T0 + k * IVAL_NS - now ))
  # sleep in slices of at most 0.2 s so a finished command is noticed promptly
  while [ "$wait_ns" -gt 0 ] && kill -0 "$TPID" 2>/dev/null; do
    slice=$(( wait_ns < 200000000 ? wait_ns : 200000000 ))
    sleep "$(printf '%d.%09d' $(( slice / 1000000000 )) $(( slice % 1000000000 )))"
    now=$(date +%s%N)
    wait_ns=$(( T0 + k * IVAL_NS - now ))
  done
done
wait "$TPID"; RC=$?
echo "exit rc=$RC" >> "$LOG"
{ echo "end=$(date -Iseconds)"; echo "rc=$RC"; echo "wall_ms=$(( ($(date +%s%N) - T0) / 1000000 ))"; } >> "$META"
exit "$RC"
