#!/bin/bash
# Usage: measure.sh <cfg...> -> TSV: cfg, file bytes, .text, .llvm_stackmaps, census lines
for cfg in "$@"; do
  V=/tmp/inc-exp/variants/x3-$cfg
  B=$V/bin/eco
  fsz=$(stat -c %s $B)
  text=$(readelf -SW $B | awk '$2==".text"{print strtonum("0x"$6)}')
  sm=$(readelf -SW $B | awk '$2==".llvm_stackmaps"{print strtonum("0x"$6)}')
  osz=$(stat -c %s $V/bin/eco.o)
  mlirmd5=$(md5sum $V/bin/eco.mlir | cut -c1-12)
  printf "%s\tfile=%s\ttext=%s\tstackmaps=%s\tobj=%s\tmlir=%s\n" $cfg $fsz $text $sm $osz $mlirmd5
  grep -ah "x3-census\|caphoist-plan\|gcfree-plan\|exp-cap-xmod" $V/fe.log $V/lower.log 2>/dev/null | sed 's/^/    /'
  grep -h "Elapsed\|Maximum resident" $V/time-fe.txt $V/time-lower.txt 2>/dev/null | sed 's/^/    /'
done
