module RecordNarrow08NoDestructureTest exposing (main)

{-| A let-bound helper with an inferred extensible-record argument, folded with `List.foldl`, logs a nested custom-type field as `LambdaId 999`.

Each record is built without an annotation, and `buildSibling` is a let-bound
helper with no annotation, so its argument's type is inferred as an extensible
record naming only the fields it reads, while the records passed in carry more.
The helper passes `inner.lambdaId` straight to `Debug.log` instead of
destructuring it, and returns a count. It runs once per member, so `lambdaId`
is logged twice; the CHECK line matches the first.
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
