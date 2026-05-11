module RecordNarrow07UnboxedMixedTest exposing (main)

{-| Variation 10: mix an unboxed Int field into Inner.

    `captureAbi : Int` (unboxed) instead of `Maybe Int` (boxed). The full
    layout's unboxed-first sort puts captureAbi at index 0 (unboxed), then
    the four boxed fields alphabetically: captures=1, closureKind=2,
    lambdaId=3, params=4.

    The narrow inferred type `{a | captures, lambdaId, params}` is all-boxed,
    so narrow indices are: captures=0, lambdaId=1, params=2.

    Tests interaction with the unboxed-first sort in computeRecordLayout.

    Expected (correct): uid: 1998
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
            , captureAbi = 7
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

                _ =
                    List.length inner.captures

                _ =
                    List.length inner.params

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
