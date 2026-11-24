module Compiler.MonoOpt.Cse exposing
    ( run, Config, Mode(..)
    , Stats, emptyStats, renderStats
    )

{-| Elm code often computes the same pure call twice in one function body, as in
`if Set.member (f x) s then ... else Set.insert (f x) s`, and nothing later in
the compiler merges the two; this module binds such a call once and reuses the
value.

The pass is common subexpression elimination (CSE) over monomorphized
function bodies. A _candidate_ is a call that `CsePurity.isSafeExpr` accepts,
whose result is not a function, which contains no `let`, destructuring,
`case` or closure, and whose `CsePurity.costOf` is at least `minCost`. An
_occurrence_ is one candidate in a body together with its _path_, the list of
steps from the body's root down to it. A _group_ is two or more occurrences
that are equal once source regions are ignored. A group's _lowest common
ancestor_ (LCA) is the longest prefix shared by all of its paths. A merged
group becomes `let mono_cse_N = <one occurrence> in <LCA node>`, and every
occurrence becomes a reference to `mono_cse_N`.

Three rules decide whether a group is merged.

  - Purity. Which calls may be merged is `CsePurity`'s decision, described
    there.

  - Evaluation. Each step of a path is either unconditional, meaning the child
    is evaluated whenever its parent is, conditional, or entering a closure
    body. A group is merged only if no occurrence lies inside a closure body
    below the LCA, and at least one occurrence is reached from the LCA by
    unconditional steps alone. That occurrence is evaluated whenever the LCA
    node is, so binding the value at the LCA adds no evaluation. The one
    exception is the body of a local tail-recursive function, whose step is
    marked unconditional although it runs only when the function is called.

  - Scope. The binding is placed at the LCA and no higher. A group is dropped
    if any name bound below the LCA on the way to an occurrence is a free
    local of the candidate, whether or not it shadows another name, because
    the binding at the LCA could not see it.

Each body takes at most `maxPerDef` groups, and of groups whose occurrences
overlap only one is kept. Names `mono_cse_N` are numbered across
the whole graph.

Expressions are moved, never copied: one occurrence becomes the bound
expression and the others disappear, so no local name is duplicated.

**Hashes.** A call of the value hash, `FNV.hash x` (`Eco.Kernel.FNV.hash`), is
a candidate whatever its cost, and it is compared after _alias resolution_: the
inliner binds each argument it passes to a fresh name (`let mono_inline_3 =
key`), so two inlined SeqDict operations on one key hash two different names.
While descending, the pass keeps an alias map from a name bound by
`let n = m`, `m` a local, to the root variable `m` stands for, in the `let`'s
body only. A hash call whose argument is an alias is compared, and bound, with
the root in its place, so `let mono_cse_0 = FNV.hash key` is written with the
root name. Two rules keep the root meaning the variable the alias meant: any
other binder `x` (a `let`, a destructuring, a local tail function's name or
parameters) removes `x` from the map, as a name and as a root, in its scope;
and the map is empty inside a closure body, which sees only its parameters
and captures. The scope rule then checks the root.

**Modes.** In `General` mode the pass merges every candidate above. In
`HashOnly` mode, the default (`cse.hashMerge`), it merges hash calls only, and
only those whose argument is, after alias resolution, a local variable; it
skips a body with fewer than two hash calls and does not run the purity
analysis, since the hash kernel is pure by its `KernelFacts` row
(plans/seqdict-hash-once-per-function.md).

The inserted `let`s carry no call staging information of their own. Only
non-function values are bound, which is why candidates whose result is a
function are excluded.

@docs run, Config, Mode
@docs Stats, emptyStats, renderStats

-}

import Array
import Compiler.Core.Name exposing (Name)
import Compiler.IR.Kernel.Facts as KernelFacts
import Compiler.IR.Mono as Mono exposing (MonoExpr(..))
import Compiler.MonoOpt.CafHoist as CafHoist
import Compiler.MonoOpt.CsePurity as CsePurity
import Data.BitSet as BitSet
import Data.NonEmptyList as NE
import Dict exposing (Dict)
import Set exposing (Set)


