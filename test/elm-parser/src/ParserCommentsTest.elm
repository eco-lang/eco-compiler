module ParserCommentsTest exposing (main)

-- CHECK: line: True
-- CHECK: block: True
-- CHECK: nested: True

import Html exposing (text)
import Parser exposing (Nestable(..))


main =
    let
        r1 = Parser.run (Parser.lineComment "--") "-- comment here"
        _ = Debug.log "line"
            (case r1 of
                Ok _ -> True
                Err _ -> False
            )
        r2 = Parser.run (Parser.multiComment "{-" "-}" NotNestable) "{- block -}"
        _ = Debug.log "block"
            (case r2 of
                Ok _ -> True
                Err _ -> False
            )
        r3 = Parser.run (Parser.multiComment "{-" "-}" Nestable) "{- outer {- inner -} -}"
        _ = Debug.log "nested"
            (case r3 of
                Ok _ -> True
                Err _ -> False
            )
    in
    text "done"
