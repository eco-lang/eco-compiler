module Sha256 exposing (bench, output)

{-| SHA-256 (FIPS 180-4) over 32-bit words held in Ints, with `Bitwise.and`, `or`, `xor`,
`complement`, `shiftLeftBy` and `shiftRightZfBy`. The work is a hash chain: hash "abc", then hash
each digest's 32 bytes, `n` times in all.

Every word is kept in `0 .. 2^32 - 1` by `modBy 4294967296` after each sum and rotation, rather
than by the usual `shiftRightZfBy 0`: elm/core defines `Bitwise` on 32-bit integers, but eco's
native backend computes it on 64 bits (`shiftRightZfBy 0 -1` is -1 there, 4294967295 in
JavaScript), and code that relies on the 32-bit wrap-around gets wrong digests. Written this way
the program gives the same, correct, result on every backend.

Every run checks the standard's test vectors for "abc" and the 448-bit message, and at the sizes
in `known` the chain's last digest must match one computed with Python's `hashlib`.

-}

import Array exposing (Array)
import Bitwise


roundConstants : Array Int
roundConstants =
    Array.fromList
        [ 0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5
        , 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174
        , 0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA
        , 0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967
        , 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85
        , 0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070
        , 0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3
        , 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
        ]


initialHash : List Int
initialHash =
    [ 0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19 ]


{-| Sum modulo 2^32; both operands may be any Int a `Bitwise` operation gives here (negative on
the JavaScript backends, where `Bitwise` results are signed 32-bit).
-}
add : Int -> Int -> Int
add a b =
    modBy 4294967296 (a + b)


{-| Rotate right; `x` must be in `0 .. 2^32 - 1`.
-}
rotr : Int -> Int -> Int
rotr n x =
    modBy 4294967296 (Bitwise.or (Bitwise.shiftRightZfBy n x) (Bitwise.shiftLeftBy (32 - n) x))


xor3 : Int -> Int -> Int -> Int
xor3 a b c =
    Bitwise.xor a (Bitwise.xor b c)


{-| The message bytes, padded: a 1 bit, zeros, then the length in bits as 64 bits big-endian.
-}
pad : List Int -> List Int
pad bytes =
    let
        length =
            List.length bytes

        zeros =
            modBy 64 (55 - length)

        bits =
            length * 8
    in
    bytes
        ++ (0x80 :: List.repeat zeros 0)
        ++ [ 0, 0, 0, modBy 256 (bits // 0x0100000000), modBy 256 (bits // 0x01000000), modBy 256 (bits // 0x010000), modBy 256 (bits // 0x0100), modBy 256 bits ]


{-| Big-endian 32-bit words of a byte list whose length is a multiple of 4.
-}
words : List Int -> List Int
words bytes =
    case bytes of
        a :: b :: c :: d :: rest ->
            (a * 0x01000000 + b * 0x010000 + c * 0x0100 + d) :: words rest

        _ ->
            []


{-| The 64-word message schedule of one 16-word block.
-}
schedule : List Int -> Array Int
schedule block =
    let
        extend t w =
            if t >= 64 then
                w

            else
                let
                    at i =
                        Maybe.withDefault 0 (Array.get i w)

                    w15 =
                        at (t - 15)

                    w2 =
                        at (t - 2)

                    s0 =
                        xor3 (rotr 7 w15) (rotr 18 w15) (Bitwise.shiftRightZfBy 3 w15)

                    s1 =
                        xor3 (rotr 17 w2) (rotr 19 w2) (Bitwise.shiftRightZfBy 10 w2)
                in
                extend (t + 1) (Array.push (add (add (at (t - 16)) s0) (add (at (t - 7)) s1)) w)
    in
    extend 16 (Array.fromList block)


type alias State =
    { a : Int, b : Int, c : Int, d : Int, e : Int, f : Int, g : Int, h : Int }


compress : List Int -> List Int -> List Int
compress state block =
    let
        w =
            schedule block

        round t s =
            if t >= 64 then
                s

            else
                let
                    s1 =
                        xor3 (rotr 6 s.e) (rotr 11 s.e) (rotr 25 s.e)

                    ch =
                        Bitwise.xor (Bitwise.and s.e s.f) (Bitwise.and (Bitwise.complement s.e) s.g)

                    temp1 =
                        add (add (add s.h s1) (add ch (Maybe.withDefault 0 (Array.get t roundConstants)))) (Maybe.withDefault 0 (Array.get t w))

                    s0 =
                        xor3 (rotr 2 s.a) (rotr 13 s.a) (rotr 22 s.a)

                    maj =
                        xor3 (Bitwise.and s.a s.b) (Bitwise.and s.a s.c) (Bitwise.and s.b s.c)

                    temp2 =
                        add s0 maj
                in
                round (t + 1) (State (add temp1 temp2) s.a s.b s.c (add s.d temp1) s.e s.f s.g)
    in
    case state of
        [ a, b, c, d, e, f, g, h ] ->
            let
                s =
                    round 0 (State a b c d e f g h)
            in
            [ add a s.a, add b s.b, add c s.c, add d s.d, add e s.e, add f s.f, add g s.g, add h s.h ]

        _ ->
            state


{-| The digest of a byte list, as eight 32-bit words.
-}
hash : List Int -> List Int
hash bytes =
    let
        go ws h =
            case ws of
                [] ->
                    h

                _ ->
                    go (List.drop 16 ws) (compress h (List.take 16 ws))
    in
    go (words (pad bytes)) initialHash


toBytes : List Int -> List Int
toBytes digest =
    List.concatMap (\x -> [ Bitwise.shiftRightZfBy 24 x, Bitwise.and 0xFF (Bitwise.shiftRightZfBy 16 x), Bitwise.and 0xFF (Bitwise.shiftRightZfBy 8 x), Bitwise.and 0xFF x ]) digest


hex : List Int -> String
hex digest =
    let
        digit d =
            String.slice d (d + 1) "0123456789abcdef"

        word x =
            List.range 0 7 |> List.map (\i -> digit (Bitwise.and 15 (Bitwise.shiftRightZfBy (28 - 4 * i) x))) |> String.concat
    in
    String.concat (List.map word digest)


ascii : String -> List Int
ascii text =
    List.map Char.toCode (String.toList text)


{-| `hash "abc"`, then the hash of each digest, `n` digests in all.
-}
chain : Int -> String
chain n =
    let
        go i digest =
            if i <= 1 then
                digest

            else
                go (i - 1) (hash (toBytes digest))
    in
    hex (go n (hash (ascii "abc")))


{-| The chain's last digest, in hex.
-}
output : Int -> String
output n =
    chain n ++ "\n"


{-| The last digest of chains of known lengths, from Python's `hashlib`.
-}
known : List ( Int, String )
known =
    [ ( 1000, "fc8a6b86a13f71cd9a67f558ab6fd82a3dd89186163a017ed8051acf6d3f8f99" )
    , ( 5000, "4d9863351151aa67a08a6b9c4eeb28ef7b1e802b969ed2d3127dd947121b3f4f" )
    ]


vectors : Bool
vectors =
    hex (hash (ascii "abc"))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        && hex (hash (ascii "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
        == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"


bench : Int -> Bool
bench n =
    let
        last =
            chain n

        matchesKnown =
            case List.filter (\( size, _ ) -> size == n) known of
                ( _, expected ) :: _ ->
                    last == expected

                [] ->
                    True
    in
    vectors && String.length last == 64 && matchesKnown
