module NullableMaybeTypeVarTest exposing (main)

{-| `Maybe` values seen through type variables and function values: `Debug.toString`
as a value, `apply`, `twice`, `always Nothing`, a generic record, a list of
`Maybe String -> Maybe String` functions, `List.repeat`, folds and pairs.

Expected output from elm make + node.

-}

-- CHECK: show: ["Nothing","Just \"\"","Just \"a\""]
-- CHECK: apply: ["N","J","Ja"]
-- CHECK: twice: ["N","J++","Ja++"]
-- CHECK: nothingOf: ("N",2)
-- CHECK: holders: ([{ label = "N", value = Nothing },{ label = "J", value = Just "" },{ label = "Ja", value = Just "a" }],["N","J","Ja"])
-- CHECK: fs: ["N","J","Ja","N","N","N","N","J!","Ja!","N","J","Ja"]
-- CHECK: repeat: ["N","N","Jx"]
-- CHECK: fold: "JaJN"
-- CHECK: pairs: ["NJa","JJ","JaN"]

import Html exposing (text)


type alias Holder a =
    { value : a, label : String }


describe : Maybe String -> String
describe m =
    case m of
        Nothing ->
            "N"

        Just s ->
            "J" ++ s


apply : (a -> b) -> a -> b
apply f x =
    f x


twice : (a -> a) -> a -> a
twice f =
    f >> f


nothingOf : a -> Maybe b
nothingOf _ =
    Nothing


main =
    let
        strs =
            [ Nothing, Just "", Just "a" ]

        show =
            Debug.toString

        holders =
            List.map (\m -> { value = m, label = describe m }) strs

        fs : List (Maybe String -> Maybe String)
        fs =
            [ identity, always Nothing, Maybe.map (\s -> s ++ "!"), \m -> Maybe.andThen (\_ -> m) m ]

        _ =
            Debug.log "show" (List.map show strs)

        _ =
            Debug.log "apply" (List.map (apply describe) strs)

        _ =
            Debug.log "twice" (List.map (twice (Maybe.map (\s -> s ++ "+")) >> describe) strs)

        _ =
            Debug.log "nothingOf" ( describe (nothingOf 1), List.length [ nothingOf "x", Nothing ] )

        _ =
            Debug.log "holders" ( holders, List.map (.value >> describe) holders )

        _ =
            Debug.log "fs" (List.concatMap (\f -> List.map (f >> describe) strs) fs)

        _ =
            Debug.log "repeat" (List.map describe (List.repeat 2 Nothing ++ [ Just "x" ]))

        _ =
            Debug.log "fold" (List.foldl (\m acc -> describe m ++ acc) "" strs)

        _ =
            Debug.log "pairs" (List.map2 Tuple.pair strs (List.reverse strs) |> List.map (\( a, b ) -> describe a ++ describe b))
    in
    text ""
