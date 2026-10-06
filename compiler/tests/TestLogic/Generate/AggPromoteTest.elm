module TestLogic.Generate.AggPromoteTest exposing (suite)

{-| Pins the verdicts of the escape walk, one of the checks that decide
whether a tuple or custom-type value bound in a `let` may be promoted, on ten
small functions, so that a change to the walk that turns one of those verdicts
fails here.

An _aggregate_ is a tuple or a value of a custom type. _Aggregate promotion_
is MLIR generation building a `let`-bound aggregate as a value
(`eco.make.tuple2`, `eco.make.tuple3` or `eco.make.custom`) instead of
allocating it on the heap. It is allowed only when the binder does not
_escape_: every use reads a field of the value rather than the value itself.
Returning the value, passing it to a call or capturing it in a closure are
escapes. The full rule, with its exceptions, belongs to
`Compiler.Generate.MLIR.Expr.tupleBinderPromotable` and
`Compiler.Generate.MLIR.Expr.aggBinderPromotableWith`, which these tests call.

The fixture is one source module, `fixtureModule`, with one function per
scenario. Every test runs it through `TestLogic.TestPipeline.runToGlobalOpt`
(the production pipeline up to and including global optimization) and asks for a verdict on the optimized graph. A function is
found as the first specialization, in SpecId order, whose comparable global
name contains the function's name and which yields a verdict, so no scenario
name may occur inside another; matching is case-sensitive, so `good` does not
match `caseGood`. Each test expects `Just True` (promotable) or `Just False`
(escapes); `Nothing`, meaning the function or its `let` was not found, fails.

The tuple tests take the function's first `let` whose value is a tuple and ask
`tupleBinderPromotable`. Every such tuple is `(a * 2, b * 3)`, bound to `t`.

  - `good` destructures `t` with a `let` pattern `(x, y)`: promotable. The
    typed optimizer lowers that pattern to a `let` binding a fresh name to
    `t`, whose fields are then read from that name, so `good` also exercises
    the walk's admission of an alias of the binder.
  - `bad` returns `t`: escapes.
  - `passed` passes `t` to `useTuple`: escapes.
  - `caseGood` matches `t` against `(x, y)` in a `case`: promotable.
  - `caseNested` matches `t` against `(0, y)` and then `(x, _)`, so the
    `case` tests the first element: promotable.
  - `caseAndPass` matches `t` in a `case` and also passes it to `useTuple`:
    escapes.

The constructor tests take the function's first `let` whose value is a call to
a constructor, and ask `aggBinderPromotableWith` with that constructor's
`CustomContainer` as the kind of container a field read must go through.

  - `ctorGood` binds `p = MkPair a b` and matches it against `MkPair x y`:
    promotable.
  - `ctorBad` passes `p` to `usePair`: escapes.
  - `ctorMulti` binds `m = Yes a` and matches it against `Yes x` and `No y`.
    Its type has two constructors, so the `case` tests which constructor `m`
    is, which reads `m` itself: escapes.
  - `ctorCap` returns a lambda that captures `p` and passes it to `usePair`:
    escapes.

Among what is not tested: the walk is always given empty tables of split
parameters, of argument positions of calls to functions whose aggregate
parameter has been split into its fields, and of forward-referenced names, so
the allowances and the guard that depend on them are not exercised; the
constructor tests bypass `promotableCtorCall`, so its configuration flag,
saturation and arity conditions are not checked; no fixture has a 3-tuple or
a tail-recursive function; the solver engine is not used; and no MLIR is
generated.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as B
import Compiler.Generate.MLIR.Expr as Expr
import Dict
import Expect
import Set
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The ten verdict tests, one per scenario function in `fixtureModule`.
-}
suite : Test
suite =
    Test.describe "U-T1.3.1 tupleBinderPromotable"
        [ Test.test "promotable: let-bound tuple only destructured" <|
            \_ ->
                expectVerdict "good" (Just True)
        , Test.test "escaping: let-bound tuple returned" <|
            \_ ->
                expectVerdict "bad" (Just False)
        , Test.test "escaping: let-bound tuple passed to a call" <|
            \_ ->
                expectVerdict "passed" (Just False)
        , Test.test "T1.3.1b promotable: tuple destructured via case scrutinee" <|
            \_ ->
                expectVerdict "caseGood" (Just True)
        , Test.test "T1.3.1b promotable: nested-pattern case (element test projects through the root)" <|
            \_ ->
                expectVerdict "caseNested" (Just True)
        , Test.test "T1.3.1b escaping: case-scrutinized tuple ALSO passed to a call" <|
            \_ ->
                expectVerdict "caseAndPass" (Just False)
        , Test.test "T1.3.2 promotable: single-ctor custom built and cased locally" <|
            \_ ->
                expectCtorVerdict "ctorGood" (Just True)
        , Test.test "T1.3.2 escaping: ctor call passed to a call" <|
            \_ ->
                expectCtorVerdict "ctorBad" (Just False)
        , Test.test "T1.3.2 escaping: multi-ctor candidate is rejected (tag dispatch on root)" <|
            \_ ->
                expectCtorVerdict "ctorMulti" (Just False)
        , Test.test "T1.3.2r escaping: ctor captured by a returned lambda" <|
            \_ ->
                expectCtorVerdict "ctorCap" (Just False)
        ]


