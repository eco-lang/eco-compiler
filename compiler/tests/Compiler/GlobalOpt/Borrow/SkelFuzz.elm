module Compiler.GlobalOpt.Borrow.SkelFuzz exposing
    ( Skel(..)
    , allProbes
    , allSkels
    , executions
    , fromPaths
    , leafPaths
    , refEndsBefore
    , refOnBoundary
    , skelFuzzer
    , subsets
    )

{-| A brute-force model of when a resource is dead, against which the lifetime
lattice in `Compiler.GlobalOpt.Borrow.Lifetime` can be checked. The lattice
answers its questions symbolically, from a `Lifetime` built by joining paths;
this module answers the same questions by listing every way a small piece of
code can run and looking at each one. It holds no tests itself.

A _skeleton_ (`Skel`) is a piece of code reduced to its evaluation order:
leaves, sequences whose children all run in order, and alternatives of which
exactly one arm runs. Positions in a skeleton are addressed by `Lifetime.Path`s,
lists of `Seq` and `Arm` steps from the root, as `Lifetime` defines them.

An _execution_ is one run through a skeleton, written as the list of leaf paths
it visits, in order. A skeleton has one execution for each way of choosing an
arm at the alternatives it runs.

A _live set_ is a list of leaf paths: the leaves at which a resource is used.
`fromPaths` turns one into the `Lifetime` the lattice gives that resource.

A _probe_ is a path at which deadness is asked about. It is either a leaf path
or a proper prefix of one, which addresses a whole subtree; `Lifetime`'s
predicates accept any path, so the model has to answer for both.

Everything else rests on where a probe's point lies in an execution. An
execution reaches a probe if some leaf it visits has the probe as a prefix, and
the probe's position is then the index of the last such leaf. For a leaf probe
that is the leaf itself, and the probe's point is the leaf. For a subtree probe
it is the leaf at which the subtree finishes, and the probe's point lies just
after it. So a use at the probe's position is before a subtree probe but not
before a leaf probe. An execution that does not reach the probe says nothing
about it.

`refEndsBefore` and `refOnBoundary` are the model's answers, to be compared with
`Lifetime.endsBefore` and `Lifetime.onBoundary`. They take a skeleton's
executions as an argument beside the live set, because the executions come from
the skeleton and a live set alone does not determine them. `allSkels` and
`skelFuzzer` supply the skeletons.

-}

import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Lifetime, Path, Step(..))
import Fuzz exposing (Fuzzer)


{-| An abstract evaluation skeleton: the shape of a piece of code, reduced to
which parts run one after another and which are a choice of one among several.

An `SLeaf` is a single program point, and the only kind of node at which the
model counts a use.

An `SSeq` runs every one of its children, in list order. An `SAlts` runs exactly
one of its children, its arms. With no arms it has no executions at all; neither
generator here builds a node without children.

The `Int` of `SSeq` and `SAlts` is the node's id, which appears in the `Seq` and
`Arm` steps of every path beneath it. The generators number interior
nodes 0, 1, 2, and so on in pre-order; a skeleton built by hand carries
whatever ids it is given.

-}
type Skel
    = SLeaf
    | SSeq Int (List Skel)
    | SAlts Int (List Skel)



-- PRE-ORDER RENUMBERING


{-| Returns `skel` with its `SSeq` and `SAlts` nodes numbered 0, 1, 2, and so
on in pre-order. Leaves take no number.
-}
renumber : Skel -> Skel
renumber skel =
    Tuple.first (renumberGo 0 skel)


{-| Numbers the interior nodes of `skel` in pre-order starting from `n`, and
returns the result with the next unused number.
-}
renumberGo : Int -> Skel -> ( Skel, Int )
renumberGo n skel =
    case skel of
        SLeaf ->
            ( SLeaf, n )

        SSeq _ kids ->
            let
                ( kids2, n2 ) =
                    renumberList (n + 1) kids
            in
            ( SSeq n kids2, n2 )

        SAlts _ kids ->
            let
                ( kids2, n2 ) =
                    renumberList (n + 1) kids
            in
            ( SAlts n kids2, n2 )


{-| Numbers the interior nodes of each skeleton in `kids` in turn, starting from
`n`, and returns them with the next unused number.
-}
renumberList : Int -> List Skel -> ( List Skel, Int )
renumberList n kids =
    case kids of
        [] ->
            ( [], n )

        k :: rest ->
            let
                ( k2, n2 ) =
                    renumberGo n k

                ( rest2, n3 ) =
                    renumberList n2 rest
            in
            ( k2 :: rest2, n3 )



-- ENUMERATION


