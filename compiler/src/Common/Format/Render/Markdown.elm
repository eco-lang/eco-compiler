module Common.Format.Render.Markdown exposing
    ( Context, LongestSpanResult
    , formatMarkdown
    )

{-| The formatter rewrites a doc comment by parsing its Markdown and printing
it back, and this module is the printer.

`formatMarkdown` turns the blocks of `Common.Format.Cheapskate.Types` into
Markdown text in one fixed layout, whatever the source spelled. Emphasis is
written with `_`, strong emphasis with `**`, a rule as `---`, a bullet item with
a `-` after two spaces, and a numbered item with its number and a period. Text
is escaped by putting a backslash before `\`, `` ` ``, `_` and `*`, and before
no other character.

Code blocks are the one place the output depends on more than the block itself.
A block tagged `elm`, or with no tag, is offered to the code formatter the caller
supplies, and kept as written when that returns `Nothing`. Such a block is
written indented by four spaces, except straight after a list, where an
indented block would read as part of the last item, so it is fenced instead.
Code in any other language is always fenced.

The text is framed for the inside of a doc comment: two newlines go before the
first block unless the comment is empty or starts with a paragraph that does not
begin `@docs`, and one more newline follows the last block when there are two or
more blocks, or one block that got the leading newlines.

@docs Context, LongestSpanResult
@docs formatMarkdown

-}

import Common.Format.Cheapskate.Types exposing (Block(..), Blocks, CodeAttr(..), Inline(..), LinkTarget(..), ListType(..))
import Maybe.Extra as Maybe
import Url
import Utils.Main as Utils


{-| Returns `blocks` as Markdown text, with Elm code blocks reformatted by
`formatCode`.

The text starts with two newlines unless `blocks` is empty or starts with a
paragraph whose first two pieces of text are not `@` and `docs`. It ends with
one extra newline when there are two or more blocks, or one block that also
gets the leading newlines.

-}
formatMarkdown : (String -> Maybe String) -> Blocks -> String
formatMarkdown formatCode blocks =
    let
        needsInitialBlanks : Bool
        needsInitialBlanks =
            case blocks of
                (Para inlines) :: _ ->
                    case inlines of
                        (Str a) :: (Str b) :: _ ->
                            (a == "@") && (b == "docs")

                        _ ->
                            False

                [] ->
                    False

                _ ->
                    True

        needsTrailingBlanks : Bool
        needsTrailingBlanks =
            case blocks of
                [] ->
                    False

                _ :: [] ->
                    needsInitialBlanks

                _ ->
                    True
    in
    formatMarkdown_ formatCode False needsInitialBlanks needsTrailingBlanks blocks


{-| Applies `f` to each element of `list` together with the element before it,
which is `Nothing` for the first.
-}
mapWithPrev : (Maybe a -> a -> b) -> List a -> List b
mapWithPrev f list =
    case list of
        [] ->
            []

        first :: rest ->
            f Nothing first :: List.map2 (\prev next -> f (Just prev) next) (first :: rest) rest


{-| Returns `blocks` as Markdown text, with the leading two newlines and the
trailing newline each switched on or off by its flag.

Blocks are separated by a blank line, except in a list item (`isListItem`) made
of exactly a paragraph followed by a list, which are written with no line
between them. A block after a list is formatted in the `AfterIndentedList`
context.

-}
formatMarkdown_ : (String -> Maybe String) -> Bool -> Bool -> Bool -> List Block -> String
formatMarkdown_ formatCode isListItem needsInitialBlanks needsTrailingBlanks blocks =
    let
        intersperse : List String -> List String
        intersperse =
            case ( isListItem, blocks ) of
                ( True, [ Para _, List _ _ _ ] ) ->
                    identity

                _ ->
                    List.intersperse "\n"

        contextFor : Maybe Block -> Context
        contextFor prev =
            case prev of
                Just (List _ _ _) ->
                    AfterIndentedList

                _ ->
                    Normal
    in
    (if needsInitialBlanks then
        "\n\n"

     else
        ""
    )
        ++ (mapWithPrev (\prev -> formatMardownBlock formatCode (contextFor prev)) blocks |> intersperse |> String.concat)
        ++ (if needsTrailingBlanks then
                "\n"

            else
                ""
           )