{-| Counters for one run of the pass.

`groups` and `merged` are counted before overlapping groups are dropped, so
they can exceed what was applied: `groups` is groups that passed every test,
and `merged` is their occurrences other than the first. `letsInserted` counts
the groups actually bound, and `specsTouched` the bodies that received at least
one. `shadowBlocked` counts groups dropped by the scope rule, and
`budgetExhausted` counts groups of equal occurrences turned away because the
body already had `maxPerDef` groups, before any other test was applied to them.
`hashGroups` and `hashMerged` count the groups of hash calls among `groups`,
and their occurrences other than the first among `merged`.

-}
type alias Stats =
    { specsTouched : Int
    , groups : Int
    , merged : Int
    , letsInserted : Int
    , shadowBlocked : Int
    , budgetExhausted : Int
    , hashGroups : Int
    , hashMerged : Int
    }


{-| All counters at zero.
-}
emptyStats : Stats
emptyStats =
    { specsTouched = 0
    , groups = 0
    , merged = 0
    , letsInserted = 0
    , shadowBlocked = 0
    , budgetExhausted = 0
    , hashGroups = 0
    , hashMerged = 0
    }


{-| Returns the counters as one line beginning `mono-cse:`.
-}
renderStats : Stats -> String
renderStats s =
    "mono-cse: specsTouched="
        ++ String.fromInt s.specsTouched
        ++ " groups="
        ++ String.fromInt s.groups
        ++ " merged="
        ++ String.fromInt s.merged
        ++ " letsInserted="
        ++ String.fromInt s.letsInserted
        ++ " shadowBlocked="
        ++ String.fromInt s.shadowBlocked
        ++ " budgetExhausted="
        ++ String.fromInt s.budgetExhausted
        ++ " hashGroups="
        ++ String.fromInt s.hashGroups
        ++ " hashMerged="
        ++ String.fromInt s.hashMerged



-- PATHS


{-| The steps from a body's root down to one expression, one string per step.

A step's first letter classifies it. `u` is unconditional: call function and
arguments, tail call arguments, list, tuple and record elements, the record of
an access or update, the bound expression and body of a `let`, the body of a
destructuring, and the first condition of an `if`. `b` is conditional: later
`if` conditions, every `if` branch and the final `else`, `case` branches, and
expressions inline in a `case` decision tree. `c` is the body of a closure. The
rest of the step says which child it is, so two different expressions in one
body never share a path.

-}
type alias Path =
    List String


{-| Returns the path as one string with steps joined by `/`, for use as a
`Dict` key.
-}
pathKey : Path -> String
pathKey =
    String.join "/"


{-| Returns whether every step of a path suffix is unconditional.
-}
dominates : List String -> Bool
dominates =
    List.all (\s -> String.startsWith "u" s)


{-| Returns whether a path suffix enters a closure body.
-}
hasClosure : List String -> Bool
hasClosure =
    List.any (\s -> String.startsWith "c" s)



-- OCCURRENCES


{-| One occurrence of a candidate in a body.

`key` is `CafHoist.kindTagOf` of the call and `shape` is the call with its
source regions zeroed, after alias resolution for a hash call; occurrences are
grouped by equal `shape`. `orig` is the call as written, and `canonical` the
call a group binds: `orig` with aliases resolved for a hash call, `orig` itself
otherwise. `binders` holds the names bound by lets and destructurings
above the occurrence, and a local tail-recursive function's parameters within
its body, each with the length of the path at which it comes into scope.

-}
type alias Occ =
    { key : String
    , shape : MonoExpr
    , orig : MonoExpr
    , canonical : MonoExpr
    , ty : Mono.MonoType
    , path : Path
    , binders : List ( Int, Name )
    , cost : Int
    }


{-| A group that passed every test: where its `let` goes (`lca`), the path
keys of its occurrences, the expression it binds, that expression's type, and
the name it binds it to.
-}
type alias Group =
    { lca : Path
    , occPaths : Set String
    , bound : MonoExpr
    , ty : Mono.MonoType
    , name : Name
    }



-- ENTRY


{-| What the pass merges: every candidate (`General`, `ECO_CSE`), or only hash
calls (`HashOnly`, `cse.hashMerge`). The module docstring describes both.
-}
type Mode
    = General
    | HashOnly


{-| The pass's settings: the cost floor of a candidate other than a hash call,
the cap on groups per body, and the mode.
-}
type alias Config =
    { minCost : Int, maxPerDef : Int, mode : Mode }


