module TestLogic.Monomorphize.LssPapMembersTest exposing (suite)

{-| INJECTION COMPLETENESS — `lss.papMembers`
(`plans/lss-injection-completeness.md`).

**What is being pinned, and why it is a soundness test rather than a precision
one.** A PARTIAL application of a known global is a PAP of that global, so the
callee's member is sound on the residual arrows (LSS\_013's arity bound: "a PAP
of member m is m"). Before this flag it was the ONE producer form that injected
nothing — P0's injection-totality census measured 3,624 such positions on the
self-compile — and that hole is what let a one-sided branch join publish a
FALSE COMPLETE set.

The recorded consequence is not hypothetical: with `arrowSolverRoots` sharing
the slots, `\flg -> if flg then (::) x else identity` published `{identity}` as
complete, devirt believed it, and `Task.map f` compiled to `\a -> succeed a` —
the identity map. `Build.findModulePaths` then scanned every source directory
to `[]` and the compiler could not find its own source files.

The paper has no such hole and needs no widening to avoid it: L^src is
curry-free, so `(::) x` is necessarily a λ there and `𝒬` injects EVERY λ
(Fig. 6). Injecting here restores that property.

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
    Test.describe "injection completeness for partial applications"
        [ Test.test "1. THE CRASH SHAPE: a one-sided join is never a false singleton" <|
            \() ->
                -- `if flg then addTo 7 else idf`, passed as an ARGUMENT — the
                -- minimal form of the `arrowSolverRoots` miscompile. The
                -- `else` arm's bare reference injects; the `then` arm is a
                -- PARTIAL application, which injected NOTHING before this
                -- flag, so the join claimed the position had exactly ONE
                -- inhabitant when it has two.
                --
                -- Asserted at the CONSUMER's parameter, which is where the
                -- real bug lived (map's `f`) and where the arg's type is
                -- store-tracked. A def's own result arrow is not the right
                -- place to look: the storeless classifier stamps ⊤ there by
                -- construction, which is what the first version of this test
                -- got wrong.
                case runWith joinModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        case allAnnos "useIt" graph of
                            [] ->
                                Expect.fail "no demand recorded for `useIt` — fixture broken"

                            annos ->
                                if List.all neverFalselyComplete annos then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("a one-sided join must not publish a singleton, got: "
                                            ++ describeAnnos annos
                                        )
        , Test.test "2. the partial's member is PRESENT, not merely widened away" <|
            \() ->
                -- Test 1 also passes if the position widens to ⊤ — which is
                -- the GUARD-shaped repair (R2 in the solver-root plan), not
                -- the paper-shaped one this plan implements. Injection is the
                -- claim, so assert the strictly stronger property: the
                -- consumer's parameter NAMES a member. "Always widen" fails
                -- here, which is the point of having both tests.
                case runWith loneModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        if List.any (annoAtLeast 1) (allAnnos "useIt" graph) then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected the injected PAP member at the consumer's param, got: "
                                    ++ describeAnnos (allAnnos "useIt" graph)
                                )
        , Test.test "4. the PAP member is NOT the callee's own `g|` identity" <|
            \() ->
                -- The correction that made the first implementation a
                -- miscompile. Reusing `g|addTo` would put the member in the
                -- STAMPABLE class, and devirt would rewrite the call site to a
                -- direct call of `addTo`'s 2-arity spec with ONE argument —
                -- exactly the `demandUnify` arity abort observed on the first
                -- flag-on self-compile.
                --
                -- Pinned behaviourally rather than by member id: the whole
                -- fixture must still monomorphize. A `g|` member here aborts
                -- the pipeline, so a green run IS the assertion, and test 2
                -- separately proves a member was injected at all.
                case runWith papDevirtModule of
                    Err msg ->
                        Expect.fail ("PAP member licensed a bad devirt: " ++ msg)

                    Ok _ ->
                        Expect.pass
        , Test.test "5. LSS_001: injection never manufactures an EMPTY set" <|
            \() ->
                let
                    everyAnno =
                        List.concatMap
                            (\m ->
                                case runWith m of
                                    Ok g ->
                                        List.concatMap annosOf (allDemands g)

                                    Err _ ->
                                        []
                            )
                            [ joinModule, loneModule, papDevirtModule ]
                in
                if List.any ((==) (Mono.LSet [])) everyAnno then
                    Expect.fail "an empty LSet reached a demand annotation"

                else
                    Expect.pass
        ]



-- ====== HARNESS ======


{-| `lss.papMembers` was fixed at its default and removed 2026-09-18, and so
was `regIdentity`, which this harness pinned OFF under the
differential-overlap rule. The deleted test 3 pinned that the injection is
gated at the MINT (flag-off produced observably different annotations, member
allocation order being artifact-relevant). Solo census with `papMembers` OFF:
`var` +3,803, artifact −61 KB.

`sigRootIdentity` used to move WITH `papMembers` here, never independently:
root identity WITHOUT injection completeness is the pairing that published the
false singleton and compiled `Task.map` into the identity map. That flag was
deleted 2026-09-17 (plans/remove-default-off-lss-flags.md).
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



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| THE CRASH SHAPE. `addTo` is a two-parameter global, so `addTo 7` is a
PARTIAL application (1 of 2 supplied) whose residual is `Int -> Int`; `idf` is
a bare reference, which injects today. The `if` is passed straight into
`useIt`'s parameter — an argument position, where the type is store-tracked —
so the branch join lands exactly where the real bug lived (map's `f`).

Before `papMembers` only the `else` arm injected, so the parameter's set was
the FALSE SINGLETON `{g|idf}`.

-}
joinModule : Src.Module
joinModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "addTo"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "idf"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = varExpr "x"
          }
        , { name = "useIt"
          , args = [ pVar "f" ]
          , tipe = tLambda hInt (tType "Int" [])
          , body = callExpr (varExpr "f") [ intExpr 1 ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr (varExpr "useIt")
                    [ ifExpr (boolExpr True) (callExpr (varExpr "addTo") [ intExpr 7 ]) (varExpr "idf") ]
          }
        ]


{-| A partial application as the SOLE inhabitant of a consumer's parameter:
the direct test that a member is injected at all.
-}
loneModule : Src.Module
loneModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "addTo"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "useIt"
          , args = [ pVar "f" ]
          , tipe = tLambda hInt (tType "Int" [])
          , body = callExpr (varExpr "f") [ intExpr 1 ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (varExpr "useIt") [ callExpr (varExpr "addTo") [ intExpr 7 ] ]
          }
        ]


