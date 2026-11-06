module JsonEncodeLoneSurrogateTest exposing (main)

{-| `Json.Encode.encode` writes a lone UTF-16 surrogate in a string as a `\uXXXX` escape and leaves
a valid surrogate pair unescaped.

The emoji U+1F600 is built with `Char.fromCode`, and `String.left 1` of it is its lone high
surrogate.

  - `lone high` and `lone low`: a string holding only U+D83D or U+DC00 encodes as `"\ud83d"` or
    `"\udc00"`.
  - `lone key`: a lone surrogate in an object key is escaped the same way.
  - `pair intact`: the encoded emoji is 4 UTF-16 units long, the two quotes and the unescaped
    pair.
-}

-- CHECK: lone high: "\"\\ud83d\""
-- CHECK: lone low: "\"\\udc00\""
-- CHECK: lone key: "{\"\\ud83d\":1}"
-- CHECK: pair intact: "4"

import ConformanceHelp exposing (logAll, worker)
import Json.Encode as E


emoji : String
emoji =
    String.fromChar (Char.fromCode 0x0001F600)


report : ()
report =
    logAll
        [ ( "lone high", E.encode 0 (E.string (String.left 1 emoji)) )
        , ( "lone low", E.encode 0 (E.string (String.fromChar (Char.fromCode 0xDC00))) )
        , ( "lone key", E.encode 0 (E.object [ ( String.left 1 emoji, E.int 1 ) ]) )
        , ( "pair intact", String.fromInt (String.length (E.encode 0 (E.string emoji))) )
        ]


main : Program () () ()
main =
    worker report
