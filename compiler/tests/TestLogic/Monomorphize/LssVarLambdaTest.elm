module TestLogic.Monomorphize.LssVarLambdaTest exposing (suite)

{-| Checks that, when a lambda that returns a function is passed as an
argument, the solver engine resolves the lambda sets on that argument's
arrows. Without the first test, a change that left such a position
unresolved or unknown in this fixture's registry rows would go unnoticed.

A lambda-set annotation (`Mono.LambdaSetAnno`, owned by
`Compiler.AST.Monomorphized`) on an arrow says which function values can flow
through it: `LSet` exactly the listed members, `LPartial` at least them,
`LVar` not yet determined, `LTop` unknown. A registry row holds the type of
one specialization of a global; a lambda has no row of its own, so the set of
the function it returns is recorded with its closure node, in the type of its
body. The settle pass `settleVarLambda` of `Compiler.MonoSolver.Monomorphize`
copies such sets from closure nodes into `LVar` positions of registry rows. It
writes a position only when the merged evidence for it holds no `LTop` or
`LVar`, every member of the enclosing set has a recorded closure, and those
closures take as many parameters as the arrow at the use site; closures that
share a member but differ in parameter count make the member unusable.

The fixture is one module, written here as Elm source:

    mkAdder : Int -> Int -> Int
    mkAdder =
        \a -> \b -> a + b

    applyTwice : (x -> Int -> Int) -> x -> Int
    applyTwice f seed =
        f seed 2

    testValue : Int
    testValue =
        applyTwice mkAdder 5

Despite its name, `applyTwice` applies `f` once and applies the result to `2`;
its body is built as a call whose function is the call `f seed`.
The function its parameter `f` returns is `mkAdder`'s inner lambda, so the set
on that result arrow is found in the type of the outer lambda's body.

The tests establish:

  - Test 1 monomorphizes the fixture with the solver engine and takes, from
    every registry row named `applyTwice` whose first parameter is a function
    returning a function, the annotations on that parameter's arrow and on the
    arrow of the function it returns. It passes only when at least one was
    found and every one is an `LSet` with at least one member; an `LTop`,
    `LVar`, `LPartial` or empty `LSet` fails it.
  - Test 1b reads the same pairs and requires each to be two different
    singletons: on the parameter's arrow the member the graph's
    `lssMemberOrigins` records as `mkAdder`, and on the returned function's
    arrow the member of another closure in `mkAdder`'s body, its inner lambda.
    Both members must be closure members of `mkAdder`'s specialization.

Among what is not tested: the write conditions above as the compiler applies
them (the strict-cell rule of `varCellMerge` and the arity guard of
`lambdaHomesOf`, which the module does not expose and no fixture here
reaches), which stage wrote the sets, and the graph after global
optimization.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The two tests the module docstring lists.
-}
suite : Test
suite =
    Test.describe "lambda-home var writes"
        [ Test.test "1. the lambda's result arrow is a set, never var or ⊤" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        let
                            on =
                                annos onG
                        in
                        if List.isEmpty on then
                            Expect.fail "no applyTwice rows — fixture broken"

                        else if List.any isTop on then
                            Expect.fail ("on-arm manufactured ⊤: " ++ describe on)

                        else if List.any isVar on then
                            Expect.fail ("on-arm expected the var to be written, got " ++ describe on)

                        else if List.all isSet on then
                            Expect.pass

                        else
                            Expect.fail ("on-arm expected sets throughout, got " ++ describe on)

                    Err e ->
                        Expect.fail e
        , Test.test "1b. the sets name mkAdder and the lambda it returns" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        let
                            lambdaMembers =
                                closureMembersOf "mkAdder" onG

                            pairs =
                                annoPairs onG

                            names ( h, r ) =
                                case ( h, r ) of
                                    ( Mono.LSet [ outer ], Mono.LSet [ inner ] ) ->
                                        outer
                                            /= inner
                                            && isGlobalMember "mkAdder" outer onG
                                            && List.member outer lambdaMembers
                                            && List.member inner lambdaMembers

                                    _ ->
                                        False
                        in
                        if not (List.isEmpty pairs) && List.all names pairs then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected mkAdder's own singleton and its inner lambda's singleton, got "
                                    ++ String.join "; " (List.map (\( h, r ) -> describe [ h, r ]) pairs)
                                    ++ " with mkAdder's closure members "
                                    ++ String.join "," (List.map String.fromInt lambdaMembers)
                                )

                    Err e ->
                        Expect.fail e
        ]



-- ====== FIXTURE ======


{-| The source type `Int`, as the fixture's annotations write it.
-}
hInt : Src.Type
hInt =
    tType "Int" []


