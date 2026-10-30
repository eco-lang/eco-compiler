module CharAstralRoundTripTest exposing (main)

{-| A Char is a Unicode code point in i32 (CGEN_015), so `Char.fromCode` and
`Char.toCode` round-trip every code point, including the astral ones
(0x1F600) and the last one (0x10FFFF), and an astral Char survives being
boxed (an `ElmChar` with a u32 value) behind a type variable (`Maybe Char`,
a polymorphic identity) and Char equality and ordering. The ordering checks
avoid U+E000..U+FFFF against an astral Char, the one range where Eco's
code-point order differs from Elm's JS (UTF-16 string) order. The lone
surrogate 0xD83D round-trips as its own value in Eco; Elm's JS `toCode` reads
past it and gives NaN (documented divergence, StringLoneSurrogateTest).
-}

-- CHECK: rt_emoji: 128512
-- CHECK: rt_max: 1114111
-- CHECK: rt_list: [128512,1114111,65536,65535,55357,0]
-- CHECK: boxed_maybe: Just 128512
-- CHECK: boxed_identity: 128512
-- CHECK: eq_astral: True
-- CHECK: neq_astral: True
-- CHECK: lt_astral: True
-- CHECK: compare_astral: GT


import Char
import Html exposing (text)


polyId : a -> a
polyId x =
    x


main =
    let
        codes =
            [ 0x0001F600, 0x0010FFFF, 0x00010000, 0xFFFF, 0xD83D, 0 ]

        emoji =
            Char.fromCode 0x0001F600

        _ =
            Debug.log "rt_emoji" (Char.toCode (Char.fromCode 0x0001F600))

        _ =
            Debug.log "rt_max" (Char.toCode (Char.fromCode 0x0010FFFF))

        _ =
            Debug.log "rt_list" (List.map (Char.fromCode >> Char.toCode) codes)

        _ =
            Debug.log "boxed_maybe" (Maybe.map Char.toCode (Just emoji))

        _ =
            Debug.log "boxed_identity" (Char.toCode (polyId emoji))

        _ =
            Debug.log "eq_astral" (emoji == '😀')

        _ =
            Debug.log "neq_astral" (emoji /= Char.fromCode 0xF600)

        _ =
            Debug.log "lt_astral" (Char.fromCode 0x20AC < emoji)

        _ =
            Debug.log "compare_astral" (compare (Char.fromCode 0x0001F601) emoji)
    in
    text "done"
