module CompilerIssue2268TcoClosureCaptureTest exposing (main)

{-| Tail-call optimization breaks closures that capture an argument of the looping function.

<https://github.com/elm/compiler/issues/2268>

The tail-recursive `tcoMakeLazy` is compiled to a `while` loop that reassigns its arguments; the
lambdas `\_ -> item` all capture the same JavaScript variable, so after the loop they all see its
last value. Elm 0.19.1 gives `[3,3,3]`; the correct result is `[3,2,1]`, the same as the
non-tail-recursive version.

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
