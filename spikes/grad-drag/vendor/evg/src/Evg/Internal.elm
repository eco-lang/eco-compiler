module Evg.Internal exposing
    ( Attribute(..)
    , BaseFilter
    , Content(..)
    , CoordinateSpace(..)
    , Def(..)
    , Easing(..)
    , Evg(..)
    , Filter(..)
    , FilterPayload
    , Mat23
    , Paint(..)
    , Stop(..)
    , Supported
    , applyPoint
    , attrHash
    , collectDefs
    , composeMat
    , contentHash
    , coordinateSpaceAttrs
    , coordinateSpaceData
    , coordinateSpaceHash
    , dedupeAttrs
    , easingFunction
    , element
    , emptyEvg
    , filterElem
    , filterPrimitives
    , filterToEvg
    , filterToEvgWith
    , hashStringToInt
    , identityMat
    , invertMat
    , keyedNode
    , mapEvg
    , mixColor
    , mixFloat
    , mixInt
    , mixString
    , renderDefs
    , serialize
    , serializeDefs
    , svgAttributes
    , textNode
    , toNode
    , wrapNode
    )

import Bitwise
import Color exposing (Color)
import Dict exposing (Dict)
import Set
import Svg
import Svg.Attributes
import VirtualDom


type Supported
    = Supported Never


{-| A speed profile, shared by `Evg.Animate` (which hands it to the browser
as a SMIL key spline) and `Evg.Drag` (which evaluates it itself).
-}
type Easing
    = Linear
    | EaseInOut
    | EaseIn
    | EaseOut
    | CubicBezier Float Float Float Float


{-| Evaluate an easing at progress `x` (0 to 1). Every easing is a cubic
Bézier curve from (0, 0) to (1, 1) with two control points, the same curves
`Evg.Animate` asks the browser for, so animations look alike either way.
-}
easingFunction : Easing -> Float -> Float
easingFunction easing x =
    let
        { x1, y1, x2, y2 } =
            case easing of
                Linear ->
                    { x1 = 0, y1 = 0, x2 = 1, y2 = 1 }

                EaseInOut ->
                    { x1 = 0.5, y1 = 0, x2 = 0.5, y2 = 1 }

                EaseIn ->
                    { x1 = 0.5, y1 = 0, x2 = 1, y2 = 1 }

                EaseOut ->
                    { x1 = 0, y1 = 0, x2 = 0.5, y2 = 1 }

                CubicBezier a b c d ->
                    { x1 = a, y1 = b, x2 = c, y2 = d }

        bezier p1 p2 s =
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s

        -- The curve's x grows monotonically for control points inside
        -- [0, 1], so bisection finds the parameter for a given x.
        solve lo hi steps =
            let
                mid =
                    (lo + hi) / 2
            in
            if steps <= 0 then
                mid

            else if bezier x1 x2 mid < x then
                solve mid hi (steps - 1)

            else
                solve lo mid (steps - 1)
    in
    if x <= 0 then
        0

    else if x >= 1 then
        1

    else
        bezier y1 y2 (solve 0 1 30)


{-| A 2×3 affine transformation matrix, matching SVG's `matrix(a b c d e f)`.
It maps a point `(x, y)` to `(a*x + c*y + e, b*x + d*y + f)`.

We track these alongside the transform strings so that event handlers can
convert a decoded scene-space point into the local coordinate space of the
element they sit on, by inverting the accumulated root→element matrix. No
browser API can do this from a JSON decoder (it would need `getScreenCTM`),
but because we render every transform ourselves we can reconstruct it.

-}
type alias Mat23 =
    { a : Float
    , b : Float
    , c : Float
    , d : Float
    , e : Float
    , f : Float
    }


identityMat : Mat23
identityMat =
    { a = 1, b = 0, c = 0, d = 1, e = 0, f = 0 }


{-| Compose two matrices: `composeMat outer inner` is the matrix that applies
`inner` first, then `outer`. This matches how nested SVG `transform`
attributes stack (the parent's transform wraps the child's).
-}
composeMat : Mat23 -> Mat23 -> Mat23
composeMat m n =
    { a = m.a * n.a + m.c * n.b
    , b = m.b * n.a + m.d * n.b
    , c = m.a * n.c + m.c * n.d
    , d = m.b * n.c + m.d * n.d
    , e = m.a * n.e + m.c * n.f + m.e
    , f = m.b * n.e + m.d * n.f + m.f
    }