{-| What the block before a block was, as far as formatting it is concerned.

`AfterIndentedList` means the previous block was a list, so an Elm code block
here is fenced rather than indented. Every other position is `Normal`.

-}
type Context
    = Normal
    | AfterIndentedList


{-| Returns one block as Markdown text, given what came before it; non-empty
output ends in a newline.

A header is preceded by an extra newline. An `@docs` block writes one `@docs`
line per group of names. A loose list puts a blank line between items; a tight
one does not. A numbered list is renumbered from the item's position in the
list, starting at 0, whatever numbers the source used.

-}
formatMardownBlock : (String -> Maybe String) -> Context -> Block -> String
formatMardownBlock formatCode context block =
    case block of
        ElmDocs terms ->
            (List.map (\term -> "@docs " ++ String.join ", " term) terms |> String.join "\n") ++ "\n"

        Para inlines ->
            (List.map (formatMarkdownInline True) inlines |> String.concat) ++ "\n"

        Header level inlines ->
            "\n" ++ String.repeat level "#" ++ " " ++ (List.map (formatMarkdownInline True) inlines |> String.concat) ++ "\n"

        Blockquote blocks ->
            formatMarkdown_ formatCode False False False blocks
                |> prefix_ "> " "> "

        List tight (Bullet _) items ->
            List.map (prefix_ "  - " "    " << formatMarkdown_ formatCode True False False) items
                |> (if tight then
                        identity

                    else
                        List.intersperse "\n"
                   )
                |> String.concat

        List tight (Numbered _ _) items ->
            List.indexedMap Tuple.pair items
                |> List.map (formatListItem formatCode)
                |> (if tight then
                        identity

                    else
                        List.intersperse "\n"
                   )
                |> String.concat

        CodeBlock (CodeAttr { codeLang }) code ->
            let
                isElm : Bool
                isElm =
                    codeLang == "elm" || codeLang == ""

                formatted : String
                formatted =
                    Maybe.withDefault (ensureNewline code) <|
                        if isElm then
                            formatCode code

                        else
                            Nothing

                ensureNewline : String -> String
                ensureNewline text =
                    if String.endsWith "\n" text then
                        text

                    else
                        text ++ "\n"

                canIndent : Bool
                canIndent =
                    case context of
                        Normal ->
                            True

                        AfterIndentedList ->
                            False
            in
            if isElm && canIndent then
                lines formatted |> List.map (\line -> "    " ++ line) |> Utils.unlines

            else
                "```" ++ codeLang ++ "\n" ++ formatted ++ "```\n"

        HtmlBlock text ->
            text ++ "\n"

        HRule ->
            "---\n"

        ReferencesBlock refs ->
            List.map formatRef refs |> String.concat


{-| Splits a string into lines, dropping the one empty line that a final
newline leaves at the end.
-}
lines : String -> List String
lines str =
    case List.reverse (String.lines str) of
        "" :: rest ->
            List.reverse rest

        result ->
            List.reverse result


{-| Returns a numbered list item, numbered `i`, with its continuation lines
indented by four spaces.
-}
formatListItem : (String -> Maybe String) -> ( Int, Blocks ) -> String
formatListItem formatCode ( i, item ) =
    let
        pref : String
        pref =
            if i < 10 then
                String.fromInt i ++ ".  "

            else
                String.fromInt i ++ ". "
    in
    formatMarkdown_ formatCode True False False item |> prefix_ pref "    "


{-| Returns a link reference definition line, `[label]: url "title"`, leaving
out the title when it is empty.
-}
formatRef : ( String, String, String ) -> String
formatRef ( label, url, title ) =
    "["
        ++ label
        ++ "]: "
        ++ url
        ++ (if title == "" then
                ""

            else
                " \"" ++ title ++ "\""
           )
        ++ "\n"


{-| Prefixes the first line of a text with `preFirst` and every later line with
`preRest`, and ends the result with a newline.
-}
prefix_ : String -> String -> String -> String
prefix_ preFirst preRest =
    lines >> prefix preFirst preRest >> Utils.unlines


{-| Prefixes the first of `list` with `preFirst` and the rest with `preRest`.
-}
prefix : String -> String -> List String -> List String
prefix preFirst preRest list =
    case list of
        [] ->
            []

        first :: rest ->
            (preFirst ++ first) :: List.map (\next -> preRest ++ next) rest


