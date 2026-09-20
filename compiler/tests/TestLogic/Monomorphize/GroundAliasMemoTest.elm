module TestLogic.Monomorphize.GroundAliasMemoTest exposing (suite)

{-| Step 4b — the per-run classify memo for ground, arrow-free alias
instantiations, and the eligibility predicate it is keyed on.

The memo exists because the compiler re-classifies the same alias occurrence
thousands of times. `S`, its own 31-field state record, is re-walked node by
node with an intern probe per node at every occurrence, and every one of those
walks produces the same canonical `MonoType`.

What has to be true for that to be sound, and is pinned below:

1.  **The key is structural, and drops parameter ids.** Two occurrences of one
    alias are two distinct object trees — `AssignMVarIds` rebuilds every node
    per occurrence — so identity is useless and the key must be
    `(home, name, args)`. The param ids paired with the args are per-def binder
    ids, not identity, so two occurrences differing only in those ids must
    produce EQUAL keys.

2.  **Eligibility excludes anything an arrow or a var could reach.** A free
    var, an arrow anywhere, or an open record disqualifies the occurrence; a
    var inside an alias BODY does not, because there it is a parameter.

3.  **A hit is indistinguishable from a re-walk.** The stored value came out of
    the intern table, so it is the same object a fresh probe would return, and
    a hit must not grow the table.

4.  **A hit ignores `topKind`.** That argument is read only by the arrow arm,
    which an eligible type never reaches — so classifying one instantiation
    under two different kinds must give the same object.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Id as Id
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine
import Compiler.MonoSolver.Store as Store
import Compiler.Type.UnionFind as UF
import Compiler.Type.Vars as Vars
import Eco.CellStore as CellStore
import Data.HashMap as HashMap
import Dict
import Expect
import Test exposing (Test)



-- ====== FIXTURES ======


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "project" ) "Main"


core : ModuleName.Canonical
core =
    ModuleName.Canonical ( "elm", "core" ) "Basics"


intType : Can.Type TypeIds.MVarId
intType =
    Can.TType core "Int" []


stringType : Can.Type TypeIds.MVarId
stringType =
    Can.TType (ModuleName.Canonical ( "elm", "core" ) "String") "String" []


mvar : Int -> TypeIds.MVarId
mvar n =
    List.foldl (\_ i -> Id.succ i) TypeIds.firstMVarId (List.range 1 n)


varType : Int -> Can.Type TypeIds.MVarId
varType n =
    Can.TVar (mvar n)


arrow : Can.Type TypeIds.MVarId
arrow =
    Can.TLambda (TypeIds.Arrow TypeIds.firstArrowId) intType intType


field : Can.Type TypeIds.MVarId -> Can.FieldType TypeIds.MVarId
field t =
    Can.FieldType 0 t


record : List ( String, Can.Type TypeIds.MVarId ) -> Can.Type TypeIds.MVarId
record fs =
    Can.TRecord (Dict.fromList (List.map (\( k, t ) -> ( k, field t )) fs)) Nothing


openRecord : Can.Type TypeIds.MVarId
openRecord =
    Can.TRecord (Dict.fromList [ ( "a", field intType ) ]) (Just (mvar 9))


{-| A closed, ground record alias — the `S` shape in miniature.
-}
groundAlias : Can.Type TypeIds.MVarId
groundAlias =
    Can.TAlias home "State" [] (Can.Filled (record [ ( "a", intType ), ( "b", stringType ) ]))


{-| Same alias, rebuilt as a distinct object tree — what a second occurrence is.
-}
groundAliasAgain : Can.Type TypeIds.MVarId
groundAliasAgain =
    Can.TAlias home "State" [] (Can.Filled (record [ ( "a", intType ), ( "b", stringType ) ]))


{-| An alias whose body reaches an arrow: never memoisable.
-}
arrowAlias : Can.Type TypeIds.MVarId
arrowAlias =
    Can.TAlias home "Handler" [] (Can.Filled (record [ ( "run", arrow ) ]))


{-| `Box a` applied to a ground argument, with the param bound as a Holey body.
`pid` is the parameter's binder id, which the key must ignore.
-}
boxOf : Int -> Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
boxOf pid argT =
    Can.TAlias home "Box" [ ( mvar pid, argT ) ] (Can.Holey (record [ ( "unbox", varType pid ) ]))


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
                    -- The first load mints the root plus the whole body; the
                    -- second mints the root and nothing else.
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
                    -- More than one new Point: no sharing happened. Two slot
                    -- POSITIONS and ONE mint is the pre-existing Phase-2a
                    -- ordinal contract, not an effect of this step — both loads
                    -- carry the same `ArrowId`, so they share the slot. The
                    -- point of the assertion is that step 4a left those numbers
                    -- exactly where `ArrowIdentityTest` pins them.
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
                                -- Deliberately contradict the walk: if the map is
                                -- consulted, the answer flips.
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


{-| Number of cells in the load context's store — the Point count.
-}
cellCount : Store.LoadCtx -> Int
cellCount c =
    CellStore.size c.store.ioRefsPoint


contentOf : Vars.Variable -> Store.LoadCtx -> Vars.Content
contentOf v c =
    (Tuple.second (UF.get v c.store)).content
