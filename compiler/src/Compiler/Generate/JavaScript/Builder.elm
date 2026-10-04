module Compiler.Generate.JavaScript.Builder exposing
    ( Builder(..), BuilderData, emptyBuilder, stmtToBuilder, exprToBuilder
    , Expr(..), LValue(..)
    , Stmt(..), Case(..)
    , InfixOp(..), PrefixOp(..)
    , Mapping(..), MappingData
    , addKernel
    )

{-| The JavaScript back end has to print the program it generates and, for a
source map, know where in the printed text each piece of Elm source ended up.
This module does both: it is a syntax tree for the JavaScript the back end
writes, and the printer that turns a tree into indented text while recording
those positions.

The tree has expressions (`Expr`), assignment targets (`LValue`), statements
(`Stmt`) and switch clauses (`Case`), with the operators in `InfixOp` and
`PrefixOp`. It has only the forms the back end writes, not the whole of
JavaScript. Names and string contents are printed exactly as given: nothing is
mangled or escaped here, so the caller supplies valid identifiers and string
text that is already escaped.

Some forms are _tracked_. A tracked form carries the Elm module it was generated
from and positions or regions in that module's source, and printing it can
record _mappings_: a mapping is a position in the printed text paired with the
Elm position it came from, and sometimes a name to report for it. An untracked
form records nothing.

A `Builder` holds the text printed so far, the line and column the next
character will go at, and the mappings recorded so far. `stmtToBuilder` and
`exprToBuilder` print onto the end of one. Printed columns count from 1 on each
line, and printed lines count from the number given to `emptyBuilder`.

Printing makes two layout decisions. No operator precedence is computed:
instead an operator expression, conditional or assignment is put in
parentheses wherever it is an operand of an operator, a part of a conditional,
the callee of a call (for a call through an application helper, the helper),
or the object of a property access or index. And an array, an object or a
call's arguments go one element to a line when any element may span lines (an
array, object, call, function or conditional, or an expression containing one),
and on one line otherwise; a call through an application helper decides this
from the arguments after the function only. Indentation is one tab per level
of nesting.


# Builder

@docs Builder, BuilderData, emptyBuilder, stmtToBuilder, exprToBuilder


# Expressions

@docs Expr, LValue


# Statements

@docs Stmt, Case


# Operators

@docs InfixOp, PrefixOp


# Source Maps

@docs Mapping, MappingData


# Kernel Code

@docs addKernel

-}

-- Based on the language-ecmascript package.
-- https://hackage.haskell.org/package/language-ecmascript
-- They did the hard work of reading the spec to figure out
-- how all the types should fit together.

import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.JavaScript.Name as Name
import Compiler.Json.Encode as Json
import Compiler.Reporting.Annotation as A
import Maybe.Extra as Maybe



-- ====== EXPRESSIONS ======


{-| A JavaScript expression. The `ExprTracked...` forms also carry an Elm
module and positions or regions in its source, from which printing can record
mappings, as described below.

`ExprString` prints its text between single quotes without escaping it, so the
text must already be escaped for a single-quoted literal. `ExprTrackedString`
does the same. `ExprTrackedFloat` carries its number already written as text.
`ExprInt` and `ExprBool` print a number and `true` or `false`. Each tracked
literal maps its first printed character to the position it carries.

`ExprJson` prints a JSON value compactly, with `Compiler.Json.Encode.encodeUgly`,
as a JavaScript literal.

`ExprArray` and `ExprObject` print an array and an object literal.
`ExprTrackedArray` and `ExprTrackedObject` carry the region of the Elm literal:
the opening bracket is mapped to the region's start, and the closing bracket to
the column before the region's end, which is the region's last character. The
fields of `ExprTrackedObject` carry the region of their names: each name is
mapped to the start of its region, reporting itself as its name, and the `:`
after it to the end of that region.

`ExprRef` prints a name. `ExprTrackedRef` carries two names: the first is the
name its mapping reports and the second is the one printed.

`ExprAccess` is a property access, `object.name`, and `ExprIndex` is
`object[index]`. `ExprTrackedAccess` maps the property name to the position it
carries, reporting the name, and the dot to the column before it.

`ExprPrefix` and `ExprInfix` apply a `PrefixOp` or an `InfixOp` to their
operands.

`ExprIf` is the conditional operator, `condition ? then : else`. `ExprAssign`
is an assignment used as an expression.

`ExprCall` is a call. `ExprTrackedNormalCall` is a call through an application
helper such as `A2`: given a helper, a function and arguments, it prints
`helper(function, arguments...)`. When the function is an `ExprTrackedRef` and
the helper an `ExprRef`, the helper's name is mapped to the call's position and
reports the function's name; otherwise the helper is printed as it is.

`ExprFunction` is a function expression, with an optional name, its parameters
and its body. `ExprTrackedFunction` has no name; each parameter is mapped to the
start of its region and reports the name it is printed as.

-}
type Expr
    = ExprString String
    | ExprTrackedString ModuleName.Canonical A.Position String
    | ExprTrackedFloat ModuleName.Canonical A.Position String
    | ExprInt Int
    | ExprTrackedInt ModuleName.Canonical A.Position Int
    | ExprBool Bool
    | ExprTrackedBool ModuleName.Canonical A.Position Bool
    | ExprJson Json.Value
    | ExprArray (List Expr)
    | ExprTrackedArray ModuleName.Canonical A.Region (List Expr)
    | ExprObject (List ( Name.Name, Expr ))
    | ExprTrackedObject ModuleName.Canonical A.Region (List ( A.Located Name.Name, Expr ))
    | ExprRef Name.Name
    | ExprTrackedRef ModuleName.Canonical A.Position Name.Name Name.Name
    | ExprAccess Expr Name.Name
    | ExprTrackedAccess Expr ModuleName.Canonical A.Position Name.Name
    | ExprIndex Expr Expr
    | ExprPrefix PrefixOp Expr
    | ExprInfix InfixOp Expr Expr
    | ExprIf Expr Expr Expr
    | ExprAssign LValue Expr
    | ExprCall Expr (List Expr)
    | ExprTrackedNormalCall ModuleName.Canonical A.Position Expr Expr (List Expr)
    | ExprFunction (Maybe Name.Name) (List Name.Name) (List Stmt)
    | ExprTrackedFunction ModuleName.Canonical (List (A.Located Name.Name)) (List Stmt)


