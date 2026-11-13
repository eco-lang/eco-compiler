module Evg.Performance exposing
    ( lazy, lazy2, lazy3
    , asDef
    )

{-| Tools for optimizing rendering performance.

Most of the time you won't need these, since the default rendering is fast
enough for typical use. Reach for this module when you have:

  - A very large number of repeated shapes (hundreds or thousands)
  - Complex shapes that are identical in structure (only position changes)
  - Heavy computations producing shapes that rarely change


# Lazy Evaluation

On every update Elm re-runs your view and works out what changed. `lazy`
skips that work for a shape whose inputs haven't changed since last time: if
the arguments are the same values as before, the previous result is reused
without re-rendering anything.

@docs lazy, lazy2, lazy3


# Reusable Definitions

Draw a complex shape once, then stamp out cheap copies of it wherever you
need them.

@docs asDef

-}

import Evg
import Evg.Internal as Internal exposing (Def(..), Evg)
import Svg
import Svg.Attributes
import VirtualDom


{-| Skips re-rendering the shape when the argument is unchanged since the
last update. Works like `Html.Lazy.lazy` but for `Evg` graphics, and comes
with the same caveats: both the function and the argument are compared by
reference, so pass a top-level function (not a lambda) and a value straight
out of your model rather than a record or list built fresh on every call.

The first argument is a name for this piece of the drawing, unique within
your whole scene. The library cannot look inside a lazy shape without
defeating its purpose, so the name stands in for the content when the
library needs to tell shapes apart (for example when a lazy shape is used
as a clip stencil). Two different lazy shapes with the same name can get
mixed up, so name them uniquely.

    Evg.Performance.lazy "sales-chart"
        viewExpensiveChart
        model.chartData

-}
lazy : String -> (a -> Evg msg) -> a -> Evg msg
lazy key fn a =
    Internal.Evg
        { content =
            Internal.RawLazy (VirtualDom.lazy2 renderLazy fn a)
                (\() -> fn a)
        , ownMatrix = Internal.identityMat
        , children = []
        , hash = Internal.hashStringToInt key
        , defs = []
        , attrs = []
        }


{-| Like [`lazy`](#lazy) but checks two arguments.
-}
lazy2 : String -> (a -> b -> Evg msg) -> a -> b -> Evg msg
lazy2 key fn a b =
    Internal.Evg
        { content =
            Internal.RawLazy (VirtualDom.lazy3 renderLazy2 fn a b)
                (\() -> fn a b)
        , ownMatrix = Internal.identityMat
        , children = []
        , hash = Internal.hashStringToInt key
        , defs = []
        , attrs = []
        }


{-| Like [`lazy`](#lazy) but checks three arguments.
-}
lazy3 : String -> (a -> b -> c -> Evg msg) -> a -> b -> c -> Evg msg
lazy3 key fn a b c =
    Internal.Evg
        { content =
            Internal.RawLazy (VirtualDom.lazy4 renderLazy3 fn a b c)
                (\() -> fn a b c)
        , ownMatrix = Internal.identityMat
        , children = []
        , hash = Internal.hashStringToInt key
        , defs = []
        , attrs = []
        }


{-| Turns a shape into a reusable definition. Returns a function that stamps
out lightweight copies, working just like the shape constructors in `Evg`:
it takes a list of attributes and then the position and size of the copy.

This is useful when you have the same complex shape repeated many times. The
shape is drawn once as a hidden definition, and each visible copy is just a
cheap reference to it, so the browser does the expensive work only once. The
definition itself travels with the copies, so simply placing the stamped
shapes in your scene is enough.

    useIcon =
        Evg.Performance.asDef myComplexIcon

    scene =
        Evg.svg []
            { width = 200, height = 200 }
            [ useIcon []
                { x = 10
                , y = 10
                , width = 24
                , height = 24
                }
            , useIcon [ Evg.opacity 0.5 ]
                { x = 50
                , y = 10
                , width = 24
                , height = 24
                }
            ]

Attributes vary each copy individually: fade one out with `opacity`, listen
for clicks with an event handler, or move it with a transform.

Colors work by ordinary inheritance: `fill` and `stroke` set on a copy flow
into the parts of the original shape that left those unset, while parts
that picked explicit colors keep them. So if you design the original
without colors, every stamp can be tinted differently; if you color the
original fully, stamps always look identical.

(There is also an explicit opt-in mechanism: parts of the original painted
with `Evg.Paint.contextFill` or `contextStroke` take their color from the
copy even alongside other explicit colors. Be aware that browser support
for context colors on copies is uneven; they are reliable for markers, less
so here.)

-}
asDef :
    Evg.Evg msg
    ->
        (List (Evg.Attribute { fill : Evg.Supported, stroke : Evg.Supported, opacity : Evg.Supported, filter : Evg.Supported, transform : Evg.Supported, events : Evg.Supported } msg)
         -> { x : Float, y : Float, width : Float, height : Float }
         -> Evg msg
        )
asDef evg =
    let
        id =
            "sym-" ++ Internal.contentHash evg

        def =
            Def id
                (Internal.element "symbol"
                    (Internal.hashStringToInt id)
                    [ Svg.Attributes.id id ]
                    []
                    Internal.identityMat
                    [ ( "id", id ) ]
                    [ evg ]
                    []
                )
    in
    \attrs rect ->
        let
            { vdomAttrs, eventBuilders, ownMatrix, defs, inspectable } =
                Internal.svgAttributes attrs

            baseAttrs =
                [ Svg.Attributes.xlinkHref ("#" ++ id)
                , Svg.Attributes.x (String.fromFloat rect.x)
                , Svg.Attributes.y (String.fromFloat rect.y)
                , Svg.Attributes.width (String.fromFloat rect.width)
                , Svg.Attributes.height (String.fromFloat rect.height)
                ]

            hash =
                Internal.hashStringToInt id
                    |> Internal.mixInt (Internal.attrHash attrs)
                    |> Internal.mixFloat rect.x
                    |> Internal.mixFloat rect.y
                    |> Internal.mixFloat rect.width
                    |> Internal.mixFloat rect.height
        in
        Internal.element "use"
            hash
            (baseAttrs ++ vdomAttrs)
            eventBuilders
            ownMatrix
            inspectable
            []
            (def :: defs)



-- Internal


renderLazy : (a -> Evg msg) -> a -> VirtualDom.Node msg
renderLazy fn a =
    renderWithDefs (fn a)


renderLazy2 : (a -> b -> Evg msg) -> a -> b -> VirtualDom.Node msg
renderLazy2 fn a b =
    renderWithDefs (fn a b)


renderLazy3 : (a -> b -> c -> Evg msg) -> a -> b -> c -> VirtualDom.Node msg
renderLazy3 fn a b c =
    renderWithDefs (fn a b c)


{-| The root svg collects defs (gradients, clip paths, and so on) by walking
the tree, but it cannot see through a lazy boundary without defeating the
point of laziness. So each lazy subtree renders its own defs locally instead.
SVG ids work document-wide, so references resolve no matter where the defs
sit, and identically-named duplicates are content-identical by construction.
-}
renderWithDefs : Evg msg -> VirtualDom.Node msg
renderWithDefs ((Internal.Evg { defs }) as evg) =
    case defs of
        [] ->
            Internal.toNode evg

        _ ->
            Svg.g [] [ Internal.renderDefs defs, Internal.toNode evg ]
