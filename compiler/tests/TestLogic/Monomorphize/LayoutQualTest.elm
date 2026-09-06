module TestLogic.Monomorphize.LayoutQualTest exposing (suite)

{-| LSS_024 — layout-qualified lambda-instance members
(`plans/lss-layout-qualified-members.md` §5.1/§5.2 pins).

Three groups:

1.  PURE pins on the key machinery: annotation-only differences erase under
    `widenSets` (equal widened keys) while layout differences survive;
    `layoutQualKey`'s captured-vs-fallback split; `internMemberKey`
    idempotence (the re-mint pin).
2.  SPIRAL pins on the MuTieTest fixture: under `layoutQualMembers` the
    qualification spiral closes at its second member WITHOUT recording any
    μ-tie — with `muTie` off (C alone terminates it: the generation-2 spec
    is an annotation-only split of generation 1, so the mint re-interns the
    same id and the registry probe hits) and with `muTie` on (the §2.3
    equal-id bypass: `tieBypass` counts, `muTied`/`lssBlockedMembers` stay
    empty). Any `lssBlockedMembers` shrink is the bypass and nothing else.
3.  SPLIT-COLLAPSE pins: a two-caller family forcing an annotation-only
    same-layout key split of `mid` whose per-spec inner lambda feeds a
    shared HOF. Flag-off the propagated ids split the HOF's key (2 specs);
    flag-on both mid specs mint ONE id (`shared` counts) and the HOF
    collapses to 1 spec — the §0 `UnionFind.get/modify`-class propagated
    split, reproduced in miniature.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
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
import Compiler.MonoSolver.Engine as Engine
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "LSS_024 layout-qualified members"
        [ Test.describe "pure key machinery" purePins
        , Test.describe "qualification spiral under C" spiralPins
        , Test.describe "annotation-split collapse" splitPins
        ]



-- ====== 1. PURE PINS ======


{-| An `(Int -> Int) -> Int` arrow whose callback slot carries `anno`.
-}
arrowWith : Mono.LambdaSetAnno -> Mono.MonoType
arrowWith anno =
    Mono.mFunction Mono.topLegacy [ Mono.mFunction anno [ Mono.MInt ] Mono.MInt ] Mono.MInt


widenedKey : Mono.MonoType -> String
widenedKey t =
    Mono.toComparableMonoType (Mono.widenSets t)


purePins : List Test
purePins =
    [ Test.test "annotation-only differences erase: equal widened keys" <|
        \() ->
            Expect.equal
                (widenedKey (arrowWith (Mono.LSet [ 101 ])))
                (widenedKey (arrowWith (Mono.LSet [ 202, 303 ])))
    , Test.test "Phase 1a/3: a set VARIABLE widens to the SAME key as LTop (1a-T7 direct pin)" <|
        \() ->
            -- `Mono.widenSets` stamps LTop, never LVar, and that is what
            -- keeps the five widened-string-key derivations byte-identical
            -- across the label split (LSS_024 specWidenedKeys, LSS_019 ground
            -- member ids, the LSS_024 F-fence fingerprint, the keyed=False
            -- widened registry key, and the budget-widened key). A drift here
            -- produces a different registry key with NO compile error.
            Expect.equal
                (widenedKey (arrowWith Mono.topLegacy))
                (widenedKey (arrowWith (Mono.LVar 0)))
    , Test.test "layout differences survive widening: distinct keys" <|
        \() ->
            Expect.notEqual
                (widenedKey (arrowWith (Mono.LSet [ 101 ])))
                (widenedKey (Mono.mFunction Mono.topLegacy [ Mono.mFunction Mono.topLegacy [ Mono.MFloat ] Mono.MInt ] Mono.MInt))
    , Test.test "layoutQualKey: captured key qualifies by the widened key" <|
        \() ->
            Expect.equal ( "l|42|A(I->I)", False )
                (Engine.layoutQualKey (Dict.fromList [ ( 7, "A(I->I)" ) ]) 42 0 7)
    , Test.test "layoutQualKey: missing capture falls back to SpecId qualification" <|
        \() ->
            Expect.equal ( "l|42|8", True )
                (Engine.layoutQualKey (Dict.fromList [ ( 7, "A(I->I)" ) ]) 42 0 8)
    , Test.test "layoutQualKey: instance tag 0 reproduces the pre-instanceQual string byte for byte" <|
        \() ->
            -- the flag-off byte-identity rail
            -- (plans/lss-instance-qualified-members.md §3.4)
            Expect.equal ( "l|42|A(I->I)", False )
                (Engine.layoutQualKey (Dict.fromList [ ( 7, "A(I->I)" ) ]) 42 0 7)
    , Test.test "layoutQualKey: a non-zero instance tag appends an unambiguous #-marked component" <|
        \() ->
            Expect.equal ( "l|42|A(I->I)|#513", False )
                (Engine.layoutQualKey (Dict.fromList [ ( 7, "A(I->I)" ) ]) 42 513 7)
    , Test.test "layoutQualKey: distinct instance tags never collide with each other or with the untagged key" <|
        \() ->
            let
                keys =
                    List.map (\t -> Tuple.first (Engine.layoutQualKey (Dict.fromList [ ( 7, "A(I->I)" ) ]) 42 t 7)) [ 0, 1, 2, 513 ]
            in
            Expect.equal 4 (List.length (List.foldl (\k acc -> if List.member k acc then acc else k :: acc) [] keys))
    , Test.test "mixTag: composition, not overwrite — the same ordinal under different outer tags differs" <|
        \() ->
            -- plans/lss-instance-qualified-members.md §3.2: an inner
            -- let-function's instance 1 inside outer instance 0 must not
            -- collide with the same ordinal inside outer instance 1.
            Expect.notEqual (Engine.mixTag (Engine.mixTag 0 0) 1) (Engine.mixTag (Engine.mixTag 0 1) 1)
    , Test.test "mixTag: a leading ordinal 0 is not absorbed into the no-instance sentinel" <|
        \() ->
            Expect.notEqual 0 (Engine.mixTag 0 0)
    , Test.test "fallback-vs-widened collisions impossible: widened keys never start with a digit" <|
        \() ->
            -- every toComparableMonoType rendering starts with a letter code;
            -- a bare-integer SpecId suffix can never equal one.
            case String.uncons (widenedKey (arrowWith Mono.topLegacy)) of
                Just ( c, _ ) ->
                    Expect.equal False (Char.isDigit c)

                Nothing ->
                    Expect.fail "empty widened key"
    , Test.test "internMemberKey: re-mint of one key is idempotent (same id, no growth)" <|
        \() ->
            let
                ( id1, t1, n1 ) =
                    Engine.internMemberKey "l|42|A(I->I)" Engine.emptyMemberTable 5000

                ( id2, _, n2 ) =
                    Engine.internMemberKey "l|42|A(I->I)" t1 n1
            in
            Expect.equal ( id1, n1 ) ( id2, n2 )
    ]



-- ====== 2. SPIRAL PINS (MuTieTest fixture, C arm) ======


type alias Facts =
    { blockedCount : Int
    , loopSpecs : Int
    , report : String
    }


runSpiral : Bool -> Bool -> Result String Facts
runSpiral muTie layoutQual =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithReport
        Config.defaultLimits
        -- sigFlow PINNED OFF: these fixtures pin LSS_024's C mechanism in
        -- isolation (default-on sigFlow since 2026-08-21 would add
        -- signature facts to the tiny fixtures and move spec counts).
        { defaults | enabled = True, keyed = True, muTie = muTie, layoutQualMembers = layoutQual, sigFlow = False }
        spiralModule
        |> Result.map
            (\( graph, maybeReport ) ->
                let
                    base =
                        factsOf graph
                in
                { base | report = Maybe.withDefault "" maybeReport }
            )


factsOf : Mono.MonoGraph -> Facts
factsOf (Mono.MonoGraph g) =
    { blockedCount = Dict.size g.lssBlockedMembers
    , loopSpecs = specCount "loop" g
    , report = ""
    }


specCount : String -> { r | registry : Mono.SpecializationRegistry } -> Int
specCount name g =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ n, _ ) ->
                    if n == name then
                        acc + 1

                    else
                        acc

                _ ->
                    acc
        )
        0
        g.registry.reverseMapping


