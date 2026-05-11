module RecordNarrow08NoDestructureTest exposing (main)

{-| Variation 16: NO destructure, just log the value.

    Read `inner.lambdaId` and pass it to `Debug.log` without destructuring.
    Debug.log uses Debug.toString to render, which inspects the value's
    type tag at runtime. With the narrow-layout misread, the bits at slot 1
    of the full layout are `captures = []`, so the value `inner.lambdaId`
    has type LambdaId statically but bits Const_Nil at runtime.

    Demonstrates the bug as silent miscompile (no destructure, no
    eco_resolve_hptr): the logged output will reveal what value was read.

    Expected (correct): lambdaId: LambdaId 999
    Buggy outcome: lambdaId: something else (likely empty list rendering,
    or runtime crash inside Debug.toString).
-}

-- CHECK: lambdaId: LambdaId 999

import Html exposing (text)


type LambdaId
    = LambdaId Int


main =
    let
        innerVal =
            { lambdaId = LambdaId 999
            , captures = []
            , params = []
            , closureKind = Nothing
            , captureAbi = Nothing
            }

        outer =
            { name = "test", inner = innerVal, body = 0, monoType = 0 }

        members =
            [ ( 0, outer ), ( 1, outer ) ]

        buildSibling tup acc =
            let
                member =
                    Tuple.second tup

                inner =
                    member.inner

                _ =
                    List.length inner.captures

                _ =
                    List.length inner.params

                _ =
                    Debug.log "lambdaId" inner.lambdaId
            in
            acc + 1

        result =
            List.foldl buildSibling 0 members

        _ =
            Debug.log "count" result
    in
    text "done"