{-| The target of an `ExprAssign`: a name, or `LBracket object index`, printed
as `object[index]`.
-}
type LValue
    = LRef Name.Name
    | LBracket Expr Expr



-- ====== STATEMENTS ======


{-| A JavaScript statement. Each is printed on its own lines at the current
indentation, with anything inside it indented further, and ends its last line,
except where this says otherwise.

`Block` is a sequence of statements, printed one after another with no braces
and no extra indentation; it is not a JavaScript block. `EmptyStmt` prints
nothing.

`IfStmt` always prints an `else` branch, which is empty when its statement is
`EmptyStmt`.

`Break` and `Continue` take an optional label. Without one they are printed
with no indentation.

`Labelled` prints the label on a line of its own, followed by the statement at
the same indentation.

`Try` is `try { ... } catch (name) { ... }`, with the name of the caught value
between its two statements.

`Throw` does not end its line, so whatever is printed next continues on the
same line.

`Var` declares one name. `TrackedVar` carries two names, the first reported by
its mapping and the second printed, and maps the printed name to its position.
`Vars` declares several names in one `var`, one to a line, and prints nothing
for an empty list.

`FunctionStmt` is a function declaration: name, parameters and body.

-}
type Stmt
    = Block (List Stmt)
    | EmptyStmt
    | ExprStmt Expr
    | IfStmt Expr Stmt Stmt
    | Switch Expr (List Case)
    | While Expr Stmt
    | Break (Maybe Name.Name)
    | Continue (Maybe Name.Name)
    | Labelled Name.Name Stmt
    | Try Stmt Name.Name Stmt
    | Throw Expr
    | Return Expr
    | Var Name.Name Expr
    | TrackedVar ModuleName.Canonical A.Position Name.Name Name.Name Expr
    | Vars (List ( Name.Name, Expr ))
    | FunctionStmt Name.Name (List Name.Name) (List Stmt)


{-| One clause of a `Switch`: `case value:` or `default:`, followed by its
statements.

Nothing is added after the statements, not even a `break`, so control falls
through into the next clause unless the statements leave the switch.

-}
type Case
    = Case Expr (List Stmt)
    | Default (List Stmt)



-- ====== OPERATORS ======


{-| A JavaScript binary operator, printed with a space on each side.

`OpEq` and `OpNe` are the strict `===` and `!==`. `OpLShift` is `<<`,
`OpSpRShift` the sign-propagating `>>` and `OpZfRShift` the zero-filling `>>>`.

-}
type InfixOp
    = OpAdd
    | OpSub
    | OpMul
    | OpDiv
    | OpMod
    | OpEq
    | OpNe
    | OpLt
    | OpLe
    | OpGt
    | OpGe
    | OpAnd
    | OpOr
    | OpBitwiseAnd
    | OpBitwiseXor
    | OpBitwiseOr
    | OpLShift
    | OpSpRShift
    | OpZfRShift


{-| A JavaScript prefix operator: `!`, `-` or `~`, in the order of the
constructors.
-}
type PrefixOp
    = PrefixNot
    | PrefixNegate
    | PrefixComplement



-- ====== BUILDER CONVERSION ======


{-| Prints a statement onto the end of `builder`, starting at the outermost
level of indentation, and records the mappings of the tracked forms in it.
-}
stmtToBuilder : Stmt -> Builder -> Builder
stmtToBuilder stmts builder =
    fromStmt levelZero stmts builder