{-| Runs the pass over the body of every `MonoDefine` and `MonoTailFunc` node in
the graph, and returns the rewritten graph with the counters.

Candidates other than hash calls must cost at least `minCost` by
`CsePurity.costOf`, and at most `maxPerDef` groups are bound in each body. Only those bodies change: every
other node, the empty slots of the node array, and every node's index are
kept, and no node is added or removed.

-}
run : Config -> Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
run cfg ((Mono.MonoGraph g) as graph) =
    let
        -- HashOnly mode admits hash calls on the kernel's row alone.
        oracle =
            case cfg.mode of
                General ->
                    CsePurity.analyze graph

                HashOnly ->
                    { safeSpecs = BitSet.empty, mergeableSpecs = BitSet.empty }

        ( nodes1, stats1, _ ) =
            Array.foldl
                (\maybeNode ( acc, st, counter ) ->
                    case maybeNode of
                        Nothing ->
                            -- Kept so that every node keeps its index.
                            ( Array.push Nothing acc, st, counter )

                        Just node ->
                            let
                                ( node1, st1, counter1 ) =
                                    rewriteNode oracle cfg node st counter
                            in
                            ( Array.push (Just node1) acc, st1, counter1 )
                )
                ( Array.empty, emptyStats, 0 )
                g.nodes
    in
    ( Mono.MonoGraph { g | nodes = nodes1 }, stats1 )


{-| Rewrites the body of a `MonoDefine` or `MonoTailFunc` node and returns any
other node unchanged, threading the counters and the next `mono_cse_N` number.
-}
rewriteNode : CsePurity.Oracle -> Config -> Mono.MonoNode -> Stats -> Int -> ( Mono.MonoNode, Stats, Int )
rewriteNode oracle cfg node stats counter =
    case node of
        Mono.MonoDefine body ty ->
            let
                ( body1, st, c ) =
                    rewriteBody oracle cfg body stats counter
            in
            ( Mono.MonoDefine body1 ty, st, c )

        Mono.MonoTailFunc params body ty ->
            let
                ( body1, st, c ) =
                    rewriteBody oracle cfg body stats counter
            in
            ( Mono.MonoTailFunc params body1 ty, st, c )

        other ->
            ( other, stats, counter )


{-| Returns `body` with every kept group merged, together with the updated
counters and the next `mono_cse_N` number.

Occurrences are bucketed by kind tag and then by result type before groups are
formed in each bucket. The order buckets are visited in decides which of two
overlapping groups is kept.

-}
rewriteBody : CsePurity.Oracle -> Config -> MonoExpr -> Stats -> Int -> ( MonoExpr, Stats, Int )
rewriteBody oracle cfg body stats counter =
    if cfg.mode == HashOnly && countHashCalls body < 2 then
        ( body, stats, counter )

    else
        rewriteBodyWith oracle cfg body stats counter


{-| `rewriteBody` without the `HashOnly` pre-scan.
-}
rewriteBodyWith : CsePurity.Oracle -> Config -> MonoExpr -> Stats -> Int -> ( MonoExpr, Stats, Int )
rewriteBodyWith oracle cfg body stats counter =
    let
        occs =
            collect { oracle = oracle, cfg = cfg } body [] [] Dict.empty []

        buckets =
            List.foldl
                (\o d ->
                    Dict.update o.key
                        (\m ->
                            let
                                inner =
                                    Maybe.withDefault Mono.specMapEmpty m

                                prev =
                                    Maybe.withDefault [] (Mono.specMapGet o.ty inner)
                            in
                            Just (Mono.specMapInsert o.ty (o :: prev) inner)
                        )
                        d
                )
                Dict.empty
                occs

        ( allGroups, stats1, counter1 ) =
            Dict.foldl
                (\_ inner acc ->
                    Mono.specMapFoldl (\_ members acc2 -> formGroups cfg members acc2) acc inner
                )
                ( [], stats, counter )
                buckets

        groups =
            dropOverlapping allGroups
    in
    if List.isEmpty groups then
        ( body, stats1, counter1 )

    else
        let
            byOcc =
                List.foldl
                    (\gr d -> Set.foldl (\p acc -> Dict.insert p ( gr.name, gr.ty ) acc) d gr.occPaths)
                    Dict.empty
                    groups

            byLca =
                List.foldl
                    (\gr d -> Dict.update (pathKey gr.lca) (\m -> Just (gr :: Maybe.withDefault [] m)) d)
                    Dict.empty
                    groups
        in
        ( rebuild byOcc byLca [] body
        , { stats1
            | specsTouched = stats1.specsTouched + 1
            , letsInserted = stats1.letsInserted + List.length groups
          }
        , counter1
        )


