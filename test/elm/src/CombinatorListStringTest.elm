module CombinatorListStringTest exposing (main)

{-| Test SKI-style combinators with lists, strings, and stdlib functions.
-}

-- CHECK: b_sum_map: 9
-- CHECK: sp_mul: 84
-- CHECK: w_concat: hihi
-- CHECK: c_cons: [1,2,3]
-- CHECK: s_palindrome: strawwarts
-- CHECK: t_pipe: 12
-- CHECK: p_lengths: 5

import Html exposing (text)


k a _ = a

s bf uf x = bf x (uf x)

i = s k k

b = s (k s) k

c = s (b b s) (k k)

sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)

t = c i

w bf x = bf x x

p bf uf x y = bf (uf x) (uf y)


main =
    let
        _ = Debug.log "b_sum_map" (b List.sum (List.map ((+) 1)) [ 1, 2, 3 ])
        _ = Debug.log "sp_mul" (sp (*) ((+) 1) ((*) 2) 6)
        _ = Debug.log "w_concat" (w (++) "hi")
        _ = Debug.log "c_cons" (c (::) [ 2, 3 ] 1)
        _ = Debug.log "s_palindrome" (s (++) String.reverse "straw")
        _ = Debug.log "t_pipe" (t [ 1, 2, 3 ] (b List.sum (List.map ((*) 2))))
        _ = Debug.log "p_lengths" (p (+) List.length [ 1, 2, 3 ] [ 4, 5 ])
    in
    text "done"
