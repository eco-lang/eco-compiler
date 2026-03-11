module Compiler.Data.BitSet exposing
    ( BitSet
    , empty
    , emptyWithSize
    , fromSize
    , insert
    , insertGrowing
    , member
    , removeGrowing
    , setWord
    )

{-| A compact bit set backed by an Array of 32-bit words.

@docs BitSet, empty, emptyWithSize, fromSize, insert, insertGrowing, member, removeGrowing, setWord

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


{-| Create a BitSet with all bits set up to the given size.
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
