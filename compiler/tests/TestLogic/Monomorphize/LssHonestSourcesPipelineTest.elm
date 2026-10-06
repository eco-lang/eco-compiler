module TestLogic.Monomorphize.LssHonestSourcesPipelineTest exposing (suite)

{-| A function such as `pickG c f = if c then f else incr` can return either
its argument or the global `incr`. If the monomorphizer annotated the result of
a caller of `pickG` with the set `{incr}` alone, it would be claiming that
`incr` is the only function that can arrive there, and a call through that
result could be turned into a direct call to `incr`. These tests run whole
modules through the solver engine and check that no one-member set is claimed
at such a caller's result.

With lambda-set specialization (LSS) on, every arrow in a `MonoType` carries a
lambda-set annotation naming the function values, its _members_, that can flow
through it. `LSet` claims exactly the listed members, `LPartial` at least those,
and `LVar` and `LTop` (⊤) name none. A one-member `LSet` whose member is a
global can be _devirtualized_: a call through it becomes a direct call to that
global.

The rule these tests concern is the honest-sources rule of
`Compiler.MonoSolver.Store`. A lambda-set slot may draw on other slots, its
_sources_, and resolving it collects its own members and those of every slot
reachable through them. A resolution that collects members and also passes
through a source slot nothing has written is widened to ⊤ instead of being read
as a complete set. Such a resolution is a _mixed crossing_. The LSS report's
`honestSources:` line ends with the word
`topMixedFlex=<signature side>/<demand side>`. The demand-side number counts
the mixed crossings Store meets, and only while the report is on, as
`runReport` arranges. The signature-side number counts a separate widening,
made by `Compiler.MonoSolver.LssInfer` on some signature facts that cross an
unwritten source.

The tests read annotations off _stored demand types_: the `MonoType` recorded in
the registry's `reverseMapping` for each specialization.

The fixtures are three modules, each run with `Config.defaultLimits` and
`Config.defaultLss`, with the report switched on for test 3:

  - `mixedSigModule` defines `incr x = x + 1`,
    `pickG c f = if c then f else incr`, `d f = pickG True f`, and a
    `testValue` that calls `d` with `\y -> y + 2`.
    `{incr}` alone at `d`'s result would be false: `d` passes `True`, so at
    run time it returns the function it is given.
  - `mixedLambdaModule` is the same with `pickL` and `dl`, and with the lambda
    `\x -> x + 1` in place of `incr`.
  - `mk2Module` defines `mk2 s = if s then (\x -> x + 1) else (\y -> y + 2)`,
    whose result can be either of two lambdas and which takes no function
    argument for a source to come from.

Test 3 expects no mixed crossing in either mixed fixture, so these fixtures do
not exercise the widening itself. Tests 1 and 2 check the property the rule
protects, whichever way the solver reaches it. The rule is tested directly, on a
hand-built store, in `TestLogic.Monomorphize.LssHonestSourcesTest`.

What the tests establish:

  - 1: at least one stored demand type of `d` is a function type, and in each
    one the annotation on the innermost arrow of its return spine is `LTop`,
    `LVar`, `LPartial`, or an `LSet` of two or more members.
  - 2: the same for `dl`, whose known member is a source lambda rather than a
    global.
  - 3: for both mixed fixtures a report is rendered, and its first line starting
    `honestSources:` ends with the word `topMixedFlex=0/0`.
  - 4: some annotation in some stored demand type of `mk2` is an `LSet` of
    exactly two members, so a rule that widened every set to ⊤ would fail here.
  - 5: no annotation in any stored demand type of any of the three fixtures is
    `LSet []`. A fixture whose pipeline fails contributes no annotations to this
    check.

Among what is not tested: a pipeline run in which a mixed crossing occurs and is
widened; annotations of `d` and `dl` other than the one on the innermost
result arrow, beyond test 5's check that none is an empty set; and the
generated code.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The five tests, in the order the module docstring lists them.
-}
suite : Test
suite =
    Test.describe "LSS_026(a) honest ∅-as-source (pipeline level)"
        [ Test.test "1. the `g|` variant: `d`'s result is never the false singleton" <|
            \() ->
                case run mixedSigModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        case resultAnnos "d" graph of
                            [] ->
                                Expect.fail "no demand recorded for `d` — fixture broken"

                            annos ->
                                if List.all neverFalselyComplete annos then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("a mixed fact must be ⊤ or a >=2 set, got: " ++ describeAnnos annos)
        , Test.test "2. the `l|` variant behaves identically — the rule is not class-sensitive" <|
            \() ->
                case run mixedLambdaModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        case resultAnnos "dl" graph of
                            [] ->
                                Expect.fail "no demand recorded for `dl` — fixture broken"

                            annos ->
                                if List.all neverFalselyComplete annos then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("a mixed fact must be ⊤ or a >=2 set, got: " ++ describeAnnos annos)
        , Test.test "3. the crossing counter is PRESENT and reads what these fixtures now produce" <|
            \() ->
                case ( runReport mixedSigModule, runReport mixedLambdaModule ) of
                    ( Ok ( _, r1 ), Ok ( _, r2 ) ) ->
                        Expect.equal ( "topMixedFlex=0/0", "topMixedFlex=0/0" )
                            ( lastWord (reportLine "honestSources:" r1)
                            , lastWord (reportLine "honestSources:" r2)
                            )

                    ( Err msg, _ ) ->
                        Expect.fail msg

                    ( _, Err msg ) ->
                        Expect.fail msg
        , Test.test "4. negative control: an UNMIXED signature is untouched by the rule" <|
            \() ->
                case run mk2Module of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        if List.any (annoHasSize 2) (allAnnos "mk2" graph) then
                            Expect.pass

                        else
                            Expect.fail
                                ("mk2's honest 2-set must survive, got: "
                                    ++ describeAnnos (allAnnos "mk2" graph)
                                )
        , Test.test "5. LSS_001: the rule never manufactures an EMPTY set" <|
            \() ->
                let
                    everyAnno =
                        List.concatMap
                            (\m ->
                                case run m of
                                    Ok g ->
                                        List.concatMap annosOf (allDemands g)

                                    Err _ ->
                                        []
                            )
                            [ mixedSigModule, mixedLambdaModule, mk2Module ]
                in
                if List.any ((==) (Mono.LSet [])) everyAnno then
                    Expect.fail "an empty LSet reached a demand annotation"

                else
                    Expect.pass
        ]



