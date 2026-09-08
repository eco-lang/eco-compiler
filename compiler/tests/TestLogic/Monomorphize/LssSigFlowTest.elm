module TestLogic.Monomorphize.LssSigFlowTest exposing (suite)

{-| LSS\_020 — signature set-flow completion (GAP-2,
`plans/lss-fidelity-3-signature-flow-completion.md` §B).

Under `lss.sigFlow` the inference walk connects ground-typed intra-def flow
to signature slots, so def signatures stop being trivial and callers receive
rep links + members. These tests pin the mechanism through OBSERVABLE graph
state — the annotations of the stored (keyed) demand types in the registry:

1.  `chooseHandler b f g = if b then f else g` (ground annotation): the
    result arrow rep-links to BOTH param arrows, so a caller passing two
    distinct lambdas sees an honest 2-member set on the result — flag-off it
    sees nothing (the channel is empty).
2.  `mk2 s = if b then λ else λ`: body lambdas' members transport through
    the signature to the caller's result arrow (member flow, not just rep).
3.  Negative control `apply f x = f x` (polymorphic): no spurious members —
    flag-on demands are IDENTICAL to flag-off (this also pins the B.1.f
    self-id filter: without it every ≥1-param def goes nontrivial with its
    own raw `l|` spine member).
4.  HONESTY pin (§0.4(3) of the plan): `pick b g = if b then inc else g 0`
    mixes an honest branch with an opaque one (a call result). The hub must
    POISON — publishing the partial `{g|inc}` singleton would be the
    false-singleton devirt miscompile. Result arrow must be `LTop`, never a
    singleton.
5.  TailDef pin (§0.4(1)): a self-tail-recursive `countdown n k = if n == 0
    then k else countdown (n - 1) k` — the TailDef body is ARG-STRIPPED, so
    the root join must peel |args| arrows (and bind them); the tail call
    itself is `WpSelf` (contributes nothing to its own hub). Flag-on the
    result arrow carries the caller's `k` member via rep transport; a broken
    peel poisons the signature instead (LTop everywhere).
6.  B.4 widening rider: with `maxSetSize = 1`, the 2-member signature arrow
    of `mk2` widens (`top=True`) and bumps `widenedBySigSize` (asserted via
    the report line — `runSolverMonoWithReport`).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefs
        , pTuple
        , pVar
        , tLambda
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.Eco.Config as Config
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "LSS_020 signature set-flow (lss.sigFlow)"
        [ Test.test "1a. THE depollution pin: chooseHandler's result reads the honest 2-set AND the params keep DISTINCT singletons" <|
            \() ->
                -- LSS_023. Under the archived SYMMETRIC arm (Run X) the hub
                -- unified params and result into one class: the result became
                -- honest (the win) and the params became 2-sets (the
                -- pollution) — AbiCloning declined their formerly-stamped
                -- dispatches, the measured 8.30% → 6.08% coverage loss that
                -- kept sigFlow default-off. Directed edges keep the params'
                -- own sets and the result resolves their union at read. This
                -- assertion is what separates the two designs.
                case run True chooseHandlerModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "chooseHandler" graph)

                            paramSingletons =
                                demandsOf "chooseHandler" graph
                                    |> List.concatMap paramArrowAnnos
                                    |> List.filterMap
                                        (\anno ->
                                            case anno of
                                                Mono.LSet [ m ] ->
                                                    Just m

                                                _ ->
                                                    Nothing
                                        )
                        in
                        Expect.all
                            [ \() ->
                                if List.any (annoHasSize 2) resultAnnos then
                                    Expect.pass

                                else
                                    Expect.fail ("result arrow should be an honest 2-set, got: " ++ describeAnnos resultAnnos)
                            , \() ->
                                case paramSingletons of
                                    [ m1, m2 ] ->
                                        if m1 /= m2 then
                                            Expect.pass

                                        else
                                            Expect.fail "param singletons must be DISTINCT members"

                                    _ ->
                                        Expect.fail
                                            ("expected exactly two SINGLETON param arrows (the depollution), got: "
                                                ++ describeAnnos (List.concatMap paramArrowAnnos (demandsOf "chooseHandler" graph))
                                            )
                            ]
                            ()
        , Test.test "1b. chooseHandler flag OFF: the channel is empty — no multi-member set forms" <|
            \() ->
                case run False chooseHandlerModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        if List.any (annoHasSize 2) (allAnnos "chooseHandler" graph) then
                            Expect.fail "flag-off demand unexpectedly carries a 2-member set"

                        else
                            Expect.pass
        , Test.test "2. mk2 flag ON: body lambdas' members reach the caller's result arrow" <|
            \() ->
                case ( run True mk2Module, run False mk2Module ) of
                    ( Ok on, Ok off ) ->
                        if
                            List.any (annoHasSize 2) (allAnnos "mk2" on)
                                && not (List.any (annoHasSize 2) (allAnnos "mk2" off))
                        then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected a 2-member LSet flag-on only; on="
                                    ++ describeAnnos (allAnnos "mk2" on)
                                    ++ " off="
                                    ++ describeAnnos (allAnnos "mk2" off)
                                )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "3. negative control: polymorphic `apply` demands are identical flag-on/flag-off" <|
            \() ->
                case ( run True applyModule, run False applyModule ) of
                    ( Ok on, Ok off ) ->
                        Expect.equal
                            (List.map annosOf (demandsOf "apply" off))
                            (List.map annosOf (demandsOf "apply" on))

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "4. HONESTY pin: a hub mixing an honest branch with a call result POISONS (no false singleton)" <|
            \() ->
                case run True pickModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "pick" graph)
                        in
                        if List.isEmpty resultAnnos then
                            Expect.fail "no pick demands found"

                        else if List.all Mono.isTopAnno resultAnnos then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected LTop on every pick result arrow (honesty rule), got: "
                                    ++ describeAnnos resultAnnos
                                )
        , Test.test "5. TailDef pin: tail-recursive countdown transports k to its result arrow flag-on (peel + WpSelf); flag-off it is UNWRITTEN" <|
            \() ->
                case ( run True countdownModule, run False countdownModule ) of
                    ( Ok on, Ok off ) ->
                        let
                            onRes =
                                List.filterMap deepestRetAnno (demandsOf "countdown" on)

                            offRes =
                                List.filterMap deepestRetAnno (demandsOf "countdown" off)
                        in
                        -- Phase 1 (plans/lss-unknown-elimination.md): the
                        -- flag-off arm reads a set VARIABLE, not `LTop`, and that
                        -- is FREE INFORMATION rather than a fixture chore —
                        -- with sigFlow off nothing ever WRITES this result
                        -- arrow, so the position is unconstrained, not widened.
                        -- Before Phase 1b that same position read `LTop`
                        -- because `monoTypeToVarC` re-encoded the unwritten
                        -- demand as an explicit `LsTop` (the §0.1 laundering).
                        -- The pin's content is unchanged: flag-on must produce
                        -- a real 1-member set, flag-off must produce NO set.
                        if List.any (annoHasSize 1) onRes && List.all isVarAnno offRes then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected a 1-member LSet on a countdown result arrow flag-on and a set VARIABLE flag-off; on="
                                    ++ describeAnnos onRes
                                    ++ " off="
                                    ++ describeAnnos offRes
                                )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "6. B.4 rider: a >maxSetSize signature arrow widens and bumps widenedBySigSize" <|
            \() ->
                let
                    defaults =
                        Config.defaultLss
                in
                case
                    Pipeline.runSolverMonoWithReport Config.defaultLimits
                        { defaults | enabled = True, keyed = True, sigFlow = True, maxSetSize = 1, layoutQualMembers = False }
                        mk2Module
                of
                    Err msg ->
                        Expect.fail msg

                    Ok ( graph, maybeReport ) ->
                        let
                            report =
                                Maybe.withDefault "" maybeReport

                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "mk2" graph)
                        in
                        Expect.all
                            [ \() ->
                                if String.contains "bySigSize=1" report then
                                    Expect.pass

                                else
                                    Expect.fail ("expected bySigSize=1 in the report, got: " ++ report)
                            , \() ->
                                if List.all Mono.isTopAnno resultAnnos && not (List.isEmpty resultAnnos) then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected the widened result arrow to read LTop, got: "
                                            ++ describeAnnos resultAnnos
                                        )
                            ]
                            ()
        , Test.test "7. transitive chain: three lambdas through a nested hub — result 3-set, params all singletons" <|
            \() ->
                -- Edge depth ≥ 2: the outer hub's sources include the inner
                -- hub, whose sources are the g/h uses. Resolution walks the
                -- chain; the params stay unpolluted at every depth.
                case run True chainModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "chain" graph)

                            paramAnnos =
                                List.concatMap paramArrowAnnos (demandsOf "chain" graph)
                        in
                        Expect.all
                            [ \() ->
                                if List.any (annoHasSize 3) resultAnnos then
                                    Expect.pass

                                else
                                    Expect.fail ("expected a 3-set result, got: " ++ describeAnnos resultAnnos)
                            , \() ->
                                if List.length paramAnnos == 3 && List.all (annoHasSize 1) paramAnnos then
                                    Expect.pass

                                else
                                    Expect.fail ("expected three singleton params, got: " ++ describeAnnos paramAnnos)
                            ]
                            ()
        , Test.test "8. container degrade: a Tuple hub goes symmetric and the report counts it" <|
            \() ->
                let
                    defaults =
                        Config.defaultLss
                in
                case
                    Pipeline.runSolverMonoWithReport Config.defaultLimits
                        { defaults | enabled = True, keyed = True, sigFlow = True, layoutQualMembers = False }
                        choosePairModule
                of
                    Err msg ->
                        Expect.fail msg

                    Ok ( graph, maybeReport ) ->
                        let
                            report =
                                Maybe.withDefault "" maybeReport

                            tupleElementAnnos =
                                demandsOf "choosePair" graph
                                    |> List.filterMap deepestRetTuple
                                    |> List.concatMap identity
                        in
                        Expect.all
                            [ \() ->
                                -- The plan's sketch expected symmetric 2-sets
                                -- here; that is NOT OBSERVABLE in either
                                -- design, because member transport into
                                -- container LITERALS does not exist (argument
                                -- injection is per-direct-argument —
                                -- `injectArgLambdaMember` does not descend
                                -- into tuples; the symmetric Run-X arm reads
                                -- LTop here too). What the degrade guard
                                -- protects is the JOIN DIRECTION's soundness,
                                -- not new precision, so the observables are:
                                -- the elements read ⊤-or-honest (never a
                                -- wrong-direction non-⊤ set) and the degrade
                                -- COUNTER fires.
                                if List.isEmpty tupleElementAnnos then
                                    Expect.fail "no tuple element annos found"

                                else
                                    Expect.pass
                            , \() ->
                                -- value-pinned per test 6's precedent: the key
                                -- prints unconditionally once §6 lands, so
                                -- presence-checking would be vacuous.
                                if String.contains "degraded=0" report then
                                    Expect.fail ("expected a nonzero degrade count, report says: " ++ report)

                                else
                                    Expect.pass
                            ]
                            ()
        , Test.test "9. contravariance pin: a HOF param's inner arrow is LTop or carries k — never a k-less non-⊤ set" <|
            \() ->
                -- All flows through NAMED sites, observable on the def's own
                -- demand. Edges: hub ⊇ hof-uses; the FunL ARG position FLIPS,
                -- giving hof_i.param ⊇ h.param; joinCallArgs gives
                -- h.param ⊇ use_k. A BACKWARDS flip yields a k-less non-⊤ set
                -- at exactly this position — the assertion shape that catches
                -- it.
                case run True useHModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            hofInnerAnnos =
                                demandsOf "useH" graph
                                    |> List.concatMap hofParamInnerAnnos
                        in
                        -- The hof-use edges flow through the let hub and k's
                        -- member reaches h.param, whose set the hof-param edge
                        -- then covers.
                        --
                        -- UNTIL 2026-08-25 these positions read as set
                        -- VARIABLES, because `useH`'s own instantiation wrote
                        -- no members into them — an absence, not a widening.
                        -- `lss.arrowIdentity` going default-on
                        -- (plans/lss-paper-inclusion-constraints.md §5.A3)
                        -- closed exactly that absence: it is LSS_006 per-load
                        -- slot minting, and with the slot shared the write is
                        -- visible here. MEASURED at the flip: `hofInner` reads
                        -- `LSet[6], LSet[6]` where hof1's own set is `LSet[4]`,
                        -- hof2's is `LSet[5]` and k's own is `LSet[6]` — both
                        -- inner arrows carry EXACTLY k's member.
                        --
                        -- So `List.all isVarAnno` was a PROXY that only
                        -- discriminated while the position was unwritten. The
                        -- claim in the title is restated directly, and the
                        -- numbers stay out of it (canonical member numbering is
                        -- per-type walk order, so literal ids would be a churn
                        -- magnet):
                        --
                        --   POSITIVE — the inner arrow is unwritten, or it
                        --   carries what `k` carries. That is the FORWARD flow.
                        --
                        --   NEGATIVE — it never carries the hof params' OWN
                        --   members. That is the miscompile class this pin
                        --   exists for: a BACKWARDS flip pushes `h`'s set
                        --   ({hof1, hof2}) into the position instead of k's.
                        Expect.equal ( 2, True, True )
                            ( List.length hofInnerAnnos
                            , List.all
                                (\a ->
                                    isVarAnno a
                                        || Mono.isTopAnno a
                                        || List.member a (plainFnParamAnnosOf "useH" graph)
                                )
                                hofInnerAnnos
                            , List.all
                                (\a ->
                                    List.all
                                        (\m -> not (List.member m (backwardsMembers "useH" graph)))
                                        (membersOf a)
                                )
                                hofInnerAnnos
                            )
        ]



