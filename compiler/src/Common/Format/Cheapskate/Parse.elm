module Common.Format.Cheapskate.Parse exposing (markdown)

{-| The formatter re-prints the Markdown inside doc comments, and this module
reads the text of a doc comment into the `Common.Format.Cheapskate.Types` tree
it is printed from. It finds the blocks of the text, such as paragraphs,
headings, lists, block quotes and code blocks, and hands the text inside
paragraphs and headings to `Common.Format.Cheapskate.Inlines`. One block is
particular to Elm: a line that starts with `@docs` becomes an `ElmDocs` block.

The text is read in two phases. The first builds a tree of containers from the
lines, and the second turns that tree into blocks.

A _container_ is a block that holds other blocks or lines: the document
itself, a block quote, a list item, a code block, a block of raw HTML, or a link
reference definition. A _leaf_ is what one line adds to a container: a line of
text, a blank line, a heading or a horizontal rule. Code blocks, HTML blocks and
reference definitions are _verbatim_ containers: a line added straight to one on
top of the stack is kept as text.

While the lines are read, the containers still open form a stack with the
document at the bottom. The start of each line is matched against each open
container's _continuation_ in turn, from the bottom up: the `>` that continues a
block quote, for instance, or the indentation that continues a list item.
Matching stops at the first continuation that fails, and as a rule that
container and every one above it are closed, which makes each a child of the
container beneath it. Then the containers that the rest of the line starts are
opened, and the line's leaf is added to the container on top. A fenced code
block on top of the stack is an exception, staying open until a closing fence.
So is a reference definition on top of the stack: the next line closes it
whatever that line matches, and leaves the containers beneath it open. So too is
a _lazy continuation_: a line of text that opens nothing is added to the top
container, closing nothing, when that container is not indented code, a fenced
code block or a reference definition, and its oldest child is a line of text
(see below).

During the first phase, closing a reference definition reads it and, when it
can be read, logs it in a map keyed by
`Common.Format.Cheapskate.Util.normalizeReference` of its label, and otherwise
discards it. The map is passed to `parseInlines`, which does not consult it, so
it has no effect on the result; the definitions reach the document as a
`ReferencesBlock`.

In the second phase consecutive lines of text become a paragraph, consecutive
list items of one kind become a list, and the lines of a code block are joined.

The result departs from the source in several ways:

  - The lines are processed last first, because they are visited with
    `Common.Format.RWS.mapM_`, which runs on the last element first. So the
    document is built back to front: `"a\n\nb"` gives the paragraph `b` before
    the paragraph `a`, `"a\nb"` gives one paragraph with `b` on its first line,
    and the items of `"1. a\n2. b"` come out `b` first.
  - Containers as a rule keep their children newest first, and the tests that
    are meant to look at the line before the current one look at the top
    container's oldest child instead. These tests decide whether an underline of
    `=` or `-` makes a heading, whether a line may open an indented code block,
    an HTML block or a reference definition, and whether a line is a lazy
    continuation. So `"Title\n====="` is a paragraph while `"=====\nTitle"` is
    a heading, and `"    code\n\ntext"` is two paragraphs.
  - When one line opens several containers they are also pushed with
    `RWS.mapM_`, so the last one found ends up outermost: `"> 1. a"` gives a
    list whose item holds a block quote, and `"> <div>"` gives an HTML block
    holding a block quote, to which a later line can add a heading or a rule.
  - A bullet followed by text is never read as a list item, while a line holding
    only a bullet is an empty one; numbered items are read. A line of as few as
    two `*`, `_` or `-`, spaces aside, is a horizontal rule, unless a line of
    `-` is taken as a setext underline.

@docs markdown

-}

import Common.Format.Cheapskate.Inlines exposing (pHtmlTag, pLinkLabel, pReference, parseInlines)
import Common.Format.Cheapskate.ParserCombinators
    exposing
        ( Parser
        , Position(..)
        , andThen
        , apply
        , char
        , count
        , endOfInput
        , getPosition
        , guard
        , lookAhead
        , many
        , map
        , notFollowedBy
        , oneOf
        , option
        , parse
        , pure
        , return
        , satisfy
        , setPosition
        , showParseError
        , skip
        , skipWhile
        , string
        , takeText
        , takeWhile
        , takeWhile1
        , unless
        )
import Common.Format.Cheapskate.Types
    exposing
        ( Block(..)
        , Blocks
        , CodeAttr(..)
        , Doc(..)
        , HtmlTagType(..)
        , ListType(..)
        , NumWrapper(..)
        , ReferenceMap
        )
import Common.Format.Cheapskate.Util
    exposing
        ( Scanner
        , isWhitespace
        , joinLines
        , nfb
        , normalizeReference
        , scanBlankline
        , scanChar
        , scanIndentSpace
        , scanNonindentSpace
        , scanSpaces
        , scanSpacesToColumn
        , tabFilter
        , upToCountChars
        )
import Common.Format.RWS as RWS exposing (RWS)
import Dict
import List.Extra as List
import Set exposing (Set)
import Utils.Crash exposing (crash)



-- ====== PARSE ======


{-| Reads the Markdown text of a doc comment into a document.

The options are ignored. The document departs from the source in the ways the
module documentation lists; most visibly, its blocks come out in reverse source
order.

-}
markdown : String -> Doc
markdown =
    processLines >> processDocument >> Doc


{-| The containers open while the lines are read: first the innermost, which
the next line's content goes into, then the containers that enclose it,
innermost first, ending with the document.
-}
type ContainerStack
    = ContainerStack Container (List Container)