{-| The test program the module docstring shows: module `Test` with the
annotated definitions `mkAdder`, `applyTwice` and `testValue`, and no unions or
aliases.
-}
fixture : Src.Module
fixture =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkAdder"
          , args = []
          , tipe = tLambda hInt (tLambda hInt hInt)
          , body =
                lambdaExpr [ pVar "a" ]
                    (lambdaExpr [ pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")))
          }
        , { name = "applyTwice"
          , args = [ pVar "f", pVar "seed" ]
          , tipe = tLambda (tLambda (tVar "x") (tLambda hInt hInt)) (tLambda (tVar "x") hInt)
          , body = callExpr (callExpr (varExpr "f") [ varExpr "seed" ]) [ intExpr 2 ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body = callExpr (varExpr "applyTwice") [ varExpr "mkAdder", intExpr 5 ]
          }
        ]
        []
        []



-- ====== HARNESS ======


{-| Monomorphizes `srcModule` with the solver engine, under the default
specialization limits and the default lambda-set configuration, and returns
the graph without global optimization. Lambda-set specialization is already
enabled in that configuration, so setting `enabled` changes nothing.
-}
runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    let
        defaults =
            Config.defaultLss
    in
    -- NoPreMono (plans/staging-honesty-and-production-test-pipeline.md P1.4): this pins an LSS
    -- analysis rule on a hand-written shape that pre-mono alias forwarding / eta-expansion
    -- rewrite before the solver sees it.
    Pipeline.runSolverMonoWithLimitsNoPreMono Config.defaultLimits
        { defaults | enabled = True }
        srcModule



-- ====== READERS ======


{-| Returns the annotations `annoPairs` pairs up, flattened.
-}
annos : Mono.MonoGraph -> List Mono.LambdaSetAnno
annos g =
    List.concatMap (\( h, r ) -> [ h, r ]) (annoPairs g)


{-| Returns, for every registry row of `g` named `applyTwice`, in any module,
the annotation on the arrow of the row's first parameter, and the one on the
arrow of the function that parameter returns. A row whose first parameter is
not a function returning a function contributes nothing, so the list can be
empty.
-}
annoPairs : Mono.MonoGraph -> List ( Mono.LambdaSetAnno, Mono.LambdaSetAnno )
annoPairs (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "applyTwice" then
                        case monoType of
                            Mono.MFunction _ _ ((Mono.MFunction _ headA _ (Mono.MFunction _ resA _ _)) :: _) _ ->
                                ( headA, resA ) :: acc

                            _ ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns the member id of every closure, nested ones included, in the
bodies of the specializations of the global named `name`.
-}
closureMembersOf : String -> Mono.MonoGraph -> List Int
closureMembersOf name (Mono.MonoGraph g) =
    List.concatMap
        (\( specId, entry ) ->
            case ( entry, Array.get specId g.nodes ) of
                ( Just ( Mono.Global _ n, _ ), Just (Just (Mono.MonoDefine body _)) ) ->
                    if n == name then
                        MonoTraverse.foldExpr
                            (\e acc ->
                                case e of
                                    Mono.MonoClosure info _ _ ->
                                        case info.lssMember of
                                            Just m ->
                                                m :: acc

                                            Nothing ->
                                                acc

                                    _ ->
                                        acc
                            )
                            []
                            body

                    else
                        []

                _ ->
                    []
        )
        (Array.toIndexedList g.registry.reverseMapping)


{-| Reports whether the graph's `lssMemberOrigins` records member `m` as the
global named `name`.
-}
isGlobalMember : String -> Int -> Mono.MonoGraph -> Bool
isGlobalMember name m (Mono.MonoGraph g) =
    case Dict.get m g.lssMemberOrigins of
        Just (Mono.OriginGlobal (Mono.Global _ n)) ->
            n == name

        _ ->
            False


{-| Reports whether an annotation is `LTop`, whatever its provenance code.
-}
isTop : Mono.LambdaSetAnno -> Bool
isTop =
    Mono.isTopAnno


{-| Reports whether an annotation is `LVar`.
-}
isVar : Mono.LambdaSetAnno -> Bool
isVar a =
    case a of
        Mono.LVar _ ->
            True

        _ ->
            False


{-| Reports whether an annotation is an `LSet` with at least one member. An
empty `LSet` and an `LPartial` are not.
-}
isSet : Mono.LambdaSetAnno -> Bool
isSet a =
    case a of
        Mono.LSet (_ :: _) ->
            True

        _ ->
            False


{-| Renders annotations for a failure message: each `LTop` with its provenance
label, each `LVar` with its number, and each `LSet` and `LPartial` with its
member count, not its members.
-}
describe : List Mono.LambdaSetAnno -> String
describe xs =
    "["
        ++ String.join ", "
            (List.map
                (\a ->
                    case a of
                        Mono.LTop k ->
                            "LTop " ++ Mono.topKindLabel k

                        Mono.LVar n ->
                            "LVar " ++ String.fromInt n

                        Mono.LSet ms ->
                            "LSet " ++ String.fromInt (List.length ms)

                        Mono.LPartial ms ->
                            "LPartial " ++ String.fromInt (List.length ms)
                )
                xs
            )
        ++ "]"
