module ParserCommentsTest exposing (main)

{-| `Parser.lineComment` and `Parser.multiComment` succeed on line, block and nested block comments.

The block-comment tests use Elm's own block-comment delimiters as the open
and close strings.

- `line`: `lineComment "--"` on `"-- comment here"`, with no newline.
- `block`: `multiComment` with `NotNestable` on a single block comment.
- `nested`: `multiComment` with `Nestable` on a block comment that contains
  another.

Each checks only that the run returns `Ok`. No parser ends with `end`, so the
tests do not show how much input was chomped; in particular `nested` would
also succeed if the comment stopped at the first closing delimiter.
-}

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