{-| Invert an affine matrix. Returns the identity for degenerate (non-invertible)
matrices such as `scale 0`, so callers get a harmless fallback rather than NaNs.
-}
invertMat : Mat23 -> Mat23
invertMat m =
    let
        det =
            m.a * m.d - m.b * m.c
    in
    if det == 0 then
        identityMat

    else
        let
            invDet =
                1 / det
        in
        { a = m.d * invDet
        , b = -m.b * invDet
        , c = -m.c * invDet
        , d = m.a * invDet
        , e = (m.c * m.f - m.d * m.e) * invDet
        , f = (m.b * m.e - m.a * m.f) * invDet
        }


applyPoint : Mat23 -> ( Float, Float ) -> ( Float, Float )
applyPoint m ( x, y ) =
    ( m.a * x + m.c * y + m.e
    , m.b * x + m.d * y + m.f
    )


{-| Defines the coordinate system for paint servers (gradients, patterns),
clip paths, and masks.

  - `ObjectBoundingBox`: coordinates are relative to the element's bounding box.
    `(0, 0)` is the top-left corner and `(1, 1)` is the bottom-right,
    regardless of the element's actual size or position.
  - `UserSpace`: coordinates use the same absolute coordinate system as the
    shapes themselves.

Both take a rect that defines the region where the effect is applied.

-}
type CoordinateSpace
    = ObjectBoundingBox { x : Float, y : Float, width : Float, height : Float }
    | UserSpace { x : Float, y : Float, width : Float, height : Float }


coordinateSpaceHash : CoordinateSpace -> Int
coordinateSpaceHash space =
    case space of
        ObjectBoundingBox { x, y, width, height } ->
            1 |> mixFloat x |> mixFloat y |> mixFloat width |> mixFloat height

        UserSpace { x, y, width, height } ->
            2 |> mixFloat x |> mixFloat y |> mixFloat width |> mixFloat height


coordinateSpaceAttrs : (String -> VirtualDom.Attribute msg) -> CoordinateSpace -> List (VirtualDom.Attribute msg)
coordinateSpaceAttrs unitsAttr space =
    case space of
        ObjectBoundingBox { x, y, width, height } ->
            [ unitsAttr "objectBoundingBox"
            , Svg.Attributes.x (String.fromFloat x)
            , Svg.Attributes.y (String.fromFloat y)
            , Svg.Attributes.width (String.fromFloat width)
            , Svg.Attributes.height (String.fromFloat height)
            ]

        UserSpace { x, y, width, height } ->
            [ unitsAttr "userSpaceOnUse"
            , Svg.Attributes.x (String.fromFloat x)
            , Svg.Attributes.y (String.fromFloat y)
            , Svg.Attributes.width (String.fromFloat width)
            , Svg.Attributes.height (String.fromFloat height)
            ]


{-| The data equivalent of `coordinateSpaceAttrs`: the same attribute pairs
as strings, for the inspectable `attrs` field.
-}
coordinateSpaceData : String -> CoordinateSpace -> List ( String, String )
coordinateSpaceData unitsAttrName space =
    let
        pairs unitsValue { x, y, width, height } =
            [ ( unitsAttrName, unitsValue )
            , ( "x", String.fromFloat x )
            , ( "y", String.fromFloat y )
            , ( "width", String.fromFloat width )
            , ( "height", String.fromFloat height )
            ]
    in
    case space of
        ObjectBoundingBox rect ->
            pairs "objectBoundingBox" rect

        UserSpace rect ->
            pairs "userSpaceOnUse" rect


type Paint
    = PaintNone
    | PaintSolid Color
    | PaintStr String
    | PaintContextFill
    | PaintContextStroke
    | PaintLinearGradient ( Float, Float ) ( Float, Float ) (List Stop)
    | PaintLinearGradientCS CoordinateSpace ( Float, Float ) ( Float, Float ) (List Stop)
    | PaintRadialGradient ( Float, Float ) Float (List Stop)
    | PaintRadialGradientCS CoordinateSpace ( Float, Float ) Float (List Stop)
    | PaintPattern (List (Attribute {} Never)) { width : Float, height : Float } (List (Evg Never))
    | PaintPatternCS (List (Attribute {} Never)) CoordinateSpace (List (Evg Never))


type Stop
    = ColorStop Float Color Float
    | StrStop Float String Float


type Evg msg
    = Evg
        { content : Content msg
        , ownMatrix : Mat23
        , children : List (Evg msg)
        , hash : Int
        , defs : List (Def msg)
        , attrs : List ( String, String )
        }


