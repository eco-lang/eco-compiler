module Gopt003CaseStagingTest exposing (main)

{-| GOPT_003 runtime guard: a `case` whose branches return differently staged
lambdas, called through EVERY branch, including the minority curried one.

After GlobalOpt such a `case` keeps its monomorphized (curried) result type
while its flat branches are retyped `[Int, Int] -> Int` and the curried branch
is NOT wrapped to the majority staging, so GOPT_003 ("all branch result types
equal the case result type including staging") does not hold. See
/work/gopt003-issue.md and the elm-test pin "GOPT_003 BUG PIN" in
`TestLogic.Monomorphize.MonoCaseBranchResultTypeTest`.

No wrong output is known: codegen emits the call on the case-selected value as
a `segmentation_unknown` generic apply, which copes with any staging. This test
turns a regression of that fallback into a wrong ANSWER or a crash; it passes
today. `CrossStageCallKindTest` exercises only the flat branch.

The scrutinee goes through `Debug.log` so pre-mono η-expansion leaves the
definition alone (see `CrossStageCallKindTest`), and `List.map` keeps the
inliner from folding the calls away.

-}

-- CHECK: results: [8, 2, 15, 8, 2, 15]
-- CHECK-MLIR: segmentation_unknown

import Html exposing (text)


caseFunc : Int -> Int -> Int -> Int
caseFunc x0 =
    let
        x =
            Debug.log "sel" x0
    in
    case x of
        0 ->
            \a b -> a + b

        1 ->
            \a b -> a - b

        _ ->
            \a -> \b -> a * b


apply3 : ( Int, Int, Int ) -> Int
apply3 ( s, a, b ) =
    caseFunc s a b


main =
    let
        _ =
            Debug.log "results" (List.map apply3 [ ( 0, 5, 3 ), ( 1, 5, 3 ), ( 2, 5, 3 ), ( 0, 5, 3 ), ( 1, 5, 3 ), ( 2, 5, 3 ) ])
    in
    text "done"
