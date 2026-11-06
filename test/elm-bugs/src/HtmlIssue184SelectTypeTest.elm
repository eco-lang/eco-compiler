module HtmlIssue184SelectTypeTest exposing (main)

{-| `type_` on a `select` throws at run time.

<https://github.com/elm/html/issues/184>
<https://github.com/elm/virtual-dom/issues/106>

A `<select>`'s `type` property has only a getter, and elm/virtual-dom sets `type_` as a
property, so rendering `select [ type_ "text" ] []` throws "Cannot assign to read only property
'type'" (Elm's code is strict). Elm 0.19.1 (elm/virtual-dom 1.0.5) crashes on the first render,
so no step is reached; the program should keep running.

-}

-- CHECK: step: 1
-- CHECK: step: 2

import Browser
import Html exposing (Html)
import Html.Attributes exposing (type_)
import Process
import Task


view : Int -> Html Int
view step =
    Html.select [ type_ "text" ] []


next : Int -> Cmd Int
next step =
    Task.perform (\_ -> step + 1) (Process.sleep 50)


main : Program () Int Int
main =
    Browser.element
        { init = \_ -> ( 0, next 0 )
        , view = view
        , update =
            \step _ ->
                ( Debug.log "step" step
                , if step < 2 then
                    next step

                  else
                    Cmd.none
                )
        , subscriptions = \_ -> Sub.none
        }
