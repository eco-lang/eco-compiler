module TestLogic.Monomorphize.LssLPartialTest exposing (suite)

{-| LPARTIAL — the asymmetry-tolerant join
(plans/lss-lpartial-asymmetric-join.md).

`LPartial members` = the paper's Q-accumulation state: "at least these
members; possibly more" — a lower bound. Three rules, each pinned:

  - PRODUCER: `unionAnno (LSet, LVar) → LPartial` (formerly ⊤conflict —
    the L7 tax, measured +45/+46/+46 across three mechanisms).
  - AR-P6: a complete side does NOT restore completeness —
    `LSet ∪ LPartial = LPartial`.
  - GUARDS: never a singleton (devirt), identity-blind (hash/keys).

-}

import Compiler.AST.Monomorphized as Mono
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "LPartial — asymmetry-tolerant join"
        [ Test.test "1. PRODUCER: set × var joins to partial, both directions, members kept" <|
            \() ->
                Expect.equal
                    [ Mono.unionAnno (Mono.LSet [ 3, 7 ]) (Mono.LVar 9)
                    , Mono.unionAnno (Mono.LVar 9) (Mono.LSet [ 3, 7 ])
                    ]
                    [ Mono.LPartial [ 3, 7 ]
                    , Mono.LPartial [ 3, 7 ]
                    ]
        , Test.test "2. AR-P6: a complete side does NOT restore completeness" <|
            \() ->
                Expect.equal
                    [ Mono.unionAnno (Mono.LSet [ 1 ]) (Mono.LPartial [ 2 ])
                    , Mono.unionAnno (Mono.LPartial [ 2 ]) (Mono.LSet [ 1 ])
                    , Mono.unionAnno (Mono.LPartial [ 1 ]) (Mono.LPartial [ 2 ])
                    , Mono.unionAnno (Mono.LPartial [ 1 ]) (Mono.LVar 4)
                    ]
                    [ Mono.LPartial [ 1, 2 ]
                    , Mono.LPartial [ 1, 2 ]
                    , Mono.LPartial [ 1, 2 ]
                    , Mono.LPartial [ 1 ]
                    ]
        , Test.test "3. ⊤ still absorbs a partial (definitely-unknown flows cap the position)" <|
            \() ->
                Expect.equal
                    [ Mono.isTopAnno (Mono.unionAnno (Mono.LPartial [ 1 ]) Mono.topPoison)
                    , Mono.isTopAnno (Mono.unionAnno Mono.topPoison (Mono.LPartial [ 1 ]))
                    ]
                    [ True, True ]
        , Test.test "4. GUARD: a partial singleton is never a devirt singleton" <|
            \() ->
                Expect.equal
                    (Mono.singletonHeadMember (Mono.mFunction (Mono.LPartial [ 5 ]) [ Mono.MInt ] Mono.MInt))
                    Nothing
        , Test.test "5. IDENTITY-BLIND: partial hashes and keys exactly as the same-membered set" <|
            \() ->
                let
                    setTy =
                        Mono.mFunction (Mono.LSet [ 5, 9 ]) [ Mono.MInt ] Mono.MInt

                    partTy =
                        Mono.mFunction (Mono.LPartial [ 5, 9 ]) [ Mono.MInt ] Mono.MInt
                in
                Expect.equal
                    [ Mono.toComparableMonoType setTy == Mono.toComparableMonoType partTy
                    , Mono.eqLayout setTy partTy
                    ]
                    [ True, True ]
        , Test.test "5b. LSS_010 LAW: annoCovers decides exactly unionAnno a b == a (partial arms)" <|
            \() ->
                let
                    law a b =
                        Mono.annoCovers a b == (Mono.unionAnno a b == a)

                    cases =
                        [ ( Mono.LPartial [ 1, 2 ], Mono.LVar 5 )
                        , ( Mono.LPartial [ 1, 2 ], Mono.LPartial [ 1 ] )
                        , ( Mono.LPartial [ 1 ], Mono.LPartial [ 1, 2 ] )
                        , ( Mono.LPartial [ 1, 2 ], Mono.LSet [ 2 ] )
                        , ( Mono.LPartial [ 1 ], Mono.LSet [ 2 ] )
                        , ( Mono.LPartial [ 1 ], Mono.topPoison )
                        , ( Mono.LSet [ 1 ], Mono.LPartial [ 1 ] )
                        , ( Mono.LVar 3, Mono.LPartial [ 1 ] )
                        , ( Mono.topPoison, Mono.LPartial [ 1 ] )
                        ]
                in
                Expect.equal (List.map (\( a, b ) -> law a b) cases) (List.repeat 9 True)
        , Test.test "6. enrich never upgrades partial to set (readback discipline)" <|
            \() ->
                let
                    partBase =
                        Mono.mFunction (Mono.LPartial [ 1 ]) [ Mono.MInt ] Mono.MInt

                    setSrc =
                        Mono.mFunction (Mono.LSet [ 2 ]) [ Mono.MInt ] Mono.MInt
                in
                Expect.equal
                    (Mono.headAnno (Mono.enrichAnnotations partBase setSrc))
                    (Mono.LPartial [ 1, 2 ])
        ]
