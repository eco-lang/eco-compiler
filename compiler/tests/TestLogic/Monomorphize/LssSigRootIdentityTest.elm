module TestLogic.Monomorphize.LssSigRootIdentityTest exposing (suite)

{-| SOLVER-ROOT SIGNATURE IDENTITY — `lss.sigRootIdentity`
(`plans/lss-solver-root-signature-identity.md` §3.1).

**The claim.** The type checker already decided which arrows are the same
arrow: its union-find made a def's annotation arrow and the body arrow it was
checked against ONE class. LSS then threw that away and re-identified arrows by
syntactic OCCURRENCE, so a def's signature could not carry what its body knew.
This flag reinstates the checker's identity — the paper's `ζ = 𝓔(ξ)` (146:10),
set-variable equalities read off the type equalities — but ONLY inside the
inference scratch store, and ONLY as a memo key. Nothing is stamped into the
graph, which is why the artifact stays byte-identical flag-off.

**Two keys, not one.** The census keys on the OCCURRENCE id and the memo keys
on the ROOT. Collapsing them would corrupt every cross-arm census join in this
arc, whose join key is precisely the flag-independent occurrence id.

**The co-requirement, pinned here because it is a soundness one.** Root sharing
merges producer sets that occurrence identity kept apart, so a class can only
be trusted if EVERY producer flowing into it injected a member. `papMembers`
is what makes partial applications inject; without it, root sharing published
`{identity}` for a set with two inhabitants and devirt miscompiled `Task.map`
into the identity map. `sigRootIdentity` must therefore never run without
`papMembers` — section 3 pins the pair in the shape where that crash lived.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , ifExpr
        , intExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Id as Id
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.MonoSolver.Engine as Engine
import Compiler.MonoSolver.Store as Store
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "lss.sigRootIdentity — the checker's arrow identity, as a memo key"
        [ Test.describe "1. the store mechanism" storePins
        , Test.describe "2. the side table" tablePins
        , Test.describe "3. the papMembers co-requirement" coGatePins
        ]



-- ====== 1. STORE MECHANISM (ArrowIdentityTest precedent: drive loadTypeC) ======


intType : Can.Type TypeIds.MVarId
intType =
    Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Int" []


arrowWith : TypeIds.ArrowSlot -> Can.Type TypeIds.MVarId
arrowWith aid =
    Can.TLambda aid intType intType


firstId : TypeIds.ArrowId
firstId =
    TypeIds.firstArrowId


secondId : TypeIds.ArrowId
secondId =
    Id.succ TypeIds.firstArrowId


{-| `( Int -> Int, Int -> Int )` with DISTINCT occurrence ids — the shape the
graph always has, since `AssignMVarIds` stamps per occurrence. Whether these
two are the same arrow is exactly what the side table knows and the ids do not.
-}
distinctArrows : Can.Type TypeIds.MVarId
distinctArrows =
    Can.TTuple (arrowWith (TypeIds.Arrow firstId)) (arrowWith (TypeIds.Arrow secondId)) []


{-| Both occurrences map to ONE root: the checker unified them.
-}
sharedRoot : Dict.Dict Int Int
sharedRoot =
    Dict.fromList
        [ ( Id.toComparable firstId, -1 )
        , ( Id.toComparable secondId, -1 )
        ]


{-| `( ordinal positions, mints, both ordinals on ONE slot )` — the
`Store.elm` hit/miss contract, in the form ArrowIdentityTest pins it.
-}
shapeOf : Dict.Dict Int Int -> Bool -> Can.Type TypeIds.MVarId -> ( Int, Int, Bool )
shapeOf rootOf keyRoots canType =
    let
        ( _, c ) =
            Store.loadTypeC Dict.empty
                canType
                (Store.testLoadCtxRoots rootOf keyRoots True Dict.empty Engine.freshStore)

        slots =
            List.reverse c.arrowSlots
    in
    -- Nothing has been unified, so `pointKey` equality IS UF equivalence.
    ( List.length slots
    , c.slotsMinted
    , case List.map Engine.pointKey slots of
        [ a, b ] ->
            a == b

        _ ->
            False
    )


storePins : List Test
storePins =
    [ Test.test "two occurrences on one root share a slot: 2 positions, 1 mint" <|
        \() ->
            -- The ordinal array still holds TWO entries. A hit that skipped
            -- `arrowSlots` would shorten it and `applyFacts` would poison the
            -- instantiation silently; a hit that bumped `slotsMinted` would
            -- corrupt the dead-slot census.
            Expect.equal ( 2, 1, True ) (shapeOf sharedRoot True distinctArrows)
    , Test.test "flag OFF: the same table changes nothing" <|
        \() ->
            Expect.equal ( 2, 2, False ) (shapeOf sharedRoot False distinctArrows)
    , Test.test "no table entry: degrade to occurrence identity, both arms" <|
        \() ->
            -- Arrows that lost solver provenance keep the old behaviour
            -- exactly — the table is PARTIAL by construction.
            Expect.equal
                ( ( 2, 2, False ), ( 2, 2, False ) )
                ( shapeOf Dict.empty True distinctArrows
                , shapeOf Dict.empty False distinctArrows
                )
    , Test.test "distinct roots do NOT merge" <|
        \() ->
            let
                distinctRoots =
                    Dict.fromList
                        [ ( Id.toComparable firstId, -1 )
                        , ( Id.toComparable secondId, -2 )
                        ]
            in
            Expect.equal ( 2, 2, False ) (shapeOf distinctRoots True distinctArrows)
    , Test.test "an unstamped arrow is never root-keyed" <|
        \() ->
            -- `NoArrow` is the 0 sentinel and names nothing. Were it ever
            -- looked up, every unstamped arrow in a type would collapse into
            -- one slot. `memoKey == 0` iff `occKey == 0` keeps that guard
            -- intact after the key split.
            let
                unstamped =
                    Can.TTuple (arrowWith Can.noArrow) (arrowWith Can.noArrow) []
            in
            Expect.equal
                ( ( 2, 2, False ), ( 2, 2, False ) )
                ( shapeOf sharedRoot True unstamped, shapeOf sharedRoot False unstamped )
    ]



-- ====== 2. THE SIDE TABLE ======


tablePins : List Test
tablePins =
    [ Test.test "recordRootKey draws NEGATIVE keys and unifies occurrences the checker unified" <|
        \() ->
            -- Two properties in one assertion because they are one design
            -- decision: root keys come from their own negative supply, so
            -- occurrence-id numbering is untouched (the graph stays
            -- byte-identical — P1's gate) AND root keys can never collide
            -- with occurrence keys (>= 1) or the 0 sentinel.
            case Pipeline.runToMono refAsValueModule of
                Err e ->
                    Expect.fail e

                Ok { globalGraph } ->
                    let
                        ( _, st ) =
                            AssignMVarIds.assignIds False globalGraph

                        values =
                            Dict.values st.arrowRootOf

                        shared =
                            List.length values - List.length (unique values)
                    in
                    if List.isEmpty values then
                        Expect.fail "no arrow carried solver provenance — fixture broken"

                    else if List.any (\v -> v >= 0) values then
                        Expect.fail "a root key was non-negative: occurrence numbering is at risk"

                    else if shared < 1 then
                        Expect.fail
                            ("no two occurrences shared a root — the table records nothing the "
                                ++ "occurrence ids did not already say"
                            )

                    else
                        Expect.pass
    ]


unique : List Int -> List Int
unique xs =
    Dict.keys (List.foldl (\x acc -> Dict.insert x () acc) Dict.empty xs)



-- ====== NOTE: TRANSPORT IS NOT PINNED HERE, AND THE REASON IS MEASURED ======
--
-- §3.1 item 3 wanted a fixture whose signature gains a member flag-on. Three
-- instruments were built and all three MEASURED NEGATIVE, each for a different
-- and informative reason:
--
--  1. Assert at a CONSUMER's parameter annotation. Does not discriminate: the
--     call-argument transport already carries a member there within one
--     module, so both arms read `[LTop, LSet 1 1]`. Wrong instrument — that
--     position is a downstream consequence another mechanism also produces.
--  2. Assert on `sigfacts` (right instrument) with a producer that RETURNS a
--     lambda. Both arms read `Test.mkStep|0|m=1,l`: a def whose body IS a
--     lambda already names itself at ordinal 0 without root identity.
--  3. Assert on `sigfacts` with the corpus gainer's own shape — a plain
--     annotated def referenced as a VALUE (`applyTo double 3`, mirroring
--     `Mlir.Pretty.ppType|0|m=1,gc`). Both arms read ZERO rows: at this scale
--     every signature is TRIVIAL, and `censusSigFacts` emits nothing for a
--     trivial signature.
--
-- Together these bound where the effect is observable: it needs a def whose
-- signature is non-trivial AND whose identity arrives from outside its own
-- item — which is a cross-item property that a synthetic single-module fixture
-- does not reproduce. §3.1 anticipated exactly this ("the 969 measured gainers
-- are Builder/IO-chain shapes that resist minimization from first principles")
-- and sanctioned the fallback: the CORPUS `sigfacts` gate stands in, measured
-- 751 -> 1,825 rows over 857 newly-carrying defs.
--
-- What IS pinned here is the mechanism at both levels it exists at — the store
-- (section 1) and the side table (section 2) — plus the soundness co-gate
-- (section 3). A regression in the transport shows up as those pins breaking,
-- or as the corpus gate falling.


{-| A plain annotated function referenced as a VALUE — the shape of the corpus
gainers (`Mlir.Pretty.ppType|0|m=1,gc`). Used by the side-table pin as a module
that definitely produces solver-unified arrows.
-}
refAsValueModule : Src.Module
refAsValueModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "applyTo"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt (tLambda (tType "Int" []) (tType "Int" []))
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (varExpr "applyTo") [ varExpr "double", intExpr 3 ]
          }
        ]



-- ====== 3. THE papMembers CO-REQUIREMENT ======


coGatePins : List Test
coGatePins =
    [ Test.test "with roots shared, a one-sided join is STILL not a false singleton" <|
        \() ->
            -- `LssPapMembersTest`'s crash shape, re-run with root sharing on.
            -- Root identity is precisely what merged the producer sets in the
            -- recorded miscompile, so this is the pairing that has to hold:
            -- injection totality must survive the merge.
            case runWith True joinModule of
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
                                    ("a one-sided join published a singleton under root identity: "
                                        ++ describeAnnos annos
                                    )
    ]


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| `addTo 7` is a PARTIAL application; `idf` is a bare reference. Both must
inject, or the join at `useIt`'s parameter claims one inhabitant for a set with
two — the `Task.map`-becomes-identity miscompile.
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



-- ====== HARNESS ======


{-| `papMembers` rides with the flag ALWAYS — §2.3's co-requirement. There is
no arm of this feature that is licensed to run without it, so there is no
configuration here that offers one.
-}
runWith : Bool -> Src.Module -> Result String Mono.MonoGraph
runWith sigRootIdentity srcModule =
    Pipeline.runSolverMonoWithLimits Config.defaultLimits (lssConfig sigRootIdentity) srcModule


lssConfig : Bool -> Config.LssConfig
lssConfig sigRootIdentity =
    let
        defaults =
            Config.defaultLss
    in
    { defaults
        | enabled = True
        , keyed = True
        , papMembers = True
        , sigRootIdentity = sigRootIdentity
    }



-- ====== READERS (LssPapMembersTest precedent) ======


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


neverFalselyComplete : Mono.LambdaSetAnno -> Bool
neverFalselyComplete anno =
    case anno of
        Mono.LTop ->
            True

        Mono.LVar _ ->
            True

        Mono.LSet ms ->
            List.length ms >= 2


describeAnnos : List Mono.LambdaSetAnno -> String
describeAnnos annos =
    "[" ++ String.join ", " (List.map describeAnno annos) ++ "]"


describeAnno : Mono.LambdaSetAnno -> String
describeAnno anno =
    case anno of
        Mono.LTop ->
            "LTop"

        Mono.LVar n ->
            "LVar " ++ String.fromInt n

        Mono.LSet ms ->
            "LSet " ++ String.fromInt (List.length ms) ++ String.concat (List.map (\m -> " " ++ String.fromInt m) ms)
