module Compiler.Generate.JavaScript.Expression exposing
    ( generate, Code
    , codeToExpr, codeToStmtList
    , generateCtor, generateField, generateMain, generateTailDef
    )

{-| The JavaScript back end needs every optimized Elm expression written as
JavaScript, and this module does that translation, producing the JavaScript
syntax tree of `Compiler.Generate.JavaScript.Builder`.

Two facts shape the module.

The first is that some Elm expressions are naturally JavaScript expressions and
others are naturally statements. A literal or a call is an expression; a `let`,
a tail call or a `case` needs variable declarations, loops and `break`s. So
`generate` returns `Code`, which is either one expression or a block of
statements, and the caller converts it to whichever form its context needs.
`codeToExpr` turns a block into an immediately called function, and
`codeToStmtList` turns an expression into a `return`.

The second is that the data representation depends on the `Mode`, whose meaning
`Compiler.Generate.Mode` states. In a development build, constructors are
objects tagged with their name in the `$` property, an enumeration constructor
or a single-field wrapper ("box") is referred to by its global name, `()` is
`_Utils_Tuple0`, and a `Char` is wrapped by `_Utils_chr`. In a production build,
constructors are tagged with an integer, an enumeration constructor is that bare
integer, a box is the wrapped value itself, `()` is `0`, a `Char` is a plain
string, and record fields are renamed to their short names. Code that builds
or inspects constructors, `Char`s, `()` and record fields therefore branches on
the mode.

Functions are curried in Elm. A function of two to nine parameters is wrapped
in one of the runtime helpers `F2` to `F9`, and a call with two to nine
arguments goes through `A2` to `A9`; other arities are curried and applied one
argument at a time. Calls to some `elm/core` functions are written inline:
arithmetic, Boolean and `Bitwise` operators as JavaScript operators,
`Tuple.first` and `Tuple.second` as property accesses, `<|` and `|>` as a direct
call, `++` as a `+` chain when a string literal is involved, and comparisons as
operators when a literal is involved.

A tail call becomes a `continue` of a `while (true)` loop labelled with the
function's name. A `case` becomes a decision tree of `if` and `switch`
statements; a branch body shared by several leaves is placed after a labelled
`while (true)` block, and each leaf that reaches it `break`s out of that block.

Much of the output is "tracked": it carries the module and source position the
builder uses for the source map.


# Code Generation

@docs generate, Code


# Code Conversion

@docs codeToExpr, codeToStmtList


# Specialized Generators

@docs generateCtor, generateField, generateMain, generateTailDef

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Path as Path
import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.Optimized as Opt
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Compiler.Type as Type
import Compiler.Elm.Compiler.Type.Extract as Extract
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Generate.JavaScript.Builder as JS
import Compiler.Generate.JavaScript.Name as JsName
import Compiler.Generate.Mode as Mode
import Compiler.Json.Encode as Encode
import Compiler.LocalOpt.Erased.DecisionTree as DT
import Compiler.Reporting.Annotation as A
import Data.Map as EveryDict
import Data.Set as EverySet
import Dict exposing (Dict)
import Prelude
import Utils.Crash exposing (crash)
import Utils.Main as Utils


{-| Generates `expression` as a single JavaScript expression, wrapping a
statement block in an immediately called function.
-}
generateJsExpr : Mode.Mode -> ModuleName.Canonical -> Opt.Expr -> JS.Expr
generateJsExpr mode parentModule expression =
    codeToExpr (generate mode parentModule expression)


{-| Generates `expression`, found in module `parentModule`, as JavaScript.

The result is an expression where the construct allows one, and a statement
block for a tail call, a `case`, a `let`, a destructuring, and an `if` with a
block in any branch. A whole-number `Float` literal is written with a trailing
`.0` unless its text is in exponent form.

-}
generate : Mode.Mode -> ModuleName.Canonical -> Opt.Expr -> Code
generate mode parentModule expression =
    case expression of
        Opt.Bool (A.Region start _) bool ->
            JS.ExprTrackedBool parentModule start bool |> JsExpr

        Opt.Chr (A.Region start _) char ->
            JsExpr <|
                case mode of
                    Mode.Dev _ ->
                        JS.ExprCall toChar [ JS.ExprTrackedString parentModule start char ]

                    Mode.Prod _ ->
                        JS.ExprTrackedString parentModule start char

        Opt.Str (A.Region start _) string ->
            JS.ExprTrackedString parentModule start string |> JsExpr

        Opt.Int (A.Region start _) int ->
            if int < 0 then
                -- A negative literal value (a hex literal at or above 2^63, or a
                -- folded negation) is written as a negation of its magnitude, so
                -- it is parenthesized where it must be: an atomic `-1` after a
                -- prefix `-` would print `--1`, which is not JS. The magnitude
                -- is taken from the text, which is exact even for `-2^63`.
                JS.ExprTrackedFloat parentModule start (String.dropLeft 1 (String.fromInt int))
                    |> JS.ExprPrefix JS.PrefixNegate
                    |> JsExpr

            else
                JS.ExprTrackedInt parentModule start int |> JsExpr

        Opt.Float (A.Region start _) float ->
            let
                text =
                    String.fromFloat float
            in
            -- From 1e21 on the text is in exponent form ("1e+21"), where ".0" is not JS.
            -- Infinity and NaN print as JS identifiers, which take no ".0" either;
            -- testing them first also keeps `floor` away from them.
            (if not (isInfinite float) && not (isNaN float) && float == toFloat (floor float) && not (String.contains "e" text) && not (String.contains "." text) then
                text ++ ".0"

             else
                text
            )
                |> JS.ExprTrackedFloat parentModule start
                |> JsExpr

        Opt.VarLocal name ->
            JS.ExprRef (JsName.fromLocal name) |> JsExpr

        Opt.TrackedVarLocal (A.Region startPos _) name ->
            JS.ExprTrackedRef parentModule startPos (JsName.fromLocalHumanReadable name) (JsName.fromLocal name) |> JsExpr

        Opt.VarGlobal (A.Region startPos _) (Opt.Global home name) ->
            JS.ExprTrackedRef parentModule startPos (JsName.fromGlobalHumanReadable home name) (JsName.fromGlobal home name) |> JsExpr

        Opt.VarEnum (A.Region startPos _) (Opt.Global home name) index ->
            case mode of
                Mode.Dev _ ->
                    JS.ExprTrackedRef parentModule startPos (JsName.fromGlobalHumanReadable home name) (JsName.fromGlobal home name) |> JsExpr

                Mode.Prod _ ->
                    JS.ExprInt (Index.toMachine index) |> JsExpr

        Opt.VarBox (A.Region startPos _) (Opt.Global home name) ->
            JsExpr <|
                case mode of
                    Mode.Dev _ ->
                        JS.ExprTrackedRef parentModule startPos (JsName.fromGlobalHumanReadable home name) (JsName.fromGlobal home name)

                    Mode.Prod _ ->
                        JS.ExprRef (JsName.fromGlobal ModuleName.basics Name.identity_)

        Opt.VarCycle (A.Region startPos _) home name ->
            JS.ExprCall (JS.ExprTrackedRef parentModule startPos (JsName.fromGlobalHumanReadable home name) (JsName.fromCycle home name)) [] |> JsExpr

        Opt.VarDebug region name home unhandledValueName ->
            generateDebug name home region unhandledValueName |> JsExpr

        Opt.VarKernel (A.Region startPos _) kernelPrefix home name ->
            let
                jsName =
                    if kernelPrefix == "Eco" then
                        JsName.fromEcoKernel home name

                    else
                        JsName.fromKernel home name
            in
            JS.ExprTrackedRef parentModule startPos jsName jsName |> JsExpr

        Opt.List region entries ->
            case entries of
                [] ->
                    JS.ExprRef (JsName.fromKernel Name.list "Nil") |> JsExpr

                _ ->
                    JsExpr <|
                        JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.list "fromArray"))
                            [ List.map (generateJsExpr mode parentModule) entries |> JS.ExprTrackedArray parentModule region
                            ]

        Opt.Function args body ->
            generateFunction (List.map JsName.fromLocal args) (generate mode parentModule body)

        Opt.TrackedFunction args body ->
            let
                argNames : List (A.Located JsName.Name)
                argNames =
                    List.map (\(A.At region name) -> A.At region (JsName.fromLocal name)) args
            in
            generateTrackedFunction parentModule argNames (generate mode parentModule body)

        Opt.Call (A.Region startPos _) func args ->
            generateCall mode parentModule startPos func args |> JsExpr

        Opt.TailCall name args ->
            generateTailCall mode parentModule name args |> JsBlock

        Opt.If branches final ->
            generateIf mode parentModule branches final

        Opt.Let def body ->
            (generateDef mode parentModule def :: codeToStmtList (generate mode parentModule body)) |> JsBlock

        Opt.Destruct (Opt.Destructor name path) body ->
            let
                pathDef : JS.Stmt
                pathDef =
                    JS.Var (JsName.fromLocal name) (generatePath mode path)
            in
            (pathDef :: codeToStmtList (generate mode parentModule body)) |> JsBlock

        Opt.Case label root decider jumps ->
            generateCase mode parentModule label root decider jumps |> JsBlock

        Opt.Accessor _ field ->
            JsExpr <|
                JS.ExprFunction Nothing
                    [ JsName.dollar ]
                    [ JS.ExprAccess (JS.ExprRef JsName.dollar) (generateField mode field) |> JS.Return
                    ]

        Opt.Access record (A.Region startPos _) field ->
            JS.ExprTrackedAccess (generateJsExpr mode parentModule record) parentModule startPos (generateField mode field) |> JsExpr

        Opt.Update region record fields ->
            JsExpr <|
                JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.utils "update"))
                    [ generateJsExpr mode parentModule record
                    , generateTrackedRecord mode parentModule region fields
                    ]

        Opt.Record fields ->
            generateRecord mode parentModule fields |> JsExpr

        Opt.TrackedRecord region fields ->
            generateTrackedRecord mode parentModule region fields |> JsExpr

        Opt.Unit ->
            case mode of
                Mode.Dev _ ->
                    JS.ExprRef (JsName.fromKernel Name.utils "Tuple0") |> JsExpr

                Mode.Prod _ ->
                    JS.ExprInt 0 |> JsExpr

        Opt.Tuple _ a b cs ->
            JsExpr <|
                case cs of
                    [] ->
                        JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.utils "Tuple2"))
                            [ generateJsExpr mode parentModule a
                            , generateJsExpr mode parentModule b
                            ]

                    [ c ] ->
                        JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.utils "Tuple3"))
                            [ generateJsExpr mode parentModule a
                            , generateJsExpr mode parentModule b
                            , generateJsExpr mode parentModule c
                            ]

                    _ ->
                        JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.utils "TupleN"))
                            (List.map (generateJsExpr mode parentModule) (a :: b :: cs))

        Opt.Shader src attributes uniforms ->
            let
                toTranlation : Name.Name -> ( JsName.Name, JS.Expr )
                toTranlation field =
                    ( JsName.fromLocal field
                    , JS.ExprString (generateField mode field)
                    )

                toTranslationObject : EverySet.EverySet String Name.Name -> JS.Expr
                toTranslationObject fields =
                    JS.ExprObject (List.map toTranlation (EverySet.toList fields))
            in
            JsExpr <|
                JS.ExprObject
                    [ ( JsName.fromLocal "src", JS.ExprString (Shader.toJsStringBuilder src) )
                    , ( JsName.fromLocal "attributes", toTranslationObject attributes )
                    , ( JsName.fromLocal "uniforms", toTranslationObject uniforms )
                    ]



