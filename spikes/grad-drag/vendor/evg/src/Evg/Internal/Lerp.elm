module Evg.Internal.Lerp exposing
    ( attribute
    , float
    , numbers
    , transform
    , transformToMatrix
    )

{-| Blending attribute values for `Evg.Drag`.

Everything here works on the inspectable string form of attributes (the same
strings `Evg.toString` writes), because that is the one representation every
node in an Evg tree carries. The strategy, in order:

1.  Equal strings stay as they are.
2.  Colours (hex, `rgb()`/`rgba()`, CSS names, `none`) blend channel-wise.
3.  Strings with the same "shape", i.e. identical apart from the numbers in
    them, blend number by number. This covers lengths, `points`, path data
    with the same commands, `viewBox`, dash patterns and so on.
4.  Anything else snaps: the first value up to the halfway point, the second
    after it.

Transforms get a dedicated path: lists of the same functions blend argument by
argument (so a `rotate(a cx cy)` sweeps along an arc), and differing lists fall
back to decomposing both into translate/rotate/skew/scale.

-}

import Dict exposing (Dict)
import Evg.Internal as Internal exposing (Mat23)


{-| Linear interpolation.
-}
float : Float -> Float -> Float -> Float
float t a b =
    a + (b - a) * t


{-| Blend the value of the attribute `key` between `a` (at `t = 0`) and `b`
(at `t = 1`). Missing values are given as `Nothing`.
-}
attribute : String -> Float -> Maybe String -> Maybe String -> Maybe String
attribute key t ma mb =
    case ( withDefault key ma, withDefault key mb ) of
        ( Just a, Just b ) ->
            Just (value key t a b)

        ( Just a, Nothing ) ->
            Just a

        ( Nothing, Just b ) ->
            Just b

        ( Nothing, Nothing ) ->
            Nothing


withDefault : String -> Maybe String -> Maybe String
withDefault key maybeValue =
    case maybeValue of
        Just _ ->
            maybeValue

        Nothing ->
            Dict.get key defaults


defaults : Dict String String
defaults =
    Dict.fromList
        [ ( "opacity", "1" )
        , ( "fill-opacity", "1" )
        , ( "stroke-opacity", "1" )
        , ( "stop-opacity", "1" )
        , ( "stroke-width", "1" )
        , ( "stroke-dashoffset", "0" )
        ]


value : String -> Float -> String -> String -> String
value key t a b =
    if a == b then
        a

    else if not (blendable key) then
        snap t a b

    else
        case ( parseColor a, parseColor b ) of
            ( Just ca, Just cb ) ->
                blendColors t ca cb

            _ ->
                if String.contains "url(" a || String.contains "url(" b then
                    snap t a b

                else
                    case blendShapes t (tokenize a) (tokenize b) of
                        Just blended ->
                            blended

                        Nothing ->
                            snap t a b


snap : Float -> a -> a -> a
snap t a b =
    if t < 0.5 then
        a

    else
        b


{-| Attributes whose values are names, references or keywords. Blending the
digits inside them would produce nonsense like `class="item-3.5"`.
-}
blendable : String -> Bool
blendable key =
    not
        (String.startsWith "data-" key
            || List.member key
                [ "class"
                , "id"
                , "href"
                , "xlink:href"
                , "font-family"
                , "result"
                , "in"
                , "in2"
                , "clip-path"
                , "mask"
                , "filter"
                , "marker-start"
                , "marker-mid"
                , "marker-end"
                , "role"
                , "aria-label"
                , "text-anchor"
                , "dominant-baseline"
                , "visibility"
                , "cursor"
                , "pointer-events"
                , "touch-action"
                ]
        )



-- NUMBERS INSIDE STRINGS


{-| The numbers in a string, in order.
-}
numbers : String -> List Float
numbers str =
    List.filterMap
        (\token ->
            case token of
                Num n ->
                    Just n

                Txt _ ->
                    Nothing
        )
        (tokenize str)


type Token
    = Num Float
    | Txt String


{-| Split a string into runs of text and the numbers between them. Numbers
follow SVG's grammar: an optional sign, digits with an optional fraction, and
an optional exponent. A sign or a dot directly after a number starts a new
number, so `"M10-5.5.5"` reads as `M`, `10`, `-5.5`, `.5`.
-}
tokenize : String -> List Token
tokenize str =
    tokenizeHelp (String.toList str) [] []


