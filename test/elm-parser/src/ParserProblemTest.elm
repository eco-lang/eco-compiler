module ParserProblemTest exposing (main)

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
