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

{-| The handful of layouts elm-format uses again and again, so that the
formatter that walks the syntax tree (`Common.Format.Render.Box`) states each
layout decision once.

Each function takes the parts of one piece of syntax, already laid out as boxes,
and returns one box. A box is either a single line that can be joined into a
surrounding line, or something that must stand on its own lines (see
`Common.Format.Box`). Most functions here make the same basic choice: they join
the parts into one line when every part is a single-line box and the caller has
not forced the multi-line layout, and otherwise they stack them. Several
(`spaceSepOrPrefix`, `prefixOrIndented`, `equalsPair`, `application`, `group_`)
add an intermediate layout or exception, described in their own docstrings. Nothing here measures
a line against a width limit. The one length test is in `spaceSepOrPrefix`, which
looks at how wide an operator is.

A _forceable_ function takes a `Bool` that, when `True`, chooses the multi-line
layout even though every part would fit on one line. The caller decides when to
force it. `Multiline` and `FunctionApplicationMultiline` play the same part for
function application, where there are more than two layouts to choose from.

The examples in the docstrings show each layout's shapes, one-line form first.


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


{-| Returns `first` and `rest` on one line separated by spaces when all are
single lines, and otherwise stacked one under another without indentation. It is
`forceableSpaceSepOrStack` never forced.
-}
spaceSepOrStack : Box -> List Box -> Box
spaceSepOrStack =
    forceableSpaceSepOrStack False


{-| Returns `first` and `rest` on one line separated by spaces, or stacked one
under another without indentation.

The one-line form is used only when `forceMultiline` is `False` and every part
is a single line.

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


{-| Returns `first` and `rest` joined on one line with nothing between them,
or stacked one under another without indentation.

The one-line form is used only when `forceMultiline` is `False` and every part
is a single line.

-}
forceableRowOrStack : Bool -> Box -> List Box -> Box
forceableRowOrStack forceMultiline first rest =
    case ( forceMultiline, first, Box.allSingles rest ) of
        ( False, Box.SingleLine first_, Ok rest_ ) ->
            Box.row (first_ :: rest_) |> Box.line

        _ ->
            Box.stack1 (first :: rest)


{-| Returns the same layout as `forceableSpaceSepOrStack`, taking the first
part as the head of `boxes`. It crashes when `boxes` is empty.
-}
forceableSpaceSepOrStack1 : Bool -> List Box -> Box
forceableSpaceSepOrStack1 forceMultiline boxes =
    case boxes of
        first :: rest ->
            forceableSpaceSepOrStack forceMultiline first rest

        _ ->
            crash "forceableSpaceSepOrStack1 with empty list"


{-| Returns `first` and `rest` on one line separated by spaces when all are
single lines, and otherwise `first` with each of `rest` indented under it. It is
`forceableSpaceSepOrIndented` never forced.
-}
spaceSepOrIndented : Box -> List Box -> Box
spaceSepOrIndented =
    forceableSpaceSepOrIndented False


{-| Returns `first` and `rest` on one line separated by spaces, or `first`
with each of `rest` indented under it:

    first rest0 rest1 rest2

    first
        rest0
        rest1
        rest2

The one-line form is used only when `forceMultiline` is `False` and every part
is a single line.

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


{-| Returns `op` followed by `rest`:

    op rest

    op rest1
        rest2

    opLong
        rest

Both on one line when both are single lines. When only `op` is a single line and
it is narrower than 4 columns, `op` and a space are put before the first line of
`rest`, and the other lines of `rest` are padded with spaces to stay aligned
with it, so `rest2` above starts under `rest1`.
Otherwise `rest` is indented under `op`.

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


{-| Returns `a` followed by `b`:

    a b

    a
        b

`a` and `b` share a line when `a` is a single line and `b` is a single line or a
line that must end there (a `--` comment); in the second case the result must
end the line too. Otherwise `b` is indented under `a`.

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


{-| Returns `left` and `right` joined by `symbol`, such as `=` or `:`.

All on one line when `forceMultiline` is `False` and both sides are single
lines. When `left` is a single line and `right` is a line that must end there (a
`--` comment), the result is one line whatever `forceMultiline` says. Otherwise
`symbol` ends the line of a single-line `left` and `right` is indented below; a
multi-line `left` puts `symbol` on its own indented line.

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


{-| Returns `equalsPair` whose left side is `first` applied to `rest`, laid
out as `application` with `FAJoinFirst JoinAll`. The final argument is the right
side.
-}
definition : String -> Bool -> Box -> List Box -> Box -> Box
definition symbol forceMultiline first rest =
    equalsPair symbol
        forceMultiline
        (application (FAJoinFirst JoinAll) first rest)


{-| Returns the function `first` applied to `args`:

    first rest0 rest1 rest2

    first rest0
        rest1
        rest2

    first
        rest0
        rest1
        rest2

With no arguments the result is `first` unchanged. The one-line form needs
`FAJoinFirst JoinAll` and every part a single line. Under any `FAJoinFirst`,
when `first` and the first argument are single lines they share a line and the
other arguments are indented below. Otherwise, and always under `FASplitFirst`,
every argument is indented under `first`.

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


{-| Returns `children` between the delimiters `left` and `right`, separated by
`sep`. `group True "<" ";" ">"` gives:

    <>

    < child0 >

    < child0; child1; child2 >

    < child0
    ; child1
    ; child2
    >

The one-line form is used when `forceMultiline` is `False` and every child is a
single line; `innerSpaces` puts a space inside each delimiter there. No children
gives the two delimiters alone, even when forced. In the multi-line form the
first child follows `left` and a space, and each other child follows `sep` and a
space.

-}
group : Bool -> String -> String -> String -> Bool -> List Box -> Box
group innerSpaces left sep right forceMultiline children =
    group_ innerSpaces left sep [] right forceMultiline children


{-| Returns the layout of `group`, with `extraFooter` placed after the children
and before `right`.

On one line the footer boxes are separated like children. In the multi-line form
each footer box is its own line, with no separator before it. With no children,
the result is one line of `left`, the footer and `right` with no separators or
inner spaces when every footer box is a single line, and `left` and `right`
alone, without the footer, when one is not.

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
                    -- Reached only when a footer box is not a single line; the footer is dropped.
                    Box.row [ Box.punc left, Box.punc right ] |> Box.line

                first :: rest ->
                    Box.stack1 <|
                        Box.prefix (Box.row [ Box.punc left, Box.space ]) first
                            :: List.map (Box.prefix <| Box.row [ Box.punc sep, Box.space ]) rest
                            ++ extraFooter
                            ++ [ Box.punc right |> Box.line ]


{-| Returns a record extension: `base` and the already laid out `fields`
between braces.

    { base fields }

    { base
        fields
    }

The one-line form is used only when `multiline` is `False` and both are single
lines.

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


{-| A choice between joining the parts of a layout on one line and splitting
them, used by `application` through `FAJoinFirst`.

`JoinAll` allows the one-line form when every part is a single line. `SplitAll`
rules it out; `application` still keeps the function and its first argument on
one line.

-}
type Multiline
    = JoinAll
    | SplitAll


{-| How `application` may lay out a function and its arguments.

`FASplitFirst` puts every argument on its own line indented under the function,
even when all would fit on one line.

`FAJoinFirst` lets the function and its first argument share a line when both
are single lines; its `Multiline` says whether the remaining arguments may join
them.

-}
type FunctionApplicationMultiline
    = FASplitFirst
    | FAJoinFirst Multiline
