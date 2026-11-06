module RecordOpenNarrowFieldIndexTest exposing (main)

{-| A let-bound helper with an inferred extensible-record argument, folded over two nested records with `List.foldl`, reads the right nested field.

`buildSibling` has no annotation and reads only `captures`, `params` and
`lambdaId` of `member.inner`, so its argument's type is inferred as a tuple
holding extensible records that name only those fields, while the records
passed in have four outer and five inner fields. Both members hold `LambdaId 999`, so the sum is 1998.

The `RecordNarrow` tests are variations of this program.
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
            { name = "test1"
            , inner = innerVal
            , body = 0
            , monoType = 0
            }

        outer2 =
            { name = "test2"
            , inner = innerVal
            , body = 0
            , monoType = 0
            }

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
