module DomGoldenTest exposing (main)

{-| The serializer goldens (plans/elm-html-native-kernel.md Appendix D.1), checked
through both serializers: `Http.Dom.toString` (natively the C++ HtmlWriter) and
`Http.Dom.render << Http.Dom.fromNode` (the Elm reference). Every case has at
most one attribute whose order could matter, so the JS target gives the same
text (D16). Cases 14-16 also accept the replacement text of elm/virtual-dom's
DEV-mode filters, which the JS test runner uses; native follows PROD (D10).
-}

-- CHECK: 1: a&lt;b&gt;&amp;&quot;&#039;
-- CHECK-NEXT: 1 ref: a&lt;b&gt;&amp;&quot;&#039;
-- CHECK: 2: <div></div>
-- CHECK-NEXT: 2 ref: <div></div>
-- CHECK: 3: <div id="x" class="a b">hi</div>
-- CHECK-NEXT: 3 ref: <div id="x" class="a b">hi</div>
-- CHECK: 4: <div class="b"></div>
-- CHECK-NEXT: 4 ref: <div class="b"></div>
-- CHECK: 5: <div class="a"></div>
-- CHECK-NEXT: 5 ref: <div class="a"></div>
-- CHECK: 6: <input type="checkbox" checked>
-- CHECK-NEXT: 6 ref: <input type="checkbox" checked>
-- CHECK: 7: <br>
-- CHECK-NEXT: 7 ref: <br>
-- CHECK: 8: <div style="color:green;background-color:blue;"></div>
-- CHECK-NEXT: 8 ref: <div style="color:green;background-color:blue;"></div>
-- CHECK: 9: <div style="margin: 0;color:red;"></div>
-- CHECK-NEXT: 9 ref: <div style="margin: 0;color:red;"></div>
-- CHECK: 10: <div style="margin: 0"></div>
-- CHECK-NEXT: 10 ref: <div style="margin: 0"></div>
-- CHECK: 11: <style>a > b {}<\/style><script></style>
-- CHECK-NEXT: 11 ref: <style>a > b {}<\/style><script></style>
-- CHECK: 12: <p>x</p>
-- CHECK-NEXT: 12 ref: <p>x</p>
-- CHECK: 13: <div data-onclick="alert(1)"></div>
-- CHECK-NEXT: 13 ref: <div data-onclick="alert(1)"></div>
-- CHECK: 14: <a href="{{(javascript:alert\(&quot;This is an XSS vector\. Please use ports or web components instead\.&quot;\))?}}">x</a>
-- CHECK-NEXT: 14 ref: <a href="{{(javascript:alert\(&quot;This is an XSS vector\. Please use ports or web components instead\.&quot;\))?}}">x</a>
-- CHECK: 15: <a href="{{(javascript:alert\(&quot;This is an XSS vector\. Please use ports or web components instead\.&quot;\))?}}"></a>
-- CHECK-NEXT: 15 ref: <a href="{{(javascript:alert\(&quot;This is an XSS vector\. Please use ports or web components instead\.&quot;\))?}}"></a>
-- CHECK: 16: <iframe src="{{(javascript:alert\(&quot;This is an XSS vector\. Please use ports or web components instead\.&quot;\))?}}"></iframe>
-- CHECK-NEXT: 16 ref: <iframe src="{{(javascript:alert\(&quot;This is an XSS vector\. Please use ports or web components instead\.&quot;\))?}}"></iframe>
-- CHECK: 17: <div></div>
-- CHECK-NEXT: 17 ref: <div></div>
-- CHECK: 18: x
-- CHECK-NEXT: 18 ref: x
-- CHECK: 19: x
-- CHECK-NEXT: 19 ref: x
-- CHECK: 20: <div data-ok="1"></div>
-- CHECK-NEXT: 20 ref: <div data-ok="1"></div>
-- CHECK: 21: <my-widget aria-label="q&quot;&lt;"></my-widget>
-- CHECK-NEXT: 21 ref: <my-widget aria-label="q&quot;&lt;"></my-widget>
-- CHECK: 22: <div tabindex="2"></div>
-- CHECK-NEXT: 22 ref: <div tabindex="2"></div>
-- CHECK: 23: <ul><li>1</li></ul>
-- CHECK-NEXT: 23 ref: <ul><li>1</li></ul>
-- CHECK: 24: <textarea>a&lt;b</textarea>
-- CHECK-NEXT: 24 ref: <textarea>a&lt;b</textarea>
-- CHECK: 25: <select><option value="a"></option><option value="b"></option></select>
-- CHECK-NEXT: 25 ref: <select><option value="a"></option><option value="b"></option></select>
-- CHECK: 26: <svg viewBox="0 0 10 10"><use xlink:href="#a"></use></svg>
-- CHECK-NEXT: 26 ref: <svg viewBox="0 0 10 10"><use xlink:href="#a"></use></svg>
-- CHECK: 27: <div id="e"></div>
-- CHECK-NEXT: 27 ref: <div id="e"></div>
-- CHECK: 28: 5
-- CHECK-NEXT: 28 ref: 5
-- CHECK: 29: <div title="3"></div>
-- CHECK-NEXT: 29 ref: <div title="3"></div>
-- CHECK: 30: x
-- CHECK-NEXT: 30 ref: x
-- CHECK: 31: <div contenteditable="true" spellcheck="false"></div>
-- CHECK-NEXT: 31 ref: <div contenteditable="true" spellcheck="false"></div>
-- CHECK: 32: <input autocomplete="off">
-- CHECK-NEXT: 32 ref: <input autocomplete="off">
-- CHECK: 33: <div class="a c"></div>
-- CHECK-NEXT: 33 ref: <div class="a c"></div>
-- CHECK: 34: <div class="a b"></div>
-- CHECK-NEXT: 34 ref: <div class="a b"></div>
-- CHECK: 35: <html><body>x</body></html>
-- CHECK-NEXT: 35 ref: <html><body>x</body></html>
-- EXIT: 0

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events as Events
import Html.Keyed as Keyed
import Html.Lazy as Lazy
import Http.Dom as Dom
import Json.Encode as Encode
import Stream.Log
import System
import VirtualDom