{-| Adds to the accumulator the groups formed from one bucket of occurrences.

The bucket is split into sets of equal `shape`. A set of one is ignored. A set
of two or more is turned away once the body already has `maxPerDef` groups, and
otherwise becomes a group if it passes the evaluation and scope rules of the
module docstring. A new group binds the set's head occurrence's `canonical`
expression and takes the next `mono_cse_N` number.

-}
formGroups :
    Config
    -> List Occ
    -> ( List Group, Stats, Int )
    -> ( List Group, Stats, Int )
formGroups cfg members ( groups, stats, counter ) =
    case members of
        [] ->
            ( groups, stats, counter )

        first :: rest ->
            let
                ( same, different ) =
                    List.partition (\o -> o.shape == first.shape) rest

                recurse acc =
                    formGroups cfg different acc
            in
            if List.isEmpty same then
                recurse ( groups, stats, counter )

            else if List.length groups >= cfg.maxPerDef then
                recurse ( groups, { stats | budgetExhausted = stats.budgetExhausted + 1 }, counter )

            else
                let
                    members1 =
                        first :: same

                    lca =
                        lcaOf (List.map .path members1)

                    lcaLen =
                        List.length lca

                    suffixes =
                        List.map (\o -> List.drop lcaLen o.path) members1

                    free =
                        freeLocals first.canonical

                    -- A name bound below the LCA is not in scope at the LCA,
                    -- whether or not it shadows anything.
                    shadowed =
                        List.any
                            (\o ->
                                List.any
                                    (\( d, n ) -> d > lcaLen && Set.member n free)
                                    o.binders
                            )
                            members1
                in
                if List.any hasClosure suffixes then
                    recurse ( groups, stats, counter )

                else if not (List.any dominates suffixes) then
                    recurse ( groups, stats, counter )

                else if shadowed then
                    recurse ( groups, { stats | shadowBlocked = stats.shadowBlocked + 1 }, counter )

                else
                    recurse
                        ( { lca = lca
                          , occPaths = Set.fromList (List.map (\o -> pathKey o.path) members1)
                          , bound = first.canonical
                          , ty = first.ty
                          , name = "mono_cse_" ++ String.fromInt counter
                          }
                            :: groups
                        , { stats
                            | groups = stats.groups + 1
                            , merged = stats.merged + List.length same
                            , hashGroups =
                                stats.hashGroups
                                    + (if isHashCall first.orig then
                                        1

                                       else
                                        0
                                      )
                            , hashMerged =
                                stats.hashMerged
                                    + (if isHashCall first.orig then
                                        List.length same

                                       else
                                        0
                                      )
                          }
                        , counter + 1
                        )


{-| Returns the groups that do not overlap a group already kept, taking them in
list order.

Two groups overlap when an occurrence of one is equal to, inside, or around an
occurrence of the other. A group binds one of its occurrences exactly as written,
so an occurrence of another group inside it would not be replaced, and an
occurrence around it would remove it. A group's LCA is above all its
occurrences, so a group whose LCA lay inside another's occurrence would overlap
it too.

-}
dropOverlapping : List Group -> List Group
dropOverlapping groups =
    List.foldl
        (\gr kept ->
            let
                taken =
                    List.concatMap (\k -> Set.toList k.occPaths) kept

                mine =
                    Set.toList gr.occPaths

                overlaps =
                    List.any
                        (\a -> List.any (\b -> a == b || isPrefixPath a b || isPrefixPath b a) mine)
                        taken
            in
            if overlaps then
                kept

            else
                gr :: kept
        )
        []
        groups


{-| Returns whether path key `b` lies strictly below path key `a`.
-}
isPrefixPath : String -> String -> Bool
isPrefixPath a b =
    String.startsWith (a ++ "/") b


{-| Returns the longest prefix shared by every path, the lowest common
ancestor, or the empty path for no paths.
-}
lcaOf : List Path -> Path
lcaOf paths =
    case paths of
        [] ->
            []

        p0 :: rest ->
            List.foldl (\p acc -> commonPrefix acc p) p0 rest


{-| Returns the longest prefix shared by two paths.
-}
commonPrefix : Path -> Path -> Path
commonPrefix a b =
    case ( a, b ) of
        ( x :: xs, y :: ys ) ->
            if x == y then
                x :: commonPrefix xs ys

            else
                []

        _ ->
            []


