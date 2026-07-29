module Compiler.GlobalOpt.Borrow.Lifetime exposing
    ( Step(..), Path, Life(..), Lifetime(..)
    , fromPath, join, joinAll, eq, leq, endsBefore, onBoundary
    )

{-| Lifetime-lattice algebra for borrow inference (design §7.4).

A `Lifetime` approximates, for one function-local resource, the latest
program point at which it is still live. Points are addressed by `Path`s
relative to a per-def skeleton (the constraint walker mints skeleton node
ids). The lattice orders "dies earlier" ≤ "dies later"; `join` is the
least-upper-bound (the later death). `LParams` sits above every `LLocal`
(a resource whose lifetime reaches a caller-visible parameter position
outlives any local point).

Constructors are exposed (house style — Phase-2 Constrain/Solve build
these directly). NEVER compare `Lifetime`/`Life` with `(==)`: they contain
`Dict`s and elm/core `Dict` equality via `==` is unreliable. Use `eq`.

-}

import Dict exposing (Dict)
import Set exposing (Set)


{-| One step of a root-relative, function-local path. The first `Int` is the
skeleton node id (minted by the Phase-2 walker); the second is the child/arm
index. Values are only ever compared/joined at the same tree position, so the
node ids of compared constructors are equal by construction; `join`/`leq`
branch on the INDEX only and keep the left-hand node id.
-}
type Step
    = Seq Int Int
    | Arm Int Int


type alias Path =
    List Step


{-| Where within a skeleton subtree a resource's lifetime ends.

  - `Star` — ends exactly at this node's completion (paper ★).
  - `InSeq n i l` — ends within sequential child `i` of node `n`.
  - `InAlts n d` — per-arm ends; a missing arm key means the resource is dead
    on that arm (paper `(— ∥ ℓ)`).

-}
type Life
    = Star
    | InSeq Int Int Life
    | InAlts Int (Dict Int Life)


type Lifetime
    = LEmpty
    | LLocal Life
    | LParams (Set Int)



-- CONSTRUCTION


{-| The lifetime ending exactly at path `p`.
-}
fromPath : Path -> Lifetime
fromPath path =
    LLocal (fromPathLife path)


fromPathLife : Path -> Life
fromPathLife path =
    case path of
        [] ->
            Star

        (Seq n i) :: rest ->
            InSeq n i (fromPathLife rest)

        (Arm n i) :: rest ->
            InAlts n (Dict.singleton i (fromPathLife rest))



-- JOIN (least upper bound = latest death)


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


joinAll : List Lifetime -> Lifetime
joinAll =
    List.foldl join LEmpty


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
            -- Unreachable on aligned skeletons; total-function fallback,
            -- conservative (Star = latest ⇒ fewer deadness claims).
            Star

        ( InAlts _ _, InSeq _ _ _ ) ->
            Star



-- ORDER (structural — NOT via join, so absorption is a real test)


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


{-| Semantic equality (never structural `==` — Dict pitfall).
-}
eq : Lifetime -> Lifetime -> Bool
eq a b =
    leq a b && leq b a



-- PREDICATES (a path denotes the completion point of the subtree at it)


{-| Paper `L ≺ p`: the resource is provably dead at path `p`.
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


endsBeforeLife : Life -> Path -> Bool
endsBeforeLife life path =
    case ( life, path ) of
        ( Star, _ ) ->
            -- Ends AT node completion; not before it (nor before any deeper p).
            False

        ( InSeq _ _ _, [] ) ->
            -- Dies inside a child, strictly before node completion.
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


{-| Paper `L ≍ p`: `p` is a final occurrence (last use on every execution
that reaches it).
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
