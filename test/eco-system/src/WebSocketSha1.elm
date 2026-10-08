module WebSocketSha1 exposing (acceptFor)

{-| `Sec-WebSocket-Accept` in pure Elm (SHA-1 and base64), for the raw test servers of the
WebSocket tests (not a test: no `main`). Written for 32-bit (JS) and 64-bit (native) `Bitwise`
alike: every intermediate value is brought back to an unsigned 32-bit number.
-}

import Array exposing (Array)
import Bitwise exposing (and, or, shiftLeftBy, shiftRightZfBy)


acceptFor : String -> String
acceptFor key =
    base64 (sha1 (List.map Char.toCode (String.toList (key ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))))


u32 : Int -> Int
u32 x =
    shiftRightZfBy 0 (and x 0xFFFFFFFF)


add : Int -> Int -> Int
add a b =
    u32 (u32 a + u32 b)


rotl : Int -> Int -> Int
rotl n x =
    u32 (or (shiftLeftBy n x) (shiftRightZfBy (32 - n) (u32 x)))


not32 : Int -> Int
not32 x =
    u32 (bxor x 0xFFFFFFFF)


{-| SHA-1 of ASCII bytes (the message is short: no streaming).
-}
sha1 : List Int -> List Int
sha1 bytes =
    let
        len =
            List.length bytes

        padLen =
            modBy 64 (55 - len)

        bitLen =
            len * 8

        padded =
            bytes ++ [ 0x80 ] ++ List.repeat padLen 0 ++ [ 0, 0, 0, 0 ] ++ be32 bitLen

        blocks =
            chunks 64 padded

        ( h0, ( h1, h2 ), ( h3, h4 ) ) =
            List.foldl block ( 0x67452301, ( 0xEFCDAB89, 0x98BADCFE ), ( 0x10325476, 0xC3D2E1F0 ) ) blocks
    in
    List.concatMap be32 [ h0, h1, h2, h3, h4 ]


be32 : Int -> List Int
be32 x =
    [ and (shiftRightZfBy 24 x) 0xFF, and (shiftRightZfBy 16 x) 0xFF, and (shiftRightZfBy 8 x) 0xFF, and x 0xFF ]


chunks : Int -> List a -> List (List a)
chunks n list =
    if List.isEmpty list then
        []

    else
        List.take n list :: chunks n (List.drop n list)


block : List Int -> ( Int, ( Int, Int ), ( Int, Int ) ) -> ( Int, ( Int, Int ), ( Int, Int ) )
block bytes ( h0, ( h1, h2 ), ( h3, h4 ) ) =
    let
        w16 =
            chunks 4 bytes |> List.map (List.foldl (\b acc -> u32 (acc * 256 + b)) 0)

        w =
            List.foldl
                (\i arr ->
                    let
                        at k =
                            Array.get k arr |> Maybe.withDefault 0
                    in
                    Array.push (rotl 1 (u32 (bxor (bxor (at (i - 3)) (at (i - 8))) (bxor (at (i - 14)) (at (i - 16)))))) arr
                )
                (Array.fromList w16)
                (List.range 16 79)

        round i ( a, ( b, c ), ( d, e ) ) =
            let
                ( f, k ) =
                    if i < 20 then
                        ( u32 (or (and b c) (and (not32 b) d)), 0x5A827999 )

                    else if i < 40 then
                        ( u32 (bxor (bxor b c) d), 0x6ED9EBA1 )

                    else if i < 60 then
                        ( u32 (or (or (and b c) (and b d)) (and c d)), 0x8F1BBCDC )

                    else
                        ( u32 (bxor (bxor b c) d), 0xCA62C1D6 )

                temp =
                    add (add (add (rotl 5 a) f) (add e k)) (Array.get i w |> Maybe.withDefault 0)
            in
            ( temp, ( a, rotl 30 b ), ( c, d ) )

        ( a2, ( b2, c2 ), ( d2, e2 ) ) =
            List.foldl round ( h0, ( h1, h2 ), ( h3, h4 ) ) (List.range 0 79)
    in
    ( add h0 a2, ( add h1 b2, add h2 c2 ), ( add h3 d2, add h4 e2 ) )


alphabet : Array Char
alphabet =
    Array.fromList (String.toList "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")


base64 : List Int -> String
base64 bytes =
    let
        char n =
            Array.get n alphabet |> Maybe.withDefault '='

        group g =
            case g of
                [ a, b, c ] ->
                    let
                        n =
                            a * 65536 + b * 256 + c
                    in
                    [ char (n // 262144), char (modBy 64 (n // 4096)), char (modBy 64 (n // 64)), char (modBy 64 n) ]

                [ a, b ] ->
                    let
                        n =
                            a * 65536 + b * 256
                    in
                    [ char (n // 262144), char (modBy 64 (n // 4096)), char (modBy 64 (n // 64)), '=' ]

                [ a ] ->
                    let
                        n =
                            a * 65536
                    in
                    [ char (n // 262144), char (modBy 64 (n // 4096)), '=', '=' ]

                _ ->
                    []
    in
    chunks 3 bytes |> List.concatMap group |> String.fromList


bxor : Int -> Int -> Int
bxor =
    Bitwise.xor