{-| Returns the names of the `MonoVarLocal`s in an expression, not looking
inside a closure's capture expressions.

It does not remove names the expression binds itself.

-}
freeLocals : MonoExpr -> Set Name
freeLocals root =
    let
        go e acc =
            case e of
                MonoVarLocal n _ ->
                    Set.insert n acc

                _ ->
                    List.foldl go acc (childrenOf e)
    in
    go root Set.empty



-- COLLECT


{-| What `collect` needs besides the expression: the purity oracle and the
settings.
-}
type alias Env =
    { oracle : CsePurity.Oracle, cfg : Config }


{-| The alias map of the module docstring: a name bound by `let n = m` to the
root variable it stands for, with the root's type.
-}
type alias Aliases =
    Dict Name ( Name, Mono.MonoType )


{-| Returns `aliases` without `x`, both as an alias and as the root of one: the
binder of `x` hides the outer `x` that those aliases meant.
-}
unbind : Name -> Aliases -> Aliases
unbind x aliases =
    Dict.filter (\n ( root, _ ) -> n /= x && root /= x) aliases


{-| Returns the alias map in the body of a `let` that binds `def`. An alias
`let n = m` records `n` with `m`'s root, unless that root is `n` itself, which
the new `n` hides.
-}
bodyAliases : Mono.MonoDef -> Aliases -> Aliases
bodyAliases def aliases =
    case def of
        Mono.MonoDef n (MonoVarLocal m mty) ->
            let
                ( root, rootTy ) =
                    Maybe.withDefault ( m, mty ) (Dict.get m aliases)

                outer =
                    unbind n aliases
            in
            if root == n then
                outer

            else
                Dict.insert n ( root, rootTy ) outer

        Mono.MonoDef n _ ->
            unbind n aliases

        Mono.MonoTailDef n _ _ ->
            unbind n aliases


{-| Adds to `acc` every candidate occurrence in `expr` and below it, except
inside closure capture expressions, given the path to `expr`, the names bound
inside the body that are in scope there, and the alias map in force there.
-}
collect : Env -> MonoExpr -> Path -> List ( Int, Name ) -> Aliases -> List Occ -> List Occ
collect env expr path binders aliases acc =
    let
        acc1 =
            case admit env aliases expr path binders of
                Just occ ->
                    occ :: acc

                Nothing ->
                    acc

        depth =
            List.length path

        step tag child bs al a =
            collect env child (path ++ [ tag ]) bs al a

        each tag items bs a =
            List.foldl (\( n, e ) b -> step (tag n) e bs aliases b) a (List.indexedMap Tuple.pair items)
    in
    case expr of
        MonoList _ items _ ->
            each (\n -> "u s" ++ String.fromInt n) items binders acc1

        MonoClosure _ body _ ->
            -- A closure body sees only its parameters and captures.
            step "c" body binders Dict.empty acc1

        MonoCall _ func args _ _ ->
            each (\n -> "u a" ++ String.fromInt n) args binders (step "u f" func binders aliases acc1)

        MonoTailCall _ args _ ->
            each (\n -> "u t" ++ String.fromInt n) (List.map Tuple.second args) binders acc1

        MonoIf branches final _ ->
            let
                a1 =
                    List.foldl
                        (\( n, ( c, t ) ) b ->
                            step ("b t" ++ String.fromInt n)
                                t
                                binders
                                aliases
                                (step
                                    (if n == 0 then
                                        "u g0"

                                     else
                                        "b g" ++ String.fromInt n
                                    )
                                    c
                                    binders
                                    aliases
                                    b
                                )
                        )
                        acc1
                        (List.indexedMap Tuple.pair branches)
            in
            step "b fin" final binders aliases a1

        MonoLet def body _ ->
            let
                bodyBinders =
                    ( depth + 1, defName def ) :: binders

                -- The scope rule is only as complete as these binder lists.
                ( boundBinders, boundAliases ) =
                    case def of
                        Mono.MonoTailDef n params _ ->
                            ( List.map (\( p, _ ) -> ( depth + 1, p )) params ++ binders
                            , List.foldl (\( p, _ ) al -> unbind p al) (unbind n aliases) params
                            )

                        Mono.MonoDef _ _ ->
                            ( binders, aliases )
            in
            step "u lb" body bodyBinders (bodyAliases def aliases) (step "u ld" (defBound def) boundBinders boundAliases acc1)

        MonoDestruct d body _ ->
            let
                names =
                    destructBinders (depth + 1) d
            in
            step "u db" body (names ++ binders) (List.foldl (\( _, n ) al -> unbind n al) aliases names) acc1

        MonoCase _ _ decider branches _ ->
            each (\n -> "b k" ++ String.fromInt n)
                (List.map Tuple.second branches)
                binders
                (collectDecider env path "" binders aliases acc1 decider)

        MonoRecordCreate fields _ ->
            each (\n -> "u r" ++ String.fromInt n) (List.map Tuple.second fields) binders acc1

        MonoRecordAccess inner _ _ ->
            step "u ra" inner binders aliases acc1

        MonoRecordUpdate inner updates _ ->
            each (\n -> "u ru" ++ String.fromInt n)
                (List.map Tuple.second updates)
                binders
                (step "u rb" inner binders aliases acc1)

        MonoTupleCreate _ items _ ->
            each (\n -> "u p" ++ String.fromInt n) (Mono.tupleToList items) binders acc1

        _ ->
            acc1