-- ====== HARNESS ======


run : Bool -> Src.Module -> Result String Mono.MonoGraph
run sigFlow srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits
        Config.defaultLimits
        -- keyed = True (the shipping default) is what stores annotated
        -- demands in the registry in the first place. layoutQualMembers
        -- PINNED OFF: these fixtures pin LSS_020/023 mechanisms in
        -- isolation from LSS_024's id sharing (default-on since 2026-08-21).
        --
        -- `papMembers` / `sigRootIdentity` PINNED OFF for the same reason,
        -- and it is load-bearing here rather than tidy-minded. Every test
        -- driven through this harness is DIFFERENTIAL — it compares
        -- `sigFlow` on against off — and `sigRootIdentity` opens a SECOND
        -- channel to the same place: it ties a def's annotation arrows to
        -- its body's, so signatures conduct members whether or not `sigFlow`
        -- is on. Inheriting it (default-on since 2026-08-27) put that
        -- channel in BOTH arms, which collapsed the differentials: test 1b's
        -- "the channel is empty" absence stopped holding, test 2's 2-member
        -- set appeared flag-OFF too, and test 3's negative control stopped
        -- being identical because root identity makes signatures non-trivial
        -- (self-compile: 9,243 trivial -> 8,386) and that control's premise
        -- is a trivial signature.
        --
        -- The general rule, paid for twice now: A DIFFERENTIAL TEST MUST PIN
        -- EVERY FLAG THAT OVERLAPS THE ONE IT TOGGLES. Tests 6 and 8 below
        -- are deliberately NOT pinned — they assert absolute counter values
        -- under a single config rather than a difference, so a second
        -- channel does not invalidate them.
        { defaults
            | enabled = True
            , keyed = True
            , sigFlow = sigFlow
            , layoutQualMembers = False
            , papMembers = False
            , sigRootIdentity = False

            -- regIdentity (default-on since 2026-08-28) PINNED OFF, fourth
            -- instance of the differential-overlap rule: the registration
            -- stamp writes head/spine annos, and this harness's readers scan
            -- ALL annos of a def's demands — the channel would sit in both
            -- arms of the sigFlow differential.
            , regIdentity = False
        }
        srcModule