{-| What a node actually is. Keeping this as data (rather than a baked
render closure) is what makes `Evg.toString` possible: the tree can be
walked and serialized, not only handed to the virtual DOM.

  - `Tag`: an ordinary element. Prebaked VirtualDom attributes render fast;
    the equivalent data lives in the record's `attrs` field. Event handlers
    are builders awaiting the accumulated transform matrix.
  - `TextContent`: character data inside an element (not a `<text>` tag).
  - `Raw`: an opaque VirtualDom node, plus a stand-in used when serializing.
    The node renders as-is, but its markup cannot be read back out of the
    virtual DOM, so `toString` emits the stand-in instead.
  - `RawLazy`: a lazily-rendered subtree. The node preserves
    `VirtualDom.lazy` caching; the thunk lets `toString` force the content.
  - `KeyedTag`: like `Tag`, but its children are rendered as a keyed list
    (one key per child, in order), so the virtual DOM moves existing DOM
    nodes when children are reordered instead of patching them in place.
    `Evg.Drag` relies on this to keep the element under a finger alive while
    the drawing rearranges around it.

-}
type Content msg
    = Tag String (List (VirtualDom.Attribute msg)) (List (Mat23 -> VirtualDom.Attribute msg))
    | KeyedTag String (List (VirtualDom.Attribute msg)) (List (Mat23 -> VirtualDom.Attribute msg)) (List String)
    | TextContent String
    | Raw (VirtualDom.Node msg) (Evg msg)
    | RawLazy (VirtualDom.Node msg) (() -> Evg msg)


toNode : Evg msg -> VirtualDom.Node msg
toNode =
    toNodeWith identityMat


{-| Render a node given the accumulated root→parent transform matrix. Each
element composes its own transform onto that accumulator and hands the result
both to its own event handlers (which invert it to recover local coordinates)
and to its children.
-}
toNodeWith : Mat23 -> Evg msg -> VirtualDom.Node msg
toNodeWith parentAccum (Evg { content, ownMatrix, children }) =
    -- IGNORE TCO: tree recursion over children cannot be tail-call optimized
    case content of
        Tag tag vdomAttrs eventBuilders ->
            let
                accum =
                    composeMat parentAccum ownMatrix

                finalAttrs =
                    case eventBuilders of
                        [] ->
                            vdomAttrs

                        _ ->
                            vdomAttrs ++ List.map (\build -> build accum) eventBuilders

                -- A nested <svg> resets the event coordinate origin: the
                -- browser reports offsets relative to the nearest ancestor
                -- <svg>, so its children start from a fresh matrix.
                childAccum =
                    if tag == "svg" then
                        identityMat

                    else
                        accum
            in
            svgNode tag finalAttrs (List.map (toNodeWith childAccum) children)

        KeyedTag tag vdomAttrs eventBuilders keys ->
            let
                accum =
                    composeMat parentAccum ownMatrix

                finalAttrs =
                    vdomAttrs ++ List.map (\build -> build accum) eventBuilders
            in
            VirtualDom.keyedNodeNS "http://www.w3.org/2000/svg"
                tag
                finalAttrs
                (List.map2 (\key child -> ( key, toNodeWith accum child )) keys children)

        TextContent str ->
            VirtualDom.text str

        Raw node fallback ->
            -- Children only ever arrive here from features that work by
            -- putting an element inside the shape they modify, above all the
            -- Animate module. That is impossible for an opaque value, so
            -- rather than silently dropping the effect we draw the fallback,
            -- which is where an explanation of what went wrong can live.
            case children of
                [] ->
                    node

                _ ->
                    toNodeWith (composeMat parentAccum ownMatrix) fallback

        RawLazy node _ ->
            node


