module ParserVariableTest exposing (main)

-- CHECK: name: Ok "foo"
-- CHECK: reserved: True

import Char
import Html exposing (text)
import Parser
import Set


variable : Parser.Parser String
variable =
    Parser.variable
        { start = Char.isLower
        , inner = \c -> Char.isAlphaNum c || c == '_'
        , reserved = Set.fromList [ "if", "then", "else" ]
        }


main =
    let
        ok_ = Parser.run variable "foo"
        _ = Debug.log "name" ok_
        bad = Parser.run variable "if"
        _ = Debug.log "reserved"
            (case bad of
                Err _ -> True
                Ok _ -> False
            )
    in
    text "done"
