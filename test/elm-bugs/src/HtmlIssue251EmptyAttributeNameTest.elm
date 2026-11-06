module HtmlIssue251EmptyAttributeNameTest exposing (main)

{-| `Html.Attributes.attribute ""` throws at run time.

<https://github.com/elm/html/issues/251>

elm/virtual-dom passes the name to `setAttribute`, which throws an InvalidCharacterError for a
name that is not a valid attribute name, such as the empty string. Elm 0.19.1
(elm/virtual-dom 1.0.5) crashes on the first render, so no step is reached; the program should
keep running.

-}

-- CHECK: step: 1
-- CHECK: step: 2

import Browser
import Html exposing (Html)
import Html.Attributes exposing (attribute)
import Process
import Task


view : Int -> Html Int
view step =
    Html.div [ attribute "" "x" ] []


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