{-| Dispatch to elm/svg's trusted constructors for the tags we emit, so the
hot path keeps skipping VirtualDom's tag sanitization exactly as before.
Unknown tags (from `customElement`) fall back to the checked constructor.
-}
svgNode : String -> List (VirtualDom.Attribute msg) -> List (VirtualDom.Node msg) -> VirtualDom.Node msg
svgNode tag =
    case tag of
        "g" ->
            Svg.g

        "circle" ->
            Svg.circle

        "rect" ->
            Svg.rect

        "line" ->
            Svg.line

        "ellipse" ->
            Svg.ellipse

        "polygon" ->
            Svg.polygon

        "polyline" ->
            Svg.polyline

        "path" ->
            Svg.path

        "text" ->
            Svg.text_

        "tspan" ->
            Svg.tspan

        "textPath" ->
            Svg.textPath

        "image" ->
            Svg.image

        "use" ->
            Svg.use

        "defs" ->
            Svg.defs

        "symbol" ->
            Svg.symbol

        "marker" ->
            Svg.marker

        "mask" ->
            Svg.mask

        "clipPath" ->
            Svg.clipPath

        "linearGradient" ->
            Svg.linearGradient

        "radialGradient" ->
            Svg.radialGradient

        "stop" ->
            Svg.stop

        "pattern" ->
            Svg.pattern

        "filter" ->
            Svg.filter

        "animate" ->
            Svg.animate

        "animateTransform" ->
            Svg.animateTransform

        "animateMotion" ->
            Svg.animateMotion

        "mpath" ->
            Svg.mpath

        "title" ->
            Svg.title

        "desc" ->
            Svg.desc

        "svg" ->
            Svg.svg

        "a" ->
            Svg.a

        "set" ->
            Svg.set

        _ ->
            Svg.node tag


wrapNode : VirtualDom.Node msg -> Evg msg
wrapNode node =
    Evg { content = Raw node emptyEvg, ownMatrix = identityMat, children = [], hash = 0, defs = [], attrs = [] }


{-| A node that renders and serializes to nothing.
-}
emptyEvg : Evg msg
emptyEvg =
    Evg { content = TextContent "", ownMatrix = identityMat, children = [], hash = 0, defs = [], attrs = [] }


{-| Like `wrapNode`, but with a caller-supplied content hash and a stand-in
for serialization. Opaque nodes cannot be hashed or read by inspecting them,
so anything user-facing needs both: without a key, two different raw nodes
would both hash to 0 and def ids derived from content (clip paths, masks,
symbols) would collide and dedupe wrongly.

The stand-in's own defs travel with the node, so a fallback that uses a
gradient or pattern still resolves when serialized.

-}
keyedNode : Int -> VirtualDom.Node msg -> Evg msg -> Evg msg
keyedNode hash node fallback =
    Evg
        { content = Raw node fallback
        , ownMatrix = identityMat
        , children = []
        , hash = hash
        , defs = evgDefs fallback
        , attrs = []
        }


{-| A bare text node (character data inside an element).
-}
textNode : String -> Evg msg
textNode str =
    Evg { content = TextContent str, ownMatrix = identityMat, children = [], hash = hashStringToInt str, defs = [], attrs = [] }


mapEvg : (a -> b) -> Evg a -> Evg b
mapEvg fn (Evg e) =
    -- IGNORE TCO: tree recursion over children cannot be tail-call optimized
    Evg
        { content = mapContent fn e.content
        , ownMatrix = e.ownMatrix
        , children = List.map (mapEvg fn) e.children
        , hash = e.hash
        , defs = List.map (\(Def defId defEvg) -> Def defId (mapEvg fn defEvg)) e.defs
        , attrs = e.attrs
        }


mapContent : (a -> b) -> Content a -> Content b
mapContent fn content =
    case content of
        Tag tag vdomAttrs eventBuilders ->
            Tag tag
                (List.map (VirtualDom.mapAttribute fn) vdomAttrs)
                (List.map (\build accum -> VirtualDom.mapAttribute fn (build accum)) eventBuilders)

        KeyedTag tag vdomAttrs eventBuilders keys ->
            KeyedTag tag
                (List.map (VirtualDom.mapAttribute fn) vdomAttrs)
                (List.map (\build accum -> VirtualDom.mapAttribute fn (build accum)) eventBuilders)
                keys

        TextContent str ->
            TextContent str

        Raw node fallback ->
            Raw (VirtualDom.map fn node) (mapEvg fn fallback)

        RawLazy node thunk ->
            RawLazy (VirtualDom.map fn node) (\() -> mapEvg fn (thunk ()))


type Def msg
    = Def String (Evg msg)


type Attribute constraints msg
    = Attr Int String String (VirtualDom.Attribute msg)
    | DefAttr Int String String (VirtualDom.Attribute msg) (Def msg)
    | AccessibilityChild Int (Evg msg)
    | TransformAttr Int String Mat23
    | EventAttr Int (Mat23 -> VirtualDom.Attribute msg)
    | Batch (List (Attribute constraints msg))
    | TextPathChild Int String (Def msg)


element :
    String
    -> Int
    -> List (VirtualDom.Attribute msg)
    -> List (Mat23 -> VirtualDom.Attribute msg)
    -> Mat23
    -> List ( String, String )
    -> List (Evg msg)
    -> List (Def msg)
    -> Evg msg
