module Compiler.GlobalOpt.CsePurity exposing
    ( Oracle, analyze, safeSpecCount
    , isSafeCall, isSafeExpr
    , costOf, countLocalUses
    )

{-| Common subexpression elimination (CSE) merges structurally equal
expressions into one shared value, and this module decides which calls it may
merge without changing what the program does.

CSE aims to merge only calls whose repeated evaluation cannot be observed, and
this module approximates that. Two kinds of callee need two kinds of answer.

A kernel, a function implemented outside Elm, is judged by its row in
`Compiler.GlobalOpt.KernelFacts`: it is accepted only if `hoistableFor` is
`True`, and an unlisted kernel is not.

A global spec, one specialization of a top-level Elm definition, is judged
transitively, because a function that calls `Debug.log` somewhere inside it
looks as innocent at its call site as one that does not. `analyze` therefore
works over the whole spec graph. It gives each spec with a body a direct
verdict, which is that the body mentions no `Debug` kernel outside closure
captures, and records every global spec the body mentions as a callee outside
closure captures. It then repeatedly marks unsafe any spec with an unsafe
callee, until nothing changes. Unsafety, the _poison_, travels from callee to
caller, and a spec only ever moves from safe to unsafe, so this terminates. The
direct verdict looks for `Debug` and nothing else: a spec whose body calls some
other kernel with effects is not poisoned by it.

`analyze` finds the call edges itself from the spec bodies and does not read
the graph's `callEdges`, `specHasEffects` or `specValueUsed`.

The rest of the module is a cost measure, `costOf`, and a use counter,
`countLocalUses`. The child traversal `foldChildren` is shared by `scanBody`,
`isSafeExpr` and `countLocalUses`; `costOf` walks expressions separately.

@docs Oracle, analyze, safeSpecCount
@docs isSafeCall, isSafeExpr
@docs costOf, countLocalUses

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..))
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Dict


{-| The answers `analyze` computes for one graph: two sets of spec ids, for two
different questions.

`safeSpecs` holds the specs in which no `Debug` kernel was found, directly or
through the global specs they mention, outside closure captures and function
values passed in. Constructor and enumeration specs are in it. This set is
sound for the `List.map` template only together with that template's own rule
about arguments, in `Compiler.GlobalOpt.MapTemplate`.

`mergeableSpecs` holds the specs two structurally equal calls of which may
become one value. It is computed in the same way but leaves out constructor
and enumeration specs. Merging two constructions makes two allocations one, and
equality compares by pointer before it compares contents, so two merged values
holding `NaN` would compare equal where two separate ones do not.

A spec id absent from either set is unsafe for that question, including the id
of a `MonoExtern` or `MonoManagerLeaf` spec, which is never in either.

-}
type alias Oracle =
    { safeSpecs : BitSet
    , mergeableSpecs : BitSet
    }


{-| Returns the number of specs in `safeSpecs`.
-}
safeSpecCount : Oracle -> Int
safeSpecCount oracle =
    BitSet.count oracle.safeSpecs



-- KERNEL CALLS


{-| Returns whether the kernel `name` in module `home` may be merged, which is
its `KernelFacts` row's `hoistable` fact, and `False` for an unlisted kernel.
-}
kernelCseSafe : Name -> Name -> Bool
kernelCseSafe home name =
    KernelFacts.hoistableFor ( home, name )



-- GLOBAL SPECS


