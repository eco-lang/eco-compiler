module Hash exposing (hash)

{-| Hash any value.

@docs hash

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

The hash reads every unit of a `String`, but only a bounded part of a large structure (256
elements, entries or fields in all, and 16 levels of nesting), so structures that differ only
beyond those bounds hash alike. Functions, `Bytes` and other values that `==` does not compare by content hash by their
kind only.

-}
hash : a -> Int
hash =
    Eco.Kernel.FNV.hash
