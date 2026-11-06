module WrapperUnionFieldTest exposing (main)

{-| A single-constructor custom type can wrap a record whose field is itself a
custom type, and a nested `case` reads the payload of that field.

`getTag (Error { tag = B 7, count = 1 })` returns 7.

-}

-- CHECK: result: 7

import Html exposing (text)


type Kind
    = A
    | B Int


type Error
    = Error { tag : Kind, count : Int }


getTag : Error -> Int
getTag e =
    case e of
        Error props ->
            case props.tag of
                A ->
                    0

                B n ->
                    n


main =
    let
        _ =
            Debug.log "result" (getTag (Error { tag = B 7, count = 1 }))
    in
    text "done"
