module CombinatorTest exposing (main)

{-| Test SKI-style combinators built from S and K.
-}

-- CHECK: b_compose: 25
-- CHECK: c_flip: -7
-- CHECK: s_feed: 15
-- CHECK: sp_combine: 84
-- CHECK: w_dup: 81
-- CHECK: t_thrush: 21
-- CHECK: i_identity: 42

import Html exposing (text)


-- Combinators

k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)

sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)

t = c i

i = s k k

w bf x = bf x x


-- Helpers

inc x = x + 1
double x = x * 2
square x = x * x
sub x y = x - y
mul x y = x * y


main =
    let
        _ = Debug.log "b_compose" (b square inc 4)
        _ = Debug.log "c_flip" (c sub 10 3)
        _ = Debug.log "s_feed" (s (+) double 5)
        _ = Debug.log "sp_combine" (sp mul inc double 6)
        _ = Debug.log "w_dup" (w mul 9)
        _ = Debug.log "t_thrush" (t 7 (\x -> x * 3))
        _ = Debug.log "i_identity" (i 42)
    in
    text "done"
