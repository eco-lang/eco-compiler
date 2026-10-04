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
  - Test 2 merges two records built in the test, a cell with a set and a cell
    marked `var`, by or-ing their `top` and `var` flags and keeping the first
    cell's members, and checks that the result has `var` set, `top` clear and
    those members. No compiler code runs: it repeats by hand the flag merge
    `varCellMerge` performs, without calling it.
  - Test 3 checks a merge function defined in the test, which keeps two equal
    parameter counts and gives `Nothing` otherwise, on three pairs. No
    compiler code runs.

Among what is not tested: any of the write conditions above as the compiler
applies them, which members the sets of test 1 hold, which stage wrote them,
and the graph after global optimization.

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
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The three tests the module docstring lists.
-}
suite : Test
suite =
    Test.describe "lambda-home var writes"
        [ -- The only test that runs the compiler.
          Test.test "1. the lambda's result arrow is a set, never var or ⊤" <|
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
        , Test.test "2. GUARD: a var cell never becomes a set (strict-cell rule)" <|
            \() ->
                let
                    setCell =
                        { top = False, var = False, sets = Just [ 7 ] }

                    varCell =
                        { top = False, var = True, sets = Nothing }

                    merged =
                        { top = setCell.top || varCell.top
                        , var = setCell.var || varCell.var
                        , sets = setCell.sets
                        }
                in
                Expect.equal ( merged.var, merged.top, merged.sets ) ( True, False, Just [ 7 ] )
        , Test.test "3. GUARD: arity disagreement makes a mid unusable" <|
            \() ->
                let
                    merge a b =
                        if a == b then
                            a

                        else
                            Nothing
                in
                Expect.equal
                    [ merge (Just 1) (Just 1), merge (Just 1) (Just 2), merge Nothing (Just 1) ]
                    [ Just 1, Nothing, Nothing ]
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
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True }
        srcModule



-- ====== READERS ======


{-| Returns two annotations for every registry row of `g` named `applyTwice`,
in any module: the one on the arrow of the row's first parameter, and the one
on the arrow of the function that parameter returns. A row whose first
parameter is not a function returning a function contributes nothing, so the
list can be empty.
-}
annos : Mono.MonoGraph -> List Mono.LambdaSetAnno
annos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "applyTwice" then
                        case monoType of
                            Mono.MFunction _ _ ((Mono.MFunction _ headA _ (Mono.MFunction _ resA _ _)) :: _) _ ->
                                headA :: resA :: acc

                            _ ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


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
