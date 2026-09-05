module TestLogic.Monomorphize.MonoTraverseTest exposing (suite)

{-| `MonoTraverse.traverseExpr` — the context-threaded bottom-up rewrite.

Pins the contract that the E4a regression violated (`DEFECTS_DO_NOT_FORGET.md`
§3): the callback runs EXACTLY ONCE per node, children before parent, with the
context threaded in evaluation order — in particular under `MonoLet` RHSs and
`MonoCase` inline branches, where the traversal used to re-lift its callback
and walk each subtree once per path (exponential in nesting). A counting
callback over deeply nested let/case/if trees must count exactly the node
total that `childrenOf` / `foldExpr` give, and an identity callback must
return the same tree.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Reporting.Annotation as A
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MonoTraverse.traverseExpr applies its callback exactly once per node"
        [ Test.test "1. nested let RHSs: visits == nodes (was 2^depth-ish)" <|
            \() -> expectOnce (nestedLets 12)
        , Test.test "2. nested case branches: visits == nodes" <|
            \() -> expectOnce (nestedCases 10)
        , Test.test "3. lets inside case branches inside lets" <|
            \() -> expectOnce (mixed 6)
        , Test.test "4. bottom-up, evaluation order: leaves are seen left to right before their parent" <|
            \() ->
                let
                    tree =
                        Mono.MonoLet (Mono.MonoDef "x" (lit 1))
                            (Mono.MonoIf [ ( lit 2, lit 3 ) ] (Mono.MonoList A.zero [ lit 4, lit 5 ] Mono.MInt) Mono.MInt)
                            Mono.MInt

                    ( _, seen ) =
                        MonoTraverse.traverseExpr
                            (\acc e ->
                                ( Nothing
                                , case e of
                                    Mono.MonoLiteral (Mono.LInt n) _ ->
                                        acc ++ [ String.fromInt n ]

                                    Mono.MonoList _ _ _ ->
                                        acc ++ [ "list" ]

                                    Mono.MonoIf _ _ _ ->
                                        acc ++ [ "if" ]

                                    Mono.MonoLet _ _ _ ->
                                        acc ++ [ "let" ]

                                    _ ->
                                        acc ++ [ "?" ]
                                )
                            )
                            []
                            tree
                in
                Expect.equal seen [ "1", "2", "3", "4", "5", "list", "if", "let" ]
        , Test.test "5b. every rebuild path propagates a change to the root" <|
            \() ->
                -- Bump every Int literal by 1 through a tree that exercises
                -- let RHSs, case branches (Chain and FanOut), jumps, tuples and
                -- ifs. If any constructor arm dropped a rebuilt child, or kept
                -- the original when a child changed, the sum would not move by
                -- exactly the number of literals.
                let
                    tree =
                        mixed 6

                    ( bumped, _ ) =
                        MonoTraverse.traverseExpr
                            (\c e ->
                                case e of
                                    Mono.MonoLiteral (Mono.LInt n) t ->
                                        ( Just (Mono.MonoLiteral (Mono.LInt (n + 1)) t), c )

                                    _ ->
                                        ( Nothing, c )
                            )
                            ()
                            tree
                in
                Expect.equal ( sumLits bumped, countLits bumped )
                    ( sumLits tree + countLits tree, countLits tree )
        , Test.test "5c. mapExpr rewrites without a context" <|
            \() ->
                let
                    tree =
                        mixed 4

                    bumped =
                        MonoTraverse.mapExpr
                            (\e ->
                                case e of
                                    Mono.MonoLiteral (Mono.LInt n) t ->
                                        Just (Mono.MonoLiteral (Mono.LInt (n + 1)) t)

                                    _ ->
                                        Nothing
                            )
                            tree
                in
                Expect.equal (sumLits bumped) (sumLits tree + countLits tree)
        , Test.test "5d. a callback that never changes anything returns the input tree" <|
            \() ->
                let
                    tree =
                        mixed 5
                in
                Expect.equal (MonoTraverse.mapExpr (\_ -> Nothing) tree) tree
        , Test.test "5. identity callback returns the same tree" <|
            \() ->
                let
                    tree =
                        mixed 5
                in
                Expect.equal (Tuple.first (MonoTraverse.traverseExpr (\c _ -> ( Nothing, c )) () tree)) tree
        ]


expectOnce : Mono.MonoExpr -> Expect.Expectation
expectOnce tree =
    let
        visits =
            Tuple.second (MonoTraverse.traverseExpr (\n _ -> ( Nothing, n + 1 )) 0 tree)

        nodes =
            size tree

        folded =
            MonoTraverse.foldExpr (\_ n -> n + 1) 0 tree
    in
    Expect.equal ( visits, folded ) ( nodes, nodes )


sumLits : Mono.MonoExpr -> Int
sumLits =
    MonoTraverse.foldExpr
        (\e acc ->
            case e of
                Mono.MonoLiteral (Mono.LInt n) _ ->
                    acc + n

                _ ->
                    acc
        )
        0


countLits : Mono.MonoExpr -> Int
countLits =
    MonoTraverse.foldExpr
        (\e acc ->
            case e of
                Mono.MonoLiteral (Mono.LInt _) _ ->
                    acc + 1

                _ ->
                    acc
        )
        0


size : Mono.MonoExpr -> Int
size e =
    1 + List.sum (List.map size (MonoTraverse.childrenOf e))



-- ====== TREES ======


lit : Int -> Mono.MonoExpr
lit n =
    Mono.MonoLiteral (Mono.LInt n) Mono.MInt


{-| `let x = <inner> in x` nested `depth` deep — each level puts the whole
subtree under a MonoDef RHS.
-}
nestedLets : Int -> Mono.MonoExpr
nestedLets depth =
    if depth <= 0 then
        lit 0

    else
        Mono.MonoLet (Mono.MonoDef "x" (nestedLets (depth - 1))) (Mono.MonoVarLocal "x" Mono.MInt) Mono.MInt


{-| A case whose inline branch holds the whole subtree, nested `depth` deep.
-}
nestedCases : Int -> Mono.MonoExpr
nestedCases depth =
    if depth <= 0 then
        lit 0

    else
        Mono.MonoCase "c"
            "s"
            (Mono.Chain [] (Mono.Leaf (Mono.Inline (nestedCases (depth - 1)))) (Mono.Leaf (Mono.Jump 0)))
            [ ( 0, lit 1 ) ]
            Mono.MInt


mixed : Int -> Mono.MonoExpr
mixed depth =
    if depth <= 0 then
        Mono.MonoIf [ ( lit 1, lit 2 ) ] (lit 3) Mono.MInt

    else
        Mono.MonoLet (Mono.MonoDef "y" (nestedCases 2))
            (Mono.MonoCase "c"
                "s"
                (Mono.FanOut (Mono.DtRoot "s" Mono.MInt) [] (Mono.Leaf (Mono.Inline (mixed (depth - 1)))))
                [ ( 0, Mono.MonoTupleCreate A.zero [ lit 4, mixed (depth - 2) ] Mono.MInt ) ]
                Mono.MInt
            )
            Mono.MInt
