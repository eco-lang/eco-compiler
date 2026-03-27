module TailRecNestedStringCaseTest exposing (main)

{-| Test that tail-recursive functions containing case expressions with
nested string pattern matching compile and run correctly.

Regression test for: eco.case with nested string cases inside scf.while
not being lowered by either SCF or CF passes.

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