tokenizeHelp : List Char -> List Char -> List Token -> List Token
tokenizeHelp chars textAcc tokens =
    case chars of
        [] ->
            List.reverse (flushText textAcc tokens)

        c :: rest ->
            case readNumber chars of
                Just ( n, remaining ) ->
                    if startsNumber c && not (glued textAcc) then
                        tokenizeHelp remaining [] (Num n :: flushText textAcc tokens)

                    else
                        tokenizeHelp rest (c :: textAcc) tokens

                Nothing ->
                    tokenizeHelp rest (c :: textAcc) tokens


{-| A number directly after a letter that isn't a single path/transform
command letter is part of a name (`e12`, `item3`), not a value. We detect this
by looking at whether the preceding text run ends in two letters.
-}
glued : List Char -> Bool
glued textAccReversed =
    case textAccReversed of
        c1 :: c2 :: _ ->
            Char.isAlpha c1 && (Char.isAlpha c2 || c2 == '-' || c2 == '_')

        _ ->
            False


startsNumber : Char -> Bool
startsNumber c =
    Char.isDigit c || c == '-' || c == '+' || c == '.'


flushText : List Char -> List Token -> List Token
flushText textAcc tokens =
    case textAcc of
        [] ->
            tokens

        _ ->
            Txt (String.fromList (List.reverse textAcc)) :: tokens


readNumber : List Char -> Maybe ( Float, List Char )
readNumber chars =
    let
        ( sign, afterSign ) =
            case chars of
                '-' :: rest ->
                    ( "-", rest )

                '+' :: rest ->
                    ( "", rest )

                _ ->
                    ( "", chars )

        ( intDigits, afterInt ) =
            spanDigits afterSign

        ( fracPart, afterFrac ) =
            case afterInt of
                '.' :: rest ->
                    let
                        ( digits, remaining ) =
                            spanDigits rest
                    in
                    ( "." ++ digits, remaining )

                _ ->
                    ( "", afterInt )

        mantissaOk =
            not (String.isEmpty intDigits) || String.length fracPart > 1

        ( expPart, afterExp ) =
            case afterFrac of
                e :: rest ->
                    if e == 'e' || e == 'E' then
                        let
                            ( expSign, afterExpSign ) =
                                case rest of
                                    '-' :: r ->
                                        ( "-", r )

                                    '+' :: r ->
                                        ( "", r )

                                    _ ->
                                        ( "", rest )

                            ( expDigits, remaining ) =
                                spanDigits afterExpSign
                        in
                        if String.isEmpty expDigits then
                            ( "", afterFrac )

                        else
                            ( "e" ++ expSign ++ expDigits, remaining )

                    else
                        ( "", afterFrac )

                [] ->
                    ( "", afterFrac )
    in
    if mantissaOk then
        String.toFloat (sign ++ zeroIfEmpty intDigits ++ fracDigitsOrEmpty fracPart ++ expPart)
            |> Maybe.map (\n -> ( n, afterExp ))

    else
        Nothing


zeroIfEmpty : String -> String
zeroIfEmpty s =
    if String.isEmpty s then
        "0"

    else
        s


fracDigitsOrEmpty : String -> String
fracDigitsOrEmpty s =
    if s == "." then
        ""

    else
        s


spanDigits : List Char -> ( String, List Char )
spanDigits chars =
    spanDigitsHelp chars []


spanDigitsHelp : List Char -> List Char -> ( String, List Char )
spanDigitsHelp chars acc =
    case chars of
        c :: rest ->
            if Char.isDigit c then
                spanDigitsHelp rest (c :: acc)

            else
                ( String.fromList (List.reverse acc), chars )

        [] ->
            ( String.fromList (List.reverse acc), [] )


blendShapes : Float -> List Token -> List Token -> Maybe String
blendShapes t a b =
    blendShapesHelp t a b []


blendShapesHelp : Float -> List Token -> List Token -> List String -> Maybe String
blendShapesHelp t a b acc =
    case ( a, b ) of
        ( [], [] ) ->
            Just (String.concat (List.reverse acc))

        ( (Num x) :: restA, (Num y) :: restB ) ->
            blendShapesHelp t restA restB (formatFloat (float t x y) :: acc)

        ( (Txt x) :: restA, (Txt y) :: restB ) ->
            if x == y then
                blendShapesHelp t restA restB (x :: acc)

            else
                Nothing

        _ ->
            Nothing


