module Prng exposing (bench)

{-| Pseudo-random number generators in a tight loop, pure `Bitwise`: Marsaglia's xorshift32
(shifts 13, 17, 5, from 2463534242) and xorshift128 (`xor128`, from his 2003 paper's four seeds),
`n` steps of each, summing the outputs.

Written to give the same results whether `Bitwise` works on 32 bits (elm/core) or 64 (eco's
native backend): every state word is kept in `0 .. 2^32 - 1` with `modBy 2^32` after each left
shift and `xor`. Every run checks the generators' published first outputs (723471715 and
3701687786), and at the sizes in `known` the final states and output sums must match a Python
implementation.

-}

import Bitwise


wrap : Int -> Int
wrap x =
    modBy 4294967296 x


xorshift32 : Int -> Int
xorshift32 x0 =
    let
        x1 =
            wrap (Bitwise.xor x0 (wrap (Bitwise.shiftLeftBy 13 x0)))

        x2 =
            wrap (Bitwise.xor x1 (Bitwise.shiftRightZfBy 17 x1))
    in
    wrap (Bitwise.xor x2 (wrap (Bitwise.shiftLeftBy 5 x2)))


type alias State128 =
    { a : Int, b : Int, c : Int, d : Int }


xor128 : State128 -> State128
xor128 s =
    let
        t =
            wrap (Bitwise.xor s.a (wrap (Bitwise.shiftLeftBy 11 s.a)))

        d =
            wrap (Bitwise.xor (Bitwise.xor s.d (Bitwise.shiftRightZfBy 19 s.d)) (Bitwise.xor t (Bitwise.shiftRightZfBy 8 t)))
    in
    State128 s.b s.c s.d d


{-| `( xorshift32 state, its output sum, xor128's last output, its output sum )` after `n`
steps, the sums modulo 1000000007.
-}
run : Int -> ( ( Int, Int ), ( Int, Int ) )
run n =
    let
        go i x s32 st s128 =
            if i <= 0 then
                ( ( x, s32 ), ( st.d, s128 ) )

            else
                let
                    x2 =
                        xorshift32 x

                    st2 =
                        xor128 st
                in
                go (i - 1) x2 (modBy 1000000007 (s32 + x2)) st2 (modBy 1000000007 (s128 + st2.d))
    in
    go n 2463534242 0 (State128 123456789 362436069 521288629 88675123) 0


known : List ( Int, ( ( Int, Int ), ( Int, Int ) ) )
known =
    [ ( 1000, ( ( 3298996588, 975913910 ), ( 2542841595, 325947671 ) ) )
    , ( 1000000, ( ( 2318261108, 516635174 ), ( 4090088915, 93053397 ) ) )
    , ( 2000000, ( ( 2689770536, 794733678 ), ( 1690491644, 536750506 ) ) )
    , ( 3000000, ( ( 4186217900, 399500351 ), ( 123467432, 175547043 ) ) )
    ]


bench : Int -> Bool
bench n =
    let
        result =
            run n

        published =
            xorshift32 2463534242 == 723471715 && (xor128 (State128 123456789 362436069 521288629 88675123)).d == 3701687786

        matchesKnown =
            case List.filter (\( size, _ ) -> size == n) known of
                ( _, expected ) :: _ ->
                    result == expected

                [] ->
                    True
    in
    published && matchesKnown
