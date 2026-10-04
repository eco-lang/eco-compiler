module Compiler.GlobalOpt.Borrow.Lifetime exposing
    ( Life(..)
    , Lifetime(..)
    , Path
    , Step(..)
    , endsBefore
    , eq
    , fromPath
    , join
    , leq
    , onBoundary
    )

{-| Borrow inference has to know whether a value is dead at a given point in a
function, and this module is the lattice it answers that from: for each
resource (a heap value the analysis tracks), the latest point at which the
resource is still live.

**Points.** A function body is viewed as a _skeleton_, a tree whose interior
nodes evaluate children in order (a _sequence_), or evaluate exactly one of
them (_alternatives_, such as the arms of a `case`), or both: an `if` evaluates
its conditions and then one branch. Each interior node has an integer id. A
`Path` names a point by the steps taken from the root: `Seq n i` enters child
`i` of sequence node `n`, and `Arm n i` enters arm `i` of alternatives node
`n`. The point a path names is the moment just after the subtree at that path
has finished evaluating, so the empty path is the end of the whole body.

**Lifetimes.** A `Lifetime` is either `LEmpty` (never live), `LLocal` (ends
somewhere inside the body, described by a `Life`), or `LParams` (reaches past
the body, to caller-visible parameter positions). They are ordered so that a
lifetime that ends earlier is below one that ends later, and `LParams` is above
every `LLocal`. `join` gives the later of two lifetimes. Because only one arm of
an alternatives node runs, a local lifetime records its end separately for each
arm, and a join keeps the later end in each arm.

**Questions.** `endsBefore` asks whether a resource is certainly dead at a
point, and `onBoundary` whether a point is exactly where its lifetime ends.

**Alignment.** Every operation here compares only the kind of each step and its
child or arm index, never the node ids. The answers are meaningful only for
lifetimes and paths from the same skeleton, written root-first, where two steps
at the same position leave the same node. Even then, at a node that is both a
sequence and alternatives, a sequence step can meet an alternatives step. There
`join` gives `Star`, an end no earlier than either, and `leq`, `endsBefore` and
`onBoundary` answer `False`, so `endsBefore` does not report the resource dead.

Compare lifetimes with `eq`, never with `(==)`, which also compares the node ids
that the lattice ignores.

-}

import Dict exposing (Dict)
import Set exposing (Set)


{-| One step of a `Path`, from a skeleton node into one of its children.

`Seq n i` enters child `i` of sequence node `n`, and `Arm n i` enters arm `i` of
alternatives node `n`. The operations in this module read only which kind of
step it is and the index.

-}
type Step
    = Seq Int Int
    | Arm Int Int


{-| A point in a function body: the steps from the root of its skeleton to the
subtree that has just finished evaluating there. The first step leaves the
root, and the empty path is the end of the whole body.

This is a name for `List Step`, not a new type. Nothing checks that a list is in
root-first order or that its steps follow a real skeleton.

-}
type alias Path =
    List Step


{-| Where a local lifetime ends, read from some position in the skeleton.

`Star` means the resource is live until the subtree at this position has
finished evaluating.

`InSeq n i l` means it ends inside child `i` of sequence node `n`, at `l` within
that child, so it is dead in every later child.

`InAlts n arms` means it ends separately in each arm of alternatives node `n`:
`arms` maps an arm index to where it ends in that arm, and an arm with no entry
is one on which the resource is never live.

-}
type Life
    = Star
    | InSeq Int Int Life
    | InAlts Int (Dict Int Life)


{-| The latest point at which a resource is live, as an element of the lattice.

`LEmpty` is the bottom: the resource is never live, so it is dead at every
point, and it is the identity of `join`.

`LLocal` ends inside the function body, at the `Life` read from the root.

`LParams` reaches past the end of the body to the parameter positions in its
set. It is above every `LLocal`, the join of two is the union of their sets,
and it is never dead at any path or on a boundary.

-}
type Lifetime
    = LEmpty
    | LLocal Life
    | LParams (Set Int)



-- CONSTRUCTION


