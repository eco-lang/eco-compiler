module IntNegativeZeroTest exposing (main)

{-| Integer results that are -0 in Elm. An Elm Int is a JavaScript number, so `remainderBy 4 -4`
(`-4 % 4`), `modBy 4 -4` (the same `%`, whose sign fix-up leaves a zero alone), `negate 0` and
`0 * -1` are all -0. It prints as `0` and equals `0`, so it shows only once converted to a Float
and divided by: `1 / toFloat n` is -Infinity. An eco Int is a 64-bit integer with a single zero,
so each is +Infinity. The operands come from `List.length` so that no compiler can fold them.

The CHECK lines are eco's output; the `-- ELM:` lines are what Elm 0.19.1 prints on node.

-}

-- DIVERGENCE: eco's Int has one zero; Elm's Int is a JS number, so these results are -0 and 1 / toFloat n is -Infinity
-- CHECK: remainderBy 4 -4: "0 Infinity"
-- CHECK: modBy 4 -4: "0 Infinity"
-- CHECK: negate 0: "0 Infinity"
-- CHECK: 0 * -1: "0 Infinity"
-- CHECK: equals 0: True
-- ELM: remainderBy 4 -4: "0 -Infinity"
-- ELM: modBy 4 -4: "0 -Infinity"
-- ELM: negate 0: "0 -Infinity"
-- ELM: 0 * -1: "0 -Infinity"
-- ELM: equals 0: True

import Html exposing (text)


{-| The Int as printed, and 1 divided by it as a Float, which tells -0 from 0.
-}
show : Int -> String
show n =
    String.fromInt n ++ " " ++ String.fromFloat (1 / toFloat n)


main =
    let
        four =
            List.length [ (), (), (), () ]

        zero =
            List.length []

        _ =
            Debug.log "remainderBy 4 -4" (show (remainderBy four (negate four)))

        _ =
            Debug.log "modBy 4 -4" (show (modBy four (negate four)))

        _ =
            Debug.log "negate 0" (show (negate zero))

        _ =
            Debug.log "0 * -1" (show (zero * negate 1))

        _ =
            Debug.log "equals 0" (remainderBy four (negate four) == 0)
    in
    text "done"