{-| Returns one inline element as Markdown text.

When `fixSpecialChars` is set, text is escaped with a backslash before `\`,
`` ` ``, `_` and `*`. Text inside emphasis and strong emphasis is always escaped.
A link whose text is its URL, with no title, and whose URL `Url.fromString`
accepts is written as an autolink, `<url>`, or as the bare URL when escaping is
off. Inline code is fenced with one backtick more than the longest run of
backticks it contains, padded with a space on each side when it contains any.

-}
formatMarkdownInline : Bool -> Inline -> String
formatMarkdownInline fixSpecialChars inline =
    let
        fix : Char -> String
        fix c =
            case c of
                '\\' ->
                    "\\\\"

                '`' ->
                    "\\`"

                '_' ->
                    "\\_"

                '*' ->
                    "\\*"

                _ ->
                    String.fromChar c
    in
    case inline of
        Str text ->
            (if fixSpecialChars then
                String.toList >> List.map fix >> String.concat

             else
                identity
            )
                text

        Space ->
            " "

        SoftBreak ->
            "\n"

        LineBreak ->
            "\n"

        Emph inlines ->
            "_" ++ (inlines |> List.map (formatMarkdownInline True) |> String.concat) ++ "_"

        Strong inlines ->
            "**" ++ (inlines |> List.map (formatMarkdownInline True) |> String.concat) ++ "**"

        Code text ->
            case longestSpanOf '`' text of
                NoSpan ->
                    "`" ++ text ++ "`"

                Span n ->
                    let
                        delimiter : String
                        delimiter =
                            String.repeat (n + 1) "`"
                    in
                    delimiter ++ " " ++ text ++ " " ++ delimiter

        Link inlines (Url url) title ->
            let
                textRaw : String
                textRaw =
                    List.map (formatMarkdownInline False) inlines |> String.concat

                isValidAutolink : String -> Bool
                isValidAutolink =
                    Url.fromString >> Maybe.isJust
            in
            if textRaw == url && title == "" && isValidAutolink url then
                if fixSpecialChars then
                    "<" ++ url ++ ">"

                else
                    url

            else
                let
                    text : String
                    text =
                        List.map (formatMarkdownInline fixSpecialChars) inlines |> String.concat
                in
                "["
                    ++ text
                    ++ "]("
                    ++ url
                    ++ (if title == "" then
                            ""

                        else
                            " \"" ++ title ++ "\""
                       )
                    ++ ")"

        Link inlines (Ref ref) _ ->
            let
                text : String
                text =
                    List.map (formatMarkdownInline fixSpecialChars) inlines |> String.concat
            in
            if text == ref || ref == "" then
                "[" ++ text ++ "]"

            else
                "[" ++ text ++ "][" ++ ref ++ "]"

        Image inlines url title ->
            "!["
                ++ (List.map (formatMarkdownInline fixSpecialChars) inlines |> String.concat)
                ++ "]("
                ++ url
                ++ (if title == "" then
                        ""

                    else
                        " \"" ++ title ++ "\""
                   )
                ++ ")"

        Entity text ->
            text

        RawHtml text ->
            text



-- ====== TEXT EXTRA ======


{-| The length of the longest run of one character in a string: `NoSpan` when
the character does not occur, otherwise `Span` with a length of at least 1.
-}
type LongestSpanResult
    = NoSpan
    | Span Int


{-| Returns the length of the longest run of `char` in `input`.
-}
longestSpanOf : Char -> String -> LongestSpanResult
longestSpanOf char input =
    let
        step : Char -> ( Maybe Int, Int ) -> ( Maybe Int, Int )
        step c ( currentSpan, longest ) =
            if c == char then
                ( Just (1 + Maybe.withDefault 0 currentSpan)
                , longest
                )

            else
                ( Nothing
                , endCurrentSpan ( currentSpan, longest )
                )

        endCurrentSpan : ( Maybe Int, Int ) -> Int
        endCurrentSpan acc =
            case acc of
                ( Nothing, longest ) ->
                    longest

                ( Just current, longest ) ->
                    max current longest
    in
    case String.foldl step ( Nothing, 0 ) input |> endCurrentSpan of
        0 ->
            NoSpan

        positive ->
            Span positive
