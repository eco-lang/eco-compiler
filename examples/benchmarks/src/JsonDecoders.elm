module JsonDecoders exposing (bench)

{-| `Json.Decode` combinators under load, the Elm-specific part of JSON: a 12-field record decoded
with an `andMap` chain, a union type decoded by `andThen` on a `"kind"` tag (eight variants),
untagged values decoded by `oneOf` over six alternatives, and a recursive tree through `lazy`.
`n` items of each are generated, encoded and decoded back.

The decoded values must equal the generated ones exactly, at every size.

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap =
    Decode.map2 (|>)



-- A WIDE RECORD


type alias Wide =
    { a : Int, b : String, c : Float, d : Bool, e : Int, f : String, g : Float, h : Bool, i : Int, j : String, k : List Int, l : Maybe Float }


wide : Int -> Wide
wide n =
    Wide n
        ("b" ++ String.fromInt n)
        (toFloat n / 8)
        (modBy 2 n == 0)
        (n * 3)
        ("f" ++ String.fromInt (n * 7))
        (toFloat n * 1.25)
        (modBy 3 n == 0)
        (n - 5)
        "j"
        (List.range 0 (modBy 4 n))
        (if modBy 5 n == 0 then
            Nothing

         else
            Just (toFloat n / 3)
        )


encodeWide : Wide -> Encode.Value
encodeWide w =
    Encode.object
        [ ( "a", Encode.int w.a )
        , ( "b", Encode.string w.b )
        , ( "c", Encode.float w.c )
        , ( "d", Encode.bool w.d )
        , ( "e", Encode.int w.e )
        , ( "f", Encode.string w.f )
        , ( "g", Encode.float w.g )
        , ( "h", Encode.bool w.h )
        , ( "i", Encode.int w.i )
        , ( "j", Encode.string w.j )
        , ( "k", Encode.list Encode.int w.k )
        , ( "l", Maybe.withDefault Encode.null (Maybe.map Encode.float w.l) )
        ]


wideDecoder : Decoder Wide
wideDecoder =
    Decode.succeed Wide
        |> andMap (Decode.field "a" Decode.int)
        |> andMap (Decode.field "b" Decode.string)
        |> andMap (Decode.field "c" Decode.float)
        |> andMap (Decode.field "d" Decode.bool)
        |> andMap (Decode.field "e" Decode.int)
        |> andMap (Decode.field "f" Decode.string)
        |> andMap (Decode.field "g" Decode.float)
        |> andMap (Decode.field "h" Decode.bool)
        |> andMap (Decode.field "i" Decode.int)
        |> andMap (Decode.field "j" Decode.string)
        |> andMap (Decode.field "k" (Decode.list Decode.int))
        |> andMap (Decode.field "l" (Decode.nullable Decode.float))



-- A TAGGED UNION


type Shape
    = Circle Float
    | Square Float
    | Rect Float Float
    | Triangle Float Float Float
    | Label String
    | Point
    | Polygon (List ( Float, Float ))
    | Group String (List Int)


shape : Int -> Shape
shape n =
    let
        x =
            toFloat n / 4
    in
    case modBy 8 n of
        0 ->
            Circle x

        1 ->
            Square x

        2 ->
            Rect x (x + 1)

        3 ->
            Triangle x (x + 1) (x + 2)

        4 ->
            Label ("shape " ++ String.fromInt n)

        5 ->
            Point

        6 ->
            Polygon (List.map (\i -> ( toFloat i, x )) (List.range 0 (modBy 5 n)))

        _ ->
            Group ("g" ++ String.fromInt n) (List.range n (n + modBy 4 n))


encodeShape : Shape -> Encode.Value
encodeShape s =
    let
        tagged kind fields =
            Encode.object (( "kind", Encode.string kind ) :: fields)
    in
    case s of
        Circle r ->
            tagged "circle" [ ( "r", Encode.float r ) ]

        Square side ->
            tagged "square" [ ( "side", Encode.float side ) ]

        Rect w h ->
            tagged "rect" [ ( "w", Encode.float w ), ( "h", Encode.float h ) ]

        Triangle a b c ->
            tagged "triangle" [ ( "sides", Encode.list Encode.float [ a, b, c ] ) ]

        Label text ->
            tagged "label" [ ( "text", Encode.string text ) ]

        Point ->
            tagged "point" []

        Polygon points ->
            tagged "polygon" [ ( "points", Encode.list (\( a, b ) -> Encode.list Encode.float [ a, b ]) points ) ]

        Group name members ->
            tagged "group" [ ( "name", Encode.string name ), ( "members", Encode.list Encode.int members ) ]


shapeDecoder : Decoder Shape
shapeDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "circle" ->
                        Decode.map Circle (Decode.field "r" Decode.float)

                    "square" ->
                        Decode.map Square (Decode.field "side" Decode.float)

                    "rect" ->
                        Decode.map2 Rect (Decode.field "w" Decode.float) (Decode.field "h" Decode.float)

                    "triangle" ->
                        Decode.field "sides"
                            (Decode.map3 Triangle (Decode.index 0 Decode.float) (Decode.index 1 Decode.float) (Decode.index 2 Decode.float))

                    "label" ->
                        Decode.map Label (Decode.field "text" Decode.string)

                    "point" ->
                        Decode.succeed Point

                    "polygon" ->
                        Decode.map Polygon (Decode.field "points" (Decode.list (Decode.map2 Tuple.pair (Decode.index 0 Decode.float) (Decode.index 1 Decode.float))))

                    "group" ->
                        Decode.map2 Group (Decode.field "name" Decode.string) (Decode.field "members" (Decode.list Decode.int))

                    other ->
                        Decode.fail ("unknown kind " ++ other)
            )



