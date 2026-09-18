module TestLogic.Monomorphize.LssRootFoldTest exposing (suite)

{-| ROOT-MEMBER FOLD — `lss.rootFold` (`plans/lss-root-member-fold.md`).

A top-level def carries two member ids — its body-root lambda's `l|` id and
its standalone `g|` id — and wherever both flow to one position the set is a
sound 2-set that singleton-only consumers cannot use. Under the fold the root
lambda interns the GROUND STANDALONE key instead, so root injection,
reference grounding and the `regIdentity` head stamp converge on ONE id.

All pins run with `regIdentity = True` explicitly (it is the mechanism that
makes the pairs meet at heads; default-on today, pinned here for
self-documentation and against future default changes).

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
        , listExpr
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
    Test.describe "lss.rootFold — one member id per (function, layout)"
        [ Test.test "1. DIFFERENTIAL: a plain def's stored head collapses 2-set -> singleton" <|
            \() ->
                case ( runWith False plainModule, runWith True plainModule ) of
                    ( Ok offG, Ok onG ) ->
                        let
                            offHeads =
                                headAnnos "double" offG

                            onHeads =
                                headAnnos "double" onG
                        in
                        if List.isEmpty onHeads then
                            Expect.fail "no spec registered for `double` — fixture broken"

                        else if not (List.all isMulti offHeads) then
                            Expect.fail ("flag-off head expected the l|/g| 2-set, got " ++ describe offHeads)

                        else if List.all isSingleton onHeads then
                            Expect.pass

                        else
                            Expect.fail ("flag-on head expected SINGLETONS, got " ++ describe onHeads)

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "2. CONVERGENCE: the stored head id IS the reference-flow id" <|
            \() ->
                -- `useIt double 3`: the consumer's parameter carries the
                -- member the REFERENCE path injected; the stored head carries
                -- the member the fold + stamp minted. Same integer = the
                -- whole point of the fold. Id-comparing, not class-guessing.
                case runWith True refModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case ( singletonIds (headAnnos "double" g), singletonIds (paramAnnos "useIt" g) ) of
                            ( headId :: _, paramId :: _ ) ->
                                if headId == paramId then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("stored head id "
                                            ++ String.fromInt headId
                                            ++ " /= reference-flow id "
                                            ++ String.fromInt paramId
                                            ++ " — the fold and the reference path diverged"
                                        )

                            ( hs, ps ) ->
                                Expect.fail
                                    ("expected singletons at both ends, got head="
                                        ++ String.fromInt (List.length hs)
                                        ++ " param="
                                        ++ String.fromInt (List.length ps)
                                    )
        , Test.test "3. KERNEL-ALIAS SKIP: no new split at a kernel-backed head" <|
            \() ->
                -- Folding a kernel-alias root would pair g|X with the k| id
                -- E9.2 folds references to — recreating the exact split the
                -- fold exists to remove. The skip is pinned as: never LVar
                -- (routing intact) and never a >2 set (no third identity).
                case runWith True consModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case headAnnos "cons" g of
                            [] ->
                                Expect.pass

                            heads ->
                                if List.all (\a -> Mono.isTopAnno a || sizeAtMost 2 a) heads then
                                    Expect.pass

                                else
                                    Expect.fail ("kernel-alias head grew a new identity: " ++ describe heads)
        , Test.test "4. DEEP SPINE: the folded head id is absent from depth 1" <|
            \() ->
                -- plans/lss-root-fold-depth-qualified-spine.md.
                --
                -- SUPERSEDES "4. DEEP SPINE UNCHANGED: plus2's depth-1 anno
                -- is arm-identical" (2026-09-17). That test asserted depth-1
                -- SET SIZES were equal across the rootFold arms, on the
                -- premise recorded in its comment: "The fold is head-only by
                -- design (`p|` stays the declining class at depth > 0)."
                -- The premise was FALSE of the translation-phase writer:
                -- `injectLambdaMemberQualified` -> `spineGoC` wrote the
                -- folded GROUND `g|` id at EVERY depth 0..arity-1, i.e. the
                -- STAMPABLE id landed on partial-application positions,
                -- which `lss-root-member-fold.md` §1.5 AR-1 forbids. The old
                -- test stayed green because it was size-based and id-blind:
                -- OFF gave `{l|lam, p|g|1}` and ON gave `{g|G|L, p|g|1}` —
                -- both size 2. It pinned the SYMMETRY of the defect, not the
                -- property its comment claimed.
                --
                -- This asserts the property directly, which is also the only
                -- form that distinguishes WHICH member survives: under the
                -- repair the head's folded id must not appear at depth 1.
                case runWithDepth True True plainModule of
                    Ok g ->
                        let
                            heads =
                                List.concatMap annoMembers (headAnnos "plus2" g)

                            deep =
                                List.concatMap annoMembers (depth1Annos "plus2" g)

                            leaked =
                                List.filter (\m -> List.member m deep) heads
                        in
                        if List.isEmpty heads then
                            Expect.fail "no head member for `plus2` — fixture broken"

                        else if List.isEmpty leaked then
                            Expect.pass

                        else
                            Expect.fail
                                ("AR-1 violated: head member(s) "
                                    ++ String.join "," (List.map String.fromInt leaked)
                                    ++ " appear at depth 1 "
                                    ++ String.join "," (List.map String.fromInt deep)
                                )

                    Err e ->
                        Expect.fail e
        , Test.test "4b. DIFFERENTIAL: rootFoldDepth is what removes it" <|
            \() ->
                -- The same read with the repair OFF must SHOW the leak, so
                -- this pair pins cause and effect rather than one endpoint.
                case runWithDepth True False plainModule of
                    Ok g ->
                        let
                            heads =
                                List.concatMap annoMembers (headAnnos "plus2" g)

                            deep =
                                List.concatMap annoMembers (depth1Annos "plus2" g)
                        in
                        if List.any (\m -> List.member m deep) heads then
                            Expect.pass

                        else
                            Expect.fail
                                ("flag-off arm no longer reproduces the leak — "
                                    ++ "heads "
                                    ++ String.join "," (List.map String.fromInt heads)
                                    ++ " vs depth1 "
                                    ++ String.join "," (List.map String.fromInt deep)
                                )

                    Err e ->
                        Expect.fail e
        , Test.test "5. CO-GATE: the crash shape publishes no false singleton" <|
            \() ->
                case runWith True joinModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case paramAnnos "useIt" g of
                            [] ->
                                Expect.fail "no demand recorded for `useIt` — fixture broken"

                            annos ->
                                if List.all neverFalselyComplete annos then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("a one-sided join published a singleton under rootFold: "
                                            ++ describe annos
                                        )
        ]



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


plainModule : Src.Module
plainModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "plus2"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = binopsExpr [ ( callExpr (varExpr "double") [ intExpr 3 ], "+" ) ] (callExpr (varExpr "plus2") [ intExpr 1, intExpr 2 ])
          }
        ]


