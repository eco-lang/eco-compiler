module Evg.Internal.Layered exposing
    ( Frame
    , Layered
    , addOverlay
    , blend
    , blendMany
    , floatLayer
    , fromEvg
    , keyAttribute
    , locate
    , locateFrame
    , position
    , toEvg
    , transplant
    , zAttribute
    )

{-| The representation `Evg.Drag` uses to blend drawings.

A drawing is split into **layers**: every element carrying a drag key
becomes its own layer, lifted out of its parent and remembered together with
everything it inherited from its ancestors (their combined transform,
inheritable presentation attributes such as `fill`, and the product of their
opacities). The rest of the drawing stays in the unkeyed root layer.

Lifting keyed elements out is what lets an element move between parents
during a blend: a card that sits in one pile in the first state and in another
pile in the second is the same layer in both, so it glides from one to the
other instead of disappearing and reappearing.

Layers are drawn in order of their stacking path (nested layers above their
parents, `zIndex` to adjust) and then document order. They are emitted as a
keyed list, so reordering layers moves DOM nodes rather than repainting them.

-}

import Dict exposing (Dict)
import Evg.Internal as Internal exposing (Def(..), Evg(..), Mat23)
import Evg.Internal.Lerp as Lerp
import Set exposing (Set)
import VirtualDom


{-| The inspectable attribute that carries an element's drag key.
-}
keyAttribute : String
keyAttribute =
    "data-drag-key"


{-| The inspectable attribute that carries an element's z-index.
-}
zAttribute : String
zAttribute =
    "data-drag-z"


type Node msg
    = Element (ElementData msg)
    | Text String
    | Opaque (Evg msg)


type alias ElementData msg =
    { tag : String
    , attrs : List ( String, String )
    , transform : String
    , matrix : Mat23

    -- The original prebaked attributes. Dropped (`Nothing`) as soon as the
    -- element's own attributes are blended, after which they are regenerated
    -- from `attrs`.
    , vdom : Maybe (List (VirtualDom.Attribute msg))
    , events : List (Mat23 -> VirtualDom.Attribute msg)
    , children : List (Node msg)

    -- The content hash of the original subtree, or 0 once blended. Equal
    -- non-zero hashes mean identical subtrees, which blending skips.
    , hash : Int
    }


type alias Layer msg =
    { parentTransform : String
    , parentMatrix : Mat23
    , inherited : List ( String, String )
    , opacity : Float
    , node : Node msg
    , z : List Int
    , order : Int

    -- Keys of the enclosing layers, nearest first.
    , ancestors : List String

    -- A pinned layer follows the pointer exactly, so transitions don't
    -- smooth it out.
    , pinned : Bool
    }


type alias Layered msg =
    { layers : Dict String (Layer msg)
    , defs : List (Def msg)
    }


empty : Layered msg
empty =
    { layers = Dict.empty, defs = [] }


rootKey : String
rootKey =
    ""


raisedZ : Int
raisedZ =
    1000000


overlayZ : Int
overlayZ =
    2000000



-- BUILDING


type alias WalkCtx =
    { transform : String
    , matrix : Mat23
    , inherited : Dict String String
    , opacity : Float
    , z : List Int
    , ancestors : List String
    , raise : Maybe String
    }


type alias Walked msg =
    { node : Maybe (Node msg)
    , layers : List ( String, Layer msg )
    , order : Int
    }


{-| Split a drawing into layers. `raise` names a key whose layer (and its
descendants) is drawn above everything else, which is how the dragged element
comes to the front.
-}
fromEvg : Maybe String -> Evg msg -> Layered msg
fromEvg raise ((Evg root) as evg) =
    let
        ctx =
            { transform = ""
            , matrix = Internal.identityMat
            , inherited = Dict.empty
            , opacity = 1
            , z = []
            , ancestors = []
            , raise = raise
            }

        walked =
            walk ctx 1 evg

        rootLayers =
            case walked.node of
                Just node ->
                    [ ( rootKey
                      , { parentTransform = ""
                        , parentMatrix = Internal.identityMat
                        , inherited = []
                        , opacity = 1
                        , node = node
                        , z = []
                        , order = 0
                        , ancestors = []
                        , pinned = False
                        }
                      )
                    ]

                Nothing ->
                    []
    in
    { layers = Dict.fromList (rootLayers ++ walked.layers)
    , defs = root.defs
    }