-- ====== CODE CHUNKS ======


{-| Generated JavaScript for one Elm expression, either a single expression
(`JsExpr`) or a block of statements (`JsBlock`).
-}
type Code
    = JsExpr JS.Expr
    | JsBlock (List JS.Stmt)


{-| Returns `code` as one expression. A block consisting of a single `return`
becomes the returned expression, and any other block an immediately called
function of no arguments.
-}
codeToExpr : Code -> JS.Expr
codeToExpr code =
    case code of
        JsExpr expr ->
            expr

        JsBlock [ JS.Return expr ] ->
            expr

        JsBlock stmts ->
            JS.ExprCall (JS.ExprFunction Nothing [] stmts) []


{-| Returns `code` as the statements of a function body. An expression becomes a
`return` of it, except that an immediately called function of no arguments is
unwrapped into its own statements.
-}
codeToStmtList : Code -> List JS.Stmt
codeToStmtList code =
    case code of
        JsExpr (JS.ExprCall (JS.ExprFunction Nothing [] stmts) []) ->
            stmts

        JsExpr expr ->
            [ JS.Return expr ]

        JsBlock stmts ->
            stmts


{-| Returns `code` as one statement, as `codeToStmtList` does but grouping
several statements into a block.
-}
codeToStmt : Code -> JS.Stmt
codeToStmt code =
    case code of
        JsExpr (JS.ExprCall (JS.ExprFunction Nothing [] stmts) []) ->
            JS.Block stmts

        JsExpr expr ->
            JS.Return expr

        JsBlock [ stmt ] ->
            stmt

        JsBlock stmts ->
            JS.Block stmts



-- ====== CHARS ======


{-| A reference to the runtime function `_Utils_chr`, which a development build
wraps around every `Char` value.
-}
toChar : JS.Expr
toChar =
    JS.ExprRef (JsName.fromKernel Name.utils "chr")



-- ====== CTOR ======


{-| Generates the constructor `home.name` with zero-based `index` and `arity`
fields: a function of the fields (wrapped as `generateFunction` does) returning
an object whose `$` property is the tag and whose fields are named `a`, `b`, and
so on. The tag is the constructor's name in development and an integer in
production, which is its index except for `Dict`'s two red-black constructors,
tagged `-1` and `-2`. With arity 0 the result is the object itself.
-}
generateCtor : Mode.Mode -> Opt.Global -> Index.ZeroBased -> Int -> Code
generateCtor mode (Opt.Global home name) index arity =
    let
        argNames : List JsName.Name
        argNames =
            Index.indexedMap (\i _ -> JsName.fromIndex i) (List.range 1 arity)

        ctorTag : JS.Expr
        ctorTag =
            case mode of
                Mode.Dev _ ->
                    JS.ExprString name

                Mode.Prod _ ->
                    JS.ExprInt (ctorToInt home name index)
    in
    JS.ExprObject
        (( JsName.dollar, ctorTag ) :: List.map (\n -> ( n, JS.ExprRef n )) argNames)
        |> JsExpr
        |> generateFunction argNames


