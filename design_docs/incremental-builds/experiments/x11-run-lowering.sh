#!/bin/bash
# Lower each X1 variant's MLIR with module-aligned units (module-req), keeping per-unit objects.
OUT=/tmp/inc-exp/results/x11objs
NATIVE=/tmp/inc-exp/repo/build/runtime/src/codegen/eco-boot-native
for tag in base1 base1b e1 e2 e3 e4 e5 e6 e7 e8 e9 e10; do
  src=${tag%b}; [ "$tag" = base1b ] && src=base1
  M=/tmp/inc-exp/variants/x12-$src/bin/eco.mlir
  D=$OUT/$tag; rm -rf "$D"; mkdir -p "$D"
  env ECO_SPLIT_POLICY=module-req ECO_SPLIT_MAX_THREADS=12 \
    ECO_EXP_LOCAL_PREFIXES=API,Builder,Codec,Common,Compiler,Control,Data,Mlir,System,Terminal,Text,Utils,Prelude \
    ECO_SPLIT_KEEP_OBJS=$D ECO_SPLIT_PART_STATS=$D/stats.tsv \
    flock /tmp/inc-exp/heavy.lock /usr/bin/time -v -o $D/time.txt $NATIVE $M -o $D/out.exe > $D/log.txt 2>&1
  echo "$tag exit=$? objs=$(ls $D/*.o | wc -l) $(grep Elapsed $D/time.txt | awk -F': ' '{print $2}')"
done
echo X11-DONE
