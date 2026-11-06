module ParserAdvancedSequenceTest exposing (main)

{-| `Parser.Advanced.sequence` parses a bracketed, comma-separated list of integers.

The sequence starts with `"["`, ends with `"]"`, separates items with `","`,
allows `spaces` around them and forbids a trailing separator. Run on
`"[1,2,3]"`, it returns `Ok [1,2,3]`, the items in input order.

Among what is not tested: whitespace inside the brackets, an empty list, and
the `Optional` and `Mandatory` trailing modes.
-}

-- CHECK: list: Ok [1,2,3]

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