walk : WalkCtx -> Int -> Evg msg -> Walked msg
walk ctx order (Evg e) =
    -- IGNORE TCO: tree recursion over children cannot be tail-call optimized
    case e.content of
        Internal.Tag tag vdom events ->
            walkElement ctx order (Evg e) tag vdom events

        Internal.KeyedTag tag vdom events _ ->
            walkElement ctx order (Evg e) tag vdom events

        Internal.TextContent str ->
            { node = Just (Text str), layers = [], order = order }

        Internal.Raw _ _ ->
            { node = Just (Opaque (Evg e)), layers = [], order = order }

        Internal.RawLazy _ _ ->
            { node = Just (Opaque (Evg e)), layers = [], order = order }


walkElement :
    WalkCtx
    -> Int
    -> Evg msg
    -> String
    -> List (VirtualDom.Attribute msg)
    -> List (Mat23 -> VirtualDom.Attribute msg)
    -> Walked msg
walkElement ctx order (Evg e) tag vdom events =
    -- IGNORE TCO: mutual recursion with walk over the tree
    let
        deduped =
            Internal.dedupeAttrs e.attrs

        ownTransform =
            lookup "transform" deduped |> Maybe.withDefault ""

        attrs =
            List.filter (\( k, _ ) -> k /= "transform") deduped

        maybeKey =
            lookup keyAttribute attrs

        nodeOpacity =
            lookup "opacity" attrs
                |> Maybe.andThen String.toFloat
                |> Maybe.withDefault 1

        layerZ =
            case maybeKey of
                Just key ->
                    if ctx.raise == Just key then
                        [ raisedZ ]

                    else
                        ctx.z
                            ++ [ lookup zAttribute attrs
                                    |> Maybe.andThen String.toInt
                                    |> Maybe.withDefault 0
                               ]

                Nothing ->
                    ctx.z

        childCtx =
            { transform = joinTransforms ctx.transform ownTransform
            , matrix = Internal.composeMat ctx.matrix e.ownMatrix
            , inherited = List.foldl (\( k, v ) acc -> Dict.insert k v acc) ctx.inherited (List.filter (\( k, _ ) -> Set.member k inheritable) attrs)
            , opacity = ctx.opacity * nodeOpacity
            , z = layerZ
            , ancestors =
                case maybeKey of
                    Just key ->
                        key :: ctx.ancestors

                    Nothing ->
                        ctx.ancestors
            , raise = ctx.raise
            }

        ( children, childLayers, nextOrder ) =
            List.foldl
                (\child ( nodesAcc, layersAcc, o ) ->
                    let
                        walked =
                            walk childCtx o child
                    in
                    ( case walked.node of
                        Just n ->
                            n :: nodesAcc

                        Nothing ->
                            nodesAcc
                    , layersAcc ++ walked.layers
                    , walked.order
                    )
                )
                ( [], [], order + 1 )
                e.children

        node =
            Element
                { tag = tag
                , attrs = attrs
                , transform = ownTransform
                , matrix = e.ownMatrix
                , vdom = Just vdom
                , events = events
                , children = List.reverse children
                , hash = e.hash
                }
    in
    case maybeKey of
        Just key ->
            { node = Nothing
            , layers =
                ( key
                , { parentTransform = ctx.transform
                  , parentMatrix = ctx.matrix
                  , inherited = Dict.toList ctx.inherited
                  , opacity = ctx.opacity
                  , node = node
                  , z = layerZ
                  , order = order
                  , ancestors = ctx.ancestors
                  , pinned = False
                  }
                )
                    :: childLayers
            , order = nextOrder
            }

        Nothing ->
            { node = Just node, layers = childLayers, order = nextOrder }


