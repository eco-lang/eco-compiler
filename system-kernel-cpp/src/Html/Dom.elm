module Html.Dom exposing
    ( Node(..), Fact(..), Tagger, Handler
    , fromHtml, fromAttribute
    , attributes, toString, htmlToString
    )

{-| `Html` is opaque in elm/html, so a program can build a page but can neither look inside it
nor turn it into text. This module gives every `Html` and `Svg` value (a `VirtualDom.Node`) a
transparent view, [`Node`](#Node), and serializes it to HTML text.

[`fromHtml`](#fromHtml) turns any `Html msg` into a `Node` you can pattern-match on, and
[`fromAttribute`](#fromAttribute) turns an `Html.Attribute msg` into a [`Fact`](#Fact): one
attribute, namespaced attribute, property, style or event handler of an element.
[`toString`](#toString) serializes a `Node`, [`htmlToString`](#htmlToString) serializes `Html`,
and [`attributes`](#attributes) gives the attributes an element's opening tag gets.

    import Html exposing (div, text)
    import Html.Attributes exposing (class)
    import Html.Dom

    Html.Dom.htmlToString (div [ class "greeting" ] [ text "Hello & welcome" ])
        --> "<div class=\"greeting\">Hello &amp; welcome</div>"

**One serialization, two implementations.** `toString` is written in Elm, over a `Node`;
`htmlToString` is the kernel's, over `Html`, and the two produce the same text. On the native
target an `Html` value already is a `Node`, so `fromHtml` and `fromAttribute` cost nothing and
`htmlToString` is a C++ copy of `toString`'s rules. On the JavaScript target `fromHtml` copies
the tree into a `Node` and `htmlToString` is `toString` applied to that copy. On the JavaScript
target the order of an element's attributes may differ from the native target, and so may the
`class` joined from several `className` properties when one of their values is not a string.

**Which attributes are written.** The facts of an element are combined before they are
written:

  - Attributes, namespaced attributes and styles are each applied as one group, at the position
    of the first fact of their kind; each property is applied at the position of its first
    occurrence. Between two facts of one kind with the same name, the later wins, except that
    `class` attributes are joined with a space, and so are `className` properties.
  - On an HTML element (one with no namespace) the names of attributes, but not of namespaced
    attributes, are lower-cased. A namespaced attribute is written under its name alone; its
    namespace is not written.
  - A property that has a matching attribute is written as that attribute: `className` as
    `class`, `htmlFor` as `for`, `id`, `href`, `title` and the like under their own names.
    Every property that an `Html.Attributes` function other than `property` and `value` makes
    is one of these.
    A boolean property such as `checked` or `disabled` is written as a bare attribute when its
    value is true in JavaScript's sense, and removes the attribute otherwise; `contentEditable`
    and `spellcheck` are exceptions, written with their value as text. `value` is the
    content of an HTML `textarea`, is not written on a `select` or on a namespaced `textarea`,
    and is the `value` attribute on other elements. Any other property, such as `innerHTML`, is
    not written.
  - Styles are written as declarations in the `style` attribute. A camel-case name is written
    in CSS form (`backgroundColor` as `background-color`), and an empty value removes the
    declaration. A `style` attribute applied after styles replaces them.
  - Event handlers are never written.

**How text is written.** Text is escaped (`&`, `<`, `>`, `"` and `'`), and so are attribute
values (`&`, `"`, `<` and `>`). The one exception is the text of an HTML `style` element, which
is written as it is except that `</` becomes `<\/`. An HTML void element (`br`, `img`, ...) gets
no closing tag and its children are dropped. A _token-breaking_ name is one that would break the
markup: an empty name, or one containing an ASCII space or control character, `"`, `'`, `<`,
`>`, `/`, or, in an attribute name, `=`. An attribute with such a name is dropped, and an element
with such a tag is replaced by its children. Neither `toString` nor `htmlToString` writes
`<!DOCTYPE html>`; [`Http.Server.setBodyAsHtml`](Http-Server#setBodyAsHtml) adds one when the
root element is `html`.

**What is not modelled.** A string-valued property whose value is an array or an object is not
written. Text inside `script`, `xmp`, `iframe`, `noembed`, `noframes` and `noscript` is
escaped like any other text.

**Laziness.** An `Html.Lazy` subtree is always computed: natively when the node is built, on
the JavaScript target each time `fromHtml` or `htmlToString` reaches it.

**Equality.** `==` on a `Node` that contains a `Mapped` node or an `Event` fact compares the
functions and decoders inside them, so it has the same restriction as `==` on `Html`.

@docs Node, Fact, Tagger, Handler


# Converting

@docs fromHtml, fromAttribute


# Rendering

@docs attributes, toString, htmlToString

-}

import Eco.Kernel.Dom
import Json.Decode as Decode
import Json.Encode
import VirtualDom


{-| A node of an `Html` or `Svg` tree, as data.

`Text` is a text node. Its string is escaped when serialized, except inside an HTML `style`
element.

`Element` carries the namespace, the tag, the facts and the children. The namespace is
`Nothing` for an HTML element and `Just` the namespace given to `VirtualDom.nodeNS` otherwise
(the SVG namespace for an `Svg` node).

`KeyedElement` is a keyed element, such as one made with `Html.Keyed`, laid out like `Element`
except that each child is paired with its key. The keys are not serialized.

`Mapped` is a node made with `Html.map`: it keeps the function, and the node it wraps is the one
serialized.

A [`Tagger`](#Tagger) can only come from `fromHtml` or `fromAttribute`, so a program can build
`Text`, `Element` and `KeyedElement` nodes from scratch, but a `Mapped` node only around a
`Tagger` taken from one of those.

-}
type Node
    = Text String
    | Element (Maybe String) String (List Fact) (List Node)
    | KeyedElement (Maybe String) String (List Fact) (List ( String, Node ))
    | Mapped Tagger Node


{-| One fact of an element: an `Html.Attribute`, as data.

`Attribute` carries a name and a value.

`AttributeNS` carries the namespace, then the name and the value.

`Property` sets a DOM property to a JSON value. Many `Html.Attributes` functions make
properties rather than attributes: `Html.Attributes.class` is `Property "className"`, and
`Html.Attributes.checked` is `Property "checked"`.

`Style` carries a CSS property name, as given to `Html.Attributes.style`, and its value.

`Event` carries the event name, the [`Handler`](#Handler) and a list of
[`Tagger`](#Tagger)s. Natively the list holds the functions given to `Html.Attributes.map`,
outermost first; on the JavaScript target it is always empty, because elm/virtual-dom folds
those functions into the handler. A `Handler` can only come from `fromHtml` or
`fromAttribute`, so a program can build an `Event` fact only with a `Handler` taken from one of
those.

-}
type Fact
    = Attribute String String
    | AttributeNS String String String
    | Property String Json.Encode.Value
    | Style String String
    | Event String Handler (List Tagger)


{-| A function given to `Html.map` or `Html.Attributes.map`, as kept in a `Mapped` node or an
`Event` fact.

A value can only be obtained from [`fromHtml`](#fromHtml) or [`fromAttribute`](#fromAttribute),
and nothing in this module applies one.

-}
type Tagger
    = Tagger


{-| An event handler: a `VirtualDom.Handler`, which holds the decoder for the event and says
how its message is handled.

A value can only be obtained from [`fromHtml`](#fromHtml) or [`fromAttribute`](#fromAttribute),
and nothing in this module uses one.

-}
type Handler
    = Handler


{-| Returns the `Node` view of any `Html msg` or `Svg msg`.

On the native target this costs nothing, because an `Html` value already is a `Node`. On the
JavaScript target the tree is copied, computing every `Html.Lazy` subtree. Each element's facts
arrive already combined by elm/virtual-dom, where natively they are the list as given. On the
JavaScript target a node made by a kernel's custom renderer becomes an empty `div` with that
node's facts.

-}
fromHtml : VirtualDom.Node msg -> Node
fromHtml =
    Eco.Kernel.Dom.fromNode


{-| Returns the `Fact` view of any `Html.Attribute msg`.
-}
fromAttribute : VirtualDom.Attribute msg -> Fact
fromAttribute =
    Eco.Kernel.Dom.fromAttribute


{-| Returns the HTML text of an `Html` or `Svg` value: the same text as `toString (fromHtml html)`.

The result has no `<!DOCTYPE html>`. Add one yourself for a whole document, or use
[`Http.Server.setBodyAsHtml`](Http-Server#setBodyAsHtml), which adds it when the root element
is `html`.

-}
htmlToString : VirtualDom.Node msg -> String
htmlToString =
    Eco.Kernel.Dom.toString


{-| Returns the attributes `toString` writes in an element's opening tag, in order and with
their values unescaped, after the facts have been combined as the module documentation
describes. `Nothing` is a bare attribute, such as `checked`. A `Mapped` node gives the
attributes of the node it wraps, and a `Text` node gives none.

For an element whose tag is token-breaking, which `toString` replaces by its children, this
still returns the attributes the element would have had.

-}
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


{-| One step of serialization still to do. `Visit` writes a node, with `True` when its text is
the raw text of an HTML `style` element. `Emit` writes text that is already HTML, such as a
closing tag.
-}
type Work
    = Visit Bool Node
    | Emit String


{-| Returns the HTML text of a `Node`, by the rules in the module documentation. For a
`Node` made by `fromHtml html` it produces the same text as [`htmlToString`](#htmlToString)
`html`.
-}
toString : Node -> String
toString node =
    renderLoop [ Visit False node ] []


{-| Returns the text already written, `acc`, which holds its pieces newest first, followed by
the HTML text of `work`.

The pending steps are an explicit list rather than a recursion over the tree, so a deep tree
does not deepen the stack.

-}
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


{-| Returns `rest` preceded by the steps that write one element: its opening tag, then its
content and closing tag, which are left out for an HTML void element. The content of an HTML
`textarea` with a `value` property that is not an array or an object is that value; otherwise
it is the children, as raw text inside an HTML `style` element. An element with a
token-breaking tag is replaced by its children.
-}
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


{-| The lower-cased tags of the HTML elements that have no closing tag and no content.
-}
voidElements : List String
voidElements =
    [ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" ]


{-| Returns the attributes as they appear in an opening tag, each preceded by a space.
-}
renderAttrs : List ( String, Maybe String ) -> String
renderAttrs attrs =
    String.concat (List.map renderAttr attrs)


{-| Returns one attribute as it appears in an opening tag, preceded by a space: the bare name
for `Nothing`, otherwise the name and the escaped value in double quotes.
-}
renderAttr : ( String, Maybe String ) -> String
renderAttr ( name, value ) =
    case value of
        Nothing ->
            " " ++ name

        Just v ->
            " " ++ name ++ "=\"" ++ escapeAttr v ++ "\""



-- RESOLVE: elm/virtual-dom's _VirtualDom_organizeFacts followed by _VirtualDom_applyFacts


{-| What an element's facts come to: the attributes of its opening tag, in order, and, for a
`textarea`, the text a `value` property gives it.
-}
type alias Resolved =
    { attrs : List ( String, Maybe String )
    , textareaValue : Maybe String
    }


{-| A property's JSON value, classified by what the serializer does with it. `PCompound` is an
array or an object.
-}
type PropValue
    = PString String
    | PBool Bool
    | PNumber Float
    | PNull
    | PCompound


{-| One position in the order in which an element's facts are applied. `StyleSlot`,
`AttrSlot` and `AttrNSSlot` stand for every fact of their kind, applied together, and
`PropSlot` for one property, with its value.
-}
type Slot
    = StyleSlot
    | AttrSlot
    | AttrNSSlot
    | PropSlot String PropValue


{-| An element's facts after grouping: the order of the slots, and the latest value of each
style, attribute and namespaced attribute by name (for `class`, the values joined), in order of
first appearance.
-}
type alias Organized =
    { slots : List Slot
    , styles : List ( String, String )
    , attrs : List ( String, String )
    , attrsNS : List ( String, String )
    }


{-| The state of an element while its slots are applied.

The `style` attribute's entry in `attrs` holds no value until the end, when its value is built
from `styleRaw`, the text of the last `style` attribute applied, and the declarations in
`styleProps`. `textareaValue` is the text a `value` property gives a `textarea`.

-}
type alias Applied =
    { attrs : List ( String, Maybe String )
    , styleRaw : String
    , styleProps : List ( String, String )
    , textareaValue : Maybe String
    }


{-| How a property is written. `AsString` writes it as the named attribute, with the
property's value as text. `AsBool` writes the named attribute bare when the value is true in
JavaScript's sense and removes it otherwise. `AsValue` is the `value` property, whose effect
depends on the tag. `NoReflect` writes nothing.
-}
type Reflect
    = AsString String
    | AsBool String
    | AsValue
    | NoReflect


{-| Returns what `facts` come to on an element with namespace `ns` and the lower-cased tag
`lowerTag`: the facts are grouped into slots and the slots applied in order.
-}
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


{-| Returns `o` with one more fact recorded. A later attribute, namespaced attribute, style or
property replaces an earlier one with the same name, except that `class` attributes, and
`className` properties, are joined with a space. Events are ignored.
-}
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


{-| Returns `st` with one slot applied. An attribute slot applies every attribute, with its
name lower-cased when `isHtml`; a style or namespaced attribute slot applies every fact of its
kind; a property slot applies that property.
-}
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


{-| Returns `st` with the property `key` applied as the attribute it is written as, if any. The
`value` property is recorded as the text of a `textarea`, which `expand` writes only for an
HTML `textarea`; it is ignored on a `select`, and is the `value` attribute on any other element.
-}
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


{-| Returns `st` with the attribute `name` set to the text of `value`, or `st` unchanged when
the value is an array or an object.
-}
setString : String -> PropValue -> Applied -> Applied
setString name value st =
    case jsString value of
        Just s ->
            setAttr name (Just s) st

        Nothing ->
            st


{-| Returns `st` with the attribute `name` set, or `st` unchanged when `name` is
token-breaking. Setting `style` replaces the style text and discards the declarations applied
so far.
-}
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


{-| Returns `st` without the attribute `name`.
-}
removeAttr : String -> Applied -> Applied
removeAttr name st =
    { st | attrs = List.filter (\( n, _ ) -> n /= name) st.attrs }


{-| Returns `st` with the declaration for the style `key` set to `value`, adding a `style`
attribute if there is none yet. An empty `value` removes the declaration instead.
-}
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


{-| Returns the attribute unchanged unless it is `style`, whose value becomes the style text
followed by the declarations, with a `;` between them when the text does not already end in
one.
-}
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


{-| Returns how the property `key` is written. The name is matched exactly, so `classname` is
not `className`.
-}
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


{-| The properties written as the attribute of the same name, with their value as text.
-}
sameNameString : List String
sameNameString =
    [ "accept", "action", "align", "alt", "autocomplete", "cite", "coords", "dir", "download"
    , "dropzone", "enctype", "headers", "href", "hreflang", "id", "kind", "label", "lang", "max"
    , "method", "min", "name", "pattern", "ping", "placeholder", "poster", "preload", "sandbox"
    , "scope", "shape", "span", "src", "srcdoc", "srclang", "start", "step", "target", "title"
    , "type", "wrap"
    ]


{-| The boolean properties written as the bare attribute of the same name.
-}
sameNameBool : List String
sameNameBool =
    [ "autofocus", "autoplay", "checked", "controls", "default", "disabled", "hidden", "loop"
    , "multiple", "required", "reversed", "selected"
    ]


{-| Returns the classification of a property's JSON value.
-}
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


{-| Returns the text JavaScript's `String()` gives a value that is not an array or an object,
with numbers printed by `String.fromFloat`; `Nothing` for an array or an object.
-}
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


{-| Returns whether a value is true in JavaScript's sense: an empty string, `false`, `0`, NaN
and `null` are not; arrays and objects are.
-}
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


{-| Returns the value of the first entry named `key`, if any.
-}
lookup : String -> List ( String, v ) -> Maybe v
lookup key entries =
    List.filter (\( k, _ ) -> k == key) entries
        |> List.head
        |> Maybe.map Tuple.second


{-| Returns `entries` with the entry named `key` given `value` in its place, or with a new entry
at the end when there is none.
-}
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


{-| Returns two class lists joined with a space, or `new` alone when `old` is empty.
-}
joinClass : String -> String -> String
joinClass old new =
    if old == "" then
        new

    else
        old ++ " " ++ new


{-| Returns `slots` with `slot` at the end, unless it is already there.
-}
addSlot : Slot -> List Slot -> List Slot
addSlot slot slots =
    if List.member slot slots then
        slots

    else
        slots ++ [ slot ]


{-| Returns `slots` with the property `key` merged into its slot, or with a new slot for it at
the end when there is none.
-}
upsertProp : String -> PropValue -> List Slot -> List Slot
upsertProp key value slots =
    if List.any (isPropSlot key) slots then
        List.map (mergePropSlot key value) slots

    else
        slots ++ [ PropSlot key value ]


{-| Returns whether `slot` is the slot of the property `key`.
-}
isPropSlot : String -> Slot -> Bool
isPropSlot key slot =
    case slot of
        PropSlot k _ ->
            k == key

        _ ->
            False


{-| Returns the slot of the property `key` with `value` in place of its old value, or, for
`className`, with the two joined with a space. Any other slot is returned unchanged.
-}
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


{-| Returns the text of a value, or the empty string for an array or an object.
-}
jsStringOrEmpty : PropValue -> String
jsStringOrEmpty value =
    Maybe.withDefault "" (jsString value)



-- TEXT HELPERS


{-| Returns whether `name` would break the markup if written as a tag, or as an attribute name
when `isAttribute`: it is empty, or holds a character for which `breaksToken` is true.
-}
isTokenBreaking : Bool -> String -> Bool
isTokenBreaking isAttribute name =
    String.isEmpty name || String.any (breaksToken isAttribute) name


{-| Returns whether `c` cannot appear in a tag, or in an attribute name when `isAttribute`: an
ASCII space or control character, `"`, `'`, `<`, `>`, `/`, and, in an attribute name, `=`.
-}
breaksToken : Bool -> Char -> Bool
breaksToken isAttribute c =
    let
        code =
            Char.toCode c
    in
    code <= 0x20 || code == 0x7F || c == '"' || c == '\'' || c == '<' || c == '>' || c == '/' || (isAttribute && c == '=')


{-| Returns `s` with its ASCII capital letters lower-cased and every other character unchanged.
-}
asciiLower : String -> String
asciiLower =
    String.map lowerChar


{-| Returns the lower-case letter for an ASCII capital, and any other character unchanged.
-}
lowerChar : Char -> Char
lowerChar c =
    if Char.isUpper c then
        Char.fromCode (Char.toCode c + 32)

    else
        c


{-| Returns the CSS form of a style name. A name with a `-` or no capital letter is already
in CSS form. `cssFloat` is `float`; any other camel-case name has each capital replaced by
`-` and its lower case (`backgroundColor` is `background-color`), with a leading `-` added for
the vendor prefixes `webkit`, `moz`, `ms` and `o`.
-}
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


{-| Returns `s` with `&`, `<`, `>`, `"` and `'` replaced by character references, for use as text.
-}
escapeText : String -> String
escapeText s =
    s
        |> String.replace "&" "&amp;"
        |> String.replace "<" "&lt;"
        |> String.replace ">" "&gt;"
        |> String.replace "\"" "&quot;"
        |> String.replace "'" "&#039;"


{-| Returns `s` with `&`, `"`, `<` and `>` replaced by character references, for use as a
double-quoted attribute value.
-}
escapeAttr : String -> String
escapeAttr s =
    s
        |> String.replace "&" "&amp;"
        |> String.replace "\"" "&quot;"
        |> String.replace "<" "&lt;"
        |> String.replace ">" "&gt;"


{-| Returns the text of an HTML `style` element as written: unescaped, except that `</` becomes
`<\/`, so that the text cannot close the element.
-}
rawText : String -> String
rawText =
    String.replace "</" "<\\/"