{-| The number of a line of the input, counting from 1.

This is a name for `Int`, not a new type. `processLines` numbers the lines, and
`processLine` does not use the number.

-}
type alias LineNumber =
    Int


{-| One child of a container. `C` is a container nested in it and `L` is a
leaf.
-}
type Elt
    = C Container
    | L Leaf


{-| A container: its kind and its children.

The children are kept newest first: each leaf added to the container, and each
container closed inside it, goes on the front of the list. The exception is a
list item that `closeContainer` closes after removing its oldest child, a blank
line, which keeps its other children oldest first.

-}
type Container
    = Container ContainerType (List Elt)


{-| The kind of a container, with what is needed to tell whether a later line
continues it.

`Document` is the whole text. It is at the bottom of the stack and is never
closed.

`BlockQuote` is a block quote.

`ListItem` is one item of a list. `markerColumn` is the column at which the
item's marker starts, and `padding` is how many columns after it the item's text
starts: the marker's width plus the spaces after it, or plus one when the marker
is followed by a blank rest of the line or by indented code.

`FencedCode` is a code block between fences. `startColumn` is the column at
which the fence that opened it starts, `fence` is that fence's run of backticks
or tildes, and `info` is the rest of its line.

`IndentedCode` is a code block indented by four spaces.

`RawHtmlBlock` is a block of HTML.

`Reference` is a link reference definition, `[label]: url "title"`.

The last four are the verbatim containers.

-}
type ContainerType
    = Document
    | BlockQuote
    | ListItem
        { markerColumn : Int
        , padding : Int
        , listType : ListType
        }
    | FencedCode
        { startColumn : Int
        , fence : String
        , info : String
        }
    | IndentedCode
    | RawHtmlBlock
    | Reference


{-| Returns the scanner that the start of a line must match to continue the
container, lazy continuations aside.

A block quote needs up to three spaces and a `>`, and takes one space after it
if there is one. Indented code needs four spaces. Fenced code needs the spaces
that bring the line to the fence's column. An HTML block needs a line that is
not blank. A reference definition needs a line that is not blank and does not
start, after up to three spaces, a link label followed by `:`. A list item needs
a blank line, or the spaces that reach the column after its marker's column,
after which up to `padding - 1` more spaces are taken. The document matches
every line.

-}
containerContinue : Container -> Scanner
containerContinue (Container containerType _) =
    case containerType of
        BlockQuote ->
            scanNonindentSpace |> andThen (\_ -> scanBlockquoteStart)

        IndentedCode ->
            scanIndentSpace

        FencedCode { startColumn } ->
            scanSpacesToColumn startColumn

        RawHtmlBlock ->
            nfb scanBlankline

        ListItem { markerColumn, padding } ->
            oneOf scanBlankline
                (scanSpacesToColumn (markerColumn + 1)
                    |> andThen (\_ -> upToCountChars (padding - 1) ((==) ' '))
                    |> andThen (\_ -> return ())
                )

        Reference ->
            nfb scanBlankline
                |> andThen (\_ -> nfb (scanNonindentSpace |> andThen (\_ -> scanReference)))

        _ ->
            return ()


{-| Produces a parser that reads, after up to three spaces, the marker that opens
a block quote or a list item, and returns the kind of container. The `Bool` is
ignored.
-}
containerStart : Parser ContainerType
containerStart =
    scanNonindentSpace
        |> andThen
            (\_ ->
                oneOf (map (\_ -> BlockQuote) scanBlockquoteStart)
                    parseListMarker
            )


{-| Produces a parser that reads, after up to three spaces, the start of a
verbatim container, and returns its kind.

A code fence is accepted whatever `lastLineIsText` is, and the rest of its line
is consumed. The others are accepted only when `lastLineIsText` is `False`: a
fourth space followed by something that is not blank opens indented code, and
the fourth space is consumed; the start of an HTML block, as
`parseHtmlBlockStart` reads it, opens an HTML block; and a link label followed
by `:` opens a reference definition. Neither of the last two consumes anything.

-}
verbatimContainerStart : Bool -> Parser ContainerType
verbatimContainerStart lastLineIsText =
    scanNonindentSpace
        |> andThen
            (\_ ->
                oneOf parseCodeFence
                    (oneOf
                        (guard (not lastLineIsText)
                            |> andThen
                                (\_ ->
                                    nfb scanBlankline
                                        |> andThen (\_ -> char ' ')
                                        |> map (\_ -> IndentedCode)
                                )
                        )
                        (oneOf (guard (not lastLineIsText) |> andThen (\_ -> map (\_ -> RawHtmlBlock) parseHtmlBlockStart))
                            (guard (not lastLineIsText) |> andThen (\_ -> map (\_ -> Reference) scanReference))
                        )
                    )
            )


{-| What one line adds to a container.

`TextLine` holds the rest of the line after its containers' markers. Up to
three spaces of indentation are removed as well, except from a line that
`processLine` adds straight to an open verbatim container: an HTML or indented
code block when every continuation matched, or a fenced code block on top of
the stack. A lazy continuation is read by `leaf` and loses them.

`BlankLine` holds a rest of the line, taken the same way, that is empty or only
whitespace.

`ATXHeader` is a heading written with leading `#`s. It holds the level, which is
the number of `#`s, and the text.

`SetextHeader` is a heading made by a line of `=`, level 1, or of `-`, level 2.
It holds the level and the text of the top container's oldest child, a text
line, which `processLine` replaces with it.

`Rule` is a horizontal rule.

-}
type Leaf
    = TextLine String
    | BlankLine String
    | ATXHeader Int String
    | SetextHeader Int String
    | Rule


