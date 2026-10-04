module Compiler.GlobalOpt.Borrow.Dsu exposing (Dsu, empty, grow, find, findRoot, union)

{-| Borrow inference groups the resources of a definition, numbered densely
from `0`, into classes that only ever grow by merging. This module is the
union-find structure it groups them with.

A union-find (also called a disjoint-set structure) divides the keys `0` to
`n - 1` into classes, where `n` is its capacity. Each class has one key, its
root, which stands for the whole class: two keys are in the same class exactly
when they have the same root. Given keys within the capacity, every key has a
parent, and following parents from any key leads to its class's root, which is
its own parent. `union` merges two classes, and classes are never split.

The structure holds nothing but the partition. Anything known about a class is
kept by the user of this module, typically in an array indexed by root. Keys
are plain `Int`s because the resources they stand for are numbered densely, so
each array lookup is direct.

Two standard techniques keep the chains from a key to its root short. `union`
puts the root of lower rank under the root of higher rank, where a root's rank
starts at `0` and goes up only in a union of two roots of equal rank. `find`
compresses the path it walks, pointing every key on it directly at the root.
`findRoot` and the compression walk in `find` are both tail calls, so a long
chain does not deepen the stack.

A key outside the capacity, including a negative one, has no parent and is
treated as its own root by `findRoot` and `find`. `union` is not total in the
same way; see its docstring.

@docs Dsu, empty, grow, find, findRoot, union

-}

import Array exposing (Array)


{-| A partition of the keys `0` to `n - 1` into classes, as a union-find.

This is a record alias, not an opaque type, so its arrays can be read and also
built by hand. Given keys within the capacity, the functions here keep two
invariants that a hand-built value may break: following `parent` from any key
ends at a key that is its own parent, and both arrays have the same length,
which is the capacity. A `rank` entry means something only at a root; at any
other key it is whatever it was when that key stopped being a root.

-}
type alias Dsu =
    { parent : Array Int
    , rank : Array Int
    }


{-| Creates a structure of capacity `n` in which every key from `0` to `n - 1`
is in a class of its own.
-}
empty : Int -> Dsu
empty n =
    { parent = Array.initialize n identity
    , rank = Array.repeat n 0
    }


{-| Returns `dsu` with its capacity raised to `n`, each added key starting as
its own parent and every existing parent and rank kept. When the capacity is
already `n` or more, returns `dsu` as it is.
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


{-| Returns the root of the class holding `x`, leaving the structure
unchanged. A key outside the capacity is returned as its own root.
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


{-| Returns the root of the class holding `x`, as `findRoot` does, together
with the structure after path compression: every key on the chain from `x` to
the root now has the root as its parent. The partition is unchanged.

The root is found first and the chain is then walked a second time to repoint
it, which keeps both walks tail calls without collecting the chain in a list.

-}
find : Int -> Dsu -> ( Int, Dsu )
find x dsu =
    let
        root =
            findRoot x dsu
    in
    ( root, compress x root dsu )


{-| Returns `dsu` with `root` made the parent of every key on the chain from
`x`, stopping before the first key that is its own parent. A key outside the
capacity leaves `dsu` unchanged.
-}
compress : Int -> Int -> Dsu -> Dsu
compress x root dsu =
    case Array.get x dsu.parent of
        Nothing ->
            dsu

        Just p ->
            if p == x then
                dsu

            else
                -- p is the parent from before x was repointed, so the walk
                -- follows the old chain.
                compress p root { dsu | parent = Array.set x root dsu.parent }


{-| Returns the structure with the classes of `a` and `b` merged into one,
after path compression of both keys as `find` does. When they already share a
class, only the compression is applied.

The root of lower rank is put under the root of higher rank, and the merged
class keeps the higher rank. When the ranks are equal, `b`'s root is put under
`a`'s root and that root's rank goes up by one.

Both keys are expected to be within the capacity, as are the keys of every
earlier union. A key outside it has rank `0`, and setting its parent or rank
changes nothing, so the merge is usually lost, though `a`'s root may still
have its rank raised by one. The exception is when `a`'s root is outside the
capacity and `b`'s root is inside it with rank `0`: then `b`'s root is given
`a`'s root as its parent, and `a`'s root, which has no parent, becomes the
root of the merged class.

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
