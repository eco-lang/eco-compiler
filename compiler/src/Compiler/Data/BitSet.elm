module Compiler.Data.BitSet exposing (BitSet, count, empty, emptyWithSize, fromSize, insert, insertGrowing, member, remove, removeGrowing, setWord)

{-| A compact bit set backed by an Array of 32-bit words.

@docs BitSet, count, empty, emptyWithSize, fromSize, insert, insertGrowing, member, remove, removeGrowing, setWord

-}

import Array exposing (Array)
import Bitwise


{-| A set of non-negative integers stored as an array of 32-bit words.
-}
type alias BitSet =
    { size : Int
    , words : Array Int
    }


wordSize : Int
wordSize =
    32


{-| An empty BitSet with no allocated storage.
-}
empty : BitSet
empty =
    { size = 0, words = Array.empty }


{-| Create an empty BitSet with storage for the given number of bits already
allocated. Unlike `emptyWithSize` the backing words exist immediately, so
`insert` never has to grow the array — use this when the bit count is known.
-}
fromSize : Int -> BitSet
fromSize nBits =
    { size = nBits
    , words = Array.repeat ((nBits + wordSize - 1) // wordSize) 0
    }


{-| Create an empty BitSet pre-allocated for the given number of bits.
-}
emptyWithSize : Int -> BitSet
emptyWithSize nBits =
    { size = nBits
    , words = Array.empty
    }


wordIndex : Int -> Int
wordIndex bitIndex =
    bitIndex // wordSize


bitOffset : Int -> Int
bitOffset bitIndex =
    bitIndex |> modBy wordSize


{-| Test whether a bit is set.
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


{-| How many bits are set.

Computed on demand in O(words) rather than maintained as a counter, so callers
that never ask pay nothing on `insert`/`remove` — the usual reason a bit set
does not carry a cardinality field.

-}
count : BitSet -> Int
count set =
    Array.foldl (\word n -> n + popcount32 word) 0 set.words


{-| Population count of one 32-bit word, by the standard SWAR halving.

Deliberately multiply-free: the usual `* 0x01010101` horizontal sum needs 32-bit
wraparound to be correct. Every step here is `and`/`add`/`shiftRightZfBy` on a
value below 2^31, which reads the same whether `Int` is a 32-bit JS integer or a
native 64-bit one. `insert` can leave a word negative on the JS backend (bit 31
set), and that is fine: the first `Bitwise.and` re-normalizes the pattern before
any value escapes.

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


{-| Set a bit. The index must be within the allocated size.
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


{-| Clear a bit. The index must be within the allocated size; clearing an index
outside it is a no-op, since it is already absent.
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


{-| Grow the BitSet so that `bitIndex` is a valid index, then insert.
Useful when the maximum index is not known ahead of time.
-}
insertGrowing : Int -> BitSet -> BitSet
insertGrowing bitIndex set =
    if bitIndex < 0 then
        set

    else
        insert bitIndex (growTo bitIndex set)


{-| Grow the BitSet so that `bitIndex` is a valid index, then remove.
Useful when the maximum index is not known ahead of time.
-}
removeGrowing : Int -> BitSet -> BitSet
removeGrowing bitIndex set =
    if bitIndex < 0 then
        set

    else
        remove bitIndex (growTo bitIndex set)


{-| Ensure the BitSet is large enough to hold the given bit index.
Grows by rounding up to the next multiple of 64 bits for amortization.
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


{-| Replace an entire 32-bit word at the given word index.
-}
setWord : Int -> Int -> BitSet -> BitSet
setWord wIndex newWord set =
    if wIndex < 0 || wIndex >= Array.length set.words then
        set

    else
        { set | words = Array.set wIndex newWord set.words }