-- UNTAGGED VALUES


type Scalar
    = SInt Int
    | SFloat Float
    | SString String
    | SBool Bool
    | SList (List Int)
    | SNull


scalar : Int -> Scalar
scalar n =
    case modBy 6 n of
        0 ->
            SInt n

        1 ->
            SFloat (toFloat n + 0.5)

        2 ->
            SString ("s" ++ String.fromInt n)

        3 ->
            SBool (modBy 4 n == 1)

        4 ->
            SList (List.range 0 (modBy 3 n))

        _ ->
            SNull


encodeScalar : Scalar -> Encode.Value
encodeScalar s =
    case s of
        SInt i ->
            Encode.int i

        SFloat f ->
            Encode.float f

        SString t ->
            Encode.string t

        SBool b ->
            Encode.bool b

        SList xs ->
            Encode.list Encode.int xs

        SNull ->
            Encode.null


{-| `int` before `float`: a JSON integer decodes as either, and the generator only makes floats
with a fraction.
-}
scalarDecoder : Decoder Scalar
scalarDecoder =
    Decode.oneOf
        [ Decode.map SInt Decode.int
        , Decode.map SFloat Decode.float
        , Decode.map SString Decode.string
        , Decode.map SBool Decode.bool
        , Decode.map SList (Decode.list Decode.int)
        , Decode.null SNull
        ]



-- A RECURSIVE TREE


type Tree
    = Leaf Int
    | Node (List Tree)


tree : Int -> Int -> Tree
tree depth n =
    if depth <= 0 then
        Leaf n

    else
        Node (List.map (\i -> tree (depth - 1) (n * 3 + i)) (List.range 0 (modBy 3 n)))


encodeTree : Tree -> Encode.Value
encodeTree t =
    case t of
        Leaf v ->
            Encode.int v

        Node children ->
            Encode.list encodeTree children


treeDecoder : Decoder Tree
treeDecoder =
    Decode.oneOf
        [ Decode.map Leaf Decode.int
        , Decode.map Node (Decode.list (Decode.lazy (\_ -> treeDecoder)))
        ]


roundTrip : (a -> Encode.Value) -> Decoder a -> List a -> Bool
roundTrip encoder decoder values =
    Decode.decodeString (Decode.list decoder) (Encode.encode 0 (Encode.list encoder values)) == Ok values


bench : Int -> Bool
bench n =
    let
        items =
            List.range 1 n
    in
    roundTrip encodeWide wideDecoder (List.map wide items)
        && roundTrip encodeShape shapeDecoder (List.map shape items)
        && roundTrip encodeScalar scalarDecoder (List.map scalar items)
        && roundTrip encodeTree treeDecoder (List.map (tree 4) (List.range 1 (n // 20 + 1)))