-- ====== HARNESS ======


{-| Runs `srcModule` through the solver engine with LSS on and the default
spec limits, returning the monomorphized graph or the pipeline's error message.
-}
run : Src.Module -> Result String Mono.MonoGraph
run srcModule =
    -- NoPreMono (plans/staging-honesty-and-production-test-pipeline.md P1.4): this pins an LSS
    -- analysis rule on a hand-written shape that pre-mono alias forwarding / eta-expansion
    -- rewrite before the solver sees it.
    Pipeline.runSolverMonoWithLimitsNoPreMono Config.defaultLimits lssConfig srcModule


{-| Runs `srcModule` as `run` does with the LSS report switched on, and
returns the graph together with the rendered report. Gives an `Err` when no
report is rendered.
-}
runReport : Src.Module -> Result String ( Mono.MonoGraph, String )
runReport srcModule =
    -- NoPreMono (plans/staging-honesty-and-production-test-pipeline.md P1.4): this pins an LSS
    -- analysis rule on a hand-written shape that pre-mono alias forwarding / eta-expansion
    -- rewrite before the solver sees it.
    Pipeline.runSolverMonoWithReportNoPreMono Config.defaultLimits lssConfig srcModule
        |> Result.andThen
            (\( graph, maybeReport ) ->
                case maybeReport of
                    Just report ->
                        Ok ( graph, report )

                    Nothing ->
                        Err "no LSS report rendered"
            )


{-| The LSS settings these tests run with: `Config.defaultLss` with `enabled`
set, which it already is.
-}
lssConfig : Config.LssConfig
lssConfig =
    let
        defaults =
            Config.defaultLss
    in
    { defaults | enabled = True }


{-| Returns the first line of `report` that starts with `prefix`, or the text
`<no line starting with PREFIX>` when there is none.
-}
reportLine : String -> String -> String
reportLine prefix report =
    String.lines report
        |> List.filter (String.startsWith prefix)
        |> List.head
        |> Maybe.withDefault ("<no line starting with " ++ prefix ++ ">")


{-| Returns the last whitespace-separated word of `line`, or the empty string
when it has none.
-}
lastWord : String -> String
lastWord line =
    String.words line |> List.reverse |> List.head |> Maybe.withDefault ""


{-| Returns every stored demand type in the registry of a global named
`target`, from any module. Accessors are skipped.
-}
demandsOf : String -> Mono.MonoGraph -> List Mono.MonoType
demandsOf target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == target then
                        monoType :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns every stored demand type in the registry, for every global and
accessor.
-}
allDemands : Mono.MonoGraph -> List Mono.MonoType
allDemands (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( _, monoType ) ->
                    monoType :: acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns, for each stored demand type of `target` that is a function type,
the annotation on the innermost arrow of its return spine.
-}
resultAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
resultAnnos target graph =
    List.filterMap deepestRetAnno (demandsOf target graph)


