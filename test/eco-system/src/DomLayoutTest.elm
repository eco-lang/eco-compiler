module DomLayoutTest exposing (main)

{-| `Http.Dom.fromNode` / `fromAttribute` see every `Node` and `Fact` shape
that `Html`, `Html.Keyed`, `Html.map`, `Html.Attributes` and `VirtualDom.nodeNS`
build (plans/elm-html-native-kernel.md P5, VDOM_001). Natively this pins the
heap layout of the VirtualDom kernel to the `Http.Dom` declaration; on JS it
pins the twin's calibration of VirtualDom's objects.
-}

-- CHECK: node: Text "hello"
-- CHECK-NEXT: node: Element - div facts=1 kids=[Text "a", Text "b"]
-- CHECK-NEXT: node: Element http://www.w3.org/2000/svg svg facts=1 kids=[Element http://www.w3.org/2000/svg use facts=1 kids=[]]
-- CHECK-NEXT: node: KeyedElement - ul facts=0 keys=[k1, k2] kids=[Element - li facts=0 kids=[Text "1"], Text "2"]
-- CHECK-NEXT: node: Mapped (Element - p facts=0 kids=[Text "m"])
-- CHECK-NEXT: node: Text "lazy 7"
-- CHECK-NEXT: fact: Attribute data-x=y
-- CHECK-NEXT: fact: AttributeNS http://www.w3.org/1999/xlink xlink:href=#a
-- CHECK-NEXT: fact: Property className "c"
-- CHECK-NEXT: fact: Property checked true
-- CHECK-NEXT: fact: Property tabIndex 3
-- CHECK-NEXT: fact: Style color=red
-- CHECK-NEXT: fact: Event click
-- CHECK-NEXT: fact: Event input
-- CHECK-NEXT: fact: Attribute data-onclick=x
-- CHECK-NEXT: fact: Property data-innerHTML "<b>"
-- EXIT: 0

import Html exposing (Html)
import Html.Attributes as A
import Html.Events as E
import Html.Keyed as Keyed
import Html.Lazy as Lazy
import Http.Dom as Dom exposing (Fact(..), Node(..))
import Json.Encode as Encode
import Stream.Log
import System
import VirtualDom


svgNs : String
svgNs =
    "http://www.w3.org/2000/svg"


nodes : List (Html ())
nodes =
    [ Html.text "hello"
    , Html.div [ A.id "d" ] [ Html.text "a", Html.text "b" ]
    , VirtualDom.nodeNS svgNs
        "svg"
        [ VirtualDom.attribute "viewBox" "0 0 1 1" ]
        [ VirtualDom.nodeNS svgNs "use" [ VirtualDom.attributeNS "http://www.w3.org/1999/xlink" "xlink:href" "#a" ] [] ]
    , Keyed.ul [] [ ( "k1", Html.li [] [ Html.text "1" ] ), ( "k2", Html.text "2" ) ]
    , Html.map identity (Html.p [] [ Html.text "m" ])
    , Lazy.lazy (\n -> Html.text ("lazy " ++ String.fromInt n)) 7
    ]


facts : List (Html.Attribute ())
facts =
    [ A.attribute "data-x" "y"
    , VirtualDom.attributeNS "http://www.w3.org/1999/xlink" "xlink:href" "#a"
    , A.class "c"
    , A.checked True
    , A.property "tabIndex" (Encode.int 3)
    , A.style "color" "red"
    , E.onClick ()
    , A.map identity (E.onInput (\_ -> ()))
    , A.attribute "onclick" "x"
    , A.property "innerHTML" (Encode.string "<b>")
    ]


maybeNs : Maybe String -> String
maybeNs ns =
    Maybe.withDefault "-" ns


describe : Node -> String
describe node =
    case node of
        Text s ->
            "Text \"" ++ s ++ "\""

        Element ns tag fs kids ->
            "Element " ++ maybeNs ns ++ " " ++ tag ++ " facts=" ++ String.fromInt (List.length fs) ++ " kids=" ++ list (List.map describe kids)

        KeyedElement ns tag fs kids ->
            "KeyedElement "
                ++ maybeNs ns
                ++ " "
                ++ tag
                ++ " facts="
                ++ String.fromInt (List.length fs)
                ++ " keys="
                ++ list (List.map Tuple.first kids)
                ++ " kids="
                ++ list (List.map (describe << Tuple.second) kids)

        Mapped _ inner ->
            "Mapped (" ++ describe inner ++ ")"


describeFact : Fact -> String
describeFact fact =
    case fact of
        Attribute k v ->
            "Attribute " ++ k ++ "=" ++ v

        AttributeNS ns k v ->
            "AttributeNS " ++ ns ++ " " ++ k ++ "=" ++ v

        Property k v ->
            "Property " ++ k ++ " " ++ Encode.encode 0 v

        Style k v ->
            "Style " ++ k ++ "=" ++ v

        Event name _ _ ->
            "Event " ++ name


list : List String -> String
list items =
    "[" ++ String.join ", " items ++ "]"


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.Log.line env.stdout
                    (String.join "\n"
                        (List.map (\n -> "node: " ++ describe (Dom.fromNode n)) nodes
                            ++ List.map (\f -> "fact: " ++ describeFact (Dom.fromAttribute f)) facts
                        )
                    )
                )
        )
