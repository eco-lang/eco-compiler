module TestLogic.Monomorphize.GroundAliasMemoTest exposing (suite)

{-| Tests for the predicates and the key that decide which type alias
instantiations the monomorphization solver memoises, and for the memo that
reuses a type's loaded store structure within one store.

The solver memoises work on _ground, arrow-free_ alias instantiations: those
with no free type variable, no function arrow and no open record. Inside a
`Holey` alias body only an arrow counts: a type variable or open record there is
allowed, and the arguments are what count. Such an instantiation has the same
expansion at every occurrence, so `Store.loadTypeC` reuses the store structure of
its first load in the same store (the `groundLoads` map), and classification
caches its result for the whole run (the `aliasMemo` map). Both maps are keyed
by the _alias key_ that `Store.aliasKeyOf` builds from the alias's home, name
and argument types, leaving out the parameter ids paired with the arguments;
`Engine.AliasKey` says why the key must be structural. A predicate that admits
a type whose expansion can differ between occurrences, or a key that merges two
instantiations, would give wrong types with no error.

The fixture is built by hand as `Can.Type MVarId` values: `Int`, `String`,
type variables, one arrow `Int -> Int` stamped with the first `ArrowId`, closed
records and an open record. Three aliases are built with home `Main` of
`author/project`:

  - `State`, a `Filled` alias of `{ a : Int, b : String }`, built as two
    separate but equal values;
  - `Handler`, a `Filled` alias of `{ run : Int -> Int }`;
  - `Box`, a `Holey` alias with one parameter and the body `{ unbox : param }`,
    built with a chosen parameter id and argument.

The load tests drive `Store.loadTypeC` on a `Store.testLoadCtx` with lambda-set
specialization on, an empty arrow memo and a fresh store.

What the tests establish:

  - `groundNoArrow` is False for a type variable, the arrow, the open record, a
    closed record with an arrow field and a tuple holding the arrow, and True
    for `Int`, unit, the closed record of `State`, `State` and `Box Int`.
  - `groundNoArrow` is False for `Handler`, whose body reaches an arrow, and
    for `Box` applied to a type variable, and True for `Box Int` whose body
    holds its parameter.
  - `groundHash` is equal for the two `State` values and differs between `Int`
    and `String`.
  - `aliasKeyOf` gives `Box Int` the same key, under `Engine.aliasKeyEq` and
    `Engine.aliasKeyHash`, for parameter ids 1 and 5. Its keys for `Box Int`
    and `Box String` are not equal. Its key for argumentless `Box` differs from
    its keys for `Crate` and for `Box` with home elm/core `Basics`. It gives no
    key for `Box` applied to a type variable.
  - `aliasBodyEligible` accepts a `Filled` closed record of `Int` and a `Holey`
    body holding a type variable, and rejects either kind of body when it holds
    the arrow.
  - Loading `State` twice: the store holds more than three cells after the
    first load and exactly one more after the second. The two roots have
    different point keys and equal content, so the second root refers to the
    first load's child Points.
  - Loading `Handler` twice: the second load adds more than one cell, so the
    alias's structure was not reused. After both loads `arrowSlots` has two
    entries and `slotsMinted` is 1, because the second load finds the arrow's
    set slot in the arrow memo under the same `ArrowId`; that is the arrow
    memo's behaviour, not the `groundLoads` memo's.
  - Loading `Box Int`, `Box String`, then `Box Int` with another parameter id:
    the third load adds exactly one cell, and `groundLoads` holds two entries.
  - After two loads of `State` the var memo's size is unchanged, `slotsMinted`
    is 0 and `arrowSlots` is empty. `State` has no type variable and no arrow,
    so these hold whether or not the second load reuses the first.
  - `groundNoArrowWith` with the empty map of `Engine.emptyMonoMemo` answers
    from the alias bodies: True for `State` and False for `Handler`. A map that
    records `AliasIneligible` under `State`'s key makes it False for `State`,
    and one that records `AliasGround` under `Handler`'s key makes it True for
    `Handler`.

Among what is not tested: classification itself. Nothing here classifies a
type or inspects the intern table, so it is not checked that a classify-memo
hit returns the interned object a fresh classification would, that it leaves
the table unchanged, or that it gives the same result whatever kind of unknown
lambda set the caller asks arrows to carry. Nor are a `Holey` alias with
several parameters, loads with lambda-set specialization off, or the load entry
points that write back into the solver state.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Id as Id
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine
import Compiler.MonoSolver.Store as Store
import Compiler.Type.UnionFind as UF
import Compiler.Type.Vars as Vars
import Data.HashMap as HashMap
import Dict
import Eco.CellStore as CellStore
import Expect
import Test exposing (Test)



-- ====== FIXTURES ======


{-| The home of the test aliases and of all but one of the test keys, `Main`
of package `author/project`.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "project" ) "Main"


{-| elm/core's `Basics`, the home of `Int`, and a second home for an alias in
the key tests.
-}
core : ModuleName.Canonical
core =
    ModuleName.Canonical ( "elm", "core" ) "Basics"


{-| The type `Int`.
-}
intType : Can.Type TypeIds.MVarId
intType =
    Can.TType core "Int" []


{-| The type `String`.
-}
stringType : Can.Type TypeIds.MVarId
stringType =
    Can.TType (ModuleName.Canonical ( "elm", "core" ) "String") "String" []


{-| Returns the type variable id `n` steps after `TypeIds.firstMVarId`, so that
equal `n` give equal ids.
-}
mvar : Int -> TypeIds.MVarId
mvar n =
    List.foldl (\_ i -> Id.succ i) TypeIds.firstMVarId (List.range 1 n)


{-| Returns a type variable whose id is `mvar n`.
-}
varType : Int -> Can.Type TypeIds.MVarId
varType n =
    Can.TVar (mvar n)


{-| The function type `Int -> Int`, its arrow stamped with `TypeIds.firstArrowId`.
Every use of this value carries the same `ArrowId`, so a load's arrow memo
treats every use as one arrow.
-}
arrow : Can.Type TypeIds.MVarId
arrow =
    Can.TLambda (TypeIds.Arrow TypeIds.firstArrowId) intType intType


{-| Returns `t` as a record field type with field index 0.
-}
field : Can.Type TypeIds.MVarId -> Can.FieldType TypeIds.MVarId
field t =
    Can.FieldType 0 t


{-| Returns the closed record type with the given fields.
-}
record : List ( String, Can.Type TypeIds.MVarId ) -> Can.Type TypeIds.MVarId
record fs =
    Can.TRecord (Dict.fromList (List.map (\( k, t ) -> ( k, field t )) fs)) Nothing


{-| The open record type `{ a : Int }` extended by the type variable `mvar 9`.
-}
openRecord : Can.Type TypeIds.MVarId
openRecord =
    Can.TRecord (Dict.fromList [ ( "a", field intType ) ]) (Just (mvar 9))


{-| The alias `State`, with no parameters and the `Filled` body
`{ a : Int, b : String }`: a ground, arrow-free alias instantiation.
-}
groundAlias : Can.Type TypeIds.MVarId
groundAlias =
    Can.TAlias home "State" [] (Can.Filled (record [ ( "a", intType ), ( "b", stringType ) ]))


{-| The same `State` instantiation as `groundAlias`, equal to it but built as a
separate value, as a second occurrence of the alias would be.
-}
groundAliasAgain : Can.Type TypeIds.MVarId
groundAliasAgain =
    Can.TAlias home "State" [] (Can.Filled (record [ ( "a", intType ), ( "b", stringType ) ]))


{-| The alias `Handler`, with no parameters and the `Filled` body
`{ run : Int -> Int }`. Its body reaches an arrow, so neither its load nor its
classification is reused.
-}
arrowAlias : Can.Type TypeIds.MVarId
arrowAlias =
    Can.TAlias home "Handler" [] (Can.Filled (record [ ( "run", arrow ) ]))


{-| Returns the alias `Box argT`, whose one parameter has id `mvar pid` and whose
`Holey` body is `{ unbox : param }`. `pid` changes the parameter id paired with
the argument, which the alias key leaves out.
-}
boxOf : Int -> Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
boxOf pid argT =
    Can.TAlias home "Box" [ ( mvar pid, argT ) ] (Can.Holey (record [ ( "unbox", varType pid ) ]))


{-| The tests of the ground-alias predicates, the alias key, the per-store load
memo and `groundNoArrowWith`.
-}
suite : Test
suite =
    Test.describe "Step 4b — ground alias classify memo"
        [ Test.describe "groundHash / groundNoArrow eligibility"
            [ Test.test "a free var, an arrow and an open record each disqualify" <|
                \() ->
                    [ Store.groundNoArrow (varType 1)
                    , Store.groundNoArrow arrow
                    , Store.groundNoArrow openRecord
                    , Store.groundNoArrow (record [ ( "f", arrow ) ])
                    , Store.groundNoArrow (Can.TTuple intType arrow [])
                    ]
                        |> Expect.equalLists [ False, False, False, False, False ]
            , Test.test "ground types and a ground alias are eligible" <|
                \() ->
                    [ Store.groundNoArrow intType
                    , Store.groundNoArrow Can.TUnit
                    , Store.groundNoArrow (record [ ( "a", intType ), ( "b", stringType ) ])
                    , Store.groundNoArrow groundAlias
                    , Store.groundNoArrow (boxOf 1 intType)
                    ]
                        |> Expect.equalLists [ True, True, True, True, True ]
            , Test.test "an arrow in an alias BODY disqualifies, a var in one does not" <|
                \() ->
                    ( Store.groundNoArrow arrowAlias, Store.groundNoArrow (boxOf 3 intType) )
                        |> Expect.equal ( False, True )
            , Test.test "a Holey alias with a VAR argument is disqualified" <|
                \() ->
                    Store.groundNoArrow (boxOf 1 (varType 7)) |> Expect.equal False
            , Test.test "structurally equal occurrences hash equal; different ones differ" <|
                \() ->
                    let
                        a =
                            Store.groundHash groundAlias

                        b =
                            Store.groundHash groundAliasAgain
                    in
                    ( a == b, Store.groundHash intType == Store.groundHash stringType )
                        |> Expect.equal ( True, False )
            ]
        , Test.describe "aliasKeyOf"
            [ Test.test "drops the parameter ids: same instantiation, different binder ids, equal keys" <|
                \() ->
                    case ( Store.aliasKeyOf home "Box" [ ( mvar 1, intType ) ], Store.aliasKeyOf home "Box" [ ( mvar 5, intType ) ] ) of
                        ( Just ka, Just kb ) ->
                            ( Engine.aliasKeyEq ka kb, Engine.aliasKeyHash ka == Engine.aliasKeyHash kb )
                                |> Expect.equal ( True, True )

                        _ ->
                            Expect.fail "expected both keys to exist"
            , Test.test "separates instantiations by argument" <|
                \() ->
                    case ( Store.aliasKeyOf home "Box" [ ( mvar 1, intType ) ], Store.aliasKeyOf home "Box" [ ( mvar 1, stringType ) ] ) of
                        ( Just ka, Just kb ) ->
                            Engine.aliasKeyEq ka kb |> Expect.equal False

                        _ ->
                            Expect.fail "expected both keys to exist"
            , Test.test "separates aliases by name and by home" <|
                \() ->
                    case ( Store.aliasKeyOf home "Box" [], Store.aliasKeyOf home "Crate" [], Store.aliasKeyOf core "Box" [] ) of
                        ( Just a, Just b, Just c ) ->
                            ( Engine.aliasKeyEq a b, Engine.aliasKeyEq a c )
                                |> Expect.equal ( False, False )

                        _ ->
                            Expect.fail "expected all three keys to exist"
            , Test.test "refuses a non-ground argument" <|
                \() ->
                    Store.aliasKeyOf home "Box" [ ( mvar 1, varType 2 ) ]
                        |> Expect.equal Nothing
            ]
        , Test.describe "aliasBodyEligible"
            [ Test.test "ground Filled body yes, arrow-bearing body no" <|
                \() ->
                    ( Store.aliasBodyEligible (Can.Filled (record [ ( "a", intType ) ]))
                    , Store.aliasBodyEligible (Can.Filled (record [ ( "run", arrow ) ]))
                    )
                        |> Expect.equal ( True, False )
            , Test.test "a Holey body may contain vars (they are the parameters)" <|
                \() ->
                    ( Store.aliasBodyEligible (Can.Holey (record [ ( "unbox", varType 1 ) ]))
                    , Store.aliasBodyEligible (Can.Holey (record [ ( "run", arrow ) ]))
                    )
                        |> Expect.equal ( True, False )
            ]
        , Test.describe "4a — the per-item load memo"
            [ Test.test "a second load of one instantiation mints exactly ONE Point" <|
                \() ->
                    let
                        c0 =
                            Store.testLoadCtx True Dict.empty (Engine.freshStore ())

                        ( _, c1 ) =
                            Store.loadTypeC Dict.empty groundAlias c0

                        n1 =
                            cellCount c1

                        ( _, c2 ) =
                            Store.loadTypeC Dict.empty groundAliasAgain c1
                    in
                    -- The first load mints the root and the whole body; the
                    -- second mints only a root.
                    ( cellCount c2 - n1, n1 > 3 )
                        |> Expect.equal ( 1, True )
            , Test.test "the two roots are different Points over the SAME children" <|
                \() ->
                    let
                        c0 =
                            Store.testLoadCtx True Dict.empty (Engine.freshStore ())

                        ( p1, c1 ) =
                            Store.loadTypeC Dict.empty groundAlias c0

                        ( p2, c2 ) =
                            Store.loadTypeC Dict.empty groundAliasAgain c1
                    in
                    ( Engine.pointKey p1 == Engine.pointKey p2
                    , contentOf p1 c2 == contentOf p2 c2
                    )
                        -- distinct roots, identical content (the shared children)
                        |> Expect.equal ( False, True )
            , Test.test "an ineligible alias is re-loaded in full, and the ordinal contract is untouched" <|
                \() ->
                    let
                        c0 =
                            Store.testLoadCtx True Dict.empty (Engine.freshStore ())

                        ( _, c1 ) =
                            Store.loadTypeC Dict.empty arrowAlias c0

                        n1 =
                            cellCount c1

                        ( _, c2 ) =
                            Store.loadTypeC Dict.empty arrowAlias c1
                    in
                    -- More than one new Point: the alias's structure was not
                    -- reused. The two slot positions and one mint come from
                    -- the arrow memo, not from `groundLoads`: both loads
                    -- carry the same `ArrowId`, so the second reuses the
                    -- first's set slot.
                    ( cellCount c2 - n1 > 1, List.length c2.arrowSlots, c2.slotsMinted )
                        |> Expect.equal ( True, 2, 1 )
            , Test.test "instantiations are keyed apart: Box Int then Box String then Box Int" <|
                \() ->
                    let
                        c0 =
                            Store.testLoadCtx True Dict.empty (Engine.freshStore ())

                        ( _, c1 ) =
                            Store.loadTypeC Dict.empty (boxOf 1 intType) c0

                        ( _, c2 ) =
                            Store.loadTypeC Dict.empty (boxOf 1 stringType) c1

                        n2 =
                            cellCount c2

                        ( _, c3 ) =
                            Store.loadTypeC Dict.empty (boxOf 2 intType) c2
                    in
                    -- the third is a HIT on the first instantiation: one Point
                    ( cellCount c3 - n2, HashMap.size c3.groundLoads )
                        |> Expect.equal ( 1, 2 )
            , Test.test "the var memo and the mint counter are untouched by a hit" <|
                \() ->
                    let
                        c0 =
                            Store.testLoadCtx True Dict.empty (Engine.freshStore ())

                        ( _, c1 ) =
                            Store.loadTypeC Dict.empty groundAlias c0

                        ( _, c2 ) =
                            Store.loadTypeC Dict.empty groundAliasAgain c1
                    in
                    ( Dict.size c2.memo, c2.slotsMinted, List.length c2.arrowSlots )
                        |> Expect.equal ( Dict.size c1.memo, 0, 0 )
            ]
        , Test.describe "groundNoArrowWith answers from the verdict map"
            [ Test.test "an empty map falls back to the walk" <|
                \() ->
                    ( Store.groundNoArrowWith Engine.emptyMonoMemo.aliasMemo groundAlias
                    , Store.groundNoArrowWith Engine.emptyMonoMemo.aliasMemo arrowAlias
                    )
                        |> Expect.equal ( True, False )
            , Test.test "a recorded verdict is used instead of walking" <|
                \() ->
                    case Store.aliasKeyOf home "State" [] of
                        Nothing ->
                            Expect.fail "expected a key"

                        Just key ->
                            let
                                -- Contradicts the body, so the answer shows the map was read.
                                poisoned =
                                    HashMap.insert Engine.aliasKeyHash
                                        Engine.aliasKeyEq
                                        key
                                        Engine.AliasIneligible
                                        HashMap.empty
                            in
                            Store.groundNoArrowWith poisoned groundAlias
                                |> Expect.equal False
            , Test.test "a recorded AliasGround verdict short-circuits to True" <|
                \() ->
                    case Store.aliasKeyOf home "Handler" [] of
                        Nothing ->
                            Expect.fail "expected a key"

                        Just key ->
                            let
                                poisoned =
                                    HashMap.insert Engine.aliasKeyHash
                                        Engine.aliasKeyEq
                                        key
                                        (Engine.AliasGround Mono.MInt)
                                        HashMap.empty
                            in
                            -- arrowAlias would WALK to False; the verdict wins
                            Store.groundNoArrowWith poisoned arrowAlias
                                |> Expect.equal True
            ]
        ]


{-| Returns the number of cells in `c`'s point store, which is the number of
Points minted into it.
-}
cellCount : Store.LoadCtx -> Int
cellCount c =
    CellStore.size c.store.ioRefsPoint


{-| Returns the content of the root descriptor of `v`'s class in `c`'s store.
-}
contentOf : Vars.Variable -> Store.LoadCtx -> Vars.Content
contentOf v c =
    (Tuple.second (UF.get v c.store)).content
