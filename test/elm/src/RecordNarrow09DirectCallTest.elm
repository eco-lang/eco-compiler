module RecordNarrow09DirectCallTest exposing (main)

{-| A let-bound helper with an inferred extensible-record argument reads the right nested field when called directly.

Each record is built without an annotation, and `buildSibling` is a let-bound
helper with no annotation, so its argument's type is inferred as an extensible
record naming only the fields it reads, while the records passed in carry more.
The helper is applied once to `( 0, outer )` rather than passed to `List.foldl`,
so the result is the single `LambdaId 999` unwrapped plus the initial 0.
-}

-- CHECK: uid: 999

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
            buildSibling ( 0, outer ) 0

        _ =
            Debug.log "uid" result
    in
    text "done"
