module Common.Format.Cheapskate.Types exposing
    ( Doc(..)
    , Block(..), Blocks
    , CodeAttr(..), ListType(..), NumWrapper(..), HtmlTagType(..)
    , Inline(..), Inlines, LinkTarget(..)
    , ReferenceMap
    )

{-| The formatter rewrites the Markdown inside doc comments, and this module is
the tree a doc comment is parsed into and printed back out from.

A document is a list of blocks. A block is a unit that occupies lines of its
own: a paragraph, a heading, a list, a code block. The text inside a paragraph
or a heading is a list of inlines, the pieces that sit within a line: plain
text, the spaces between words, emphasis, code spans and links.

The tree is printed back as Markdown rather than turned into HTML, so it keeps
several things in the form in which they were written. A reference link, one
written `[text][label]` or `[text]`, keeps its label rather than the URL the
label stands for. The reference definitions that give labels their URLs stay
in the document as a block of their own. An HTML entity such as `&amp;` stays an
entity rather than becoming the character it names, and raw HTML is kept as
text.

One block is particular to Elm. `ElmDocs` holds the docs lines of a doc
comment, which name the values a module documents.


# Document

@docs Doc


# Block Elements

@docs Block, Blocks
@docs CodeAttr, ListType, NumWrapper, HtmlTagType


# Inline Elements

@docs Inline, Inlines, LinkTarget


# References

@docs ReferenceMap

-}

import Dict exposing (Dict)



-- ====== TYPES ======


{-| A parsed Markdown document, which is its list of blocks.
-}
type Doc
    = Doc Blocks


{-| One block of a Markdown document.

`Para` is a paragraph, holding its text as inlines.

`Header` carries the heading's level, where 1 is the most prominent, and it is
printed as that many `#` signs.

`Blockquote` holds the blocks inside a block quote.

`List` is a whole list. Its `Bool` says whether the list is tight, meaning that
no blank line separates its items or stands directly inside one of them; blank
lines within a block nested in an item are not counted. Each item is a list of
blocks of its own.

`CodeBlock` holds the text of a fenced or indented code block, with the
information string of a fence line, as `CodeAttr` describes.

`HtmlBlock` is a block of raw HTML, kept as text.

`HRule` is a horizontal rule.

`ReferencesBlock` holds link reference definitions, `[label]: url "title"`, as
label, URL and title, with an empty title where there is none. A definition
the parser cannot read is dropped from the document.

`ElmDocs` holds the names from a `@docs` line and from the text lines the parser
groups with it. There is one inner list for each line that names anything,
holding the names on that line without their commas or surrounding spaces.

-}
type Block
    = Para Inlines
    | Header Int Inlines
    | Blockquote Blocks
    | List Bool ListType (List Blocks)
    | CodeBlock CodeAttr String
    | HtmlBlock String
    | HRule
    | ReferencesBlock (List ( String, String, String ))
    | ElmDocs (List (List String))


{-| The information string of a fenced code block, split in two.

`codeLang` is the first word of the information string, such as `elm`, and
`codeInfo` is the rest of it, trimmed. The parser reads a document's lines last
first, so the string is taken from the block's closing fence, when it has one,
not its opening fence. Both are empty for an indented code block, which has no
fence.

-}
type CodeAttr
    = CodeAttr
        { codeLang : String
        , codeInfo : String
        }


{-| The kind of marker a list uses.

`Bullet` carries the bullet character. `Numbered` carries the punctuation that
follows the number, and the number on the marker of the list's last item in the
source, which is the item the parser reads first.

-}
type ListType
    = Bullet Char
    | Numbered NumWrapper Int


{-| The punctuation after the number of a numbered list item: `PeriodFollowing`
for `1.` and `ParenFollowing` for `1)`.
-}
type NumWrapper
    = PeriodFollowing
    | ParenFollowing


{-| The kind of an HTML tag the parser has read, with the tag's name in lower
case.

`Closing` is a tag written `</name>`. `SelfClosing` is one whose `>` is preceded
by `/`, and `Opening` is any other.

This is not part of the document tree. The parser uses it to decide whether a
line begins an HTML block.

-}
type HtmlTagType
    = Opening String
    | Closing String
    | SelfClosing String


{-| A sequence of blocks, such as the contents of a document or of one list item.
This is a name for `List Block`.
-}
type alias Blocks =
    List Block


{-| One piece of the text inside a paragraph, a heading, or the text of a link.

`Str` is literal text. A backslash escape has already been removed from it,
leaving the character the backslash protected.

`Space` is a run of whitespace within one line, of any length.

`SoftBreak` is a line ending inside a paragraph. `LineBreak` is a hard line
break: a line ending preceded by two or more spaces, or a backslash at the end
of a line.

`Emph` and `Strong` hold the inlines of emphasised and strongly emphasised
text.

`Code` is the text of a code span, without its backticks and with surrounding
spaces trimmed.

`Link` carries the link's text, its target, and its title, which is empty when
the link has none.

`Image` carries the image's alternative text, its URL and its title. The URL is
a plain string, not a `LinkTarget`, because only an image written with its URL
in place, `![text](url)`, becomes an `Image`.

`Entity` is an HTML entity as written, including its `&` and `;`.

`RawHtml` is an HTML tag or comment, kept as text.

-}
type Inline
    = Str String
    | Space
    | SoftBreak
    | LineBreak
    | Emph Inlines
    | Strong Inlines
    | Code String
    | Link Inlines LinkTarget String
    | Image Inlines String String
    | Entity String
    | RawHtml String


{-| Where a link points.

`Url` is a URL given in the link itself, as in `[text](url)` or `<url>`. An
e-mail address written `<name@example.com>` gets `mailto:` in front of it.

`Ref` is the label of a reference link, as in `[text][label]`; for a link
written `[text]` the label is that text. The label is not looked up.

-}
type LinkTarget
    = Url String
    | Ref String


{-| A sequence of inlines, such as the contents of a paragraph.
This is a name for `List Inline`.
-}
type alias Inlines =
    List Inline


{-| The link reference definitions of a document, from label to URL and title.

The parser builds it keyed by each label in lower case with its whitespace
removed. No link is resolved through it: a `Ref` keeps its label.

-}
type alias ReferenceMap =
    Dict String ( String, String )
