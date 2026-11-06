module LocalRecCaptureSplitParamTest exposing (main)

{-| A let-bound recursive function reads a tuple parameter of the tail-recursive
function that encloses it.

`outer2` and `outer3` each call themselves with an updated pair until `n`
reaches 0, then define a local `loop` that counts to 3 and adds both
components of the pair. `outer2` reads them with `Tuple.first` and
`Tuple.second`; `outer3` destructures the pair with `case` inside `loop`.
From `( 0, 0 )` with n = 2 the pair becomes `( 2, 4 )`, so each prints
3 + 2 + 4 = 9.
-}

-- CHECK: o2: 9
-- CHECK: o3: 9

import Html exposing (text)


outer2 : ( Int, Int ) -> Int -> Int
outer2 pair n =
    if n <= 0 then
        let
            loop i =
                if i >= 3 then
                    i + Tuple.first pair + Tuple.second pair

                else
                    loop (i + 1)
        in
        loop 0

    else
        case pair of
            ( x, y ) ->
                outer2 ( x + 1, y + 2 ) (n - 1)


outer3 : ( Int, Int ) -> Int -> Int
outer3 pair n =
    if n <= 0 then
        let
            loop i =
                case pair of
                    ( p, q ) ->
                        if i >= 3 then
                            i + p + q

                        else
                            loop (i + 1)
        in
        loop 0

    else
        case pair of
            ( x, y ) ->
                outer3 ( x + 1, y + 2 ) (n - 1)


main =
    let
        _ =
            Debug.log "o2" (outer2 ( 0, 0 ) 2)

        _ =
            Debug.log "o3" (outer3 ( 0, 0 ) 2)
    in
    text "done"
