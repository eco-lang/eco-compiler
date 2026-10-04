module TestLogic.GlobalOpt.CafHoistTest exposing (suite)

{-| Tests for `Compiler.GlobalOpt.CafHoist.run`, without which a change to
which subexpressions the pass moves, to how it shares one new definition
between equal ones, or to how it adds that definition to the graph would go
unnoticed.

The pass looks inside function bodies for closed subexpressions, ones that
read no local variable bound outside themselves. To hoist one is to append a
new spec to the graph, a nullary `MonoDefine` whose body is the subexpression,
and to replace the subexpression with a `MonoVarGlobal` naming that spec. A
spec is one node of the `MonoGraph`, numbered by its position. The counters
the tests read are the fields of `CafHoist.Stats`.

The fixture is `testGraph`, built by hand so that the tests control exactly
which subexpressions are closed. It has three specs, numbered 0 to 2, each a
function of one `String` parameter whose body is a `String.append` kernel call
of a closed subexpression and the parameter. That call reads the parameter, so
it is never closed itself. Specs 0 and 1 both use `closedCall`, a call with
result type `String` that counts four expression nodes; spec 2 uses
`closedScalarCall`, a call with result type `Int` that counts three.

The tests establish:

  - With a minimum size of 3 and room for 100 hoists, one spec is minted
    (`hoisted` 1) and two sites are replaced (`sites` 2), the second by reusing
    the first's spec (`deduped` 1), and the `Int` call is counted in
    `skippedScalar`. The graph then has four nodes,
    `registry.nextId` is 4 and `registry.reverseMapping` has four entries. Node
    3 is a `MonoDefine` of a call, of type `String`, and spec 0's body call
    has `MonoVarGlobal` spec 3 as its first argument and a local variable as
    its second (its name is not checked). Spec 1's body is not inspected.
  - Running the pass again, with the same settings, on the graph the first run
    produced mints nothing and replaces nothing.
  - With a minimum size of 10, larger than either closed call, nothing is
    minted and nothing is replaced.
  - With room for no hoists, nothing is minted and `skippedBudget` is at
    least 1.

Among what is not tested: candidates that contain a closure, which are minted
once per site rather than shared; the exclusions for function-typed, `Debug`
and `elm/bytes` candidates; tail-function bodies and closure
capture expressions; an eligible subexpression inside an ineligible one; the
names given to new specs in `reverseMapping`; the crash on a registry whose
size does not match the node count; and the `origNodes` counter.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.CafHoist as CafHoist
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import Test exposing (Test)


{-| The `CafHoist` tests, as the module docstring lists them.
-}
suite : Test
suite =
    Test.describe "CafHoist"
        [ Test.test "closed call is hoisted; duplicate site dedupes; scalar site excluded" <|
            \_ ->
                let
                    ( Mono.MonoGraph g1, stats ) =
                        CafHoist.run { minNodes = 3, maxHoists = 100 } testGraph
                in
                Expect.all
                    [ \_ -> Expect.equal 1 stats.hoisted
                    , \_ -> Expect.equal 2 stats.sites
                    , \_ -> Expect.equal 1 stats.deduped
                    , \_ -> Expect.equal 1 stats.skippedScalar
                    , \_ -> Expect.equal 4 (Array.length g1.nodes)
                    , \_ -> Expect.equal 4 g1.registry.nextId
                    , \_ -> Expect.equal 4 (Array.length g1.registry.reverseMapping)
                    , \_ ->
                        case Array.get 3 g1.nodes of
                            Just (Just (Mono.MonoDefine (Mono.MonoCall _ _ _ _ _) ty)) ->
                                Expect.equal Mono.MString ty

                            _ ->
                                Expect.fail "expected appended MonoDefine call spec at id 3"
                    , \_ ->
                        case Array.get 0 g1.nodes of
                            Just (Just (Mono.MonoDefine (Mono.MonoClosure _ (Mono.MonoCall _ _ [ Mono.MonoVarGlobal _ 3 _, Mono.MonoVarLocal _ _ ] _ _) _) _)) ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected node 0 body arg replaced by MonoVarGlobal 3"
                    ]
                    ()
        , Test.test "re-running on the hoisted graph mints nothing (stability)" <|
            \_ ->
                let
                    ( g1, _ ) =
                        CafHoist.run { minNodes = 3, maxHoists = 100 } testGraph

                    ( _, stats2 ) =
                        CafHoist.run { minNodes = 3, maxHoists = 100 } g1
                in
                Expect.equal ( 0, 0 ) ( stats2.hoisted, stats2.sites )
        , Test.test "minNodes floor excludes small candidates" <|
            \_ ->
                let
                    ( _, stats ) =
                        CafHoist.run { minNodes = 10, maxHoists = 100 } testGraph
                in
                Expect.equal ( 0, 0 ) ( stats.hoisted, stats.sites )
        , Test.test "maxHoists budget stops minting and counts overflow" <|
            \_ ->
                let
                    ( _, stats ) =
                        CafHoist.run { minNodes = 3, maxHoists = 0 } testGraph
                in
                Expect.all
                    [ \_ -> Expect.equal 0 stats.hoisted
                    , \_ -> Expect.atLeast 1 stats.skippedBudget
                    ]
                    ()
        ]



-- ====== SYNTHETIC GRAPH ======


{-| The module the fixture's three functions and their lambdas are named in.
No test depends on which module it is.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


{-| The `String` type, used for the fixture's parameters, string literals and
`String` results.
-}
strTy : Mono.MonoType
strTy =
    Mono.MString


{-| The type `String -> String`, given to the three specs, their closures and
all three kernel references.

That is not the real type of any of the three kernels. It does not matter
here, because `CafHoist.run` judges a call by the result type recorded on the
call itself, not by the type of the function it calls.

-}
fnTy : Mono.MonoType
fnTy =
    Mono.mFunction Mono.topLegacy [ strTy ] strTy


{-| The closed call `String.repeat 3 "ab"`, with result type `String`, which
the pass hoists when the minimum size and the hoist budget allow.

It counts four expression nodes: the call, the kernel reference and the two
literals. That reaches a minimum size of 3 but not one of 10.

-}
closedCall : Mono.MonoExpr
closedCall =
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero "Elm" "String" "repeat" fnTy)
        [ Mono.MonoLiteral (Mono.LInt 3) Mono.MInt
        , Mono.MonoLiteral (Mono.LStr "ab") strTy
        ]
        strTy
        Mono.defaultCallInfo


{-| The closed call `String.length "ab"`, with result type `Int`, which the pass
does not hoist because an `Int` result is a scalar.

It counts three expression nodes. At a minimum size of 3 it passes the size
check and is then counted in `skippedScalar`; at a minimum size of 10 the size
check rejects it first and no counter changes.

-}
closedScalarCall : Mono.MonoExpr
closedScalarCall =
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero "Elm" "String" "length" fnTy)
        [ Mono.MonoLiteral (Mono.LStr "ab") strTy ]
        Mono.MInt
        Mono.defaultCallInfo


