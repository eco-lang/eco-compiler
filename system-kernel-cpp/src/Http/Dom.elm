module Http.Dom exposing
    ( Node(..), Fact(..), Tagger, Handler
    , fromNode, fromAttribute
    , attributes, render, toString
    )

{-| A transparent view of [`Html`](/packages/elm/html/latest/Html#Html) and `Svg` values (that
is, `VirtualDom.Node` values), and their serialization to HTML text.

`Html` is opaque in elm/html, so a server could otherwise build pages but never send them.
[`fromNode`](#fromNode) turns any `Html msg` into a [`Node`](#Node) you can pattern-match on,
and [`toString`](#toString) renders it. To answer an HTTP request with a page, use
[`Http.Server.Response.setBodyAsHtml`](Http-Server-Response#setBodyAsHtml), which serializes
straight into the response without building a `String` first.

    import Html exposing (div, text)
    import Html.Attributes exposing (class)
    import Http.Dom

    Http.Dom.toString (div [ class "greeting" ] [ text "Hello & welcome" ])
        --> "<div class=\"greeting\">Hello &amp; welcome</div>"

**What the serializer produces.** Attributes are the ones a browser would end up with after
Elm renders the node: properties such as `class` or `checked` become their attributes, later
facts win over earlier ones as they do in the browser, and properties that have no attribute
(such as `innerHTML`, which the XSS filters rename anyway) are left out. All text and attribute
values are escaped, and the text of a `<style>` element has `</` written as `<\/`. A tag or
attribute name that would break the markup (an empty name, or one containing whitespace, a
control character, a quote, `<`, `>`, `/`, or `=` in an attribute name) is not written: such an
attribute is dropped, and such an element is replaced by its children.

**Known differences from a browser:** children of void elements (`br`, `img`, …) are dropped;
the `value` of a `select` does not mark an option as selected; text inside `xmp`, `iframe`,
`noembed`, `noframes` and `noscript` is escaped; a `null` property is written as `"null"` and
array or object properties are not written; the attribute order follows the order Elm applies
facts in, which can differ from a browser's for properties with integer-like names. On the
JavaScript target the attribute order, the text of numbers and the bytes of a lone surrogate may
differ from the native target.

**Laziness.** `Html.Lazy` is evaluated eagerly when the node is built, so a `lazy` subtree is
always computed, even if it is never rendered.

**Equality.** `==` on a `Node` that contains an [`Event`](#Fact) or a [`Mapped`](#Node) node
compares functions, so it has the same restriction as `==` on `Html`.

@docs Node, Fact, Tagger, Handler


# Converting

@docs fromNode, fromAttribute


# Rendering

@docs attributes, render, toString

-}

import Eco.Kernel.Dom
import Json.Decode as Decode
import Json.Encode
import VirtualDom


{-| A DOM node. `Element` and `KeyedElement` carry the namespace (`Nothing` for HTML, `Just`
the SVG namespace for `Svg` nodes), the tag, the facts and the children; a keyed element's
children are paired with their keys. `Mapped` is a node made with `Html.map`: the function
is kept, and the node it wraps is the one rendered.
-}
type Node
    = Text String
    | Element (Maybe String) String (List Fact) (List Node)
    | KeyedElement (Maybe String) String (List Fact) (List ( String, Node ))
    | Mapped Tagger Node


{-| What an `Html.Attribute` is made of. `Attribute` and `AttributeNS` set attributes (the
namespace comes first), `Property` sets a DOM property to a JSON value (`Html.Attributes.class`
is `Property "className" …`), `Style` sets one CSS property, and `Event` is an event handler
with the functions given to `Html.Attributes.map`, outermost first.
-}
type Fact
    = Attribute String String
    | AttributeNS String String String
    | Property String Json.Encode.Value
    | Style String String
    | Event String Handler (List Tagger)


{-| The function given to `Html.map` or `Html.Attributes.map`. Opaque. -}
type Tagger
    = Tagger


{-| An event handler (`VirtualDom.Handler msg`). Opaque. -}
type Handler
    = Handler


{-| View any `Html msg` (or `Svg msg`) as a `Node`. On the native target this costs nothing:
an `Html` value already is a `Node`.
-}
fromNode : VirtualDom.Node msg -> Node
fromNode =
    Eco.Kernel.Dom.fromNode


{-| View any `Html.Attribute msg` as a `Fact`.
-}
fromAttribute : VirtualDom.Attribute msg -> Fact
fromAttribute =
    Eco.Kernel.Dom.fromAttribute


{-| Serialize `Html` (or `Svg`) to HTML text. The result has no `<!DOCTYPE html>`; add one
yourself for a whole document, or use `Http.Server.Response.setBodyAsHtml`, which adds it when
the root element is `html`.

This is `render << fromNode`, computed natively without building a `Node` view first.
-}
toString : VirtualDom.Node msg -> String
toString =
    Eco.Kernel.Dom.toString


{-| The attributes the browser would end up with, in order. `Nothing` is a bare boolean attribute. -}
attributes : Node -> List ( String, Maybe String )
attributes node =
    case node of
        Element ns tag facts _ ->
            (resolve ns (asciiLower tag) facts).attrs

        KeyedElement ns tag facts _ ->
            (resolve ns (asciiLower tag) facts).attrs

        Mapped _ inner ->
            attributes inner

        Text _ ->
            []



-- RENDER


type Work
    = Visit Bool Node
    | Emit String


{-| Serialize a `Node` to HTML text, exactly as [`toString`](#toString) does.
-}
render : Node -> String
render node =
    renderLoop [ Visit False node ] []


renderLoop : List Work -> List String -> String
renderLoop work acc =
    case work of
        [] ->
            String.concat (List.reverse acc)

        (Emit s) :: rest ->
            renderLoop rest (s :: acc)

        (Visit raw node) :: rest ->
            case node of
                Text s ->
                    renderLoop rest
                        ((if raw then
                            rawText s

                          else
                            escapeText s
                         )
                            :: acc
                        )

                Mapped _ inner ->
                    renderLoop (Visit raw inner :: rest) acc

                Element ns tag facts kids ->
                    renderLoop (expand ns tag facts kids rest) acc

                KeyedElement ns tag facts kids ->
                    renderLoop (expand ns tag facts (List.map Tuple.second kids) rest) acc


expand : Maybe String -> String -> List Fact -> List Node -> List Work -> List Work
expand ns tag facts kids rest =
    if isTokenBreaking False tag then
        List.map (Visit False) kids ++ rest

    else
        let
            lowerTag =
                asciiLower tag

            isHtml =
                ns == Nothing

            resolved =
                resolve ns lowerTag facts

            open =
                Emit ("<" ++ tag ++ renderAttrs resolved.attrs ++ ">")

            close =
                Emit ("</" ++ tag ++ ">")
        in
        if isHtml && List.member lowerTag voidElements then
            open :: rest

        else
            case ( isHtml && lowerTag == "textarea", resolved.textareaValue ) of
                ( True, Just value ) ->
                    open :: Emit (escapeText value) :: close :: rest

                _ ->
                    open :: List.map (Visit (isHtml && lowerTag == "style")) kids ++ (close :: rest)


voidElements : List String
voidElements =
    [ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" ]


renderAttrs : List ( String, Maybe String ) -> String
renderAttrs attrs =
    String.concat (List.map renderAttr attrs)


renderAttr : ( String, Maybe String ) -> String
renderAttr ( name, value ) =
    case value of
        Nothing ->
            " " ++ name

        Just v ->
            " " ++ name ++ "=\"" ++ escapeAttr v ++ "\""



-- RESOLVE: _VirtualDom_organizeFacts followed by _VirtualDom_applyFacts (plan §8.5)


type alias Resolved =
    { attrs : List ( String, Maybe String )
    , textareaValue : Maybe String
    }


type PropValue
    = PString String
    | PBool Bool
    | PNumber Float
    | PNull
    | PCompound


type Slot
    = StyleSlot
    | AttrSlot
    | AttrNSSlot
    | PropSlot String PropValue


type alias Organized =
    { slots : List Slot
    , styles : List ( String, String )
    , attrs : List ( String, String )
    , attrsNS : List ( String, String )
    }


type alias Applied =
    { attrs : List ( String, Maybe String )
    , styleRaw : String
    , styleProps : List ( String, String )
    , textareaValue : Maybe String
    }


type Reflect
    = AsString String
    | AsBool String
    | AsValue
    | NoReflect


resolve : Maybe String -> String -> List Fact -> Resolved
resolve ns lowerTag facts =
    let
        organized =
            List.foldl organizeFact { slots = [], styles = [], attrs = [], attrsNS = [] } facts

        applied =
            List.foldl (applySlot (ns == Nothing) lowerTag organized)
                { attrs = [], styleRaw = "", styleProps = [], textareaValue = Nothing }
                organized.slots
    in
    { attrs = List.map (finishStyle applied) applied.attrs
    , textareaValue = applied.textareaValue
    }


organizeFact : Fact -> Organized -> Organized
organizeFact fact o =
    case fact of
        Attribute k v ->
            { o
                | slots = addSlot AttrSlot o.slots
                , attrs =
                    case ( k == "class", lookup k o.attrs ) of
                        ( True, Just old ) ->
                            upsert k (joinClass old v) o.attrs

                        _ ->
                            upsert k v o.attrs
            }

        AttributeNS _ k v ->
            { o | slots = addSlot AttrNSSlot o.slots, attrsNS = upsert k v o.attrsNS }

        Style k v ->
            { o | slots = addSlot StyleSlot o.slots, styles = upsert k v o.styles }

        Property k json ->
            { o | slots = upsertProp k (propValue json) o.slots }

        Event _ _ _ ->
            o


applySlot : Bool -> String -> Organized -> Slot -> Applied -> Applied
applySlot isHtml lowerTag o slot st =
    case slot of
        StyleSlot ->
            List.foldl (\( k, v ) acc -> setStyle k v acc) st o.styles

        AttrSlot ->
            List.foldl
                (\( k, v ) acc ->
                    setAttr
                        (if isHtml then
                            asciiLower k

                         else
                            k
                        )
                        (Just v)
                        acc
                )
                st
                o.attrs

        AttrNSSlot ->
            List.foldl (\( k, v ) acc -> setAttr k (Just v) acc) st o.attrsNS

        PropSlot k value ->
            reflectProp lowerTag k value st


reflectProp : String -> String -> PropValue -> Applied -> Applied
reflectProp lowerTag key value st =
    case reflection key of
        AsString name ->
            setString name value st

        AsBool name ->
            if truthy value then
                setAttr name Nothing st

            else
                removeAttr name st

        AsValue ->
            if lowerTag == "textarea" then
                { st | textareaValue = jsString value }

            else if lowerTag == "select" then
                st

            else
                setString "value" value st

        NoReflect ->
            st


setString : String -> PropValue -> Applied -> Applied
setString name value st =
    case jsString value of
        Just s ->
            setAttr name (Just s) st

        Nothing ->
            st


setAttr : String -> Maybe String -> Applied -> Applied
setAttr name value st =
    if isTokenBreaking True name then
        st

    else if name == "style" then
        { st
            | attrs = upsert "style" Nothing st.attrs
            , styleRaw = Maybe.withDefault "" value
            , styleProps = []
        }

    else
        { st | attrs = upsert name value st.attrs }


removeAttr : String -> Applied -> Applied
removeAttr name st =
    { st | attrs = List.filter (\( n, _ ) -> n /= name) st.attrs }


setStyle : String -> String -> Applied -> Applied
setStyle key value st =
    let
        name =
            cssName key
    in
    if value == "" then
        { st | styleProps = List.filter (\( n, _ ) -> n /= name) st.styleProps }

    else
        { st
            | styleProps = upsert name value st.styleProps
            , attrs =
                if List.any (\( n, _ ) -> n == "style") st.attrs then
                    st.attrs

                else
                    st.attrs ++ [ ( "style", Nothing ) ]
        }


finishStyle : Applied -> ( String, Maybe String ) -> ( String, Maybe String )
finishStyle st ( name, value ) =
    if name == "style" then
        let
            props =
                String.concat (List.map (\( k, v ) -> k ++ ":" ++ v ++ ";") st.styleProps)
        in
        if props == "" || st.styleRaw == "" || String.endsWith ";" st.styleRaw then
            ( name, Just (st.styleRaw ++ props) )

        else
            ( name, Just (st.styleRaw ++ ";" ++ props) )

    else
        ( name, value )


reflection : String -> Reflect
reflection key =
    case key of
        "className" ->
            AsString "class"

        "htmlFor" ->
            AsString "for"

        "httpEquiv" ->
            AsString "http-equiv"

        "acceptCharset" ->
            AsString "accept-charset"

        "accessKey" ->
            AsString "accesskey"

        "useMap" ->
            AsString "usemap"

        "contentEditable" ->
            AsString "contenteditable"

        "spellcheck" ->
            AsString "spellcheck"

        "isMap" ->
            AsBool "ismap"

        "noValidate" ->
            AsBool "novalidate"

        "readOnly" ->
            AsBool "readonly"

        "value" ->
            AsValue

        _ ->
            if List.member key sameNameString then
                AsString key

            else if List.member key sameNameBool then
                AsBool key

            else
                NoReflect


sameNameString : List String
sameNameString =
    [ "accept", "action", "align", "alt", "autocomplete", "cite", "coords", "dir", "download"
    , "dropzone", "enctype", "headers", "href", "hreflang", "id", "kind", "label", "lang", "max"
    , "method", "min", "name", "pattern", "ping", "placeholder", "poster", "preload", "sandbox"
    , "scope", "shape", "span", "src", "srcdoc", "srclang", "start", "step", "target", "title"
    , "type", "wrap"
    ]


sameNameBool : List String
sameNameBool =
    [ "autofocus", "autoplay", "checked", "controls", "default", "disabled", "hidden", "loop"
    , "multiple", "required", "reversed", "selected"
    ]


propValue : Json.Encode.Value -> PropValue
propValue value =
    Decode.decodeValue
        (Decode.oneOf
            [ Decode.map PString Decode.string
            , Decode.map PBool Decode.bool
            , Decode.map PNumber Decode.float
            , Decode.null PNull
            , Decode.succeed PCompound
            ]
        )
        value
        |> Result.withDefault PCompound


jsString : PropValue -> Maybe String
jsString value =
    case value of
        PString s ->
            Just s

        PBool b ->
            Just
                (if b then
                    "true"

                 else
                    "false"
                )

        PNumber f ->
            Just (String.fromFloat f)

        PNull ->
            Just "null"

        PCompound ->
            Nothing


truthy : PropValue -> Bool
truthy value =
    case value of
        PString s ->
            s /= ""

        PBool b ->
            b

        PNumber f ->
            f /= 0 && not (isNaN f)

        PNull ->
            False

        PCompound ->
            True



-- ORGANIZE HELPERS


lookup : String -> List ( String, v ) -> Maybe v
lookup key entries =
    List.filter (\( k, _ ) -> k == key) entries
        |> List.head
        |> Maybe.map Tuple.second


upsert : String -> v -> List ( String, v ) -> List ( String, v )
upsert key value entries =
    if List.any (\( k, _ ) -> k == key) entries then
        List.map
            (\( k, old ) ->
                if k == key then
                    ( k, value )

                else
                    ( k, old )
            )
            entries

    else
        entries ++ [ ( key, value ) ]


joinClass : String -> String -> String
joinClass old new =
    if old == "" then
        new

    else
        old ++ " " ++ new


addSlot : Slot -> List Slot -> List Slot
addSlot slot slots =
    if List.member slot slots then
        slots

    else
        slots ++ [ slot ]


upsertProp : String -> PropValue -> List Slot -> List Slot
upsertProp key value slots =
    if List.any (isPropSlot key) slots then
        List.map (mergePropSlot key value) slots

    else
        slots ++ [ PropSlot key value ]


isPropSlot : String -> Slot -> Bool
isPropSlot key slot =
    case slot of
        PropSlot k _ ->
            k == key

        _ ->
            False


mergePropSlot : String -> PropValue -> Slot -> Slot
mergePropSlot key value slot =
    case slot of
        PropSlot k old ->
            if k /= key then
                slot

            else if key == "className" then
                PropSlot k (PString (joinClass (jsStringOrEmpty old) (jsStringOrEmpty value)))

            else
                PropSlot k value

        _ ->
            slot


jsStringOrEmpty : PropValue -> String
jsStringOrEmpty value =
    Maybe.withDefault "" (jsString value)



-- TEXT HELPERS


isTokenBreaking : Bool -> String -> Bool
isTokenBreaking isAttribute name =
    String.isEmpty name || String.any (breaksToken isAttribute) name


breaksToken : Bool -> Char -> Bool
breaksToken isAttribute c =
    let
        code =
            Char.toCode c
    in
    code <= 0x20 || code == 0x7F || c == '"' || c == '\'' || c == '<' || c == '>' || c == '/' || (isAttribute && c == '=')


asciiLower : String -> String
asciiLower =
    String.map lowerChar


lowerChar : Char -> Char
lowerChar c =
    if Char.isUpper c then
        Char.fromCode (Char.toCode c + 32)

    else
        c


cssName : String -> String
cssName key =
    if String.contains "-" key || not (String.any Char.isUpper key) then
        key

    else if key == "cssFloat" then
        "float"

    else
        let
            kebab =
                String.foldr
                    (\c acc ->
                        if Char.isUpper c then
                            "-" ++ String.cons (lowerChar c) acc

                        else
                            String.cons c acc
                    )
                    ""
                    key
        in
        if List.any (\p -> String.startsWith p kebab) [ "webkit-", "moz-", "ms-", "o-" ] then
            "-" ++ kebab

        else
            kebab


escapeText : String -> String
escapeText s =
    s
        |> String.replace "&" "&amp;"
        |> String.replace "<" "&lt;"
        |> String.replace ">" "&gt;"
        |> String.replace "\"" "&quot;"
        |> String.replace "'" "&#039;"


escapeAttr : String -> String
escapeAttr s =
    s
        |> String.replace "&" "&amp;"
        |> String.replace "\"" "&quot;"
        |> String.replace "<" "&lt;"
        |> String.replace ">" "&gt;"


rawText : String -> String
rawText =
    String.replace "</" "<\\/"
