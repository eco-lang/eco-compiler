module TestLogic.GlobalOpt.PreMonoFreshTest exposing (suite)

{-| `Compiler.GlobalOpt.PreMono.Fresh` — the one place a pre-monomorphization
pass mints identity (`plans/pre-mono-lss-transforms-00-assign-mvar-ids-first.md`
§6).

What is pinned here is the property the whole item rests on: after
`AssignMVarIds` moved in front of the pre-mono passes, identity EXISTS while
those passes run, so a copy that keeps its ids puts two bodies under one member
— LSS\_009 impersonation, a silent wrong answer rather than a crash. These tests
assert that a copy shares NO lambda id and NO arrow id with its original, that
an unsubstituted type variable is re-minted WITH its supertype constraint, that
a substituted one is spliced verbatim, and that `assertMinted` rejects both an
unminted node and a REPEATED id.

The fixtures are built directly rather than through the source pipeline: this
module is about the id allocator, and a hand-built graph is the only way to
construct the duplicate-id case that `assertMinted` exists to catch.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.PreMono.Fresh as Fresh
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Reporting.Annotation as A
import Compiler.Type.Vars as Vars
import Data.Map as DMap
import Data.Set as EverySet
import Dict
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "PreMono.Fresh"
        [ freshenCopySuite
        , mintNewNodeSuite
        , assertMintedSuite
        ]



-- ============================================================================
-- freshenCopy
-- ============================================================================


freshenCopySuite : Test
freshenCopySuite =
    Test.describe "freshenCopy"
        [ Test.test "a copy shares no lambda id with its original" <|
            \_ ->
                let
                    ( copy, _ ) =
                        Fresh.freshenCopy Dict.empty state0 twoLambdaBody

                    originals =
                        lamIds twoLambdaBody

                    copied =
                        lamIds copy
                in
                Expect.equal ( 2, 2, [] )
                    ( List.length originals
                    , List.length copied
                    , List.filter (\i -> List.member i originals) copied
                    )
        , Test.test "a copy shares no arrow id with its original" <|
            \_ ->
                let
                    ( copy, _ ) =
                        Fresh.freshenCopy Dict.empty state0 twoLambdaBody

                    originals =
                        arrowIds twoLambdaBody

                    copied =
                        arrowIds copy
                in
                Expect.equal ( True, [] )
                    ( List.length originals > 0
                    , List.filter (\i -> List.member i originals) copied
                    )
        , Test.test "two copies share nothing with each other" <|
            \_ ->
                let
                    ( copyA, state1 ) =
                        Fresh.freshenCopy Dict.empty state0 twoLambdaBody

                    ( copyB, _ ) =
                        Fresh.freshenCopy Dict.empty state1 twoLambdaBody
                in
                Expect.equal []
                    (List.filter (\i -> List.member i (lamIds copyA)) (lamIds copyB))
        , Test.test "an unsubstituted variable is re-minted WITH its super" <|
            \_ ->
                -- `withRenamedSupers` used to re-key `varSupers` by NAME; the
                -- copy now carries the constraint by ID. Losing it would let a
                -- `number` default differently in the copy — silent, not a type
                -- error.
                let
                    ( copy, state1 ) =
                        Fresh.freshenCopy Dict.empty numberVarState numberVarBody

                    copiedVars =
                        typeVarsOf copy
                in
                case copiedVars of
                    [ v ] ->
                        Expect.equal ( True, Just Vars.Number )
                            ( v /= Id.toComparable originalNumberVar
                            , Dict.get v state1.superVars
                            )

                    other ->
                        Expect.fail ("expected exactly one copied type variable, got " ++ String.fromInt (List.length other))
        , Test.test "a substituted variable becomes the call site's type, arrows unchanged" <|
            \_ ->
                let
                    subst =
                        Dict.singleton (Id.toComparable originalVar) callSiteArrowType

                    ( copy, _ ) =
                        Fresh.freshenCopy subst state0 varTypedBody
                in
                Expect.equal ( [], arrowIds callSiteArrowType_asExpr )
                    ( typeVarsOf copy, arrowIds copy )
        ]



-- ============================================================================
-- mintNewNode
-- ============================================================================


mintNewNodeSuite : Test
mintNewNodeSuite =
    Test.describe "mintNewNode"
        [ Test.test "assigns identity to a created lambda and arrow" <|
            \_ ->
                let
                    ( minted, _ ) =
                        Fresh.mintNewNode state0 unmintedLambda
                in
                Expect.equal ( 1, 1 )
                    ( List.length (lamIds minted), List.length (arrowIds minted) )
        , Test.test "is idempotent — existing identity is left alone" <|
            \_ ->
                let
                    ( once, state1 ) =
                        Fresh.mintNewNode state0 unmintedLambda

                    ( twice, _ ) =
                        Fresh.mintNewNode state1 once
                in
                Expect.equal ( lamIds once, arrowIds once )
                    ( lamIds twice, arrowIds twice )
        ]



-- ============================================================================
-- assertMinted
-- ============================================================================


assertMintedSuite : Test
assertMintedSuite =
    Test.describe "assertMinted"
        [ Test.test "accepts a fully minted graph" <|
            \_ ->
                expectOk (Fresh.assertMinted (graphOf (mintedLambda ())))
        , Test.test "rejects a lambda with no id" <|
            \_ ->
                expectErr (Fresh.assertMinted (graphOf unmintedLambda))
        , Test.test "rejects a REPEATED lambda id — the copy-without-mint case" <|
            \_ ->
                -- The check that earns its keep. A missing id declines visibly
                -- as `g1absentl`; a repeated one is two bodies under one member
                -- and no presence check can see it.
                expectErr (Fresh.assertMinted (graphOf duplicatedLambda))
        ]


expectOk : Result String () -> Expect.Expectation
expectOk r =
    case r of
        Ok () ->
            Expect.pass

        Err e ->
            Expect.fail ("expected Ok, got: " ++ e)


expectErr : Result String () -> Expect.Expectation
expectErr r =
    case r of
        Ok () ->
            Expect.fail "expected the validator to reject this graph"

        Err _ ->
            Expect.pass



-- ============================================================================
-- FIXTURES
-- ============================================================================


{-| An allocator whose supplies START PAST the ids the fixtures hand-pick.

Without this the test is vacuous in the worst way: `assignIdsToType` leaves
`nextLam`/`nextArrow` at `first*`, the fixtures use ids 0..2, and a genuinely
fresh mint hands back exactly those — so a copy that minted correctly would
still "share ids with its original" and the test would fail while the module is
right. Advancing the supplies makes original and copy ranges disjoint, which is
what the assertions are actually about.

-}
state0 : AssignMVarIds.GlobalMVarState
state0 =
    let
        seeded =
            Tuple.second (AssignMVarIds.assignIdsToType (Can.TVar "seed"))
    in
    { seeded | nextLam = nthLam 10, nextArrow = nthArrow 10 }


{-| A state whose `superVars` marks `originalNumberVar` as a `number`.
-}
numberVarState : AssignMVarIds.GlobalMVarState
numberVarState =
    let
        st =
            state0
    in
    { st
        | superVars =
            Dict.insert (Id.toComparable originalNumberVar) Vars.Number st.superVars
    }


originalVar : TypeIds.MVarId
originalVar =
    TypeIds.firstMVarId


originalNumberVar : TypeIds.MVarId
originalNumberVar =
    TypeIds.firstMVarId


intType : Can.Type TypeIds.MVarId
intType =
    Can.TType ModuleName.basics "Int" []


arrow : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Int -> Can.Type TypeIds.MVarId
arrow from to n =
    Can.TLambda (TypeIds.Arrow (nthArrow n)) from to


nthArrow : Int -> TypeIds.ArrowId
nthArrow n =
    List.foldl (\_ a -> Id.succ a) TypeIds.firstArrowId (List.range 1 n)


nthLam : Int -> TypeIds.SrcLambdaId
nthLam n =
    List.foldl (\_ a -> Id.succ a) TypeIds.firstSrcLambdaId (List.range 1 n)


meta : Can.Type TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId
meta t =
    { tipe = t, tvar = Nothing }


{-| `\x -> \y -> x` — two lambdas, three arrows.
-}
twoLambdaBody : TOpt.Expr TypeIds.MVarId
twoLambdaBody =
    TOpt.Function (Just (nthLam 0))
        [ ( "x", intType ) ]
        (TOpt.Function (Just (nthLam 1))
            [ ( "y", intType ) ]
            (TOpt.VarLocal "x" (meta intType))
            (meta (arrow intType intType 1))
        )
        (meta (arrow intType (arrow intType intType 2) 0))


{-| A body whose only type is the variable under test.
-}
numberVarBody : TOpt.Expr TypeIds.MVarId
numberVarBody =
    TOpt.VarLocal "n" (meta (Can.TVar originalNumberVar))


varTypedBody : TOpt.Expr TypeIds.MVarId
varTypedBody =
    TOpt.VarLocal "v" (meta (Can.TVar originalVar))


{-| The call site's type for the substitution test: an arrow with ids that must
survive the splice untouched.
-}
callSiteArrowType : Can.Type TypeIds.MVarId
callSiteArrowType =
    arrow intType intType 99


callSiteArrowType_asExpr : TOpt.Expr TypeIds.MVarId
callSiteArrowType_asExpr =
    TOpt.VarLocal "v" (meta callSiteArrowType)


unmintedLambda : TOpt.Expr TypeIds.MVarId
unmintedLambda =
    TOpt.Function Nothing
        [ ( "x", intType ) ]
        (TOpt.VarLocal "x" (meta intType))
        (meta (Can.tLambda intType intType))


mintedLambda : () -> TOpt.Expr TypeIds.MVarId
mintedLambda () =
    TOpt.Function (Just (nthLam 0))
        [ ( "x", intType ) ]
        (TOpt.VarLocal "x" (meta intType))
        (meta (arrow intType intType 0))


{-| Two lambdas carrying the SAME id — what a copy that forgot to mint produces.
-}
duplicatedLambda : TOpt.Expr TypeIds.MVarId
duplicatedLambda =
    TOpt.Call A.zero
        (mintedLambda ())
        [ mintedLambda () ]
        (meta intType)


graphOf : TOpt.Expr TypeIds.MVarId -> TOpt.GlobalGraph TypeIds.MVarId
graphOf expr =
    TOpt.GlobalGraph
        (DMap.singleton TOpt.toComparableGlobal
            (TOpt.Global ModuleName.basics "probe")
            (TOpt.Define expr (EverySet.empty) (meta intType))
        )
        Dict.empty
        DMap.empty
        DMap.empty
        Dict.empty



-- ============================================================================
-- WALKERS (test-local; deliberately independent of the module under test)
-- ============================================================================


lamIds : TOpt.Expr TypeIds.MVarId -> List Int
lamIds expr =
    (case expr of
        TOpt.Function (Just l) _ _ _ ->
            [ Id.toComparable l ]

        TOpt.TrackedFunction (Just l) _ _ _ ->
            [ Id.toComparable l ]

        _ ->
            []
    )
        ++ List.concatMap lamIds (kids expr)


arrowIds : TOpt.Expr TypeIds.MVarId -> List Int
arrowIds expr =
    arrowIdsOfType (TOpt.typeOf expr) ++ List.concatMap arrowIds (kids expr)


arrowIdsOfType : Can.Type TypeIds.MVarId -> List Int
arrowIdsOfType t =
    case t of
        Can.TLambda (TypeIds.Arrow a) from to ->
            Id.toComparable a :: (arrowIdsOfType from ++ arrowIdsOfType to)

        Can.TLambda _ from to ->
            arrowIdsOfType from ++ arrowIdsOfType to

        Can.TType _ _ args ->
            List.concatMap arrowIdsOfType args

        Can.TTuple a b rest ->
            arrowIdsOfType a ++ arrowIdsOfType b ++ List.concatMap arrowIdsOfType rest

        _ ->
            []


typeVarsOf : TOpt.Expr TypeIds.MVarId -> List Int
typeVarsOf expr =
    typeVarsOfType (TOpt.typeOf expr) ++ List.concatMap typeVarsOf (kids expr)


typeVarsOfType : Can.Type TypeIds.MVarId -> List Int
typeVarsOfType t =
    case t of
        Can.TVar v ->
            [ Id.toComparable v ]

        Can.TLambda _ from to ->
            typeVarsOfType from ++ typeVarsOfType to

        Can.TType _ _ args ->
            List.concatMap typeVarsOfType args

        Can.TTuple a b rest ->
            typeVarsOfType a ++ typeVarsOfType b ++ List.concatMap typeVarsOfType rest

        _ ->
            []


kids : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
kids expr =
    case expr of
        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Call _ f args _ ->
            f :: args

        TOpt.List _ items _ ->
            items

        _ ->
            []
