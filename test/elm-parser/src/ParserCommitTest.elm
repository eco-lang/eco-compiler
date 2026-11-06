module ParserCommitTest exposing (main)

{-| `Parser.oneOf` does not try a later alternative once an earlier one has consumed input and committed.

The first alternative parses `"a"`, calls `commit`, then expects `"b"`; the
second parses `"a"` alone. Run on `"ax"`, the first alternative fails at
`"x"` and the result is `Err`, not `Ok 1` from the second.

Having parsed `"a"`, the first alternative has already consumed input, so the
test does not separate the effect of `commit` from that of consuming.
-}

-- CHECK: committed: True

import Html exposing (text)
import Parser exposing ((|.))


{-| Returns 0 for `"ab"`, committing after the `"a"`, or 1 for `"a"` alone.
-}
p : Parser.Parser Int
p =
    Parser.oneOf
        [ Parser.succeed 0
            |. Parser.symbol "a"
            |. Parser.commit ()
            |. Parser.symbol "b"
        , Parser.succeed 1 |. Parser.symbol "a"
        ]


main =
    let
        result = Parser.run p "ax"
        _ = Debug.log "committed"
            (case result of
                Err _ -> True
                Ok _ -> False
            )
    in
    text "done"
