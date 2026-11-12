module Tensor.Internal.Key exposing (Key, mix, mixFloat, mixFloats, mixInt64s, mixInts, mixKey, mixString, start)

{-| Structural keys: two multiplicative hashes, each below 2^31, so every product stays exact on
every Elm back end. Equal expressions get equal keys; lowering checks the shallow structure on
every key hit, so a collision is reported rather than merged.
-}

import Bytes exposing (Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode


type alias Key =
    ( Int, Int )


start : String -> Key
start tag =
    mixString tag ( 17, 19 )


mix : Int -> Key -> Key
mix x ( a, b ) =
    ( modBy 2147483647 (a * 1000003 + x), modBy 1000000007 (b * 131071 + x) )


mixInts : List Int -> Key -> Key
mixInts l k =
    List.foldl mix (mix (List.length l) k) l


mixString : String -> Key -> Key
mixString s k =
    String.foldl (\c acc -> mix (Char.toCode c) acc) (mix (String.length s) k) s


mixKey : Key -> Key -> Key
mixKey ( a, b ) k =
    mix b (mix a k)


{-| By the float's 64-bit pattern: -0.0 and 0.0 differ, NaN equals itself.
-}
mixFloat : Float -> Key -> Key
mixFloat f k =
    let
        bytes =
            Encode.encode (Encode.float64 LE f)

        words =
            Decode.decode (Decode.map2 Tuple.pair (Decode.unsignedInt32 LE) (Decode.unsignedInt32 LE)) bytes
                |> Maybe.withDefault ( 0, 0 )
    in
    k |> mix (modBy 65536 (Tuple.first words)) |> mix (Tuple.first words // 65536) |> mix (modBy 65536 (Tuple.second words)) |> mix (Tuple.second words // 65536)


mixFloats : List Float -> Key -> Key
mixFloats l k =
    List.foldl mixFloat (mix (List.length l) k) l


{-| Integer constants' values. An `Int` within ±2⁵³ is mixed as `mixFloat` mixes the same number
(so a constant's key does not depend on whether it was written as `Float`s or `Int`s, and keys
match those of earlier versions: shared subgraphs are named by key). A larger one is mixed as a
marker, 65536 (never a limb), then its 64 bits as four 16-bit limbs (floored division: exact for
negative values and the most negative `Int`).
-}
mixInt64s : List Int -> Key -> Key
mixInt64s l k =
    List.foldl mixInt64 (mix (List.length l) k) l


mixInt64 : Int -> Key -> Key
mixInt64 n k =
    let
        bound =
            9007199254740992

        step _ ( m, acc ) =
            let
                p =
                    modBy 65536 m
            in
            ( (m - p) // 65536, mix p acc )
    in
    if n >= -bound && n <= bound then
        mixFloat (toFloat n) k

    else
        List.foldl step ( n, mix 65536 k ) [ 1, 2, 3, 4 ] |> Tuple.second