{-| Prints an expression onto the end of `builder`, at the outermost level of
indentation and with no enclosing parentheses, and records the mappings of the
tracked forms in it. The current line is not ended.
-}
exprToBuilder : Expr -> Builder -> Builder
exprToBuilder expr builder =
    fromExpr levelZero Whatever expr builder



-- ====== INDENT LEVEL ======


{-| One depth of indentation: the tabs that start a line at that depth, and
a way to get the next depth in. The next depth is a function so that it is made
only when it is needed.
-}
type Level
    = Level String (() -> Level)


{-| The outermost level of indentation, which has no tabs.
-}
levelZero : Level
levelZero =
    Level "" (\_ -> makeLevel 1 (String.repeat 16 "\t"))


{-| Makes the level `level` tabs deep, taking its tabs from `oldTabs`, which
is first doubled if it is shorter than `level`. The levels after it are made
from the same tab string.
-}
makeLevel : Int -> String -> Level
makeLevel level oldTabs =
    let
        tabs : String
        tabs =
            if level <= String.length oldTabs then
                oldTabs

            else
                oldTabs ++ oldTabs
    in
    Level (String.left level tabs) (\_ -> makeLevel (level + 1) tabs)



-- ====== HELPERS ======


{-| Prints each element of the list with `fn`, separated by a comma and a
space. It adds no line break between elements.
-}
commaSep : (a -> Builder -> Builder) -> List a -> Builder -> Builder
commaSep fn exprs builder =
    case exprs of
        [] ->
            builder

        [ first ] ->
            fn first builder

        first :: rest ->
            commaSep fn rest (addAscii ", " (fn first builder))


{-| Prints each element of the list with `fn`, separated by a comma, a newline
and the indentation one level deeper than `level`.

Nothing is printed before the first element or after the last, so the caller
starts the first line and closes the last.

-}
commaNewlineSep : Level -> (a -> Builder -> Builder) -> List a -> Builder -> Builder
commaNewlineSep ((Level _ nextLevel) as level) fn exprs builder =
    case exprs of
        [] ->
            builder

        [ first ] ->
            fn first builder

        first :: rest ->
            let
                (Level deeperIndent _) =
                    nextLevel ()
            in
            commaNewlineSep level fn rest (addByteString deeperIndent (addLine (addAscii "," (fn first builder))))



-- ====== STATEMENTS ======


{-| Prints the statements one after another at `level`.
-}
fromStmtBlock : Level -> List Stmt -> Builder -> Builder
fromStmtBlock level stmts builder =
    List.foldl (fromStmt level) builder stmts


{-| Prints one statement at indentation `level`, laid out as `Stmt` describes.
-}
fromStmt : Level -> Stmt -> Builder -> Builder
fromStmt ((Level indent nextLevel) as level) statement builder =
    case statement of
        Block stmts ->
            fromStmtBlock level stmts builder

        EmptyStmt ->
            builder

        ExprStmt expr ->
            builder
                |> addByteString indent
                |> fromExpr level Whatever expr
                |> addAscii ";"
                |> addLine

        IfStmt condition thenStmt elseStmt ->
            builder
                |> addByteString indent
                |> addAscii "if ("
                |> fromExpr level Whatever condition
                |> addAscii ") {"
                |> addLine
                |> fromStmt (nextLevel ()) thenStmt
                |> addByteString indent
                |> addAscii "} else {"
                |> addLine
                |> fromStmt (nextLevel ()) elseStmt
                |> addByteString indent
                |> addAscii "}"
                |> addLine

        Switch expr clauses ->
            builder
                |> addByteString indent
                |> addAscii "switch ("
                |> fromExpr level Whatever expr
                |> addAscii ") {"
                |> addLine
                |> fromClauses (nextLevel ()) clauses
                |> addByteString indent
                |> addAscii "}"
                |> addLine

        While expr stmt ->
            builder
                |> addByteString indent
                |> addAscii "while ("
                |> fromExpr level Whatever expr
                |> addAscii ") {"
                |> addLine
                |> fromStmt (nextLevel ()) stmt
                |> addByteString indent
                |> addAscii "}"
                |> addLine

        Break Nothing ->
            builder
                |> addAscii "break;"
                |> addLine

        Break (Just label) ->
            builder
                |> addByteString indent
                |> addAscii "break "
                |> addByteString label
                |> addAscii ";"
                |> addLine

        Continue Nothing ->
            builder
                |> addAscii "continue;"
                |> addLine

        Continue (Just label) ->
            builder
                |> addByteString indent
                |> addAscii "continue "
                |> addByteString label
                |> addAscii ";"
                |> addLine

        Labelled label stmt ->
            builder
                |> addByteString indent
                |> addByteString label
                |> addAscii ":"
                |> addLine
                |> fromStmt level stmt

        Try tryStmt errorName catchStmt ->
            builder
                |> addByteString indent
                |> addAscii "try {"
                |> addLine
                |> fromStmt (nextLevel ()) tryStmt
                |> addByteString indent
                |> addAscii "} catch ("
                |> addByteString errorName
                |> addAscii ") {"
                |> addLine
                |> fromStmt (nextLevel ()) catchStmt
                |> addByteString indent
                |> addAscii "}"
                |> addLine

        Throw expr ->
            builder
                |> addByteString indent
                |> addAscii "throw "
                |> fromExpr level Whatever expr
                |> addAscii ";"

        Return expr ->
            builder
                |> addByteString indent
                |> addAscii "return "
                |> fromExpr level Whatever expr
                |> addAscii ";"
                |> addLine

        Var name expr ->
            builder
                |> addByteString indent
                |> addAscii "var "
                |> addByteString name
                |> addAscii " = "
                |> fromExpr level Whatever expr
                |> addAscii ";"
                |> addLine

        TrackedVar moduleName pos name genName expr ->
            builder
                |> addByteString indent
                |> addAscii "var "
                |> addName moduleName pos name genName
                |> addAscii " = "
                |> fromExpr level Whatever expr
                |> addAscii ";"
                |> addLine

        Vars [] ->
            builder

        Vars vars ->
            builder
                |> addByteString indent
                |> addAscii "var "
                |> commaNewlineSep level (varToBuilder level) vars
                |> addAscii ";"
                |> addLine

        FunctionStmt name args stmts ->
            builder
                |> addByteString indent
                |> addAscii "function "
                |> addByteString name
                |> addAscii "("
                |> commaSep addByteString args
                |> addAscii ") {"
                |> addLine
                |> fromStmtBlock (nextLevel ()) stmts
                |> addByteString indent
                |> addAscii "}"
                |> addLine