{-| Read a census counter (`label` includes the `=`, e.g. `"tieBypass="`).
-1 when absent.
-}
counterOf : String -> String -> Int
counterOf label report =
    case String.split label report |> List.drop 1 |> List.head of
        Just rest ->
            Maybe.withDefault -1 (String.toInt (leadingDigits rest))

        Nothing ->
            -1


leadingDigits : String -> String
leadingDigits s =
    case String.uncons s of
        Just ( c, rest ) ->
            if Char.isDigit c then
                String.cons c (leadingDigits rest)

            else
                ""

        Nothing ->
            ""


spiralPins : List Test
spiralPins =
    [ Test.test "muTie OFF + layoutQual ON: C alone closes the spiral, nothing blocked" <|
        \() ->
            case runSpiral False True of
                Err msg ->
                    Expect.fail msg

                Ok f ->
                    Expect.all
                        [ \x -> Expect.equal 0 x.blockedCount
                        , \x ->
                            if x.loopSpecs <= 3 then
                                Expect.pass

                            else
                                Expect.fail ("spiral did not close: loopSpecs=" ++ String.fromInt x.loopSpecs)
                        , \x -> Expect.equal 0 (counterOf "fallback=" x.report)
                        ]
                        f
    , Test.test "muTie ON + layoutQual ON: equal-id bypass — closed, nothing recorded, tieBypass counts" <|
        \() ->
            case runSpiral True True of
                Err msg ->
                    Expect.fail msg

                Ok f ->
                    Expect.all
                        [ \x -> Expect.equal 0 x.blockedCount
                        , \x ->
                            if x.loopSpecs <= 3 then
                                Expect.pass

                            else
                                Expect.fail ("spiral did not close: loopSpecs=" ++ String.fromInt x.loopSpecs)
                        , \x ->
                            if counterOf "tieBypass=" x.report >= 1 then
                                Expect.pass

                            else
                                Expect.fail ("expected tieBypass >= 1 in: " ++ x.report)
                        , \x ->
                            if counterOf "shared=" x.report >= 1 then
                                Expect.pass

                            else
                                Expect.fail ("expected shared >= 1 in: " ++ x.report)
                        , \x -> Expect.equal 0 (counterOf "fallback=" x.report)
                        ]
                        f
    , Test.test "muTie ON + layoutQual OFF: the tie still fires and blocks (LSS_018 unchanged)" <|
        \() ->
            case runSpiral True False of
                Err msg ->
                    Expect.fail msg

                Ok f ->
                    Expect.all
                        [ \x ->
                            if x.blockedCount >= 1 then
                                Expect.pass

                            else
                                Expect.fail "expected the flag-off arm to μ-tie and block"
                        , \x ->
                            if x.loopSpecs <= 3 then
                                Expect.pass

                            else
                                Expect.fail ("tie did not close the spiral: loopSpecs=" ++ String.fromInt x.loopSpecs)
                        , \x -> Expect.equal 0 (counterOf "tieBypass=" x.report)
                        ]
                        f
    ]