{-| Print a number compactly. Blended values are rounded to a millionth, which
is far below anything visible and keeps strings short and stable.
-}
formatFloat : Float -> String
formatFloat x =
    let
        rounded =
            toFloat (round (x * 1000000)) / 1000000
    in
    if abs rounded < 1.0e-9 then
        "0"

    else
        String.fromFloat rounded



-- COLOURS


type alias Rgba =
    { r : Float, g : Float, b : Float, a : Float }


blendColors : Float -> Rgba -> Rgba -> String
blendColors t ca cb =
    let
        -- Blending to or from `none` fades the other colour's alpha
        -- rather than passing through black.
        ( fromC, toC ) =
            if ca.a == 0 && isNoneSentinel ca then
                ( { cb | a = 0 }, cb )

            else if cb.a == 0 && isNoneSentinel cb then
                ( ca, { ca | a = 0 } )

            else
                ( ca, cb )

        pct x =
            String.fromFloat (toFloat (round (x * 10000)) / 100) ++ "%"
    in
    "rgba("
        ++ pct (float t fromC.r toC.r)
        ++ ","
        ++ pct (float t fromC.g toC.g)
        ++ ","
        ++ pct (float t fromC.b toC.b)
        ++ ","
        ++ String.fromFloat (toFloat (round (float t fromC.a toC.a * 1000)) / 1000)
        ++ ")"


{-| `none` parses to this marker (an impossible negative channel), so blending
can tell it apart from a genuinely transparent black.
-}
noneColor : Rgba
noneColor =
    { r = -1, g = -1, b = -1, a = 0 }


isNoneSentinel : Rgba -> Bool
isNoneSentinel c =
    c.r < 0


parseColor : String -> Maybe Rgba
parseColor raw =
    let
        str =
            String.toLower (String.trim raw)
    in
    if str == "none" || str == "transparent" then
        Just noneColor

    else if String.startsWith "#" str then
        parseHex (String.dropLeft 1 str)

    else if String.startsWith "rgb" str then
        parseRgbFunction str

    else
        Dict.get str namedColors
            |> Maybe.andThen (\hex -> parseHex hex)


parseHex : String -> Maybe Rgba
parseHex hex =
    let
        channel s =
            hexToInt s |> Maybe.map (\n -> toFloat n / 255)

        double c =
            String.fromList [ c, c ]
    in
    case String.toList hex of
        [ r, g, b ] ->
            Maybe.map3 (\r_ g_ b_ -> { r = r_, g = g_, b = b_, a = 1 })
                (channel (double r))
                (channel (double g))
                (channel (double b))

        [ r1, r2, g1, g2, b1, b2 ] ->
            Maybe.map3 (\r_ g_ b_ -> { r = r_, g = g_, b = b_, a = 1 })
                (channel (String.fromList [ r1, r2 ]))
                (channel (String.fromList [ g1, g2 ]))
                (channel (String.fromList [ b1, b2 ]))

        [ r1, r2, g1, g2, b1, b2, a1, a2 ] ->
            Maybe.map4 (\r_ g_ b_ a_ -> { r = r_, g = g_, b = b_, a = a_ })
                (channel (String.fromList [ r1, r2 ]))
                (channel (String.fromList [ g1, g2 ]))
                (channel (String.fromList [ b1, b2 ]))
                (channel (String.fromList [ a1, a2 ]))

        _ ->
            Nothing


hexToInt : String -> Maybe Int
hexToInt s =
    String.foldl
        (\c acc ->
            Maybe.andThen
                (\n ->
                    hexDigit c |> Maybe.map (\d -> n * 16 + d)
                )
                acc
        )
        (Just 0)
        s


hexDigit : Char -> Maybe Int
hexDigit c =
    if Char.isDigit c then
        Just (Char.toCode c - Char.toCode '0')

    else if c >= 'a' && c <= 'f' then
        Just (Char.toCode c - Char.toCode 'a' + 10)

    else
        Nothing


