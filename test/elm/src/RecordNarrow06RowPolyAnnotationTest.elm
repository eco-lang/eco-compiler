module RecordNarrow06RowPolyAnnotationTest exposing (main)

{-| Variation 2: explicit row-polymorphic annotation matching the access.

    `buildSibling` has an explicit row-polymorphic type signature naming the
    three inner fields it accesses. This makes the narrowing explicit in the
    source rather than inferred.

    Confirms whether the bug is specifically about row polymorphism (whether
    inferred or annotated). If this test still crashes, the bug is about
    record polymorphism itself, not about absence of annotation.

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
            , captureAbi = Nothing
            }

        outer1 =
            { name = "test1", inner = innerVal, body = 0, monoType = 0 }

        outer2 =
            { name = "test2", inner = innerVal, body = 0, monoType = 0 }

        members =
            [ ( 0, outer1 ), ( 1, outer2 ) ]

        buildSibling : ( Int, { a | inner : { b | captures : List Int, lambdaId : LambdaId, params : List Int } } ) -> Int -> Int
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
