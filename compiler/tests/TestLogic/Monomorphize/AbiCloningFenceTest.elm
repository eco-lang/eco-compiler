module TestLogic.Monomorphize.AbiCloningFenceTest exposing (suite)

{-| Tests for the body check in `Compiler.GlobalOpt.AbiCloning` that stops a
call from being stamped with the code of the wrong closure.

The AbiCloning pass looks at calls whose callee's lambda set names exactly one
member, and stamps such a call for fast dispatch: the call then jumps straight
to the code of one representative closure instance of that member, with no
check at run time of which closure actually arrived. Several closure instances
can carry the same member id. If two of them had the same layouts but different
bodies, a stamp would run the representative's body where the other's was
meant. So when the pass stamps a call with one of several closure instances,
the instances in the layout group the call is matched to must agree on their
capture layout and on their body fingerprint. The fingerprint is a
serialization of the closure's info and body in which source regions are left
out, and local names and the closure's own lambda ids are numbered by first
appearance. The types of the expressions in the body are kept, annotations
included. Without these tests, a stamp across two different bodies would go
unnoticed until the wrong code ran.

Each test runs `AbiCloning.abiCloningPass`, with its census switch on, over a
graph of one `MonoDefine` node whose body is a list of three expressions: two
closures carrying member 99991 with distinct lambda ids, each taking one `Int`
parameter `x`, and one call that applies a local `h` to an `Int`, where `h` is
a function whose lambda set is the singleton {99991}. The pass links the call
to the closures by that member id alone. The graph is not a runnable program:
the list is typed `List Int` whatever it holds, and `h` (and `k` in the second
test) is bound nowhere. Only the counters the pass returns are inspected.

The tests establish:

  - Two closures with no captures whose bodies are both `x`: the call is
    stamped (`dispatchUpgraded` is 1), there is no body or capture-layout
    decline, and the closures form one layout group of more than one instance
    (`multiInstanceGroups` is 1).
  - Two closures with no captures whose bodies are a variable `k` of type
    `Int -> Int`, the arrow annotated with the set {777} in one and {778} in
    the other: nothing is stamped, there is one body decline
    (`declinedBodyMismatch`) and no capture-layout decline, and the closures
    still form one multi-instance group. Bodies that differ only in an inner
    annotation therefore count as different.
  - Two closures with the body `x`, one capturing an `Int` and the other a
    `String`: nothing is stamped, and there is one capture-layout decline
    (`declinedAbiMismatch`) and no body decline. The pass checks capture
    layout before the fingerprint.

Among what is not tested: what the stamp writes into the call's `CallInfo`;
blocked members; `Char` captures; calls that apply more or fewer arguments
than the callee's first stage, or that reach a partially applied closure;
whether a fingerprint is computed at all in the third test; and the pass with
its census switch off.

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


{-| The three tests described in the module docstring, one per pair of
closures.
-}
suite : Test
suite =
    Test.describe "LSS_024 fingerprint fence (AbiCloning)"
        [ Test.test "verbatim clones under one member: multi group, fingerprints agree, site STAMPS" <|
            \() ->
                let
                    stats =
                        statsOf
                            [ mkClosure 1 member [] plainBody plainRet
                            , mkClosure 2 member [] plainBody plainRet
                            , callSite plainRet
                            ]
                in
                Expect.all
                    [ \s -> Expect.equal 1 s.dispatchUpgraded
                    , \s -> Expect.equal 0 s.declinedBodyMismatch
                    , \s -> Expect.equal 0 s.declinedAbiMismatch
                    , \s -> Expect.equal 1 s.multiInstanceGroups
                    ]
                    stats
        , Test.test "E11-shaped pair (inner annotation names a different member): bodyMismatch decline" <|
            \() ->
                let
                    stats =
                        statsOf
                            [ mkClosure 1 member [] (annoBody 777) (annoRet 777)
                            , mkClosure 2 member [] (annoBody 778) (annoRet 778)
                            , callSite (intFn Mono.topLegacy)
                            ]
                in
                Expect.all
                    [ \s -> Expect.equal 0 s.dispatchUpgraded
                    , \s -> Expect.equal 1 s.declinedBodyMismatch
                    , \s -> Expect.equal 0 s.declinedAbiMismatch
                    , \s -> Expect.equal 1 s.multiInstanceGroups
                    ]
                    stats
        , Test.test "capture-layout-divergent pair: abiMismatch (existing fence unchanged)" <|
            \() ->
                let
                    stats =
                        statsOf
                            [ mkClosure 1 member [ ( "c", Mono.MonoLiteral (Mono.LInt 1) Mono.MInt, False ) ] plainBody plainRet
                            , mkClosure 2 member [ ( "c", Mono.MonoLiteral (Mono.LStr "s") Mono.MString, False ) ] plainBody plainRet
                            , callSite plainRet
                            ]
                in
                Expect.all
                    [ \s -> Expect.equal 0 s.dispatchUpgraded
                    , \s -> Expect.equal 0 s.declinedBodyMismatch
                    , \s -> Expect.equal 1 s.declinedAbiMismatch
                    ]
                    stats
        ]



-- ====== FIXTURE MACHINERY ======


{-| The member id that both closures in every test carry and that the call's
lambda set names. The value itself is arbitrary.
-}
member : Int
member =
    99991


{-| The module named in the closures' lambda ids. It is not the module of
staging wrappers, so the closures do not block their member.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


{-| Returns the type `Int -> Int` with `anno` as its arrow's lambda-set
annotation.
-}
intFn : Mono.LambdaSetAnno -> Mono.MonoType
intFn anno =
    Mono.mFunction anno [ Mono.MInt ] Mono.MInt


{-| The closure body of the first and third tests: the parameter `x`, an `Int`.
-}
plainBody : Mono.MonoExpr
plainBody =
    Mono.MonoVarLocal "x" Mono.MInt


{-| The return type of the closures and of the call in the first and third
tests.
-}
plainRet : Mono.MonoType
plainRet =
    Mono.MInt


{-| Returns the second test's closure body: a variable `k` of type `Int -> Int`
whose arrow carries the singleton set {`mid`}. Bodies built with different
`mid` have the same layout but different fingerprints.
-}
annoBody : Int -> Mono.MonoExpr
annoBody mid =
    Mono.MonoVarLocal "k" (intFn (Mono.LSet [ mid ]))


{-| Returns the type of `annoBody mid`, used as the second test's closure
return type.
-}
annoRet : Int -> Mono.MonoType
annoRet mid =
    intFn (Mono.LSet [ mid ])


{-| Builds a closure that takes one `Int` parameter `x`, with lambda id `uid`
in `home`, member `mid`, and the given captures and body. Its type is
`Int -> retTy` with the singleton set {`mid`} on the arrow. The pass reads an
instance's return layout from its body, not from this type, so `retTy` should
be the body's type.
-}
mkClosure : Int -> Int -> List ( String, Mono.MonoExpr, Bool ) -> Mono.MonoExpr -> Mono.MonoType -> Mono.MonoExpr
mkClosure uid mid captures body retTy =
    Mono.MonoClosure
        { lambdaId = Mono.AnonymousLambda home uid
        , srcLambda = Nothing
        , lssMember = Just mid
        , captures = captures
        , params = [ ( "x", Mono.MInt ) ]
        , closureKind = Nothing
        , captureAbi = Nothing
        }
        body
        (Mono.mFunction (Mono.LSet [ mid ]) [ Mono.MInt ] retTy)


{-| Builds the call: a local `h` of type `Int -> retTy`, whose arrow carries
the singleton set {`member`}, applied to the literal 1, with the default
`CallInfo`, which holds no stamp.
-}
callSite : Mono.MonoType -> Mono.MonoExpr
callSite retTy =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" (Mono.mFunction (Mono.LSet [ member ]) [ Mono.MInt ] retTy))
        [ Mono.MonoLiteral (Mono.LInt 1) Mono.MInt ]
        retTy
        Mono.defaultCallInfo


{-| Returns the pass's counters for a graph holding the given expressions. It
is another name for `statsWithFence`.
-}
statsOf : List Mono.MonoExpr -> AbiCloning.AbiCloningStats
statsOf =
    statsWithFence


{-| Returns the counters from `AbiCloning.abiCloningPass`, run with its census
switch on, over a graph whose one node is a `MonoDefine` of a list of `exprs`
typed `List Int`. The rewritten graph is dropped. The registry is empty and no
member is blocked or has an origin, so the closures in `exprs` are all the
pass has to resolve a call against.
-}
statsWithFence : List Mono.MonoExpr -> AbiCloning.AbiCloningStats
statsWithFence exprs =
    Tuple.second
        (AbiCloning.abiCloningPass
            True
            (Mono.MonoGraph
                { nodes =
                    Array.fromList
                        [ Just
                            (Mono.MonoDefine
                                (Mono.MonoList A.zero exprs (Mono.mList Mono.MInt))
                                (Mono.mList Mono.MInt)
                            )
                        ]
                , main = Nothing
                , registry =
                    { nextId = 0
                    , mapping = Mono.specKeyMapEmpty
                    , reverseMapping = Array.empty
                    , countByGlobal = Dict.empty
                    }
                , ctorShapes = Mono.layoutMapEmpty
                , nextLambdaIndex = 100
                , callEdges = Array.empty
                , specHasEffects = BitSet.empty
                , specValueUsed = BitSet.empty
                , ports = []
                , flagsDecoder = Nothing
                , lssMemberOrigins = Dict.empty
                , lssMemberKinds = Dict.empty
                , lssBlockedMembers = Dict.empty
                }
            )
        )
