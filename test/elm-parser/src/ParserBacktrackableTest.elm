module ParserBacktrackableTest exposing (main)

{-| `Parser.oneOf` moves on to its next alternative when a `Parser.backtrackable` alternative fails.

The first alternative expects the keyword `"letx"` inside `backtrackable`;
the second expects the keyword `"let"`. Run on `"let"`, the first fails and
the result is `Ok 1` from the second.

The failing keyword consumes no input, so `oneOf` would try the second
alternative here even without `backtrackable`. The test does not cover an
alternative that consumes input before failing.
-}

-- CHECK: result: Ok 1

import Html exposing (text)
import Parser exposing ((|.))


{-| Returns 0 for the keyword `"letx"`, tried with backtracking, or 1 for the keyword `"let"`.
-}
p : Parser.Parser Int
p =
    Parser.oneOf
        [ Parser.backtrackable (Parser.succeed 0 |. Parser.keyword "letx")
        , Parser.succeed 1 |. Parser.keyword "let"
        ]


main =
    let
        result = Parser.run p "let"
        _ = Debug.log "result" result
    in
    text "done"
