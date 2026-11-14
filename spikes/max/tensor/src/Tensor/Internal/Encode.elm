module Tensor.Internal.Encode exposing (draws, encodeValues, lcg, normalDraws)

{-| Some resident buffers (buffers that outlive a run; see `Train`) start with contents computed in
Elm and handed over as bytes, and this module makes those bytes. It writes a tensor's element
values in the package encoding, and it holds the pseudo-random generator from which values, such as
parameters' initial values, are drawn in Elm without running a graph.

The package encoding is stated in `Train`'s module docstring: row-major, little-endian, each element
at its dtype's width, with nothing between or around the elements. `encodeValues` writes elements in
the order of its list, so putting them in row-major order is the caller's part. The rest of the
encoding is settled here.

f16 and bf16 elements are written as 16-bit patterns rounded to nearest even from the value's f32
pattern, so a value is rounded twice: first to f32, as elm/bytes writes it, then to 16 bits. Values
too large for the format become ±∞. Every bf16 NaN is written as `0x7FC0`, while an f16 NaN keeps
the sign of its f32 pattern. The largest part of this module is that rounding, done on bits because
elm/bytes writes floats only as 32 or 64 bits.

A mask element is one byte: 1 for any nonzero value, a float NaN included, and 0 for zero. A 64-bit
integer is written as its low 32 bits and then its high 32 bits, which for a negative `Int` is its
two's-complement pattern; a `ui64` element held under the u64 convention of
`Tensor.Internal.Values` is therefore written as its own 64 bits. Under JavaScript not every
integer beyond ±2⁵³ can be held as an `Int` (see `Tensor.Internal.Values`).

Nothing is range-checked. An si8, ui8 or si32 element outside its dtype's range is handed to
elm/bytes' fixed-width encoder as it is, and a float written for an integer dtype is first rounded
with `round`, NaN and ±∞ included.

The generator is a 32-bit linear congruential generator. A seed may be any `Int`, each state gives
the next by `lcg`, every state after the seed is in 0 … 2³² − 1, and a uniform draw in `draws` is a
state divided by 2³², so it lies in [0, 1). The draw functions return the last state they drew
from (the seed itself when they draw nothing), so that the next draws can start from it. The values
a seed gives depend on the generator and on the order in which `draws` and `normalDraws` write their
values, last draw first, so changing either changes them. `normalDraws`' values also depend on the platform's `logBase`, `sqrt`, `cos`
and `sin`, so they need not agree to the last bit across platforms.

-}

import Bitwise
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Values exposing (Values(..))


{-| Returns `values` as elements of `dt` in the package encoding, in list order.

`IntValues` given for an integer dtype are written at its width with no range check, and for a
mask give 1 for any nonzero value. `FloatValues` given for an integer dtype are rounded with
`round`, unchecked, and for a mask give 1 for any nonzero value, NaN included. `IntValues` given
for a float dtype are converted with `toFloat`.

-}
encodeValues : DT -> Values -> Bytes
encodeValues dt values =
    case values of
        FloatValues l ->
            Encode.encode (Encode.sequence (List.map (element dt) l))

        IntValues l ->
            Encode.encode (Encode.sequence (List.map (intElement dt) l))


{-| Returns the encoder for one integer element of `dt`. An integer dtype writes `n` at its width,
unchecked; a mask writes 1 for any nonzero `n`; a float dtype writes `toFloat n` as `element` does.
-}
intElement : DT -> Int -> Encode.Encoder
intElement dt n =
    case dt of
        SI8 ->
            Encode.signedInt8 n

        UI8 ->
            Encode.unsignedInt8 n

        SI32 ->
            Encode.signedInt32 LE n

        SI64 ->
            int64 n

        UI64 ->
            int64 n

        Bool ->
            Encode.unsignedInt8
                (if n /= 0 then
                    1

                 else
                    0
                )

        _ ->
            element dt (toFloat n)


{-| Returns the encoder for one float element of `dt`.

An integer dtype writes `round v`, unchecked. A mask writes 1 for any nonzero `v`, NaN included.

-}
element : DT -> Float -> Encode.Encoder
element dt v =
    case dt of
        F32 ->
            Encode.float32 LE v

        F64 ->
            Encode.float64 LE v

        BF16 ->
            Encode.unsignedInt16 LE (bf16Bits v)

        F16 ->
            Encode.unsignedInt16 LE (f16Bits v)

        SI8 ->
            Encode.signedInt8 (round v)

        UI8 ->
            Encode.unsignedInt8 (round v)

        SI32 ->
            Encode.signedInt32 LE (round v)

        SI64 ->
            int64 (round v)

        UI64 ->
            int64 (round v)

        Bool ->
            Encode.unsignedInt8
                (if v /= 0 then
                    1

                 else
                    0
                )


{-| Returns the encoder for `n` as a little-endian 64-bit integer: its low 32 bits, then its high
32 bits as a signed word, which for a negative `n` is its two's-complement pattern. Under JavaScript
an `Int` outside the 64-bit range is written modulo 2⁶⁴.
-}
int64 : Int -> Encode.Encoder
int64 n =
    let
        low =
            modBy 4294967296 n

        high =
            (n - low) // 4294967296
    in
    Encode.sequence [ Encode.unsignedInt32 LE low, Encode.signedInt32 LE high ]