{-| A step of the first phase. It reads and replaces the stack of open
containers, and logs the reference definitions it closes, keyed by
`normalizeReference` of the label, to URL and title.

This is a name for an `RWS` with no environment, not a new type.

-}
type alias ContainerM a =
    RWS () ContainerStack a


{-| Closes every open container except the one at the bottom of the stack, the
document, and returns that container.
-}
closeStack : ContainerM Container
closeStack =
    RWS.get
        |> RWS.andThen
            (\(ContainerStack top rest) ->
                if List.isEmpty rest then
                    RWS.return top

                else
                    closeContainer |> RWS.andThen (\_ -> closeStack)
            )


{-| Closes the container on top of the stack, making it the newest child of the
container beneath it. When the stack holds only one container, the stack is
left as it is.

Two kinds of container are treated differently:

  - A reference definition is read with `pReference` from the text of its
    children, joined with newlines and trimmed. When that succeeds, the
    definition is logged, keyed by `normalizeReference` of its label, and the
    container is closed as usual. When it fails, the container is discarded with
    everything in it.
  - A list item whose oldest child is a blank line loses that line, which
    becomes the parent's next child after the item, or is dropped when it was
    the item's only child. The item keeps its other children, but oldest first,
    the reverse of the order every other container keeps.

-}
closeContainer : ContainerM ()
closeContainer =
    RWS.get
        |> RWS.andThen
            (\(ContainerStack top rest) ->
                case top of
                    Container Reference cs__ ->
                        case parse pReference (String.trim <| joinLines <| List.map extractText cs__) of
                            Ok ( lab, lnk, tit ) ->
                                RWS.tell (Dict.singleton (normalizeReference lab) ( lnk, tit ))
                                    |> RWS.andThen
                                        (\_ ->
                                            case rest of
                                                (Container ct_ cs_) :: rs ->
                                                    RWS.put (ContainerStack (Container ct_ (C top :: cs_)) rs)

                                                [] ->
                                                    RWS.return ()
                                        )

                            Err _ ->
                                case rest of
                                    c :: cs ->
                                        RWS.put (ContainerStack c cs)

                                    [] ->
                                        RWS.return ()

                    Container ((ListItem _) as li) cs__ ->
                        case rest of
                            (Container ct_ cs_) :: rs ->
                                case List.reverse cs__ of
                                    ((L (BlankLine _)) as b) :: zs ->
                                        RWS.put
                                            (ContainerStack
                                                (if List.isEmpty zs then
                                                    Container ct_ (C (Container li zs) :: cs_)

                                                 else
                                                    Container ct_ (b :: C (Container li zs) :: cs_)
                                                )
                                                rs
                                            )

                                    _ ->
                                        RWS.put (ContainerStack (Container ct_ (C top :: cs_)) rs)

                            [] ->
                                RWS.return ()

                    _ ->
                        case rest of
                            (Container ct_ cs_) :: rs ->
                                RWS.put (ContainerStack (Container ct_ (C top :: cs_)) rs)

                            [] ->
                                RWS.return ()
            )


{-| Adds `lf` as the newest child of the container on top of the stack.

A blank line meant for a list item whose oldest child is a blank line closes the
item instead, and is then added to the container beneath by the same rule.

-}
addLeaf : Leaf -> ContainerM ()
addLeaf lf =
    RWS.get
        |> RWS.andThen
            (\(ContainerStack top rest) ->
                case ( top, lf ) of
                    ( Container ((ListItem _) as ct) cs, BlankLine _ ) ->
                        case List.reverse cs of
                            (L (BlankLine _)) :: _ ->
                                closeContainer
                                    |> RWS.andThen (\_ -> addLeaf lf)

                            _ ->
                                RWS.put (ContainerStack (Container ct (L lf :: cs)) rest)

                    ( Container ct cs, _ ) ->
                        RWS.put (ContainerStack (Container ct (L lf :: cs)) rest)
            )


{-| Opens an empty container of kind `ct` on top of the stack.
-}
addContainer : ContainerType -> ContainerM ()
addContainer ct =
    RWS.modify
        (\(ContainerStack top rest) ->
            ContainerStack (Container ct []) (top :: rest)
        )



-- ====== SECOND PHASE: CONTAINERS TO BLOCKS ======


{-| Returns the blocks of the document container that `processLines` built,
reading its children oldest first with `processElts`, to which the reference map
is passed on. It crashes when the container is not a `Document`, which
`processLines` never returns.
-}
processDocument : ( Container, ReferenceMap ) -> Blocks
processDocument ( Container ct cs, remap ) =
    case ct of
        Document ->
            processElts remap (List.reverse cs)

        _ ->
            crash "top level container is not Document"


