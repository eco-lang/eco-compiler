module ClosureCapture05Test exposing (main)

{-| A lambda returned from a function captures a custom-type value holding two
`Maybe String`s, and when called matches on it and then on each `Maybe` in turn.

The two strings are concatenated, with `Nothing` counting as the empty string,
so the three calls log `"ab"`, `"a"` and `""`.

-}

-- CHECK: both: "ab"
-- CHECK: one: "a"
-- CHECK: none: ""

import Html exposing (text)


type Pair a b
    = Pair a b


extractStrings : Pair (Maybe String) (Maybe String) -> (Int -> String)
extractStrings pair =
    \dummy ->
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
