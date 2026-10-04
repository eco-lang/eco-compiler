module Compiler.Data.BitSet exposing (BitSet, count, empty, emptyWithSize, fromSize, insert, insertGrowing, member, remove, removeGrowing, setWord)

{-| A set of small non-negative integers, such as dense ids, kept as one bit per
possible member. Asking whether an integer is a member is one array lookup and
one shift. The module answers membership and counts members; it has no way to
list them.

A set has a _capacity_, its `size`: it can hold the integers from 0 to
`size - 1` and no others. `member`, `insert` and `remove` treat an integer
outside that range as absent and leave the set as it is; they never raise the
capacity. `insertGrowing` and `removeGrowing` raise it first, so they suit a set
whose largest member is not known in advance.

The bits are stored 32 to a _word_, one `Int` each, in an `Array`. A set may
have fewer words than its capacity needs, and a missing word reads as all
clear. `fromSize` allocates every word at once, `emptyWithSize` none, and
`insert` and `remove` add words up to the one they touch.

Only the low 32 bits of a word stand for members, on both back ends. On the
JavaScript back end a word with bit 31 set may be a negative `Int`, as it is
once `insert` has set that bit. `member` and `count` give the same answer
whatever the sign.

@docs BitSet, count, empty, emptyWithSize, fromSize, insert, insertGrowing, member, remove, removeGrowing, setWord

-}

import Array exposing (Array)
import Bitwise


{-| A set of integers drawn from 0 up to, but not including, a capacity.

`size` is the capacity, not the number of members; `count` gives that. Bit `i`
of the word at index `w` in `words` stands for the integer `32 * w + i`.

`==` compares `size` and `words`, not the members. Two sets with the same
members and capacity differ when one has allocated more words than the other,
as an empty set from `fromSize` and one from `emptyWithSize` do.

-}
type alias BitSet =
    { size : Int
    , words : Array Int
    }


{-| The number of bits in one word. It is 32, the width at which Elm's `Bitwise`
functions work on the JavaScript back end, so that a word means the same on
both back ends.
-}
wordSize : Int
wordSize =
    32


{-| The empty set with capacity 0 and no words. Until `insertGrowing` or
`removeGrowing` raises its capacity, `insert` ignores every integer given to it.
-}
empty : BitSet
empty =
    { size = 0, words = Array.empty }


