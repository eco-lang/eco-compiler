module ParserIssue24GetIndentDefaultTest exposing (main)

{-| `getIndent` without any `withIndent` returns 1, not the documented default 0.

<https://github.com/elm/parser/issues/24>

The documentation says "`getIndent` results in `0`, the default value" and that
`succeed Tuple.pair |= withIndent 4 getIndent |= getIndent` gives `(4,0)`. Elm 0.19.1
(elm/parser 1.1.0) gives 1 and `(4,1)`.

-}

-- CHECK: indent: Ok 0
-- CHECK: pair: Ok (4,0)

import Html exposing (text)
import Parser exposing ((|=))


main =
    let
        _ =
            Debug.log "indent" (Parser.run Parser.getIndent "")

        _ =
            Debug.log "pair"
                (Parser.run
                    (Parser.succeed Tuple.pair
                        |= Parser.withIndent 4 Parser.getIndent
                        |= Parser.getIndent
                    )
                    ""
                )
    in
    text "done"
