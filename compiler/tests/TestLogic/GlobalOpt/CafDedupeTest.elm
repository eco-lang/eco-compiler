module TestLogic.GlobalOpt.CafDedupeTest exposing (suite)

{-| Tests for `Compiler.GlobalOpt.CafDedupe`, the pass that merges top-level
`MonoDefine` definitions whose types are equal and whose bodies are equal apart
from source regions. Without them, a change to the pass could merge two
definitions that differ, leave a reference pointing at a definition it has
removed, or stop after one round when a merge has made two further definitions
equal.

A spec is one node of a `MonoGraph`, numbered by its position in the node
array. When the pass finds a group of equal `MonoDefine` specs, it keeps the one
with the smallest number, the canonical spec, and removes the others, the
victims, by setting their node to `Nothing`. References to a victim written as
`MonoVarGlobal` in expressions, and the graph's port decoders, flags decoder and
`main`, are redirected to the canonical spec.

The fixtures are small graphs built by hand with `mkGraph`. Most of their specs
are thunks: definitions of type `String` whose body calls the kernel
`String.repeat` with `3` and a string literal, so two thunks are equal exactly
when their literals are. The kernel functions `String.repeat` and
`String.append` are both given the type `String -> String`, which is the real
type of neither, and every registry entry is typed `String` whatever its node's
type; the tests do not depend on either.

The tests establish:

  - On `testGraph`, after `run`: the stats report one group, one removed spec
    and one rewritten reference; the node array still has four entries; spec 2
    is `Nothing`; spec 0 is still a `MonoDefine`; the closure in spec 3 now
    refers to spec 0; and the port's `decoderSpecId` is `Just 0`. Because the
    count of rewritten references is one, the port's decoder field is not
    counted in it.
  - On `distinctGraph`, two thunks with different literals, no group is found
    and nothing is removed.
  - On `typeSplitGraph`, two specs with the same body but different declared
    types, no group is found and nothing is removed.
  - Running the pass a second time on its own result for `testGraph` removes
    nothing.
  - On `cascadeGraph`, the stats report two groups, two removed specs and at
    least two rounds, and specs 1 and 3 are `Nothing`.

Among what is not tested: the redirection of `flagsDecoder` and `main`;
references inside closure captures, `let`s, `case`s and other expression forms
besides a call inside a closure body and, in the cascade test, a reference that
is a whole definition body; a group of more than two equal specs; bodies that
differ only in their source regions; the cap on the number of rounds and the
exact round count; and whether the canonical spec's body is unchanged.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.CafDedupe as CafDedupe
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import Test exposing (Test)


{-| The five tests of the dedupe pass described in the module docstring.
-}
suite : Test
suite =
    Test.describe "CafDedupe"
        [ Test.test "identical thunks merge onto the lowest specId; refs and ports remap" <|
            \_ ->
                let
                    ( Mono.MonoGraph g1, stats ) =
                        CafDedupe.run testGraph
                in
                Expect.all
                    [ \_ -> Expect.equal 1 stats.groups
                    , \_ -> Expect.equal 1 stats.removed

                    -- Only the reference inside spec 3 is counted; the port's
                    -- decoder is a field of the graph, not an expression.
                    , \_ -> Expect.equal 1 stats.refsRewritten
                    , \_ ->
                        Expect.equal 4 (Array.length g1.nodes)
                    , \_ ->
                        case Array.get 2 g1.nodes of
                            Just Nothing ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected victim spec 2 nulled out"
                    , \_ ->
                        case Array.get 0 g1.nodes of
                            Just (Just (Mono.MonoDefine _ _)) ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected canonical spec 0 intact"
                    , \_ ->
                        case Array.get 3 g1.nodes of
                            Just (Just (Mono.MonoDefine (Mono.MonoClosure _ (Mono.MonoCall _ _ [ Mono.MonoVarGlobal _ 0 _, Mono.MonoVarLocal _ _ ] _ _) _) _)) ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected node 3 arg remapped to MonoVarGlobal 0"
                    , \_ ->
                        Expect.equal [ Just 0 ]
                            (List.map .decoderSpecId g1.ports)
                    ]
                    ()
        , Test.test "different bodies do not merge" <|
            \_ ->
                let
                    ( _, stats ) =
                        CafDedupe.run distinctGraph
                in
                Expect.equal ( 0, 0 ) ( stats.groups, stats.removed )
        , Test.test "different types do not merge even with equal bodies" <|
            \_ ->
                let
                    ( _, stats ) =
                        CafDedupe.run typeSplitGraph
                in
                Expect.equal ( 0, 0 ) ( stats.groups, stats.removed )
        , Test.test "idempotent: re-running the deduped graph removes nothing" <|
            \_ ->
                let
                    ( g1, _ ) =
                        CafDedupe.run testGraph

                    ( _, stats2 ) =
                        CafDedupe.run g1
                in
                Expect.equal 0 stats2.removed
        , Test.test "cascade: aliases of merged specs merge on a later round" <|
            \_ ->
                let
                    ( Mono.MonoGraph g1, stats ) =
                        CafDedupe.run cascadeGraph
                in
                Expect.all
                    [ -- Round 1 merges spec 1 into spec 0, after which
                      -- specs 2 and 3 both refer to spec 0; round 2 merges
                      -- spec 3 into 2.
                      \_ -> Expect.equal 2 stats.groups
                    , \_ -> Expect.equal 2 stats.removed
                    , \_ -> Expect.atLeast 2 stats.rounds
                    , \_ ->
                        case ( Array.get 1 g1.nodes, Array.get 3 g1.nodes ) of
                            ( Just Nothing, Just Nothing ) ->
                                Expect.pass

                            _ ->
                                Expect.fail "expected specs 1 and 3 nulled out"
                    ]
                    ()
        ]



-- ====== SYNTHETIC GRAPHS ======


{-| The module every global and lambda in the fixtures is named in.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


{-| The `String` type, which every thunk has.
-}
strTy : Mono.MonoType
strTy =
    Mono.MString


{-| The function type from `String` to `String`, used for the kernel functions,
for the closure in `consumerNode`, and as the declared type of the second spec
in `typeSplitGraph`.
-}
fnTy : Mono.MonoType
fnTy =
    Mono.mFunction Mono.topLegacy [ strTy ] strTy


{-| Builds the body of a thunk: a call of the kernel `String.repeat` with `3`
and the string literal `lit`.
-}
thunkBody : String -> Mono.MonoExpr
thunkBody lit =
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero "Elm" "String" "repeat" fnTy)
        [ Mono.MonoLiteral (Mono.LInt 3) Mono.MInt
        , Mono.MonoLiteral (Mono.LStr lit) strTy
        ]
        strTy
        Mono.defaultCallInfo


{-| Builds a thunk: a definition of type `String` whose body is `thunkBody lit`.
-}
thunkNode : String -> Mono.MonoNode
thunkNode lit =
    Mono.MonoDefine (thunkBody lit) strTy


{-| Builds a definition whose value is the closure `\x -> String.append g x`,
where `g` is a reference to spec `refId`. The reference sits in the closure's
body, not among its captures, which are empty.
-}
consumerNode : Int -> Mono.MonoNode
consumerNode refId =
    Mono.MonoDefine
        (Mono.MonoClosure
            { lambdaId = Mono.AnonymousLambda home 0
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = []
            , params = [ ( "x", strTy ) ]
            , closureKind = Nothing
            , captureAbi = Nothing
            }
            (Mono.MonoCall A.zero
                (Mono.MonoVarKernel A.zero "Elm" "String" "append" fnTy)
                [ Mono.MonoVarGlobal A.zero refId strTy
                , Mono.MonoVarLocal "x" strTy
                ]
                strTy
                Mono.defaultCallInfo
            )
            fnTy
        )
        fnTy


{-| Builds a registry for `n` specs, in which spec `i` is the global `g<i>` of
`home` at type `String`. The forward mapping and the per-global counts are
empty.
-}
baseRegistry : Int -> Mono.SpecializationRegistry
baseRegistry n =
    { nextId = n
    , mapping = Mono.specKeyMapEmpty
    , reverseMapping =
        Array.fromList
            (List.map
                (\i -> Just ( Mono.Global home ("g" ++ String.fromInt i), strTy ))
                (List.range 0 (n - 1))
            )
    , countByGlobal = Dict.empty
    }


{-| Builds a graph from its nodes and ports, with a registry from
`baseRegistry` sized to the nodes, no `main` and no flags decoder. The other
tables are empty, and the next lambda index is 1.
-}
mkGraph : List (Maybe Mono.MonoNode) -> List Mono.PortRegistration -> Mono.MonoGraph
mkGraph nodes ports =
    Mono.MonoGraph
        { nodes = Array.fromList nodes
        , main = Nothing
        , registry = baseRegistry (List.length nodes)
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = 1
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = ports
        , flagsDecoder = Nothing
        , lssMemberOrigins = Dict.empty
        , lssMemberKinds = Dict.empty
        , lssBlockedMembers = Dict.empty
        }


{-| A graph of four specs and one port. Specs 0 and 2 are equal thunks, spec 1
is a thunk with a different literal, and spec 3 is a closure whose body refers
to spec 2. The port is incoming and its decoder is spec 2. The dedupe pass is
expected to make spec 0 canonical and spec 2 its victim.
-}
testGraph : Mono.MonoGraph
testGraph =
    mkGraph
        [ Just (thunkNode "ab")
        , Just (thunkNode "cd")
        , Just (thunkNode "ab")
        , Just (consumerNode 2)
        ]
        [ { name = "p", key = "p", incoming = True, decoderSpecId = Just 2 } ]


{-| A graph of two thunks with different literals, which the pass must not
merge.
-}
distinctGraph : Mono.MonoGraph
distinctGraph =
    mkGraph
        [ Just (thunkNode "ab")
        , Just (thunkNode "cd")
        ]
        []


{-| A graph of two specs with the same body, a reference to the kernel
`String.empty`, declared at different types: one `String`, the other a
function type. Definitions of different types may have different layouts, so
the pass must not merge them; it uses equality of the declared type to rule
that out.
-}
typeSplitGraph : Mono.MonoGraph
typeSplitGraph =
    mkGraph
        [ Just (Mono.MonoDefine (Mono.MonoVarKernel A.zero "Elm" "String" "empty" strTy) strTy)
        , Just (Mono.MonoDefine (Mono.MonoVarKernel A.zero "Elm" "String" "empty" strTy) fnTy)
        ]
        []


{-| A graph in which one merge makes two further specs equal. Specs 0 and 1 are
equal thunks. Spec 2 is defined as a reference to spec 0 and spec 3 as a
reference to spec 1, so specs 2 and 3 differ until spec 1 has been merged into
spec 0 and the reference in spec 3 redirected.
-}
cascadeGraph : Mono.MonoGraph
cascadeGraph =
    mkGraph
        [ Just (thunkNode "ab")
        , Just (thunkNode "ab")
        , Just (Mono.MonoDefine (Mono.MonoVarGlobal A.zero 0 strTy) strTy)
        , Just (Mono.MonoDefine (Mono.MonoVarGlobal A.zero 1 strTy) strTy)
        ]
        []