element tag hash vdomAttrs eventBuilders ownMatrix inspectableAttrs children ownDefs =
    Evg
        { content = Tag tag vdomAttrs eventBuilders
        , ownMatrix = ownMatrix
        , children = children

        -- Children's hashes must contribute: content hashes name defs (clip
        -- paths, masks, symbols), and two same-attribute containers with
        -- different children would otherwise collide and dedupe wrongly.
        , hash = List.foldl (\(Evg child) acc -> Bitwise.xor (acc * 33) child.hash) hash children
        , defs = ownDefs ++ collectDefs children
        , attrs = inspectableAttrs
        }


svgAttributes :
    List (Attribute constraints msg)
    ->
        { vdomAttrs : List (VirtualDom.Attribute msg)
        , eventBuilders : List (Mat23 -> VirtualDom.Attribute msg)
        , ownMatrix : Mat23
        , defs : List (Def msg)
        , a11yChildren : List (Evg msg)
        , inspectable : List ( String, String )
        , textPath : Maybe ( String, Def msg )
        }
svgAttributes attrs =
    let
        go remaining accAttrs accEvents accMatrices accDefs accChildren accTransforms accInspectable accTextPath =
            case remaining of
                [] ->
                    let
                        finalAttrs =
                            case accTransforms of
                                [] ->
                                    List.reverse accAttrs

                                _ ->
                                    Svg.Attributes.transform (String.join " " (List.reverse accTransforms)) :: List.reverse accAttrs
                    in
                    { vdomAttrs = finalAttrs
                    , eventBuilders = List.reverse accEvents
                    , ownMatrix = List.foldl composeMat identityMat accMatrices
                    , defs = List.reverse accDefs
                    , a11yChildren = List.reverse accChildren
                    , inspectable = List.reverse accInspectable
                    , textPath = accTextPath
                    }

                (Attr _ key value a) :: rest ->
                    go rest (a :: accAttrs) accEvents accMatrices accDefs accChildren accTransforms (( key, value ) :: accInspectable) accTextPath

                (DefAttr _ key value a def) :: rest ->
                    go rest (a :: accAttrs) accEvents accMatrices (def :: accDefs) accChildren accTransforms (( key, value ) :: accInspectable) accTextPath

                (AccessibilityChild _ child) :: rest ->
                    go rest accAttrs accEvents accMatrices accDefs (child :: accChildren) accTransforms accInspectable accTextPath

                (TransformAttr _ str mat) :: rest ->
                    go rest accAttrs accEvents (mat :: accMatrices) accDefs accChildren (str :: accTransforms) (( "transform", str ) :: accInspectable) accTextPath

                (EventAttr _ build) :: rest ->
                    go rest accAttrs (build :: accEvents) accMatrices accDefs accChildren accTransforms accInspectable accTextPath

                (Batch batchAttrs) :: rest ->
                    go (batchAttrs ++ rest) accAttrs accEvents accMatrices accDefs accChildren accTransforms accInspectable accTextPath

                (TextPathChild _ href def) :: rest ->
                    go rest accAttrs accEvents accMatrices (def :: accDefs) accChildren accTransforms accInspectable (Just ( href, def ))
    in
    go attrs [] [] [] [] [] [] [] Nothing


attrHash : List (Attribute constraints msg) -> Int
attrHash attrs =
    -- IGNORE TCO: recursion into nested Batch attributes cannot be tail-call optimized
    List.foldl
        (\attr acc ->
            let
                h =
                    case attr of
                        Attr hash _ _ _ ->
                            hash

                        DefAttr hash _ _ _ _ ->
                            hash

                        AccessibilityChild hash _ ->
                            hash

                        TransformAttr hash _ _ ->
                            hash

                        EventAttr hash _ ->
                            hash

                        Batch batchAttrs ->
                            attrHash batchAttrs

                        TextPathChild hash _ _ ->
                            hash
            in
            Bitwise.xor (acc * 31) h
        )
        5381
        attrs


collectDefs : List (Evg msg) -> List (Def msg)
collectDefs children =
    List.concatMap (\(Evg { defs }) -> defs) children


{-| The complete def list, including defs nested inside another def's own
tree. A shape used as a clip stencil or mask can itself be painted with a
gradient or pattern, and that paint's def lives inside the stencil's subtree
rather than at the top level, so a shallow collection would leave the
reference dangling. Walks each def's children transitively.
-}
allDefs : List (Def msg) -> List (Def msg)
allDefs defs =
    -- IGNORE TCO: tree recursion over def subtrees cannot be tail-call optimized
    List.concatMap
        (\((Def _ evg) as def) ->
            def :: allDefs (evgDefs evg)
        )
        defs


