module TestLogic.GlobalOpt.AliasForwardTest exposing (suite)

{-| Tests for `Compiler.GlobalOpt.PreMono.AliasForward`, the pass that runs
before monomorphization and rewrites references to alias definitions so that
they name what the alias names. `TestLogic.TestPipeline` runs no
pre-monomorphization pass, so the pipeline tests built on it do not exercise
this one. These tests run it directly, and pin which references it forwards and
which it keeps.

An _alias definition_ is a top-level definition with no parameters whose body
is only a reference to another global, such as `f = inc`, or to a kernel
function, such as `add = Elm.Kernel.Basics.add`. Not every such definition is
one: for instance the flags decoder is not, nor is a definition in a recursive
group, nor one whose body is a `Debug` function. The second kind is a _kernel
alias_. To _forward_ a reference is to replace a reference to the alias with
one to its target. Which references the pass forwards and which it keeps is
stated in `Compiler.GlobalOpt.PreMono.AliasForward`.

Each fixture is a module named `Test` of annotated top-level definitions (and,
in one fixture, a type alias), with a `testValue` that uses the definitions
under test. A test compiles it with `TestPipeline.runToAssigned`, which runs it
through monomorphization and returns the global graph from before
monomorphization with its ids assigned. The tests of `aliasMap`'s targets and
membership call `AliasForward.aliasMap` on that graph. All the others, the
`chainsMax` and `cycles` checks among them, call `AliasForward.run` on it, with
`aliasForward` on except in the flag-off tests, and read the graph `run`
returns, in some tests also the graph it was given, or the `Metrics` it
reports. Nodes are looked up by name alone. Besides the fixture's definitions
and the `main` that `TestPipeline` adds, the graph holds `TestPipeline`'s mock
nodes for `List.cons` and `List.map2`, each an alias of the kernel of the same
name.

What the tests establish:

  - For `f = inc; testValue = f 1`, `bodiesSeen` is above zero.
  - `aliasMap`: for `g = h; f = g`, both `f` and `g` map to `h`, and for the
    same fixture `run` reports a `chainsMax` of 2 and a `cycles` of 0. For
    `f = inc`, `f` is in the map and `inc` is not.
    `add = Elm.Kernel.Basics.add` maps to a kernel target with home `Basics`,
    name `add`, a spine of 2 and `abiFixed` true. The spine is the number of
    arrows on the outer spine of the type the kernel reference carries in the
    alias body, and `abiFixed` says that the kernel's ABI is decided by that
    type rather than by each use.
  - Call position, for `f = inc; testValue = f 1`: `testValue`'s only callee
    becomes `inc`; `f`'s own body is the same before and after; the metas (the
    type information a reference carries) of the references to `inc` afterwards
    equal those of the references to `f` before; `callsRewritten` is 1.
  - A call through `g = h; f = g` has `h` as its only callee.
  - `testValue = add 1 2`, with `add` a kernel alias, has the kernel
    `Basics.add` as its only callee; after the pass, `testValue`'s `deps`
    contain `TOpt.toKernelGlobal "Basics"`; `callsRewritten`,
    `callsRewrittenKernel` and `depsExtended` are each 1.
  - In `List.map (add 1) [ 1 ]` the under-applied call keeps `add` as a callee;
    `callsKeptKernelPartial` is 1, and `argRefsKeptKernel` and `callsRewritten`
    are 0.
  - `pick : a -> a; pick = Elm.Kernel.Basics.identity` is a kernel alias whose
    type has a type variable and whose kernel name is not among
    `KernelAbi.suffixSelectingKernels`, so `abiFixed` is false: in `pick 1` the
    only callee stays `pick`, `callsKeptKernelPoly` is 1 and `callsRewritten`
    is 0.
  - `cons = Elm.Kernel.List.cons` is polymorphic too, but `List.cons` is a
    suffix-selecting kernel: in `cons 1 [ 2 ]` the only callee becomes the
    kernel `List.cons`.
  - Argument position: in `List.map f [ 1 ]` the value reference to `f`
    becomes one to `inc`, with `argRefsRewritten` 1 and `callsRewritten` 0. In
    `List.foldl add 0 [ 1 ]` the value reference to the kernel alias `add`
    stays, with `argRefsKeptKernel` 1 and `argRefsRewritten` 0.
  - A recursive `loop` that calls `f = inc` gives the graph a `Cycle` node, and
    inside the `Cycle` bodies `inc` is a callee and `f` is not.
  - With `type alias Doc = List Int` and `fromChars : Int -> Doc;
    fromChars = mk`, the call of `fromChars` and the value reference to it in
    `testValue` both become references to `mk`, and the metas of the two
    references to `mk` afterwards equal those of the two references to
    `fromChars` before.
  - With `aliasForward` off, `testValue`'s callees are the same before and
    after, and `callsRewritten` is still 1: the metrics count what the pass
    would rewrite.