{-| `rgb(255, 0, 0)`, `rgba(100%,0%,0%,0.5)` and the space-separated modern
syntax. Percentages and 0–255 channels can be mixed.
-}
parseRgbFunction : String -> Maybe Rgba
parseRgbFunction str =
    let
        inner =
            str
                |> String.replace "rgba(" ""
                |> String.replace "rgb(" ""
                |> String.replace ")" ""
                |> String.replace "," " "
                |> String.replace "/" " "
                |> String.words

        channel s =
            if String.endsWith "%" s then
                String.toFloat (String.dropRight 1 s) |> Maybe.map (\n -> n / 100)

            else
                String.toFloat s |> Maybe.map (\n -> n / 255)

        alpha s =
            if String.endsWith "%" s then
                String.toFloat (String.dropRight 1 s) |> Maybe.map (\n -> n / 100)

            else
                String.toFloat s
    in
    case inner of
        [ r, g, b ] ->
            Maybe.map3 (\r_ g_ b_ -> { r = r_, g = g_, b = b_, a = 1 }) (channel r) (channel g) (channel b)

        [ r, g, b, a ] ->
            Maybe.map4 (\r_ g_ b_ a_ -> { r = r_, g = g_, b = b_, a = a_ }) (channel r) (channel g) (channel b) (alpha a)

        _ ->
            Nothing