{-| Every def reachable from a node: its own plus those of all its children.
-}
evgDefs : Evg msg -> List (Def msg)
evgDefs (Evg { defs, children }) =
    defs ++ collectDefs children


renderDefs : List (Def msg) -> VirtualDom.Node msg
renderDefs defs =
    case allDefs defs of
        [] ->
            VirtualDom.text ""

        expanded ->
            let
                dedup =
                    List.foldl
                        (\(Def id evg) acc ->
                            if Dict.member id acc then
                                acc

                            else
                                Dict.insert id (toNode evg) acc
                        )
                        Dict.empty
                        expanded
            in
            Svg.defs [] (Dict.values dedup)


{-| Serialize a node (and its children) to SVG markup. Event handlers are
dropped (markup has no behavior), lazy nodes are forced through their thunk,
and opaque `Raw` nodes are skipped since VirtualDom values cannot be
inspected from Elm.
-}
serialize : Evg msg -> String
serialize (Evg { content, children, attrs }) =
    -- IGNORE TCO: tree recursion over children cannot be tail-call optimized
    case content of
        Tag tag _ _ ->
            serializeTag tag attrs children

        KeyedTag tag _ _ _ ->
            serializeTag tag attrs children

        TextContent str ->
            escapeText str

        Raw _ fallback ->
            serialize fallback

        RawLazy _ thunk ->
            serializeWithLocalDefs (thunk ())


serializeTag : String -> List ( String, String ) -> List (Evg msg) -> String
serializeTag tag attrs children =
    -- IGNORE TCO: mutual recursion with serialize over the tree
    let
        attrStr =
            attrs
                |> dedupeAttrs
                |> List.map (\( k, v ) -> " " ++ k ++ "=\"" ++ escapeAttr v ++ "\"")
                |> String.concat

        inner =
            children
                |> List.map serialize
                |> String.concat
    in
    if String.isEmpty inner then
        "<" ++ tag ++ attrStr ++ "/>"

    else
        "<" ++ tag ++ attrStr ++ ">" ++ inner ++ "</" ++ tag ++ ">"


{-| A lazy subtree renders its own defs locally (see Evg.Performance), so its
serialization must include them the same way or references would dangle.
-}
serializeWithLocalDefs : Evg msg -> String
serializeWithLocalDefs ((Evg { defs }) as evg) =
    case defs of
        [] ->
            serialize evg

        _ ->
            "<g>" ++ serializeDefs defs ++ serialize evg ++ "</g>"


{-| Serialize a def list to a `<defs>` element, deduplicated by id, matching
`renderDefs`.
-}
serializeDefs : List (Def msg) -> String
serializeDefs defs =
    case allDefs defs of
        [] ->
            ""

        expanded ->
            let
                dedup =
                    List.foldl
                        (\(Def id evg) acc ->
                            if Dict.member id acc then
                                acc

                            else
                                Dict.insert id (serialize evg) acc
                        )
                        Dict.empty
                        expanded
            in
            "<defs>" ++ String.concat (Dict.values dedup) ++ "</defs>"


{-| Collapse repeated attribute names the way rendering does: repeated
`transform` entries join into one space-separated value (transforms
compose), while for any other repeated name the last value wins. Order of
first appearance is kept.
-}
dedupeAttrs : List ( String, String ) -> List ( String, String )
dedupeAttrs attrs =
    let
        resolved =
            List.foldl
                (\( k, v ) acc ->
                    Dict.update k
                        (\existing ->
                            case ( existing, k ) of
                                ( Just prev, "transform" ) ->
                                    Just (prev ++ " " ++ v)

                                _ ->
                                    Just v
                        )
                        acc
                )
                Dict.empty
                attrs
    in
    attrs
        |> List.foldl
            (\( k, _ ) ( seen, acc ) ->
                if Set.member k seen then
                    ( seen, acc )

                else
                    ( Set.insert k seen
                    , ( k, Maybe.withDefault "" (Dict.get k resolved) ) :: acc
                    )
            )
            ( Set.empty, [] )
        |> Tuple.second
        |> List.reverse


escapeAttr : String -> String
escapeAttr =
    String.foldl
        (\c acc ->
            acc
                ++ (case c of
                        '&' ->
                            "&amp;"

                        '<' ->
                            "&lt;"

                        '>' ->
                            "&gt;"

                        '"' ->
                            "&quot;"

                        _ ->
                            String.fromChar c
                   )
        )
        ""