{-| The identity guard, in the shape that actually aborted the first flag-on
self-compile: a partial application passed to a HIGHER-ORDER consumer that
calls it, so a singleton set at the consumer's parameter is live for devirt.
With the callee's `g|` identity, devirt rewrites `f 1` to a direct call of
`addTo`'s 2-arity spec with one argument and monomorphization dies on
`demandUnify`. With the PAP's own `p|` identity it declines, and the pipeline
completes — so a GREEN run is the assertion.
-}
papDevirtModule : Src.Module
papDevirtModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "addTo"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "applyTwice"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt (tLambda (tType "Int" []) (tType "Int" []))
          , body = callExpr (varExpr "f") [ callExpr (varExpr "f") [ varExpr "n" ] ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (varExpr "applyTwice") [ callExpr (varExpr "addTo") [ intExpr 7 ], intExpr 1 ]
          }
        ]



-- ====== READERS (LssHonestSourcesPipelineTest precedent) ======


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


{-| Every annotation of the named global's demands BELOW the demand type's own
head. The head carries the registration stamp's tautological self-identity —
an HONEST singleton — so scanning it would trip the false-completeness pin on
correct behaviour. That used to be handled by pinning `regIdentity = False`;
the flag was fixed at its default and removed 2026-09-18, so the reader is
narrowed instead. The false-completeness class this file pins lives at the
CONSUMER's parameter, which is below the head by construction.
-}
allAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
allAnnos target graph =
    List.concatMap belowHead (demandsOf target graph)


belowHead : Mono.MonoType -> List Mono.LambdaSetAnno
belowHead t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.concatMap annosOf args ++ annosOf ret

        _ ->
            annosOf t


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


{-| ⊤ and `LVar` claim nothing; a >=2 set is not devirtable. A SINGLETON or an
empty set is the false-completeness claim that hijacks the representative.
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

        Mono.LSet ms ->
            List.length ms >= 2


annoAtLeast : Int -> Mono.LambdaSetAnno -> Bool
annoAtLeast n anno =
    case anno of
        Mono.LSet ms ->
            List.length ms >= n

        _ ->
            False


describeAnnos : List Mono.LambdaSetAnno -> String
describeAnnos annos =
    "[" ++ String.join ", " (List.map describeAnno annos) ++ "]"


describeAnno : Mono.LambdaSetAnno -> String
describeAnno anno =
    case anno of
        Mono.LTop _ ->
            "LTop"

        Mono.LVar n ->
            "LVar " ++ String.fromInt n

        Mono.LSet ms ->
            "LSet " ++ String.fromInt (List.length ms)

        Mono.LPartial ms ->
            "LPartial " ++ String.fromInt (List.length ms) ++ String.concat (List.map (\m -> " " ++ String.fromInt m) ms)