-- ====== SWITCH CLAUSES ======


{-| Prints one switch clause at `level`, with its statements one level deeper.
-}
fromClause : Level -> Case -> Builder -> Builder
fromClause ((Level indent nextLevel) as level) clause builder =
    case clause of
        Case expr stmts ->
            builder
                |> addByteString indent
                |> addAscii "case "
                |> fromExpr level Whatever expr
                |> addAscii ":"
                |> addLine
                |> fromStmtBlock (nextLevel ()) stmts

        Default stmts ->
            builder
                |> addByteString indent
                |> addAscii "default:"
                |> addLine
                |> fromStmtBlock (nextLevel ()) stmts


{-| Prints the switch clauses in order, each at `level`.
-}
fromClauses : Level -> List Case -> Builder -> Builder
fromClauses level clauses builder =
    case clauses of
        [] ->
            builder

        first :: rest ->
            fromClauses level rest (fromClause level first builder)



-- ====== VAR DECLS ======


{-| Prints one `name = value` of a `var` declaration, with no indentation of
its own.
-}
varToBuilder : Level -> ( Name.Name, Expr ) -> Builder -> Builder
varToBuilder level ( name, expr ) builder =
    builder
        |> addByteString name
        |> addAscii " = "
        |> fromExpr level Whatever expr



-- ====== EXPRESSIONS ======


{-| Whether an expression is laid out as a single line (`One`) or may span
several (`Many`), as `fromExprLines` decides. `Many` says the expression may
span lines, not that it does: a call with no arguments is `Many`.
-}
type Lines
    = One
    | Many


{-| Returns `Many` if either argument is `Many`, and `One` otherwise.
-}
merge : Lines -> Lines -> Lines
merge a b =
    if a == Many || b == Many then
        Many

    else
        One


{-| Returns whether `func` finds any element of `xs` to be `Many`.
-}
linesMap : (a -> Lines) -> List a -> Bool
linesMap func xs =
    linesMapHelp func xs


{-| Does the work of `linesMap`, stopping at the first `Many`.
-}
linesMapHelp : (a -> Lines) -> List a -> Bool
linesMapHelp func xs =
    case xs of
        [] ->
            False

        a :: rest ->
            case func a of
                Many ->
                    True

                One ->
                    linesMapHelp func rest


{-| What the place an expression is printed in needs of it.

`Atomic` is an operand position, where an operator expression, a conditional
or an assignment must be put in parentheses to be read as one unit. `Whatever`
needs no parentheses. Every other expression is printed the same in both.

-}
type Grouping
    = Atomic
    | Whatever


{-| Prints `fillContent` onto `builder`, inside parentheses when `grouping` is
`Atomic`.
-}
parensFor : Grouping -> Builder -> (Builder -> Builder) -> Builder
parensFor grouping builder fillContent =
    case grouping of
        Atomic ->
            builder
                |> addAscii "("
                |> fillContent
                |> addAscii ")"

        Whatever ->
            fillContent builder