{-| Presentation attributes that SVG inherits down the tree. A lifted layer
gets the values its ancestors would have given it.
-}
inheritable : Set String
inheritable =
    Set.fromList
        [ "fill"
        , "fill-opacity"
        , "fill-rule"
        , "stroke"
        , "stroke-width"
        , "stroke-opacity"
        , "stroke-linecap"
        , "stroke-linejoin"
        , "stroke-dasharray"
        , "stroke-dashoffset"
        , "stroke-miterlimit"
        , "font-family"
        , "font-size"
        , "font-weight"
        , "font-style"
        , "text-anchor"
        , "dominant-baseline"
        , "letter-spacing"
        , "word-spacing"
        , "visibility"
        , "color"
        , "cursor"
        , "pointer-events"
        , "paint-order"
        , "marker-start"
        , "marker-mid"
        , "marker-end"
        , "clip-rule"
        , "shape-rendering"
        , "text-rendering"
        ]


joinTransforms : String -> String -> String
joinTransforms outer inner =
    if String.isEmpty outer then
        inner

    else if String.isEmpty inner then
        outer

    else
        outer ++ " " ++ inner


lookup : String -> List ( String, String ) -> Maybe String
lookup key attrs =
    case attrs of
        [] ->
            Nothing

        ( k, v ) :: rest ->
            if k == key then
                Just v

            else
                lookup key rest


{-| Convert a drawing to a single node, without lifting anything out. Used for
overlays.
-}
plainNode : Evg msg -> Node msg
plainNode (Evg e) =
    -- IGNORE TCO: tree recursion over children cannot be tail-call optimized
    let
        element tag vdom events =
            let
                deduped =
                    Internal.dedupeAttrs e.attrs
            in
            Element
                { tag = tag
                , attrs = List.filter (\( k, _ ) -> k /= "transform") deduped
                , transform = lookup "transform" deduped |> Maybe.withDefault ""
                , matrix = e.ownMatrix
                , vdom = Just vdom
                , events = events
                , children = List.map plainNode e.children
                , hash = e.hash
                }
    in
    case e.content of
        Internal.Tag tag vdom events ->
            element tag vdom events

        Internal.KeyedTag tag vdom events _ ->
            element tag vdom events

        Internal.TextContent str ->
            Text str

        Internal.Raw _ _ ->
            Opaque (Evg e)

        Internal.RawLazy _ _ ->
            Opaque (Evg e)



-- QUERIES


{-| Like `position`, but straight from a drawing, without building layers.
This is the cheap query the drag engine runs many times per frame.
-}
locate : String -> ( Float, Float ) -> Evg msg -> Maybe ( Float, Float )
locate key anchor evg =
    locateFrame key evg
        |> Maybe.map (\frame -> pointInFrame frame anchor)


{-| Where an element sits: its matrix relative to the drawing's root, and its
geometric origin in its own coordinates.

Dragging follows the grabbed point relative to the element's **origin**, not
just its transform, because Evg shapes are usually placed by their geometry
(`center`, `x`/`y`) rather than by a transform. The origin is:

  - circles and ellipses: the centre
  - rectangles, images and text: the `x`, `y` corner
  - lines: the start point
  - polygons, polylines and paths: the first point
  - groups and anything else: the origin of its first child that has one,
    or (0, 0)

-}
type alias Frame =
    { matrix : Mat23
    , origin : ( Float, Float )
    }


pointInFrame : Frame -> ( Float, Float ) -> ( Float, Float )
pointInFrame frame ( ax, ay ) =
    Internal.applyPoint frame.matrix ( Tuple.first frame.origin + ax, Tuple.second frame.origin + ay )


locateFrame : String -> Evg msg -> Maybe Frame
locateFrame key evg =
    findFrame key Internal.identityMat evg


findFrame : String -> Mat23 -> Evg msg -> Maybe Frame
findFrame key parent ((Evg e) as evg) =
    -- IGNORE TCO: tree recursion over children cannot be tail-call optimized
    let
        m =
            Internal.composeMat parent e.ownMatrix
    in
    if List.member ( keyAttribute, key ) e.attrs then
        Just { matrix = m, origin = evgOrigin evg }

    else
        firstJust (findFrame key m) e.children