Among what is not tested: an over-applied kernel-alias call
(`callsKeptKernelOver`), a call whose reference meta does not match the
kernel's spine (`callsKeptKernelMeta`), an alias cycle, references inside port
nodes, the `deps` of a node whose forwarded target is a global, `byTarget`,
anything about the flag-off graph beyond `testValue`'s callees, and the
`GlobalMVarState` that `run` returns.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , binopsExpr
        , callExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliasesExtended
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.PreMono.AliasForward as AliasForward
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Data.Map
import Data.Set as EverySet
import Dict as CoreDict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| Collects every test in this module.
-}
suite : Test
suite =
    Test.describe "AliasForward (pre-mono)"
        [ denominatorSuite
        , mapSuite
        , callSuite
        , valueSuite
        , cycleSuite
        , docAliasSuite
        , inertSuite
        ]



-- ============================================================================
-- BODIES SEEN
-- ============================================================================


{-| Checks that the pass reports seeing at least one top-level body of
`simpleModule`, so that a zero count in another test is not explained by a pass
that matched no node.
-}
denominatorSuite : Test
denominatorSuite =
    Test.describe "Denominator"
        [ Test.test "the pass examines top-level bodies at all" <|
            \_ ->
                withMetrics simpleModule
                    (\m ->
                        if m.bodiesSeen > 0 then
                            Expect.pass

                        else
                            Expect.fail "AliasForward matched no top-level body"
                    )
        ]



-- ============================================================================
-- THE ALIAS MAP
-- ============================================================================


{-| Checks the targets `AliasForward.aliasMap` resolves for a chain, an alias
against a function, and a kernel alias, and the chain depth and cycle count that
`AliasForward.run` reports.
-}
mapSuite : Test
mapSuite =
    Test.describe "aliasMap"
        [ Test.test "F2: a chain resolves every link to its end" <|
            \_ ->
                withAssigned chainModule
                    (\assigned ->
                        let
                            ( aliases, _, _ ) =
                                AliasForward.aliasMap assigned.graph

                            targetOf name =
                                globalNamed assigned.graph name
                                    |> Maybe.andThen (\g -> CoreDict.get (TOpt.toComparableGlobal g) aliases)
                                    |> Maybe.andThen globalTargetName
                        in
                        Expect.equal ( Just "h", Just "h" ) ( targetOf "f", targetOf "g" )
                    )
        , Test.test "F2: chainsMax is the chain depth" <|
            \_ ->
                withMetrics chainModule (\m -> Expect.equal 2 m.chainsMax)
        , Test.test "F2: no cycles are reported" <|
            \_ ->
                withMetrics chainModule (\m -> Expect.equal 0 m.cycles)
        , Test.test "a function definition is not an alias, an alias is" <|
            \_ ->
                -- Only membership is checked: the graph also holds
                -- `TestPipeline`'s mock kernel-alias nodes.
                withAssigned simpleModule
                    (\assigned ->
                        let
                            ( aliases, _, _ ) =
                                AliasForward.aliasMap assigned.graph

                            isAlias name =
                                globalNamed assigned.graph name
                                    |> Maybe.map (\g -> CoreDict.member (TOpt.toComparableGlobal g) aliases)
                        in
                        Expect.equal ( Just True, Just False ) ( isAlias "f", isAlias "inc" )
                    )
        , Test.test "F3: a kernel alias is a kernel target" <|
            \_ ->
                withAssigned kernelCallModule
                    (\assigned ->
                        let
                            ( aliases, _, _ ) =
                                AliasForward.aliasMap assigned.graph
                        in
                        case globalNamed assigned.graph "add" |> Maybe.andThen (\g -> CoreDict.get (TOpt.toComparableGlobal g) aliases) of
                            Just (AliasForward.ToKernel _ "Basics" "add" 2 True) ->
                                Expect.pass

                            other ->
                                Expect.fail ("add resolved to " ++ Debug.toString other)
                    )
        ]



