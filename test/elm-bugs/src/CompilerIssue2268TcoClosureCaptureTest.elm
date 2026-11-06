module CompilerIssue2268TcoClosureCaptureTest exposing (main)

{-| Lambdas created inside a tail-recursive function each keep the argument value they were created with.

<https://github.com/elm/compiler/issues/2268>

`tcoMakeLazy` walks `[ 1, 2, 3 ]` and prepends `\_ -> item` to an accumulator, so forcing the
result gives `[3,2,1]`. `makeLazy` is the same function with its recursive call written using
`<|`; both must print `[3,2,1]`. Elm 0.19.1 turns the tail call in `tcoMakeLazy` into a loop that
reassigns `item`, every lambda sees its last value, and the `tco` line prints `[3,3,3]`.

-}

-- CHECK: plain: [3,2,1]
-- CHECK: tco: [3,2,1]

import Html exposing (text)


makeLazy : List a -> List (() -> a) -> List (() -> a)
makeLazy list accum =
    case list of
        item :: items ->
            makeLazy items <| ((\_ -> item) :: accum)

        _ ->
            accum


tcoMakeLazy : List a -> List (() -> a) -> List (() -> a)
tcoMakeLazy list accum =
    case list of
        item :: items ->
            tcoMakeLazy items ((\_ -> item) :: accum)

        _ ->
            accum


main =
    let
        _ =
            Debug.log "plain" (makeLazy [ 1, 2, 3 ] [] |> List.map (\f -> f ()))

        _ =
            Debug.log "tco" (tcoMakeLazy [ 1, 2, 3 ] [] |> List.map (\f -> f ()))
    in
    text "done"