{-| Returns the production-mode tag of a constructor: its zero-based index,
except that `Dict`'s `RBNode_elm_builtin` and `RBEmpty_elm_builtin` get the
negative of their one-based index (`-1` and `-2`).
-}
ctorToInt : ModuleName.Canonical -> Name.Name -> Index.ZeroBased -> Int
ctorToInt home name index =
    if home == ModuleName.dict && (name == "RBNode_elm_builtin" || name == "RBEmpty_elm_builtin") then
        -(Index.toHuman index)

    else
        Index.toMachine index



-- ====== RECORDS ======


{-| Generates a record literal whose fields carry no source positions.
-}
generateRecord : Mode.Mode -> ModuleName.Canonical -> Dict Name.Name Opt.Expr -> JS.Expr
generateRecord mode parentModule fields =
    let
        toPair : ( Name.Name, Opt.Expr ) -> ( JsName.Name, JS.Expr )
        toPair ( field, value ) =
            ( generateField mode field, generateJsExpr mode parentModule value )
    in
    JS.ExprObject (List.map toPair (Dict.toList fields))


{-| Generates a record literal, keeping the region of the whole record and of
each field name for the source map.
-}
generateTrackedRecord : Mode.Mode -> ModuleName.Canonical -> A.Region -> EveryDict.Dict String (A.Located Name.Name) Opt.Expr -> JS.Expr
generateTrackedRecord mode parentModule region fields =
    let
        toPair : ( A.Located Name.Name, Opt.Expr ) -> ( A.Located JsName.Name, JS.Expr )
        toPair ( A.At fieldRegion field, value ) =
            ( A.At fieldRegion (generateField mode field), generateJsExpr mode parentModule value )
    in
    JS.ExprTrackedObject parentModule region (List.map toPair (EveryDict.toList fields))


{-| Returns the JavaScript property name of a record field: the field's own name
in development, and its short name in production. Crashes in production for a
field missing from the short-name table.
-}
generateField : Mode.Mode -> Name.Name -> JsName.Name
generateField mode name =
    case mode of
        Mode.Dev _ ->
            JsName.fromLocal name

        Mode.Prod fields ->
            case Dict.get name fields of
                Just v ->
                    v

                Nothing ->
                    crash "Compiler.Generate.JavaScript.Expression: field not found in ShortFieldNames"



-- ====== DEBUG ======


{-| Generates a reference to a `Debug` function used in module `home`.

`Debug.todo` becomes a call of the kernel's `todo` with the module name and
`region`, so that the crash can say where it came from. When
`unhandledValueName` is present the `todo` stands for an unhandled `case`
branch, and the kernel's `todoCase` also receives the value being matched.
Any other `Debug` function is a plain reference.

-}
generateDebug : Name.Name -> ModuleName.Canonical -> A.Region -> Maybe Name.Name -> JS.Expr
generateDebug name (ModuleName.Canonical _ home) region unhandledValueName =
    if name /= "todo" then
        JS.ExprRef (JsName.fromGlobal ModuleName.debug name)

    else
        case unhandledValueName of
            Nothing ->
                JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.debug "todo"))
                    [ JS.ExprString home
                    , regionToJsExpr region
                    ]

            Just valueName ->
                JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.debug "todoCase"))
                    [ JS.ExprString home
                    , regionToJsExpr region
                    , JS.ExprRef (JsName.fromLocal valueName)
                    ]


{-| Generates a `{ start, end }` object for a source region.
-}
regionToJsExpr : A.Region -> JS.Expr
regionToJsExpr (A.Region start end) =
    JS.ExprObject
        [ ( JsName.fromLocal "start", positionToJsExpr start )
        , ( JsName.fromLocal "end", positionToJsExpr end )
        ]


{-| Generates a `{ line, column }` object for a source position.
-}
positionToJsExpr : A.Position -> JS.Expr
positionToJsExpr (A.Position line column) =
    JS.ExprObject
        [ ( JsName.fromLocal "line", JS.ExprInt line )
        , ( JsName.fromLocal "column", JS.ExprInt column )
        ]



-- ====== FUNCTION ======


{-| Generates a function of `args` returning `body`: wrapped in `F2` to `F9` for
two to nine parameters, and otherwise written as nested one-parameter
functions.
-}
generateFunction : List JsName.Name -> Code -> Code
generateFunction args body =
    case Dict.get (List.length args) funcHelpers of
        Just helper ->
            JsExpr <|
                JS.ExprCall helper
                    [ codeToStmtList body |> JS.ExprFunction Nothing args
                    ]

        Nothing ->
            let
                addArg : JsName.Name -> Code -> Code
                addArg arg code =
                    codeToStmtList code |> JS.ExprFunction Nothing [ arg ] |> JsExpr
            in
            List.foldr addArg body args


{-| Generates a function as `generateFunction` does, keeping the parameters'
source regions for the source map. The regions are kept only when an `F`
helper is used or there is exactly one parameter; nested one-parameter
functions for other arities carry none.
-}
generateTrackedFunction : ModuleName.Canonical -> List (A.Located JsName.Name) -> Code -> Code
generateTrackedFunction parentModule args body =
    case Dict.get (List.length args) funcHelpers of
        Just helper ->
            JsExpr <|
                JS.ExprCall
                    helper
                    [ codeToStmtList body |> JS.ExprTrackedFunction parentModule args
                    ]

        Nothing ->
            case args of
                [ _ ] ->
                    codeToStmtList body |> JS.ExprTrackedFunction parentModule args |> JsExpr

                _ ->
                    let
                        addArg : JsName.Name -> Code -> Code
                        addArg arg code =
                            codeToStmtList code |> JS.ExprFunction Nothing [ arg ] |> JsExpr
                    in
                    List.foldr addArg body (List.map A.toValue args)


{-| The function-wrapping helpers `F2` to `F9`, keyed by arity.
-}
funcHelpers : Dict Int JS.Expr
funcHelpers =
    List.map (\n -> ( n, JS.ExprRef (JsName.makeF n) )) (List.range 2 9) |> Dict.fromList



-- ====== CALLS ======


{-| Generates a call of `func` on `args`.

A call of an `elm/core` global may be written inline (see `generateCoreCall`).
In production, calling a box constructor on one argument is just that argument.

-}
generateCall : Mode.Mode -> ModuleName.Canonical -> A.Position -> Opt.Expr -> List Opt.Expr -> JS.Expr
generateCall mode parentModule pos func args =
    case func of
        Opt.VarGlobal _ ((Opt.Global (ModuleName.Canonical pkg _) _) as global) ->
            if pkg == Pkg.core then
                generateCoreCall mode parentModule pos global args

            else
                generateCallHelp mode parentModule pos func args

        Opt.VarBox _ _ ->
            case mode of
                Mode.Dev _ ->
                    generateCallHelp mode parentModule pos func args

                Mode.Prod _ ->
                    case args of
                        [ arg ] ->
                            generateJsExpr mode parentModule arg

                        _ ->
                            generateCallHelp mode parentModule pos func args

        _ ->
            generateCallHelp mode parentModule pos func args


