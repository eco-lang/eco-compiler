module ClosureCapture05Test exposing (main)

{-| Test closure captures variable used in nested case destruct.

Uses explicit lambda return to force nested Function nodes.
The captured variable `pair` is a custom type containing two Maybes.
The inner lambda destructs `pair` and then further destructs the
extracted Maybe values.
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
