module NullableUserTypeTest exposing (main)

{-| Maybe-shaped user types (one constructor without fields, one with one
field) under `NullableMaybe` with user types
(plans/constructor-representation-levels.md N1b): the nullary constructor
declared first and declared second, with a record payload (made nullable) and
with a payload that has a nullary constructor (kept on the heap, decision D2).

-}

-- CHECK: first: [5,-1]
-- CHECK: second: [6,-1]
-- CHECK: enumPayload: ["Some Up","None"]
-- CHECK: show: [Present { x = 6 },Absent]
-- CHECK: eq: [True,False]

import Html exposing (text)


type Opt
    = None
    | Some { x : Int }


type Opt2
    = Present { x : Int }
    | Absent


type Dir
    = Up
    | Down


type OptDir
    = NoDir
    | SomeDir Dir


optX : Opt -> Int
optX o =
    case o of
        Some r ->
            r.x

        None ->
            -1


opt2X : Opt2 -> Int
opt2X o =
    case o of
        Present r ->
            r.x

        Absent ->
            -1


showDir : OptDir -> String
showDir o =
    case o of
        SomeDir Up ->
            "Some Up"

        SomeDir Down ->
            "Some Down"

        NoDir ->
            "None"


main =
    let
        _ =
            Debug.log "first" (List.map optX [ Some { x = 5 }, None ])

        _ =
            Debug.log "second" (List.map opt2X [ Present { x = 6 }, Absent ])

        _ =
            Debug.log "enumPayload" (List.map showDir [ SomeDir Up, NoDir ])

        _ =
            Debug.log "show" [ Present { x = 6 }, Absent ]

        _ =
            Debug.log "eq" [ Some { x = 1 } == Some { x = 1 }, Some { x = 1 } == None ]
    in
    text "done"