namedColors : Dict String String
namedColors =
    Dict.fromList
        [ ( "aliceblue", "f0f8ff" )
        , ( "antiquewhite", "faebd7" )
        , ( "aqua", "00ffff" )
        , ( "aquamarine", "7fffd4" )
        , ( "azure", "f0ffff" )
        , ( "beige", "f5f5dc" )
        , ( "bisque", "ffe4c4" )
        , ( "black", "000000" )
        , ( "blanchedalmond", "ffebcd" )
        , ( "blue", "0000ff" )
        , ( "blueviolet", "8a2be2" )
        , ( "brown", "a52a2a" )
        , ( "burlywood", "deb887" )
        , ( "cadetblue", "5f9ea0" )
        , ( "chartreuse", "7fff00" )
        , ( "chocolate", "d2691e" )
        , ( "coral", "ff7f50" )
        , ( "cornflowerblue", "6495ed" )
        , ( "cornsilk", "fff8dc" )
        , ( "crimson", "dc143c" )
        , ( "cyan", "00ffff" )
        , ( "darkblue", "00008b" )
        , ( "darkcyan", "008b8b" )
        , ( "darkgoldenrod", "b8860b" )
        , ( "darkgray", "a9a9a9" )
        , ( "darkgreen", "006400" )
        , ( "darkgrey", "a9a9a9" )
        , ( "darkkhaki", "bdb76b" )
        , ( "darkmagenta", "8b008b" )
        , ( "darkolivegreen", "556b2f" )
        , ( "darkorange", "ff8c00" )
        , ( "darkorchid", "9932cc" )
        , ( "darkred", "8b0000" )
        , ( "darksalmon", "e9967a" )
        , ( "darkseagreen", "8fbc8f" )
        , ( "darkslateblue", "483d8b" )
        , ( "darkslategray", "2f4f4f" )
        , ( "darkslategrey", "2f4f4f" )
        , ( "darkturquoise", "00ced1" )
        , ( "darkviolet", "9400d3" )
        , ( "deeppink", "ff1493" )
        , ( "deepskyblue", "00bfff" )
        , ( "dimgray", "696969" )
        , ( "dimgrey", "696969" )
        , ( "dodgerblue", "1e90ff" )
        , ( "firebrick", "b22222" )
        , ( "floralwhite", "fffaf0" )
        , ( "forestgreen", "228b22" )
        , ( "fuchsia", "ff00ff" )
        , ( "gainsboro", "dcdcdc" )
        , ( "ghostwhite", "f8f8ff" )
        , ( "gold", "ffd700" )
        , ( "goldenrod", "daa520" )
        , ( "gray", "808080" )
        , ( "green", "008000" )
        , ( "greenyellow", "adff2f" )
        , ( "grey", "808080" )
        , ( "honeydew", "f0fff0" )
        , ( "hotpink", "ff69b4" )
        , ( "indianred", "cd5c5c" )
        , ( "indigo", "4b0082" )
        , ( "ivory", "fffff0" )
        , ( "khaki", "f0e68c" )
        , ( "lavender", "e6e6fa" )
        , ( "lavenderblush", "fff0f5" )
        , ( "lawngreen", "7cfc00" )
        , ( "lemonchiffon", "fffacd" )
        , ( "lightblue", "add8e6" )
        , ( "lightcoral", "f08080" )
        , ( "lightcyan", "e0ffff" )
        , ( "lightgoldenrodyellow", "fafad2" )
        , ( "lightgray", "d3d3d3" )
        , ( "lightgreen", "90ee90" )
        , ( "lightgrey", "d3d3d3" )
        , ( "lightpink", "ffb6c1" )
        , ( "lightsalmon", "ffa07a" )
        , ( "lightseagreen", "20b2aa" )
        , ( "lightskyblue", "87cefa" )
        , ( "lightslategray", "778899" )
        , ( "lightslategrey", "778899" )
        , ( "lightsteelblue", "b0c4de" )
        , ( "lightyellow", "ffffe0" )
        , ( "lime", "00ff00" )
        , ( "limegreen", "32cd32" )
        , ( "linen", "faf0e6" )
        , ( "magenta", "ff00ff" )
        , ( "maroon", "800000" )
        , ( "mediumaquamarine", "66cdaa" )
        , ( "mediumblue", "0000cd" )
        , ( "mediumorchid", "ba55d3" )
        , ( "mediumpurple", "9370db" )
        , ( "mediumseagreen", "3cb371" )
        , ( "mediumslateblue", "7b68ee" )
        , ( "mediumspringgreen", "00fa9a" )
        , ( "mediumturquoise", "48d1cc" )
        , ( "mediumvioletred", "c71585" )
        , ( "midnightblue", "191970" )
        , ( "mintcream", "f5fffa" )
        , ( "mistyrose", "ffe4e1" )
        , ( "moccasin", "ffe4b5" )
        , ( "navajowhite", "ffdead" )
        , ( "navy", "000080" )
        , ( "oldlace", "fdf5e6" )
        , ( "olive", "808000" )
        , ( "olivedrab", "6b8e23" )
        , ( "orange", "ffa500" )
        , ( "orangered", "ff4500" )
        , ( "orchid", "da70d6" )
        , ( "palegoldenrod", "eee8aa" )
        , ( "palegreen", "98fb98" )
        , ( "paleturquoise", "afeeee" )
        , ( "palevioletred", "db7093" )
        , ( "papayawhip", "ffefd5" )
        , ( "peachpuff", "ffdab9" )
        , ( "peru", "cd853f" )
        , ( "pink", "ffc0cb" )
        , ( "plum", "dda0dd" )
        , ( "powderblue", "b0e0e6" )
        , ( "purple", "800080" )
        , ( "rebeccapurple", "663399" )
        , ( "red", "ff0000" )
        , ( "rosybrown", "bc8f8f" )
        , ( "royalblue", "4169e1" )
        , ( "saddlebrown", "8b4513" )
        , ( "salmon", "fa8072" )
        , ( "sandybrown", "f4a460" )
        , ( "seagreen", "2e8b57" )
        , ( "seashell", "fff5ee" )
        , ( "sienna", "a0522d" )
        , ( "silver", "c0c0c0" )
        , ( "skyblue", "87ceeb" )
        , ( "slateblue", "6a5acd" )
        , ( "slategray", "708090" )
        , ( "slategrey", "708090" )
        , ( "snow", "fffafa" )
        , ( "springgreen", "00ff7f" )
        , ( "steelblue", "4682b4" )
        , ( "tan", "d2b48c" )
        , ( "teal", "008080" )
        , ( "thistle", "d8bfd8" )
        , ( "tomato", "ff6347" )
        , ( "turquoise", "40e0d0" )
        , ( "violet", "ee82ee" )
        , ( "wheat", "f5deb3" )
        , ( "white", "ffffff" )
        , ( "whitesmoke", "f5f5f5" )
        , ( "yellow", "ffff00" )
        , ( "yellowgreen", "9acd32" )
        ]



-- TRANSFORMS


type alias TransformFn =
    { name : String, args : List Float }