{-| Returns the annotation of the innermost arrow reached by following result
types from `t`, or `Nothing` when `t` is not a function type.
-}
deepestRetAnno : Mono.MonoType -> Maybe Mono.LambdaSetAnno
deepestRetAnno t =
    case t of
        Mono.MFunction _ anno _ ret ->
            case deepestRetAnno ret of
                Just deeper ->
                    Just deeper

                Nothing ->
                    Just anno

        _ ->
            Nothing


{-| Returns every lambda-set annotation in every stored demand type of
`target`.
-}
allAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
allAnnos target graph =
    List.concatMap annosOf (demandsOf target graph)


{-| Returns every lambda-set annotation in `t` at any depth: on its arrows,
and inside list elements, tuple elements, record fields and custom-type
arguments. Other types have none.
-}
annosOf : Mono.MonoType -> List Mono.LambdaSetAnno
annosOf t =
    case t of
        Mono.MFunction _ anno args ret ->
            anno :: (List.concatMap annosOf args ++ annosOf ret)

        Mono.MList _ el ->
            annosOf el

        Mono.MTuple _ els ->
            List.concatMap annosOf els

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft acc -> acc ++ annosOf ft) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap annosOf args

        _ ->
            []


{-| Tells whether `anno` claims too little to be read as one complete call
target. `LTop`, `LVar` and `LPartial` pass, and an `LSet` passes only with two
or more members, so a one-member set fails and so does an empty one.
-}
neverFalselyComplete : Mono.LambdaSetAnno -> Bool
neverFalselyComplete anno =
    case anno of
        Mono.LTop _ ->
            True

        Mono.LVar _ ->
            True

        Mono.LPartial _ ->
            True

        Mono.LSet members ->
            List.length members >= 2


{-| Tells whether `anno` is an `LSet` of exactly `n` members.
-}
annoHasSize : Int -> Mono.LambdaSetAnno -> Bool
annoHasSize n anno =
    case anno of
        Mono.LSet members ->
            List.length members == n

        Mono.LTop _ ->
            False

        Mono.LVar _ ->
            False

        Mono.LPartial _ ->
            False


{-| Renders `annos` for a failure message, separated by commas, each as its
constructor name with its number or member ids. An `LTop` is shown without its
provenance code.
-}
describeAnnos : List Mono.LambdaSetAnno -> String
describeAnnos annos =
    String.join ", "
        (List.map
            (\anno ->
                case anno of
                    Mono.LTop _ ->
                        "LTop"

                    Mono.LVar n ->
                        "LVar" ++ String.fromInt n

                    Mono.LSet ms ->
                        "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"

                    Mono.LPartial ms ->
                        "LPartial[" ++ String.join "," (List.map String.fromInt ms) ++ "]"
            )
            annos
        )



-- ====== FIXTURES ======


{-| The source type `Int -> Int`, used for the function values in the
fixtures.
-}
hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| A module in which `d f = pickG True f` returns, through
`pickG c f = if c then f else incr`, either its argument or the global `incr`,
and whose `testValue` calls `d` with a lambda.
-}
mixedSigModule : Src.Module
mixedSigModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "incr"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "pickG"
          , args = [ pVar "c", pVar "f" ]
          , tipe = tLambda (tType "Bool" []) (tLambda hInt hInt)
          , body = ifExpr (varExpr "c") (varExpr "f") (varExpr "incr")
          }
        , { name = "d"
          , args = [ pVar "f" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "pickG") [ boolExpr True, varExpr "f" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "d")
                        [ lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2)) ]
                    )
                    [ intExpr 7 ]
          }
        ]


{-| A module in which `dl f = pickL True f` returns, through `pickL`, either
its argument or a lambda written in `pickL`'s else branch, and whose
`testValue` calls `dl` with another lambda.
-}
mixedLambdaModule : Src.Module
mixedLambdaModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "pickL"
          , args = [ pVar "c", pVar "f" ]
          , tipe = tLambda (tType "Bool" []) (tLambda hInt hInt)
          , body =
                ifExpr (varExpr "c")
                    (varExpr "f")
                    (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)))
          }
        , { name = "dl"
          , args = [ pVar "f" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "pickL") [ boolExpr True, varExpr "f" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "dl")
                        [ lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2)) ]
                    )
                    [ intExpr 7 ]
          }
        ]


{-| A module whose `mk2` returns one of two lambdas, chosen by its `Bool`
argument, and which takes no function argument for a source to come from.
-}
mk2Module : Src.Module
mk2Module =
    makeModuleWithTypedDefs "Test"
        [ { name = "mk2"
          , args = [ pVar "s" ]
          , tipe = tLambda (tType "Bool" []) hInt
          , body =
                ifExpr (varExpr "s")
                    (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)))
                    (lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2)))
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (callExpr (varExpr "mk2") [ boolExpr True ]) [ intExpr 4 ]
          }
        ]
