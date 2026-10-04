module TestLogic.GlobalOpt.PreMonoFreshTest exposing (suite)

{-| Tests for `Compiler.GlobalOpt.PreMono.Fresh`, which gives identity to the
code a pre-monomorphization pass copies or creates.

When those passes run, every lambda already carries a source-lambda id
(`SrcLambdaId`), every function arrow in a type an arrow id (`ArrowId`), and
every type variable a program-wide id (`MVarId`), all handed out from the
supplies of an `AssignMVarIds.GlobalMVarState`, the _allocator_. Taking the
next id from a supply is called _minting_. A copy that keeps its original's
ids, or a copied type variable that loses its `number` constraint, raises no
error where it happens; `Compiler.GlobalOpt.PreMono.Fresh` states what a kept
id leads to.

The fixtures are typed-optimized expressions built by hand, not compiled from
source. The allocator the `freshenCopy` and `mintNewNode` tests start from,
`state0` (the `number` test through `numberVarState`), has its lambda and arrow
supplies moved on to 10, past the fixtures' hand-picked lambda ids 0 and 1 and
arrow ids 0 to 2, so a correctly minted id cannot coincide with an original
one. Its type variable supply stands at 1, because one variable was assigned
the first `MVarId`, which is the id the fixtures' type variables use. The ids
are read back by walkers written in this module, which descend only into
functions, calls and lists. The arrow id and type variable walkers read only
each expression's own type, not parameter types.

What the tests establish:

  - A copy of `\x -> \y -> x` has two lambda ids, neither of them one of the
    original's.
  - The original has at least one arrow id, and the copy has none of them.
  - Of two copies made one after the other, threading the allocator, the
    second has no lambda id of the first. Their arrow ids are not compared.
  - A copied type variable with no substitution is one variable with a new id,
    recorded in the returned allocator's `superVars` as `Vars.Number`, as the
    original was.
  - A type variable the substitution maps to `Int -> Int` with arrow id 99
    leaves the copy with no type variable and with arrow id 99 as its only
    arrow id.
  - `mintNewNode` gives a lambda that has no lambda id and no arrow id one of
    each. The test counts them and does not check their values.
  - Running `mintNewNode` again on its own result leaves the lambda ids and
    arrow ids as they were.
  - `assertMinted` returns `Ok` for a graph whose one definition is a lambda
    with lambda id 0 and arrow id 0.
  - `assertMinted` returns an `Err` for a lambda with no lambda id and no arrow
    id.
  - `assertMinted` returns an `Err` for a call of one lambda on another, both
    with lambda id 0 and arrow id 0. Only the `Err` is checked, so the test
    does not show which of the two repeats is caught.

Among what is not tested: `freshenType`; copying a `TrackedFunction`, a record,
an alias, a tuple or a record extension variable; the types of parameters and
`let` definitions, which the walkers do not read; `mintNewNode` on a
`SolverRoot` arrow; a repeated arrow id on its own; and any graph node other
than a single `Define`.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
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


{-| The `freshenCopy`, `mintNewNode` and `assertMinted` tests, as one suite.
-}
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


{-| The tests of `freshenCopy`: lambda and arrow ids in a copy, lambda ids in a
second copy, and what becomes of a type variable with and without a
substitution.
-}
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


{-| The tests of `mintNewNode`: that it gives an unminted lambda its ids, and
that a second run leaves its lambda and arrow ids as they were.
-}
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


{-| The tests of `assertMinted`, each on a graph built by `graphOf`: one
minted lambda passes, and a lambda with no ids and a repeated lambda both fail.
-}
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
                expectErr (Fresh.assertMinted (graphOf duplicatedLambda))
        ]


{-| Passes when `r` is `Ok`, and otherwise fails with the error message.
-}
expectOk : Result String () -> Expect.Expectation
expectOk r =
    case r of
        Ok () ->
            Expect.pass

        Err e ->
            Expect.fail ("expected Ok, got: " ++ e)


{-| Passes when `r` is an `Err`, whatever its message, and fails on `Ok`.
-}
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


{-| The allocator the `freshenCopy` and `mintNewNode` tests start from (the
`number` test through `numberVarState`), with its lambda and arrow supplies
past the ids the fixtures pick by hand.

It is the state `assignIdsToType` leaves after assigning one type variable,
which takes the first `MVarId`, so the next type variable minted is not the
fixtures' one. That state's lambda and arrow supplies are still at their first
ids, which the fixtures also use, so a correctly minted copy would share ids
with its original. Both supplies are moved on to 10.

-}
state0 : AssignMVarIds.GlobalMVarState
state0 =
    let
        seeded =
            Tuple.second (AssignMVarIds.assignIdsToType (Can.TVar "seed"))
    in
    { seeded | nextLam = nthLam 10, nextArrow = nthArrow 10 }