-- ====== 3. SPLIT-COLLAPSE PINS ======


runSplit : Bool -> Result String { midSpecs : Int, hofSpecs : Int, report : String }
runSplit layoutQual =
    runSplitWithBudget layoutQual Config.defaultLss.maxSpecsPerGlobal


{-| §5.1's budget-twin pin runs this with `maxSpecsPerGlobal = 1`: the first
`mid` demand creates ANNOTATION-keyed (under budget), the second creates
BUDGET-WIDENED — twins of one global whose widened creation keys must land
EQUAL, so their lambdas SHARE one id.
-}
runSplitWithBudget : Bool -> Int -> Result String { midSpecs : Int, hofSpecs : Int, report : String }
runSplitWithBudget layoutQual budget =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithReport
        Config.defaultLimits
        { defaults | enabled = True, keyed = True, layoutQualMembers = layoutQual, maxSpecsPerGlobal = budget, sigFlow = False }
        splitModule
        |> Result.map
            (\( (Mono.MonoGraph g) as graph, maybeReport ) ->
                { midSpecs = specCount "mid" g
                , hofSpecs = specCount "applyHof" g
                , report = Maybe.withDefault "" maybeReport
                }
            )


splitPins : List Test
splitPins =
    [ Test.test "flag OFF: annotation-only split of mid propagates into applyHof (2 specs each)" <|
        \() ->
            case runSplit False of
                Err msg ->
                    Expect.fail msg

                Ok f ->
                    Expect.equal { midSpecs = 2, hofSpecs = 2 }
                        { midSpecs = f.midSpecs, hofSpecs = f.hofSpecs }
    , Test.test "flag ON: mid's root split persists, the PROPAGATED applyHof split collapses to 1" <|
        \() ->
            case runSplit True of
                Err msg ->
                    Expect.fail msg

                Ok f ->
                    Expect.all
                        [ \x -> Expect.equal 2 x.midSpecs
                        , \x -> Expect.equal 1 x.hofSpecs
                        , \x ->
                            if counterOf "shared=" x.report >= 1 then
                                Expect.pass

                            else
                                Expect.fail ("expected shared >= 1 in: " ++ x.report)
                        , \x -> Expect.equal 0 (counterOf "fallback=" x.report)
                        ]
                        f
    , Test.test "budget twins share: annotation-created + budget-widened specs of one global mint ONE id" <|
        \() ->
            case runSplitWithBudget True 1 of
                Err msg ->
                    Expect.fail msg

                Ok f ->
                    Expect.all
                        [ \x ->
                            if counterOf "shared=" x.report >= 1 then
                                Expect.pass

                            else
                                Expect.fail ("expected shared >= 1 in: " ++ x.report)
                        , \x -> Expect.equal 0 (counterOf "fallback=" x.report)

                        -- NOT 1: at budget=1 applyHof itself keys as an
                        -- annotated + budget-widened twin PAIR (2 specs by
                        -- budget mechanics). The sharing pin above is the
                        -- twin evidence — `mid` is the only lambda-minting
                        -- global in the fixture, so shared >= 1 can only
                        -- come from its annotation-created + budget-widened
                        -- twins interning one id.
                        , \x -> Expect.equal 2 x.hofSpecs
                        ]
                        f
    ]



