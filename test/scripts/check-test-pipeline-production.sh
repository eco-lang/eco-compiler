#!/bin/sh
# Drift guard for the test harness (plans/staging-honesty-and-production-test-pipeline.md P1.3).
#
# Usage: test/scripts/check-test-pipeline-production.sh [repo-root]
#
# The elm-test harnesses that compile whole programs (TestLogic.TestPipeline and
# Compiler.PackageCompilation) must run the compiler's middle end only through
# Compiler.Pipeline.Steps, the functions Builder.Generate also calls, so a test
# compiles a program exactly the way `eco make` does. This fails if either file
# imports a pass module directly. Tests that unit-test one pass may import it;
# the harnesses may not.
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
FORBIDDEN='^import (Compiler\.GlobalOpt\.MonoInlineSimplify|Compiler\.GlobalOpt\.MonoGlobalOptimize|Compiler\.GlobalOpt\.InlineSimplify|Compiler\.GlobalOpt\.PreMono\.[A-Za-z]+|Compiler\.GlobalOpt\.MonoCse|Compiler\.GlobalOpt\.CafDedupe|Compiler\.GlobalOpt\.CafHoist|Compiler\.MonoSolver\.Monomorphize|Compiler\.MonoSolver\.Diff|Compiler\.Monomorphize\.Monomorphize|Compiler\.Monomorphize\.Prune)( |$)'
status=0
for f in compiler/tests/TestLogic/TestPipeline.elm compiler/tests/Compiler/PackageCompilation.elm; do
    hits=$(grep -nE "$FORBIDDEN" "$ROOT/$f")
    if [ -n "$hits" ]; then
        echo "check-test-pipeline-production: $f calls a compiler pass directly;"
        echo "  run it through Compiler.Pipeline.Steps instead:"
        echo "$hits" | sed 's/^/    /'
        status=1
    fi
done
[ $status -eq 0 ] && echo "check-test-pipeline-production: ok"
exit $status