{-| Generates an ordinary call of `func` on `args`, with no inlining.
-}
generateCallHelp : Mode.Mode -> ModuleName.Canonical -> A.Position -> Opt.Expr -> List Opt.Expr -> JS.Expr
generateCallHelp mode parentModule pos func args =
    generateNormalCall parentModule
        pos
        (generateJsExpr mode parentModule func)
        (List.map (generateJsExpr mode parentModule) args)


{-| Generates an ordinary call of the global `home.name` on already generated
`args`. The reference is tracked for the source map unless `pos` is line 0,
column 0, the position of synthesized code.
-}
generateGlobalCall : ModuleName.Canonical -> A.Position -> ModuleName.Canonical -> Name.Name -> List JS.Expr -> JS.Expr
generateGlobalCall parentModule ((A.Position line col) as pos) home name args =
    let
        ref : JS.Expr
        ref =
            if line == 0 && col == 0 then
                JS.ExprRef (JsName.fromGlobal home name)

            else
                JS.ExprTrackedRef parentModule pos (JsName.fromGlobalHumanReadable home name) (JsName.fromGlobal home name)
    in
    generateNormalCall parentModule pos ref args


{-| Generates a call of `func` on `args` through `A2` to `A9` for two to nine
arguments, and otherwise as one single-argument call per argument.
-}
generateNormalCall : ModuleName.Canonical -> A.Position -> JS.Expr -> List JS.Expr -> JS.Expr
generateNormalCall parentModule pos func args =
    case Dict.get (List.length args) callHelpers of
        Just helper ->
            JS.ExprTrackedNormalCall parentModule pos helper func args

        Nothing ->
            List.foldl (\a f -> JS.ExprCall f [ a ]) func args


{-| The application helpers `A2` to `A9`, keyed by argument count.
-}
callHelpers : Dict Int JS.Expr
callHelpers =
    List.map (\n -> ( n, JS.ExprRef (JsName.makeA n) )) (List.range 2 9) |> Dict.fromList



-- ====== CORE CALLS ======


{-| Generates a call of a global from `elm/core`, writing it inline where the
module's helper knows how: `Basics`, `Bitwise`, `Tuple` and `Elm.JsArray`
(`Name.jsArray`). Any other call is an ordinary call.
-}
generateCoreCall : Mode.Mode -> ModuleName.Canonical -> A.Position -> Opt.Global -> List Opt.Expr -> JS.Expr
generateCoreCall mode parentModule pos (Opt.Global ((ModuleName.Canonical _ moduleName) as home) name) args =
    if moduleName == Name.basics then
        generateBasicsCall mode parentModule pos home name args

    else if moduleName == Name.bitwise then
        generateBitwiseCall parentModule pos home name (List.map (generateJsExpr mode parentModule) args)

    else if moduleName == Name.tuple then
        generateTupleCall parentModule pos home name (List.map (generateJsExpr mode parentModule) args)

    else if moduleName == Name.jsArray then
        generateJsArrayCall parentModule pos home name (List.map (generateJsExpr mode parentModule) args)

    else
        generateGlobalCall parentModule pos home name (List.map (generateJsExpr mode parentModule) args)


{-| Generates `Tuple.first` and `Tuple.second` on one argument as an access of
the tuple's `a` or `b` property, and anything else as an ordinary call.
-}
generateTupleCall : ModuleName.Canonical -> A.Position -> ModuleName.Canonical -> Name.Name -> List JS.Expr -> JS.Expr
generateTupleCall parentModule pos home name args =
    case args of
        [ value ] ->
            case name of
                "first" ->
                    JS.ExprAccess value (JsName.fromLocal "a")

                "second" ->
                    JS.ExprAccess value (JsName.fromLocal "b")

                _ ->
                    generateGlobalCall parentModule pos home name args

        _ ->
            generateGlobalCall parentModule pos home name args


{-| Generates `singleton` on one argument as an array literal and `unsafeGet` on
two as an index expression, and anything else as an ordinary call.
-}
generateJsArrayCall : ModuleName.Canonical -> A.Position -> ModuleName.Canonical -> Name.Name -> List JS.Expr -> JS.Expr
generateJsArrayCall parentModule pos home name args =
    case ( args, name ) of
        ( [ entry ], "singleton" ) ->
            JS.ExprArray [ entry ]

        ( [ index, array ], "unsafeGet" ) ->
            JS.ExprIndex array index

        _ ->
            generateGlobalCall parentModule pos home name args


{-| Generates a saturated `Bitwise` call as the JavaScript operator: `~` for
`complement`, `&`, `|` and `^`, and `<<`, `>>` and `>>>` for the shifts, whose
Elm arguments come in the opposite order (shift amount first). Anything else
is an ordinary call.
-}
generateBitwiseCall : ModuleName.Canonical -> A.Position -> ModuleName.Canonical -> Name.Name -> List JS.Expr -> JS.Expr
generateBitwiseCall parentModule pos home name args =
    case args of
        [ arg ] ->
            case name of
                "complement" ->
                    JS.ExprPrefix JS.PrefixComplement arg

                _ ->
                    generateGlobalCall parentModule pos home name args

        [ left, right ] ->
            case name of
                "and" ->
                    JS.ExprInfix JS.OpBitwiseAnd left right

                "or" ->
                    JS.ExprInfix JS.OpBitwiseOr left right

                "xor" ->
                    JS.ExprInfix JS.OpBitwiseXor left right

                "shiftLeftBy" ->
                    JS.ExprInfix JS.OpLShift right left

                "shiftRightBy" ->
                    JS.ExprInfix JS.OpSpRShift right left

                "shiftRightZfBy" ->
                    JS.ExprInfix JS.OpZfRShift right left

                _ ->
                    generateGlobalCall parentModule pos home name args

        _ ->
            generateGlobalCall parentModule pos home name args


