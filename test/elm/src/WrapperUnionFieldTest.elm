module WrapperUnionFieldTest exposing (main)

{-| Test wrapper type holding a record with a union field. -}

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
