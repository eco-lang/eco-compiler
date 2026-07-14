module CharCaptureEscapedTailDefTest exposing (main)

{-| Regression: a local tail-recursive def that captures a raw Char (i16)
and ESCAPES as a value (stored in a list, extracted, then applied). The
reified loop shell's capture ABI must agree with its papCreate site —
`mlirTypeToApproxMonoType` used to type I16 captures as boxed (stale
pre-i16-Char `I32 -> MChar` arm), so the outlined `$cap` said `!eco.value`
while the creation site passed i16 with unboxed_bitmap=3, tripping
"Calling a function with a bad signature" at LLVM translation.
-}

import Html exposing (text)

-- CHECK: hit: True
-- CHECK: miss: False
-- CHECK: both: True


pickers : Char -> List (List Char -> Bool)
pickers c =
    let
        go xs =
            case xs of
                [] ->
                    False

                y :: rest ->
                    if y == c then
                        True

                    else
                        go rest
    in
    [ go ]


runFirst : List (List Char -> Bool) -> List Char -> Bool
runFirst fs xs =
    case fs of
        f :: _ ->
            f xs

        [] ->
            False


main =
    let
        _ =
            Debug.log "hit" (runFirst (pickers 'x') [ 'a', 'b', 'x' ])

        _ =
            Debug.log "miss" (runFirst (pickers 'q') [ 'a', 'b', 'x' ])

        _ =
            Debug.log "both" (List.all (\f -> f [ 'z' ]) (pickers 'z'))
    in
    text "done"