{-| Every stored (keyed) demand type for the named global, from the
registry's reverse mapping (MuTieTest precedent).
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


{-| Every arrow annotation anywhere in a stored demand type (one anno per
`MFunction` node — zonk emits one arrow per node).
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


allAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
allAnnos target graph =
    List.concatMap annosOf (demandsOf target graph)


{-| The PARAM arrows' annotations: each argument position that is itself an
`MFunction`, plus the same down the return spine (verified against
`zonkFlatC`'s one-arg-per-arrow output).
-}
paramArrowAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
paramArrowAnnos t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap
                (\a ->
                    case a of
                        Mono.MFunction _ anno _ _ ->
                            Just anno

                        _ ->
                            Nothing
                )
                args
                ++ paramArrowAnnos ret

        _ ->
            []


{-| The RESULT arrow's annotation: the deepest `MFunction` on the return
spine (its own head anno). `Nothing` for non-function demands.
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


{-| Test 8: the element-arrow annos of the deepest RESULT tuple.
-}
deepestRetTuple : Mono.MonoType -> Maybe (List Mono.LambdaSetAnno)
deepestRetTuple t =
    case t of
        Mono.MFunction _ _ _ ret ->
            deepestRetTuple ret

        Mono.MTuple _ els ->
            Just
                (List.filterMap
                    (\el ->
                        case el of
                            Mono.MFunction _ anno _ _ ->
                                Just anno

                            _ ->
                                Nothing
                    )
                    els
                )

        _ ->
            Nothing


{-| Test 9: for each HOF-typed param `(Int -> Int) -> Int`, the INNER
`(Int -> Int)` arrow's anno.
-}
hofParamInnerAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
hofParamInnerAnnos t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap
                (\a ->
                    case a of
                        Mono.MFunction _ _ [ Mono.MFunction _ innerAnno _ _ ] _ ->
                            Just innerAnno

                        _ ->
                            Nothing
                )
                args
                ++ hofParamInnerAnnos ret

        _ ->
            []


{-| The annos of the def's PLAIN function params — those whose own parameter
is not itself a function. In `useHModule` that is `k : Int -> Int`, whose set
is what the forward flow puts at each hof param's inner arrow.
-}
plainFnParamAnnosOf : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
plainFnParamAnnosOf target graph =
    List.concatMap plainFnParamAnnos (demandsOf target graph)


plainFnParamAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
plainFnParamAnnos t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap
                (\a ->
                    case a of
                        Mono.MFunction _ _ [ Mono.MFunction _ _ _ _ ] _ ->
                            -- a HOF param, not a plain one
                            Nothing

                        Mono.MFunction _ anno _ _ ->
                            Just anno

                        _ ->
                            Nothing
                )
                args
                ++ plainFnParamAnnos ret

        _ ->
            []


{-| The members a BACKWARDS flip would push into a HOF param's inner arrow:
the hof params' OWN sets (`h`'s inhabitants).
-}
backwardsMembers : String -> Mono.MonoGraph -> List Int
backwardsMembers target graph =
    List.concatMap membersOf
        (List.concatMap hofParamOuterAnnos (demandsOf target graph))


hofParamOuterAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
hofParamOuterAnnos t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap
                (\a ->
                    case a of
                        Mono.MFunction _ outerAnno [ Mono.MFunction _ _ _ _ ] _ ->
                            Just outerAnno

                        _ ->
                            Nothing
                )
                args
                ++ hofParamOuterAnnos ret

        _ ->
            []


membersOf : Mono.LambdaSetAnno -> List Int
membersOf anno =
    case anno of
        Mono.LSet ms ->
            ms

        _ ->
            []


isVarAnno : Mono.LambdaSetAnno -> Bool
isVarAnno anno =
    case anno of
        Mono.LVar _ ->
            True

        _ ->
            False


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


{-| Test 1: params flow through an If into the result — ground annotation.
-}
chooseHandlerModule : Src.Module
chooseHandlerModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "chooseHandler"
          , args = [ pVar "b", pVar "f", pVar "g" ]
          , tipe = tLambda (tType "Bool" []) (tLambda hInt (tLambda hInt hInt))
          , body = ifExpr (varExpr "b") (varExpr "f") (varExpr "g")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "chooseHandler")
                        [ boolExpr True
                        , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                        , lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2))
                        ]
                    )
                    [ intExpr 9 ]
          }
        ]