{-| Creates an empty set with capacity `nBits`, with every word it needs
allocated now. Its members are those of `emptyWithSize nBits`, but because its
words exist, `setWord` can write to any of them straight away.
-}
fromSize : Int -> BitSet
fromSize nBits =
    { size = nBits
    , words = Array.repeat ((nBits + wordSize - 1) // wordSize) 0
    }


{-| Creates an empty set with capacity `nBits` and no words allocated. `insert`
and `remove` allocate words as they reach them, but `setWord` does nothing until
the word it names exists, so `fromSize` is the one to fill a word at a time.
-}
emptyWithSize : Int -> BitSet
emptyWithSize nBits =
    { size = nBits
    , words = Array.empty
    }


{-| Returns the index of the word that holds the bit for `bitIndex`.
-}
wordIndex : Int -> Int
wordIndex bitIndex =
    bitIndex // wordSize


{-| Returns the position of the bit for `bitIndex` within its word, from 0 for
the least significant bit to 31.
-}
bitOffset : Int -> Int
bitOffset bitIndex =
    bitIndex |> modBy wordSize


{-| Returns whether `bitIndex` is a member of `set`. An integer outside the
capacity, or one whose word has not been allocated, is not a member.
-}
member : Int -> BitSet -> Bool
member bitIndex set =
    if bitIndex < 0 || bitIndex >= set.size then
        False

    else
        case Array.get (wordIndex bitIndex) set.words of
            Nothing ->
                False

            Just word ->
                Bitwise.and (Bitwise.shiftRightZfBy (bitOffset bitIndex) word) 1 /= 0


{-| Returns the number of bits set among the low 32 bits of each word of `set`,
by counting the bits of every word on each call. This is the number of members,
unless bits at or beyond the capacity have been stored, as `setWord` allows:
those are counted here although `member` reports them absent.
-}
count : BitSet -> Int
count set =
    Array.foldl (\word n -> n + popcount32 word) 0 set.words


{-| Returns the number of set bits among the low 32 bits of `word`.

It counts in parallel within the word: first the bits of each 2-bit field, then
of each 4-bit field, then of each byte, then adds the four byte counts. The
common last step, a multiplication by `0x01010101`, relies on the product
wrapping at 32 bits, which a 64-bit native `Int` does not do, so the bytes are
added with shifts instead. On the JavaScript back end a word with bit 31 set may
be negative, and then so is `pairs`; the `Bitwise` functions read each as the same
32-bit pattern, and every later intermediate stays below 2^31, so the count is
the same on both back ends.

-}
popcount32 : Int -> Int
popcount32 word =
    let
        pairs =
            word - Bitwise.and (Bitwise.shiftRightZfBy 1 word) 0x55555555

        quads =
            Bitwise.and pairs 0x33333333
                + Bitwise.and (Bitwise.shiftRightZfBy 2 pairs) 0x33333333

        bytes =
            Bitwise.and (quads + Bitwise.shiftRightZfBy 4 quads) 0x0F0F0F0F

        halves =
            bytes + Bitwise.shiftRightZfBy 8 bytes
    in
    Bitwise.and (halves + Bitwise.shiftRightZfBy 16 halves) 0x3F


{-| Returns `set` with zero words appended, if it needs them, so that the word at
index `wIdx` exists. The capacity is not changed.
-}
ensureWord : Int -> BitSet -> BitSet
ensureWord wIdx set =
    let
        len =
            Array.length set.words
    in
    if len > wIdx then
        set

    else
        { set | words = Array.append set.words (Array.repeat (wIdx + 1 - len) 0) }


{-| Adds `bitIndex` to `set`, allocating words up to the one that holds it.

An integer outside the capacity, that is one not in the range
`0 <= bitIndex < size`, is ignored and the set returned unchanged; nothing
reports it. `insertGrowing` raises the capacity instead.

-}
insert : Int -> BitSet -> BitSet
insert bitIndex set0 =
    if bitIndex < 0 || bitIndex >= set0.size then
        set0

    else
        let
            wIndex =
                wordIndex bitIndex

            mask =
                Bitwise.shiftLeftBy (bitOffset bitIndex) 1

            set =
                ensureWord wIndex set0
        in
        case Array.get wIndex set.words of
            Nothing ->
                set

            Just word ->
                { set | words = Array.set wIndex (Bitwise.or word mask) set.words }


{-| Removes `bitIndex` from `set`. An integer outside the capacity is ignored,
as it cannot be a member. Like `insert`, it allocates words up to the one that
holds the bit, even when that bit was already clear.
-}
remove : Int -> BitSet -> BitSet
remove bitIndex set0 =
    if bitIndex < 0 || bitIndex >= set0.size then
        set0

    else
        let
            wIndex =
                wordIndex bitIndex

            mask =
                Bitwise.shiftLeftBy (bitOffset bitIndex) 1

            set =
                ensureWord wIndex set0
        in
        case Array.get wIndex set.words of
            Nothing ->
                set

            Just word ->
                { set | words = Array.set wIndex (Bitwise.and word (Bitwise.complement mask)) set.words }


{-| Adds `bitIndex` to `set`, first raising the capacity, if it does not already
cover `bitIndex`, to the smallest multiple of 64 above it. A negative
`bitIndex` is ignored.
-}
insertGrowing : Int -> BitSet -> BitSet
insertGrowing bitIndex set =
    if bitIndex < 0 then
        set

    else
        insert bitIndex (growTo bitIndex set)


{-| Removes `bitIndex` from `set`, first raising the capacity as `insertGrowing`
does. The capacity is raised even though an integer beyond it cannot have been
a member. A negative `bitIndex` is ignored.
-}
removeGrowing : Int -> BitSet -> BitSet
removeGrowing bitIndex set =
    if bitIndex < 0 then
        set

    else
        remove bitIndex (growTo bitIndex set)


{-| Returns `set` with a capacity that covers `bitIndex`. A set that already
covers it is returned unchanged. Otherwise the capacity becomes the smallest
multiple of 64 above `bitIndex`, so that integers arriving in increasing order
raise it once per 64 rather than once each, and words are allocated for the
whole new capacity.
-}
growTo : Int -> BitSet -> BitSet
growTo bitIndex set =
    if bitIndex < set.size then
        set

    else
        let
            newSize =
                ((bitIndex + 64) // 64) * 64

            currentWordCount =
                Array.length set.words

            neededWordCount =
                (newSize + wordSize - 1) // wordSize

            extraWords =
                neededWordCount - currentWordCount
        in
        { size = newSize
        , words =
            if extraWords > 0 then
                Array.append set.words (Array.repeat extraWords 0)

            else
                set.words
        }


{-| Replaces the word at index `wIndex` with `newWord`, setting membership for
the 32 integers from `32 * wIndex` at once: bit `i` of `newWord` stands for
`32 * wIndex + i`.

Only an allocated word is replaced. A `wIndex` beyond the allocated words leaves
the set unchanged, which for a set from `emptyWithSize` is every `wIndex` until
some other call has allocated that word. `newWord` is not checked against the
capacity: bits it sets for integers at or beyond `size` are stored, and `count`
counts them although `member` reports them absent. `member` and `count` ignore
bits above 31.

-}
setWord : Int -> Int -> BitSet -> BitSet
setWord wIndex newWord set =
    if wIndex < 0 || wIndex >= Array.length set.words then
        set

    else
        { set | words = Array.set wIndex newWord set.words }
