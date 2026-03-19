module AccessorVariableTest exposing (main)

{-| Test accessor function stored in a variable and used on different record types. -}

-- CHECK: via_var: 42
-- CHECK: mapped: [10, 20, 30]
-- CHECK: person_name: "Alice"
-- CHECK: company_name: "ACME"

import Html exposing (text)


main =
    let
        accessor = .value
        item = { value = 42, label = "test" }
        _ = Debug.log "via_var" (accessor item)
        items = [ { value = 10 }, { value = 20 }, { value = 30 } ]
        _ = Debug.log "mapped" (List.map .value items)
        persons = [ { name = "Alice", age = 30 } ]
        companies = [ { name = "ACME", employees = 100 } ]
        personName =
            case List.head (List.map .name persons) of
                Just n ->
                    n

                Nothing ->
                    "none"
        companyName =
            case List.head (List.map .name companies) of
                Just n ->
                    n

                Nothing ->
                    "none"
        _ = Debug.log "person_name" personName
        _ = Debug.log "company_name" companyName
    in
    text "done"
