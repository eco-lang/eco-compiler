module Common.Format.Render.ElmStructure exposing
    ( Multiline(..), FunctionApplicationMultiline(..)
    , spaceSepOrStack, forceableSpaceSepOrStack, forceableSpaceSepOrStack1, forceableRowOrStack
    , spaceSepOrIndented, forceableSpaceSepOrIndented
    , spaceSepOrPrefix, prefixOrIndented
    , equalsPair, definition
    , application
    , group, group_
    , extensionGroup_
    )

{-| Higher-level formatting primitives for common Elm syntax structures.

This module provides specialized layout functions for recurring patterns in Elm syntax,
such as function applications, definitions with equals signs, grouped elements with
delimiters, and record extensions. Each function intelligently chooses between compact
single-line layout and expanded multi-line layout based on content complexity.

These primitives abstract common formatting decisions and ensure consistent style across
the entire codebase, handling indentation, spacing, and line breaking automatically.


# Multiline Control

@docs Multiline, FunctionApplicationMultiline


# Space-separated or Stacked

@docs spaceSepOrStack, forceableSpaceSepOrStack, forceableSpaceSepOrStack1, forceableRowOrStack


# Space-separated or Indented

@docs spaceSepOrIndented, forceableSpaceSepOrIndented


# Prefix Layouts

@docs spaceSepOrPrefix, prefixOrIndented


# Definitions and Pairs

@docs equalsPair, definition


# Function Application

@docs application


# Grouped Elements

@docs group, group_


# Record Extensions

@docs extensionGroup_

-}

import Common.Format.Box as Box exposing (Box)
import Utils.Crash exposing (crash)


{-| Same as `forceableSpaceSepOrStack False`
-}
spaceSepOrStack : Box -> List Box -> Box
spaceSepOrStack =
    forceableSpaceSepOrStack False


{-| Formats as:

    first rest0 rest1

    first

    rest0

    rest1

-}
forceableSpaceSepOrStack : Bool -> Box -> List Box -> Box
forceableSpaceSepOrStack forceMultiline first rest =
    case
        ( forceMultiline, first, Box.allSingles rest )
    of
        ( False, Box.SingleLine first_, Ok rest_ ) ->
            List.intersperse Box.space (first_ :: rest_) |> Box.row |> Box.line

        _ ->
            Box.stack1 (first :: rest)


{-| Formats as row or stack with forceable multiline layout.
Similar to forceableSpaceSepOrStack but without spaces between elements in single-line mode.

    first rest0 rest1

    first

    rest0

    rest1

-}
forceableRowOrStack : Bool -> Box -> List Box -> Box
forceableRowOrStack forceMultiline first rest =
    case ( forceMultiline, first, Box.allSingles rest ) of
        ( False, Box.SingleLine first_, Ok rest_ ) ->
            Box.row (first_ :: rest_) |> Box.line

        _ ->
            Box.stack1 (first :: rest)


{-| Same as `forceableSpaceSepOrStack`
-}
forceableSpaceSepOrStack1 : Bool -> List Box -> Box
forceableSpaceSepOrStack1 forceMultiline boxes =
    case boxes of
        first :: rest ->
            forceableSpaceSepOrStack forceMultiline first rest

        _ ->
            crash "forceableSpaceSepOrStack1 with empty list"


{-| Formats as:

    first rest0 rest1 rest2

    first
        rest0
        rest1
        rest2

-}
spaceSepOrIndented : Box -> List Box -> Box
spaceSepOrIndented =
    forceableSpaceSepOrIndented False


{-| Formats as space-separated or indented with forceable multiline layout.
When forceMultiline is True or content doesn't fit on one line, the first element stays
on its own line and subsequent elements are indented.

    first rest0 rest1 rest2

    first
        rest0
        rest1
        rest2

-}
forceableSpaceSepOrIndented : Bool -> Box -> List Box -> Box
forceableSpaceSepOrIndented forceMultiline first rest =
    case
        ( forceMultiline, first, Box.allSingles rest )
    of
        ( False, Box.SingleLine first_, Ok rest_ ) ->
            List.intersperse Box.space (first_ :: rest_) |> Box.row |> Box.line

        _ ->
            Box.stack1
                (first :: List.map Box.indent rest)


{-| Formats as:

    op rest

    op rest1
        rest2

    opLong
        rest

-}
spaceSepOrPrefix : Box -> Box -> Box
spaceSepOrPrefix op rest =
    case ( op, rest ) of
        ( Box.SingleLine op_, Box.SingleLine rest_ ) ->
            Box.row [ op_, Box.space, rest_ ] |> Box.line

        ( Box.SingleLine op_, _ ) ->
            if Box.lineLength 0 op_ < 4 then
                Box.prefix (Box.row [ op_, Box.space ]) rest

            else
                Box.stack1 [ op, Box.indent rest ]

        _ ->
            Box.stack1 [ op, Box.indent rest ]


{-| Formats two boxes with space separation on single line, or stacks them with indentation.
Similar to spaceSepOrPrefix but without the special handling for short operators.

    a b

    a
        b

-}
prefixOrIndented : Box -> Box -> Box
prefixOrIndented a b =
    case ( a, b ) of
        ( Box.SingleLine a_, Box.SingleLine b_ ) ->
            Box.row [ a_, Box.space, b_ ] |> Box.line

        ( Box.SingleLine a_, Box.MustBreak b_ ) ->
            Box.row [ a_, Box.space, b_ ] |> Box.mustBreak

        _ ->
            Box.stack1 [ a, Box.indent b ]