{-| Prints an expression at indentation `level`, laid out as `Expr` and the
module docstring describe. `grouping` matters only for an operator expression,
a conditional or an assignment, which it puts in parentheses when `Atomic`.
-}
fromExpr : Level -> Grouping -> Expr -> Builder -> Builder
fromExpr ((Level indent nextLevel) as level) grouping expression builder =
    let
        (Level deeperIndent _) =
            nextLevel ()
    in
    case expression of
        ExprString string ->
            addByteString ("'" ++ string ++ "'") builder

        ExprTrackedString moduleName position string ->
            addTrackedByteString moduleName position ("'" ++ string ++ "'") builder

        ExprTrackedFloat moduleName position float ->
            addTrackedByteString moduleName position float builder

        ExprInt n ->
            addByteString (String.fromInt n) builder

        ExprTrackedInt moduleName position n ->
            addTrackedByteString moduleName position (String.fromInt n) builder

        ExprBool bool ->
            addAscii
                (if bool then
                    "true"

                 else
                    "false"
                )
                builder

        ExprTrackedBool moduleName position bool ->
            addTrackedByteString moduleName
                position
                (if bool then
                    "true"

                 else
                    "false"
                )
                builder

        ExprJson json ->
            addAscii (Json.encodeUgly json) builder

        ExprArray exprs ->
            let
                anyMany : Bool
                anyMany =
                    linesMap (fromExprLines level) exprs
            in
            if anyMany then
                builder
                    |> addAscii "["
                    |> addLine
                    |> addByteString deeperIndent
                    |> commaNewlineSep level (fromExpr level Whatever) exprs
                    |> addLine
                    |> addByteString indent
                    |> addAscii "]"

            else
                builder
                    |> addAscii "["
                    |> commaSep (fromExpr level Whatever) exprs
                    |> addAscii "]"

        ExprTrackedArray moduleName (A.Region start (A.Position endLine endCol)) exprs ->
            let
                anyMany : Bool
                anyMany =
                    linesMap (fromExprLines level) exprs
            in
            if anyMany then
                builder
                    |> addTrackedByteString moduleName start "["
                    |> addLine
                    |> addByteString deeperIndent
                    |> commaNewlineSep level (fromExpr level Whatever) exprs
                    |> addLine
                    |> addByteString indent
                    |> addTrackedByteString moduleName (A.Position endLine (endCol - 1)) "]"

            else
                builder
                    |> addTrackedByteString moduleName start "["
                    |> commaSep (fromExpr level Whatever) exprs
                    |> addTrackedByteString moduleName (A.Position endLine (endCol - 1)) "]"

        ExprObject fields ->
            let
                anyMany : Bool
                anyMany =
                    linesMap (fromFieldLines (nextLevel ())) fields
            in
            if anyMany then
                builder
                    |> addAscii "{"
                    |> addLine
                    |> addByteString deeperIndent
                    |> commaNewlineSep level (fromField (nextLevel ())) fields
                    |> addLine
                    |> addByteString indent
                    |> addAscii "}"

            else
                builder
                    |> addAscii "{"
                    |> commaSep (fromField (nextLevel ())) fields
                    |> addAscii "}"

        ExprTrackedObject moduleName (A.Region start (A.Position endLine endCol)) fields ->
            let
                anyMany : Bool
                anyMany =
                    linesMap (trackedFromFieldLines (nextLevel ())) fields
            in
            if anyMany then
                builder
                    |> addTrackedByteString moduleName start "{"
                    |> addLine
                    |> addByteString deeperIndent
                    |> commaNewlineSep level (trackedFromField (nextLevel ()) moduleName) fields
                    |> addLine
                    |> addByteString indent
                    |> addTrackedByteString moduleName (A.Position endLine (endCol - 1)) "}"

            else
                builder
                    |> addTrackedByteString moduleName start "{"
                    |> commaSep (trackedFromField (nextLevel ()) moduleName) fields
                    |> addTrackedByteString moduleName (A.Position endLine (endCol - 1)) "}"

        ExprRef name ->
            addByteString name builder

        ExprTrackedRef position moduleName name generatedName ->
            addName position moduleName name generatedName builder

        ExprAccess expr field ->
            makeDot level expr field builder

        ExprTrackedAccess expr moduleName ((A.Position fieldLine fieldCol) as position) field ->
            builder
                |> fromExpr level Atomic expr
                |> addTrackedDot moduleName (A.Position fieldLine (fieldCol - 1))
                |> addName moduleName position field field

        ExprIndex expr bracketedExpr ->
            makeBracketed level expr bracketedExpr builder

        ExprPrefix op expr ->
            parensFor grouping builder <|
                (fromPrefix op
                    >> fromExpr level Atomic expr
                )

        ExprInfix op leftExpr rightExpr ->
            parensFor grouping builder <|
                \b ->
                    fromExpr level Atomic leftExpr b
                        |> fromInfix op
                        |> fromExpr level Atomic rightExpr

        ExprIf condExpr thenExpr elseExpr ->
            parensFor grouping builder <|
                fromExpr level Atomic condExpr
                    >> addAscii " ? "
                    >> fromExpr level Atomic thenExpr
                    >> addAscii " : "
                    >> fromExpr level Atomic elseExpr

        ExprAssign lValue expr ->
            parensFor grouping builder <|
                \b ->
                    fromLValue level lValue b
                        |> addAscii " = "
                        |> fromExpr level Whatever expr

        ExprCall function args ->
            let
                anyMany : Bool
                anyMany =
                    linesMap (fromExprLines (nextLevel ())) args

                funcB : Builder
                funcB =
                    fromExpr level Atomic function builder
            in
            if anyMany then
                funcB
                    |> addAscii "("
                    |> addLine
                    |> addByteString deeperIndent
                    |> commaNewlineSep level (fromExpr (nextLevel ()) Whatever) args
                    |> addAscii ")"

            else
                funcB
                    |> addAscii "("
                    |> commaSep (fromExpr (nextLevel ()) Whatever) args
                    |> addAscii ")"

        ExprTrackedNormalCall moduleName position helper function args ->
            let
                anyMany : Bool
                anyMany =
                    linesMap (fromExprLines (nextLevel ())) args

                trackedHelper : Expr
                trackedHelper =
                    case ( trackedNameFromExpr function, helper ) of
                        ( Just functionName, ExprRef helperName ) ->
                            ExprTrackedRef moduleName position functionName helperName

                        _ ->
                            helper

                funcB : Builder
                funcB =
                    fromExpr level Atomic trackedHelper builder
            in
            if anyMany then
                funcB
                    |> addAscii "("
                    |> addLine
                    |> addByteString deeperIndent
                    |> commaNewlineSep level (fromExpr (nextLevel ()) Whatever) (function :: args)
                    |> addAscii ")"

            else
                funcB
                    |> addAscii "("
                    |> commaSep (fromExpr (nextLevel ()) Whatever) (function :: args)
                    |> addAscii ")"

        ExprFunction maybeName args stmts ->
            builder
                |> addAscii "function "
                |> addByteString (Maybe.unwrap "" identity maybeName)
                |> addAscii "("
                |> commaSep addByteString args
                |> addAscii ") {"
                |> addLine
                |> fromStmtBlock (nextLevel ()) stmts
                |> addByteString indent
                |> addAscii "}"

        ExprTrackedFunction moduleName args stmts ->
            builder
                |> addAscii "function "
                |> addAscii "("
                |> commaSep (\(A.At (A.Region start _) name) -> addName moduleName start name name) args
                |> addAscii ") {"
                |> addLine
                |> fromStmtBlock (nextLevel ()) stmts
                |> addByteString indent
                |> addAscii "}"