{-| Generates a call of a `Basics` function, inline where one exists.

With one argument, `not` and `negate` become prefix operators, `toFloat` is the
argument itself, and `truncate` is `| 0`. With two, `++` goes to `append`, `<|`
and `|>` become a call of the function on the value, arithmetic and the
Boolean operators become JavaScript operators, `//` is a division followed by
`| 0`, `remainderBy` is `%` with its arguments swapped, and equality and
ordering go through `equal`, `notEqual` and `cmp`. `<<` and `>>` are not
inlined. Any other call, or another argument count, is an ordinary call.

-}
generateBasicsCall : Mode.Mode -> ModuleName.Canonical -> A.Position -> ModuleName.Canonical -> Name.Name -> List Opt.Expr -> JS.Expr
generateBasicsCall mode parentModule pos home name args =
    case args of
        [ elmArg ] ->
            let
                arg : JS.Expr
                arg =
                    generateJsExpr mode parentModule elmArg
            in
            case name of
                "not" ->
                    JS.ExprPrefix JS.PrefixNot arg

                "negate" ->
                    JS.ExprPrefix JS.PrefixNegate arg

                "toFloat" ->
                    arg

                "truncate" ->
                    JS.ExprInfix JS.OpBitwiseOr arg (JS.ExprInt 0)

                _ ->
                    generateGlobalCall parentModule pos home name [ arg ]

        [ elmLeft, elmRight ] ->
            case name of
                "append" ->
                    append mode parentModule elmLeft elmRight

                "apL" ->
                    apply elmLeft elmRight |> generateJsExpr mode parentModule

                "apR" ->
                    apply elmRight elmLeft |> generateJsExpr mode parentModule

                _ ->
                    let
                        left : JS.Expr
                        left =
                            generateJsExpr mode parentModule elmLeft

                        right : JS.Expr
                        right =
                            generateJsExpr mode parentModule elmRight
                    in
                    case name of
                        "add" ->
                            JS.ExprInfix JS.OpAdd left right

                        "sub" ->
                            JS.ExprInfix JS.OpSub left right

                        "mul" ->
                            JS.ExprInfix JS.OpMul left right

                        "fdiv" ->
                            JS.ExprInfix JS.OpDiv left right

                        "idiv" ->
                            JS.ExprInfix JS.OpBitwiseOr (JS.ExprInfix JS.OpDiv left right) (JS.ExprInt 0)

                        "eq" ->
                            equal left right

                        "neq" ->
                            notEqual left right

                        "lt" ->
                            cmp JS.OpLt JS.OpLt 0 left right

                        "gt" ->
                            cmp JS.OpGt JS.OpGt 0 left right

                        "le" ->
                            cmp JS.OpLe JS.OpLt 1 left right

                        "ge" ->
                            cmp JS.OpGe JS.OpGt -1 left right

                        -- Operator uses of `&&` and `||` reach here too: the
                        -- erased optimizer keeps them as calls of Basics.
                        "or" ->
                            JS.ExprInfix JS.OpOr left right

                        "and" ->
                            JS.ExprInfix JS.OpAnd left right

                        "xor" ->
                            JS.ExprInfix JS.OpNe left right

                        "remainderBy" ->
                            JS.ExprInfix JS.OpMod right left

                        _ ->
                            generateGlobalCall parentModule pos home name [ left, right ]

        _ ->
            List.map (generateJsExpr mode parentModule) args |> generateGlobalCall parentModule pos home name


{-| Generates `left == right`: a JavaScript comparison when either side is a
literal, and otherwise the structural `_Utils_eq`.
-}
equal : JS.Expr -> JS.Expr -> JS.Expr
equal left right =
    if isLiteral left || isLiteral right then
        strictEq left right

    else
        JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.utils "eq")) [ left, right ]


{-| Generates `left /= right`: a JavaScript comparison when either side is a
literal, and otherwise the negation of `_Utils_eq`.
-}
notEqual : JS.Expr -> JS.Expr -> JS.Expr
notEqual left right =
    if isLiteral left || isLiteral right then
        strictNEq left right

    else
        JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.utils "eq")) [ left, right ] |> JS.ExprPrefix JS.PrefixNot


{-| Generates an ordering comparison: `idealOp` directly when either side is a
literal, and otherwise `_Utils_cmp(left, right)`, which returns -1, 0 or 1,
compared with `backupInt` by `backupOp`.
-}
cmp : JS.InfixOp -> JS.InfixOp -> Int -> JS.Expr -> JS.Expr -> JS.Expr
cmp idealOp backupOp backupInt left right =
    if isLiteral left || isLiteral right then
        JS.ExprInfix idealOp left right

    else
        JS.ExprInfix backupOp
            (JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.utils "cmp")) [ left, right ])
            (JS.ExprInt backupInt)


{-| Returns `True` for a string, number or Bool literal, the values a JavaScript
comparison operator compares correctly.
-}
isLiteral : JS.Expr -> Bool
isLiteral expr =
    case expr of
        JS.ExprString _ ->
            True

        JS.ExprTrackedString _ _ _ ->
            True

        JS.ExprTrackedFloat _ _ _ ->
            True

        JS.ExprInt _ ->
            True

        JS.ExprTrackedInt _ _ _ ->
            True

        JS.ExprBool _ ->
            True

        JS.ExprTrackedBool _ _ _ ->
            True

        _ ->
            False


{-| Builds the Elm call of `func` on `value`, used for `<|` and `|>`. A record
accessor becomes a field access, and an existing call gets `value` appended to
its arguments.
-}
apply : Opt.Expr -> Opt.Expr -> Opt.Expr
apply func value =
    case func of
        Opt.Accessor region field ->
            Opt.Access value region field

        Opt.Call region f args ->
            Opt.Call region f (args ++ [ value ])

        _ ->
            Opt.Call (Maybe.withDefault A.zero (exprRegion func)) func [ value ]


{-| Returns the source region an expression carries, if its constructor has one.
-}
exprRegion : Opt.Expr -> Maybe A.Region
exprRegion expr =
    case expr of
        Opt.Bool region _ ->
            Just region

        Opt.Chr region _ ->
            Just region

        Opt.Str region _ ->
            Just region

        Opt.Int region _ ->
            Just region

        Opt.Float region _ ->
            Just region

        Opt.VarLocal _ ->
            Nothing

        Opt.TrackedVarLocal region _ ->
            Just region

        Opt.VarGlobal region _ ->
            Just region

        Opt.VarEnum region _ _ ->
            Just region

        Opt.VarBox region _ ->
            Just region

        Opt.VarCycle region _ _ ->
            Just region

        Opt.VarDebug region _ _ _ ->
            Just region

        Opt.VarKernel region _ _ _ ->
            Just region

        Opt.List region _ ->
            Just region

        Opt.Function _ _ ->
            Nothing

        Opt.TrackedFunction _ _ ->
            Nothing

        Opt.Call region _ _ ->
            Just region

        Opt.TailCall _ _ ->
            Nothing

        Opt.If _ _ ->
            Nothing

        Opt.Let _ _ ->
            Nothing

        Opt.Destruct _ _ ->
            Nothing

        Opt.Case _ _ _ _ ->
            Nothing

        Opt.Accessor region _ ->
            Just region

        Opt.Access _ region _ ->
            Just region

        Opt.Update region _ _ ->
            Just region

        Opt.Record _ ->
            Nothing

        Opt.TrackedRecord region _ ->
            Just region

        Opt.Unit ->
            Nothing

        Opt.Tuple region _ _ _ ->
            Just region

        Opt.Shader _ _ _ ->
            Nothing


{-| Generates `left ++ right`, flattening a chain of `Basics.append` on the
right. When any piece is a string literal the chain is joined with JavaScript
`+`; otherwise it is nested calls of `_Utils_ap`.
-}
append : Mode.Mode -> ModuleName.Canonical -> Opt.Expr -> Opt.Expr -> JS.Expr
append mode parentModule left right =
    let
        seqs : List JS.Expr
        seqs =
            generateJsExpr mode parentModule left :: toSeqs mode parentModule right
    in
    if List.any isStringLiteral seqs then
        Utils.foldr1 (JS.ExprInfix JS.OpAdd) seqs

    else
        Utils.foldr1 jsAppend seqs


