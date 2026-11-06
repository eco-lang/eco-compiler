module RecordNarrow06RowPolyAnnotationTest exposing (main)

{-| A let-bound helper annotated with a nested extensible record type, folded with `List.foldl`, reads the right nested field.

`buildSibling` is annotated
`( Int, { a | inner : { b | captures : List Int, lambdaId : LambdaId, params : List Int } } ) -> Int -> Int`,
naming only the fields it reads, while the records passed in have four outer and
five inner fields. Both members hold `LambdaId 999`, so the sum is 1998.
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