-- ====== FIXTURES ======


{-| The MuTieTest spiral, verbatim (see that module's doc for why the
non-tail `1 +` is load-bearing).
-}
spiralModule : Src.Module
spiralModule =
    makeModuleWithTypedDefs "Test" [ loopDef, spiralValueDef ]


loopDef : TypedDef
loopDef =
    { name = "loop"
    , args = [ pVar "n", pVar "f" ]
    , tipe =
        tLambda (tType "Int" [])
            (tLambda (tLambda (tType "Int" []) (tType "Int" []))
                (tType "Int" [])
            )
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (callExpr (varExpr "f") [ intExpr 0 ])
            (binopsExpr [ ( intExpr 1, "+" ) ]
                (callExpr (varExpr "loop")
                    [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                    , lambdaExpr [ pVar "x" ]
                        (binopsExpr
                            [ ( callExpr (varExpr "f") [ varExpr "x" ], "+" ) ]
                            (intExpr 1)
                        )
                    ]
                )
            )
    }


spiralValueDef : TypedDef
spiralValueDef =
    { name = "testValue"
    , args = []
    , tipe = tType "Int" []
    , body =
        callExpr (varExpr "loop")
            [ intExpr 3
            , lambdaExpr [ pVar "x" ] (varExpr "x")
            ]
    }


{-| The split family: `mid inc` / `mid dec` force an annotation-only
same-layout key split of `mid` ({g|inc} vs {g|dec} on `f`'s arrow); each
`mid` spec mints its own copy of the inner lambda, which flows to the
shared `applyHof`. The inner lambdas are the same source lambda at the same
layouts, so under LSS_024 both specs intern ONE member id. (The clones are
E11-DIVERGENT — they capture different `f`s — which is the consumer-side
fence's problem, deliberately not this mono-level test's: stamping is
AbiCloning's, exercised in the fence unit tests.)
-}
splitModule : Src.Module
splitModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = tLambda (tType "Int" []) (tType "Int" [])
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "dec"
          , args = [ pVar "x" ]
          , tipe = tLambda (tType "Int" []) (tType "Int" [])
          , body = binopsExpr [ ( varExpr "x", "-" ) ] (intExpr 1)
          }
        , { name = "applyHof"
          , args = [ pVar "g", pVar "y" ]
          , tipe =
                tLambda (tLambda (tType "Int" []) (tType "Int" []))
                    (tLambda (tType "Int" []) (tType "Int" []))
          , body = callExpr (varExpr "g") [ varExpr "y" ]
          }
        , { name = "mid"
          , args = [ pVar "f", pVar "x" ]
          , tipe =
                tLambda (tLambda (tType "Int" []) (tType "Int" []))
                    (tLambda (tType "Int" []) (tType "Int" []))
          , body =
                callExpr (varExpr "applyHof")
                    [ lambdaExpr [ pVar "v" ]
                        (callExpr (varExpr "f")
                            [ binopsExpr [ ( varExpr "v", "+" ) ] (varExpr "x") ]
                        )
                    , varExpr "x"
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "mid") [ varExpr "inc", intExpr 1 ], "+" ) ]
                    (callExpr (varExpr "mid") [ varExpr "dec", intExpr 2 ])
          }
        ]