-- ============================================================================
-- CALL POSITION
-- ============================================================================


{-| Checks which calls of an alias are forwarded, what a forwarded call keeps
and gains, and the counters each case moves.
-}
callSuite : Test
callSuite =
    Test.describe "Call position"
        [ Test.test "F1: the call targets the alias's target" <|
            \_ ->
                withGraph simpleModule
                    (\g -> Expect.equal [ "g:inc" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        , Test.test "F1: the alias definition itself is untouched" <|
            \_ ->
                withBefore simpleModule
                    (\before after -> Expect.equal (nodeBody before "f") (nodeBody after "f"))
        , Test.test "F1: the rewritten reference keeps the CALLER's meta (R7)" <|
            \_ ->
                withBefore simpleModule
                    (\before after ->
                        Expect.equal
                            (List.concatMap (refMetas "f") (bodyOf before "testValue"))
                            (List.concatMap (refMetas "inc") (bodyOf after "testValue"))
                    )
        , Test.test "F1: one call is counted" <|
            \_ ->
                withMetrics simpleModule (\m -> Expect.equal 1 m.callsRewritten)
        , Test.test "F2: a chained call targets the end of the chain" <|
            \_ ->
                withGraph chainModule
                    (\g -> Expect.equal [ "g:h" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        , Test.test "F3: a saturated kernel-alias call becomes a kernel call" <|
            \_ ->
                withGraph kernelCallModule
                    (\g -> Expect.equal [ "k:Basics.add" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        , Test.test "F3: the caller's deps gain the kernel global" <|
            \_ ->
                withGraph kernelCallModule
                    (\g ->
                        case nodeDeps g "testValue" of
                            Just deps ->
                                if EverySet.member TOpt.toComparableGlobal (TOpt.toKernelGlobal "Basics") deps then
                                    Expect.pass

                                else
                                    Expect.fail "deps does not contain Elm.Kernel.Basics"

                            Nothing ->
                                Expect.fail "no testValue node"
                    )
        , Test.test "F3: the kernel call is counted" <|
            \_ ->
                withMetrics kernelCallModule
                    (\m -> Expect.equal ( 1, 1, 1 ) ( m.callsRewritten, m.callsRewrittenKernel, m.depsExtended ))
        , Test.test "F6: an under-applied kernel-alias call keeps the alias (§3.2 amendment)" <|
            \_ ->
                withGraph kernelPartialModule
                    (\g ->
                        if List.member "g:add" (List.concatMap calleeNames (bodyOf g "testValue")) then
                            Expect.pass

                        else
                            Expect.fail "the partial call of the kernel alias was forwarded"
                    )
        , Test.test "F6: the kept partial is counted, and not as a value" <|
            \_ ->
                withMetrics kernelPartialModule
                    (\m -> Expect.equal ( 1, 0, 0 ) ( m.callsKeptKernelPartial, m.argRefsKeptKernel, m.callsRewritten ))
        , Test.test "F3-poly: a POLYMORPHIC kernel alias's saturated call keeps the alias (ABI is per-occurrence)" <|
            \_ ->
                withGraph kernelPolyModule
                    (\g -> Expect.equal [ "g:pick" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        , Test.test "F3-poly: the kept call is counted" <|
            \_ ->
                withMetrics kernelPolyModule
                    (\m -> Expect.equal ( 1, 0 ) ( m.callsKeptKernelPoly, m.callsRewritten ))
        , Test.test "F3-suffix: a polymorphic SUFFIX-SELECTING kernel alias (List.cons) is forwarded" <|
            \_ ->
                withGraph kernelConsModule
                    (\g -> Expect.equal [ "k:List.cons" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        ]



-- ============================================================================
-- ARGUMENT POSITION
-- ============================================================================


{-| Checks that an alias passed as a value is forwarded when its target is a
global and kept when it is a kernel, and the counters each case moves.
-}
valueSuite : Test
valueSuite =
    Test.describe "Argument position"
        [ Test.test "F4: a ToGlobal alias passed as a value is forwarded" <|
            \_ ->
                withGraph valueModule
                    (\g ->
                        let
                            refs =
                                List.concatMap valueRefNames (bodyOf g "testValue")
                        in
                        Expect.equal ( True, False ) ( List.member "inc" refs, List.member "f" refs )
                    )
        , Test.test "F4: the value is counted" <|
            \_ ->
                withMetrics valueModule (\m -> Expect.equal ( 1, 0 ) ( m.argRefsRewritten, m.callsRewritten ))
        , Test.test "F5: a kernel alias passed as a value is NOT forwarded (R6)" <|
            \_ ->
                withGraph kernelValueModule
                    (\g ->
                        if List.member "add" (List.concatMap valueRefNames (bodyOf g "testValue")) then
                            Expect.pass

                        else
                            Expect.fail "the kernel alias value was forwarded"
                    )
        , Test.test "F5: the kept kernel value is counted" <|
            \_ ->
                withMetrics kernelValueModule
                    (\m -> Expect.equal ( 1, 0 ) ( m.argRefsKeptKernel, m.argRefsRewritten ))
        ]



-- ============================================================================
-- CYCLE BODIES
-- ============================================================================


{-| Checks that a call of an alias inside a `Cycle` node is forwarded, after
checking that the fixture produces a `Cycle` node at all.
-}
cycleSuite : Test
cycleSuite =
    Test.describe "Cycle bodies"
        [ Test.test "F7: the fixture produces a Cycle node" <|
            \_ ->
                withGraph cycleModule
                    (\g ->
                        if List.isEmpty (cycleBodies g) then
                            Expect.fail "no Cycle node — the fixture is not recursive"

                        else
                            Expect.pass
                    )
        , Test.test "F7: an alias called from inside a Cycle member is forwarded" <|
            \_ ->
                withGraph cycleModule
                    (\g ->
                        let
                            callees =
                                List.concatMap calleeNames (cycleBodies g)
                        in
                        Expect.equal ( True, False ) ( List.member "g:inc" callees, List.member "g:f" callees )
                    )
        ]



-- ============================================================================
-- AN ALIAS TYPED THROUGH A TYPE ALIAS
-- ============================================================================


{-| Checks that an alias whose annotation names a type alias is forwarded in
call and in argument position with the references' metas kept, and that the
fixture has the two references the meta comparison relies on.
-}
docAliasSuite : Test
docAliasSuite =
    Test.describe "Alias typed through a type alias"
        [ Test.test "F8: forwarded in call position" <|
            \_ ->
                withGraph docModule
                    (\g ->
                        let
                            callees =
                                List.concatMap calleeNames (bodyOf g "testValue")
                        in
                        Expect.equal ( True, False ) ( List.member "g:mk" callees, List.member "g:fromChars" callees )
                    )
        , Test.test "F8: forwarded in argument position" <|
            \_ ->
                withGraph docModule
                    (\g ->
                        let
                            refs =
                                List.concatMap valueRefNames (bodyOf g "testValue")
                        in
                        Expect.equal ( True, False ) ( List.member "mk" refs, List.member "fromChars" refs )
                    )
        , Test.test "F8: both references keep their metas" <|
            \_ ->
                withBefore docModule
                    (\before after ->
                        Expect.equal
                            (List.concatMap (refMetas "fromChars") (bodyOf before "testValue"))
                            (List.concatMap (refMetas "mk") (bodyOf after "testValue"))
                    )
        , Test.test "F8: the metas were actually compared (two references)" <|
            \_ ->
                withBefore docModule
                    (\before _ -> Expect.equal 2 (List.length (List.concatMap (refMetas "fromChars") (bodyOf before "testValue"))))
        ]



-- ============================================================================
-- INERT WITH THE FLAG OFF
-- ============================================================================


{-| Checks `AliasForward.run` with `aliasForward` off: `testValue`'s callees are
unchanged, and the metrics still count the call that would be forwarded.
-}
inertSuite : Test
inertSuite =
    Test.describe "Flag off"
        [ Test.test "the graph is returned untouched" <|
            \_ ->
                withAssigned simpleModule
                    (\assigned ->
                        let
                            ( after, _, _ ) =
                                AliasForward.run offInline assigned.mvarState assigned.graph
                        in
                        Expect.equal (List.concatMap calleeNames (bodyOf assigned.graph "testValue")) (List.concatMap calleeNames (bodyOf after "testValue"))
                    )
        , Test.test "the census is still computed" <|
            \_ ->
                withAssigned simpleModule
                    (\assigned ->
                        let
                            ( _, _, m ) =
                                AliasForward.run offInline assigned.mvarState assigned.graph
                        in
                        Expect.equal 1 m.callsRewritten
                    )
        ]



-- ============================================================================
-- HARNESS
-- ============================================================================


{-| The default inline configuration with alias forwarding on.
-}
afwdConfig : Config.InlineConfig
afwdConfig =
    { defaultInline | aliasForward = True }


{-| The inline configuration of `Config.default`.
-}
defaultInline : Config.InlineConfig
defaultInline =
    Config.default.inline


{-| The default inline configuration with alias forwarding off. It is set
explicitly so that the flag-off tests do not depend on the default value of
`aliasForward`.
-}
offInline : Config.InlineConfig
offInline =
    { defaultInline | aliasForward = False }


{-| Runs `check` on the `EntryPrep.Assigned` result (the graph, its id state and
the flags-decoder global) that `TestPipeline.runToAssigned` gives for
`srcModule`, or fails with the pipeline's message if any stage fails.
-}
withAssigned : Src.Module -> (EntryPrep.Assigned -> Expect.Expectation) -> Expect.Expectation
withAssigned srcModule check =
    case Pipeline.runToAssigned srcModule of
        Err msg ->
            Expect.fail msg

        Ok assigned ->
            check assigned


{-| Runs `check` on the metrics of `AliasForward.run`, with forwarding on, over
the assigned graph of `srcModule`.
-}
withMetrics : Src.Module -> (AliasForward.Metrics -> Expect.Expectation) -> Expect.Expectation
withMetrics srcModule check =
    withAssigned srcModule
        (\assigned ->
            let
                ( _, _, m ) =
                    AliasForward.run afwdConfig assigned.mvarState assigned.graph
            in
            check m
        )


{-| Runs `check` on the graph `AliasForward.run` returns, with forwarding on,
for the assigned graph of `srcModule`.
-}
withGraph : Src.Module -> (TOpt.GlobalGraph TypeIds.MVarId -> Expect.Expectation) -> Expect.Expectation
withGraph srcModule check =
    withBefore srcModule (\_ after -> check after)


{-| Runs `check` on the assigned graph of `srcModule` and on the graph
`AliasForward.run` returns for it with forwarding on, in that order.
-}
withBefore : Src.Module -> (TOpt.GlobalGraph TypeIds.MVarId -> TOpt.GlobalGraph TypeIds.MVarId -> Expect.Expectation) -> Expect.Expectation
withBefore srcModule check =
    withAssigned srcModule
        (\assigned ->
            let
                ( after, _, _ ) =
                    AliasForward.run afwdConfig assigned.mvarState assigned.graph
            in
            check assigned.graph after
        )



-- ====== STRUCTURAL READERS ======


{-| Returns the name of a target that is a global, or `Nothing` for a kernel
target.
-}
globalTargetName : AliasForward.Target -> Maybe Name
globalTargetName t =
    case t of
        AliasForward.ToGlobal (TOpt.Global _ n) ->
            Just n

        AliasForward.ToKernel _ _ _ _ _ ->
            Nothing


{-| Returns the global of a node called `name`, in whatever module. If several
nodes have that name, it returns the last in the graph's key order.
-}
globalNamed : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe TOpt.Global
globalNamed (TOpt.GlobalGraph nodes _ _ _ _) name =
    Data.Map.foldl
        (\((TOpt.Global _ n) as g) _ acc ->
            if n == name then
                Just g

            else
                acc
        )
        Nothing
        nodes


{-| Returns the body of the `Define` or `TrackedDefine` node called `name`, in
whatever module, or `Nothing` if there is none. If several have that name, it
returns the last in the graph's key order.
-}
nodeBody : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe (TOpt.Expr TypeIds.MVarId)
nodeBody (TOpt.GlobalGraph nodes _ _ _ _) name =
    Data.Map.foldl
        (\(TOpt.Global _ n) node acc ->
            if n == name then
                case node of
                    TOpt.Define e _ _ ->
                        Just e

                    TOpt.TrackedDefine _ e _ _ ->
                        Just e

                    _ ->
                        acc

            else
                acc
        )
        Nothing
        nodes


{-| Returns the `deps` of the `Define` or `TrackedDefine` node called `name`, in
whatever module, or `Nothing` if there is none. If several have that name, it
returns the last in the graph's key order.
-}
nodeDeps : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe (EverySet.EverySet String TOpt.Global)
nodeDeps (TOpt.GlobalGraph nodes _ _ _ _) name =
    Data.Map.foldl
        (\(TOpt.Global _ n) node acc ->
            if n == name then
                case node of
                    TOpt.Define _ deps _ ->
                        Just deps

                    TOpt.TrackedDefine _ _ deps _ ->
                        Just deps

                    _ ->
                        acc

            else
                acc
        )
        Nothing
        nodes


{-| Returns the body `nodeBody` finds for `name` as a one-element list, or an
empty list if it finds none. The tests pass the list to the readers below, so a
missing node shows up as an empty result rather than as a `Maybe`.
-}
bodyOf : TOpt.GlobalGraph TypeIds.MVarId -> Name -> List (TOpt.Expr TypeIds.MVarId)
bodyOf g name =
    Maybe.withDefault [] (Maybe.map List.singleton (nodeBody g name))


{-| Returns the body of every definition in every `Cycle` node of the graph:
its values, and its functions whether `Def` or `TailDef`.
-}
cycleBodies : TOpt.GlobalGraph TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
cycleBodies (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl
        (\_ node acc ->
            case node of
                TOpt.Cycle _ values defs _ ->
                    List.map Tuple.second values
                        ++ List.map
                            (\def ->
                                case def of
                                    TOpt.Def _ _ body _ ->
                                        body

                                    TOpt.TailDef _ _ _ body _ _ ->
                                        body
                            )
                            defs
                        ++ acc

                _ ->
                    acc
        )
        []
        nodes


{-| Returns the callee of every `Call` in `expr` whose callee is a `VarGlobal`
or a `VarKernel`, in pre-order, as `g:name` for a global and `k:home.name` for a
kernel. A global's module is not included.
-}
calleeNames : TOpt.Expr TypeIds.MVarId -> List String
calleeNames expr =
    (case expr of
        TOpt.Call _ (TOpt.VarGlobal _ (TOpt.Global _ n) _) _ _ ->
            [ "g:" ++ n ]

        TOpt.Call _ (TOpt.VarKernel _ _ home name _) _ _ ->
            [ "k:" ++ home ++ "." ++ name ]

        _ ->
            []
    )
        ++ List.concatMap calleeNames (children expr)


{-| Returns the name of every `VarGlobal` in `expr` that is not the callee of a
`Call`.
-}
valueRefNames : TOpt.Expr TypeIds.MVarId -> List String
valueRefNames expr =
    case expr of
        TOpt.VarGlobal _ (TOpt.Global _ n) _ ->
            [ n ]

        TOpt.Call _ func args _ ->
            (case func of
                TOpt.VarGlobal _ _ _ ->
                    []

                TOpt.VarKernel _ _ _ _ _ ->
                    []

                _ ->
                    valueRefNames func
            )
                ++ List.concatMap valueRefNames args

        _ ->
            List.concatMap valueRefNames (children expr)


{-| Returns the meta of every `VarGlobal` called `name` in `expr`, whether a
callee or a value, in pre-order.
-}
refMetas : Name -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Meta TypeIds.MVarId)
refMetas name expr =
    (case expr of
        TOpt.VarGlobal _ (TOpt.Global _ n) meta ->
            if n == name then
                [ meta ]

            else
                []

        _ ->
            []
    )
        ++ List.concatMap (refMetas name) (children expr)


{-| Returns the direct subexpressions of `expr`, including the expressions in a
`Case`'s decision tree and branches and a `Let`'s bound definition.
-}
children : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
children expr =
    case expr of
        TOpt.List _ items _ ->
            items

        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Call _ f args _ ->
            f :: args

        TOpt.TailCall _ args _ ->
            List.map Tuple.second args

        TOpt.If branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        TOpt.Let def body _ ->
            (case def of
                TOpt.Def _ _ bound _ ->
                    [ bound ]

                TOpt.TailDef _ _ _ b _ _ ->
                    [ b ]
            )
                ++ [ body ]

        TOpt.Destruct _ body _ ->
            [ body ]

        TOpt.Case _ _ decider jumps _ ->
            deciderChildren decider ++ List.map Tuple.second jumps

        TOpt.Access inner _ _ _ ->
            [ inner ]

        TOpt.Update _ record fields _ ->
            record :: Data.Map.values fields

        TOpt.Record fields _ ->
            CoreDict.values fields

        TOpt.TrackedRecord _ fields _ ->
            Data.Map.values fields

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        _ ->
            []


{-| Returns the expressions held inline in the leaves of a decision tree.
-}
deciderChildren : TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> List (TOpt.Expr TypeIds.MVarId)
deciderChildren decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            [ e ]

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ ok ko ->
            deciderChildren ok ++ deciderChildren ko

        TOpt.FanOut _ branches fallback ->
            List.concatMap (\( _, d ) -> deciderChildren d) branches
                ++ deciderChildren fallback



-- ============================================================================
-- FIXTURES
-- ============================================================================
--
-- Every fixture defines `testValue`, because `TestPipeline` requires one; the
-- call- and argument-position assertions read its body.


{-| The type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| Returns the type `List inner`.
-}
tList : Src.Type -> Src.Type
tList inner =
    tType "List" [ inner ]


{-| Builds a module named `Test` with `defs` as its annotated top-level values
and `aliases` as its type aliases.
-}
modOf : List TypedDef -> List AliasDef -> Src.Module
modOf defs aliases =
    makeModuleWithTypedDefsUnionsAliasesExtended "Test" defs [] aliases


{-| The definition `inc : Int -> Int; inc x = x`. It returns its argument
unchanged, whatever its name suggests, and it has a parameter, so it is not an
alias.
-}
incDef : TypedDef
incDef =
    { name = "inc", args = [ pVar "x" ], tipe = tLambda tInt tInt, body = varExpr "x" }


{-| Returns the alias definition `name : Int -> Int; name = target`.
-}
aliasOf : Name -> Name -> TypedDef
aliasOf name target =
    { name = name, args = [], tipe = tLambda tInt tInt, body = varExpr target }


{-| The kernel alias `add : Int -> Int -> Int; add = Elm.Kernel.Basics.add`.
-}
kernelAddDef : TypedDef
kernelAddDef =
    { name = "add"
    , args = []
    , tipe = tLambda tInt (tLambda tInt tInt)
    , body = qualVarExpr "Elm.Kernel.Basics" "add"
    }


{-| Returns the definition `testValue : tipe; testValue = body`.
-}
testValueDef : Src.Type -> Src.Expr -> TypedDef
testValueDef tipe body =
    { name = "testValue", args = [], tipe = tipe, body = body }


{-| `inc`, the alias `f = inc`, and `testValue = f 1`.
-}
simpleModule : Src.Module
simpleModule =
    modOf
        [ incDef
        , aliasOf "f" "inc"
        , testValueDef tInt (callExpr (varExpr "f") [ intExpr 1 ])
        ]
        []


{-| `h x = x`, the aliases `g = h` and `f = g`, and `testValue = f 1`.
-}
chainModule : Src.Module
chainModule =
    modOf
        [ { incDef | name = "h" }
        , aliasOf "g" "h"
        , aliasOf "f" "g"
        , testValueDef tInt (callExpr (varExpr "f") [ intExpr 1 ])
        ]
        []


{-| The kernel alias `pick : a -> a; pick = Elm.Kernel.Basics.identity`, and
`testValue : Int; testValue = pick 1`. `pick`'s type has a type variable, and
`( "Basics", "identity" )` is not in `KernelAbi.suffixSelectingKernels`.
-}
kernelPolyModule : Src.Module
kernelPolyModule =
    modOf
        [ { name = "pick"
          , args = []
          , tipe = tLambda (tVar "a") (tVar "a")
          , body = qualVarExpr "Elm.Kernel.Basics" "identity"
          }
        , testValueDef tInt (callExpr (varExpr "pick") [ intExpr 1 ])
        ]
        []


{-| The kernel alias
`cons : a -> List a -> List a; cons = Elm.Kernel.List.cons`, and
`testValue : List Int; testValue = cons 1 [ 2 ]`. `cons`'s type has a type
variable, but `List.cons` is in `KernelAbi.suffixSelectingKernels`.
-}
kernelConsModule : Src.Module
kernelConsModule =
    modOf
        [ { name = "cons"
          , args = []
          , tipe = tLambda (tVar "a") (tLambda (tList (tVar "a")) (tList (tVar "a")))
          , body = qualVarExpr "Elm.Kernel.List" "cons"
          }
        , testValueDef (tList tInt) (callExpr (varExpr "cons") [ intExpr 1, listExpr [ intExpr 2 ] ])
        ]
        []


{-| The kernel alias `add`, and `testValue = add 1 2`, a call with as many
arguments as `add`'s type has arrows.
-}
kernelCallModule : Src.Module
kernelCallModule =
    modOf
        [ kernelAddDef
        , testValueDef tInt (callExpr (varExpr "add") [ intExpr 1, intExpr 2 ])
        ]
        []


{-| The kernel alias `add`, and `testValue = List.map (add 1) [ 1 ]`, in which
`add` is called with one argument of two.
-}
kernelPartialModule : Src.Module
kernelPartialModule =
    modOf
        [ kernelAddDef
        , testValueDef (tList tInt)
            (callExpr (qualVarExpr "List" "map")
                [ callExpr (varExpr "add") [ intExpr 1 ], listExpr [ intExpr 1 ] ]
            )
        ]
        []


{-| `inc`, the alias `f = inc`, and `testValue = List.map f [ 1 ]`, in which `f`
is passed as a value.
-}
valueModule : Src.Module
valueModule =
    modOf
        [ incDef
        , aliasOf "f" "inc"
        , testValueDef (tList tInt)
            (callExpr (qualVarExpr "List" "map") [ varExpr "f", listExpr [ intExpr 1 ] ])
        ]
        []


{-| The kernel alias `add`, and `testValue = List.foldl add 0 [ 1 ]`, in which
`add` is passed as a value.
-}
kernelValueModule : Src.Module
kernelValueModule =
    modOf
        [ kernelAddDef
        , testValueDef tInt
            (callExpr (qualVarExpr "List" "foldl") [ varExpr "add", intExpr 0, listExpr [ intExpr 1 ] ])
        ]
        []


{-| `inc`, the alias `f = inc`, `testValue = loop 3`, and a recursive `loop`,
whose self-call is not in tail position, that calls `f` in both branches:

    loop n =
        if n == 0 then
            f n

        else
            f (loop (n - 1))

-}
cycleModule : Src.Module
cycleModule =
    modOf
        [ incDef
        , aliasOf "f" "inc"
        , { name = "loop"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt tInt
          , body =
                ifExpr (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (callExpr (varExpr "f") [ varExpr "n" ])
                    (callExpr (varExpr "f")
                        [ callExpr (varExpr "loop") [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ] ]
                    )
          }
        , testValueDef tInt (callExpr (varExpr "loop") [ intExpr 3 ])
        ]
        []


{-| `type alias Doc = List Int`, `mk : Int -> Doc; mk x = [ x ]`, the alias
`fromChars : Int -> Doc; fromChars = mk`, and
`testValue = fromChars 1 ++ List.concat (List.map fromChars [ 2 ])`, which
refers to `fromChars` once as a callee and once as a value.
-}
docModule : Src.Module
docModule =
    let
        tDoc =
            tType "Doc" []
    in
    modOf
        [ { name = "mk", args = [ pVar "x" ], tipe = tLambda tInt tDoc, body = listExpr [ varExpr "x" ] }
        , { name = "fromChars", args = [], tipe = tLambda tInt tDoc, body = varExpr "mk" }
        , testValueDef tDoc
            (binopsExpr [ ( callExpr (varExpr "fromChars") [ intExpr 1 ], "++" ) ]
                (callExpr (qualVarExpr "List" "concat")
                    [ callExpr (qualVarExpr "List" "map") [ varExpr "fromChars", listExpr [ intExpr 2 ] ] ]
                )
            )
        ]
        [ { name = "Doc", args = [], tipe = tList tInt } ]
