module Compiler.GlobalOpt.Borrow.Dsu exposing
    ( Dsu, empty, size, grow, find, findRoot, union )

{-| Pure Int-keyed union-find (disjoint-set) with NO payloads — a quotient
structure over `ResVar`s minted densely from 0 per def-analysis (design
§7.1). The `storageOwned` bit lives in Phase-2 solver state keyed by root,
not here.

Backed by dense `Array Int` (BitSet / Staging `Uf` precedent): ResVars are
dense, so `Array` gives O(1) access with no hashing. Alias, not opaque —
it is pass-internal and `DsuTest` inspects `parent`/`rank` directly.

Algorithmic core copied from `Staging/UnionFind.elm:110-153` with three
deliberate changes: Int keys (no Node/StagingGraph coupling), union-by-rank
(Staging has none), and a stack-safe two-pass `find` (Staging's recursion is
non-tail).

-}

import Array exposing (Array)


type alias Dsu =
    { parent : Array Int
    , rank : Array Int
    }


{-| Capacity `n`; each `i ∈ [0,n)` starts as its own root.
-}
empty : Int -> Dsu
empty n =
    { parent = Array.initialize n identity
    , rank = Array.repeat n 0
    }


size : Dsu -> Int
size dsu =
    Array.length dsu.parent


{-| Ensure capacity ≥ `n` (mint outpaces `empty`). New indices are singleton
roots. No-op when already large enough.
-}
grow : Int -> Dsu -> Dsu
grow n dsu =
    let
        len =
            Array.length dsu.parent
    in
    if n <= len then
        dsu

    else
        { parent = Array.append dsu.parent (Array.initialize (n - len) (\i -> len + i))
        , rank = Array.append dsu.rank (Array.repeat (n - len) 0)
        }


{-| Read-only root chase (tail-recursive). Out-of-range keys are their own
root (Staging totality convention).
-}
findRoot : Int -> Dsu -> Int
findRoot x dsu =
    case Array.get x dsu.parent of
        Nothing ->
            x

        Just p ->
            if p == x then
                x

            else
                findRoot p dsu


{-| Two-pass find: chase to the root, then compress every node on the path to
point directly at it. Both passes are tail-recursive (no intermediate list).
-}
find : Int -> Dsu -> ( Int, Dsu )
find x dsu =
    let
        root =
            findRoot x dsu
    in
    ( root, compress x root dsu )


compress : Int -> Int -> Dsu -> Dsu
compress x root dsu =
    case Array.get x dsu.parent of
        Nothing ->
            dsu

        Just p ->
            if p == x then
                dsu

            else
                -- advance to the OLD parent read before the set (tail call)
                compress p root { dsu | parent = Array.set x root dsu.parent }


{-| Union by rank.
-}
union : Int -> Int -> Dsu -> Dsu
union a b d0 =
    let
        ( ra, d1 ) =
            find a d0

        ( rb, d2 ) =
            find b d1
    in
    if ra == rb then
        d2

    else
        let
            ka =
                Maybe.withDefault 0 (Array.get ra d2.rank)

            kb =
                Maybe.withDefault 0 (Array.get rb d2.rank)
        in
        if ka < kb then
            { d2 | parent = Array.set ra rb d2.parent }

        else if kb < ka then
            { d2 | parent = Array.set rb ra d2.parent }

        else
            { d2
                | parent = Array.set rb ra d2.parent
                , rank = Array.set ra (ka + 1) d2.rank
            }
