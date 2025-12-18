module Common.Format.Cheapskate.Types exposing
    ( Doc(..), Options(..)
    , Block(..), Blocks
    , CodeAttr(..), ListType(..), NumWrapper(..), HtmlTagType(..)
    , Inline(..), Inlines, LinkTarget(..)
    , ReferenceMap
    )

{-| Core types for representing Markdown documents.

This module defines the abstract syntax tree (AST) for Markdown documents,
including block-level elements (paragraphs, headers, lists, code blocks) and
inline elements (text, emphasis, links, images). The types support a rich
Markdown feature set including fenced code blocks, HTML blocks, and link
references.


# Document

@docs Doc, Options


# Block Elements

@docs Block, Blocks
@docs CodeAttr, ListType, NumWrapper, HtmlTagType


# Inline Elements

@docs Inline, Inlines, LinkTarget


# References

@docs ReferenceMap

-}

import Data.Map exposing (Dict)



-- TYPES


{-| A complete Markdown document with block content.
-}
type Doc
    = Doc Blocks


{-| Block-level elements that make up a Markdown document.
Includes paragraphs, headers, lists, code blocks, HTML blocks, and more.
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


{-| Attributes for fenced code blocks.
The language identifier and additional information from the fence line.
-}
type CodeAttr
    = CodeAttr
        { codeLang : String
        , codeInfo : String
        }


{-| The type of list marker used.
-}
type ListType
    = Bullet Char
    | Numbered NumWrapper Int


{-| The style of number wrapper for ordered lists.
-}
type NumWrapper
    = PeriodFollowing
    | ParenFollowing


{-| The type of an HTML tag: opening, closing, or self-closing.
-}
type HtmlTagType
    = Opening String
    | Closing String
    | SelfClosing String


{-| A sequence of block-level elements.
Represented as a list for efficient operations.
-}
type alias Blocks =
    List Block


{-| Inline elements within a block such as text, emphasis, links, and code spans.
-}
type Inline
    = Str String
    | Space
    | SoftBreak
    | LineBreak
    | Emph Inlines
    | Strong Inlines
    | Code String
    | Link Inlines LinkTarget {- URL -} String {- title -}
    | Image Inlines String {- URL -} String {- title -}
    | Entity String
    | RawHtml String


{-| The target of a link: either a direct URL or a reference to be resolved.
-}
type LinkTarget
    = Url String
    | Ref String


{-| A sequence of inline elements.
-}
type alias Inlines =
    List Inline


{-| A mapping from link reference labels to their URLs and titles.
-}
type alias ReferenceMap =
    Dict String String ( String, String )


{-| Options controlling document rendering and parsing behavior.
-}
type Options
    = Options
