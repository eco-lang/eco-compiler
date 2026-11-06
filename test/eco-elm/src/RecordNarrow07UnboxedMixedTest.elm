module RecordNarrow07UnboxedMixedTest exposing (main)

{-| A let-bound helper with an inferred extensible-record argument, folded with `List.foldl`, reads the right nested field when the record also has an `Int` field it does not read.

Each record is built without an annotation, and `buildSibling` is a let-bound
helper with no annotation, so its argument's type is inferred as an extensible
record naming only the fields it reads, while the records passed in carry more.
The inner record's `captureAbi` is the `Int` 7, which the helper never reads. The
helper unwraps `inner.lambdaId`; both members hold `LambdaId 999`, so the sum is 1998.

## eco

Record-narrowing variation with an unboxed field. The full record layout from
`computeRecordLayout` (compiler/src/Compiler/GenerateMlir/Types.elm) puts
unboxed fields first, so `captureAbi` is at index 0 and the boxed fields follow
alphabetically: captures 1, closureKind 2, lambdaId 3, params 4. The helper's
narrow inferred type `{ a | captures, lambdaId, params }` is all boxed, with
indices 0, 1 and 2. Field access must use the full layout's indices, not the
narrow ones, or it reads the wrong field.

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
