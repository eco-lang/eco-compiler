module TestLogic.Monomorphize.AbiCloningPapFastPassTest exposing (suite)

{-| Pins which call sites the `AbiCloning` pass gives a fast PAP stamp, and
what the stamp records. A stamp naming the wrong spec would call code that reads
the bound arguments at the wrong kind, and a stamp that rewrote the callee would
lose them; these tests drive the whole pass on hand-built graphs to catch both.

A partial application (PAP) of a global `g` with `k` bound arguments is a heap
object holding those `k` arguments. As a lambda-set member it is `p|g|k`, which
the graph's `lssMemberOrigins` maps to `OriginPap g k`. The function type left
after the bound arguments is the PAP's _residual_. Calling `g` in place of the
callee would drop the bound arguments, so for such a member the pass leaves
the callee as it is.

The _fast PAP stamp_ instead fills the call's `CallInfo`: `fastEvaluatorSpec`
names the one spec of `g` to call, `fastPapPrefix` is `k`, `captureAbi` is that
spec's parameter row split after `k` into `captureTypes` (the bound slots read
out of the object) and `paramTypes` (the site's arguments), with its return
type, and `fastEvaluator` is a sentinel `AnonymousLambda` in `g`'s home module
whose negative uid is `-(specId) - 1`.

The fixture, built by `run`, is a graph whose node 0 defines a list holding the
call sites and whose nodes 1 onwards are specs of one global, each at the index
of its registry entry. A site applies integer literals to a local variable
whose type is the residual, with the singleton set holding the member `pap` as
its head annotation, and `origins` maps `pap` to `OriginPap global k`. No spec
node is a closure instance of `pap`, so the pass looks the global's specs up in
the registry. The pass runs with its census switch on. Spec 1 is the only spec
in every test but test 2.

What the tests establish:

  - Test 1: with one spec `[Int, Int] -> Int` and one bound argument, a site
    applying one argument is stamped. It asserts one `stampedPapGlobal` and no
    `declinedNoInstance`, a `fastPapPrefix` and `fastEvaluatorSpec` of 1, a
    `captureAbi` of `[Int]`, `[Int]` and `Int`, a `fastEvaluator` of
    `AnonymousLambda home -2`, and a callee that is still a local variable.
  - Test 2: two specs, `[Int, Int] -> Int` and `[Float, Int] -> Int`, both fit
    the residual `Int -> Int`, while their bound slot holds an `Int` in one and
    a `Float` in the other. It asserts no stamp, one `declinedNoInstance`, and
    no `fastPapPrefix`.
  - Test 3: the global's one spec is a constant, not a function. It asserts no
    stamp and one `declinedNoInstance`.
  - Test 4: the bound parameter is a `Char`. It asserts no stamp.
  - Test 5: a three-parameter spec with one bound argument, whose residual is
    typed curried, `Int -> (Int -> Int)`, at a site applying two arguments at
    once. It asserts one stamp, a `fastPapPrefix` of 1 and a `captureAbi` of
    `[Int]`, `[Int, Int]` and `Int`.
  - Test 6: the spec returns `Float` where the residual returns `Int`. It
    asserts no stamp.
  - Test 7: a three-parameter spec with two bound arguments. It asserts one
    stamp, a `fastPapPrefix` of 2 and a `captureAbi` of `[Int, Int]`, `[Int]`
    and `Int`.
  - Test 8: the spec is a constructor (`MonoCtor`) with an `Int` and a `Float`
    field, one bound. It asserts one stamp, a `fastPapPrefix` of 1, a
    `captureAbi` of `[Int]`, `[Float]` and `shapeTy`, and a callee that is
    still a local variable.
  - Test 9: the spec is a constructor with 25 `Int` fields, one bound. The pass
    treats a constructor as callable only up to 24 fields, because code
    generation stores the fields from index 24 on boxed while a fast call
    passes them unboxed. It asserts no stamp and one `declinedNoInstance`.

The decline reasons in the test names (`papAmbiguous`, `papNonFn`, `papChar`,
`papShapeMiss`) are not asserted; the tests read the counters, the stamped
`CallInfo` and, in tests 1 and 8, the callee expression.

Among what is not tested: the `closureKind` the stamp also sets; a callee that
is not a local variable; a residual that cannot be split into exactly the
site's argument count; a global with no spec; a tail-function spec; a blocked
member; the sentinel for a spec id other than 1.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import Test exposing (Test)


{-| The nine tests of the fast PAP stamp, described in the module docstring.
-}
suite : Test
suite =
    Test.describe "LSS_040 p| fast stamp at the pass level"
        [ Test.test "1. a p| site FAST-stamps, callee untouched" <|
            \() ->
                -- `add : Int -> Int -> Int` with one bound argument (k = 1);
                -- the site applies the residual's one argument.
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MInt, Mono.MInt ] Mono.MInt ) ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt ] Mono.MInt ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    ( onGraph, onStats ) =
                        run (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 onStats.stampedPapGlobal
                    , \_ -> Expect.equal 0 onStats.declinedNoInstance

                    -- The stamp names spec 1 and splits its row after k = 1.
                    , \_ -> Expect.equal (Just 1) (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo onGraph))
                    , \_ -> Expect.equal (Just 1) (Maybe.andThen (\ci -> ci.fastEvaluatorSpec) (firstCallInfo onGraph))
                    , \_ ->
                        Expect.equal
                            (Just { captureTypes = [ Mono.MInt ], paramTypes = [ Mono.MInt ], returnType = Mono.MInt })
                            (Maybe.andThen (\ci -> ci.captureAbi) (firstCallInfo onGraph))

                    -- The sentinel's uid is -(specId) - 1, for spec 1.
                    , \_ -> Expect.equal (Just (Mono.AnonymousLambda home -2)) (Maybe.andThen (\ci -> ci.fastEvaluator) (firstCallInfo onGraph))

                    -- The callee is still the local variable: a rewrite to
                    -- the global would drop the bound argument.
                    , \_ -> Expect.equal True (calleeIsLocal onGraph)
                    ]
                    ()
        , Test.test "2. P5 UNIQUENESS: two specs of the global with the same residual DECLINE (papAmbiguous)" <|
            \() ->
                -- `p|add|1` does not say which spec was applied. Both specs
                -- have residual `Int -> Int`, but their PAP objects hold an Int
                -- and a Float in slot 0, so stamping either one would load
                -- slot 0 at the wrong kind for the other.
                let
                    reg =
                        registryOf
                            [ Nothing
                            , Just ( addGlobal, fn [ Mono.MInt, Mono.MInt ] Mono.MInt )
                            , Just ( addGlobal, fn [ Mono.MFloat, Mono.MInt ] Mono.MInt )
                            ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt ] Mono.MInt
                        , specClosure [ Mono.MFloat, Mono.MInt ] Mono.MInt
                        ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    ( g, st ) =
                        run (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 st.stampedPapGlobal
                    , \_ -> Expect.equal 1 st.declinedNoInstance
                    , \_ -> Expect.equal Nothing (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo g))
                    ]
                    ()
        , Test.test "3. P3 FUNCTION TARGET: a non-function spec node (CAF) DECLINES (papNonFn)" <|
            \() ->
                -- The registry's only spec of the global is a constant, not
                -- callable code.
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, Mono.MInt ) ]

                    nodes =
                        [ Mono.MonoDefine (Mono.MonoLiteral (Mono.LInt 7) Mono.MInt) Mono.MInt ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    ( _, st ) =
                        run (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 st.stampedPapGlobal
                    , \_ -> Expect.equal 1 st.declinedNoInstance
                    ]
                    ()
        , Test.test "4. P6 CHAR gate: an MChar in the k-prefix DECLINES (papChar)" <|
            \() ->
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MChar, Mono.MInt ] Mono.MInt ) ]

                    nodes =
                        [ specClosure [ Mono.MChar, Mono.MInt ] Mono.MInt ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    ( _, st ) =
                        run (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.equal 0 st.stampedPapGlobal
        , Test.test "5. P2 RESIDUAL PEEL: a curried residual applied flat is peeled and stamps with k=1, |params|=2" <|
            \() ->
                -- A three-parameter spec with one bound argument (k = 1). The
                -- residual is typed `Int -> (Int -> Int)`, one parameter per
                -- stage, while the site applies two arguments at once.
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MInt, Mono.MInt, Mono.MInt ] Mono.MInt ) ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt, Mono.MInt ] Mono.MInt ]

                    curriedResidual =
                        fn1 [ Mono.MInt ] (Mono.mFunction Mono.topLegacy [ Mono.MInt ] Mono.MInt)

                    site =
                        papSite 2 curriedResidual 1

                    ( g, st ) =
                        run (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 st.stampedPapGlobal
                    , \_ -> Expect.equal (Just 1) (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo g))
                    , \_ ->
                        Expect.equal
                            (Just { captureTypes = [ Mono.MInt ], paramTypes = [ Mono.MInt, Mono.MInt ], returnType = Mono.MInt })
                            (Maybe.andThen (\ci -> ci.captureAbi) (firstCallInfo g))
                    ]
                    ()
        , Test.test "6. P4 SHAPE: a return-layout mismatch DECLINES (papShapeMiss)" <|
            \() ->
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MInt, Mono.MInt ] Mono.MFloat ) ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt ] Mono.MFloat ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    ( _, st ) =
                        run (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.equal 0 st.stampedPapGlobal
        , Test.test "7. k=2: two bound arguments split the row at 2" <|
            \() ->
                -- A three-parameter spec with two bound arguments (k = 2);
                -- the residual is `Int -> Int`.
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MInt, Mono.MInt, Mono.MInt ] Mono.MInt ) ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt, Mono.MInt ] Mono.MInt ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 2

                    ( g, st ) =
                        run (origins [ ( pap, Mono.OriginPap addGlobal 2 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 st.stampedPapGlobal
                    , \_ -> Expect.equal (Just 2) (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo g))
                    , \_ ->
                        Expect.equal
                            (Just { captureTypes = [ Mono.MInt, Mono.MInt ], paramTypes = [ Mono.MInt ], returnType = Mono.MInt })
                            (Maybe.andThen (\ci -> ci.captureAbi) (firstCallInfo g))
                    ]
                    ()
        , Test.test "8. §11.1 CONSTRUCTOR PAP: a MonoCtor spec within the typed-slot bound STAMPS" <|
            \() ->
                -- `Rect` with an Int and a Float field, one bound (k = 1). The
                -- pass reads a constructor spec's row as its field list and its
                -- return as the result of its type.
                let
                    reg =
                        registryOf [ Nothing, Just ( rectGlobal, fn [ Mono.MInt, Mono.MFloat ] shapeTy ) ]

                    nodes =
                        [ ctorSpec [ Mono.MInt, Mono.MFloat ] ]

                    site =
                        papSite 1 (fn1 [ Mono.MFloat ] shapeTy) 1

                    ( g, st ) =
                        run (origins [ ( pap, Mono.OriginPap rectGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 st.stampedPapGlobal
                    , \_ -> Expect.equal (Just 1) (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo g))
                    , \_ ->
                        Expect.equal
                            (Just { captureTypes = [ Mono.MInt ], paramTypes = [ Mono.MFloat ], returnType = shapeTy })
                            (Maybe.andThen (\ci -> ci.captureAbi) (firstCallInfo g))
                    , \_ -> Expect.equal True (calleeIsLocal g)
                    ]
                    ()
        , Test.test "9. §11.1 GUARD: a constructor wider than 24 fields DECLINES (tail fields are boxed)" <|
            \() ->
                -- 25 Int fields, k = 1. Code generation stores fields at index
                -- 24 and above boxed, and the fast call would pass them unboxed.
                let
                    fields =
                        List.repeat 25 Mono.MInt

                    reg =
                        registryOf [ Nothing, Just ( rectGlobal, fn fields shapeTy ) ]

                    nodes =
                        [ ctorSpec fields ]

                    site =
                        papSite 24 (fn1 (List.repeat 24 Mono.MInt) shapeTy) 1

                    ( _, st ) =
                        run (origins [ ( pap, Mono.OriginPap rectGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 st.stampedPapGlobal
                    , \_ -> Expect.equal 1 st.declinedNoInstance
                    ]
                    ()
        ]



-- ====== FIXTURE MACHINERY ======


{-| The lambda-set member id on every site's callee, standing for the partial
application under test. Each test's `origins` says which global it applies and
how many arguments it binds.
-}
pap : Int
pap =
    99993


{-| The module `M` of package `author/proj`, home of both globals.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


{-| The global `add`, used by tests 1 to 7. Tests 5 and 7 give it a
three-parameter spec, and test 3 a constant one.
-}
addGlobal : Mono.Global
addGlobal =
    Mono.Global home "add"


{-| The constructor global `Rect`, used by tests 8 and 9.
-}
rectGlobal : Mono.Global
rectGlobal =
    Mono.Global home "Rect"


{-| The result type of the constructor specs in tests 8 and 9, standing in for
a custom type. It is `List Float`. The pass never checks that it is a custom
type: it compares it with `eqLayout` against the site's return type and records
it as the stamp's return type.
-}
shapeTy : Mono.MonoType
shapeTy =
    Mono.mList Mono.MFloat


{-| Builds a constructor spec node: `MonoCtor` named `Rect` with tag 0 and
fields `fieldTys`, typed as a function from those fields to `shapeTy`. The pass
reads its parameter row as the field list and its return as the final result of
that type.
-}
ctorSpec : List Mono.MonoType -> Mono.MonoNode
ctorSpec fieldTys =
    Mono.MonoCtor
        { name = "Rect", tag = 0, fieldTypes = fieldTys }
        (fn fieldTys shapeTy)


{-| Builds the function type from `params` to `ret` with the `topLegacy`
annotation, for spec nodes and registry entries.
-}
fn : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
fn params ret =
    Mono.mFunction Mono.topLegacy params ret


{-| Builds a site's callee type: the residual from `params` to `ret`, whose head
annotation is the singleton set holding `pap`. A singleton head is what makes
the pass look the member up.
-}
fn1 : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
fn1 params ret =
    Mono.mFunction (Mono.LSet [ pap ]) params ret


{-| Builds a function spec node: a top-level closure with no captures, one
parameter per type in `paramTys`, and type `paramTys -> ret`. It carries no
lambda-set member, no source lambda and an unannotated (`topLegacy`) type, so
the pass indexes no closure instance for it and reaches it only through the
registry's specs of its global.
-}
specClosure : List Mono.MonoType -> Mono.MonoType -> Mono.MonoNode
specClosure paramTys ret =
    let
        params =
            List.indexedMap (\i t -> ( "p" ++ String.fromInt i, t )) paramTys

        -- Typed `ret` because the pass takes a spec's return type from its
        -- body's type; a body typed as a parameter would report that type.
        body =
            Mono.MonoVarLocal "r" ret
    in
    Mono.MonoDefine
        (Mono.MonoClosure
            { lambdaId = Mono.AnonymousLambda home 1
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = []
            , params = params
            , closureKind = Nothing
            , captureAbi = Nothing
            }
            body
            (fn paramTys ret)
        )
        (fn paramTys ret)


{-| Builds a call applying `argCount` integer literals to the local variable `h`
of type `calleeTy`. The call's result type is the return of `calleeTy`'s first
stage, which in test 5 is still a function. The third argument is ignored; it
names k for the reader of each test.
-}
papSite : Int -> Mono.MonoType -> Int -> Mono.MonoExpr
papSite argCount calleeTy _ =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" calleeTy)
        (List.repeat argCount (Mono.MonoLiteral (Mono.LInt 1) Mono.MInt))
        (case calleeTy of
            Mono.MFunction _ _ _ r ->
                r

            other ->
                other
        )
        Mono.defaultCallInfo


{-| Builds the member-origin table from pairs of member id and origin.
-}
origins : List ( Int, Mono.MemberOrigin ) -> Dict.Dict Int Mono.MemberOrigin
origins =
    Dict.fromList


{-| Builds a registry whose entry i, in `entries` order, is SpecId i, with
`nextId` set to the entry count and an empty key map.
-}
registryOf : List (Maybe ( Mono.Global, Mono.MonoType )) -> Mono.SpecializationRegistry
registryOf entries =
    { nextId = List.length entries
    , mapping = Mono.specKeyMapEmpty
    , reverseMapping = Array.fromList entries
    , countByGlobal = Dict.empty
    }


{-| Returns the first call in the list node 0 defines, or `Nothing` when there
is none.
-}
firstCall : Mono.MonoGraph -> Maybe Mono.MonoExpr
firstCall (Mono.MonoGraph record) =
    case Array.get 0 record.nodes of
        Just (Just (Mono.MonoDefine (Mono.MonoList _ exprs _) _)) ->
            List.head
                (List.filter
                    (\e ->
                        case e of
                            Mono.MonoCall _ _ _ _ _ ->
                                True

                            _ ->
                                False
                    )
                    exprs
                )

        _ ->
            Nothing


{-| Returns the `CallInfo` of `firstCall`.
-}
firstCallInfo : Mono.MonoGraph -> Maybe Mono.CallInfo
firstCallInfo g =
    case firstCall g of
        Just (Mono.MonoCall _ _ _ _ ci) ->
            Just ci

        _ ->
            Nothing


{-| Tells whether the callee of `firstCall` is still a local variable; `False`
when there is no call.
-}
calleeIsLocal : Mono.MonoGraph -> Bool
calleeIsLocal g =
    case firstCall g of
        Just (Mono.MonoCall _ (Mono.MonoVarLocal _ _) _ _ _) ->
            True

        _ ->
            False


{-| Runs `AbiCloning.abiCloningPass`, census switched on, and returns the graph
and its stats. Node 0 defines a list of `exprs`, and `specNodes` follow from
node 1. The pass reads node i as the spec at registry entry i, so each spec
node sits at the index of its entry and the registry passed in must leave entry
0 empty, for node 0. `memberOrigins` becomes the graph's `lssMemberOrigins`;
the other tables are empty.
-}
run : Dict.Dict Int Mono.MemberOrigin -> Mono.SpecializationRegistry -> List Mono.MonoNode -> List Mono.MonoExpr -> ( Mono.MonoGraph, AbiCloning.AbiCloningStats )
run memberOrigins registry specNodes exprs =
    AbiCloning.abiCloningPass True
        (Mono.MonoGraph
            { nodes =
                Array.fromList
                    (Just
                        (Mono.MonoDefine
                            (Mono.MonoList A.zero exprs (Mono.mList Mono.MInt))
                            (Mono.mList Mono.MInt)
                        )
                        :: List.map Just specNodes
                    )
            , main = Nothing
            , registry = registry
            , ctorShapes = Mono.layoutMapEmpty
            , nextLambdaIndex = 100
            , callEdges = Array.empty
            , specHasEffects = BitSet.empty
            , specValueUsed = BitSet.empty
            , ports = []
            , flagsDecoder = Nothing
            , lssMemberOrigins = memberOrigins
            , lssMemberKinds = Dict.empty
            , lssBlockedMembers = Dict.empty
            }
        )