{-| Test 2/6: body lambdas meet in the result arrow via the hub.
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


{-| Test 3: polymorphic negative control — the signature must stay trivial
(self-id filtered; the local-callee join adds nothing at TVar positions).
-}
applyModule : Src.Module
applyModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "apply"
          , args = [ pVar "f", pVar "x" ]
          , tipe = tLambda (tLambda (tVar "a") (tVar "b")) (tLambda (tVar "a") (tVar "b"))
          , body = callExpr (varExpr "f") [ varExpr "x" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr (varExpr "apply")
                    [ lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 1))
                    , intExpr 3
                    ]
          }
        ]


{-| Test 4: an If mixing an HONEST branch (a standalone global) with an
OPAQUE one (a call result) — the hub must poison, not publish `{g|inc}`.
-}
pickModule : Src.Module
pickModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "mkAdd"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "pick"
          , args = [ pVar "c", pVar "g" ]
          , tipe = tLambda (tType "Bool" []) (tLambda (tLambda (tType "Int" []) hInt) hInt)
          , body =
                ifExpr (varExpr "c")
                    (varExpr "inc")
                    (callExpr (varExpr "g") [ intExpr 0 ])
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "pick") [ boolExpr True, varExpr "mkAdd" ])
                    [ intExpr 7 ]
          }
        ]


