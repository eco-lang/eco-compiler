module Gopt003CaseStagingTest exposing (main)

{-| A `case` whose branches return functions written in different shapes, one a two-parameter lambda `\a b -> ...` and one a lambda returning a lambda `\a -> \b -> ...`, gives the right result whichever branch is taken.

Elm treats the two shapes as the same type, `Int -> Int -> Int`, and calling
either with two arguments must give the same answer as applying it one
argument at a time. Every chosen function is called with both arguments at
once. The `case` appears in five positions:

  - `caseFunc` is a `case` that is a definition's whole body, with two
    two-parameter branches (add, subtract) and one nested-lambda branch
    (multiply). `results` logs it on selectors 0, 1, 2, twice: 8, 2, 15.
  - `pickLetBound` binds the chosen function in a `let` and calls it twice,
    once with the selector itself as first argument: 11, 18, 21.
  - `pickInList` puts the `case` as the element of a list and applies it
    through `List.map`: `[8]`, `[15]`, `[15]`.
  - `pickAsArgument` passes the function returned by `join` to the
    higher-order `apply2`: 8, 15, 15.
  - `pickInRecord` stores the chosen function in a record field and calls it
    through the field: 8, 15, 15.

Every selector also passes through `Debug.log` (as `sel` or `n`), so those
lines are printed too; only the five result lines are checked.

## eco

Runtime guard for GOPT_003 in design_docs/invariants.csv, as rewritten by the
staging-honesty work (plans/staging-honesty-and-production-test-pipeline.md):
after GlobalOpt a function-valued join claims no staging beyond what all its
branches agree on. The branches keep their own staging (`[2]` and `[1, 1]`),
and every call through the join is a `segmentation_unknown` generic apply
that reads the closure header at run time (the CHECK-MLIR line). A call that
wrongly trusted a static staging shows up here as a wrong answer or a crash,
including through the minority curried branch.

The `pick*` functions hold joins that pre-mono eta-expansion
(compiler/src/Compiler/PreMono/EtaExpand.elm) cannot dissolve. Selectors go
through `Debug.log` so eta-expansion leaves the definitions alone (as in
test/eco-mlir/src/CrossStageCallKindTest.elm), and `List.map` keeps the
inliner from folding the calls away.

-}

-- CHECK: results: [8,2,15,8,2,15]
-- CHECK: letBound: [11,18,21]
-- CHECK: inList: [[8],[15],[15]]
-- CHECK: asArgument: [8,15,15]
-- CHECK: inRecord: [8,15,15]
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


{-| Returns, for `n0` equal to 0, a two-parameter lambda that adds, and
otherwise a lambda returning a lambda that multiplies.
-}
join : Int -> Int -> Int -> Int
join n0 =
    let
        n =
            Debug.log "n" n0
    in
    case n of
        0 ->
            \a b -> a + b

        _ ->
            \a -> \b -> a * b


pickLetBound : Int -> Int
pickLetBound n0 =
    let
        n =
            Debug.log "n" n0

        f =
            case n of
                0 ->
                    \a b -> a + b

                _ ->
                    \a -> \b -> a * b
    in
    f n 3 + f 5 3


pickInList : Int -> List Int
pickInList n0 =
    let
        n =
            Debug.log "n" n0
    in
    List.map (\g -> g 5 3)
        [ case n of
            0 ->
                \a b -> a + b

            _ ->
                \a -> \b -> a * b
        ]


apply2 : (Int -> Int -> Int) -> Int -> Int -> Int
apply2 g a b =
    g a b


pickAsArgument : Int -> Int
pickAsArgument n =
    apply2 (join n) 5 3


pickInRecord : Int -> Int
pickInRecord n0 =
    let
        n =
            Debug.log "n" n0

        r =
            { op =
                case n of
                    0 ->
                        \a b -> a + b

                    _ ->
                        \a -> \b -> a * b
            }
    in
    r.op 5 3


main =
    let
        _ =
            Debug.log "results" (List.map apply3 [ ( 0, 5, 3 ), ( 1, 5, 3 ), ( 2, 5, 3 ), ( 0, 5, 3 ), ( 1, 5, 3 ), ( 2, 5, 3 ) ])

        _ =
            Debug.log "letBound" (List.map pickLetBound [ 0, 1, 2 ])

        _ =
            Debug.log "inList" (List.map pickInList [ 0, 1, 2 ])

        _ =
            Debug.log "asArgument" (List.map pickAsArgument [ 0, 1, 2 ])

        _ =
            Debug.log "inRecord" (List.map pickInRecord [ 0, 1, 2 ])
    in
    text "done"
