module HtmlApiCoverageTest exposing (main)

{-| References every exposed function of `Html`, `Html.Attributes`,
`Html.Events`, `Html.Keyed` and `Html.Lazy` (elm/html 1.0.0), building one
tree that uses them all (plans/elm-html-native-kernel.md P3). A missing kernel
symbol or an ABI mismatch fails the build (CGEN_038).
-}

-- CHECK: built: <internals>
-- CHECK: decoders: "ok"

import Html exposing (..)
import Html.Attributes as A
import Html.Events as E
import Html.Keyed as Keyed
import Html.Lazy as Lazy
import Json.Decode as D
import Json.Encode as Enc


type Msg
    = Clicked
    | Typed String
    | Checked Bool
    | Code Int


elements : List (List (Attribute Msg) -> List (Html Msg) -> Html Msg)
elements =
    [ h1, h2, h3, h4, h5, h6
    , div, p, hr, pre, blockquote
    , span, a, code, em, strong, i, b, u, sub, sup, br
    , ol, ul, li, dl, dt, dd
    , img, iframe, canvas, math
    , form, input, textarea, button, select, option
    , section, nav, article, aside, header, footer, address, main_
    , figure, figcaption
    , table, caption, colgroup, col, tbody, thead, tfoot, tr, td, th
    , fieldset, legend, label, datalist, optgroup, output, progress, meter
    , audio, video, source, track
    , embed, object, param
    , ins, del
    , small, cite, dfn, abbr, time, var, samp, kbd, s, q
    , mark, ruby, rt, rp, bdi, bdo, wbr
    , details, summary, menuitem, menu
    , node "custom-element"
    ]


attributes : List (Attribute Msg)
attributes =
    [ A.style "color" "red"
    , A.property "foo" (Enc.string "bar")
    , A.attribute "data-x" "y"
    , A.map identity (A.title "mapped")
    , A.class "c"
    , A.classList [ ( "a", True ), ( "b", False ) ]
    , A.id "i"
    , A.title "t"
    , A.hidden False
    , A.type_ "text"
    , A.value "v"
    , A.checked True
    , A.placeholder "p"
    , A.selected False
    , A.accept "image/*"
    , A.acceptCharset "utf-8"
    , A.action "/go"
    , A.autocomplete True
    , A.autofocus False
    , A.disabled False
    , A.enctype "multipart/form-data"
    , A.list "l"
    , A.maxlength 10
    , A.minlength 1
    , A.method "post"
    , A.multiple True
    , A.name "n"
    , A.novalidate True
    , A.pattern "[a-z]+"
    , A.readonly False
    , A.required True
    , A.size 3
    , A.for "f"
    , A.form "fm"
    , A.max "9"
    , A.min "0"
    , A.step "1"
    , A.cols 20
    , A.rows 2
    , A.wrap "soft"
    , A.href "/h"
    , A.target "_blank"
    , A.download "file.txt"
    , A.hreflang "en"
    , A.media "print"
    , A.ping "/ping"
    , A.rel "noopener"
    , A.ismap True
    , A.usemap "#m"
    , A.shape "rect"
    , A.coords "0,0,1,1"
    , A.src "/s.png"
    , A.height 10
    , A.width 20
    , A.alt "alt"
    , A.autoplay False
    , A.controls True
    , A.loop False
    , A.preload "none"
    , A.poster "/p.png"
    , A.default True
    , A.kind "subtitles"
    , A.srclang "en"
    , A.sandbox "allow-scripts"
    , A.srcdoc "<p>doc</p>"
    , A.reversed True
    , A.start 3
    , A.align "left"
    , A.colspan 2
    , A.rowspan 3
    , A.headers "h"
    , A.scope "col"
    , A.accesskey 'k'
    , A.contenteditable True
    , A.contextmenu "menu"
    , A.dir "rtl"
    , A.draggable "true"
    , A.dropzone "copy"
    , A.itemprop "name"
    , A.lang "en"
    , A.spellcheck False
    , A.tabindex 1
    , A.cite "/c"
    , A.datetime "2026-10-08"
    , A.pubdate "2026-10-08"
    , A.manifest "/m"
    ]


events : List (Attribute Msg)
events =
    [ E.onClick Clicked
    , E.onDoubleClick Clicked
    , E.onMouseDown Clicked
    , E.onMouseUp Clicked
    , E.onMouseEnter Clicked
    , E.onMouseLeave Clicked
    , E.onMouseOver Clicked
    , E.onMouseOut Clicked
    , E.onInput Typed
    , E.onCheck Checked
    , E.onSubmit Clicked
    , E.onBlur Clicked
    , E.onFocus Clicked
    , E.on "keydown" (D.map Code E.keyCode)
    , E.stopPropagationOn "click" (D.succeed ( Clicked, True ))
    , E.preventDefaultOn "submit" (D.succeed ( Clicked, True ))
    , E.custom "x" (D.succeed { message = Clicked, stopPropagation = False, preventDefault = False })
    , E.on "input" (D.map Typed E.targetValue)
    , E.on "change" (D.map Checked E.targetChecked)
    ]


tree : Html Msg
tree =
    div (attributes ++ events)
        (List.map (\el -> el [ A.class "x" ] [ text "y" ]) elements
            ++ [ Keyed.node "div" [] [ ( "k1", text "1" ) ]
               , Keyed.ol [] [ ( "k2", li [] [ text "2" ] ) ]
               , Keyed.ul [] [ ( "k3", li [] [ text "3" ] ) ]
               , Html.map identity (text "mapped")
               , Lazy.lazy (\x -> text x) "l1"
               , Lazy.lazy2 (\x y -> text (x ++ y)) "l" "2"
               , Lazy.lazy3 (\x y z -> text (x ++ y ++ z)) "l" "3" ""
               , Lazy.lazy4 (\x y z w -> text (x ++ y ++ z ++ w)) "l" "4" "" ""
               , Lazy.lazy5 (\x y z w v -> text (x ++ y ++ z ++ w ++ v)) "l" "5" "" "" ""
               , Lazy.lazy6 (\x y z w v t -> text (x ++ y ++ z ++ w ++ v ++ t)) "l" "6" "" "" "" ""
               , Lazy.lazy7 (\x y z w v t r -> text (x ++ y ++ z ++ w ++ v ++ t ++ r)) "l" "7" "" "" "" "" ""
               , Lazy.lazy8 (\x y z w v t r q_ -> text (x ++ y ++ z ++ w ++ v ++ t ++ r ++ q_)) "l" "8" "" "" "" "" "" ""
               ]
        )


main =
    let
        _ =
            Debug.log "built" tree

        decoded =
            [ D.decodeString E.targetValue "{\"target\":{\"value\":\"v\"}}" == Ok "v"
            , D.decodeString E.targetChecked "{\"target\":{\"checked\":true}}" == Ok True
            , D.decodeString E.keyCode "{\"keyCode\":13}" == Ok 13
            ]

        _ =
            Debug.log "decoders"
                (if List.all identity decoded then
                    "ok"

                 else
                    "bad"
                )
    in
    tree
