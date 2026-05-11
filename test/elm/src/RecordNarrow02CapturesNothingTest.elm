module RecordNarrow02CapturesNothingTest exposing (main)

{-| Variation 15: replace `captures : List Int` with `captures : Maybe Int`.

    Same shape as the original repro, but captures is now Maybe Int (Nothing).
    Nothing is the embedded constant Const_Nothing (constant=6), distinct from
    Const_Nil (constant=5).

    Confirms the misread slot identity by observing a different embedded
    constant in the crash diagnostic.

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
            , captures = Nothing
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

                _ =
                    case inner.captures of
                        Just _ ->
                            1

                        Nothing ->
                            0

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
