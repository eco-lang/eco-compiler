module ParserAdvancedLoopTest exposing (main)

-- CHECK: items: Ok [3, 2, 1]

import Html exposing (text)
import Parser.Advanced as PA exposing ((|.), (|=))


type Ctx
    = ListCtx


type Prob
    = ExpectedInt
    | ExpectedComma


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
