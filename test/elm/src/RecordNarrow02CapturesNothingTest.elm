module RecordNarrow02CapturesNothingTest exposing (main)

{-| A let-bound helper with an inferred extensible-record argument, folded over two records with `List.foldl`, reads the right nested field when its `captures` field is `Nothing`.

Each record is built without an annotation, and `buildSibling` is a let-bound
helper with no annotation, so its argument's type is inferred as an extensible
record naming only the fields it reads, while the records passed in carry more.
Here `captures` is `Nothing` rather than a list, and the helper inspects it
with a `case`. It then unwraps `inner.lambdaId`; both members hold `LambdaId 999`, so the sum is 1998.
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
