module TestLogic.Monomorphize.LssLPartialTest exposing (suite)

{-| Pins the rules for `LPartial`, the lambda-set annotation that means "at least
these members, possibly more". If a change let a partial annotation become a
complete set, a list of members would be read as complete when other functions
may also reach that position, and the Elm type checker could not catch it,
because both are constructors of the same type.

A lambda-set annotation sits on a function arrow in a `MonoType` and records
which functions a value of that type may be, each named by an integer member id.
`Compiler.AST.Monomorphized` owns the annotation type and its rules. The four
forms used here are `LSet`, exactly the listed members; `LPartial`, a lower
bound; `LVar`, a set not yet known; and `LTop`, an unknown set, written here
with the constant `topPoison`. The fixtures are these annotations built by hand,
some on their own and some as the head annotation of an `Int -> Int` function
type made with `mFunction`.

What the tests establish:

  - `unionAnno` of `LSet [ 3, 7 ]` and `LVar 9`, in either order, is
    `LPartial [ 3, 7 ]`.
  - `unionAnno` of `LSet [ 1 ]` and `LPartial [ 2 ]`, in either order, and of
    `LPartial [ 1 ]` and `LPartial [ 2 ]`, is `LPartial [ 1, 2 ]`: a complete
    side does not make the result complete. `unionAnno` of `LPartial [ 1 ]` and
    `LVar 4` is `LPartial [ 1 ]`.
  - `unionAnno` of `LPartial [ 1 ]` and `topPoison`, in either order, is an
    `LTop`, as `isTopAnno` reads it.
  - `singletonHeadMember` gives `Nothing` for a function type whose head
    annotation is `LPartial [ 5 ]`, so a one-member partial is not treated as
    a function value known to be that one member.
  - Function types headed by `LSet [ 5, 9 ]` and by `LPartial [ 5, 9 ]` have
    the same `toComparableMonoType` key, and `eqLayout` holds between them.
    `eqLayout` ignores arrow annotations altogether, so that second assertion
    says nothing particular to `LPartial`.
  - For nine pairs with an `LPartial` on one side or both, `annoCovers a b`
    equals `unionAnno a b == a`. The left-hand partials are paired with an
    `LVar`, a smaller and a larger partial, a set inside and a set outside
    them, and `topPoison`; the right-hand partials with an `LSet`, an `LVar`
    and `topPoison`.
  - `enrichAnnotations` with a base headed by `LPartial [ 1 ]` and a source
    headed by `LSet [ 2 ]` gives a head annotation of `LPartial [ 1, 2 ]`.

Among what is not tested: hashing (`specHashOf`) of a partial against the
same-membered set, despite the fifth test's title; `eqKeySpec` on partials;
`enrichAnnotations` with an `LSet` base and an `LPartial` source, or any other
base; and `unionAnno` of two `LSet`s.

-}

import Compiler.AST.Monomorphized as Mono
import Expect
import Test exposing (Test)


{-| The `LPartial` annotation rules as one group of tests.
-}
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
