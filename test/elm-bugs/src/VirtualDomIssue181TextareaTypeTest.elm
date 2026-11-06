module VirtualDomIssue181TextareaTypeTest exposing (main)

{-| `type_` on a `textarea` throws at run time.

<https://github.com/elm/virtual-dom/issues/181>
<https://github.com/elm/compiler/issues/2245>

A `<textarea>`'s `type` property has only a getter, and elm/virtual-dom sets `type_` as a
property, so rendering `textarea [ type_ "text" ] []` throws "Cannot set property type of
#<HTMLTextAreaElement> which has only a getter" (Elm's code is strict). Elm 0.19.1
(elm/virtual-dom 1.0.5) crashes on the first render, so no step is reached; the program should
keep running.

-}

-- CHECK: step: 1
-- CHECK: step: 2

import Browser
import Html exposing (Html)
import Html.Attributes exposing (class, type_)
import Process
import Task


{-| Renders the same `textarea`, with `type_` set, at every step.
-}
view : Int -> Html Int
view step =
    Html.textarea [ type_ "text", class "hello" ] []


{-| Sends `step + 1` as the next message after a 50 ms sleep.
-}
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
