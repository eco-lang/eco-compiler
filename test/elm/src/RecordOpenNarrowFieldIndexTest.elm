module RecordOpenNarrowFieldIndexTest exposing (main)

{-| Reproducer for the Stage 7 Const_Nil crash.

    Mirrors `buildSiblingData` inside
    `Compiler.Generate.MLIR.Expr.generateLetGroup`:

      1. `buildSibling` is a let-bound, row-polymorphic local helper (no
         type annotation).
      2. The helper takes a tuple `(Int, ClosureBinding)` and only reads
         three fields of the nested record (captures, lambdaId, params).
      3. The helper is passed to `List.foldl`, which forces specialization
         against a concrete tuple type.

    If MLIR codegen indexes record projections against the row-polymorphic
    narrow inferred type (`{a | captures, lambdaId, params}`), the read of
    `inner.lambdaId` uses slot 1, but the heap value has the full 5-field
    layout (slot 1 = `captures`). Empty captures = [] = Const_Nil → the
    destructure `(LambdaId uid) = inner.lambdaId` aborts in eco_resolve_hptr.
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