evgOrigin : Evg msg -> ( Float, Float )
evgOrigin (Evg e) =
    -- IGNORE TCO: recursion into the first child cannot be tail-call optimized
    case e.content of
        Internal.Tag tag _ _ ->
            case geometricOrigin tag e.attrs of
                Just origin ->
                    origin

                Nothing ->
                    case e.children of
                        ((Evg c) as child) :: _ ->
                            Internal.applyPoint c.ownMatrix (evgOrigin child)

                        [] ->
                            ( 0, 0 )

        _ ->
            ( 0, 0 )


geometricOrigin : String -> List ( String, String ) -> Maybe ( Float, Float )
geometricOrigin tag attrs =
    let
        num k =
            lookup k attrs
                |> Maybe.andThen (\v -> List.head (Lerp.numbers v))

        pair kx ky =
            Maybe.map2 Tuple.pair (num kx) (num ky)

        firstTwo k =
            case lookup k attrs |> Maybe.map Lerp.numbers of
                Just (x :: y :: _) ->
                    Just ( x, y )

                _ ->
                    Nothing
    in
    case tag of
        "circle" ->
            pair "cx" "cy"

        "ellipse" ->
            pair "cx" "cy"

        "rect" ->
            pair "x" "y"

        "image" ->
            pair "x" "y"

        "text" ->
            pair "x" "y"

        "use" ->
            pair "x" "y"

        "foreignObject" ->
            pair "x" "y"

        "line" ->
            pair "x1" "y1"

        "polygon" ->
            firstTwo "points"

        "polyline" ->
            firstTwo "points"

        "path" ->
            firstTwo "d"

        _ ->
            Nothing


nodeOrigin : Node msg -> ( Float, Float )
nodeOrigin node =
    -- IGNORE TCO: recursion into the first child cannot be tail-call optimized
    case node of
        Element e ->
            case geometricOrigin e.tag e.attrs of
                Just origin ->
                    origin

                Nothing ->
                    case e.children of
                        ((Element c) as child) :: _ ->
                            Internal.applyPoint c.matrix (nodeOrigin child)

                        _ ->
                            ( 0, 0 )

        _ ->
            ( 0, 0 )


firstJust : (a -> Maybe b) -> List a -> Maybe b
firstJust fn list =
    case list of
        [] ->
            Nothing

        x :: rest ->
            case fn x of
                Just found ->
                    Just found

                Nothing ->
                    firstJust fn rest


{-| Where the point `anchor`, given relative to the origin of the element
keyed `key`, ends up in the drawing's root coordinates.
-}
position : String -> ( Float, Float ) -> Layered msg -> Maybe ( Float, Float )
position key anchor layered =
    Dict.get key layered.layers
        |> Maybe.map
            (\layer ->
                pointInFrame
                    { matrix = Internal.composeMat layer.parentMatrix (nodeMatrix layer.node)
                    , origin = nodeOrigin layer.node
                    }
                    anchor
            )


nodeMatrix : Node msg -> Mat23
nodeMatrix node =
    case node of
        Element e ->
            e.matrix

        _ ->
            Internal.identityMat



-- BLENDING


{-| Blend two layered drawings: `a` at `t = 0`, `b` at `t = 1`. What can't be
blended (text, event handlers, opaque nodes) comes from whichever side `t` is
closer to. Layers present on one side only fade in or out. A pinned layer on
the `b` side is taken as it is.
-}
blend : Float -> Layered msg -> Layered msg -> Layered msg
blend t a b =
    if t <= 0 then
        a

    else if t >= 1 then
        b

    else
        let
            fromA =
                Dict.foldl
                    (\key la acc ->
                        case Dict.get key b.layers of
                            Just lb ->
                                Dict.insert key (blendLayer t la lb) acc

                            Nothing ->
                                insertMaybe key (fadeLayer (1 - t) la) acc
                    )
                    Dict.empty
                    a.layers

            layers =
                Dict.foldl
                    (\key lb acc ->
                        if Dict.member key a.layers then
                            acc

                        else if lb.pinned then
                            Dict.insert key lb acc

                        else
                            insertMaybe key (fadeLayer t lb) acc
                    )
                    fromA
                    b.layers
        in
        { layers = layers
        , defs = mergeDefs a.defs b.defs
        }