{-| `state0` with `originalNumberVar` recorded in `superVars` as a `number`
variable.
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


{-| The type variable the substitution test replaces. It is the first `MVarId`.
-}
originalVar : TypeIds.MVarId
originalVar =
    TypeIds.firstMVarId


{-| The type variable the `number` test copies. It is the first `MVarId`, the
same id as `originalVar`.
-}
originalNumberVar : TypeIds.MVarId
originalNumberVar =
    TypeIds.firstMVarId


{-| The type `Int` from `Basics`.
-}
intType : Can.Type TypeIds.MVarId
intType =
    Can.TType ModuleName.basics "Int" []


{-| Builds the function type `from -> to` with the arrow id `nthArrow n`.
-}
arrow : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Int -> Can.Type TypeIds.MVarId
arrow from to n =
    Can.TLambda (TypeIds.Arrow (nthArrow n)) from to


{-| Returns the arrow id `n` steps after the first, so `nthArrow 0` is the
first.
-}
nthArrow : Int -> TypeIds.ArrowId
nthArrow n =
    List.foldl (\_ a -> Id.succ a) TypeIds.firstArrowId (List.range 1 n)


{-| Returns the lambda id `n` steps after the first, so `nthLam 0` is the first.
-}
nthLam : Int -> TypeIds.SrcLambdaId
nthLam n =
    List.foldl (\_ a -> Id.succ a) TypeIds.firstSrcLambdaId (List.range 1 n)


{-| Builds expression metadata of type `t` with no solver variable.
-}
meta : Can.Type TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId
meta t =
    { tipe = t, tvar = Nothing }


{-| `\x -> \y -> x` at type `Int -> Int -> Int`, with lambda ids 0 and 1. The
outer lambda's type carries arrow ids 0 and 2, and the inner lambda's type
arrow id 1.
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


{-| A local variable `n` whose type is the type variable `originalNumberVar`.
-}
numberVarBody : TOpt.Expr TypeIds.MVarId
numberVarBody =
    TOpt.VarLocal "n" (meta (Can.TVar originalNumberVar))


{-| A local variable `v` whose type is the type variable `originalVar`.
-}
varTypedBody : TOpt.Expr TypeIds.MVarId
varTypedBody =
    TOpt.VarLocal "v" (meta (Can.TVar originalVar))


{-| The type the substitution test puts in place of `originalVar`: `Int -> Int`
with arrow id 99, which the test expects to find unchanged in the copy.
-}
callSiteArrowType : Can.Type TypeIds.MVarId
callSiteArrowType =
    arrow intType intType 99


{-| A local variable of type `callSiteArrowType`, from which the substitution
test reads the arrow ids it expects.
-}
callSiteArrowType_asExpr : TOpt.Expr TypeIds.MVarId
callSiteArrowType_asExpr =
    TOpt.VarLocal "v" (meta callSiteArrowType)


{-| `\x -> x` at type `Int -> Int` with no lambda id, and with an arrow that has
no arrow id (`NoArrow`, from `Can.tLambda`).
-}
unmintedLambda : TOpt.Expr TypeIds.MVarId
unmintedLambda =
    TOpt.Function Nothing
        [ ( "x", intType ) ]
        (TOpt.VarLocal "x" (meta intType))
        (meta (Can.tLambda intType intType))


{-| Builds `\x -> x` at type `Int -> Int` with lambda id 0 and arrow id 0.
-}
mintedLambda : () -> TOpt.Expr TypeIds.MVarId
mintedLambda () =
    TOpt.Function (Just (nthLam 0))
        [ ( "x", intType ) ]
        (TOpt.VarLocal "x" (meta intType))
        (meta (arrow intType intType 0))


{-| A call of `mintedLambda` on a second `mintedLambda`: two lambdas that share
lambda id 0 and also share arrow id 0, as a copy that kept its original's ids
would.
-}
duplicatedLambda : TOpt.Expr TypeIds.MVarId
duplicatedLambda =
    TOpt.Call A.zero
        (mintedLambda ())
        [ mintedLambda () ]
        (meta intType)


{-| Builds a global graph whose one node defines `Basics.probe` as `expr`, with
every other table of the graph empty.
-}
graphOf : TOpt.Expr TypeIds.MVarId -> TOpt.GlobalGraph TypeIds.MVarId
graphOf expr =
    TOpt.GlobalGraph
        (DMap.singleton TOpt.toComparableGlobal
            (TOpt.Global ModuleName.basics "probe")
            (TOpt.Define expr EverySet.empty (meta intType))
        )
        Dict.empty
        DMap.empty
        DMap.empty
        Dict.empty



-- ============================================================================
-- WALKERS (test-local; deliberately independent of the module under test)
-- ============================================================================


{-| Returns the lambda ids, as `Id.toComparable` keys, of `expr` and of every
sub-expression `kids` reaches, outermost first. A lambda with no id adds
nothing.
-}
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


{-| Returns the arrow ids found by `arrowIdsOfType` in the type of `expr` and of
every sub-expression `kids` reaches. Parameter types are not read.
-}
arrowIds : TOpt.Expr TypeIds.MVarId -> List Int
arrowIds expr =
    arrowIdsOfType (TOpt.typeOf expr) ++ List.concatMap arrowIds (kids expr)


{-| Returns the arrow ids in `t`, as `Id.toComparable` keys, looking inside
arrows, type arguments and tuples. An arrow with no id adds nothing of its own,
and records and aliases add nothing at all.
-}
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


{-| Returns the type variable ids found by `typeVarsOfType` in the type of
`expr` and of every sub-expression `kids` reaches, with repeats kept.
-}
typeVarsOf : TOpt.Expr TypeIds.MVarId -> List Int
typeVarsOf expr =
    typeVarsOfType (TOpt.typeOf expr) ++ List.concatMap typeVarsOf (kids expr)


{-| Returns the type variable ids in `t`, as `Id.toComparable` keys, looking
inside arrows, type arguments and tuples. Records and aliases add nothing.
-}
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


{-| Returns the sub-expressions the walkers descend into: a function's body, a
call's function and arguments, and a list's items. Any other expression is
treated as having none, which holds for every fixture in this module.
-}
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