{-| Returns the blocks that the elements `elts` stand for. The text of
paragraphs and headings is read with `parseInlines`, which is given `remap`.

The elements are taken from the front, and each one either starts a block or is
skipped:

  - A text line that starts with `@docs` starts an `ElmDocs` block, which also
    takes every text line directly after it, with any `@docs` at their start
    removed. Each line is split at its commas into trimmed names. Empty names,
    and lines left with no names, are dropped.
  - Any other text line starts a paragraph, which also takes the text lines
    directly after it up to one that starts with `@docs`. Each line loses its
    leading whitespace, and the joined text its trailing whitespace.
  - A blank line is skipped. A heading becomes a `Header` and a rule an `HRule`.
  - A block quote becomes a `Blockquote` of its children's blocks.
  - A list item starts a list, which also takes the list items after it that
    have the same bullet character, or the same punctuation after the number,
    with at most one blank line before each. The list takes the first item's
    list type. It is tight when no blank line comes between the items and none
    is a direct child of an item.
  - A fenced code block becomes a `CodeBlock` of its lines, with its `info`
    split at the first space into the language and the rest, trimmed.
  - An indented code block takes the indented code blocks and blank lines after
    it, and they become one `CodeBlock`, with trailing lines of only spaces
    removed.
  - An HTML block becomes an `HtmlBlock` of its lines.
  - A reference definition takes the reference definitions directly after it,
    and they become one `ReferencesBlock`, each line read again with
    `pReference`. A line that cannot be read gives `( "??", "??", "??" )`, but
    `closeContainer` has already discarded any reference container whose text
    could not be read.

Containers as a rule keep their children newest first (see `Container`), and a
container's children are reversed here before they are read, with three
exceptions. The first item of a list has its children reversed twice, so they
are read in the order the item keeps them, while the other items' children are
reversed once. Every indented code block but the first, and every reference
definition but the first, gives its lines unreversed. A `Document` among the
elements crashes.

-}
processElts : ReferenceMap -> List Elt -> Blocks
processElts remap elts =
    case elts of
        [] ->
            []

        (L lf) :: rest ->
            case lf of
                TextLine t ->
                    case stripPrefix "@docs" t of
                        Just terms1 ->
                            let
                                docs : List String
                                docs =
                                    terms1 :: List.map (extractText >> cleanDoc) docLines

                                ( docLines, rest_ ) =
                                    List.span isDocLine rest

                                isDocLine : Elt -> Bool
                                isDocLine elt =
                                    case elt of
                                        L (TextLine _) ->
                                            True

                                        _ ->
                                            False

                                cleanDoc : String -> String
                                cleanDoc lin =
                                    case stripPrefix "@docs" lin of
                                        Nothing ->
                                            lin

                                        Just stripped ->
                                            stripped
                            in
                            (List.map (List.filter ((/=) "") << List.map String.trim << String.split ",") docs |> List.filter ((/=) []) |> ElmDocs)
                                :: processElts remap rest_

                        Nothing ->
                            let
                                txt : String
                                txt =
                                    List.map String.trimLeft
                                        (t :: List.map extractText textlines)
                                        |> joinLines
                                        |> String.trimRight

                                ( textlines, rest_ ) =
                                    List.span isTextLine rest

                                isTextLine : Elt -> Bool
                                isTextLine elt =
                                    case elt of
                                        L (TextLine s) ->
                                            not (String.startsWith "@docs" s)

                                        _ ->
                                            False
                            in
                            Para (parseInlines remap txt)
                                :: processElts remap rest_

                BlankLine _ ->
                    processElts remap rest

                ATXHeader lvl t ->
                    (parseInlines remap t |> Header lvl)
                        :: processElts remap rest

                SetextHeader lvl t ->
                    (parseInlines remap t |> Header lvl)
                        :: processElts remap rest

                Rule ->
                    HRule :: processElts remap rest

        (C (Container ct csRev)) :: rest ->
            let
                cs =
                    List.reverse csRev

                isBlankLine : Elt -> Bool
                isBlankLine x =
                    case x of
                        L (BlankLine _) ->
                            True

                        _ ->
                            False

                tightListItem : List Elt -> Bool
                tightListItem xs =
                    case xs of
                        [] ->
                            True

                        _ ->
                            List.any isBlankLine xs |> not
            in
            case ct of
                Document ->
                    crash "Document container found inside Document"

                BlockQuote ->
                    (processElts remap cs |> Blockquote)
                        :: processElts remap rest

                ListItem { listType } ->
                    let
                        xs : List Elt
                        xs =
                            takeListItems rest

                        rest_ : List Elt
                        rest_ =
                            List.drop (List.length xs) rest

                        takeListItems : List Elt -> List Elt
                        takeListItems ys =
                            case ys of
                                (C ((Container (ListItem li_) _) as c)) :: zs ->
                                    if listTypesMatch li_.listType listType then
                                        C c :: takeListItems zs

                                    else
                                        []

                                ((L (BlankLine _)) as lf) :: ((C (Container (ListItem li_) _)) as c) :: zs ->
                                    if listTypesMatch li_.listType listType then
                                        lf :: c :: takeListItems zs

                                    else
                                        []

                                _ ->
                                    []

                        listTypesMatch : ListType -> ListType -> Bool
                        listTypesMatch listType_ listType__ =
                            case ( listType_, listType__ ) of
                                ( Bullet c1, Bullet c2 ) ->
                                    c1 == c2

                                ( Numbered w1 _, Numbered w2 _ ) ->
                                    w1 == w2

                                _ ->
                                    False

                        items : List (List Elt)
                        items =
                            List.filterMap getItem
                                (Container ct cs
                                    :: List.filterMap
                                        (\x ->
                                            case x of
                                                C c ->
                                                    Just c

                                                _ ->
                                                    Nothing
                                        )
                                        xs
                                )

                        getItem : Container -> Maybe (List Elt)
                        getItem container =
                            case container of
                                Container (ListItem _) cs_ ->
                                    Just (List.reverse cs_)

                                _ ->
                                    Nothing

                        items_ : List Blocks
                        items_ =
                            List.map (processElts remap) items

                        isTight : Bool
                        isTight =
                            tightListItem xs && List.all tightListItem items
                    in
                    List isTight listType items_ :: processElts remap rest_

                FencedCode { info } ->
                    let
                        txt : String
                        txt =
                            List.map extractText cs |> joinLines

                        attr : CodeAttr
                        attr =
                            CodeAttr { codeLang = x, codeInfo = String.trim y }

                        ( x, y ) =
                            stringBreak ((==) ' ') info
                    in
                    CodeBlock attr txt
                        :: processElts remap rest

                IndentedCode ->
                    let
                        txt : String
                        txt =
                            List.concatMap extractCode cbs |> stripTrailingEmpties |> joinLines

                        stripTrailingEmpties : List String -> List String
                        stripTrailingEmpties =
                            List.reverse >> List.dropWhile (String.all ((==) ' ')) >> List.reverse

                        -- A blank line has already lost up to three leading spaces; drop one more.
                        extractCode : Elt -> List String
                        extractCode elt =
                            case elt of
                                L (BlankLine t) ->
                                    [ String.dropLeft 1 t ]

                                C (Container IndentedCode cs_) ->
                                    List.map extractText cs_

                                _ ->
                                    []

                        ( cbs, rest_ ) =
                            List.span isIndentedCodeOrBlank
                                (C (Container ct cs) :: rest)

                        isIndentedCodeOrBlank : Elt -> Bool
                        isIndentedCodeOrBlank elt =
                            case elt of
                                L (BlankLine _) ->
                                    True

                                C (Container IndentedCode _) ->
                                    True

                                _ ->
                                    False
                    in
                    CodeBlock (CodeAttr { codeLang = "", codeInfo = "" }) txt
                        :: processElts remap rest_

                RawHtmlBlock ->
                    let
                        txt : String
                        txt =
                            joinLines (List.map extractText cs)
                    in
                    HtmlBlock txt :: processElts remap rest

                Reference ->
                    let
                        refs : List Elt -> List ( String, String, String )
                        refs cs_ =
                            List.map (extractText >> extractRef) cs_

                        extractRef : String -> ( String, String, String )
                        extractRef t =
                            case parse pReference (String.trim t) of
                                Ok ( lab, lnk, tit ) ->
                                    ( lab, lnk, tit )

                                Err _ ->
                                    ( "??", "??", "??" )

                        processElts_ : List (List ( String, String, String )) -> List Elt -> Blocks
                        processElts_ acc pass =
                            case pass of
                                (C (Container Reference cs_)) :: rest_ ->
                                    processElts_ (refs cs_ :: acc) rest_

                                _ ->
                                    (List.reverse acc |> List.concat |> ReferencesBlock)
                                        :: processElts remap pass
                    in
                    processElts_ [] (C (Container ct cs) :: rest)