{-| Builds a function body that calls `String.append` on `closed` and the local
variable `param`. Because the call reads `param`, the call itself is never
closed.
-}
bodyUsing : String -> Mono.MonoExpr -> Mono.MonoExpr
bodyUsing param closed =
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero "Elm" "String" "append" fnTy)
        [ closed
        , Mono.MonoVarLocal param strTy
        ]
        strTy
        Mono.defaultCallInfo


{-| Builds a spec defining a function of one `String` parameter, `param`, whose
body is `bodyUsing param closed`. The function captures nothing, and `uid`
numbers its anonymous lambda.
-}
funcNode : Int -> String -> Mono.MonoExpr -> Mono.MonoNode
funcNode uid param closed =
    Mono.MonoDefine
        (Mono.MonoClosure
            { lambdaId = Mono.AnonymousLambda home uid
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = []
            , params = [ ( param, strTy ) ]
            , closureKind = Nothing
            , captureAbi = Nothing
            }
            (bodyUsing param closed)
            fnTy
        )
        fnTy


{-| The three-spec graph every test runs on. Spec 0 (`f`) and spec 1 (`h`)
both contain `closedCall`, and spec 2 (`n`) contains `closedScalarCall`.

`registry.nextId` is 3 and `registry.reverseMapping` has three entries, one
per node. `CafHoist.run` crashes unless both match the node count.

-}
testGraph : Mono.MonoGraph
testGraph =
    Mono.MonoGraph
        { nodes =
            Array.fromList
                [ Just (funcNode 0 "x" closedCall)
                , Just (funcNode 1 "y" closedCall)
                , Just (funcNode 2 "z" closedScalarCall)
                ]
        , main = Nothing
        , registry =
            { nextId = 3
            , mapping = Mono.specKeyMapEmpty
            , reverseMapping =
                Array.fromList
                    [ Just ( Mono.Global home "f", fnTy )
                    , Just ( Mono.Global home "h", fnTy )
                    , Just ( Mono.Global home "n", fnTy )
                    ]
            , countByGlobal = Dict.empty
            }
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = 3
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = []
        , flagsDecoder = Nothing
        , lssMemberOrigins = Dict.empty
        , lssMemberKinds = Dict.empty
        , lssBlockedMembers = Dict.empty
        }