{-| Returns the name an `ExprTrackedRef` reports, or `Nothing` for any other
expression.
-}
trackedNameFromExpr : Expr -> Maybe Name.Name
trackedNameFromExpr expr =
    case expr of
        ExprTrackedRef _ _ name _ ->
            Just name

        _ ->
            Nothing


{-| Decides whether an expression may span lines.

Arrays, objects, calls, functions and conditionals are `Many` whatever they
contain, and literals and names are `One`. A property access, index, operator
expression or assignment is `Many` when any part of it is. `level` plays no
part in the answer.

-}
fromExprLines : Level -> Expr -> Lines
fromExprLines level expression =
    case expression of
        ExprString _ ->
            One

        ExprTrackedString _ _ _ ->
            One

        ExprTrackedFloat _ _ _ ->
            One

        ExprInt _ ->
            One

        ExprTrackedInt _ _ _ ->
            One

        ExprBool _ ->
            One

        ExprTrackedBool _ _ _ ->
            One

        ExprJson _ ->
            One

        ExprArray _ ->
            Many

        ExprTrackedArray _ _ _ ->
            Many

        ExprObject _ ->
            Many

        ExprTrackedObject _ _ _ ->
            Many

        ExprRef _ ->
            One

        ExprTrackedRef _ _ _ _ ->
            One

        ExprAccess expr _ ->
            makeDotLines level expr

        ExprTrackedAccess expr _ _ _ ->
            fromExprLines level expr

        ExprIndex expr bracketedExpr ->
            makeBracketedLines level expr bracketedExpr

        ExprPrefix _ expr ->
            fromExprLines level expr

        ExprInfix _ leftExpr rightExpr ->
            merge (fromExprLines level leftExpr) (fromExprLines level rightExpr)

        ExprIf _ _ _ ->
            Many

        ExprAssign lValue expr ->
            merge (fromLValueLines level lValue) (fromExprLines level expr)

        ExprCall _ _ ->
            Many

        ExprTrackedNormalCall _ _ _ _ _ ->
            Many

        ExprFunction _ _ _ ->
            Many

        ExprTrackedFunction _ _ _ ->
            Many