{-| Returns the text of a text line, and `""` for any other element.
-}
extractText : Elt -> String
extractText elt =
    case elt of
        L (TextLine t) ->
            t

        _ ->
            ""



-- ====== FIRST PHASE: LINES TO CONTAINERS ======


{-| Reads `t` into a tree of containers, and returns the document container
together with the map of reference definitions logged while closing them.

The text is split into lines with `String.lines`, and each line has its tabs
expanded with `tabFilter`. The lines are handed to `processLine` through
`RWS.mapM_`, so the last line is processed first and the first line last. Every
container still open above the document is then closed, and the document is
returned.

-}
processLines : String -> ( Container, ReferenceMap )
processLines t =
    let
        lns : List ( LineNumber, String )
        lns =
            List.indexedMap (\i ln -> ( i + 1, ln )) (List.map tabFilter (String.lines t))

        startState : ContainerStack
        startState =
            ContainerStack (Container Document []) []
    in
    RWS.evalRWS (RWS.mapM_ processLine lns |> RWS.andThen (\_ -> closeStack)) () startState


{-| Adds one line to the stack of open containers, closing and opening
containers as the line requires.

The continuations of the open containers are matched first, giving the rest of
the line and how many containers at the top of the stack were left unmatched:
the first whose continuation failed and all those above it. What happens next
depends on the container on top:

  - In an HTML block or an indented code block, when every continuation matched,
    the rest is added as a text line.
  - In a fenced code block, matched or not, a rest that starts with the fence
    closes the block and is not added; any other rest is added as a text line.
  - A reference definition on top is closed whatever matched, and the rest is
    read for the containers it opens and its leaf, which are added. The other
    containers that did not match stay open.
  - Otherwise the rest is read for the containers it opens and its leaf. A text
    line that opens nothing is a lazy continuation, added to the top container
    without closing anything, when some continuation did not match, the top
    container is not indented code, and its oldest child is a text line. A
    setext underline, which is read only when every continuation matched,
    replaces the top container's oldest child, a text line, with a heading of
    that text. In every other case the containers that did not match are closed,
    the new ones are opened, and the leaf is added to the top one.

The rest of the line is read by `tryNewContainers`, whose `lastLineIsText` is
whether every continuation matched and the top container's oldest child is a
text line. The new containers are opened through `RWS.mapM_`, so the last one
found is opened first and ends up outermost. The blank rest of a line that opens
a fenced code block is not added. The `LineNumber` is not used.

-}
processLine : ( LineNumber, String ) -> ContainerM ()
processLine ( _, txt ) =
    RWS.get
        |> RWS.andThen
            (\(ContainerStack ((Container ct cs) as top) rest) ->
                let
                    ( t_, numUnmatched ) =
                        tryOpenContainers (List.reverse (top :: rest)) txt

                    lastLineIsText : Bool
                    lastLineIsText =
                        (numUnmatched == 0)
                            && (case List.reverse cs of
                                    (L (TextLine _)) :: _ ->
                                        True

                                    _ ->
                                        False
                               )

                    addNew : ( List ContainerType, Leaf ) -> () -> ContainerStack -> ( (), ContainerStack, Dict.Dict String ( String, String ) )
                    addNew ( ns, lf ) =
                        RWS.mapM_ addContainer ns
                            |> RWS.andThen
                                (\_ ->
                                    case ( List.reverse ns, lf ) of
                                        -- A fence line leaves nothing to add to the block it opens.
                                        ( (FencedCode _) :: _, BlankLine _ ) ->
                                            RWS.return ()

                                        _ ->
                                            addLeaf lf
                                )
                in
                case ( ct, numUnmatched == 0 ) of
                    ( RawHtmlBlock, True ) ->
                        addLeaf (TextLine t_)

                    ( IndentedCode, True ) ->
                        addLeaf (TextLine t_)

                    ( FencedCode { fence }, _ ) ->
                        if
                            String.startsWith fence t_
                            -- On top of the stack, matched or not, a fenced block stays open until a fence closes it.
                        then
                            closeContainer

                        else
                            addLeaf (TextLine t_)

                    ( Reference, _ ) ->
                        let
                            ( ns, lf ) =
                                tryNewContainers lastLineIsText (String.length txt - String.length t_) t_
                        in
                        closeContainer
                            |> RWS.andThen (\_ -> addNew ( ns, lf ))

                    _ ->
                        case tryNewContainers lastLineIsText (String.length txt - String.length t_) t_ of
                            ( [] as ns, (TextLine t) as lf ) ->
                                if
                                    numUnmatched
                                        > 0
                                        && (case List.reverse cs of
                                                (L (TextLine _)) :: _ ->
                                                    True

                                                _ ->
                                                    False
                                           )
                                        && ct
                                        /= IndentedCode
                                then
                                    addLeaf (TextLine t)

                                else
                                    RWS.replicateM numUnmatched closeContainer
                                        |> RWS.andThen (\_ -> addNew ( ns, lf ))

                            ( [] as ns, (SetextHeader lev _) as lf ) ->
                                if numUnmatched == 0 then
                                    case List.reverse cs of
                                        (L (TextLine t)) :: cs_ ->
                                            RWS.put
                                                (ContainerStack
                                                    (Container ct
                                                        (List.reverse (L (SetextHeader lev t) :: cs_))
                                                    )
                                                    rest
                                                )

                                        -- Unreachable: a setext underline is read only when this child is a text line.
                                        _ ->
                                            RWS.error "setext header line without preceding text line"

                                else
                                    RWS.replicateM numUnmatched closeContainer
                                        |> RWS.andThen (\_ -> addNew ( ns, lf ))

                            ( ns, lf ) ->
                                RWS.replicateM numUnmatched closeContainer
                                    |> RWS.andThen (\_ -> addNew ( ns, lf ))
            )