{-| Runs `fixtureModule` to global optimization and expects `expected` to be
the constructor verdict for the function named by `defName`: the verdict of
`Expr.aggBinderPromotableWith` on that function's first `let` whose value is a
call to a constructor, with the constructor's `CustomContainer` as the kind.

The function is the first specialization, in SpecId order, whose comparable
global name contains `defName` and for which `nodeCtorVerdict` gives a
verdict. If `Pipeline.runToGlobalOpt` returns an error, the test fails with
its message.

-}
expectCtorVerdict : String -> Maybe Bool -> Expect.Expectation
expectCtorVerdict defName expected =
    case Pipeline.runToGlobalOpt fixtureModule of
        Err msg ->
            Expect.fail ("pipeline: " ++ msg)

        Ok { optimizedMonoGraph } ->
            let
                (Mono.MonoGraph { nodes, registry }) =
                    optimizedMonoGraph

                ctorShapeOf specId =
                    case Array.get specId nodes of
                        Just (Just (Mono.MonoCtor shape _)) ->
                            Just shape

                        _ ->
                            Nothing

                verdict =
                    Array.foldl
                        (\( maybeName, maybeNode ) acc ->
                            case acc of
                                Just _ ->
                                    acc

                                Nothing ->
                                    case ( maybeName, maybeNode ) of
                                        ( Just ( g, _ ), Just node ) ->
                                            if String.contains defName (Mono.toComparableGlobal g) then
                                                nodeCtorVerdict ctorShapeOf node

                                            else
                                                Nothing

                                        _ ->
                                            Nothing
                        )
                        Nothing
                        (zipArrays registry.reverseMapping nodes)
            in
            verdict |> Expect.equal expected


{-| Returns the constructor verdict for the body of `node`, as `findCtorLet`
finds it, or `Nothing` when `node` is neither a `MonoDefine` nor a
`MonoTailFunc`.
-}
nodeCtorVerdict : (Int -> Maybe Mono.CtorShape) -> Mono.MonoNode -> Maybe Bool
nodeCtorVerdict ctorShapeOf node =
    case node of
        Mono.MonoDefine body _ ->
            findCtorLet ctorShapeOf body

        Mono.MonoTailFunc _ body _ ->
            findCtorLet ctorShapeOf body

        _ ->
            Nothing