{-| Returns the bit pattern of `v` rounded to f32, as an `Int` in 0 … 2³² − 1.
-}
f32Bits : Float -> Int
f32Bits v =
    Encode.encode (Encode.float32 LE v)
        |> Decode.decode (Decode.unsignedInt32 LE)
        |> Maybe.withDefault 0


{-| Returns the bf16 pattern of `v`: the upper 16 bits of its f32 pattern, rounded to nearest even
on the lower 16.

Infinities are kept, and a finite value that rounds past the largest bf16 becomes ±∞. Every NaN
gives `0x7FC0`, whatever its sign.

-}
bf16Bits : Float -> Int
bf16Bits v =
    let
        bits =
            f32Bits v

        upper =
            bits // 65536

        lower =
            modBy 65536 bits
    in
    if isNaN v then
        0x7FC0

    else if lower > 0x8000 || (lower == 0x8000 && modBy 2 upper == 1) then
        modBy 65536 (upper + 1)

    else
        upper


{-| Returns the f16 pattern of `v`, rounded from its f32 pattern to nearest even.

Values too large for f16 give ±∞. Below 2⁻¹⁴, the smallest normal f16, a value is rounded to a
multiple of 2⁻²⁴, the smallest subnormal, keeping its sign, so a magnitude of 2⁻²⁵ or less gives a
signed zero. A NaN gives `0x7E00` with the sign of its f32 pattern kept and its payload dropped.

-}
f16Bits : Float -> Int
f16Bits v =
    let
        bits =
            f32Bits v

        sign =
            Bitwise.and (Bitwise.shiftRightZfBy 16 bits) 0x8000

        e =
            Bitwise.and (Bitwise.shiftRightZfBy 23 bits) 0xFF

        mant =
            Bitwise.and bits 0x007FFFFF
    in
    if e == 0xFF then
        Bitwise.or sign
            (if mant /= 0 then
                0x7E00

             else
                0x7C00
            )

    else
        let
            ex =
                e - 127 + 15
        in
        if ex >= 31 then
            Bitwise.or sign 0x7C00

        else if ex <= 0 then
            if ex < -10 then
                sign

            else
                let
                    m =
                        Bitwise.or mant 0x00800000

                    shift =
                        14 - ex

                    half =
                        Bitwise.shiftLeftBy (shift - 1) 1

                    rounded =
                        roundShift m shift half
                in
                Bitwise.or sign rounded

        else
            let
                rounded =
                    roundShift mant 13 0x1000

                combined =
                    ex * 1024 + rounded
            in
            if combined >= 0x7C00 then
                Bitwise.or sign 0x7C00

            else
                Bitwise.or sign combined


{-| Returns `m` shifted right by `shift` bits, rounded to nearest even. `half` must be
2^(`shift` − 1). A result that rounds up may carry into the bit above those kept.
-}
roundShift : Int -> Int -> Int -> Int
roundShift m shift half =
    let
        q =
            Bitwise.shiftRightZfBy shift m

        r =
            m - Bitwise.shiftLeftBy shift q
    in
    if r > half || (r == half && modBy 2 q == 1) then
        q + 1

    else
        q


{-| Returns the generator's state after `seed`: (1664525 · `seed` + 1013904223) mod 2³², a value
in 0 … 2³² − 1.

Under JavaScript the arithmetic can be inexact once |`seed`| is beyond about 5.4 · 10⁹. Every state
this returns is below that, so only a starting seed beyond it can give other values than native
code.

-}
lcg : Int -> Int
lcg seed =
    modBy 4294967296 (1664525 * seed + 1013904223)


{-| Returns `count` values `toValue u`, each `u` a uniform draw from the states that follow
`seed0`, and the last state. The list holds the last draw first. A `count` of 0 or less gives no
values and returns `seed0`.
-}
draws : (Float -> Float) -> Int -> Int -> ( List Float, Int )
draws toValue count seed0 =
    let
        go k seed acc =
            if k <= 0 then
                ( acc, seed )

            else
                let
                    s =
                        lcg seed

                    u =
                        toFloat s / 4294967296
                in
                go (k - 1) s (toValue u :: acc)
    in
    go count seed0 []


{-| Returns `count` values drawn from the normal distribution with mean `mean` and standard
deviation `std`, and the last state.

Each pair of values comes from two successive states `s1`, `s2` by the Box–Muller transform:
with u1 = (`s1` + 1) / (2³² + 1), which is never 0, and u2 = `s2` / 2³², the pair is
`mean` + `std` · r · cos (2π u2) and `mean` + `std` · r · sin (2π u2), where r = √(−2 ln u1).

The list holds the last pair first, each pair's cosine value first. An odd `count` still draws a
whole last pair: the sine value of the first pair is dropped, and the state returned is the second
of the last pair's two states. A `count` of 0 or less gives no values and returns `seed0`.

-}
normalDraws : Float -> Float -> Int -> Int -> ( List Float, Int )
normalDraws mean std count seed0 =
    let
        go k seed acc =
            if k <= 0 then
                ( List.take count acc, seed )

            else
                let
                    s1 =
                        lcg seed

                    s2 =
                        lcg s1

                    u1 =
                        (toFloat s1 + 1) / 4294967297

                    u2 =
                        toFloat s2 / 4294967296

                    r =
                        sqrt (-2 * logBase e u1)

                    a =
                        mean + std * r * cos (2 * pi * u2)

                    b =
                        mean + std * r * sin (2 * pi * u2)
                in
                go (k - 2) s2 (a :: b :: acc)
    in
    go count seed0 []
