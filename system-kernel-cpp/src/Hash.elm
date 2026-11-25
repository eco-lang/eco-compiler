module Hash exposing
    ( hash
    , Hashed, hashed, value, hashOf
    )

{-| Hash any value, and pair a value with its hash.

@docs hash


# Hashed values

A `Hashed` value carries its hash with it, so that hashing it again, or hashing anything built from
it, costs no walk of the value. Keep the parts of a recursive structure as `Hashed` and each node
hashes in time proportional to its own number of fields: the basis of hash-consing (sharing one
copy of each distinct structure, with `HashedSet.intern`).

@docs Hashed, hashed, value, hashOf

-}

import Eco.Kernel.FNV


{-| A hash of any value: an `Int` in `[0, 2^32)`, never 0 on the native backend.

Values that `==` finds equal have equal hashes. That is the only promise: two different values may
share a hash, so a hash table built on it must still compare keys with `==` (as `SeqDict` and
`SeqSet` do).

The numbers are deterministic within one compiled program on one backend, but they follow how the
compiler chose to lay the value out in memory, so they differ between the native and JavaScript
backends, between programs, between compiler versions and between build modes. Never store a hash
or send it elsewhere; compute it again where it is needed.

The hash reads every unit of a `String` and every byte of `Bytes`, but only a bounded part of a large
structure (256 elements, entries or fields in all, and 16 levels of nesting), so structures that differ
only beyond those bounds hash alike. A [`Hashed`](#Hashed) part counts as its stored hash, so a
structure built from `Hashed` parts is told apart by them however deep it is. Functions and other
values that `==` does not compare by content hash by their kind only.

-}
hash : a -> Int
hash =
    Eco.Kernel.FNV.hash


{-| A value paired with its hash.

`==` on two `Hashed` values is `==` on their values (the hashes are compared first, so two
different values are usually told apart without looking at them), and `Debug.toString` prints the
value alone. Hashing a value that contains a `Hashed` reads its stored hash instead of walking it.

-}
type Hashed a
    = Hashed a


{-| Pair a value with its hash, computing the hash once.
-}
hashed : a -> Hashed a
hashed =
    Eco.Kernel.FNV.hashed


{-| The value, the same one given to `hashed`.
-}
value : Hashed a -> a
value =
    Eco.Kernel.FNV.value


{-| The stored hash: `hash (value h)`.
-}
hashOf : Hashed a -> Int
hashOf =
    Eco.Kernel.FNV.hashOf
