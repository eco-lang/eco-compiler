module VirtualDomIssue110LazyRootRedrawTest exposing (main)

{-| A top-level `Html.Lazy.lazy` view whose root node is redrawn loses track of the root DOM node.

<https://github.com/elm/virtual-dom/issues/110>

When the view is `lazy f model` and `f` changes the root element (here `h4` to `div`), the
thunk patch never gets a DOM node in `_VirtualDom_addDomNodes`, so `_VirtualDom_applyPatchesHelp`
does not return the new root node. `Browser.element` keeps patching the old, detached `h4`, and
the next patch that touches a child crashes. Elm 0.19.1 (elm/virtual-dom 1.0.5) throws a
TypeError while rendering step 2, so step 3 is never reached; it should render every step.

-}

-- CHECK: step: 1
-- CHECK: step: 2
-- CHECK: step: 3

import Browser
import Html exposing (Html)
import Html.Lazy
import Process
import Task


view : Int -> Html Int
view step =
    case step of
        0 ->
            Html.h4 [] []

        1 ->
            Html.div [] [ Html.span [] [ Html.span [] [] ] ]

        _ ->
            Html.div [] [ Html.span [] [ Html.span [] [], Html.span [] [] ] ]


next : Int -> Cmd Int
next step =
    Task.perform (\_ -> step + 1) (Process.sleep 50)


main : Program () Int Int
main =
    Browser.element
        { init = \_ -> ( 0, next 0 )
        , view = Html.Lazy.lazy view
        , update =
            \step _ ->
                ( Debug.log "step" step
                , if step < 3 then
                    next step

                  else
                    Cmd.none
                )
        , subscriptions = \_ -> Sub.none
        }