{-| Generates a call of `_Utils_ap`, the runtime's `++` for strings and lists.
-}
jsAppend : JS.Expr -> JS.Expr -> JS.Expr
jsAppend a b =
    JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.utils "ap")) [ a, b ]


{-| Returns the generated operands of a right-nested chain of `Basics.append`
calls, in order; any other expression is one operand.
-}
toSeqs : Mode.Mode -> ModuleName.Canonical -> Opt.Expr -> List JS.Expr
toSeqs mode parentModule expr =
    case expr of
        Opt.Call _ (Opt.VarGlobal _ (Opt.Global home "append")) [ left, right ] ->
            if home == ModuleName.basics then
                generateJsExpr mode parentModule left :: toSeqs mode parentModule right

            else
                [ generateJsExpr mode parentModule expr ]

        _ ->
            [ generateJsExpr mode parentModule expr ]


{-| Returns `True` for a string literal.
-}
isStringLiteral : JS.Expr -> Bool
isStringLiteral expr =
    case expr of
        JS.ExprString _ ->
            True

        JS.ExprTrackedString _ _ _ ->
            True

        _ ->
            False



-- ====== SIMPLIFY INFIX OPERATORS ======


{-| Generates `===`, simplified when one side is `0`, `true` or `false`: a
comparison with `0` or `false` becomes `!` of the other side, and with `true`
the other side itself. The left side is checked first.
-}
strictEq : JS.Expr -> JS.Expr -> JS.Expr
strictEq left right =
    case left of
        JS.ExprInt 0 ->
            JS.ExprPrefix JS.PrefixNot right

        JS.ExprTrackedInt _ _ 0 ->
            JS.ExprPrefix JS.PrefixNot right

        JS.ExprBool bool ->
            if bool then
                right

            else
                JS.ExprPrefix JS.PrefixNot right

        JS.ExprTrackedBool _ _ bool ->
            if bool then
                right

            else
                JS.ExprPrefix JS.PrefixNot right

        _ ->
            case right of
                JS.ExprInt 0 ->
                    JS.ExprPrefix JS.PrefixNot left

                JS.ExprTrackedInt _ _ 0 ->
                    JS.ExprPrefix JS.PrefixNot left

                JS.ExprBool bool ->
                    if bool then
                        left

                    else
                        JS.ExprPrefix JS.PrefixNot left

                JS.ExprTrackedBool _ _ bool ->
                    if bool then
                        left

                    else
                        JS.ExprPrefix JS.PrefixNot left

                _ ->
                    JS.ExprInfix JS.OpEq left right


{-| Generates `!==`, simplified as `strictEq` is: a comparison with `0` becomes
`!!` of the other side, with `true` its negation, and with `false` the other
side itself.
-}
strictNEq : JS.Expr -> JS.Expr -> JS.Expr
strictNEq left right =
    case left of
        JS.ExprInt 0 ->
            JS.ExprPrefix JS.PrefixNot (JS.ExprPrefix JS.PrefixNot right)

        JS.ExprTrackedInt _ _ 0 ->
            JS.ExprPrefix JS.PrefixNot (JS.ExprPrefix JS.PrefixNot right)

        JS.ExprBool bool ->
            if bool then
                JS.ExprPrefix JS.PrefixNot right

            else
                right

        JS.ExprTrackedBool _ _ bool ->
            if bool then
                JS.ExprPrefix JS.PrefixNot right

            else
                right

        _ ->
            case right of
                JS.ExprInt 0 ->
                    JS.ExprPrefix JS.PrefixNot (JS.ExprPrefix JS.PrefixNot left)

                JS.ExprTrackedInt _ _ 0 ->
                    JS.ExprPrefix JS.PrefixNot (JS.ExprPrefix JS.PrefixNot left)

                JS.ExprBool bool ->
                    if bool then
                        JS.ExprPrefix JS.PrefixNot left

                    else
                        left

                JS.ExprTrackedBool _ _ bool ->
                    if bool then
                        JS.ExprPrefix JS.PrefixNot left

                    else
                        left

                _ ->
                    JS.ExprInfix JS.OpNe left right



-- ====== TAIL CALL ======


{-| Generates a self tail call of the function `name`: every new argument is
computed into a `$temp$` variable first, then copied into the parameter, and
the loop labelled `name` is continued. The temporaries keep an argument from
seeing a parameter already overwritten.
-}
generateTailCall : Mode.Mode -> ModuleName.Canonical -> Name.Name -> List ( Name.Name, Opt.Expr ) -> List JS.Stmt
generateTailCall mode parentModule name args =
    let
        toTempVars : ( String, Opt.Expr ) -> ( JsName.Name, JS.Expr )
        toTempVars ( argName, arg ) =
            ( JsName.makeTemp argName, generateJsExpr mode parentModule arg )

        toRealVars : ( Name.Name, b ) -> JS.Stmt
        toRealVars ( argName, _ ) =
            JS.ExprAssign (JS.LRef (JsName.fromLocal argName)) (JS.ExprRef (JsName.makeTemp argName)) |> JS.ExprStmt
    in
    JS.Vars (List.map toTempVars args)
        :: List.map toRealVars args
        ++ [ JS.Continue (Just (JsName.fromLocal name)) ]



-- ====== DEFINITIONS ======


{-| Generates a `let` definition as a `var` statement.
-}
generateDef : Mode.Mode -> ModuleName.Canonical -> Opt.Def -> JS.Stmt
generateDef mode parentModule def =
    case def of
        Opt.Def (A.Region start _) name body ->
            JS.TrackedVar parentModule start (JsName.fromLocal name) (JsName.fromLocal name) (generateJsExpr mode parentModule body)

        Opt.TailDef (A.Region start _) name argNames body ->
            JS.TrackedVar parentModule start (JsName.fromLocal name) (JsName.fromLocal name) (codeToExpr (generateTailDef mode parentModule name argNames body))


{-| Generates the tail-recursive function `name` of `argNames`: its body runs in
a `while (true)` loop labelled `name`, which each tail call in the body
`continue`s.
-}
generateTailDef : Mode.Mode -> ModuleName.Canonical -> Name.Name -> List (A.Located Name.Name) -> Opt.Expr -> Code
generateTailDef mode parentModule name argNames body =
    generateTrackedFunction parentModule (List.map (\(A.At region argName) -> A.At region (JsName.fromLocal argName)) argNames) <|
        JsBlock
            [ generate mode parentModule body |> codeToStmt |> JS.While (JS.ExprBool True) |> JS.Labelled (JsName.fromLocal name)
            ]



-- ====== PATHS ======