escapeText : String -> String
escapeText =
    String.foldl
        (\c acc ->
            acc
                ++ (case c of
                        '&' ->
                            "&amp;"

                        '<' ->
                            "&lt;"

                        '>' ->
                            "&gt;"

                        _ ->
                            String.fromChar c
                   )
        )
        ""


contentHash : Evg msg -> String
contentHash (Evg { hash }) =
    String.fromInt hash


hashStringToInt : String -> Int
hashStringToInt str =
    String.foldl (\c acc -> Bitwise.xor (acc * 31) (Char.toCode c)) 5381 str


mixFloat : Float -> Int -> Int
mixFloat value acc =
    Bitwise.xor (acc * 31) (round (value * 1000))


mixColor : Color -> Int -> Int
mixColor color acc =
    let
        { red, green, blue, alpha } =
            Color.toRgba color
    in
    acc
        |> mixFloat red
        |> mixFloat green
        |> mixFloat blue
        |> mixFloat alpha


mixString : String -> Int -> Int
mixString str acc =
    String.foldl (\c a -> Bitwise.xor (a * 31) (Char.toCode c)) acc str


mixInt : Int -> Int -> Int
mixInt value acc =
    Bitwise.xor (acc * 31) value



-- Filter types and rendering


type alias BaseFilter a =
    { a
        | name : String
        , id : String
        , args : List ( String, String )
        , children : List ( String, List ( String, String ) )
    }


type alias FilterPayload =
    { defs : Dict String (BaseFilter {})
    , name : String
    , id : String
    , args : List ( String, String )
    , children : List ( String, List ( String, String ) )
    }


type Filter
    = Filter FilterPayload
    | Virtual String


filterPrimitives : Filter -> ( String, List (VirtualDom.Node msg) )
filterPrimitives filter =
    case filter of
        Filter args ->
            let
                outputPrimitive =
                    { name = args.name, id = args.id, args = args.args, children = args.children }

                depPrimitives =
                    Dict.values args.defs

                sorted =
                    topologicalSort depPrimitives
            in
            ( args.id, List.map filterToNode sorted ++ [ filterToNode outputPrimitive ] )

        Virtual _ ->
            ( "", [] )


filterElem : Filter -> ( String, VirtualDom.Node msg )
filterElem filter =
    case filter of
        Filter args ->
            let
                outputPrimitive =
                    { name = args.name, id = args.id, args = args.args, children = args.children }

                depPrimitives =
                    Dict.values args.defs

                sorted =
                    topologicalSort depPrimitives
            in
            ( args.id
            , Svg.filter
                [ Svg.Attributes.id args.id ]
                (List.map filterToNode sorted ++ [ filterToNode outputPrimitive ])
            )

        Virtual _ ->
            ( "", VirtualDom.text "" )


filterToEvg : String -> Filter -> Evg msg
filterToEvg id filter =
    filterToEvgWith id [] [] filter


{-| Like `filterToEvg`, but with extra attributes on the `<filter>` element
(paired as prebaked VirtualDom attributes and their data equivalents), used
for filter region overrides.
-}
filterToEvgWith : String -> List (VirtualDom.Attribute msg) -> List ( String, String ) -> Filter -> Evg msg
filterToEvgWith id extraVdomAttrs extraDataAttrs filter =
    case filter of
        Filter args ->
            let
                outputPrimitive =
                    { name = args.name, id = args.id, args = args.args, children = args.children }

                depPrimitives =
                    Dict.values args.defs

                sorted =
                    topologicalSort depPrimitives

                allPrimitives =
                    sorted ++ [ outputPrimitive ]

                primitiveChildren =
                    List.map primitiveToEvg allPrimitives
            in
            Evg
                { content = Tag "filter" (Svg.Attributes.id id :: extraVdomAttrs) []
                , ownMatrix = identityMat
                , children = primitiveChildren
                , hash = 0
                , defs = []
                , attrs = ( "id", id ) :: extraDataAttrs
                }

        Virtual _ ->
            wrapNode (VirtualDom.text "")


