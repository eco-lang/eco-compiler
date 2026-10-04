module TestLogic.Monomorphize.MonoTraverseTest exposing (suite)

{-| Tests for `MonoTraverse.traverseExpr` and `MonoTraverse.mapExpr`, the
bottom-up rewrites over a `MonoExpr` tree, and for the node count
`MonoTraverse.foldExpr` gives.

`traverseExpr` runs its callback once per node, after the node's children, and
threads a context value through the calls in evaluation order. If a let's
bound expression or a case branch were walked more than once, the callback
would run more than once on the nodes inside it: the work would grow
exponentially with nesting depth, and a callback that counts would count
too many.

The fixtures are built by hand. `nestedLets` nests lets through their bound
expressions, `nestedCases` nests cases through an inline branch, and `mixed`
combines both with ifs, tuples and case jump bodies (the branch bodies a
`MonoCase` holds apart from its decision tree, which a `Jump` leaf names by
index). Every literal in them is an `Int`.

The tests establish:

  - Tests 1 to 3 (`nestedLets 12`, `nestedCases 10`, `mixed 6`): a callback
    that counts its calls counts exactly the nodes of the tree, as `size`
    computes them from `MonoTraverse.childrenOf`, and a counting
    `MonoTraverse.foldExpr` gives the same number.
  - Test 4: on `let x = 1 in if 2 then 3 else [4, 5]`, the callback sees the
    literals 1 to 5 in that order, then the list, the if and the let, so each
    node comes after its children and siblings come left to right.
  - Test 5b: adding one to every literal through `traverseExpr` on `mixed 6`
    raises the sum of the literals by the number of literals and leaves that
    number unchanged.
  - Test 5c: the same rewrite through `mapExpr` on `mixed 4` raises the sum by
    the number of literals.
  - Test 5d: `mapExpr` with a callback that always returns `Nothing` returns a
    tree equal to its input, `mixed 5`.
  - Test 5: `traverseExpr` with a callback that always returns `Nothing` and
    the context it was given returns a tree equal to its input, `mixed 5`.

Among what is not tested: closures, calls, tail calls, destructuring and the
record expressions, which no fixture contains; the failure branch of a `Chain`
and the edges of a `FanOut`, which hold no expression in any fixture; whether
an unchanged tree comes back as the same value or only an equal one, since
`Expect.equal` compares structure; and a child position that `traverseExpr`
and `childrenOf` both skip, since the expected count comes from `childrenOf`.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Reporting.Annotation as A
import Expect
import Test exposing (Test)


{-| The tests of `traverseExpr`, `mapExpr` and the `foldExpr` count, in the
order the module docstring lists them.
-}
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
                -- `mixed` holds literals under let bound expressions, Chain
                -- success leaves and FanOut fallbacks, case jump bodies,
                -- tuples and ifs. A rebuild that kept the original node in
                -- place of a changed child on any of those paths would leave
                -- the sum short.
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


{-| Checks that a callback counting its calls through `traverseExpr`, and a
counting `foldExpr`, both count the nodes of `tree` as `size` gives them.
-}
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


{-| Returns the sum of the `Int` literals in an expression.
-}
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


{-| Returns the number of `Int` literals in an expression.
-}
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


{-| Returns the number of nodes in an expression, counting the expression
itself and recursing through `MonoTraverse.childrenOf`.
-}
size : Mono.MonoExpr -> Int
size e =
    1 + List.sum (List.map size (MonoTraverse.childrenOf e))



-- ====== TREES ======


{-| Builds an `Int` literal of type `MInt` holding `n`.
-}
lit : Int -> Mono.MonoExpr
lit n =
    Mono.MonoLiteral (Mono.LInt n) Mono.MInt


{-| Builds `depth` lets nested through their bound expressions. Each level is
`let x = inner in x`, where `inner` is the next level down, and the innermost
is the literal 0.
-}
nestedLets : Int -> Mono.MonoExpr
nestedLets depth =
    if depth <= 0 then
        lit 0

    else
        Mono.MonoLet (Mono.MonoDef "x" (nestedLets (depth - 1))) (Mono.MonoVarLocal "x" Mono.MInt) Mono.MInt


{-| Builds `depth` cases nested through an inline branch, down to the literal 0.

Each case's decision tree is a `Chain` with no tests: its success leaf holds the
next level inline, and its failure leaf jumps to the case's one jump body, the
literal 1.

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


{-| Builds a tree `depth` levels deep that combines lets, cases, tuples and ifs.

Each level is a let whose bound expression is `nestedCases 2` and whose body is
a case. The case's decision tree is a `FanOut` with no edges whose fallback
holds `mixed (depth - 1)` inline, and its one jump body is a tuple of the
literal 4 and `mixed (depth - 2)`. At a `depth` of zero or below the tree is
`if 1 then 2 else 3`.

-}
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