{-| Adds to `acc` the occurrences in the expressions held inline at the leaves
of a `case` decision tree.

`dpath` records the way down the tree to the current node, and becomes part of
the leaf's step, so that two leaves of one tree have different paths. Jump
leaves hold no expression here; their targets are the `case` branches.

-}
collectDecider : Env -> Path -> String -> List ( Int, Name ) -> Aliases -> List Occ -> Mono.Decider Mono.MonoChoice -> List Occ
collectDecider env path dpath binders aliases acc decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            collect env e (path ++ [ "b dl" ++ dpath ]) binders aliases acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            collectDecider env
                path
                (dpath ++ "f")
                binders
                aliases
                (collectDecider env path (dpath ++ "s") binders aliases acc success)
                failure

        Mono.FanOut _ tests fallback ->
            collectDecider env
                path
                (dpath ++ "b")
                binders
                aliases
                (List.foldl
                    (\( n, ( _, d ) ) a ->
                        collectDecider env path (dpath ++ "t" ++ String.fromInt n) binders aliases a d
                    )
                    acc
                    (List.indexedMap Tuple.pair (NE.toList tests))
                )
                fallback


{-| Returns the occurrence for `expr` if it is a candidate, as the module
docstring defines one for the mode in `env`.
-}
admit : Env -> Aliases -> MonoExpr -> Path -> List ( Int, Name ) -> Maybe Occ
admit env aliases expr path binders =
    case expr of
        MonoCall _ _ _ ty _ ->
            let
                hash =
                    isHashCall expr

                canonical =
                    if hash then
                        resolveHashArgument aliases expr

                    else
                        expr

                occ cost =
                    Just
                        { key = CafHoist.kindTagOf expr
                        , shape = CafHoist.zeroRegions canonical
                        , orig = expr
                        , canonical = canonical
                        , ty = ty
                        , path = path
                        , binders = binders
                        , cost = cost
                        }
            in
            case env.cfg.mode of
                HashOnly ->
                    if hash && hashArgumentIsLocal canonical && KernelFacts.hoistableFor hashKernel then
                        occ (CsePurity.costOf expr)

                    else
                        Nothing

                General ->
                    let
                        cost =
                            CsePurity.costOf expr
                    in
                    if Mono.isFunctionType ty then
                        Nothing

                    else if hasBinderOrClosure expr then
                        Nothing

                    else if not (CsePurity.isSafeExpr env.oracle expr) then
                        Nothing

                    else if cost < env.cfg.minCost && not hash then
                        Nothing

                    else
                        occ cost

        _ ->
            Nothing


{-| The `KernelFacts` key of the value hash kernel.
-}
hashKernel : ( Name, Name, Name )
hashKernel =
    ( "Eco", "FNV", "hash" )


{-| Returns whether `expr` is a call of the value hash with one argument.
-}
isHashCall : MonoExpr -> Bool
isHashCall expr =
    case expr of
        MonoCall _ (MonoVarKernel _ prefix home name _) [ _ ] _ _ ->
            ( prefix, home, name ) == hashKernel

        _ ->
            False


