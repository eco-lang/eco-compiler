module Gopt003CaseStagingTest exposing (main)

{-| GOPT_003 runtime guard: joins (`case`s) whose branches return differently
staged lambdas, called through EVERY branch, including the minority curried one.

GOPT_003 (as rewritten by plans/staging-honesty-and-production-test-pipeline.md
P2.3): after GlobalOpt a function-valued join makes no staging claim beyond what
all of its branches agree on. The branches keep their own staging (a `[2]`
lambda and a `[1, 1]` lambda here), and every call through such a value is a
`segmentation_unknown` / generic apply, which reads the closure header at run
time. This test turns a call that wrongly trusted a static staging into a wrong
ANSWER or a crash.

`caseFunc` is a join that is a definition's whole body. The four `pick*`
functions hold joins a build's pre-mono η-expansion cannot dissolve: let-bound
and called twice, the element of a list, the argument of a higher-order
function, and the field of a record (the elm-test twins are JoinpointABI
category 6). Every scrutinee goes through `Debug.log` so pre-mono η-expansion
leaves the definitions alone (see `CrossStageCallKindTest`), and `List.map`
keeps the inliner from folding the calls away.

-}

-- CHECK: results: [8, 2, 15, 8, 2, 15]
-- CHECK: letBound: [11, 18, 21]
-- CHECK: inList: [[8], [15], [15]]
-- CHECK: asArgument: [8, 15, 15]
-- CHECK: inRecord: [8, 15, 15]
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


{-| A `[2]` branch and a `[1, 1]` branch.
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