{-| Returns the escape walk's verdict on the first `let` in `expr` that binds a
call to a global which `ctorShapeOf` maps to a constructor shape, with that
constructor's `CustomContainer` as the kind, or `Nothing` if there is none.

The search goes down through closures and through the bodies of `let`s and
destructures, and nowhere else, so a `let` inside a `case` branch, an `if`, a
call argument or another `let`'s value is not found.

-}
findCtorLet : (Int -> Maybe Mono.CtorShape) -> Mono.MonoExpr -> Maybe Bool
findCtorLet ctorShapeOf expr =
    case expr of
        Mono.MonoClosure _ inner _ ->
            findCtorLet ctorShapeOf inner

        Mono.MonoLet (Mono.MonoDef x (Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) _ _ _)) body _ ->
            case ctorShapeOf specId of
                Just shape ->
                    Just (Expr.aggBinderPromotableWith (Mono.CustomContainer shape.name) x body)

                Nothing ->
                    findCtorLet ctorShapeOf body

        Mono.MonoLet _ body _ ->
            findCtorLet ctorShapeOf body

        Mono.MonoDestruct _ body _ ->
            findCtorLet ctorShapeOf body

        _ ->
            Nothing


{-| Runs `fixtureModule` to global optimization and expects `expected` to be
the tuple verdict for the function named by `defName`: the verdict of
`Expr.tupleBinderPromotable` on that function's first `let` whose value is a
tuple, as `findTupleLet` finds it.

The function is the first specialization, in SpecId order, whose comparable
global name contains `defName` and for which `nodeVerdict` gives a verdict.
If `Pipeline.runToGlobalOpt` returns an error, the test fails with its message.

-}
expectVerdict : String -> Maybe Bool -> Expect.Expectation
expectVerdict defName expected =
    case Pipeline.runToGlobalOpt fixtureModule of
        Err msg ->
            Expect.fail ("pipeline: " ++ msg)

        Ok { optimizedMonoGraph } ->
            let
                (Mono.MonoGraph { nodes, registry }) =
                    optimizedMonoGraph

                verdict =
                    Array.foldl
                        (\( maybeName, maybeNode ) acc ->
                            case acc of
                                Just _ ->
                                    acc

                                Nothing ->
                                    case ( maybeName, maybeNode ) of
                                        ( Just ( g, _ ), Just node ) ->
                                            if String.contains defName (Mono.toComparableGlobal g) then
                                                nodeVerdict node

                                            else
                                                Nothing

                                        _ ->
                                            Nothing
                        )
                        Nothing
                        (zipArrays registry.reverseMapping nodes)
            in
            verdict |> Expect.equal expected


{-| Returns the pairs of elements of `xs` and `ys` at the same index, as long
as the shorter array. The tests use it to pair each specialization's registry
entry with its node, since both arrays are indexed by SpecId.
-}
zipArrays : Array.Array a -> Array.Array b -> Array.Array ( a, b )
zipArrays xs ys =
    Array.indexedMap
        (\i x ->
            case Array.get i ys of
                Just y ->
                    Just ( x, y )

                Nothing ->
                    Nothing
        )
        xs
        |> Array.foldr
            (\m acc ->
                case m of
                    Just p ->
                        p :: acc

                    Nothing ->
                        acc
            )
            []
        |> Array.fromList


{-| Returns the tuple verdict for the body of `node`, as `findTupleLet` finds
it, or `Nothing` when `node` is neither a `MonoDefine` nor a `MonoTailFunc`.
-}
nodeVerdict : Mono.MonoNode -> Maybe Bool
nodeVerdict node =
    case node of
        Mono.MonoDefine body _ ->
            findTupleLet body

        Mono.MonoTailFunc _ body _ ->
            findTupleLet body

        _ ->
            Nothing


