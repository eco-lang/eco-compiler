module ParserAdvancedSequenceTest exposing (main)

-- CHECK: list: Ok [1, 2, 3]

import Html exposing (text)
import Parser.Advanced as PA exposing (Trailing(..))


type Prob
    = ExpectedStart
    | ExpectedEnd
    | ExpectedSep
    | ExpectedInt


intList : PA.Parser c Prob (List Int)
intList =
    PA.sequence
        { start = PA.Token "[" ExpectedStart
        , separator = PA.Token "," ExpectedSep
        , end = PA.Token "]" ExpectedEnd
        , spaces = PA.spaces
        , item = PA.int ExpectedInt ExpectedInt
        , trailing = Forbidden
        }


main =
    let
        result = PA.run intList "[1,2,3]"
        _ = Debug.log "list" result
    in
    text "done"
