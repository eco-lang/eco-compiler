module ParserAdvancedLoopTest exposing (main)

{-| `Parser.Advanced.loop` repeats a step until it returns `Done`, threading its accumulated state through each step.

Each step either parses an integer, followed by an optional comma, and loops
with the integer added to the front of the list, or, when no integer
follows, finishes with the list so far. Run on `"1,2,3"`, the result is
`Ok [3,2,1]`: the list is built by prepending and is not reversed.
-}

-- CHECK: items: Ok [3,2,1]

import Html exposing (text)
import Parser.Advanced as PA exposing ((|.), (|=))


type Ctx
    = ListCtx


type Prob
    = ExpectedInt
    | ExpectedComma


{-| Parses integers separated by commas, returning them in reverse order of appearance.
-}
loopInts : PA.Parser Ctx Prob (List Int)
loopInts =
    PA.loop []
        (\acc ->
            PA.oneOf
                [ PA.succeed (\n -> PA.Loop (n :: acc))
                    |= PA.int ExpectedInt ExpectedInt
                    |. PA.oneOf
                        [ PA.symbol (PA.Token "," ExpectedComma)
                        , PA.succeed ()
                        ]
                , PA.succeed (PA.Done acc)
                ]
        )


main =
    let
        result = PA.run loopInts "1,2,3"
        _ = Debug.log "items" result
    in
    text "done"
