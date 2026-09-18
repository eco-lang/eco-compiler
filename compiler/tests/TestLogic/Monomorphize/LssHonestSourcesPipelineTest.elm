module TestLogic.Monomorphize.LssHonestSourcesPipelineTest exposing (suite)

{-| LSS\_026(a) — honest ∅-as-source, PIPELINE level.

The store-level semantics of the rule — including the pre-rule reading, which
is the RED half — live in `LssHonestSourcesTest`, which drives
`Store.resolveSlotMembers` directly with `honestSources` toggled. This file
is the other end: it runs whole modules through the monomorphizer and asserts
on the annotations of the stored (keyed) demand types in the registry
(`LssSigFlowTest`'s precedent), so the rule is pinned where a real program
meets it.

**The shape being pinned** (plan §0.5). `pickG c f = if c then f else incr`
has an honestly MIXED result fact — members `{g|incr}` plus a promoted source
for its own `f` param. `d f = pickG True f` returns the CALLER's function at
runtime, but inside `d` the argument `f` never connects to that param's
instantiation slot (the A.1 arg-position leak), so the slot dangles as an
unconstrained FlexVar. Reading that dangling inflow as an ∅ contribution
makes `d`'s result read `LSet [g|incr]` — a COMPLETENESS claim that is false.

It is not a hypothetical: LSS\_025's post-settle devirt acts on such a
singleton, and `test/elm/src/LssMixedSigHonestyTest.elm` printed
`[42, 42, 42]` for `[41, 42, 82]` at the shipping default before the rule
went unconditional. That is why LSS\_026(a) is **not** behind a flag, and why
these tests take no flag argument.

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


suite : Test
suite =
    Test.describe "LSS_026(a) honest ∅-as-source (pipeline level)"
        [ Test.test "1. the `g|` variant: `d`'s result is never the false singleton" <|
            \() ->
                -- A standalone-global member GROUNDS at the consuming zonk
                -- (LSS_019) and IS consumable by the devirts, so a false
                -- `{g|incr}` here is the representative-hijack MISCOMPILE
                -- class — the one the runtime fixture caught.
                --
                -- UNTIL 2026-08-25 this asserted ⊤, because the A.1 leak left
                -- `d`'s `f` dangling and ⊤ was the honest reading of a fact
                -- mixed with an UNCONSTRAINED source. `lss.arrowIdentity` going
                -- default-on (plans/lss-paper-inclusion-constraints.md §5.A3)
                -- CLOSED that leak — the arg now shares the param's slot — so
                -- the source is no longer unconstrained and the fixture no
                -- longer produces a mixed-with-flex fact at all.
                --
                -- What is asserted is therefore the property that actually
                -- guards the miscompile, and it holds in both readings: the
                -- result is ⊤, or a set with AT LEAST TWO members. LSS_025's
                -- post-settle devirt acts on a SINGLETON; `{g|incr}` alone is
                -- the false completeness claim. For this closed fixture the
                -- complete inhabitant set is {incr, the caller's lambda} — two
                -- members — so a singleton here is still exactly the bug.
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
                -- The plan's literal §0.5 text uses a lambda in the else
                -- branch. A raw `l|` member merely DECLINES at AbiCloning
                -- (LSS_017), so this variant is imprecision rather than
                -- miscompile — but the resolver rule is the same one and
                -- must not depend on the member's class.
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
                -- `topMixedFlex=<sig>/<demand>`. The counter is what let
                -- Phase 0 size the exposure across a whole self-compile; a
                -- silent widening would be untrackable.
                --
                -- It read `1/0` while the A.1 leak dangled `d`'s `f`. With
                -- `lss.arrowIdentity` default-on the slot is shared, nothing is
                -- mixed with an unconstrained source here, and the honest count
                -- is `0/0`. THE COUNTER ITSELF IS STILL COVERED: the RULE is
                -- pinned at store level by `LssHonestSourcesTest`, which drives
                -- `Store.resolveSlotMembers` directly with `honestSources`
                -- toggled and does not depend on a pipeline fixture reaching
                -- the crossing. What this test still guards is that the line is
                -- EMITTED and parses — a dropped counter would read the same as
                -- a zero one otherwise.
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
                -- `mk2 s = if s then λ else λ` carries members and NO
                -- sources, so `sawFlex` is False and the fact must survive
                -- verbatim. This is what separates "widen the mixed case"
                -- from "widen everything" — without it, a rule that returned
                -- ⊤ unconditionally would pass tests 1 and 2.
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
                -- ⊤ is the fallback, never `LSet []` — an empty set claims
                -- the position has NO inhabitants, the one reading that is
                -- always wrong. Checked over every annotation of every
                -- fixture.
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


{-| `sigFlow` ON (without it there are no sources to be honest about);
`layoutQualMembers` pinned OFF for the same reason `LssSigFlowTest` pins it
off — these fixtures pin LSS\_026(a) in isolation from LSS\_024's id sharing.
-}
run : Src.Module -> Result String Mono.MonoGraph
run srcModule =
    Pipeline.runSolverMonoWithLimits Config.defaultLimits lssConfig srcModule


runReport : Src.Module -> Result String ( Mono.MonoGraph, String )
runReport srcModule =
    Pipeline.runSolverMonoWithReport Config.defaultLimits lssConfig srcModule
        |> Result.andThen
            (\( graph, maybeReport ) ->
                case maybeReport of
                    Just report ->
                        Ok ( graph, report )

                    Nothing ->
                        Err "no LSS report rendered"
            )


lssConfig : Config.LssConfig
lssConfig =
    let
        defaults =
            Config.defaultLss
    in
    { defaults | enabled = True, keyed = True, sigFlow = True, layoutQualMembers = False }


reportLine : String -> String -> String
reportLine prefix report =
    String.lines report
        |> List.filter (String.startsWith prefix)
        |> List.head
        |> Maybe.withDefault ("<no line starting with " ++ prefix ++ ">")


lastWord : String -> String
lastWord line =
    String.words line |> List.reverse |> List.head |> Maybe.withDefault ""


{-| Every stored (keyed) demand type for the named global (MuTieTest /
LssSigFlowTest precedent).
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


{-| The RESULT arrow's annotation for each stored demand: the deepest
`MFunction` on the return spine.
-}
resultAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
resultAnnos target graph =
    List.filterMap deepestRetAnno (demandsOf target graph)


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


allAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
allAnnos target graph =
    List.concatMap annosOf (demandsOf target graph)


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


{-| The guard LSS\_026(a) actually exists for: never a set small enough for a
consumer to devirtualize on. ⊤ is fine (it claims nothing); a >=2 set is fine
(no devirt arm takes it); a SINGLETON or an empty set is the false completeness
claim that hijacks the representative.
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


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| §0.5, `gc`-member variant — the miscompile class.
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


{-| The plan's literal §0.5 text: a LAMBDA in the else branch.
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


{-| Negative control (LssSigFlowTest test 2's fixture): members, no sources,
so nothing is mixed and the rule must be silent.
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