insertMaybe : comparable -> Maybe v -> Dict comparable v -> Dict comparable v
insertMaybe key maybeValue dict =
    case maybeValue of
        Just v ->
            Dict.insert key v dict

        Nothing ->
            dict


mergeDefs : List (Def msg) -> List (Def msg) -> List (Def msg)
mergeDefs a b =
    let
        seen =
            List.foldl (\(Def id _) acc -> Set.insert id acc) Set.empty a
    in
    a ++ List.filter (\(Def id _) -> not (Set.member id seen)) b


{-| Weighted blend of several drawings. The weights needn't sum to one; they
are normalised. Zero weights are skipped.
-}
blendMany : List ( Layered msg, Float ) -> Layered msg
blendMany items =
    let
        positive =
            List.filter (\( _, w ) -> w > 0) items
    in
    case positive of
        [] ->
            case items of
                ( first, _ ) :: _ ->
                    first

                [] ->
                    empty

        ( first, w0 ) :: rest ->
            List.foldl
                (\( layered, w ) ( acc, accW ) ->
                    ( blend (w / (accW + w)) acc layered, accW + w )
                )
                ( first, w0 )
                rest
                |> Tuple.first


blendLayer : Float -> Layer msg -> Layer msg -> Layer msg
blendLayer t la lb =
    if lb.pinned then
        lb

    else
        let
            near =
                if t < 0.5 then
                    la

                else
                    lb

            parentTransform =
                Lerp.transform t la.parentTransform lb.parentTransform
        in
        { parentTransform = parentTransform
        , parentMatrix = matrixFor parentTransform la.parentTransform la.parentMatrix lb.parentTransform lb.parentMatrix
        , inherited = blendAttrs t la.inherited lb.inherited
        , opacity = Lerp.float t la.opacity lb.opacity
        , node = blendNode t la.node lb.node
        , z = near.z
        , order = near.order
        , ancestors = near.ancestors
        , pinned = False
        }


{-| The matrix for a blended transform string, reusing an exact matrix when
the string came through unchanged.
-}
matrixFor : String -> String -> Mat23 -> String -> Mat23 -> Mat23
matrixFor result strA matA strB matB =
    if result == strA then
        matA

    else if result == strB then
        matB

    else
        Lerp.transformToMatrix result


fadeLayer : Float -> Layer msg -> Maybe (Layer msg)
fadeLayer factor layer =
    let
        opacity =
            layer.opacity * factor
    in
    if opacity <= 1.0e-3 then
        Nothing

    else
        Just { layer | opacity = opacity }


blendNode : Float -> Node msg -> Node msg -> Node msg
blendNode t na nb =
    -- IGNORE TCO: tree recursion over children cannot be tail-call optimized
    let
        near =
            if t < 0.5 then
                na

            else
                nb
    in
    case ( na, nb ) of
        ( Element a, Element b ) ->
            if a.tag /= b.tag || (a.hash /= 0 && a.hash == b.hash) then
                near

            else
                let
                    nearData =
                        if t < 0.5 then
                            a

                        else
                            b

                    attrs =
                        blendAttrs t a.attrs b.attrs

                    transform =
                        Lerp.transform t a.transform b.transform
                in
                Element
                    { tag = a.tag
                    , attrs = attrs
                    , transform = transform
                    , matrix = matrixFor transform a.transform a.matrix b.transform b.matrix
                    , vdom =
                        if attrs == nearData.attrs && transform == nearData.transform then
                            nearData.vdom

                        else
                            Nothing
                    , events = nearData.events
                    , children = blendChildren t a.children b.children
                    , hash = 0
                    }

        _ ->
            near


blendChildren : Float -> List (Node msg) -> List (Node msg) -> List (Node msg)
blendChildren t as_ bs =
    blendChildrenHelp t as_ bs []