{-| Returns the lifetime that ends at `path`: live up to that point on any
execution that reaches it, dead at every later point, and never live on an arm
the path does not take.
-}
fromPath : Path -> Lifetime
fromPath path =
    LLocal (fromPathLife path)


{-| Returns the `Life` that ends at `path`, read from the current position: one
`InSeq`, or one single-arm `InAlts`, for each step, ending in `Star`.
-}
fromPathLife : Path -> Life
fromPathLife path =
    case path of
        [] ->
            Star

        (Seq n i) :: rest ->
            InSeq n i (fromPathLife rest)

        (Arm n i) :: rest ->
            InAlts n (Dict.singleton i (fromPathLife rest))



-- JOIN


{-| Returns the later of two lifetimes: an upper bound of both in the order
`leq` defines.

`LEmpty` is the identity, `LParams` absorbs any `LLocal`, and two `LParams` give
the union of their sets. Two local lifetimes are combined position by position.
`Star` absorbs anything. Within a sequence, the end in the later child wins, and
two ends in the same child are joined in turn. Within alternatives, every arm
of either is kept, and an arm in both keeps the join of its two ends. A
sequence end meeting an alternatives end at the same position gives `Star`.

Node ids are not compared.

-}
join : Lifetime -> Lifetime -> Lifetime
join a b =
    case ( a, b ) of
        ( LEmpty, x ) ->
            x

        ( x, LEmpty ) ->
            x

        ( LParams s, LParams t ) ->
            LParams (Set.union s t)

        ( LParams s, LLocal _ ) ->
            LParams s

        ( LLocal _, LParams t ) ->
            LParams t

        ( LLocal x, LLocal y ) ->
            LLocal (joinLife x y)


{-| Returns the later of two local lifetimes read from the same position, as
`join` describes for two `LLocal`s.
-}
joinLife : Life -> Life -> Life
joinLife x y =
    case ( x, y ) of
        ( Star, _ ) ->
            Star

        ( _, Star ) ->
            Star

        ( InSeq n i l, InSeq _ j m ) ->
            if i > j then
                InSeq n i l

            else if j > i then
                InSeq n j m

            else
                InSeq n i (joinLife l m)

        ( InAlts n as_, InAlts _ bs ) ->
            InAlts n
                (Dict.merge
                    Dict.insert
                    (\k l m acc -> Dict.insert k (joinLife l m) acc)
                    Dict.insert
                    as_
                    bs
                    Dict.empty
                )

        ( InSeq _ _ _, InAlts _ _ ) ->
            Star

        ( InAlts _ _, InSeq _ _ _ ) ->
            Star



-- ORDER


{-| Returns whether `a` ends no later than `b` in the lattice order.

`LEmpty` is below everything, every `LLocal` is below every `LParams`, and one
`LParams` is below another when its set is a subset of the other's. Of two local
lifetimes, `Star` is above all the rest. Within a sequence, an end in an earlier
child is below one in a later child, and two ends in the same child are compared
in turn. Within alternatives, `a` is below `b` when every arm `a` is live on is
an arm `b` is live on, with an end no later. A sequence end and an alternatives
end at the same position are not ordered either way. Node ids are not compared.

The order is computed from the structure directly, not by way of `join`.

-}
leq : Lifetime -> Lifetime -> Bool
leq a b =
    case ( a, b ) of
        ( LEmpty, _ ) ->
            True

        ( LLocal _, LParams _ ) ->
            True

        ( LParams s, LParams t ) ->
            Set.isEmpty (Set.diff s t)

        ( LParams _, LLocal _ ) ->
            False

        ( LParams _, LEmpty ) ->
            False

        ( LLocal _, LEmpty ) ->
            False

        ( LLocal x, LLocal y ) ->
            lifeLeq x y


