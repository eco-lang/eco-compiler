module HtmlIssue215TextareaTypeOnPatchTest exposing (main)

{-| Adding `type_` to an existing `textarea` throws when the view is patched.

<https://github.com/elm/html/issues/215>

The second variant in the issue: the first view renders a plain `textarea`, and the next one
adds `type_ "text"`. A `<textarea>`'s `type` property has only a getter, so the patch throws
(Elm's code is strict). Elm 0.19.1 (elm/virtual-dom 1.0.5) crashes rendering step 1, so step 2
is never reached; the program should keep running.

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
    if step == 0 then
        Html.textarea [] []

    else
        Html.textarea [ type_ "text" ] []


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