{-| Returns a hash call with its argument replaced by its root when the argument
is an alias in `aliases`.
-}
resolveHashArgument : Aliases -> MonoExpr -> MonoExpr
resolveHashArgument aliases expr =
    case expr of
        MonoCall r func [ MonoVarLocal n t ] ty info ->
            case Dict.get n aliases of
                Just ( root, rootTy ) ->
                    MonoCall r func [ MonoVarLocal root rootTy ] ty info

                Nothing ->
                    MonoCall r func [ MonoVarLocal n t ] ty info

        _ ->
            expr


{-| Returns whether a hash call's argument is a local variable.
-}
hashArgumentIsLocal : MonoExpr -> Bool
hashArgumentIsLocal expr =
    case expr of
        MonoCall _ _ [ MonoVarLocal _ _ ] _ _ ->
            True

        _ ->
            False


{-| Returns the number of hash calls in `expr`, closure bodies included.
-}
countHashCalls : MonoExpr -> Int
countHashCalls expr =
    List.foldl (\child n -> n + countHashCalls child)
        (if isHashCall expr then
            1

         else
            0
        )
        (childrenOf expr)


{-| Returns whether an expression contains a `let`, a destructuring, a `case` or
a closure.
-}
hasBinderOrClosure : MonoExpr -> Bool
hasBinderOrClosure root =
    let
        go e =
            case e of
                MonoLet _ _ _ ->
                    True

                MonoDestruct _ _ _ ->
                    True

                MonoCase _ _ _ _ _ ->
                    True

                MonoClosure _ _ _ ->
                    True

                _ ->
                    List.any go (childrenOf e)
    in
    go root



-- REBUILD


{-| Returns `expr`, found at `path`, with the groups applied: an occurrence
becomes a reference to its group's name, and a node that is some groups' LCA is
rebuilt and then wrapped in one `let` per group. Each `let` binds its group's
bound expression as written, not a rebuilt copy.
-}
rebuild : Dict String ( Name, Mono.MonoType ) -> Dict String (List Group) -> Path -> MonoExpr -> MonoExpr
rebuild byOcc byLca path expr =
    let
        here =
            pathKey path
    in
    case Dict.get here byOcc of
        Just ( n, ty ) ->
            MonoVarLocal n ty

        Nothing ->
            let
                inner =
                    rebuildChildren byOcc byLca path expr
            in
            case Dict.get here byLca of
                Nothing ->
                    inner

                Just groups ->
                    List.foldl
                        (\gr acc ->
                            MonoLet (Mono.MonoDef gr.name gr.bound) acc (Mono.typeOf acc)
                        )
                        inner
                        groups


{-| Returns `expr` with `rebuild` applied to each child, using the same steps
as `collect`.
-}
rebuildChildren : Dict String ( Name, Mono.MonoType ) -> Dict String (List Group) -> Path -> MonoExpr -> MonoExpr
rebuildChildren byOcc byLca path expr =
    let
        at tag child =
            rebuild byOcc byLca (path ++ [ tag ]) child

        mapIdx tag items =
            List.indexedMap (\n e -> at (tag n) e) items
    in
    case expr of
        MonoList r items ty ->
            MonoList r (mapIdx (\n -> "u s" ++ String.fromInt n) items) ty

        MonoClosure ci body ty ->
            MonoClosure ci (at "c" body) ty

        MonoCall r func args ty ci ->
            MonoCall r (at "u f" func) (mapIdx (\n -> "u a" ++ String.fromInt n) args) ty ci

        MonoTailCall n args ty ->
            MonoTailCall n
                (List.indexedMap (\k ( nm, e ) -> ( nm, at ("u t" ++ String.fromInt k) e )) args)
                ty

        MonoIf branches final ty ->
            MonoIf
                (List.indexedMap
                    (\n ( c, t ) ->
                        ( at
                            (if n == 0 then
                                "u g0"

                             else
                                "b g" ++ String.fromInt n
                            )
                            c
                        , at ("b t" ++ String.fromInt n) t
                        )
                    )
                    branches
                )
                (at "b fin" final)
                ty

        MonoLet def body ty ->
            MonoLet (mapDefBound (at "u ld") def) (at "u lb" body) ty

        MonoDestruct d body ty ->
            MonoDestruct d (at "u db" body) ty

        MonoCase s j decider branches ty ->
            MonoCase s
                j
                (rebuildDecider byOcc byLca path "" decider)
                (List.indexedMap (\n ( k, e ) -> ( k, at ("b k" ++ String.fromInt n) e )) branches)
                ty

        MonoRecordCreate fields ty ->
            MonoRecordCreate
                (List.indexedMap (\n ( f, e ) -> ( f, at ("u r" ++ String.fromInt n) e )) fields)
                ty

        MonoRecordAccess inner f ty ->
            MonoRecordAccess (at "u ra" inner) f ty

        MonoRecordUpdate inner updates ty ->
            MonoRecordUpdate (at "u rb" inner)
                (List.indexedMap (\n ( f, e ) -> ( f, at ("u ru" ++ String.fromInt n) e )) updates)
                ty

        MonoTupleCreate r items ty ->
            MonoTupleCreate r (Mono.tupleIndexedMap (\n e -> at ("u p" ++ String.fromInt n) e) items) ty

        other ->
            other


