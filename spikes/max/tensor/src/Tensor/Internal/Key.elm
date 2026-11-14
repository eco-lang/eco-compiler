module Tensor.Internal.Key exposing (Key, mix, mixFloat, mixFloats, mixInt64s, mixInts, mixKey, mixString, start)

{-| Keys: hash values that stand in for the identity of a large structure, so that two structures
can be matched or told apart in constant time instead of by walking them.

A key is built by describing a value as a sequence of integers and _mixing_ them, one at a time,
into a starting key. Two values described by the same sequence get the same key. Two described by
different sequences usually get different keys, but a key is a hash and two can collide; nothing in
this module detects a collision. The structures keyed are tensor expressions: what goes into the
description of each kind of expression, and so what its key depends on, is decided by
`Tensor.Internal.Expr`.

The mixers for lists and strings mix the length before the items, so that a description made of
several lists is a different sequence when the same items are divided between the lists
differently.

A key is two independent hashes, so two different descriptions share a key only if they collide in
both. Mixing an integer `x` multiplies the first hash by 1000003 and the second by 131071, adds `x`
to each, and reduces them modulo 2147483647 and 1000000007. Both moduli are below 2³¹, so for a key
made here neither product reaches 2⁵¹. That bound is what makes keys the same under JavaScript,
where an `Int` is a double and integer arithmetic is exact only up to 2⁵³, and in native code, where
an `Int` has 64 bits: `mix` gives the same result on both for any `x` of magnitude below 2⁵³ − 2⁵¹.
The other mixers break their input into small numbers (character codes, the components of keys
made here, 16-bit pieces) before mixing, so only integers mixed whole by `mix` and `mixInts` are
subject to that bound.

-}

import Bytes exposing (Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Tensor.Internal.Values as Values


{-| A key: the pair of hash values that stands for a value's identity.

This is a name for a pair of `Int`s, not a new type, so any pair is accepted where a `Key` is
expected. A key returned by this module has its first component in 0 … 2147483646 and its second
in 0 … 1000000006.

-}
type alias Key =
    ( Int, Int )


{-| Returns the key a description starts from: a fixed initial key with the string `tag` mixed in.
Starting from a tag that names the kind of value keeps two kinds whose descriptions continue with
the same numbers from being mixed from the same sequence.
-}
start : String -> Key
start tag =
    mixString tag ( 17, 19 )


{-| Returns the given key with the integer `x` mixed into both hashes.

The result is the same under JavaScript and native code when the key was made here and `x`'s
magnitude is below 2⁵³ − 2⁵¹; beyond that the two may differ.

-}
mix : Int -> Key -> Key
mix x ( a, b ) =
    ( modBy 2147483647 (a * 1000003 + x), modBy 1000000007 (b * 131071 + x) )


{-| Returns `k` with the length of `l` and then each of its integers mixed in. Each integer is
mixed whole, as `mix` mixes it, and is subject to the same bound.
-}
mixInts : List Int -> Key -> Key
mixInts l k =
    List.foldl mix (mix (List.length l) k) l


{-| Returns `k` with the length of `s` and then the code of each of its characters mixed in.
-}
mixString : String -> Key -> Key
mixString s k =
    String.foldl (\c acc -> mix (Char.toCode c) acc) (mix (String.length s) k) s


{-| Returns `k` with another key mixed in, its first component and then its second, so that a
description can include the key of a value it is built from.
-}
mixKey : Key -> Key -> Key
mixKey ( a, b ) k =
    mix b (mix a k)


{-| Returns `k` with the 64-bit IEEE 754 pattern of `f` mixed in, as four 16-bit pieces from the
least significant end.

Mixing the pattern rather than the number makes `-0.0` and `0.0` different, and gives two NaNs with
the same pattern the same key, although `NaN /= NaN`.

-}
mixFloat : Float -> Key -> Key
mixFloat f k =
    let
        bytes =
            Encode.encode (Encode.float64 LE f)

        -- The low and high 32 bits. Decoding the eight bytes just written cannot fail.
        words =
            Decode.decode (Decode.map2 Tuple.pair (Decode.unsignedInt32 LE) (Decode.unsignedInt32 LE)) bytes
                |> Maybe.withDefault ( 0, 0 )
    in
    k |> mix (modBy 65536 (Tuple.first words)) |> mix (Tuple.first words // 65536) |> mix (modBy 65536 (Tuple.second words)) |> mix (Tuple.second words // 65536)


{-| Returns `k` with the length of `l` and then each of its floats mixed in, as `mixFloat` mixes
it.
-}
mixFloats : List Float -> Key -> Key
mixFloats l k =
    List.foldl mixFloat (mix (List.length l) k) l


{-| Returns `k` with the length of `l` and then each of its integers mixed in.

An integer within ±2⁵³ is mixed as `mixFloat` mixes the equal `Float`, so for such a list the
result is the one `mixFloats` gives for the same numbers as `Float`s. Nothing here tells the two
apart: a description that must keep an integer list and a float list distinct has to mix something
else that differs.

A larger integer is mixed as the marker 65536, which no 16-bit piece can equal, followed by the four
16-bit pieces of its 64-bit two's complement pattern from the least significant end
(`Tensor.Internal.Values.limbs`). Because of the marker, a list holding such an integer is never
mixed from the same sequence as a list of integers within ±2⁵³. The key is the same under
JavaScript as in native code for integers in −2⁶³ … 2⁶³ − 1 that JavaScript holds exactly.

-}
mixInt64s : List Int -> Key -> Key
mixInt64s l k =
    List.foldl mixInt64 (mix (List.length l) k) l


{-| Returns `k` with one integer mixed in: as the equal `Float` within ±2⁵³, otherwise as the marker
65536 and the four 16-bit pieces of its 64-bit pattern, lowest first.
-}
mixInt64 : Int -> Key -> Key
mixInt64 n k =
    let
        -- 2⁵³: every integer up to this magnitude is exact as a Float.
        bound =
            9007199254740992
    in
    if n >= -bound && n <= bound then
        mixFloat (toFloat n) k

    else
        List.foldl mix (mix 65536 k) (Values.limbs n)
