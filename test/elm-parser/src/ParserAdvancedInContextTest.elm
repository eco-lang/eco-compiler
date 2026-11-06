module ParserAdvancedInContextTest exposing (main)

{-| `Parser.Advanced.inContext` records its context on the dead ends of a parser that fails inside it.

The inner parser is a `chompIf` whose predicate rejects every character, so
running it on `"abc"` fails. The test checks that the first dead end's
`contextStack` is not empty.

Among what is not tested: which context the stack holds, its position, and
nested contexts.
-}

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
