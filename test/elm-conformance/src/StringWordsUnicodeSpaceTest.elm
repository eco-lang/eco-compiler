module StringWordsUnicodeSpaceTest exposing (main)

{-| DEAD-10 guard (plans/kernel-lib-bug-fixes.md, group 01). `String.words` on strings whose
whitespace is non-ASCII (U+00A0, U+3000), which takes the kernel's UTF-16 branch. DEAD-10 says the
`if (ranges.empty()) return alloc::listNil();` lines in `words` are unreachable: an empty or
all-whitespace string has already returned [""], and a trimmed non-empty string has a word. These
cases sit next to that branch (whitespace around and between words, whitespace only), so the
assert the fix puts there would fire on them if the reasoning were wrong. Passes today (the branch
is unreachable, so nothing can expose it). Expectations recorded from Elm (JS `\s` includes both
characters).
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