{-| Returns the rest of `t` after the continuations of the containers `cs`,
matched in order, and the number of containers from the first whose
continuation did not match to the end of `cs`, which is zero when all matched.
Matching stops at the first continuation that does not match. The crash is
unreachable, since the parser falls back to the rest of `t` instead of failing.
-}
tryOpenContainers : List Container -> String -> ( String, Int )
tryOpenContainers cs t =
    let
        scanners : List (Parser a) -> Parser ( String, Int )
        scanners ss =
            case ss of
                [] ->
                    pure Tuple.pair
                        |> apply takeText
                        |> apply (pure 0)

                p :: ps ->
                    oneOf (p |> andThen (\_ -> scanners ps)) (map Tuple.pair takeText |> apply (pure (List.length (p :: ps))))
    in
    case parse (List.map containerContinue cs |> scanners) t of
        Ok ( t_, n ) ->
            ( t_, n )

        Err e ->
            crash <|
                "error parsing scanners: "
                    ++ showParseError e


{-| Reads the rest of a line, `t`, for the containers it opens and the leaf it
adds, and returns both, the containers in the order they were found.

`offset` is the length of the part of the line before `t`, so that columns are
counted from the start of the whole line. Any number of block quote and list
item markers are read first, then at most one start of a verbatim container.
With no verbatim container the leaf is read by `leaf`; after one, the rest of
the line is a text line or a blank line. `lastLineIsText` is passed to the
parsers that depend on it. The crash is unreachable, since none of these
parsers fails.

-}
tryNewContainers : Bool -> Int -> String -> ( List ContainerType, Leaf )
tryNewContainers lastLineIsText offset t =
    let
        newContainers : Parser ( List ContainerType, Leaf )
        newContainers =
            getPosition
                |> andThen
                    (\(Position ln _) ->
                        setPosition (Position ln (offset + 1))
                            |> andThen
                                (\_ ->
                                    many containerStart
                                        |> andThen
                                            (\regContainers ->
                                                option [] (count 1 (verbatimContainerStart lastLineIsText))
                                                    |> andThen
                                                        (\verbatimContainers ->
                                                            if List.isEmpty verbatimContainers then
                                                                map (Tuple.pair regContainers) (leaf lastLineIsText)

                                                            else
                                                                map (Tuple.pair (regContainers ++ verbatimContainers)) textLineOrBlank
                                                        )
                                            )
                                )
                    )
    in
    case parse newContainers t of
        Ok ( cs, t_ ) ->
            ( cs, t_ )

        Err err ->
            crash (showParseError err)


{-| A parser that consumes the rest of the input and returns it as a blank line
when it is empty or all whitespace, as `isWhitespace` defines it, and as a text
line otherwise.
-}
textLineOrBlank : Parser Leaf
textLineOrBlank =
    let
        consolidate : String -> Leaf
        consolidate ts =
            if String.all isWhitespace ts then
                BlankLine ts

            else
                TextLine ts
    in
    map consolidate takeText


