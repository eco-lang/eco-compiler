module ParserChompIfTest exposing (main)

-- CHECK: digit_ok: True
-- CHECK: alpha_fail: True

import Char
import Html exposing (text)
import Parser


digitP : Parser.Parser ()
digitP =
    Parser.chompIf Char.isDigit


main =
    let
        ok_ = Parser.run digitP "5"
        _ = Debug.log "digit_ok"
            (case ok_ of
                Ok _ -> True
                Err _ -> False
            )
        bad = Parser.run digitP "a"
        _ = Debug.log "alpha_fail"
            (case bad of
                Err _ -> True
                Ok _ -> False
            )
    in
    text "done"
