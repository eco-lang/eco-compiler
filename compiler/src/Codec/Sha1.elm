module Codec.Sha1 exposing (hex)

{-| Computes SHA-1 digests (FIPS 180-4), which the package manager uses to check a
downloaded package archive against the hash the registry gives for it.

The arithmetic is written so that it gives the same answer whether `Bitwise` works on
32-bit integers, as in JavaScript, or on 64-bit ones, as on eco's native backend. Every
word is kept in `[0, 2^32)`: sums are reduced with `modBy`, rotations are built from
`//` and `modBy` rather than from shifts, the complement of a word is `0xFFFFFFFF` minus
it, and the result of `Bitwise.and`, `or` and `xor`, which JavaScript gives as a signed
32-bit number, is brought back into range by `u32`.

@docs hex

-}

import Array exposing (Array)
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode exposing (Decoder, Step(..))
import Bytes.Encode as Encode
import Bitwise


{-| The SHA-1 digest of the bytes, as 40 lowercase hexadecimal digits.

    hex (Bytes.Encode.encode (Bytes.Encode.string "abc"))
        == "a9993e364706816aba3e25717850c26c9cd0d89d"

-}
hex : Bytes -> String
hex message =
    let
        padded =
            pad message

        blocks =
            Bytes.width padded // 64

        ( h0, h1, h2 ) =
            ( 0x67452301, 0xEFCDAB89, 0x98BADCFE )

        ( h3, h4 ) =
            ( 0x10325476, 0xC3D2E1F0 )

        digest =
            Decode.decode (Decode.loop ( blocks, State h0 h1 h2 h3 h4 ) blockStep) padded
                |> Maybe.withDefault (State 0 0 0 0 0)
    in
    String.concat (List.map wordToHex [ digest.a, digest.b, digest.c, digest.d, digest.e ])



-- ====== STATE ======


{-| The five words of the hash state.
-}
type alias State =
    { a : Int
    , b : Int
    , c : Int
    , d : Int
    , e : Int
    }


{-| Reads the remaining `n` blocks, each of 16 big-endian words, folding each into the
state.
-}
blockStep : ( Int, State ) -> Decoder (Step ( Int, State ) State)
blockStep ( n, state ) =
    if n <= 0 then
        Decode.succeed (Done state)

    else
        Decode.loop ( 16, [] ) wordStep
            |> Decode.map (\words -> Loop ( n - 1, processBlock (Array.fromList words) state ))


{-| Reads `n` more big-endian words onto `acc`, and gives them in the order read.
-}
wordStep : ( Int, List Int ) -> Decoder (Step ( Int, List Int ) (List Int))
wordStep ( n, acc ) =
    if n <= 0 then
        Decode.succeed (Done (List.reverse acc))

    else
        Decode.unsignedInt32 BE
            |> Decode.map (\w -> Loop ( n - 1, w :: acc ))



-- ====== PADDING ======


{-| The message followed by a 1 bit, zero bits up to 56 bytes past a multiple of 64,
and the message's length in bits as a big-endian 64-bit number.
-}
pad : Bytes -> Bytes
pad message =
    let
        len =
            Bytes.width message

        zeros =
            modBy 64 (55 - len)

        bitLength =
            len * 8
    in
    Encode.encode
        (Encode.sequence
            (Encode.bytes message
                :: Encode.unsignedInt8 0x80
                :: List.repeat zeros (Encode.unsignedInt8 0)
                ++ [ Encode.unsignedInt32 BE (bitLength // 4294967296)
                   , Encode.unsignedInt32 BE (modBy 4294967296 bitLength)
                   ]
            )
        )



-- ====== COMPRESSION ======


{-| Folds one block of 16 words into the state.
-}
processBlock : Array Int -> State -> State
processBlock block state =
    let
        schedule =
            expand 16 block

        final =
            rounds 0 schedule state
    in
    { a = add state.a final.a
    , b = add state.b final.b
    , c = add state.c final.c
    , d = add state.d final.d
    , e = add state.e final.e
    }


{-| Extends the message schedule from `t` words to 80.
-}
expand : Int -> Array Int -> Array Int
expand t w =
    if t >= 80 then
        w

    else
        let
            at i =
                Array.get i w |> Maybe.withDefault 0

            next =
                rotateLeft 1 (xor32 (xor32 (at (t - 3)) (at (t - 8))) (xor32 (at (t - 14)) (at (t - 16))))
        in
        expand (t + 1) (Array.push next w)


{-| Runs rounds `t` to 79 over the working state.
-}
rounds : Int -> Array Int -> State -> State
rounds t schedule s =
    if t >= 80 then
        s

    else
        let
            ( f, k ) =
                if t < 20 then
                    ( or32 (and32 s.b s.c) (and32 (0xFFFFFFFF - s.b) s.d), 0x5A827999 )

                else if t < 40 then
                    ( xor32 (xor32 s.b s.c) s.d, 0x6ED9EBA1 )

                else if t < 60 then
                    ( or32 (or32 (and32 s.b s.c) (and32 s.b s.d)) (and32 s.c s.d), 0x8F1BBCDC )

                else
                    ( xor32 (xor32 s.b s.c) s.d, 0xCA62C1D6 )

            w =
                Array.get t schedule |> Maybe.withDefault 0

            temp =
                modBy 4294967296 (rotateLeft 5 s.a + f + s.e + k + w)
        in
        rounds (t + 1)
            schedule
            { a = temp
            , b = s.a
            , c = rotateLeft 30 s.b
            , d = s.c
            , e = s.d
            }



-- ====== WORD ARITHMETIC ======


{-| The sum of two words, modulo 2^32.
-}
add : Int -> Int -> Int
add x y =
    modBy 4294967296 (x + y)


{-| The word rotated left by `n` bits, for `n` in 1 to 31. Built from `//` and `modBy`,
whose results never exceed 2^32 here, so it is exact on both backends.
-}
rotateLeft : Int -> Int -> Int
rotateLeft n x =
    let
        split =
            2 ^ (32 - n)
    in
    modBy split x * (2 ^ n) + x // split


{-| Brings the result of a 32-bit bitwise operation on two words back into `[0, 2^32)`:
JavaScript gives it as a signed 32-bit number, eco's native backend as it is.
-}
u32 : Int -> Int
u32 x =
    if x < 0 then
        x + 4294967296

    else
        x


{-| The bitwise and of two words, as a word.
-}
and32 : Int -> Int -> Int
and32 x y =
    u32 (Bitwise.and x y)


{-| The bitwise or of two words, as a word.
-}
or32 : Int -> Int -> Int
or32 x y =
    u32 (Bitwise.or x y)


{-| The bitwise exclusive or of two words, as a word.
-}
xor32 : Int -> Int -> Int
xor32 x y =
    u32 (Bitwise.xor x y)



-- ====== HEX ======


{-| The word as 8 lowercase hexadecimal digits.
-}
wordToHex : Int -> String
wordToHex w =
    List.range 0 7
        |> List.map (\i -> hexDigit (modBy 16 (w // (2 ^ (4 * (7 - i))))))
        |> String.fromList


hexDigit : Int -> Char
hexDigit n =
    if n < 10 then
        Char.fromCode (48 + n)

    else
        Char.fromCode (87 + n)
