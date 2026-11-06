module StringWordsUnicodeSpaceTest exposing (main)

{-| `String.words` splits on non-ASCII whitespace (U+00A0, U+3000, U+2028) and gives `[""]` for a
string that is only whitespace.

The inputs have whitespace around one word, between two words, around and between two words,
and as the whole string.

-}

-- CHECK: nbsp around: ["a"]
-- CHECK: nbsp between: ["a","b"]
-- CHECK: ideographic only: [""]
-- CHECK: mixed only: [""]
-- CHECK: mixed around two: ["x","y"]


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "nbsp around" (String.words "\u{00A0}a\u{3000}")

                    _ =
                        Debug.log "nbsp between" (String.words "a\u{00A0}b")

                    _ =
                        Debug.log "ideographic only" (String.words "\u{3000}")

                    _ =
                        Debug.log "mixed only" (String.words " \u{00A0}\t\u{3000}\n")

                    _ =
                        Debug.log "mixed around two" (String.words "\u{3000} x\u{00A0}\u{00A0}y \u{2028}")
                in
                ( (), Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
