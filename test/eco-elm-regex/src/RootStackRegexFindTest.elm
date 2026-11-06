module RootStackRegexFindTest exposing (main)

{-| `Regex.find` returns every match when there are tens of thousands of them.

The input is the 70,000 numbers `"00000"` to `"69999"` joined with commas, and
the pattern `[0-9]+` matches each number once, so the list of matches has
length 70,000.

## eco

A GC shadow-root-stack pin for the bounded-rooting work (plans/kernel-root-stack-bounded-rooting.md). `Elm_Kernel_Regex_findAtMost` in
elm-kernel-cpp/src/regex/RegexExports.cpp once pushed one root record per match; 70,000 matches
is more than the 65,536 records the shadow stack holds.

-}

-- CHECK: matches: 70000

import Html exposing (text)
import Regex


{-| Formats `n` as a decimal number left-padded with zeros to five digits.
-}
pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| The 70,000 five-digit strings `"00000"` to `"69999"`, in order.
-}
strs : List String
strs =
    List.map pad (List.range 0 69999)


{-| The pattern `[0-9]+`, one or more decimal digits.
-}
digits : Regex.Regex
digits =
    Maybe.withDefault Regex.never (Regex.fromString "[0-9]+")


main =
    let
        _ =
            Debug.log "matches" (List.length (Regex.find digits (String.join "," strs)))

    in
    text "done"
