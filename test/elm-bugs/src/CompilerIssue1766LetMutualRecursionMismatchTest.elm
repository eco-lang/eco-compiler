module CompilerIssue1766LetMutualRecursionMismatchTest exposing (..)

{-| Mutually recursive let functions give a type a false "mismatch" with itself.

<https://github.com/elm/compiler/issues/1766>

Elm 0.19.1 rejects this program, saying `SearchResult state` does not match
`SearchResult state`. The program is well-typed and should compile.

-}

-- CHECK: result: Goal

import Html exposing (text)


type SearchResult state
    = Complete
    | Goal


iterativeSearch : SearchResult state
iterativeSearch =
    let
        iteration count =
            evaluate count Goal

        evaluate count result =
            case result of
                Complete ->
                    iteration (count + 1)

                Goal ->
                    Goal
    in
    iteration 0


iterativeCostIncreasing : SearchResult state
iterativeCostIncreasing =
    iterativeSearch


main =
    let
        _ =
            Debug.log "result" iterativeCostIncreasing
    in
    text "done"
