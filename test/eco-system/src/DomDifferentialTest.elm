module DomDifferentialTest exposing (main)

{-| Differential test of the two serializers (plans/elm-html-native-kernel.md
P5, VDOM_005): 2,000 pseudo-random trees, each rendered by `Http.Dom.toString`
(natively the C++ HtmlWriter) and by `Http.Dom.render << Http.Dom.fromNode` (the
Elm reference). The vocabulary includes token-breaking tags and attribute names,
every kind of property value, styles, classList, map, Keyed and lazy.
-}

-- SKIP-JS: compares the C++ HtmlWriter with the Elm render; on JS both are the Elm render
-- CHECK: trees: 2000
-- CHECK-NEXT: mismatches: 0
-- EXIT: 0

import Html exposing (Attribute, Html)
import Html.Attributes as A
import Html.Keyed as Keyed
import Html.Lazy as Lazy
import Http.Dom as Dom
import Json.Encode as Encode
import Stream.Log
import System
import VirtualDom


{-| A linear congruential generator (no elm/random): ( value, next seed ).
-}
next : Int -> ( Int, Int )
next seed =
    let
        s =
            modBy 2147483647 (seed * 48271)
    in
    ( s, s )


pick : List a -> a -> Int -> ( a, Int )
pick items default seed =
    let
        ( r, s ) =
            next seed
    in
    ( List.drop (modBy (List.length items) r) items |> List.head |> Maybe.withDefault default, s )


tags : List String
tags =
    [ "div", "span", "p", "br", "img", "input", "textarea", "select", "option", "style", "script", "my-el", "DIV", "a b", "", "x/y", "x\"y", "svg", "Table" ]


names : List String
names =
    [ "id", "class", "className", "title", "style", "value", "href", "data-x", "onclick", "x y", "a=b", "TabIndex", "checked", "disabled", "readOnly", "htmlFor", "innerHTML", "for", "" ]


texts : List String
texts =
    [ "", "x", "a<b>&\"'", "</style>", "é€😀", "  ", "javascript:alert(1)", "data:text/html,<b>", "1;", "margin: 0" ]


styleKeys : List String
styleKeys =
    [ "color", "backgroundColor", "cssFloat", "webkitTransform", "msFlex", "--custom", "Margin" ]


jsonValue : Int -> ( Encode.Value, Int )
jsonValue seed =
    let
        ( r, s1 ) =
            next seed

        ( t, s2 ) =
            pick texts "" s1
    in
    case modBy 8 r of
        0 ->
            ( Encode.string t, s2 )

        1 ->
            ( Encode.bool (modBy 2 r == 0), s2 )

        2 ->
            ( Encode.int (modBy 1000 r - 500), s2 )

        3 ->
            ( Encode.float (toFloat (modBy 100000 r) / 7), s2 )

        4 ->
            ( Encode.null, s2 )

        5 ->
            ( Encode.list Encode.string [ t, "javascript:x" ], s2 )

        6 ->
            ( Encode.object [ ( "k", Encode.string t ) ], s2 )

        _ ->
            ( Encode.float 0, s2 )


attribute : Int -> ( Attribute msg, Int )
attribute seed =
    let
        ( r, s1 ) =
            next seed

        ( name, s2 ) =
            pick names "id" s1

        ( value, s3 ) =
            pick texts "" s2
    in
    case modBy 6 r of
        0 ->
            ( A.attribute name value, s3 )

        1 ->
            let
                ( json, s4 ) =
                    jsonValue s3
            in
            ( A.property name json, s4 )

        2 ->
            let
                ( key, s4 ) =
                    pick styleKeys "color" s3
            in
            ( A.style key value, s4 )

        3 ->
            ( A.classList [ ( value, modBy 2 r == 0 ), ( name, True ) ], s3 )

        4 ->
            ( VirtualDom.attributeNS "urn:x" name value, s3 )

        _ ->
            ( A.map identity (A.class value), s3 )


attributes : Int -> Int -> ( List (Attribute msg), Int )
attributes n seed =
    if n <= 0 then
        ( [], seed )

    else
        let
            ( a, s1 ) =
                attribute seed

            ( rest, s2 ) =
                attributes (n - 1) s1
        in
        ( a :: rest, s2 )


tree : Int -> Int -> ( Html msg, Int )
tree depth seed =
    let
        ( r, s1 ) =
            next seed
    in
    if depth <= 0 || modBy 5 r == 0 then
        let
            ( t, s2 ) =
                pick texts "" s1
        in
        ( Html.text t, s2 )

    else
        let
            ( tag, s2 ) =
                pick tags "div" s1

            ( attrs, s3 ) =
                attributes (modBy 4 r) s2

            ( kids, s4 ) =
                children (modBy 4 (r // 7)) (depth - 1) s3
        in
        case modBy 7 (r // 11) of
            0 ->
                ( Html.map identity (Html.node tag attrs kids), s4 )

            1 ->
                ( Keyed.node tag attrs (List.indexedMap (\i k -> ( String.fromInt i, k )) kids), s4 )

            2 ->
                ( Lazy.lazy (\t -> Html.node t attrs kids) tag, s4 )

            3 ->
                ( VirtualDom.nodeNS "http://www.w3.org/2000/svg" tag attrs kids, s4 )

            _ ->
                ( Html.node tag attrs kids, s4 )


children : Int -> Int -> Int -> ( List (Html msg), Int )
children n depth seed =
    if n <= 0 then
        ( [], seed )

    else
        let
            ( k, s1 ) =
                tree depth seed

            ( rest, s2 ) =
                children (n - 1) depth s1
        in
        ( k :: rest, s2 )


count : Int -> Int -> Int -> Int
count i seed mismatches =
    if i >= 2000 then
        mismatches

    else
        let
            ( h, s1 ) =
                tree 4 seed

            same =
                Dom.toString h == Dom.render (Dom.fromNode h)
        in
        count (i + 1)
            s1
            (if same then
                mismatches

             else
                mismatches + 1
            )


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.Log.line env.stdout
                    ("trees: 2000\nmismatches: " ++ String.fromInt (count 0 42 0))
                )
        )