-- ====== FIELDS ======


{-| Prints one `name: value` field of an object, the value at `level`.
-}
fromField : Level -> ( Name.Name, Expr ) -> Builder -> Builder
fromField level ( field, expr ) builder =
    builder
        |> addByteString field
        |> addAscii ": "
        |> fromExpr level Whatever expr


{-| Decides whether an object field may span lines, which is whether its
value may.
-}
fromFieldLines : Level -> ( Name.Name, Expr ) -> Lines
fromFieldLines level ( _, expr ) =
    fromExprLines level expr


{-| Prints one field of an `ExprTrackedObject`, mapping the name to the start
of its region and the `:` after it to the end of that region.
-}
trackedFromField : Level -> ModuleName.Canonical -> ( A.Located Name.Name, Expr ) -> Builder -> Builder
trackedFromField level moduleName ( A.At (A.Region start end) field, expr ) builder =
    builder
        |> addName moduleName start field field
        |> addTrackedByteString moduleName end ": "
        |> fromExpr level Whatever expr


{-| Decides whether a field of an `ExprTrackedObject` may span lines, which is
whether its value may.
-}
trackedFromFieldLines : Level -> ( A.Located Name.Name, Expr ) -> Lines
trackedFromFieldLines level ( _, expr ) =
    fromExprLines level expr



-- ====== VALUES ======


{-| Prints the target of an assignment.
-}
fromLValue : Level -> LValue -> Builder -> Builder
fromLValue level lValue builder =
    case lValue of
        LRef name ->
            addByteString name builder

        LBracket expr bracketedExpr ->
            makeBracketed level expr bracketedExpr builder


{-| Decides whether the target of an assignment may span lines.
-}
fromLValueLines : Level -> LValue -> Lines
fromLValueLines level lValue =
    case lValue of
        LRef _ ->
            One

        LBracket expr bracketedExpr ->
            makeBracketedLines level expr bracketedExpr


{-| Prints `expr.field`, with `expr` in an operand position.
-}
makeDot : Level -> Expr -> Name.Name -> Builder -> Builder
makeDot level expr field builder =
    builder
        |> fromExpr level Atomic expr
        |> addAscii "."
        |> addByteString field


{-| Decides whether `expr.field` may span lines, which is whether `expr` may.
-}
makeDotLines : Level -> Expr -> Lines
makeDotLines level expr =
    fromExprLines level expr


{-| Prints `expr[bracketedExpr]`, with `expr` in an operand position.
-}
makeBracketed : Level -> Expr -> Expr -> Builder -> Builder
makeBracketed level expr bracketedExpr builder =
    fromExpr level Atomic expr builder
        |> addAscii "["
        |> fromExpr level Whatever bracketedExpr
        |> addAscii "]"


{-| Decides whether `expr[bracketedExpr]` may span lines, which is whether
either expression may.
-}
makeBracketedLines : Level -> Expr -> Expr -> Lines
makeBracketedLines level expr bracketedExpr =
    merge (fromExprLines level expr) (fromExprLines level bracketedExpr)



-- ====== OPERATORS ======


{-| Prints the symbol of a prefix operator.
-}
fromPrefix : PrefixOp -> Builder -> Builder
fromPrefix op =
    addAscii
        (case op of
            PrefixNot ->
                "!"

            PrefixNegate ->
                "-"

            PrefixComplement ->
                "~"
        )


{-| Prints the symbol of a binary operator, with a space on each side.
-}
fromInfix : InfixOp -> Builder -> Builder
fromInfix op =
    addAscii
        (case op of
            OpAdd ->
                " + "

            OpSub ->
                " - "

            OpMul ->
                " * "

            OpDiv ->
                " / "

            OpMod ->
                " % "

            OpEq ->
                " === "

            OpNe ->
                " !== "

            OpLt ->
                " < "

            OpLe ->
                " <= "

            OpGt ->
                " > "

            OpGe ->
                " >= "

            OpAnd ->
                " && "

            OpOr ->
                " || "

            OpBitwiseAnd ->
                " & "

            OpBitwiseXor ->
                " ^ "

            OpBitwiseOr ->
                " | "

            OpLShift ->
                " << "

            OpSpRShift ->
                " >> "

            OpZfRShift ->
                " >>> "
        )



-- ====== BUILDER ======


{-| The state of a print in progress: the text printed so far, the line and
column the next character will go at, the mappings recorded, and the kernel
code stored by `addKernel`.

`revBuilders` is the printed text in order, despite its name. `revKernels` and
`mappings` are newest first. `currentCol` counts from 1 on each line.

-}
type alias BuilderData =
    { revKernels : List String
    , revBuilders : String
    , currentLine : Int
    , currentCol : Int
    , mappings : List Mapping
    }


{-| A print in progress, holding what `BuilderData` describes. The constructor
is exposed, so the data can be read, and written, directly.
-}
type Builder
    = Builder BuilderData


