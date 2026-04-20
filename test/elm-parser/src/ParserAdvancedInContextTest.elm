module ParserAdvancedInContextTest exposing (main)

-- CHECK: failed_with_context: True

import Html exposing (text)
import List
import Parser.Advanced as PA


type Context
    = Definition String


type Prob
    = ExpectedChar


p : PA.Parser Context Prob ()
p =
    PA.inContext (Definition "top")
        (PA.chompIf (\_ -> False) ExpectedChar)


main =
    let
        result = PA.run p "abc"
        hasContext =
            case result of
                Err (de :: _) ->
                    List.length de.contextStack > 0

                _ ->
                    False
        _ = Debug.log "failed_with_context" hasContext
    in
    text "done"
