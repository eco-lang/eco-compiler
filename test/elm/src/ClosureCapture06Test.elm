module ClosureCapture06Test exposing (main)

{-| Test nested case destruct with flat multi-arg function.

This is the flat-form version of a nested destruct pattern (Pair containing
two Maybes). It compiles successfully but triggers a runtime error, which
should be investigated separately from the closure capture compilation bug.
-}

-- CHECK: both: "ab"
-- CHECK: one: "a"
-- CHECK: none: ""

import Html exposing (text)


type Pair a b
    = Pair a b


extractStrings : Pair (Maybe String) (Maybe String) -> Int -> String
extractStrings pair dummy =
    case pair of
        Pair ma mb ->
            let
                a =
                    case ma of
                        Just s ->
                            s

                        Nothing ->
                            ""

                b =
                    case mb of
                        Just s ->
                            s

                        Nothing ->
                            ""
            in
            a ++ b


main =
    let
        _ = Debug.log "both" (extractStrings (Pair (Just "a") (Just "b")) 0)
        _ = Debug.log "one" (extractStrings (Pair (Just "a") Nothing) 0)
        _ = Debug.log "none" (extractStrings (Pair Nothing Nothing) 0)
    in
    text "done"
