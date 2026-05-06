module EscapeCustomCaseScrutineeTest exposing (main)

{-| Phase 2 negative: a Custom value flowing into a case scrutinee
(the only way to deconstruct a custom in Elm source) counts as
escaping under the conservative classifier. eco.make.custom
rewriting is suppressed; behaviour must match the heap path.
-}

-- CHECK: just: 7
-- CHECK: nothing: 0


import Html exposing (text)


type Maybe2
    = Just2 Int
    | Nothing2


unwrap : Maybe2 -> Int
unwrap m =
    case m of
        Just2 x ->
            x

        Nothing2 ->
            0


main =
    let
        _ =
            Debug.log "just" (unwrap (Just2 7))

        _ =
            Debug.log "nothing" (unwrap Nothing2)
    in
    text "done"