blendChildrenHelp : Float -> List (Node msg) -> List (Node msg) -> List (Node msg) -> List (Node msg)
blendChildrenHelp t as_ bs acc =
    case ( as_, bs ) of
        ( a :: restA, b :: restB ) ->
            if sameKind a b then
                blendChildrenHelp t restA restB (blendNode t a b :: acc)

            else
                blendChildrenHelp t restA restB (prependMaybe (fadeNode t b) (prependMaybe (fadeNode (1 - t) a) acc))

        ( a :: restA, [] ) ->
            blendChildrenHelp t restA [] (prependMaybe (fadeNode (1 - t) a) acc)

        ( [], b :: restB ) ->
            blendChildrenHelp t [] restB (prependMaybe (fadeNode t b) acc)

        ( [], [] ) ->
            List.reverse acc


prependMaybe : Maybe a -> List a -> List a
prependMaybe maybeItem list =
    case maybeItem of
        Just item ->
            item :: list

        Nothing ->
            list


sameKind : Node msg -> Node msg -> Bool
sameKind a b =
    case ( a, b ) of
        ( Element ea, Element eb ) ->
            ea.tag == eb.tag

        ( Text _, Text _ ) ->
            True

        ( Opaque _, Opaque _ ) ->
            True

        _ ->
            False


fadeNode : Float -> Node msg -> Maybe (Node msg)
fadeNode factor node =
    case node of
        Element e ->
            let
                opacity =
                    (lookup "opacity" e.attrs |> Maybe.andThen String.toFloat |> Maybe.withDefault 1) * factor
            in
            if opacity <= 1.0e-3 then
                Nothing

            else
                Just
                    (Element
                        { e
                            | attrs = setAttr "opacity" (String.fromFloat opacity) e.attrs
                            , vdom = Nothing
                            , hash = 0
                        }
                    )

        _ ->
            if factor >= 0.5 then
                Just node

            else
                Nothing


setAttr : String -> String -> List ( String, String ) -> List ( String, String )
setAttr key val attrs =
    if List.any (\( k, _ ) -> k == key) attrs then
        List.map
            (\( k, v ) ->
                if k == key then
                    ( k, val )

                else
                    ( k, v )
            )
            attrs

    else
        attrs ++ [ ( key, val ) ]


blendAttrs : Float -> List ( String, String ) -> List ( String, String ) -> List ( String, String )
blendAttrs t as_ bs =
    if as_ == bs then
        as_

    else
        let
            bDict =
                Dict.fromList bs

            aKeys =
                List.foldl (\( k, _ ) acc -> Set.insert k acc) Set.empty as_

            fromA =
                List.filterMap
                    (\( k, va ) ->
                        Lerp.attribute k t (Just va) (Dict.get k bDict)
                            |> Maybe.map (\v -> ( k, v ))
                    )
                    as_

            fromB =
                List.filterMap
                    (\( k, vb ) ->
                        if Set.member k aKeys then
                            Nothing

                        else
                            Lerp.attribute k t Nothing (Just vb)
                                |> Maybe.map (\v -> ( k, v ))
                    )
                    bs
        in
        fromA ++ fromB



-- REARRANGING


{-| Move the layer `key` (and the layers nested in it) by `offset` and pin it,
so transitions leave it alone. With a ghost opacity, a faded copy stays behind
at the original position.
-}
floatLayer : String -> ( Float, Float ) -> Maybe Float -> Layered msg -> Layered msg
floatLayer key ( dx, dy ) ghost layered =
    let
        shift =
            { a = 1, b = 0, c = 0, d = 1, e = dx, f = dy }

        shiftString =
            "translate(" ++ String.fromFloat dx ++ " " ++ String.fromFloat dy ++ ")"

        moved =
            Dict.map
                (\k layer ->
                    if k == key || List.member key layer.ancestors then
                        { layer
                            | parentTransform = joinTransforms shiftString layer.parentTransform
                            , parentMatrix = Internal.composeMat shift layer.parentMatrix
                            , pinned = True
                            , z = raisedZ :: layer.z
                        }

                    else
                        layer
                )
                layered.layers

        withGhosts =
            case ghost of
                Just ghostOpacity ->
                    Dict.foldl
                        (\k layer acc ->
                            if k == key || List.member key layer.ancestors then
                                Dict.insert ("ghost:" ++ k) { layer | opacity = layer.opacity * ghostOpacity } acc

                            else
                                acc
                        )
                        moved
                        layered.layers

                Nothing ->
                    moved
    in
    { layered | layers = withGhosts }


