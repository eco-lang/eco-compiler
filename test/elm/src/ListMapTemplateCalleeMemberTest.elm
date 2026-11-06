module ListMapTemplateCalleeMemberTest exposing (main)

{-| Checks `List.map` with a callback that applies a function received as a
parameter, here a lambda bound to a typed `let` name in `main`.

`helper` maps `\x -> f x` over its list, and `main` passes it `inc`, which adds
one, so `[1, 2, 3]` maps to `[2, 3, 4]`.

-}

-- CHECK: mapped: [2,3,4]

import Html exposing (text)


helper : (Int -> Int) -> List Int -> List Int
helper f xs =
    List.map (\x -> f x) xs


main : Html.Html msg
main =
    let
        inc : Int -> Int
        inc =
            \y -> y + 1

        mapped =
            helper inc [ 1, 2, 3 ]

        _ =
            Debug.log "mapped" mapped
    in
    text "done"