{-| Produces a parser for the leaf of a line that opens no verbatim container.

After up to three spaces it tries, in order: an ATX heading, whose text loses
its trailing `#`s and spaces, though when what is left ends in a backslash a
`#` is added after it; a setext underline, only when `lastLineIsText` is
`True`, giving a heading with no text yet; a horizontal rule; and otherwise the
rest of the line, as a text line or a blank line.

-}
leaf : Bool -> Parser Leaf
leaf lastLineIsText =
    scanNonindentSpace
        |> andThen
            (\_ ->
                let
                    removeATXSuffix : String -> String
                    removeATXSuffix t =
                        case String.uncons (String.reverse (stringDropWhileEnd (\c -> String.contains (String.fromChar c) " #") t)) of
                            Nothing ->
                                ""

                            Just ( '\\', t_ ) ->
                                String.reverse t_ ++ "\\#"

                            Just ( c, t_ ) ->
                                String.reverse (String.cons c t_)
                in
                oneOf
                    (pure ATXHeader
                        |> apply parseAtxHeaderStart
                        |> apply (map (String.trim << removeATXSuffix) takeText)
                    )
                    (oneOf
                        (guard lastLineIsText
                            |> andThen
                                (\_ ->
                                    pure SetextHeader
                                        |> apply parseSetextHeaderLine
                                        |> apply (pure "")
                                )
                        )
                        (oneOf (map (\_ -> Rule) scanHRuleLine)
                            textLineOrBlank
                        )
                    )
            )



-- ====== SCANNERS ======


{-| A scanner that matches, without consuming anything, a link label followed by
`:`, which is how a reference definition starts.
-}
scanReference : Scanner
scanReference =
    map (\_ -> ()) (lookAhead (pLinkLabel |> andThen (\_ -> scanChar ':')))


{-| A scanner for the marker of a block quote: `>`, and one space after it if
there is one. Indentation before it is left to the caller.
-}
scanBlockquoteStart : Scanner
scanBlockquoteStart =
    scanChar '>'
        |> andThen (\_ -> option () (scanChar ' '))


{-| A parser for the one to six `#`s that open an ATX heading, returning how many
there are. They must be followed by a space or the end of the line, and the
space is not consumed. Requiring the space keeps a line such as `#8 toggle bolt`
from becoming a heading.
-}
parseAtxHeaderStart : Parser Int
parseAtxHeaderStart =
    char '#'
        |> andThen (\_ -> upToCountChars 5 ((==) '#'))
        |> andThen
            (\hashes ->
                notFollowedBy (skip ((/=) ' '))
                    |> map (\_ -> String.length hashes + 1)
            )


{-| A parser for the underline of a setext heading, a run of `=` or of `-` with
nothing after it but spaces, returning the heading's level: 1 for `=` and 2 for
`-`. One character is enough.
-}
parseSetextHeaderLine : Parser Int
parseSetextHeaderLine =
    satisfy (\c -> c == '-' || c == '=')
        |> andThen
            (\d ->
                let
                    lev : Int
                    lev =
                        if d == '=' then
                            1

                        else
                            2
                in
                skipWhile ((==) d)
                    |> andThen (\_ -> scanBlankline)
                    |> map (\_ -> lev)
            )


{-| A scanner for a horizontal rule: two or more of one character, `*`, `_` or
`-`, with spaces allowed between and after them and nothing else to the end of
the line. Two are enough, so `--` matches.
-}
scanHRuleLine : Scanner
scanHRuleLine =
    satisfy (\c -> c == '*' || c == '_' || c == '-')
        |> andThen
            (\c ->
                count 2 scanSpaces
                    |> andThen (\_ -> skip ((==) c))
                    |> andThen (\_ -> skipWhile (\x -> x == ' ' || x == c))
                    |> andThen (\_ -> endOfInput)
            )


{-| A parser for a line that opens a fenced code block: three or more backticks,
or three or more tildes, then spaces, then an information string that runs to
the end of the line and holds neither a backtick nor a tilde. It returns the
container, with the column at which the fence starts.
-}
parseCodeFence : Parser ContainerType
parseCodeFence =
    getPosition
        |> andThen
            (\(Position _ col) ->
                oneOf (takeWhile1 ((==) '`')) (takeWhile1 ((==) '~'))
                    |> andThen
                        (\cs ->
                            guard (String.length cs >= 3)
                                |> andThen (\_ -> scanSpaces)
                                |> andThen (\_ -> takeWhile (\c -> c /= '`' && c /= '~'))
                                |> andThen
                                    (\rawattr ->
                                        endOfInput
                                            |> map
                                                (\_ ->
                                                    FencedCode
                                                        { startColumn = col
                                                        , fence = cs
                                                        , info = rawattr
                                                        }
                                                )
                                    )
                        )
            )


{-| A parser that matches, without consuming anything, the start of an HTML
block: a tag, as `pHtmlTag` reads tags, whose name is in `blockHtmlTags`, or
the text `<!--` or `-->`. Indentation before it is left to the caller.
-}
parseHtmlBlockStart : Parser ()
parseHtmlBlockStart =
    let
        f : HtmlTagType -> Bool
        f htmlTagType =
            case htmlTagType of
                Opening name ->
                    Set.member name blockHtmlTags

                SelfClosing name ->
                    Set.member name blockHtmlTags

                Closing name ->
                    Set.member name blockHtmlTags
    in
    lookAhead
        (oneOf
            (pHtmlTag
                |> andThen
                    (\t ->
                        guard (f (Tuple.first t))
                            |> map (\_ -> Tuple.second t)
                    )
            )
            (oneOf (string "<!--") (string "-->"))
        )
        |> map (\_ -> ())