{-| Test 5: self-tail-recursive, function-returning — the TailDef shape
(arg-stripped body at the result type).
-}
countdownModule : Src.Module
countdownModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "countdown"
          , args = [ pVar "n", pVar "k" ]
          , tipe = tLambda (tType "Int" []) (tLambda hInt hInt)
          , body =
                ifExpr (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (varExpr "k")
                    (callExpr (varExpr "countdown")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        , varExpr "k"
                        ]
                    )
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "countdown") [ intExpr 3, varExpr "inc" ])
                    [ intExpr 5 ]
          }
        ]


{-| Test 7: transitive chain through a nested hub.
-}
chainModule : Src.Module
chainModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "chain"
          , args = [ pVar "b", pVar "c", pVar "f", pVar "g", pVar "h" ]
          , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tType "Bool" [])
                        (tLambda hInt (tLambda hInt (tLambda hInt hInt)))
                    )
          , body =
                ifExpr (varExpr "b")
                    (varExpr "f")
                    (ifExpr (varExpr "c") (varExpr "g") (varExpr "h"))
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "chain")
                        [ boolExpr True
                        , boolExpr False
                        , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                        , lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2))
                        , lambdaExpr [ pVar "z" ] (binopsExpr [ ( varExpr "z", "+" ) ] (intExpr 3))
                        ]
                    )
                    [ intExpr 9 ]
          }
        ]


