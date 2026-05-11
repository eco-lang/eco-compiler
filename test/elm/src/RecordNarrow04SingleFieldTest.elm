module RecordNarrow04SingleFieldTest exposing (main)

{-| Variation 7: access only ONE inner field.

    The helper only reads `inner.lambdaId`. The narrow inferred type is
    `{ a | lambdaId }`, so narrow index for lambdaId is 0. The full layout
    has captureAbi at index 0. With `captureAbi = Nothing`, slot 0 contains
    Const_Nothing bits.

    Confirms the off-by-N narrowing is general (not specific to N=2).

    Expected (correct): uid: 1998
    Buggy outcome: native abort in eco_resolve_hptr with constant=6 (Const_Nothing).
-}

-- CHECK: uid: 1998

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

        outer1 =
            { name = "test1", inner = innerVal, body = 0, monoType = 0 }

        outer2 =
            { name = "test2", inner = innerVal, body = 0, monoType = 0 }

        members =
            [ ( 0, outer1 ), ( 1, outer2 ) ]

        buildSibling tup acc =
            let
                member =
                    Tuple.second tup

                inner =
                    member.inner

                (LambdaId uid) =
                    inner.lambdaId
            in
            uid + acc

        result =
            List.foldl buildSibling 0 members

        _ =
            Debug.log "uid" result
    in
    text "done"