svgNode : String -> List (Attribute msg) -> List (Html msg) -> Html msg
svgNode =
    VirtualDom.nodeNS "http://www.w3.org/2000/svg"


cases : List ( Int, Html () )
cases =
    [ ( 1, text "a<b>&\"'" )
    , ( 2, div [] [] )
    , ( 3, div [ id "x", class "a", class "b" ] [ text "hi" ] )
    , ( 4, div [ class "a", attribute "class" "b" ] [] )
    , ( 5, div [ attribute "class" "b", class "a" ] [] )
    , ( 6, input [ type_ "checkbox", checked True, disabled False ] [] )
    , ( 7, br [] [ text "x" ] )
    , ( 8, div [ style "color" "red", style "backgroundColor" "blue", style "color" "green" ] [] )
    , ( 9, div [ attribute "style" "margin: 0", style "color" "red" ] [] )
    , ( 10, div [ style "color" "red", attribute "style" "margin: 0" ] [] )
    , ( 11, node "style" [] [ text "a > b {}</style><script>" ] )
    , ( 12, node "script" [] [ text "x" ] )
    , ( 13, div [ attribute "onclick" "alert(1)" ] [] )
    , ( 14, a [ href "javascript:alert(1)" ] [ text "x" ] )
    , ( 15, a [ href "\tjava\tSCRIPT:alert(1)" ] [] )
    , ( 16, iframe [ src "data:text/html,<b>" ] [] )
    , ( 17, div [ property "innerHTML" (Encode.string "<b>") ] [] )
    , ( 18, node "div onclick=alert(1)" [] [ text "x" ] )
    , ( 19, node "script " [] [ text "x" ] )
    , ( 20, div [ attribute "x onclick" "y", attribute "a=b" "z", attribute "data-ok" "1" ] [] )
    , ( 21, node "my-widget" [ attribute "aria-label" "q\"<" ] [] )
    , ( 22, div [ attribute "tabIndex" "1", attribute "TABINDEX" "2" ] [] )
    , ( 23, Html.map identity (Keyed.ul [] [ ( "a", li [] [ text "1" ] ) ]) )
    , ( 24, textarea [ value "a<b" ] [ text "ignored" ] )
    , ( 25, select [ value "b" ] [ option [ value "a" ] [], option [ value "b" ] [] ] )
    , ( 26, svgNode "svg" [ VirtualDom.attribute "viewBox" "0 0 10 10" ] [ svgNode "use" [ VirtualDom.attributeNS "http://www.w3.org/1999/xlink" "xlink:href" "#a" ] [] ] )
    , ( 27, div [ Events.onClick (), id "e" ] [] )
    , ( 28, Lazy.lazy (\n -> text (String.fromInt n)) 5 )
    , ( 29, div [ property "title" (Encode.int 3), property "foo" (Encode.string "x") ] [] )
    , ( 30, node "" [] [ text "x" ] )
    , ( 31, div [ contenteditable True, spellcheck False ] [] )
    , ( 32, input [ autocomplete False ] [] )
    , ( 33, div [ classList [ ( "a", True ), ( "b", False ), ( "c", True ) ] ] [] )
    , ( 34, div [ attribute "class" "a", attribute "class" "b" ] [] )
    , ( 35, node "html" [] [ node "body" [] [ text "x" ] ] )
    ]


lines : List String
lines =
    List.concatMap
        (\( n, h ) ->
            [ String.fromInt n ++ ": " ++ Dom.toString h
            , String.fromInt n ++ " ref: " ++ Dom.render (Dom.fromNode h)
            ]
        )
        cases


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env -> System.endSimpleProgram (Stream.Log.line env.stdout (String.join "\n" lines)))