refModule : Src.Module
refModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "useIt"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (varExpr "useIt") [ varExpr "double", intExpr 3 ]
          }
        ]


consModule : Src.Module
consModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "List" [ hInt ]
          , body = binopsExpr [ ( varExpr "double", "::" ) ] (listExpr [])
          }
        ]


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



-- ====== HARNESS ======


runWith : Bool -> Src.Module -> Result String Mono.MonoGraph
runWith rootFold srcModule =
    runWithDepth rootFold Config.defaultLss.stamp.rootFoldDepth srcModule


{-| `runWith` with explicit control of `lss.stamp.rootFoldDepth`
(plans/lss-root-fold-depth-qualified-spine.md). Needed because the two flags
interact: `rootFoldDepth` only acts when `rootFold` is on, since it governs
where the FOLDED id may be written.
-}
runWithDepth : Bool -> Bool -> Src.Module -> Result String Mono.MonoGraph
runWithDepth rootFold depthIds srcModule =
    let
        defaults =
            Config.defaultLss

        stamp0 =
            defaults.stamp
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults
            | enabled = True
            , keyed = True
            , regIdentity = True
            , rootFold = rootFold
            , stamp = { stamp0 | rootFoldDepth = depthIds }
        }
        srcModule


{-| The member ids of an annotation, or `[]` for anything that is not a set.
-}
annoMembers : Mono.LambdaSetAnno -> List Int
annoMembers a =
    case a of
        Mono.LSet ms ->
            ms

        _ ->
            []



-- ====== READERS ======


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


headAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
headAnnos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ anno _ _ ->
                    Just anno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


depth1Annos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
depth1Annos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ _ (Mono.MFunction _ rAnno _ _) ->
                    Just rAnno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


paramAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
paramAnnos target graph =
    List.concatMap
        (\t ->
            case t of
                Mono.MFunction _ _ args _ ->
                    List.filterMap
                        (\a ->
                            case a of
                                Mono.MFunction _ anno _ _ ->
                                    Just anno

                                _ ->
                                    Nothing
                        )
                        args

                _ ->
                    []
        )
        (demandsOf target graph)


singletonIds : List Mono.LambdaSetAnno -> List Int
singletonIds =
    List.filterMap
        (\a ->
            case a of
                Mono.LSet [ m ] ->
                    Just m

                _ ->
                    Nothing
        )


isSingleton : Mono.LambdaSetAnno -> Bool
isSingleton a =
    case a of
        Mono.LSet [ _ ] ->
            True

        _ ->
            False


isMulti : Mono.LambdaSetAnno -> Bool
isMulti a =
    case a of
        Mono.LSet ms ->
            List.length ms >= 2

        _ ->
            False


sizeAtMost : Int -> Mono.LambdaSetAnno -> Bool
sizeAtMost n a =
    case a of
        Mono.LSet ms ->
            List.length ms <= n

        _ ->
            True


annoSize : Mono.LambdaSetAnno -> Int
annoSize a =
    case a of
        Mono.LSet ms ->
            List.length ms

        Mono.LVar _ ->
            -1

        Mono.LTop _ ->
            -2

        Mono.LPartial _ ->
            -3


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


describe : List Mono.LambdaSetAnno -> String
describe annos =
    "["
        ++ String.join ", "
            (List.map
                (\a ->
                    case a of
                        Mono.LTop _ ->
                            "LTop"

                        Mono.LVar n ->
                            "LVar " ++ String.fromInt n

                        Mono.LSet ms ->
                            "LSet " ++ String.fromInt (List.length ms)

                        Mono.LPartial ms ->
                            "LPartial " ++ String.fromInt (List.length ms)
                )
                annos
            )
        ++ "]"