{-| Returns the verdict of `Expr.tupleBinderPromotable` on the first `let` in
`expr` whose value is a tuple, or `Nothing` if there is none.

The walk is given empty tables of split parameters, of argument positions of
calls to functions whose aggregate parameter has been split into its fields,
and of forward-referenced names. The search goes down through closures and
through the bodies of `let`s and destructures, and nowhere else.

-}
findTupleLet : Mono.MonoExpr -> Maybe Bool
findTupleLet expr =
    case expr of
        Mono.MonoClosure _ inner _ ->
            findTupleLet inner

        Mono.MonoLet (Mono.MonoDef x (Mono.MonoTupleCreate _ _ tupleTy)) body _ ->
            Just (Expr.tupleBinderPromotable Dict.empty Dict.empty Set.empty x tupleTy body)

        Mono.MonoLet _ body _ ->
            findTupleLet body

        Mono.MonoDestruct _ body _ ->
            findTupleLet body

        _ ->
            Nothing


{-| The source module `Test` that every test compiles: one function per
scenario, as the module docstring lists them, with the helpers they use and
the custom types `Pair`, whose one constructor is `MkPair Int Int`, and `MB`,
whose constructors are `Yes Int` and `No Int`.

`useTuple` and `usePair` return the sum of the two fields of the value they
are given. `passed` and `caseAndPass` pass their tuple to `useTuple`, and
`ctorBad` and `ctorCap` pass their `Pair` to `usePair`. `testValue` calls
every scenario function, `bad` through `useTuple`, so that each one is
reached from the `main` that `TestLogic.TestPipeline` adds and is specialized
by monomorphization.

-}
fixtureModule : Src.Module
fixtureModule =
    let
        intType =
            B.tType "Int" []

        tupleTy =
            B.tTuple intType intType

        mkTuple =
            B.tupleExpr
                (B.binopsExpr [ ( B.varExpr "a", "*" ) ] (B.intExpr 2))
                (B.binopsExpr [ ( B.varExpr "b", "*" ) ] (B.intExpr 3))

        goodBody =
            B.letExpr
                [ B.define "t" [] mkTuple
                , B.destruct (B.pTuple (B.pVar "x") (B.pVar "y")) (B.varExpr "t")
                ]
                (B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y"))

        badBody =
            B.letExpr [ B.define "t" [] mkTuple ] (B.varExpr "t")

        passedBody =
            B.letExpr [ B.define "t" [] mkTuple ]
                (B.callExpr (B.varExpr "useTuple") [ B.varExpr "t" ])

        useTupleBody =
            B.caseExpr (B.varExpr "p")
                [ ( B.pTuple (B.pVar "x") (B.pVar "y")
                  , B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y")
                  )
                ]

        caseGoodBody =
            B.letExpr [ B.define "t" [] mkTuple ]
                (B.caseExpr (B.varExpr "t")
                    [ ( B.pTuple (B.pVar "x") (B.pVar "y")
                      , B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y")
                      )
                    ]
                )

        caseNestedBody =
            B.letExpr [ B.define "t" [] mkTuple ]
                (B.caseExpr (B.varExpr "t")
                    [ ( B.pTuple (B.pInt 0) (B.pVar "y")
                      , B.varExpr "y"
                      )
                    , ( B.pTuple (B.pVar "x") B.pAnything
                      , B.varExpr "x"
                      )
                    ]
                )

        caseAndPassBody =
            B.letExpr [ B.define "t" [] mkTuple ]
                (B.binopsExpr
                    [ ( B.caseExpr (B.varExpr "t")
                            [ ( B.pTuple (B.pVar "x") B.pAnything
                              , B.varExpr "x"
                              )
                            ]
                      , "+"
                      )
                    ]
                    (B.callExpr (B.varExpr "useTuple") [ B.varExpr "t" ])
                )

        ctorGoodBody =
            B.letExpr [ B.define "p" [] (B.callExpr (B.ctorExpr "MkPair") [ B.varExpr "a", B.varExpr "b" ]) ]
                (B.caseExpr (B.varExpr "p")
                    [ ( B.pCtor "MkPair" [ B.pVar "x", B.pVar "y" ]
                      , B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y")
                      )
                    ]
                )

        ctorBadBody =
            B.letExpr [ B.define "p" [] (B.callExpr (B.ctorExpr "MkPair") [ B.varExpr "a", B.varExpr "b" ]) ]
                (B.callExpr (B.varExpr "usePair") [ B.varExpr "p" ])

        ctorMultiBody =
            B.letExpr [ B.define "m" [] (B.callExpr (B.ctorExpr "Yes") [ B.varExpr "a" ]) ]
                (B.caseExpr (B.varExpr "m")
                    [ ( B.pCtor "Yes" [ B.pVar "x" ], B.varExpr "x" )
                    , ( B.pCtor "No" [ B.pVar "y" ], B.varExpr "y" )
                    ]
                )

        ctorCapBody =
            B.letExpr [ B.define "p" [] (B.callExpr (B.ctorExpr "MkPair") [ B.varExpr "a", B.varExpr "b" ]) ]
                (B.lambdaExpr [ B.pVar "n" ]
                    (B.binopsExpr [ ( B.callExpr (B.varExpr "usePair") [ B.varExpr "p" ], "+" ) ] (B.varExpr "n"))
                )

        pairTy =
            B.tType "Pair" []

        unions =
            [ { name = "Pair"
              , args = []
              , ctors = [ { name = "MkPair", args = [ intType, intType ] } ]
              }
            , { name = "MB"
              , args = []
              , ctors =
                    [ { name = "Yes", args = [ intType ] }
                    , { name = "No", args = [ intType ] }
                    ]
              }
            ]
    in
    B.makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "good"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = goodBody
          }
        , { name = "bad"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType tupleTy)
          , body = badBody
          }
        , { name = "passed"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = passedBody
          }
        , { name = "useTuple"
          , args = [ B.pVar "p" ]
          , tipe = B.tLambda tupleTy intType
          , body = useTupleBody
          }
        , { name = "caseGood"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = caseGoodBody
          }
        , { name = "caseNested"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = caseNestedBody
          }
        , { name = "caseAndPass"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = caseAndPassBody
          }
        , { name = "ctorGood"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = ctorGoodBody
          }
        , { name = "ctorBad"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = ctorBadBody
          }
        , { name = "usePair"
          , args = [ B.pVar "q" ]
          , tipe = B.tLambda pairTy intType
          , body =
                B.caseExpr (B.varExpr "q")
                    [ ( B.pCtor "MkPair" [ B.pVar "ux", B.pVar "uy" ]
                      , B.binopsExpr [ ( B.varExpr "ux", "+" ) ] (B.varExpr "uy")
                      )
                    ]
          }
        , { name = "ctorMulti"
          , args = [ B.pVar "a" ]
          , tipe = B.tLambda intType intType
          , body = ctorMultiBody
          }
        , { name = "ctorCap"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType (B.tLambda intType intType))
          , body = ctorCapBody
          }
        , { name = "testValue"
          , args = []
          , tipe = intType
          , body =
                B.binopsExpr
                    [ ( B.callExpr (B.varExpr "good") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "passed") [ B.intExpr 3, B.intExpr 4 ], "+" )
                    , ( B.callExpr (B.varExpr "caseGood") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "caseNested") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "caseAndPass") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "ctorGood") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "ctorMulti") [ B.intExpr 3 ], "+" )
                    , ( B.callExpr (B.varExpr "ctorBad") [ B.intExpr 4, B.intExpr 5 ], "+" )
                    , ( B.callExpr (B.callExpr (B.varExpr "ctorCap") [ B.intExpr 1, B.intExpr 2 ]) [ B.intExpr 3 ], "+" )
                    ]
                    (B.callExpr (B.varExpr "useTuple") [ B.callExpr (B.varExpr "bad") [ B.intExpr 5, B.intExpr 6 ] ])
          }
        ]
        unions
        []