{-| Builds the `Oracle` for a graph.

A spec with a body starts in both sets when its body mentions no `Debug`
kernel outside closure captures. A constructor or enumeration spec starts in
`safeSpecs` only. Any other spec, and an empty slot in the graph, starts in
neither. Each set is then reduced separately: a spec with a body is removed
while any spec its body mentions is absent, until a full pass removes nothing.

-}
analyze : Mono.MonoGraph -> Oracle
analyze (Mono.MonoGraph g) =
    let
        noSpecs =
            BitSet.fromSize (Array.length g.nodes)

        scan =
            Array.foldl
                (\maybeNode ( sid, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( sid + 1, acc )

                        Just node ->
                            case bodyOf node of
                                Nothing ->
                                    ( sid + 1
                                    , if isPureConstruction node then
                                        { acc | safeSeed = BitSet.insert sid acc.safeSeed }

                                      else
                                        acc
                                    )

                                Just body ->
                                    let
                                        ( direct, callees ) =
                                            scanBody body
                                    in
                                    ( sid + 1
                                    , { acc
                                        | safeSeed = insertIf direct sid acc.safeSeed
                                        , mergeSeed = insertIf direct sid acc.mergeSeed
                                        , edges = Dict.insert sid callees acc.edges
                                      }
                                    )
                )
                ( 0, { safeSeed = noSpecs, mergeSeed = noSpecs, edges = Dict.empty } )
                g.nodes
                |> Tuple.second

        settle safe =
            let
                ( next, changed ) =
                    Dict.foldl
                        (\sid callees ( acc, dirty ) ->
                            if BitSet.member sid acc && List.any (\c -> not (BitSet.member c acc)) callees then
                                ( BitSet.remove sid acc, True )

                            else
                                ( acc, dirty )
                        )
                        ( safe, False )
                        scan.edges
            in
            if changed then
                settle next

            else
                next
    in
    { safeSpecs = settle scan.safeSeed
    , mergeableSpecs = settle scan.mergeSeed
    }


{-| Returns `set` with `sid` added when `cond` is `True`, and `set` unchanged
otherwise.
-}
insertIf : Bool -> Int -> BitSet -> BitSet
insertIf cond sid set =
    if cond then
        BitSet.insert sid set

    else
        set


{-| Returns whether a node is a `MonoCtor` or a `MonoEnum`, the specs that build
a value and so cannot reach `Debug`.
-}
isPureConstruction : Mono.MonoNode -> Bool
isPureConstruction node =
    case node of
        Mono.MonoCtor _ _ ->
            True

        Mono.MonoEnum _ _ ->
            True

        _ ->
            False


{-| Returns the expression a node is defined by, for a `MonoDefine`, a
`MonoTailFunc` and the two port kinds, and `Nothing` for every other node.
-}
bodyOf : Mono.MonoNode -> Maybe MonoExpr
bodyOf node =
    case node of
        Mono.MonoDefine body _ ->
            Just body

        Mono.MonoTailFunc _ body _ ->
            Just body

        Mono.MonoPortIncoming body _ ->
            Just body

        Mono.MonoPortOutgoing body _ ->
            Just body

        _ ->
            Nothing


{-| Returns whether `root` mentions no `Debug` kernel, and the ids of the
global specs it mentions, whether called or only referred to.

The walk stops collecting at the first `Debug` kernel, so the list is complete
only when the verdict is `True`. Expressions inside a closure's captures are
not visited, as `foldChildren` describes.

-}
scanBody : MonoExpr -> ( Bool, List Int )
scanBody root =
    let
        go expr ( ok, callees ) =
            if not ok then
                ( False, callees )

            else
                case expr of
                    MonoVarKernel _ _ home _ _ ->
                        ( home /= "Debug", callees )

                    MonoVarGlobal _ sid _ ->
                        ( True, sid :: callees )

                    MonoCall _ func args _ _ ->
                        List.foldl go (go func ( ok, callees )) args

                    _ ->
                        foldChildren go ( ok, callees ) expr
    in
    go root ( True, [] )


{-| Returns whether an expression may be merged with a structurally equal one.

Every kernel it mentions must be `hoistable` in `KernelFacts`, every global spec
it mentions must be in the oracle's `mergeableSpecs`, and it must contain no
closure and no tail call. Kernels inside a called global spec are not checked
here; that spec's place in `mergeableSpecs` stands for them, and it records
only that no `Debug` kernel was found in that spec or the global specs it
mentions.

-}
isSafeExpr : Oracle -> MonoExpr -> Bool
isSafeExpr oracle root =
    let
        go expr ok =
            if not ok then
                False

            else
                case expr of
                    MonoVarKernel _ _ home name _ ->
                        kernelCseSafe home name

                    MonoVarGlobal _ sid _ ->
                        BitSet.member sid oracle.mergeableSpecs

                    MonoClosure _ _ _ ->
                        False

                    MonoTailCall _ _ _ ->
                        False

                    _ ->
                        foldChildren go ok expr
    in
    go root True


{-| Returns `isSafeExpr` for a `MonoCall`, and `False` for any other
expression.
-}
isSafeCall : Oracle -> MonoExpr -> Bool
isSafeCall oracle expr =
    case expr of
        MonoCall _ _ _ _ _ ->
            isSafeExpr oracle expr

        _ ->
            False



-- COST


{-| Returns an approximate size of an expression.

A list, tuple or record creation costs 3 plus its parts, a call costs 5 plus
its function and arguments, whatever the callee, and a record access costs 1
plus its record. Every other expression costs 1, however large it is.

-}
costOf : MonoExpr -> Int
costOf expr =
    case expr of
        MonoList _ items _ ->
            3 + List.foldl (\i n -> n + costOf i) 0 items

        MonoCall _ func args _ _ ->
            5 + costOf func + List.foldl (\a n -> n + costOf a) 0 args

        MonoRecordCreate fields _ ->
            3 + List.foldl (\( _, e ) n -> n + costOf e) 0 fields

        MonoTupleCreate _ items _ ->
            3 + List.foldl (\i n -> n + costOf i) 0 items

        MonoRecordAccess inner _ _ ->
            1 + costOf inner

        _ ->
            1



-- LOCAL USES


{-| Returns the number of `MonoVarLocal` occurrences of `name` in `root`.

Names are compared without regard to scope, so a reference to a different
binding with the same name is counted too. References inside a closure's
captures are not counted, as `foldChildren` describes.

-}
countLocalUses : Name -> MonoExpr -> Int
countLocalUses name root =
    let
        go expr n =
            case expr of
                MonoVarLocal v _ ->
                    if v == name then
                        n + 1

                    else
                        n

                _ ->
                    foldChildren go n expr
    in
    go root 0


{-| Folds `f` over the immediate sub-expressions of `expr`, left to right.

A `case` contributes the expressions in its decider's inline leaves and then its
branches. A `let` contributes the bound expression of its definition and then
its body. A closure contributes only its body: the expressions it captures are
not visited.

The match lists every `MonoExpr` constructor, so a new one is a compile error
here rather than a case silently skipped.

-}
foldChildren : (MonoExpr -> a -> a) -> a -> MonoExpr -> a
foldChildren f acc expr =
    case expr of
        MonoLiteral _ _ ->
            acc

        MonoVarLocal _ _ ->
            acc

        MonoVarGlobal _ _ _ ->
            acc

        MonoVarKernel _ _ _ _ _ ->
            acc

        MonoUnit ->
            acc

        MonoAccessorValue _ _ _ ->
            acc

        MonoList _ items _ ->
            List.foldl f acc items

        MonoClosure _ body _ ->
            f body acc

        MonoCall _ func args _ _ ->
            List.foldl f (f func acc) args

        MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> f e a) acc args

        MonoIf branches final _ ->
            f final (List.foldl (\( c, t ) a -> f t (f c a)) acc branches)

        MonoLet def body _ ->
            f body (f (defBound def) acc)

        MonoDestruct _ body _ ->
            f body acc

        MonoCase _ _ decider branches _ ->
            List.foldl (\( _, e ) a -> f e a)
                (foldDecider f acc decider)
                branches

        MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> f e a) acc fields

        MonoRecordAccess inner _ _ ->
            f inner acc

        MonoRecordUpdate inner updates _ ->
            List.foldl (\( _, e ) a -> f e a) (f inner acc) updates

        MonoTupleCreate _ items _ ->
            List.foldl f acc items


{-| Folds `f` over the expressions in a decider's inline leaves, success branch
before failure branch and tests before fallback. A jump leaf contributes
nothing.
-}
foldDecider : (MonoExpr -> a -> a) -> a -> Mono.Decider Mono.MonoChoice -> a
foldDecider f acc decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            f e acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            foldDecider f (foldDecider f acc success) failure

        Mono.FanOut _ tests fallback ->
            foldDecider f
                (List.foldl (\( _, d ) a -> foldDecider f a d) acc tests)
                fallback


{-| Returns the expression a local definition binds, which for a tail
definition is its body.
-}
defBound : Mono.MonoDef -> MonoExpr
defBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound
