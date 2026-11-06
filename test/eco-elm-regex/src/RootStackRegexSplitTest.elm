module RootStackRegexSplitTest exposing (main)

{-| `Regex.split` returns every part when a string splits into tens of thousands of them.

The input is the 70,000 numbers `"00000"` to `"69999"` joined with commas.
Splitting on `,` cuts at the 69,999 commas, so the list of parts has length
70,000.

## eco

A GC shadow-root-stack pin for the bounded-rooting work (plans/kernel-root-stack-bounded-rooting.md). `Elm_Kernel_Regex_splitAtMost` in
elm-kernel-cpp/src/regex/RegexExports.cpp once pushed one root record per part; 70,000 parts is
more than the 65,536 records the shadow stack holds.

-}

-- CHECK: parts: 70000

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


{-| The pattern `,`, a single comma.
-}
comma : Regex.Regex
comma =
    Maybe.withDefault Regex.never (Regex.fromString ",")


main =
    let
        _ =
            Debug.log "parts" (List.length (Regex.split comma (String.join "," strs)))

    in
    text "done"
