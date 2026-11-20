module EraseWrapperBasicTest exposing (main)

{-| Values of single-constructor, single-field ("wrapper") types built,
unwrapped and passed around in the ways `EraseWrappers`
(plans/constructor-representation-levels.md E1a) rewrites: a saturated
constructor call, the constructor as a first-class function (`List.map Name`),
unwrapping in a function parameter, in a `let` and in a `case`, a wrapper
returned from a function that is not inlined, a wrapper inside a record, a
tuple, a `Maybe` and a list, and `==` on wrapped values.

-}

-- CHECK: names: ["ada","bob"]
-- CHECK: greet: "hello ada"
-- CHECK: lengths: [3,3]
-- CHECK: total: 6
-- CHECK: rec: "bob"
-- CHECK: pair: "ada-bob"
-- CHECK: maybe: "ada"
-- CHECK: eq: True
-- CHECK: neq: True
-- CHECK: folded: "abc"

import Html exposing (text)


type Name
    = Name String


type Score
    = Score (List Int)


unName : Name -> String
unName (Name s) =
    s


greet : Name -> String
greet name =
    let
        (Name s) =
            name
    in
    "hello " ++ s


makeName : Int -> String -> Name
makeName n s =
    if n > 100 then
        makeName (n - 1) s

    else
        Name (String.toLower s)


scoreTotal : Score -> Int
scoreTotal score =
    case score of
        Score xs ->
            List.sum xs


type alias Rec =
    { who : Name, n : Int }


append : Name -> Name -> Name
append (Name a) (Name b) =
    Name (a ++ b)


main =
    let
        names =
            List.map Name [ "ada", "bob" ]

        _ =
            Debug.log "names" (List.map unName names)

        _ =
            Debug.log "greet" (greet (makeName 1 "ADA"))

        _ =
            Debug.log "lengths" (List.map (unName >> String.length) names)

        _ =
            Debug.log "total" (scoreTotal (Score [ 1, 2, 3 ]))

        rec =
            { who = Name "bob", n = 1 }

        _ =
            Debug.log "rec" (unName rec.who)

        ( Name a, Name b ) =
            ( Name "ada", Name "bob" )

        _ =
            Debug.log "pair" (a ++ "-" ++ b)

        _ =
            Debug.log "maybe" (Maybe.map unName (List.head names) |> Maybe.withDefault "")

        _ =
            Debug.log "eq" (Name "x" == Name "x")

        _ =
            Debug.log "neq" (Name "x" /= Name "y")

        _ =
            Debug.log "folded" (unName (List.foldl (\s acc -> append acc s) (Name "") (List.map Name [ "a", "b", "c" ])))
    in
    text "done"