{-| The names of the HTML tags whose opening, closing or self-closing tag can
start an HTML block.
-}
blockHtmlTags : Set String
blockHtmlTags =
    Set.fromList
        [ "article"
        , "header"
        , "aside"
        , "hgroup"
        , "blockquote"
        , "hr"
        , "body"
        , "li"
        , "br"
        , "map"
        , "button"
        , "object"
        , "canvas"
        , "ol"
        , "caption"
        , "output"
        , "col"
        , "p"
        , "colgroup"
        , "pre"
        , "dd"
        , "progress"
        , "div"
        , "section"
        , "dl"
        , "table"
        , "dt"
        , "tbody"
        , "embed"
        , "textarea"
        , "fieldset"
        , "tfoot"
        , "figcaption"
        , "th"
        , "figure"
        , "thead"
        , "footer"
        , "tr"
        , "form"
        , "ul"
        , "h1"
        , "h2"
        , "h3"
        , "h4"
        , "h5"
        , "h6"
        , "video"
        ]


{-| A parser for a list marker and the spaces after it, returning a list item
container that records the column at which the marker starts.

The marker is a bullet or a number, and must be followed by a space or by the
end of the line. The item's `padding` is the marker's width plus the spaces
after it, which are consumed, with two exceptions that count one instead of the
spaces: a rest of the line that is blank, which is consumed, and a space
followed by four more, of which only the first is consumed.

-}
parseListMarker : Parser ContainerType
parseListMarker =
    getPosition
        |> andThen
            (\(Position _ col) ->
                oneOf parseBullet parseListNumber
                    |> andThen
                        (\ty ->
                            oneOf (map (\_ -> 1) scanBlankline)
                                (oneOf (map (\_ -> 1) (skip ((==) ' ') |> andThen (\_ -> lookAhead (count 4 (char ' ')))))
                                    (map String.length (takeWhile ((==) ' ')))
                                )
                                |> andThen
                                    (\padding_ ->
                                        guard (padding_ > 0)
                                            |> andThen
                                                (\() ->
                                                    return
                                                        (ListItem
                                                            { listType = ty
                                                            , markerColumn = col
                                                            , padding = padding_ + listMarkerWidth ty
                                                            }
                                                        )
                                                )
                                    )
                        )
            )


{-| Returns the width in characters of a list marker: 1 for a bullet, and for a
number its count of digits plus one for the `.` or `)`. The digits are counted
from the number's value, so leading zeros are not counted and any number from
1000 up counts as four digits.
-}
listMarkerWidth : ListType -> Int
listMarkerWidth listType =
    case listType of
        Bullet _ ->
            1

        Numbered _ n ->
            if n < 10 then
                2

            else if n < 100 then
                3

            else if n < 1000 then
                4

            else
                5


{-| A parser for a bullet, `+`, `*` or `-`, returning its list type.

It succeeds only when nothing but spaces and the bullet character follow to the
end of the line, so a bullet followed by text is never read as one: `- a` is a
paragraph, and a line holding only `-` is an empty list item. For `*` and `-` it
also fails when the same character comes again after any spaces, which lets a
line such as `- -` be read as a horizontal rule instead; `+` has no such check.

-}
parseBullet : Parser ListType
parseBullet =
    satisfy (\c -> c == '+' || c == '*' || c == '-')
        |> andThen
            (\c ->
                unless (c == '+') (nfb (count 2 scanSpaces |> andThen (\_ -> skip ((==) c))))
                    |> andThen
                        (\_ ->
                            skipWhile (\x -> x == ' ' || x == c) |> andThen (\_ -> endOfInput)
                        )
                    |> andThen (\_ -> return (Bullet c))
            )


{-| A parser for the marker of a numbered list item, ASCII digits followed by `.`
or `)`, returning the list type with the number. It crashes if `String.toInt`
rejects the digits.
-}
parseListNumber : Parser ListType
parseListNumber =
    takeWhile1 Char.isDigit
        |> andThen
            (\numStr ->
                case String.toInt numStr of
                    Just num ->
                        oneOf (map (\_ -> PeriodFollowing) (skip ((==) '.'))) (map (\_ -> ParenFollowing) (skip ((==) ')')))
                            |> andThen (\wrap -> return (Numbered wrap num))

                    Nothing ->
                        crash "Exception: Prelude.read: no parse"
            )


{-| Returns the rest of `t` after the prefix `p`, or `Nothing` when `t` does not
start with `p`.
-}
stripPrefix : String -> String -> Maybe String
stripPrefix p t =
    if String.startsWith p t then
        Just (String.dropLeft (String.length p) t)

    else
        Nothing


{-| Splits `t` before its first character that satisfies `p`, returning the part
before it and the part from it on, or `t` and `""` when no character satisfies
`p`.
-}
stringBreak : (Char -> Bool) -> String -> ( String, String )
stringBreak p t =
    List.splitWhen p (String.toList t)
        |> Maybe.map (Tuple.mapBoth String.fromList String.fromList)
        |> Maybe.withDefault ( t, "" )


{-| Returns the string without its trailing characters that satisfy `f`.
-}
stringDropWhileEnd : (Char -> Bool) -> String -> String
stringDropWhileEnd f =
    String.reverse
        >> stringDropWhile f
        >> String.reverse


{-| Returns `str` without its leading characters that satisfy `f`.
-}
stringDropWhile : (Char -> Bool) -> String -> String
stringDropWhile f str =
    case String.uncons str of
        Just ( first, rest ) ->
            if f first then
                stringDropWhile f rest

            else
                str

        Nothing ->
            ""
