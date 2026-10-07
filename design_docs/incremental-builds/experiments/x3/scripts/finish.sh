#!/bin/bash
S=/tmp/inc-exp/results/x3/scripts
ECO_EXP_CAP_XMOD=r $S/lower-link.sh all /tmp/inc-exp/variants/x3-all/bin/eco.mlir; echo "all rc=$?"
ECO_EXP_CAP_XMOD=1 $S/lower-link.sh r4def /tmp/inc-exp/variants/x3-base/bin/eco.mlir; echo "r4def rc=$?"
ECO_EXP_CAP_XMOD=r $S/lower-link.sh r4req /tmp/inc-exp/variants/x3-base/bin/eco.mlir; echo "r4req rc=$?"
echo BUILDS-DONE
$S/time-runs.sh 3 base r1 r2 r3 r3h all r4def r4req
echo TIMING-DONE
