#!/bin/bash
# Usage: time-runs.sh <N> <cfg...>   round-robin N rounds over cfgs.
# Each run: cold cache (rm run-dir eco-stuff), under the heavy lock, clean env,
# /usr/bin/time -v. Results appended to /tmp/inc-exp/results/x3/timing.tsv.
set -uo pipefail
N=$1; shift
RD=/tmp/inc-exp/x3-run
R=/tmp/inc-exp/results/x3
mkdir -p $R/timing
for ((round=1; round<=N; round++)); do
  for cfg in "$@"; do
    E=/tmp/inc-exp/variants/x3-$cfg/bin/eco
    tag=$cfg-r$round
    flock /tmp/inc-exp/heavy.lock bash -c "
      rm -rf $RD/eco-stuff
      cd $RD
      env -i HOME=\$HOME PATH=\$PATH /usr/bin/time -v -o $R/timing/$tag.time \
        $E make --optimize --kernel-package eco/compiler \
        --local-package eco/kernel=/tmp/inc-exp/repo/eco-kernel-cpp \
        --output=$RD/out/$cfg.mlir src/Terminal/Main.elm > $R/timing/$tag.log 2>&1
      echo \$? > $R/timing/$tag.rc
    "
    wall=$(grep 'Elapsed (wall' $R/timing/$tag.time | awk '{print $NF}')
    rss=$(grep 'Maximum resident' $R/timing/$tag.time | awk '{print $NF}')
    usr=$(grep 'User time' $R/timing/$tag.time | awk '{print $NF}')
    sys=$(grep 'System time' $R/timing/$tag.time | awk '{print $NF}')
    md5=$(md5sum $RD/out/$cfg.mlir | cut -c1-12)
    printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n" $cfg $round "$wall" "$usr" "$sys" "$rss" "$(cat $R/timing/$tag.rc)" $md5 | tee -a $R/timing.tsv
  done
done