{-| Copy the layer `key` (and its nested layers) from `source` into `target`,
replacing whatever `target` had under those keys.
-}
transplant : String -> Layered msg -> Layered msg -> Layered msg
transplant key source target =
    { layers =
        Dict.foldl
            (\k layer acc ->
                if k == key || List.member key layer.ancestors then
                    Dict.insert k layer acc

                else
                    acc
            )
            target.layers
            source.layers
    , defs = mergeDefs target.defs source.defs
    }


{-| Draw `overlay` on top of everything, in root coordinates. `index` keeps
several overlays apart.
-}
addOverlay : Int -> Evg msg -> Layered msg -> Layered msg
addOverlay index ((Evg o) as overlay) layered =
    { layers =
        Dict.insert ("overlay:" ++ String.fromInt index)
            { parentTransform = ""
            , parentMatrix = Internal.identityMat
            , inherited = []
            , opacity = 1
            , node = plainNode overlay
            , z = [ overlayZ ]
            , order = index
            , ancestors = []
            , pinned = True
            }
            layered.layers
    , defs = mergeDefs layered.defs o.defs
    }



-- DRAWING


{-| Draw the layers back into an Evg node: a keyed group with one child group
per layer, in stacking order.
-}
toEvg : List (VirtualDom.Attribute msg) -> List (Mat23 -> VirtualDom.Attribute msg) -> Layered msg -> Evg msg
toEvg vdomAttrs events layered =
    let
        sorted =
            layered.layers
                |> Dict.toList
                |> List.sortWith (\( _, la ) ( _, lb ) -> compareLayers la lb)
    in
    Evg
        { content = Internal.KeyedTag "g" vdomAttrs events (List.map (\( k, _ ) -> "l" ++ k) sorted)
        , ownMatrix = Internal.identityMat
        , children = List.map (\( _, layer ) -> layerToEvg layer) sorted
        , hash = 0
        , defs = layered.defs
        , attrs = []
        }


compareLayers : Layer msg -> Layer msg -> Order
compareLayers la lb =
    case compare la.z lb.z of
        EQ ->
            compare la.order lb.order

        other ->
            other


layerToEvg : Layer msg -> Evg msg
layerToEvg layer =
    let
        opacityAttrs =
            if layer.opacity < 1 then
                [ ( "opacity", String.fromFloat layer.opacity ) ]

            else
                []

        transformAttrs =
            if String.isEmpty layer.parentTransform then
                []

            else
                [ ( "transform", layer.parentTransform ) ]

        data =
            transformAttrs ++ layer.inherited ++ opacityAttrs
    in
    Evg
        { content = Internal.Tag "g" (List.map toVdom data) []
        , ownMatrix = layer.parentMatrix
        , children = [ nodeToEvg layer.node ]
        , hash = 0
        , defs = []
        , attrs = data
        }


nodeToEvg : Node msg -> Evg msg
nodeToEvg node =
    -- IGNORE TCO: tree recursion over children cannot be tail-call optimized
    case node of
        Element e ->
            let
                data =
                    if String.isEmpty e.transform then
                        e.attrs

                    else
                        ( "transform", e.transform ) :: e.attrs
            in
            Evg
                { content =
                    Internal.Tag e.tag
                        (case e.vdom of
                            Just vdom ->
                                vdom

                            Nothing ->
                                List.map toVdom data
                        )
                        e.events
                , ownMatrix = e.matrix
                , children = List.map nodeToEvg e.children
                , hash = e.hash
                , defs = []
                , attrs = data
                }

        Text str ->
            Internal.textNode str

        Opaque evg ->
            evg


toVdom : ( String, String ) -> VirtualDom.Attribute msg
toVdom ( key, val ) =
    if key == "xlink:href" then
        VirtualDom.attributeNS "http://www.w3.org/1999/xlink" key val

    else if key == "xml:space" then
        VirtualDom.attributeNS "http://www.w3.org/XML/1998/namespace" key val

    else
        VirtualDom.attribute key val
