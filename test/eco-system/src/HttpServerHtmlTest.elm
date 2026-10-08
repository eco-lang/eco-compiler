module HttpServerHtmlTest exposing (main)

{-| `Http.Server.Response.setBodyAsHtml` (plans/elm-html-native-kernel.md P6,
D13, D15): the page is serialized as it is sent, `<!DOCTYPE html>` comes first
only when the root element is `html` (seen through `Html.map`), and
`Content-Type: text/html; charset=utf-8` is added unless the response already
has a Content-Type.
-}

-- CHECK: server: /page
-- CHECK-NEXT: server: /xhtml
-- CHECK-NEXT: server: /frag
-- CHECK-NEXT: server: /mapped
-- CHECK-NEXT: client: 200 text/html; charset=utf-8 <!DOCTYPE html><html><body>x</body></html>
-- CHECK-NEXT: client: 200 application/xhtml+xml <div>y</div>
-- CHECK-NEXT: client: 200 text/html; charset=utf-8 <p>&lt;z&gt;</p>
-- CHECK-NEXT: client: 200 text/html; charset=utf-8 <!DOCTYPE html><HTML lang="en"><head><title>t</title></head></HTML>
-- EXIT: 0

import Html exposing (div, node, p, text)
import Html.Attributes exposing (lang)
import Http.Server.Response as Response
import HttpServerTestHelp as Help
import Task


handler : Help.Handler
handler request response =
    let
        path =
            request.url.path

        reply =
            case path of
                "/page" ->
                    response
                        |> Response.setBodyAsHtml (node "html" [] [ node "body" [] [ text "x" ] ])

                "/xhtml" ->
                    response
                        |> Response.setHeader "Content-Type" "application/xhtml+xml"
                        |> Response.setBodyAsHtml (div [] [ text "y" ])

                "/frag" ->
                    response
                        |> Response.setBodyAsHtml (Html.map identity (p [] [ text "<z>" ]))

                _ ->
                    response
                        |> Response.setBodyAsHtml
                            (Html.map identity
                                (node "HTML" [ lang "en" ] [ node "head" [] [ node "title" [] [ text "t" ] ] ])
                            )
    in
    ( [ path ], reply )


client : String -> Task.Task Never (List String)
client base =
    Help.get (base ++ "/page")
        |> Task.andThen
            (\a ->
                Help.get (base ++ "/xhtml")
                    |> Task.andThen
                        (\b ->
                            Help.get (base ++ "/frag")
                                |> Task.andThen
                                    (\c ->
                                        Help.get (base ++ "/mapped")
                                            |> Task.map (\d -> [ a, b, c, d ])
                                    )
                        )
            )


main =
    Help.program { handler = handler, client = client }
