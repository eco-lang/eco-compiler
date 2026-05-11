module RecordNarrow03FullAnnotationTest exposing (main)

{-| Variation 1: NEGATIVE CONTROL.

    Same shape as the bug reproducer, but `buildSibling` carries an explicit
    full-type annotation `(Int, Outer) -> Int -> Int`. The concrete record
    type should prevent row-polymorphic narrowing, so codegen should use the
    full 5-field layout indices and the test should PASS.

    Expected (correct): uid: 1998
    If this test still crashes, the bug is not row-poly-specific.
-}

-- CHECK: uid: 1998

import Html exposing (text)


type LambdaId
    = LambdaId Int


type alias Inner =
    { lambdaId : LambdaId
    , captures : List Int
    , params : List Int
    , closureKind : Maybe Int
    , captureAbi : Maybe Int
    }


type alias Outer =
    { name : String
    , inner : Inner
    , body : Int
    , monoType : Int
    }


main =
    let
        innerVal : Inner
        innerVal =
            { lambdaId = LambdaId 999
            , captures = []
            , params = []
            , closureKind = Nothing
            , captureAbi = Nothing
            }

        outer1 : Outer
        outer1 =
            { name = "test1", inner = innerVal, body = 0, monoType = 0 }

        outer2 : Outer
        outer2 =
            { name = "test2", inner = innerVal, body = 0, monoType = 0 }

        members : List ( Int, Outer )
        members =
            [ ( 0, outer1 ), ( 1, outer2 ) ]

        buildSibling : ( Int, Outer ) -> Int -> Int
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