{-| Returns a `case` decision tree with `rebuild` applied to the expressions
held inline at its leaves, using the same steps as `collectDecider`.
-}
rebuildDecider : Dict String ( Name, Mono.MonoType ) -> Dict String (List Group) -> Path -> String -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
rebuildDecider byOcc byLca path dpath decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Mono.Leaf (Mono.Inline (rebuild byOcc byLca (path ++ [ "b dl" ++ dpath ]) e))

        Mono.Leaf (Mono.Jump j) ->
            Mono.Leaf (Mono.Jump j)

        Mono.Chain tests success failure ->
            Mono.Chain tests
                (rebuildDecider byOcc byLca path (dpath ++ "s") success)
                (rebuildDecider byOcc byLca path (dpath ++ "f") failure)

        Mono.FanOut p tests fallback ->
            Mono.FanOut p
                (NE.indexedMap
                    (\n ( t, d ) -> ( t, rebuildDecider byOcc byLca path (dpath ++ "t" ++ String.fromInt n) d ))
                    tests
                )
                (rebuildDecider byOcc byLca path (dpath ++ "b") fallback)



-- SHAPE HELPERS


{-| Returns the direct subexpressions of an expression, including those inline
in a `case` decision tree, except a closure's capture expressions.
-}
childrenOf : MonoExpr -> List MonoExpr
childrenOf expr =
    case expr of
        MonoList _ items _ ->
            items

        MonoClosure _ body _ ->
            [ body ]

        MonoCall _ func args _ _ ->
            func :: args

        MonoTailCall _ args _ ->
            List.map Tuple.second args

        MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        MonoLet def body _ ->
            [ defBound def, body ]

        MonoDestruct _ body _ ->
            [ body ]

        MonoCase _ _ decider branches _ ->
            deciderExprs decider ++ List.map Tuple.second branches

        MonoRecordCreate fields _ ->
            List.map Tuple.second fields

        MonoRecordAccess inner _ _ ->
            [ inner ]

        MonoRecordUpdate inner updates _ ->
            inner :: List.map Tuple.second updates

        MonoTupleCreate _ items _ ->
            Mono.tupleToList items

        _ ->
            []


{-| Returns the expressions held inline at the leaves of a decision tree.
-}
deciderExprs : Mono.Decider Mono.MonoChoice -> List MonoExpr
deciderExprs decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            [ e ]

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ success failure ->
            deciderExprs success ++ deciderExprs failure

        Mono.FanOut _ tests fallback ->
            List.concatMap (\( _, d ) -> deciderExprs d) (NE.toList tests) ++ deciderExprs fallback


{-| Returns the expression a local definition binds.
-}
defBound : Mono.MonoDef -> MonoExpr
defBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound


{-| Returns the name a local definition binds.
-}
defName : Mono.MonoDef -> Name
defName def =
    case def of
        Mono.MonoDef n _ ->
            n

        Mono.MonoTailDef n _ _ ->
            n


{-| Returns a local definition with `f` applied to its bound expression.
-}
mapDefBound : (MonoExpr -> MonoExpr) -> Mono.MonoDef -> Mono.MonoDef
mapDefBound f def =
    case def of
        Mono.MonoDef n bound ->
            Mono.MonoDef n (f bound)

        Mono.MonoTailDef n ps bound ->
            Mono.MonoTailDef n ps (f bound)


{-| Returns the name a destructuring binds, paired with `depth`.
-}
destructBinders : Int -> Mono.MonoDestructor -> List ( Int, Name )
destructBinders depth d =
    case d of
        Mono.MonoDestructor n _ _ ->
            [ ( depth, n ) ]