{-| Parse an SVG transform list such as `translate(10 20) rotate(45, 5, 5)`.
Returns `Nothing` for anything it doesn't understand.
-}
parseTransform : String -> Maybe (List TransformFn)
parseTransform str =
    parseTransformHelp (tokenize str) []


parseTransformHelp : List Token -> List TransformFn -> Maybe (List TransformFn)
parseTransformHelp tokens acc =
    case tokens of
        [] ->
            Just (List.reverse acc)

        (Txt txt) :: rest ->
            case transformName txt of
                Just name ->
                    let
                        ( args, remaining ) =
                            collectArgs rest []
                    in
                    parseTransformHelp remaining ({ name = name, args = args } :: acc)

                Nothing ->
                    if String.isEmpty (String.trim (String.replace ")" "" (String.replace "," "" txt))) then
                        parseTransformHelp rest acc

                    else
                        Nothing

        (Num _) :: _ ->
            Nothing


{-| A text run like `") rotate("` or `"translate("`: the last word before the
opening parenthesis is the function name.
-}
transformName : String -> Maybe String
transformName txt =
    case String.split "(" txt of
        [ before, after ] ->
            if String.isEmpty (String.trim after) then
                let
                    name =
                        before
                            |> String.replace ")" " "
                            |> String.replace "," " "
                            |> String.words
                            |> List.reverse
                            |> List.head
                            |> Maybe.withDefault ""
                in
                if List.member name [ "translate", "rotate", "scale", "skewX", "skewY", "matrix" ] then
                    Just name

                else
                    Nothing

            else
                Nothing

        _ ->
            Nothing


collectArgs : List Token -> List Float -> ( List Float, List Token )
collectArgs tokens acc =
    case tokens of
        (Num n) :: rest ->
            collectArgs rest (n :: acc)

        (Txt txt) :: rest ->
            if String.contains "(" txt then
                ( List.reverse acc, tokens )

            else if String.isEmpty (String.trim (String.replace "," "" txt)) then
                collectArgs rest acc

            else
                -- A closing parenthesis ends the argument list. Whatever
                -- follows it in the same run is handed back for the next
                -- function name.
                ( List.reverse acc, remainderAfterParen txt rest )

        [] ->
            ( List.reverse acc, [] )


remainderAfterParen : String -> List Token -> List Token
remainderAfterParen txt rest =
    case String.indexes ")" txt of
        i :: _ ->
            let
                remainder =
                    String.dropLeft (i + 1) txt
            in
            if String.isEmpty (String.trim remainder) then
                rest

            else
                Txt remainder :: rest

        [] ->
            rest


fnToMatrix : TransformFn -> Mat23
fnToMatrix { name, args } =
    case ( name, args ) of
        ( "translate", [ x ] ) ->
            { a = 1, b = 0, c = 0, d = 1, e = x, f = 0 }

        ( "translate", [ x, y ] ) ->
            { a = 1, b = 0, c = 0, d = 1, e = x, f = y }

        ( "scale", [ s ] ) ->
            { a = s, b = 0, c = 0, d = s, e = 0, f = 0 }

        ( "scale", [ sx, sy ] ) ->
            { a = sx, b = 0, c = 0, d = sy, e = 0, f = 0 }

        ( "rotate", [ deg ] ) ->
            rotation deg

        ( "rotate", [ deg, cx, cy ] ) ->
            Internal.composeMat { a = 1, b = 0, c = 0, d = 1, e = cx, f = cy }
                (Internal.composeMat (rotation deg) { a = 1, b = 0, c = 0, d = 1, e = -cx, f = -cy })

        ( "skewX", [ deg ] ) ->
            { a = 1, b = 0, c = tan (degrees deg), d = 1, e = 0, f = 0 }

        ( "skewY", [ deg ] ) ->
            { a = 1, b = tan (degrees deg), c = 0, d = 1, e = 0, f = 0 }

        ( "matrix", [ a, b, c, d, e, f ] ) ->
            { a = a, b = b, c = c, d = d, e = e, f = f }

        _ ->
            Internal.identityMat


rotation : Float -> Mat23
rotation deg =
    let
        r =
            degrees deg
    in
    { a = cos r, b = sin r, c = -(sin r), d = cos r, e = 0, f = 0 }


