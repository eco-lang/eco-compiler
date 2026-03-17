module Styles exposing (cssContent, file, general, modulePage, overview, page)

import Html.String as Html exposing (Html)
import Html.String.Attributes as Attr
import Html.String.Extra as Html
import Service


page : String -> Service.Version -> Int -> List (Html msg) -> Html msg
page title version depth content =
    let
        cssPath =
            String.repeat depth "../" ++ "styles.css"
    in
    Html.html []
        [ Html.head []
            [ Html.node "link" [ Attr.rel "stylesheet", Attr.href cssPath ] []
            , Html.node "meta" [ Attr.attribute "charset" "UTF-8" ] []
            ]
        , Html.node "body" []
            [ Html.header [] [ Html.h1 [ Attr.id "top" ] [ Html.text title ] ]
            , Html.section [] content
            , Html.footer []
                [ Html.text "Generated with "
                , Html.a [ Attr.href "https://github.com/zwilias/elm-coverage" ] [ Html.text "elm-coverage" ]
                , Html.text <| "@" ++ version
                ]
            ]
        ]


{-| Create a standalone page for a single module.
The depth parameter indicates how many directory levels deep the module is,
used to compute the relative path back to the overview and CSS.
-}
modulePage : String -> Service.Version -> Int -> List (Html msg) -> Html msg
modulePage title version depth content =
    let
        cssPath =
            String.repeat depth "../" ++ "styles.css"

        backLink =
            String.repeat depth "../" ++ "coverage.html"
    in
    Html.html []
        [ Html.head []
            [ Html.node "link" [ Attr.rel "stylesheet", Attr.href cssPath ] []
            , Html.node "meta" [ Attr.attribute "charset" "UTF-8" ] []
            ]
        , Html.node "body" []
            [ Html.header []
                [ Html.a [ Attr.href backLink, Attr.class "b" ] [ Html.text "← Back to overview" ]
                , Html.h1 [ Attr.id "top" ] [ Html.text title ]
                ]
            , Html.section [] content
            , Html.footer []
                [ Html.text "Generated with "
                , Html.a [ Attr.href "https://github.com/zwilias/elm-coverage" ] [ Html.text "elm-coverage" ]
                , Html.text <| "@" ++ version
                ]
            ]
        ]


{-| Complete minified CSS content for the external stylesheet.
Class name mapping:
  c=coverage, v=covered, u=uncovered, b=back-link, i=indicator,
  l=lines, s=source, o=overview, w=wrapper, t=toTop, g=legend,
  f=file, n=line, x=none, nf=info, i0-i10=opacity levels
-}
cssContent : String
cssContent =
    general ++ file ++ overview


general : String
general =
    "@import url(https://fonts.googleapis.com/css?family=Fira+Sans);@font-face{font-family:'Fira Code';src:local('Fira Code'),local('FiraCode'),url(https://cdn.rawgit.com/tonsky/FiraCode/master/distr/ttf/FiraCode-Regular.ttf)}code{font-family:\"Fira Code\",monospace;font-size:.9em}body{margin:0 30px;color:#333;font-family:\"Fira Sans\",sans-serif;background-color:#fdfdfd;font-size:16px}footer{margin:1em;text-align:center;font-size:.8em}a{font-weight:normal}.b{display:block;margin-bottom:.5em;font-size:.9em}"


file : String
file =
    ".t{float:right;text-decoration:none}.c{font-family:\"Fira Code\",monospace;font-size:.8em;white-space:pre;line-height:1.2rem;background-color:#fdfdfd;padding:1em .4em;border:1px solid #D0D0D0;border-radius:.5em;display:flex;flex-direction:row;padding-left:0}.s .v{background-color:#aef5ae;color:#202020;box-shadow:0 0 0 2px #aef5ae;border-bottom:1px solid #aef5ae}.s .u{background-color:rgb(255,30,30);color:#fff;box-shadow:0 0 0 2px rgb(255,30,30);border-bottom-width:1px;border-bottom-style:dashed}.s .v>.v{box-shadow:none;background-color:initial;border-bottom:none}.s .u>.u{box-shadow:none;border-bottom:none;background-color:initial}.s .u .v{background-color:transparent;color:inherit;box-shadow:none}.l{text-align:right;margin-right:10px;border-right:1px solid #d0d0d0;padding-right:10px;margin-top:-1em;padding-top:1em;padding-bottom:1em;margin-bottom:-1em}.l .n{display:block;color:#c0c0c0;text-decoration:none;transition:all .3s ease;font-size:.9em;line-height:1.2rem}.l .n:hover{color:#303030}.s{flex:1;overflow:scroll}.g{text-align:center;font-size:.9em;margin-bottom:2em}.i{display:inline-block;float:left;background-color:rgb(255,30,30)}.i0{opacity:0}.i1{opacity:.1}.i2{opacity:.2}.i3{opacity:.3}.i4{opacity:.4}.i5{opacity:.5}.i6{opacity:.6}.i7{opacity:.7}.i8{opacity:.8}.i9{opacity:.9}.i10{opacity:1}"


overview : String
overview =
    ".o{width:100%;padding:0 30px;border:1px solid #d0d0d0;border-radius:.5em;table-layout:fixed}.o thead{text-align:center}.o thead tr,.o tfoot tr{height:3em}.o tbody th,.o tfoot th{text-align:right;text-overflow:ellipsis;overflow:hidden;direction:rtl}.o .w{display:flex}.o .x{text-align:center;color:#606060;font-size:.8em}.o progress{flex:1.5;display:none}@media only screen and (min-width:960px){.o progress{display:block}}.o .nf{flex:1;text-align:right;margin:0 1em}"