{-| Generates the expression that reaches the value a destructuring path names.
`Unbox` steps through a box: property `a` in development, nothing in
production.
-}
generatePath : Mode.Mode -> Opt.Path -> JS.Expr
generatePath mode path =
    case path of
        Opt.Index index subPath ->
            JS.ExprAccess (generatePath mode subPath) (JsName.fromIndex index)

        Opt.ArrayIndex index subPath ->
            JS.ExprIndex (generatePath mode subPath) (JS.ExprInt index)

        Opt.Root name ->
            JS.ExprRef (JsName.fromLocal name)

        Opt.Field field subPath ->
            JS.ExprAccess (generatePath mode subPath) (generateField mode field)

        Opt.Unbox subPath ->
            case mode of
                Mode.Dev _ ->
                    JS.ExprAccess (generatePath mode subPath) (JsName.fromIndex Index.first)

                Mode.Prod _ ->
                    generatePath mode subPath



-- ====== GENERATE IFS ======


{-| Generates an `if` chain, first merging nested `else if` chains with
`crushIfs`. The result is a conditional expression when every branch is an
expression, and an `if` statement otherwise.
-}
generateIf : Mode.Mode -> ModuleName.Canonical -> List ( Opt.Expr, Opt.Expr ) -> Opt.Expr -> Code
generateIf mode parentModule givenBranches givenFinal =
    let
        ( branches, final ) =
            crushIfs givenBranches givenFinal

        convertBranch : ( Opt.Expr, Opt.Expr ) -> ( JS.Expr, Code )
        convertBranch ( condition, expr ) =
            ( generateJsExpr mode parentModule condition
            , generate mode parentModule expr
            )

        branchExprs : List ( JS.Expr, Code )
        branchExprs =
            List.map convertBranch branches

        finalCode : Code
        finalCode =
            generate mode parentModule final
    in
    if isBlock finalCode || List.any (Tuple.second >> isBlock) branchExprs then
        JsBlock [ List.foldr addStmtIf (codeToStmt finalCode) branchExprs ]

    else
        JsExpr (List.foldr addExprIf (codeToExpr finalCode) branchExprs)


{-| Puts one branch in front of `final` as a conditional expression.
-}
addExprIf : ( JS.Expr, Code ) -> JS.Expr -> JS.Expr
addExprIf ( condition, branch ) final =
    JS.ExprIf condition (codeToExpr branch) final


{-| Puts one branch in front of `final` as an `if` statement.
-}
addStmtIf : ( JS.Expr, Code ) -> JS.Stmt -> JS.Stmt
addStmtIf ( condition, branch ) final =
    JS.IfStmt condition (codeToStmt branch) final


{-| Returns `True` when the code is a statement block.
-}
isBlock : Code -> Bool
isBlock code =
    case code of
        JsBlock _ ->
            True

        JsExpr _ ->
            False


{-| Flattens an `if` whose final `else` is itself an `if` into one list of
branches, repeatedly, so an `else if` chain becomes one chain.
-}
crushIfs : List ( Opt.Expr, Opt.Expr ) -> Opt.Expr -> ( List ( Opt.Expr, Opt.Expr ), Opt.Expr )
crushIfs branches final =
    crushIfsHelp [] branches final


{-| Does the work of `crushIfs`; `visitedBranches` holds the branches seen so
far, newest first.
-}
crushIfsHelp :
    List ( Opt.Expr, Opt.Expr )
    -> List ( Opt.Expr, Opt.Expr )
    -> Opt.Expr
    -> ( List ( Opt.Expr, Opt.Expr ), Opt.Expr )
crushIfsHelp visitedBranches unvisitedBranches final =
    case unvisitedBranches of
        [] ->
            case final of
                Opt.If subBranches subFinal ->
                    crushIfsHelp visitedBranches subBranches subFinal

                _ ->
                    ( List.reverse visitedBranches, final )

        visiting :: unvisited ->
            crushIfsHelp (visiting :: visitedBranches) unvisited final



-- ====== CASE EXPRESSIONS ======


{-| Generates a `case` on the variable `root`.

Each shared branch in `jumps` is placed after a `while (true)` block labelled
`label$index`, and these blocks are nested around the decision tree. A leaf of
the tree that jumps to a shared branch `break`s out of its block, which falls
through to that branch's code.

-}
generateCase : Mode.Mode -> ModuleName.Canonical -> Name.Name -> Name.Name -> Opt.Decider Opt.Choice -> List ( Int, Opt.Expr ) -> List JS.Stmt
generateCase mode parentModule label root decider jumps =
    List.foldr (goto mode parentModule label) (generateDecider mode parentModule label root decider) jumps


{-| Wraps `stmts` in the labelled block for the shared branch `index` and puts
that branch's code after it.
-}
goto : Mode.Mode -> ModuleName.Canonical -> Name.Name -> ( Int, Opt.Expr ) -> List JS.Stmt -> List JS.Stmt
goto mode parentModule label ( index, branch ) stmts =
    let
        labeledDeciderStmt : JS.Stmt
        labeledDeciderStmt =
            JS.Labelled
                (JsName.makeLabel label index)
                (JS.While (JS.ExprBool True) (JS.Block stmts))
    in
    labeledDeciderStmt :: codeToStmtList (generate mode parentModule branch)


{-| Generates a decision tree. A leaf is either its branch inline or a `break` to
a shared branch; a chain of tests is an `if`; a fan-out is a `switch` on the
value tested by its first edge, with the fallback as `default`.
-}
generateDecider : Mode.Mode -> ModuleName.Canonical -> Name.Name -> Name.Name -> Opt.Decider Opt.Choice -> List JS.Stmt
generateDecider mode parentModule label root decisionTree =
    case decisionTree of
        Opt.Leaf (Opt.Inline branch) ->
            codeToStmtList (generate mode parentModule branch)

        Opt.Leaf (Opt.Jump index) ->
            [ JS.Break (Just (JsName.makeLabel label index)) ]

        Opt.Chain testChain success failure ->
            [ JS.IfStmt
                (Utils.foldl1_ (JS.ExprInfix JS.OpAnd) (List.map (generateIfTest mode root) testChain))
                (JS.Block (generateDecider mode parentModule label root success))
                (JS.Block (generateDecider mode parentModule label root failure))
            ]

        Opt.FanOut path edges fallback ->
            [ JS.Switch
                (generateCaseTest mode root path (Tuple.first (Prelude.head edges)))
                (List.foldr
                    (\edge cases -> generateCaseBranch mode parentModule label root edge :: cases)
                    [ JS.Default (generateDecider mode parentModule label root fallback) ]
                    edges
                )
            ]