{-| One mapping: a position in the printed text, and the Elm module and source
position it came from.

`genLine` and `genCol` are the printed position, with lines counted from the
builder's starting line and columns from 1. `srcLine` and `srcCol` are the Elm
source position, as the row and column of an `A.Position`. `srcName` is
the name the mapping reports, which can differ from the printed text, and is
`Nothing` for literals and punctuation.

-}
type alias MappingData =
    { srcLine : Int
    , srcCol : Int
    , srcModule : ModuleName.Canonical
    , srcName : Maybe Name.Name
    , genLine : Int
    , genCol : Int
    }


{-| A mapping, holding what `MappingData` describes. The constructor is
exposed, so the data can be read, and written, directly.
-}
type Mapping
    = Mapping MappingData


{-| Creates a builder with no text, kernel code or mappings, whose next
character goes at column 1 of line `startLine`.
-}
emptyBuilder : Int -> Builder
emptyBuilder startLine =
    Builder { revKernels = [], revBuilders = "", currentLine = startLine, currentCol = 1, mappings = [] }


{-| Appends text with no mapping, advancing the column by the text's length.
The line is not advanced, so the text must not contain a newline.
-}
addAscii : String -> Builder -> Builder
addAscii ascii (Builder b) =
    Builder { b | revBuilders = b.revBuilders ++ ascii, currentCol = b.currentCol + String.length ascii }


{-| Stores a piece of kernel JavaScript in the builder's `revKernels`, apart
from the printed text. The line, the column and the mappings do not change.
-}
addKernel : String -> Builder -> Builder
addKernel kernel (Builder b) =
    Builder { b | revKernels = kernel :: b.revKernels }


{-| Appends text with no mapping.

Text without a line break advances the column by its length. Text with line
breaks advances the line by their number and sets the column to 1, which is
right only when the text ends with a line break.

-}
addByteString : String -> Builder -> Builder
addByteString str (Builder b) =
    let
        bsLines : Int
        bsLines =
            List.length (String.lines str) - 1
    in
    if bsLines == 0 then
        let
            bsSize : Int
            bsSize =
                String.length str
        in
        Builder { b | revBuilders = b.revBuilders ++ str, currentCol = b.currentCol + bsSize }

    else
        Builder { b | revBuilders = b.revBuilders ++ str, currentLine = b.currentLine + bsLines, currentCol = 1 }


{-| Appends text as `addByteString` does, and records a mapping from where the
text starts to the given position in `moduleName`, with no name.
-}
addTrackedByteString : ModuleName.Canonical -> A.Position -> String -> Builder -> Builder
addTrackedByteString moduleName (A.Position line col) str (Builder b) =
    let
        bsLines : Int
        bsLines =
            List.length (String.lines str) - 1

        newMappings : List Mapping
        newMappings =
            Mapping { srcLine = line, srcCol = col, srcModule = moduleName, srcName = Nothing, genLine = b.currentLine, genCol = b.currentCol }
                :: b.mappings
    in
    if bsLines == 0 then
        let
            bsSize : Int
            bsSize =
                String.length str
        in
        Builder { b | revBuilders = b.revBuilders ++ str, currentCol = b.currentCol + bsSize, mappings = newMappings }

    else
        Builder { b | revBuilders = b.revBuilders ++ str, currentLine = b.currentLine + bsLines, currentCol = 1, mappings = newMappings }


{-| Appends `genName` and records a mapping from where it starts to the given
position, reporting `name`. The column advances by the length of `genName`,
so it must not contain a newline.
-}
addName : ModuleName.Canonical -> A.Position -> Name.Name -> Name.Name -> Builder -> Builder
addName moduleName (A.Position line col) name genName (Builder b) =
    let
        size : Int
        size =
            String.length genName
    in
    Builder
        { b
            | revBuilders = b.revBuilders ++ genName
            , currentCol = b.currentCol + size
            , mappings =
                Mapping { srcLine = line, srcCol = col, srcModule = moduleName, srcName = Just name, genLine = b.currentLine, genCol = b.currentCol }
                    :: b.mappings
        }


{-| Appends a `.` and records a mapping from it to the given position.
-}
addTrackedDot : ModuleName.Canonical -> A.Position -> Builder -> Builder
addTrackedDot moduleName (A.Position line col) (Builder b) =
    Builder
        { b
            | revBuilders = b.revBuilders ++ "."
            , currentCol = b.currentCol + 1
            , mappings =
                Mapping { srcLine = line, srcCol = col, srcModule = moduleName, srcName = Nothing, genLine = b.currentLine, genCol = b.currentCol }
                    :: b.mappings
        }


{-| Ends the current line, so the next character goes at column 1 of the
next line.
-}
addLine : Builder -> Builder
addLine (Builder b) =
    Builder { b | revBuilders = b.revBuilders ++ "\n", currentLine = b.currentLine + 1, currentCol = 1 }