{-| Returns the path from the root to every leaf of `skel`, left to right. A
lone `SLeaf` has one leaf, at the empty path.
-}
leafPaths : Skel -> List Path
leafPaths skel =
    case skel of
        SLeaf ->
            [ [] ]

        SSeq n kids ->
            List.concat
                (List.indexedMap
                    (\i kid -> List.map (\p -> Seq n i :: p) (leafPaths kid))
                    kids
                )

        SAlts n kids ->
            List.concat
                (List.indexedMap
                    (\i kid -> List.map (\p -> Arm n i :: p) (leafPaths kid))
                    kids
                )


{-| Returns every execution of `skel`, each the list of leaf paths it visits in
order.

An `SSeq` runs all its children, so its executions are every combination of one
execution per child, concatenated in child order. An `SAlts` runs one arm, so
its executions are those of its first arm, then those of its second, and so on.

-}
executions : Skel -> List (List Path)
executions skel =
    case skel of
        SLeaf ->
            [ [ [] ] ]

        SSeq n kids ->
            let
                perChild =
                    List.indexedMap
                        (\i kid ->
                            List.map (List.map (\p -> Seq n i :: p)) (executions kid)
                        )
                        kids
            in
            List.map List.concat (cartesian perChild)

        SAlts n kids ->
            List.concat
                (List.indexedMap
                    (\i kid ->
                        List.map (List.map (\p -> Arm n i :: p)) (executions kid)
                    )
                    kids
                )


{-| Returns every list made by taking one element from each of `lists`, in
order. It is empty if any of `lists` is empty, and holds one empty list when
`lists` itself is empty.
-}
cartesian : List (List a) -> List (List a)
cartesian lists =
    case lists of
        [] ->
            [ [] ]

        xs :: rest ->
            let
                restProd =
                    cartesian rest
            in
            List.concatMap (\x -> List.map (\r -> x :: r) restProd) xs


{-| Builds the lifetime of a resource used at each of `paths`: the
`Lifetime.join` of `Lifetime.fromPath` over them, or `LEmpty` when there are
none.
-}
fromPaths : List Path -> Lifetime
fromPaths paths =
    List.foldl (\p acc -> L.join (L.fromPath p) acc) L.LEmpty paths



-- PROBES (leaf paths ∪ proper prefixes)


{-| Returns every probe of `skel`, each once: its leaf paths first, then the
proper prefixes of those paths.
-}
allProbes : Skel -> List Path
allProbes skel =
    let
        leaves =
            leafPaths skel

        prefixes =
            List.concatMap properPrefixes leaves
    in
    dedupe (leaves ++ prefixes)


{-| Returns every prefix of `path` shorter than `path` itself, from the empty
path upwards.
-}
properPrefixes : Path -> List Path
properPrefixes path =
    let
        len =
            List.length path
    in
    List.filter (\p -> List.length p < len) (inits path)


{-| Returns every prefix of `xs`, from the empty list up to `xs` itself.
-}
inits : List a -> List (List a)
inits xs =
    case xs of
        [] ->
            [ [] ]

        x :: rest ->
            [] :: List.map (\r -> x :: r) (inits rest)


{-| Returns `paths` with repeats removed, keeping the last occurrence of each.
-}
dedupe : List Path -> List Path
dedupe =
    List.foldr
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []


{-| Returns every sublist of `list`, from the empty list to the whole of it,
each in the order of `list`.
-}
subsets : List a -> List (List a)
subsets list =
    case list of
        [] ->
            [ [] ]

        x :: rest ->
            let
                s =
                    subsets rest
            in
            s ++ List.map (\sub -> x :: sub) s



-- REFERENCE PREDICATES (arbiter)


{-| Returns whether a resource used at the leaves `s` is dead at probe `p` on
every execution in `execs`.

On each execution that reaches `p`, every leaf of `s` that the execution visits
must come before `p`'s point. When `p` is itself one of the execution's leaves,
that means strictly before `p`, so a use at `p` is not dead at `p`. Otherwise it
means no later than the last leaf under `p`. An execution that does not reach
`p`, or a leaf of `s` that an execution does not visit, imposes nothing, so an
empty `s` is dead everywhere.

-}
refEndsBefore : List (List Path) -> List Path -> Path -> Bool
refEndsBefore execs s p =
    List.all
        (\e ->
            if containsPath e p then
                let
                    pp =
                        lastPos e p

                    isLeafP =
                        List.member p e
                in
                List.all
                    (\q ->
                        case leafIndex e q of
                            Nothing ->
                                True

                            Just qi ->
                                if isLeafP then
                                    qi < pp

                                else
                                    qi <= pp
                    )
                    s

            else
                True
        )
        execs