{-| Generates one test of a test chain as a Boolean expression on the value at
`path`.

A constructor test compares the tag: the `$` property in development, and in
production the `$` property for an ordinary type or the value itself for an
enumeration or a box. A `Char` in development is compared through `valueOf()`.
A list is non-empty exactly when it has a `b` property. Crashes on a tuple
test, which the decision tree never makes.

-}
generateIfTest : Mode.Mode -> Name.Name -> ( DT.Path, DT.Test ) -> JS.Expr
generateIfTest mode root ( path, test ) =
    let
        value : JS.Expr
        value =
            pathToJsExpr mode root path
    in
    case test of
        Test.IsCtor home name index _ opts ->
            let
                tag : JS.Expr
                tag =
                    case mode of
                        Mode.Dev _ ->
                            JS.ExprAccess value JsName.dollar

                        Mode.Prod _ ->
                            case opts of
                                Can.Normal ->
                                    JS.ExprAccess value JsName.dollar

                                Can.Enum ->
                                    value

                                Can.Unbox ->
                                    value
            in
            strictEq tag
                (case mode of
                    Mode.Dev _ ->
                        JS.ExprString name

                    Mode.Prod _ ->
                        JS.ExprInt (ctorToInt home name index)
                )

        Test.IsBool True ->
            value

        Test.IsBool False ->
            JS.ExprPrefix JS.PrefixNot value

        Test.IsInt int ->
            strictEq value (JS.ExprInt int)

        Test.IsChr char ->
            strictEq (JS.ExprString char)
                (case mode of
                    Mode.Dev _ ->
                        JS.ExprCall (JS.ExprAccess value (JsName.fromLocal "valueOf")) []

                    Mode.Prod _ ->
                        value
                )

        Test.IsStr string ->
            strictEq value (JS.ExprString string)

        Test.IsCons ->
            JS.ExprAccess value (JsName.fromLocal "b")

        Test.IsNil ->
            JS.ExprAccess value (JsName.fromLocal "b") |> JS.ExprPrefix JS.PrefixNot

        Test.IsTuple ->
            crash "COMPILER BUG - there should never be tests on a tuple"


{-| Generates one `case` of a `switch` for a fan-out edge.
-}
generateCaseBranch : Mode.Mode -> ModuleName.Canonical -> Name.Name -> Name.Name -> ( DT.Test, Opt.Decider Opt.Choice ) -> JS.Case
generateCaseBranch mode parentModule label root ( test, subTree ) =
    JS.Case
        (generateCaseValue mode test)
        (generateDecider mode parentModule label root subTree)


{-| Generates the value a `switch` case matches for a test. Crashes for Bool,
list and tuple tests, which never appear in a fan-out.
-}
generateCaseValue : Mode.Mode -> DT.Test -> JS.Expr
generateCaseValue mode test =
    case test of
        Test.IsCtor home name index _ _ ->
            case mode of
                Mode.Dev _ ->
                    JS.ExprString name

                Mode.Prod _ ->
                    JS.ExprInt (ctorToInt home name index)

        Test.IsInt int ->
            JS.ExprInt int

        Test.IsChr char ->
            JS.ExprString char

        Test.IsStr string ->
            JS.ExprString string

        Test.IsBool _ ->
            crash "COMPILER BUG - there should never be three tests on a boolean"

        Test.IsCons ->
            crash "COMPILER BUG - there should never be three tests on a list"

        Test.IsNil ->
            crash "COMPILER BUG - there should never be three tests on a list"

        Test.IsTuple ->
            crash "COMPILER BUG - there should never be three tests on a tuple"


{-| Generates the value a `switch` examines, given one of its edge tests: the
constructor tag (as in `generateIfTest`), the value itself for an `Int` or
`String`, or the `Char`'s `valueOf()` in development. Crashes for Bool, list
and tuple tests.
-}
generateCaseTest : Mode.Mode -> Name.Name -> DT.Path -> DT.Test -> JS.Expr
generateCaseTest mode root path exampleTest =
    let
        value : JS.Expr
        value =
            pathToJsExpr mode root path
    in
    case exampleTest of
        Test.IsCtor home name _ _ opts ->
            if name == Name.bool && home == ModuleName.basics then
                value

            else
                case mode of
                    Mode.Dev _ ->
                        JS.ExprAccess value JsName.dollar

                    Mode.Prod _ ->
                        case opts of
                            Can.Normal ->
                                JS.ExprAccess value JsName.dollar

                            Can.Enum ->
                                value

                            Can.Unbox ->
                                value

        Test.IsInt _ ->
            value

        Test.IsStr _ ->
            value

        Test.IsChr _ ->
            case mode of
                Mode.Dev _ ->
                    JS.ExprCall (JS.ExprAccess value (JsName.fromLocal "valueOf")) []

                Mode.Prod _ ->
                    value

        Test.IsBool _ ->
            crash "COMPILER BUG - there should never be three tests on a list"

        Test.IsCons ->
            crash "COMPILER BUG - there should never be three tests on a list"

        Test.IsNil ->
            crash "COMPILER BUG - there should never be three tests on a list"

        Test.IsTuple ->
            crash "COMPILER BUG - there should never be three tests on a list"



-- ====== PATTERN PATHS ======


{-| Generates the expression that reaches the value at a decision-tree `path`,
starting from the variable `root`. `Unbox` steps through a box: property `a` in
development, nothing in production.
-}
pathToJsExpr : Mode.Mode -> Name.Name -> DT.Path -> JS.Expr
pathToJsExpr mode root path =
    case path of
        Path.Index index subPath ->
            JS.ExprAccess (pathToJsExpr mode root subPath) (JsName.fromIndex index)

        Path.Unbox subPath ->
            case mode of
                Mode.Dev _ ->
                    JS.ExprAccess (pathToJsExpr mode root subPath) (JsName.fromIndex Index.first)

                Mode.Prod _ ->
                    pathToJsExpr mode root subPath

        Path.Empty ->
            JS.ExprRef (JsName.fromLocal root)



-- ====== GENERATE MAIN ======


{-| Generates the initialization of `main` in module `home`.

A `Static` main (a plain view) is passed to `_VirtualDom_init` with the
arguments `0` and `0`. A `Dynamic` main (a program) is called with the flags
decoder and then the debugger metadata, which is a JSON description of the
message type in a debug build and `0` otherwise.

-}
generateMain : Mode.Mode -> ModuleName.Canonical -> Opt.Main -> JS.Expr
generateMain mode home main =
    case main of
        Opt.Static ->
            JS.ExprRef (JsName.fromKernel Name.virtualDom "init")
                |> call (JS.ExprRef (JsName.fromGlobal home "main"))
                |> call (JS.ExprInt 0)
                |> call (JS.ExprInt 0)

        Opt.Dynamic msgType decoder ->
            JS.ExprRef (JsName.fromGlobal home "main")
                |> call (generateJsExpr mode home decoder)
                |> call (toDebugMetadata mode msgType)


{-| Generates a call of `func` on one argument, with the argument first for
use in pipelines.
-}
call : JS.Expr -> JS.Expr -> JS.Expr
call arg func =
    JS.ExprCall func [ arg ]


{-| Generates the debugger metadata passed to `main`: a JSON object of the
compiler version and the types reachable from the message type in a debug
build, and `0` otherwise.
-}
toDebugMetadata : Mode.Mode -> Can.Type Name -> JS.Expr
toDebugMetadata mode msgType =
    case mode of
        Mode.Prod _ ->
            JS.ExprInt 0

        Mode.Dev Nothing ->
            JS.ExprInt 0

        Mode.Dev (Just interfaces) ->
            JS.ExprJson
                (Encode.object
                    [ ( "versions", Encode.object [ ( "elm", V.encode V.elmCompiler ) ] )
                    , ( "types", Type.encodeMetadata (Extract.fromMsg interfaces msgType) )
                    ]
                )
