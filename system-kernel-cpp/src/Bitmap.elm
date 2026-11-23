module Bitmap exposing (index, popCount32)

{-| Bit counts over 32-bit bitmaps, for SeqDict's hash trie. Both functions read only the low 32 bits
of their bitmap argument, so they give the same results natively (64-bit `Int`) and in JavaScript.
On the native backend both are intrinsics that compile to a hardware population count.

@docs index, popCount32

-}

import Eco.Kernel.Bitmap


{-| `index bitmap i` is the number of set bits of `bitmap` below bit `i mod 32`: the position, in a
compressed array, of the element whose bit is `i`. Bits 32 and up of `bitmap` are ignored.
-}
index : Int -> Int -> Int
index =
    Eco.Kernel.Bitmap.index


{-| The number of set bits among the low 32 bits of an `Int`.
-}
popCount32 : Int -> Int
popCount32 =
    Eco.Kernel.Bitmap.popCount32