{-| Returns whether local lifetime `x` ends no later than `y`, both read from
the same position, as `leq` describes for two `LLocal`s.
-}
lifeLeq : Life -> Life -> Bool
lifeLeq x y =
    case ( x, y ) of
        ( _, Star ) ->
            True

        ( Star, InSeq _ _ _ ) ->
            False

        ( Star, InAlts _ _ ) ->
            False

        ( InSeq _ i l, InSeq _ j m ) ->
            i < j || (i == j && lifeLeq l m)

        ( InAlts _ as_, InAlts _ bs ) ->
            Dict.foldl
                (\k l acc ->
                    acc
                        && (case Dict.get k bs of
                                Just m ->
                                    lifeLeq l m

                                Nothing ->
                                    False
                           )
                )
                True
                as_

        ( InSeq _ _ _, InAlts _ _ ) ->
            False

        ( InAlts _ _, InSeq _ _ _ ) ->
            False


{-| Returns whether two lifetimes are equal in the lattice, meaning each is
`leq` the other. Use this rather than `(==)`, which also compares the node ids
that the lattice ignores.
-}
eq : Lifetime -> Lifetime -> Bool
eq a b =
    leq a b && leq b a



-- PREDICATES


{-| Returns whether the resource is certainly dead at the point `path`: on every
execution that reaches `path`, its lifetime has ended before that point.

`LEmpty` is dead everywhere and `LParams` nowhere. A local lifetime is dead at
`path` when it ends in an earlier child of a sequence that `path` passes
through, when `path` takes an arm on which it is never live, or when `path`
stops at a node above the place where the lifetime ends, because the point is
after that node's subtree has finished. It is not dead where it ends, so
`endsBefore (fromPath p) p` is `False`, nor anywhere inside a subtree it lasts
to the end of. Where `path` takes a different kind of step from the lifetime at
the same position, the answer is `False`.

-}
endsBefore : Lifetime -> Path -> Bool
endsBefore lifetime path =
    case lifetime of
        LEmpty ->
            True

        LParams _ ->
            False

        LLocal l ->
            endsBeforeLife l path


{-| Returns whether local lifetime `life` has ended before the point `path`,
both read from the current position, as `endsBefore` describes.
-}
endsBeforeLife : Life -> Path -> Bool
endsBeforeLife life path =
    case ( life, path ) of
        ( Star, _ ) ->
            False

        ( InSeq _ _ _, [] ) ->
            True

        ( InSeq _ i l, (Seq _ j) :: rest ) ->
            if i < j then
                True

            else if i > j then
                False

            else
                endsBeforeLife l rest

        ( InSeq _ _ _, (Arm _ _) :: _ ) ->
            False

        ( InAlts _ _, [] ) ->
            True

        ( InAlts _ as_, (Arm _ j) :: rest ) ->
            case Dict.get j as_ of
                Nothing ->
                    True

                Just l ->
                    endsBeforeLife l rest

        ( InAlts _ _, (Seq _ _) :: _ ) ->
            False


{-| Returns whether the lifetime ends exactly at `path`, so that on any
execution that reaches `path`, that point is the last at which the resource is
live.

That holds when `path` follows the lifetime's own steps to its end: the same
child at each sequence, an arm the lifetime is live on at each alternatives
node, and no steps left over. It is always `False` for `LEmpty` and `LParams`.

-}
onBoundary : Lifetime -> Path -> Bool
onBoundary lifetime path =
    case lifetime of
        LEmpty ->
            False

        LParams _ ->
            False

        LLocal l ->
            onBoundaryLife l path


{-| Returns whether `path`, read from the current position, follows local
lifetime `life` exactly to its end, as `onBoundary` describes.
-}
onBoundaryLife : Life -> Path -> Bool
onBoundaryLife life path =
    case ( life, path ) of
        ( Star, [] ) ->
            True

        ( Star, _ :: _ ) ->
            False

        ( InSeq _ i l, (Seq _ j) :: rest ) ->
            i == j && onBoundaryLife l rest

        ( InSeq _ _ _, [] ) ->
            False

        ( InSeq _ _ _, (Arm _ _) :: _ ) ->
            False

        ( InAlts _ as_, (Arm _ j) :: rest ) ->
            case Dict.get j as_ of
                Just l ->
                    onBoundaryLife l rest

                Nothing ->
                    False

        ( InAlts _ _, [] ) ->
            False

        ( InAlts _ _, (Seq _ _) :: _ ) ->
            False