{-| Formats as:

    left =
        right
    left =
        right
    left =
        right

-}
equalsPair : String -> Bool -> Box -> Box -> Box
equalsPair symbol forceMultiline left right =
    case ( forceMultiline, left, right ) of
        ( False, Box.SingleLine left_, Box.SingleLine right_ ) ->
            Box.line <|
                Box.row
                    [ left_
                    , Box.space
                    , Box.punc symbol
                    , Box.space
                    , right_
                    ]

        ( _, Box.SingleLine left_, Box.MustBreak right_ ) ->
            Box.mustBreak <|
                Box.row
                    [ left_
                    , Box.space
                    , Box.punc symbol
                    , Box.space
                    , right_
                    ]

        ( _, Box.SingleLine left_, right_ ) ->
            Box.stack1
                [ Box.row [ left_, Box.space, Box.punc symbol ] |> Box.line
                , Box.indent right_
                ]

        ( _, left_, right_ ) ->
            Box.stack1
                [ left_
                , Box.punc symbol |> Box.line |> Box.indent
                , Box.indent right_
                ]


{-| An equalsPair where the left side is an application
-}
definition : String -> Bool -> Box -> List Box -> Box -> Box
definition symbol forceMultiline first rest =
    equalsPair symbol
        forceMultiline
        (application (FAJoinFirst JoinAll) first rest)


{-| Formats as:

    first rest0 rest1 rest2

    first rest0
        rest1
        rest2

    first
        rest0
        rest1
        rest2

-}
application : FunctionApplicationMultiline -> Box -> List Box -> Box
application forceMultiline first args =
    case args of
        [] ->
            first

        arg0 :: rest ->
            case
                ( ( forceMultiline
                  , first
                  )
                , ( arg0
                  , Box.allSingles rest
                  )
                )
            of
                ( ( FAJoinFirst JoinAll, Box.SingleLine first_ ), ( Box.SingleLine arg0_, Ok rest_ ) ) ->
                    (first_ :: arg0_ :: rest_)
                        |> List.intersperse Box.space
                        |> Box.row
                        |> Box.line

                ( ( FAJoinFirst _, Box.SingleLine first_ ), ( Box.SingleLine arg0_, _ ) ) ->
                    Box.stack1 <|
                        Box.line (Box.row [ first_, Box.space, arg0_ ])
                            :: List.map Box.indent rest

                _ ->
                    Box.stack1 <|
                        first
                            :: List.map Box.indent (arg0 :: rest)


{-| `group True '<' ';' '>'` formats as:

    <>

    < child0 >

    < child0; child1; child2 >

    < child0
    ; child1
    ; child2
    >

-}
group : Bool -> String -> String -> String -> Bool -> List Box -> Box
group innerSpaces left sep right forceMultiline children =
    group_ innerSpaces left sep [] right forceMultiline children


{-| Similar to `group` but with additional footer elements to insert before the closing delimiter.
Allows extra boxes (like trailing commas or comments) to be placed after the main children
but before the right delimiter.
-}
group_ : Bool -> String -> String -> List Box -> String -> Bool -> List Box -> Box
group_ innerSpaces left sep extraFooter right forceMultiline children =
    case ( forceMultiline, Box.allSingles children, Box.allSingles extraFooter ) of
        ( _, Ok [], Ok efs ) ->
            List.concat [ [ Box.punc left ], efs, [ Box.punc right ] ] |> Box.row |> Box.line

        ( False, Ok ls, Ok efs ) ->
            List.concat
                [ if innerSpaces then
                    [ Box.punc left, Box.space ]

                  else
                    [ Box.punc left ]
                , List.intersperse (Box.row [ Box.punc sep, Box.space ]) (ls ++ efs)
                , if innerSpaces then
                    [ Box.space, Box.punc right ]

                  else
                    [ Box.punc right ]
                ]
                |> Box.row
                |> Box.line

        _ ->
            case children of
                [] ->
                    -- TODO: might lose extraFooter in this case, but can that ever happen?
                    Box.row [ Box.punc left, Box.punc right ] |> Box.line

                first :: rest ->
                    Box.stack1 <|
                        Box.prefix (Box.row [ Box.punc left, Box.space ]) first
                            :: List.map (Box.prefix <| Box.row [ Box.punc sep, Box.space ]) rest
                            ++ extraFooter
                            ++ [ Box.punc right |> Box.line ]


{-| Alternative version of extensionGroup that takes pre-formatted fields as a single Box.
Formats record extension syntax with base record and fields.

    { base fields }

    { base
        fields
    }

-}
extensionGroup_ : Bool -> Box -> Box -> Box
extensionGroup_ multiline base fields =
    case
        ( multiline
        , base
        , fields
        )
    of
        ( False, Box.SingleLine base_, Box.SingleLine fields_ ) ->
            List.intersperse Box.space
                [ Box.punc "{"
                , base_
                , fields_
                , Box.punc "}"
                ]
                |> Box.row
                |> Box.line

        _ ->
            Box.stack1
                [ Box.prefix (Box.row [ Box.punc "{", Box.space ]) base
                , Box.indent fields
                , Box.punc "}" |> Box.line
                ]



-- FROM `AST.V0_16`


{-| Controls whether multiple elements should be joined on one line or split across lines.

  - JoinAll: Keep all elements on a single line if possible
  - SplitAll: Force each element onto its own line

-}
type Multiline
    = JoinAll
    | SplitAll


{-| Controls multiline behavior for function applications.

  - FASplitFirst: Function name on one line, all arguments indented on subsequent lines
  - FAJoinFirst: Function name and first argument may share a line based on the Multiline setting

-}
type FunctionApplicationMultiline
    = FASplitFirst
    | FAJoinFirst Multiline