{-| Returns whether probe `p` is a last use of a resource used at the
leaves `s`.

`p` must be one of `s`, and on every execution in `execs` that reaches `p`, no
leaf of `s` that the execution visits may come after `p`'s position. An
execution that does not reach `p` imposes nothing.

-}
refOnBoundary : List (List Path) -> List Path -> Path -> Bool
refOnBoundary execs s p =
    List.member p s
        && List.all
            (\e ->
                if containsPath e p then
                    let
                        pp =
                            lastPos e p
                    in
                    List.all
                        (\q ->
                            case leafIndex e q of
                                Nothing ->
                                    True

                                Just qi ->
                                    qi <= pp
                        )
                        s

                else
                    True
            )
            execs


{-| Returns whether execution `e` reaches probe `p`, that is whether some leaf
in `e` has `p` as a prefix.
-}
containsPath : List Path -> Path -> Bool
containsPath e p =
    List.any (\leaf -> isPrefix p leaf) e


{-| Returns the index in execution `e` of the last leaf that has `p` as a
prefix, or -1 when none does.
-}
lastPos : List Path -> Path -> Int
lastPos e p =
    List.foldl
        (\( idx, leaf ) best ->
            if isPrefix p leaf then
                idx

            else
                best
        )
        -1
        (List.indexedMap Tuple.pair e)


{-| Returns the index in execution `e` of the leaf path `q`, if `e` visits it.
-}
leafIndex : List Path -> Path -> Maybe Int
leafIndex e q =
    indexOf 0 e q


{-| Returns the index of the first element of `e` equal to `q`, counting the
head of `e` as `i`.
-}
indexOf : Int -> List Path -> Path -> Maybe Int
indexOf i e q =
    case e of
        [] ->
            Nothing

        leaf :: rest ->
            if leaf == q then
                Just i

            else
                indexOf (i + 1) rest q


{-| Returns whether `pre` is a prefix of `full`. The empty path is a prefix of
every path, and every path is a prefix of itself.
-}
isPrefix : Path -> Path -> Bool
isPrefix pre full =
    case ( pre, full ) of
        ( [], _ ) ->
            True

        ( _, [] ) ->
            False

        ( a :: ar, b :: br ) ->
            a == b && isPrefix ar br



-- SKELETON GENERATORS


{-| Every skeleton of depth at most 2 in which a sequence has one or two
children and an alternative exactly two arms, numbered in pre-order. A lone leaf
has depth 0, and each level of `SSeq` or `SAlts` nesting adds one. There are 37.

Being a fixed list rather than a random sample, a check over it covers every one
of them however many fuzz runs are asked for.

-}
allSkels : List Skel
allSkels =
    List.map renumber (skelsUpToDepth 2)


{-| Returns every skeleton of depth at most `d` in which a sequence has one or
two children and an alternative exactly two arms, with every node id 0.
-}
skelsUpToDepth : Int -> List Skel
skelsUpToDepth d =
    if d <= 0 then
        [ SLeaf ]

    else
        let
            sub =
                skelsUpToDepth (d - 1)

            seq1 =
                List.map (\k -> SSeq 0 [ k ]) sub

            seq2 =
                List.concatMap (\a -> List.map (\b -> SSeq 0 [ a, b ]) sub) sub

            alts2 =
                List.concatMap (\a -> List.map (\b -> SAlts 0 [ a, b ]) sub) sub
        in
        SLeaf :: (seq1 ++ seq2 ++ alts2)


{-| Produces a fuzzer of skeletons of depth at most `d`, numbered in pre-order.
Above the deepest level, each node is a leaf, a sequence of one to three
children or an alternative of two or three arms, with equal chance of each.
-}
skelFuzzer : Int -> Fuzzer Skel
skelFuzzer d =
    Fuzz.map renumber (skelFuzzerRaw d)


{-| Produces a fuzzer of skeletons as `skelFuzzer` does, but with node id 0 on
every interior node.
-}
skelFuzzerRaw : Int -> Fuzzer Skel
skelFuzzerRaw d =
    if d <= 0 then
        Fuzz.constant SLeaf

    else
        Fuzz.oneOf
            [ Fuzz.constant SLeaf
            , Fuzz.intRange 1 3
                |> Fuzz.andThen
                    (\w ->
                        Fuzz.map (SSeq 0)
                            (Fuzz.listOfLength w (Fuzz.lazy (\_ -> skelFuzzerRaw (d - 1))))
                    )
            , Fuzz.intRange 2 3
                |> Fuzz.andThen
                    (\w ->
                        Fuzz.map (SAlts 0)
                            (Fuzz.listOfLength w (Fuzz.lazy (\_ -> skelFuzzerRaw (d - 1))))
                    )
            ]