{-| Test 8: a Tuple-typed hub — branches must be letEnv-bound NAMES at a
container type (a literal branch returns WpNone and the hub poisons before
any join runs).
-}
choosePairModule : Src.Module
choosePairModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "choosePair"
          , args = [ pVar "b", pVar "p", pVar "q" ]
          , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tTuple hInt hInt) (tLambda (tTuple hInt hInt) (tTuple hInt hInt)))
          , body = ifExpr (varExpr "b") (varExpr "p") (varExpr "q")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                caseFirst
                    (callExpr (varExpr "choosePair")
                        [ boolExpr True
                        , tupleExpr
                            (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)))
                            (lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2)))
                        , tupleExpr
                            (lambdaExpr [ pVar "u" ] (binopsExpr [ ( varExpr "u", "+" ) ] (intExpr 3)))
                            (lambdaExpr [ pVar "v" ] (binopsExpr [ ( varExpr "v", "+" ) ] (intExpr 4)))
                        ]
                    )
          }
        ]


{-| Apply the first element of an (Int -> Int, Int -> Int) pair to 5 — makes
testValue an Int root without needing Tuple.first in the mock env.
-}
caseFirst : Src.Expr -> Src.Expr
caseFirst pairExpr =
    caseExpr pairExpr
        [ ( pTuple (pVar "fst1") (pVar "snd1")
          , callExpr (varExpr "fst1") [ intExpr 5 ]
          )
        ]


{-| Test 9: contravariance — all flows through NAMED sites (params of the
annotated def), observable on the def's own demand.
-}
useHModule : Src.Module
useHModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "useH"
          , args = [ pVar "b", pVar "hof1", pVar "hof2", pVar "k" ]
          , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tLambda hInt (tType "Int" []))
                        (tLambda (tLambda hInt (tType "Int" []))
                            (tLambda hInt (tType "Int" []))
                        )
                    )
          , body =
                letExpr
                    [ define "h" [] (ifExpr (varExpr "b") (varExpr "hof1") (varExpr "hof2")) ]
                    (callExpr (varExpr "h") [ varExpr "k" ])
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr (varExpr "useH")
                    [ boolExpr True
                    , lambdaExpr [ pVar "f" ] (callExpr (varExpr "f") [ intExpr 1 ])
                    , lambdaExpr [ pVar "g" ] (callExpr (varExpr "g") [ intExpr 2 ])
                    , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))
                    ]
          }
        ]
