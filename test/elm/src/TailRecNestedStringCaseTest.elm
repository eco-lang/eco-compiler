module TailRecNestedStringCaseTest exposing (main)

{-| A self-recursive function whose non-recursive branch matches a `String` against literal patterns returns the matched value after unwrapping several layers.

`process` calls itself in tail position through two `Wrapper` layers and then
maps the leaf name `"answer"` to 42.
-}

-- CHECK: result: 42

import Html exposing (text)


type MyType
    = Leaf String
    | Wrapper MyType


process : MyType -> Int
process tipe =
    case tipe of
        Wrapper inner ->
            process inner

        Leaf name ->
            case name of
                "answer" ->
                    42

                "zero" ->
                    0

                _ ->
                    -1


main =
    let
        val =
            process (Wrapper (Wrapper (Leaf "answer")))

        _ =
            Debug.log "result" val
    in
    text "done"
