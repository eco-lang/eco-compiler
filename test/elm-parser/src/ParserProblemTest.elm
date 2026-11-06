module ParserProblemTest exposing (main)

{-| Checks that `Parser.problem` makes a parse fail and that `Parser.deadEndsToString` renders the failure.

The parser matches `"a"` and then fails with a custom problem. The test checks
that the result is an `Err` and that the rendered dead ends are a non-empty
string; it does not check the text.
-}

-- CHECK: has_problem: True
-- CHECK: render_nonempty: True

import Html exposing (text)
import Parser exposing ((|.))
import String


p : Parser.Parser ()
p =
    Parser.succeed ()
        |. Parser.symbol "a"
        |. Parser.problem "intentional failure"


main =
    let
        result = Parser.run p "a"
        _ = Debug.log "has_problem"
            (case result of
                Err _ -> True
                Ok _ -> False
            )
        msg =
            case result of
                Err deadEnds -> Parser.deadEndsToString deadEnds
                Ok _ -> ""
        _ = Debug.log "render_nonempty" (String.length msg > 0)
    in
    text "done"
