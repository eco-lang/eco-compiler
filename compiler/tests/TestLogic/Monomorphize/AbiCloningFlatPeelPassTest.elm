module TestLogic.Monomorphize.AbiCloningFlatPeelPassTest exposing (suite)

{-| Tests that `AbiCloning.abiCloningPass` stamps a call passing several
arguments at once through a curried callee type with a closure instance that
takes exactly those arguments in one stage, and not with one that takes more.
Without them, a change to the pass could stop it stamping such calls, leaving
them on generic dispatch, or could make it stamp one with a closure that the
call does not saturate.

A callee's type can be curried, one parameter per `MFunction` stage, while the
closure that flows to it takes all its parameters in one stage. A call that
passes more arguments than the callee type's first stage declares is an
_over-applying_ call. For such a call, the pass peels the callee type, joining
stages until it has exactly as many parameters as the call has arguments
(`AbiCloning.peelStages`, tested on its own in `AbiCloningFlatPeelTest`), and
looks for a layout group of the callee's member whose instances take that flat
parameter list and return what remains of the type. An _instance_ is a closure
carrying the member's id, and a _layout group_ is the member's instances whose
parameter and return types have the same layout, lambda-set annotations
ignored.

Each test builds a one-node graph with `statsOf` and runs the whole pass on it.
Every closure is an instance of the one member `member`, captures nothing and
takes `Int` parameters. Every call's callee is a local `h` whose type's head
arrow carries the singleton set `LSet [member]`; nothing binds `h`. The
assertions read only counters of the returned `AbiCloningStats`, never the
stamped `CallInfo`.

What the tests establish:

  - A three-parameter instance and a call passing three arguments through a
    callee type of three one-parameter stages: `dispatchUpgraded` is 1 and
    `declinedShapeArityOver` is 0.
  - The same call with a four-parameter instance: `dispatchUpgraded` is 0 and
    `declinedShapeArityOver` is 1. The instance's last three parameters match
    the call's peeled ones, so a match on a parameter suffix, which the pass
    tries for partial applications at exactly saturating calls, would stamp
    it. The peeled match looks only for groups with the full peeled parameter
    list.
  - Two three-parameter instances with different lambda ids, which differ
    only in the lambda-set member, 777 or 778, annotated on their return
    type. They form one layout group, but their instance fingerprints, which
    keep annotations, differ. The over-applying call gives
    `declinedBodyMismatch` 1, and `dispatchUpgraded` and
    `declinedShapeArityOver` 0: a call that gets past the arity check through
    the peeled match still meets the fingerprint check.
  - A one-parameter instance and a one-argument call whose callee type is a
    single one-parameter stage, which the pass decides without peeling:
    `dispatchUpgraded` is 1 and `declinedShapeArityOver` is 0.

Among what is not tested: what the stamp writes into the `CallInfo`; a peel
that overshoots the argument count or runs out of stages; a stamp through the
first-stage match an over-applying call falls back to when the peel finds no
group; blocked members; and the `Char` and capture-layout checks.

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


{-| The four tests the module docstring lists, in its order.
-}
suite : Test
suite =
    Test.describe "Fix A at the pass level"
        [ Test.test "1. an over-applying site STAMPS (it declined before Fix A)" <|
            \() ->
                let
                    graph =
                        [ flatClosure 1 member [ Mono.MInt, Mono.MInt, Mono.MInt ] intBody
                        , overSite 3 Mono.MInt
                        ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 (statsOf graph).dispatchUpgraded
                    , \_ -> Expect.equal 0 (statsOf graph).declinedShapeArityOver
                    ]
                    ()
        , Test.test "2. A PAP SUFFIX NEVER QUALIFIES — a 4-param instance is not stamped at a 3-arg site" <|
            \() ->
                let
                    graph =
                        [ flatClosure 1 member [ Mono.MInt, Mono.MInt, Mono.MInt, Mono.MInt ] intBody
                        , overSite 3 Mono.MInt
                        ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 (statsOf graph).dispatchUpgraded
                    , \_ -> Expect.equal 1 (statsOf graph).declinedShapeArityOver
                    ]
                    ()
        , Test.test "3. Fix A does NOT bypass the LSS_024 fence: divergent bodies still decline" <|
            \() ->
                let
                    graph =
                        [ flatClosure 1 member [ Mono.MInt, Mono.MInt, Mono.MInt ] (annoBody 777)
                        , flatClosure 2 member [ Mono.MInt, Mono.MInt, Mono.MInt ] (annoBody 778)
                        , overSite 3 (annoRet 777)
                        ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 (statsOf graph).dispatchUpgraded
                    , \_ -> Expect.equal 1 (statsOf graph).declinedBodyMismatch
                    , \_ -> Expect.equal 0 (statsOf graph).declinedShapeArityOver
                    ]
                    ()
        , Test.test "4. an EXACTLY-saturating site stamps on the ordinary path" <|
            \() ->
                let
                    graph =
                        [ flatClosure 1 member [ Mono.MInt ] intBody
                        , exactSite
                        ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 (statsOf graph).dispatchUpgraded
                    , \_ -> Expect.equal 0 (statsOf graph).declinedShapeArityOver
                    ]
                    ()
        ]



-- ====== FIXTURE MACHINERY ======


{-| The lambda-set member id that every fixture closure is an instance of and
every call's callee type names.
-}
member : Int
member =
    99991


{-| The module the fixture's lambda ids belong to. It is not the staging
wrapper home, so the pass does not treat a fixture closure as a wrapper that
blocks its member.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


{-| A body that returns the closure's first parameter, `p0`, an `Int`.
-}
intBody : Mono.MonoExpr
intBody =
    Mono.MonoVarLocal "p0" Mono.MInt


{-| Builds a body that returns the variable `k` at type `annoRet mid`. Two such
bodies with different `mid` have the same layout but different instance
fingerprints, because the layout ignores lambda-set annotations and the
fingerprint keeps them.
-}
annoBody : Int -> Mono.MonoExpr
annoBody mid =
    Mono.MonoVarLocal "k" (annoRet mid)


{-| Returns the type `Int -> Int` with its arrow annotated `LSet [mid]`.
-}
annoRet : Int -> Mono.MonoType
annoRet mid =
    Mono.mFunction (Mono.LSet [ mid ]) [ Mono.MInt ] Mono.MInt


{-| Builds an instance of member `mid`: a closure with lambda id `uid` in
`home`, no captures, a parameter `p0`, `p1`, ... for each of `paramTys`, and
`body`. Its type takes all of `paramTys` in one stage, carries `LSet [mid]` on
that arrow, and returns `body`'s type.
-}
flatClosure : Int -> Int -> List Mono.MonoType -> Mono.MonoExpr -> Mono.MonoExpr
flatClosure uid mid paramTys body =
    Mono.MonoClosure
        { lambdaId = Mono.AnonymousLambda home uid
        , srcLambda = Nothing
        , lssMember = Just mid
        , captures = []
        , params = List.indexedMap (\i t -> ( "p" ++ String.fromInt i, t )) paramTys
        , closureKind = Nothing
        , captureAbi = Nothing
        }
        body
        (Mono.mFunction (Mono.LSet [ mid ]) paramTys (Mono.typeOf body))


{-| Returns a curried type of `n` stages, each taking one `Int`, that ends in
`ret`. The outermost arrow carries `headAnno` and the inner ones
`Mono.topLegacy`, a widened (top) annotation. This is the
one-parameter-per-stage shape that `Compiler.MonoSolver.Store` builds when it
classifies a function type.
-}
curried : Mono.LambdaSetAnno -> Int -> Mono.MonoType -> Mono.MonoType
curried headAnno n ret =
    List.foldr
        (\i acc ->
            Mono.mFunction
                (if i == 0 then
                    headAnno

                 else
                    Mono.topLegacy
                )
                [ Mono.MInt ]
                acc
        )
        ret
        (List.range 0 (n - 1))


{-| Builds a call passing the `Int` literals 1 to `n` at once to `h`, typed
`curried (LSet [member]) n ret`, with result type `ret` and the default
`CallInfo`. For `n` of 2 or more the call over-applies, since the callee type's
first stage takes one parameter.
-}
overSite : Int -> Mono.MonoType -> Mono.MonoExpr
overSite n ret =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" (curried (Mono.LSet [ member ]) n ret))
        (List.map (\i -> Mono.MonoLiteral (Mono.LInt i) Mono.MInt) (List.range 1 n))
        ret
        Mono.defaultCallInfo


{-| A call passing one `Int` to `h`, typed `Int -> Int` with `LSet [member]` on
its arrow, so that it exactly saturates the callee type's only stage.
-}
exactSite : Mono.MonoExpr
exactSite =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" (Mono.mFunction (Mono.LSet [ member ]) [ Mono.MInt ] Mono.MInt))
        [ Mono.MonoLiteral (Mono.LInt 1) Mono.MInt ]
        Mono.MInt
        Mono.defaultCallInfo


{-| Runs `AbiCloning.abiCloningPass`, with its census switch on, over a graph
whose one node is a `MonoDefine` of a list holding `exprs`, and returns the
pass's counters. The graph's registry and lambda-set tables are empty, so no
member is blocked through `lssBlockedMembers`.
-}
statsOf : List Mono.MonoExpr -> AbiCloning.AbiCloningStats
statsOf exprs =
    Tuple.second
        (AbiCloning.abiCloningPass True
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