primitiveToEvg : BaseFilter a -> Evg msg
primitiveToEvg prim =
    let
        childEvgs =
            List.map
                (\( childName, attrs ) ->
                    Evg
                        { content = Tag childName (List.map filterAttr attrs) []
                        , ownMatrix = identityMat
                        , children = []
                        , hash = 0
                        , defs = []
                        , attrs = attrs
                        }
                )
                prim.children
    in
    Evg
        { content = Tag prim.name (Svg.Attributes.result prim.id :: List.map filterAttr prim.args) []
        , ownMatrix = identityMat
        , children = childEvgs

        -- attrs must mirror the rendered attributes exactly, or toString drifts
        -- from toNode. That means the result id plus every arg, including the
        -- in/in2 wiring that chains one primitive's output into the next.
        , hash = 0
        , defs = []
        , attrs = ( "result", prim.id ) :: prim.args
        }


topologicalSort : List (BaseFilter {}) -> List (BaseFilter {})
topologicalSort primitives =
    let
        idSet =
            List.map .id primitives |> Set.fromList

        getDeps prim =
            let
                argDeps =
                    prim.args
                        |> List.filterMap
                            (\( k, v ) ->
                                if (k == "in" || k == "in2") && Set.member v idSet then
                                    Just v

                                else
                                    Nothing
                            )

                childDeps =
                    prim.children
                        |> List.concatMap
                            (\( _, childAttrs ) ->
                                List.filterMap
                                    (\( k, v ) ->
                                        if (k == "in" || k == "in2") && Set.member v idSet then
                                            Just v

                                        else
                                            Nothing
                                    )
                                    childAttrs
                            )
            in
            argDeps ++ childDeps

        go remaining emitted result =
            case remaining of
                [] ->
                    List.reverse result

                _ ->
                    let
                        ( ready, blocked ) =
                            List.partition
                                (\prim ->
                                    List.all (\dep -> Set.member dep emitted) (getDeps prim)
                                )
                                remaining
                    in
                    case ready of
                        [] ->
                            List.reverse result ++ remaining

                        _ ->
                            let
                                newEmitted =
                                    List.foldl (\prim acc -> Set.insert prim.id acc) emitted ready
                            in
                            go blocked newEmitted (List.reverse ready ++ result)
    in
    go primitives Set.empty []


filterToNode : BaseFilter a -> VirtualDom.Node msg
filterToNode args =
    Svg.node args.name
        (Svg.Attributes.result args.id
            :: List.map filterAttr args.args
        )
        (List.map
            (\( childName, attrs ) ->
                Svg.node childName
                    (List.map filterAttr attrs)
                    []
            )
            args.children
        )


filterAttr : ( String, String ) -> VirtualDom.Attribute msg
filterAttr ( key, value ) =
    case key of
        "in" ->
            Svg.Attributes.in_ value

        "in2" ->
            Svg.Attributes.in2 value

        "stdDeviation" ->
            Svg.Attributes.stdDeviation value

        "baseFrequency" ->
            Svg.Attributes.baseFrequency value

        "numOctaves" ->
            Svg.Attributes.numOctaves value

        "seed" ->
            Svg.Attributes.seed value

        "type" ->
            Svg.Attributes.type_ value

        "scale" ->
            Svg.Attributes.scale value

        "operator" ->
            Svg.Attributes.operator value

        "k1" ->
            Svg.Attributes.k1 value

        "k2" ->
            Svg.Attributes.k2 value

        "k3" ->
            Svg.Attributes.k3 value

        "k4" ->
            Svg.Attributes.k4 value

        "mode" ->
            Svg.Attributes.mode value

        "dx" ->
            Svg.Attributes.dx value

        "dy" ->
            Svg.Attributes.dy value

        "radius" ->
            Svg.Attributes.radius value

        "flood-color" ->
            Svg.Attributes.floodColor value

        "surfaceScale" ->
            Svg.Attributes.surfaceScale value

        "specularConstant" ->
            Svg.Attributes.specularConstant value

        "specularExponent" ->
            Svg.Attributes.specularExponent value

        "diffuseConstant" ->
            Svg.Attributes.diffuseConstant value

        "lighting-color" ->
            Svg.Attributes.lightingColor value

        "x" ->
            Svg.Attributes.x value

        "y" ->
            Svg.Attributes.y value

        "z" ->
            Svg.Attributes.z value

        "azimuth" ->
            Svg.Attributes.azimuth value

        "elevation" ->
            Svg.Attributes.elevation value

        "pointsAtX" ->
            Svg.Attributes.pointsAtX value

        "pointsAtY" ->
            Svg.Attributes.pointsAtY value

        "pointsAtZ" ->
            Svg.Attributes.pointsAtZ value

        "limitingConeAngle" ->
            Svg.Attributes.limitingConeAngle value

        _ ->
            VirtualDom.attribute key value