{-| The matrix a transform string describes (identity if it can't be parsed).
-}
transformToMatrix : String -> Mat23
transformToMatrix str =
    case parseTransform str of
        Just fns ->
            List.foldl (\fn acc -> Internal.composeMat acc (fnToMatrix fn)) Internal.identityMat fns

        Nothing ->
            Internal.identityMat


{-| Blend two transform strings. Returns the blended string.
-}
transform : Float -> String -> String -> String
transform t a b =
    if a == b then
        a

    else
        case ( parseTransform a, parseTransform b ) of
            ( Just fa, Just fb ) ->
                if sameShape fa fb then
                    List.map2
                        (\x y -> { name = x.name, args = List.map2 (float t) x.args y.args })
                        fa
                        fb
                        |> printTransform

                else
                    blendMatrices t (composeFns fa) (composeFns fb)
                        |> printMatrix

            _ ->
                blendMatrices t (transformToMatrix a) (transformToMatrix b)
                    |> printMatrix


sameShape : List TransformFn -> List TransformFn -> Bool
sameShape fa fb =
    List.length fa
        == List.length fb
        && List.all identity
            (List.map2 (\x y -> x.name == y.name && List.length x.args == List.length y.args) fa fb)


composeFns : List TransformFn -> Mat23
composeFns =
    List.foldl (\fn acc -> Internal.composeMat acc (fnToMatrix fn)) Internal.identityMat


printTransform : List TransformFn -> String
printTransform fns =
    fns
        |> List.map (\{ name, args } -> name ++ "(" ++ String.join " " (List.map formatFloat args) ++ ")")
        |> String.join " "


printMatrix : Mat23 -> String
printMatrix m =
    if m == Internal.identityMat then
        ""

    else
        "matrix("
            ++ String.join " " (List.map formatFloat [ m.a, m.b, m.c, m.d, m.e, m.f ])
            ++ ")"


type alias Decomposed =
    { tx : Float, ty : Float, angle : Float, skew : Float, sx : Float, sy : Float }


{-| Split a matrix into translate · rotate · skewX · scale, so that blending
the parts turns shapes rather than squashing them through the middle.
-}
decompose : Mat23 -> Decomposed
decompose m =
    let
        det =
            m.a * m.d - m.b * m.c

        -- A reflection is folded into a negative x scale.
        flip =
            if det < 0 then
                -1

            else
                1

        a =
            m.a * flip

        b =
            m.b * flip

        sx =
            sqrt (a * a + b * b)
    in
    if sx == 0 then
        { tx = m.e, ty = m.f, angle = 0, skew = 0, sx = 0, sy = sqrt (m.c * m.c + m.d * m.d) }

    else
        let
            ax =
                a / sx

            bx =
                b / sx

            skewRaw =
                ax * m.c + bx * m.d

            c2 =
                m.c - ax * skewRaw

            d2 =
                m.d - bx * skewRaw

            sy =
                sqrt (c2 * c2 + d2 * d2)
        in
        { tx = m.e
        , ty = m.f
        , angle = atan2 bx ax
        , skew =
            if sy == 0 then
                0

            else
                skewRaw / sy
        , sx = sx * flip
        , sy = sy
        }


recompose : Decomposed -> Mat23
recompose { tx, ty, angle, skew, sx, sy } =
    let
        cosA =
            cos angle

        sinA =
            sin angle
    in
    { a = cosA * sx
    , b = sinA * sx
    , c = cosA * skew * sy - sinA * sy
    , d = sinA * skew * sy + cosA * sy
    , e = tx
    , f = ty
    }


blendMatrices : Float -> Mat23 -> Mat23 -> Mat23
blendMatrices t ma mb =
    let
        da =
            decompose ma

        db =
            decompose mb

        -- Turn the short way round.
        dAngle =
            wrapAngle (db.angle - da.angle)
    in
    recompose
        { tx = float t da.tx db.tx
        , ty = float t da.ty db.ty
        , angle = da.angle + dAngle * t
        , skew = float t da.skew db.skew
        , sx = float t da.sx db.sx
        , sy = float t da.sy db.sy
        }


wrapAngle : Float -> Float
wrapAngle x =
    if x > pi then
        wrapAngle (x - 2 * pi)

    else if x < -pi then
        wrapAngle (x + 2 * pi)

    else
        x
