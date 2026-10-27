module Compiler.Generate.JavaScript exposing (generate, generateForRepl, generateForReplEndpoint)

{-| Turns an optimized program into one JavaScript text, either a whole program
or a snippet that the REPL runs to show one value.

The input is the _global graph_ of `Compiler.AST.Optimized`: every top-level
definition of the program and its packages, each a node keyed by its global
(module and name) and listing the globals it uses. Most of the graph is not
needed. Generation starts from the entry points, a module's `main` for a program
and the evaluated value for the REPL, and walks the graph depth first. Each node
is added to the state once, after the nodes it depends on; kernel text and the
members of a cycle are the exceptions. A `State` records the text so far and
the globals already visited. Dependencies are visited in
`Opt.compareGlobal` order, which makes the output the same on every run.

A node becomes a `var`, a constructor, a group of mutually recursive
definitions, an effect manager registration, a port, or the text of a _kernel
module_, which is hand-written JavaScript from a package, split into chunks by
`Compiler.Elm.Kernel`. Kernel text is collected apart from the rest and placed
before all other generated code.

`generate` wraps the program in a function that is called at once with
`this`, after the `F`/`A` helpers of `Compiler.Generate.JavaScript.Functions`.
The program's `main`s are exported as a nested object following the dots of
their module names, so the `main` of `Page.Home` is the `init` field of the
`Home` field of the `Page` field. The _trie_ at the end of this file is that
nesting, one level per module-name segment.

The mode decides how much is kept for development. In production, a type
whose constructors all take no arguments has them as integers, a type with a
single one-argument constructor has it as `identity`, and cycles of values are
not guarded. In development a cycle of values that loops throws an error that
draws the cycle.


# Code Generation

@docs generate, generateForRepl, generateForReplEndpoint

-}

import Basics.Extra exposing (flip)
import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Kernel as K
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.JavaScript.Builder as JS
import Compiler.Generate.JavaScript.Expression as Expr
import Compiler.Generate.JavaScript.Functions as Functions
import Compiler.Generate.JavaScript.Name as JsName
import Compiler.Generate.JavaScript.SourceMap as SourceMap
import Compiler.Generate.Mode as Mode
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Type as RT
import Compiler.Reporting.Render.Type.Localizer as L
import Data.Map as DataMap
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import Json.Encode as Encode
import Maybe.Extra as Maybe
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== Main Code Generation ======


{-| The nodes of the global graph, keyed by the global each defines.
-}
type alias Graph =
    DataMap.Dict String Opt.Global Opt.Node


{-| Returns the number of lines in the prelude for `mode`, the line on which the
builder's generated code is counted as starting.
-}
firstGeneratedLineNumber : Mode.Mode -> Int
firstGeneratedLineNumber mode =
    List.length (String.lines (prelude mode))


{-| Returns the opening of a program: the start of the wrapping function, the
runtime helpers, and the development-mode warning.
-}
prelude : Mode.Mode -> String
prelude mode =
    "(function(scope){\n'use strict';"
        ++ Functions.functions
        ++ perfNote mode


{-| Generates the JavaScript program that runs `mains`, from `graph`.

The text is one function called at once with `this`. Inside it are
the runtime helpers, a console warning unless `mode` is production, the kernel
code, a few definitions that let ports carry `Bytes`, every global reachable
from a `main` in dependency order, the export of the `main`s, and a few
definitions for tuples of more than three elements in `Debug.toString`.

With source maps the text ends with a source map comment. `leadingLines` is
the number of lines that will come before this text in the file it is written
to, and is added to every mapped line.

-}
generate : CodeGen.SourceMaps -> Int -> Mode.Mode -> Opt.GlobalGraph -> CodeGen.Mains -> String
generate sourceMaps leadingLines mode (Opt.GlobalGraph graph _) mains =
    let
        state : State
        state =
            DataMap.foldr (addMain mode graph) (emptyState (firstGeneratedLineNumber mode)) mains
    in
    prelude mode
        ++ stateToBuilder state
        ++ toMainExports mode mains
        ++ escapeNewCode """// EXTRA GUIDA CORE

function _Utils_TupleN(a, b, ...cs) {
  return { $: '#N', a: a, b: b, cs: cs };
}

(function(original) {
    _Debug_toAnsiString = function(ansi, value) {
        if (value.$ === '#N') {
            var output = [_Debug_toAnsiString(ansi, value.a), _Debug_toAnsiString(ansi, value.b)];
            for (var k in value.cs) {
                output.push(_Debug_toAnsiString(ansi, value.cs[k]));
            }
            return '(' + output.join(',') + ')';
        }
        return original(ansi, value);
    }
}(_Debug_toAnsiString))"""
        ++ "}(this));"
        ++ generateSourceMaps sourceMaps leadingLines state


{-| Returns `code` on lines of its own between a `//__START__` and an
`//__END__` comment line.
-}
escapeNewCode : String -> String
escapeNewCode code =
    "//__START__\n" ++ code ++ "\n//__END__\n"


{-| Returns the source map comment for the code in `state`, or the empty string
without source maps.

The builder counts lines from the end of the prelude, so the lines of the kernel
code, which goes in before the builder's text, are added here.

-}
generateSourceMaps : CodeGen.SourceMaps -> Int -> State -> String
generateSourceMaps sourceMaps leadingLines state =
    case sourceMaps of
        CodeGen.NoSourceMaps ->
            ""

        CodeGen.SourceMaps moduleSources ->
            let
                kernelLeadingLines : Int
                kernelLeadingLines =
                    stateKernels state
                        |> List.map (String.length << String.filter ((==) '\n'))
                        |> List.sum
            in
            SourceMap.generate leadingLines kernelLeadingLines moduleSources (stateToMappings state)


{-| Adds the `main` of `home`, and everything it depends on, to `state`.
-}
addMain : Mode.Mode -> Graph -> ModuleName.Canonical -> Opt.Main -> State -> State
addMain mode graph home _ state =
    addGlobal mode graph state (Opt.Global home "main")


{-| Returns a statement that warns on the console that the program was compiled
in development or debug mode, or the empty string in production.
-}
perfNote : Mode.Mode -> String
perfNote mode =
    case mode of
        Mode.Prod _ ->
            ""

        Mode.Dev Nothing ->
            "console.warn('Compiled in DEV mode. Follow the advice at "
                ++ D.makeNakedLink "optimize"
                ++ " for better performance and smaller assets.');"

        Mode.Dev (Just _) ->
            "console.warn('Compiled in DEBUG mode. Follow the advice at "
                ++ D.makeNakedLink "optimize"
                ++ " for better performance and smaller assets.');"


{-| Generates a script that prints the value `name` of `home` and its type to
the console, with ANSI colours when `ansi` is set.

The code is generated in development mode, with `Debug.toString` and everything
the value depends on. An uncaught exception is written to standard error and
ends the process with status 1. The type goes on its own line when it holds a
newline or the whole would reach 80 characters.

-}
generateForRepl : Bool -> L.Localizer -> Opt.GlobalGraph -> ModuleName.Canonical -> Name.Name -> Can.Annotation Name -> String
generateForRepl ansi localizer (Opt.GlobalGraph graph _) home name (Can.Forall _ tipe) =
    let
        mode : Mode.Mode
        mode =
            Mode.Dev Nothing

        debugState : State
        debugState =
            addGlobal mode graph (emptyState 0) (Opt.Global ModuleName.debug "toString")

        evalState : State
        evalState =
            addGlobal mode graph debugState (Opt.Global home name)
    in
    "process.on('uncaughtException', function(err) { process.stderr.write(err.toString() + '\\n'); process.exit(1); });"
        ++ Functions.functions
        ++ stateToBuilder evalState
        ++ print ansi localizer home name tipe


{-| Returns the code that prints the value `name` of `home` followed by `tipe`,
as `generateForRepl` describes.
-}
print : Bool -> L.Localizer -> ModuleName.Canonical -> Name.Name -> Can.Type Name -> String
print ansi localizer home name tipe =
    let
        value : JsName.Name
        value =
            JsName.fromGlobal home name

        toString : JsName.Name
        toString =
            JsName.fromKernel Name.debug "toAnsiString"

        tipeDoc : D.Doc
        tipeDoc =
            RT.canToDoc localizer RT.None tipe

        bool : String
        bool =
            if ansi then
                "true"

            else
                "false"
    in
    "var _value = "
        ++ toString
        ++ "("
        ++ bool
        ++ ", "
        ++ value
        ++ ");\nvar _type = "
        ++ Encode.encode 0 (Encode.string (D.toString tipeDoc))
        ++ ";\nfunction _print(t) { console.log(_value + ("
        ++ bool
        ++ " ? '\\x1b[90m' + t + '\\x1b[0m' : t)); }\\n"
        ++ "if (_value.length + 3 + _type.length >= 80 || _type.indexOf('\\n') >= 0) {\\n"
        ++ "    _print('\\n    : ' + _type.split('\\n').join('\\n      '));\\n"
        ++ "} else {\\n"
        ++ "    _print(' : ' + _type);\\n"
        ++ "}\\n"



-- ====== REPL Endpoint Generation ======


{-| Generates a script that sends the REPL's value and its type with
`self.postMessage`, as a web worker does.

The value is `maybeName` of `home`, or `Name.replValueToPrint` when there is no
name. The message has the fields `name` (the name, or `null` without one),
`value` (the value as `Debug.toString` shows it, with ANSI colours) and `type`.
The code is generated in development mode.

-}
generateForReplEndpoint : L.Localizer -> Opt.GlobalGraph -> ModuleName.Canonical -> Maybe Name.Name -> Can.Annotation Name -> String
generateForReplEndpoint localizer (Opt.GlobalGraph graph _) home maybeName (Can.Forall _ tipe) =
    let
        name : Name.Name
        name =
            Maybe.unwrap Name.replValueToPrint identity maybeName

        mode : Mode.Mode
        mode =
            Mode.Dev Nothing

        debugState : State
        debugState =
            addGlobal mode graph (emptyState 0) (Opt.Global ModuleName.debug "toString")

        evalState : State
        evalState =
            addGlobal mode graph debugState (Opt.Global home name)
    in
    Functions.functions
        ++ stateToBuilder evalState
        ++ postMessage localizer home maybeName tipe


{-| Returns the `self.postMessage` call that `generateForReplEndpoint`
describes.

The name is put between double quotes with no escaping, and the rendered type
is inserted as it is, not as a string literal.

-}
postMessage : L.Localizer -> ModuleName.Canonical -> Maybe Name.Name -> Can.Type Name -> String
postMessage localizer home maybeName tipe =
    let
        name : Name.Name
        name =
            Maybe.unwrap Name.replValueToPrint identity maybeName

        value : JsName.Name
        value =
            JsName.fromGlobal home name

        toString : JsName.Name
        toString =
            JsName.fromKernel Name.debug "toAnsiString"

        tipeDoc : D.Doc
        tipeDoc =
            RT.canToDoc localizer RT.None tipe

        toName : String -> String
        toName n =
            "\"" ++ n ++ "\""
    in
    "self.postMessage({\n  name: "
        ++ Maybe.unwrap "null" toName maybeName
        ++ ",\n  value: "
        ++ toString
        ++ "(true, "
        ++ value
        ++ "),\n  type: "
        ++ D.toString tipeDoc
        ++ "\n});\n"


{-| Generation in progress: the JavaScript built so far, and the globals already
visited, so that each is emitted once.
-}
type State
    = State JS.Builder (EverySet String Opt.Global)


{-| Creates a state with no code and nothing visited, whose code is counted from
line `startingLine`.
-}
emptyState : Int -> State
emptyState startingLine =
    State (JS.emptyBuilder startingLine) EverySet.empty


{-| Returns the code in the state: the kernel code in the order it was added,
then `bytesForPorts`, then the rest of the generated code.
-}
stateToBuilder : State -> String
stateToBuilder (State (JS.Builder b) _) =
    prependBuilders b.revKernels (bytesForPorts ++ b.revBuilders)


{-| The JavaScript definitions of `_Json_decodeBytes` and `_Json_encodeBytes`.
The decoder accepts a `Uint8Array`, an `ArrayBuffer` or a `DataView` and gives a
`DataView`; the encoder gives a `Uint8Array` over the same bytes.
-}
bytesForPorts : String
bytesForPorts =
    """
// BYTES FOR PORTS
var _Json_decodeBytes = _Json_decodePrim(function(value) {
    if (value instanceof Uint8Array) {
        return $elm$core$Result$Ok(new DataView(value.buffer, value.byteOffset, value.byteLength));
    }
    if (value instanceof ArrayBuffer) {
        return $elm$core$Result$Ok(new DataView(value));
    }
    if (value instanceof DataView) {
        return $elm$core$Result$Ok(value);
    }
    return _Json_expecting('a BYTES value (Uint8Array, ArrayBuffer, or DataView)', value);
});

var _Json_encodeBytes = function(bytes) {
    return _Json_wrap(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength));
};
"""


{-| Returns `monolith` with the pieces of `revBuilders`, which are newest first,
put before it oldest first.
-}
prependBuilders : List String -> String -> String
prependBuilders revBuilders monolith =
    List.foldl (\b m -> b ++ m) monolith revBuilders


{-| Returns the source map mappings recorded in the state, newest first.
-}
stateToMappings : State -> List JS.Mapping
stateToMappings (State (JS.Builder b) _) =
    b.mappings


{-| Returns the kernel code in the state, newest first.
-}
stateKernels : State -> List String
stateKernels (State (JS.Builder b) _) =
    b.revKernels


{-| Adds `global` and everything it depends on to the state, unless it has
already been visited.
-}
addGlobal : Mode.Mode -> Graph -> State -> Opt.Global -> State
addGlobal mode graph ((State builder seen) as state) global =
    if EverySet.member Opt.toComparableGlobal global seen then
        state

    else
        State builder (EverySet.insert Opt.toComparableGlobal global seen) |> addGlobalHelp mode graph global


{-| Adds the code for the node of `global`, after its dependencies.

A `Link` adds the global it links to instead. A debugger kernel is skipped
unless `mode` is debug. A kernel's dependencies are resolved as
`resolveKernelGlobal` describes. The global is looked up with `Utils.find`, so
one missing from the graph crashes.

-}
addGlobalHelp : Mode.Mode -> Graph -> Opt.Global -> State -> State
addGlobalHelp mode graph ((Opt.Global home _) as global) state =
    let
        addDeps : EverySet String Opt.Global -> State -> State
        addDeps deps someState =
            let
                sortedDeps : List Opt.Global
                sortedDeps =
                    -- Sorted so that the output order does not depend on the set's own order.
                    List.sortWith Opt.compareGlobal (EverySet.toList deps)
            in
            List.foldl (flip (addGlobal mode graph)) someState sortedDeps
    in
    case Utils.find Opt.toComparableGlobal global graph of
        Opt.Define expr deps ->
            addStmt (addDeps deps state)
                (var global (Expr.generate mode home expr))

        Opt.TrackedDefine region expr deps ->
            addStmt (addDeps deps state)
                (trackedVar region global (Expr.generate mode home expr))

        Opt.Ctor index arity ->
            addStmt state
                (var global (Expr.generateCtor mode global index arity))

        Opt.Link linkedGlobal ->
            addGlobal mode graph state linkedGlobal

        Opt.Cycle names values functions deps ->
            addStmt (addDeps deps state)
                (generateCycle mode global names values functions)

        Opt.Manager effectsType ->
            generateManager mode graph global effectsType state

        Opt.Kernel chunks deps ->
            if isDebugger global && not (Mode.isDebug mode) then
                state

            else
                addKernel (addDeps (resolveKernelDeps graph deps) state) (generateKernel mode graph global chunks)

        Opt.Enum index ->
            addStmt state
                (generateEnum mode global index)

        Opt.Box ->
            addStmt (addGlobal mode graph state identity_)
                (generateBox mode global)

        Opt.PortIncoming decoder deps ->
            addStmt (addDeps deps state)
                (generatePort mode global "incomingPort" decoder)

        Opt.PortOutgoing encoder deps ->
            addStmt (addDeps deps state)
                (generatePort mode global "outgoingPort" encoder)


{-| Appends `stmt` to the code in the state.
-}
addStmt : State -> JS.Stmt -> State
addStmt (State builder seen) stmt =
    State (JS.stmtToBuilder stmt builder) seen


{-| Adds `kernel` to the state's kernel code.
-}
addKernel : State -> String -> State
addKernel (State builder seen) kernel =
    State (JS.addKernel kernel builder) seen


{-| Returns the `var` statement defining the global as `code`.
-}
var : Opt.Global -> Expr.Code -> JS.Stmt
var (Opt.Global home name) code =
    JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr code)


{-| Returns the `var` statement defining the global as `code`, recording a
source map mapping from the start of `region`.
-}
trackedVar : A.Region -> Opt.Global -> Expr.Code -> JS.Stmt
trackedVar (A.Region startPos _) (Opt.Global home name) code =
    JS.TrackedVar home startPos (JsName.fromGlobalHumanReadable home name) (JsName.fromGlobal home name) (Expr.codeToExpr code)


{-| Tells whether `global` belongs to a module named `Name.debugger`. For a
kernel node this is the kernel module `Elm.Kernel.Debugger`.
-}
isDebugger : Opt.Global -> Bool
isDebugger (Opt.Global (ModuleName.Canonical _ home) _) =
    home == Name.debugger



-- ====== Mutually Recursive Definitions ======


{-| Returns the statements for a cycle: a group of definitions in one module
that refer to each other.

The `functions` are defined first, as ordinary `var`s; a function body does not
run when it is defined, so their order does not matter. Each of the `values` is
then defined as a function of no arguments that computes it, and called in turn.
After the call, that function is replaced with one returning the value. A value
that needs itself while being computed calls its function again and recurses
without end. In development, any exception thrown while the values are computed
is replaced with an error message that draws the cycle `names`.

-}
generateCycle : Mode.Mode -> Opt.Global -> List Name.Name -> List ( Name.Name, Opt.Expr ) -> List Opt.Def -> JS.Stmt
generateCycle mode (Opt.Global ((ModuleName.Canonical _ module_) as home) _) names values functions =
    JS.Block
        [ List.map (generateCycleFunc mode home) functions |> JS.Block
        , List.map (generateSafeCycle mode home) values |> JS.Block
        , case List.map (generateRealCycle home) values of
            [] ->
                JS.EmptyStmt

            (_ :: _) as realBlock ->
                case mode of
                    Mode.Prod _ ->
                        JS.Block realBlock

                    Mode.Dev _ ->
                        ("Some top-level definitions from `"
                            ++ module_
                            ++ "` are causing infinite recursion:\\n"
                            ++ drawCycle names
                            ++ "\\n\\nThese errors are very tricky, so read "
                            ++ D.makeNakedLink "bad-recursion"
                            ++ " to learn how to fix it!"
                        )
                            |> JS.ExprString
                            |> JS.Throw
                            |> JS.Try (JS.Block realBlock) JsName.dollar
        ]


{-| Returns the `var` statement for one function of a cycle.
-}
generateCycleFunc : Mode.Mode -> ModuleName.Canonical -> Opt.Def -> JS.Stmt
generateCycleFunc mode home def =
    case def of
        Opt.Def _ name expr ->
            JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr (Expr.generate mode home expr))

        Opt.TailDef _ name args expr ->
            JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr (Expr.generateTailDef mode home name args expr))


{-| Returns the function of no arguments that computes one value of a cycle,
named as `JsName.fromCycle` names it.
-}
generateSafeCycle : Mode.Mode -> ModuleName.Canonical -> ( Name.Name, Opt.Expr ) -> JS.Stmt
generateSafeCycle mode home ( name, expr ) =
    Expr.codeToStmtList (Expr.generate mode home expr) |> JS.FunctionStmt (JsName.fromCycle home name) []


{-| Returns the statements that define one value of a cycle by calling its
function, and then replace that function with one returning the value.
-}
generateRealCycle : ModuleName.Canonical -> ( Name.Name, expr ) -> JS.Stmt
generateRealCycle home ( name, _ ) =
    let
        safeName : JsName.Name
        safeName =
            JsName.fromCycle home name

        realName : JsName.Name
        realName =
            JsName.fromGlobal home name
    in
    JS.Block
        [ JS.Var realName (JS.ExprCall (JS.ExprRef safeName) [])
        , JS.ExprFunction Nothing [] [ JS.Return (JS.ExprRef realName) ] |> JS.ExprAssign (JS.LRef safeName) |> JS.ExprStmt
        ]


{-| Returns `names` drawn as a loop of arrows, for the error message of a cycle.
The line breaks are written as a backslash followed by `n`, ready to go inside
a JavaScript string literal.
-}
drawCycle : List Name.Name -> String
drawCycle names =
    let
        topLine : String
        topLine =
            "\\n  ┌─────┐"

        nameLine : String -> String
        nameLine name =
            "\\n  │    " ++ name

        midLine : String
        midLine =
            "\\n  │     ↓"

        bottomLine : String
        bottomLine =
            "\\n  └─────┘"
    in
    String.concat (topLine :: List.intersperse midLine (List.map nameLine names) ++ [ bottomLine ])


{-| Generates JavaScript code from the chunks of the kernel module keyed by
`global`.

An `Eco` kernel's values are named `_Eco_Home_name` (`JsName.fromEcoKernel`)
so that they cannot clash with an `Elm` kernel of the same home. An `Elm`
kernel's text is emitted as written. A kernel's source, though, spells its own
values `_Home_name` in its plain JavaScript text, and can read another kernel
module's values that way. So in the text of
an `Eco` kernel each identifier `_Home_...` whose `Home` is an `Eco` kernel of
the program becomes `_Eco_Home_...` (`qualifyEcoKernelNames`), and the rest of
its text is left alone.

A value imported with a kernel import (`JsVar`) is named the way
`resolveKernelGlobal` resolves its module, which is how `resolveKernelDeps`
resolves the node's dependencies.

-}
generateKernel : Mode.Mode -> Graph -> Opt.Global -> List K.Chunk -> String
generateKernel mode graph global chunks =
    let
        isEcoHome : Name -> Bool
        isEcoHome home =
            DataMap.member Opt.toComparableGlobal (Opt.toKernelGlobal "Eco" home) graph

        qualifyText : String -> String
        qualifyText =
            case Opt.ecoKernelHome global of
                Just _ ->
                    qualifyEcoKernelNames isEcoHome

                Nothing ->
                    identity
    in
    List.foldr (addChunk mode isEcoHome qualifyText) "" chunks


{-| Returns one kernel chunk's JavaScript followed by `builder`. `isEcoHome`
tells whether the program has an `Eco` kernel of a home, and `qualifyText`
rewrites plain JavaScript text, as `generateKernel` describes.
-}
addChunk : Mode.Mode -> (Name -> Bool) -> (String -> String) -> K.Chunk -> String -> String
addChunk mode isEcoHome qualifyText chunk builder =
    case chunk of
        K.JS javascript ->
            qualifyText javascript ++ builder

        K.ElmVar home name ->
            JsName.fromGlobal home name ++ builder

        K.JsVar kernelPrefix home name ->
            if kernelPrefix == "Eco" && isEcoHome home then
                JsName.fromEcoKernel home name ++ builder

            else
                JsName.fromKernel home name ++ builder

        K.ElmField name ->
            Expr.generateField mode name ++ builder

        K.JsField int ->
            JsName.fromInt int ++ builder

        K.JsEnum int ->
            String.fromInt int ++ builder

        K.Debug ->
            case mode of
                Mode.Dev _ ->
                    builder

                Mode.Prod _ ->
                    "_UNUSED" ++ builder

        K.Prod ->
            case mode of
                Mode.Dev _ ->
                    "_UNUSED" ++ builder

                Mode.Prod _ ->
                    builder



{-| Returns the global a kernel node's dependency `global` stands for in
`graph`.

A kernel import `import Eco.Kernel.Home` names the `Eco` kernel `Home`. When the
graph has none, the global of the `Elm` kernel `Home` is returned instead.
Every other global is returned as it is.

-}
resolveKernelGlobal : Graph -> Opt.Global -> Opt.Global
resolveKernelGlobal graph global =
    case Opt.ecoKernelHome global of
        Just home ->
            if DataMap.member Opt.toComparableGlobal global graph then
                global

            else
                Opt.toKernelGlobal "Elm" home

        Nothing ->
            global


{-| Returns a kernel node's dependencies, each resolved by `resolveKernelGlobal`.
-}
resolveKernelDeps : Graph -> EverySet String Opt.Global -> EverySet String Opt.Global
resolveKernelDeps graph deps =
    EverySet.fromList Opt.toComparableGlobal (List.map (resolveKernelGlobal graph) (EverySet.toList deps))


{-| Rewrites each identifier `_Home_rest` in the JavaScript text `js` whose
`Home` satisfies `isEcoHome` to `_Eco_Home_rest`, the name
`JsName.fromEcoKernel` gives the values of `Eco` kernel `Home`.

An identifier here is a `_` that does not follow a letter, digit, `_` or `$`,
then a capital letter followed by any number of ASCII letters and digits
(`Home`), then `_`. The start of `js` counts as such a boundary. The scan
does not tell code from strings and comments, so it rewrites `_Home_` there
too.

-}
qualifyEcoKernelNames : (Name -> Bool) -> String -> String
qualifyEcoKernelNames isEcoHome js =
    let
        charAt : Int -> String
        charAt i =
            String.slice i (i + 1) js

        isIdentChar : String -> Bool
        isIdentChar c =
            c == "_" || c == "$" || String.all Char.isAlphaNum c && c /= ""

        homeEnd : Int -> Int
        homeEnd i =
            if String.all Char.isAlphaNum (charAt i) && charAt i /= "" then
                homeEnd (i + 1)

            else
                i

        -- The index at which "Eco_" goes in when the `_` at `idx` starts a
        -- `_Home_` identifier of an `Eco` kernel.
        insertionPoint : Int -> Maybe Int
        insertionPoint idx =
            if (idx == 0 || not (isIdentChar (charAt (idx - 1)))) && String.all Char.isUpper (charAt (idx + 1)) && charAt (idx + 1) /= "" then
                let
                    end =
                        homeEnd (idx + 1)
                in
                if charAt end == "_" && isEcoHome (String.slice (idx + 1) end js) then
                    Just (idx + 1)

                else
                    Nothing

            else
                Nothing

        insertions : List Int
        insertions =
            List.filterMap insertionPoint (String.indexes "_" js)
    in
    case insertions of
        [] ->
            js

        _ ->
            let
                ( last, revPieces ) =
                    List.foldl
                        (\at ( from, acc ) -> ( at, "Eco_" :: String.slice from at js :: acc ))
                        ( 0, [] )
                        insertions
            in
            String.concat (List.reverse (String.dropLeft last js :: revPieces))



-- ====== Enum Constructors ======


{-| Returns the `var` statement for a constructor with no arguments: the
constructor's object in development, and its index as an integer in production.
-}
generateEnum : Mode.Mode -> Opt.Global -> Index.ZeroBased -> JS.Stmt
generateEnum mode ((Opt.Global home name) as global) index =
    JS.Var (JsName.fromGlobal home name) <|
        case mode of
            Mode.Dev _ ->
                Expr.codeToExpr (Expr.generateCtor mode global index 0)

            Mode.Prod _ ->
                JS.ExprInt (Index.toMachine index)



-- ====== Box Constructors ======


{-| Returns the `var` statement for the one constructor, of one argument, of a
type: a constructor function in development, and `identity` in production, so
that the value is the argument itself.
-}
generateBox : Mode.Mode -> Opt.Global -> JS.Stmt
generateBox mode ((Opt.Global home name) as global) =
    JS.Var (JsName.fromGlobal home name) <|
        case mode of
            Mode.Dev _ ->
                Expr.codeToExpr (Expr.generateCtor mode global Index.first 1)

            Mode.Prod _ ->
                JS.ExprRef (JsName.fromGlobal ModuleName.basics Name.identity_)


{-| The global of `Basics.identity`.
-}
identity_ : Opt.Global
identity_ =
    Opt.Global ModuleName.basics Name.identity_



-- ====== Ports ======


{-| Returns the `var` statement defining a port as a call of the platform
kernel's `makePort` with the port's name and `converter`, its decoder or
encoder.
-}
generatePort : Mode.Mode -> Opt.Global -> Name.Name -> Opt.Expr -> JS.Stmt
generatePort mode (Opt.Global home name) makePort converter =
    JS.Var (JsName.fromGlobal home name) <|
        JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.platform makePort))
            [ JS.ExprString name
            , Expr.codeToExpr (Expr.generate mode home converter)
            ]



-- ====== Effect Managers ======


{-| Adds an effect manager to the state: its functions, the registration of the
manager under its module's name, and the `command` or `subscription` function,
or both, that make its effects.
-}
generateManager : Mode.Mode -> Graph -> Opt.Global -> Opt.EffectsType -> State -> State
generateManager mode graph (Opt.Global ((ModuleName.Canonical _ moduleName) as home) _) effectsType state =
    let
        managerLVar : JS.LValue
        managerLVar =
            JS.LBracket
                (JS.ExprRef (JsName.fromKernel Name.platform "effectManagers"))
                (JS.ExprString moduleName)

        ( deps, args, stmts ) =
            generateManagerHelp home effectsType

        createManager : JS.Stmt
        createManager =
            JS.ExprCall (JS.ExprRef (JsName.fromKernel Name.platform "createManager")) args |> JS.ExprAssign managerLVar |> JS.ExprStmt
    in
    JS.Block (createManager :: stmts) |> addStmt (List.foldl (flip (addGlobal mode graph)) state deps)


{-| Returns the `var` statement defining `name` of `home` as the platform's
`leaf` for the module.
-}
generateLeaf : ModuleName.Canonical -> Name.Name -> JS.Stmt
generateLeaf ((ModuleName.Canonical _ moduleName) as home) name =
    JS.ExprCall leaf [ JS.ExprString moduleName ] |> JS.Var (JsName.fromGlobal home name)


{-| A reference to the platform kernel's `leaf` function.
-}
leaf : JS.Expr
leaf =
    JS.ExprRef (JsName.fromKernel Name.platform "leaf")


{-| Returns, for an effect manager of `home`, the globals it needs, the
arguments of its registration, and the statements defining its `command`
and `subscription`. A subscription-only manager passes `0` where a command
manager passes `cmdMap`.
-}
generateManagerHelp : ModuleName.Canonical -> Opt.EffectsType -> ( List Opt.Global, List JS.Expr, List JS.Stmt )
generateManagerHelp home effectsType =
    let
        dep : Name.Name -> Opt.Global
        dep name =
            Opt.Global home name

        ref : Name.Name -> JS.Expr
        ref name =
            JS.ExprRef (JsName.fromGlobal home name)
    in
    case effectsType of
        Opt.Cmd ->
            ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap" ]
            , [ ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap" ]
            , [ generateLeaf home "command" ]
            )

        Opt.Sub ->
            ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "subMap" ]
            , [ ref "init", ref "onEffects", ref "onSelfMsg", JS.ExprInt 0, ref "subMap" ]
            , [ generateLeaf home "subscription" ]
            )

        Opt.Fx ->
            ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap", dep "subMap" ]
            , [ ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap", ref "subMap" ]
            , [ generateLeaf home "command"
              , generateLeaf home "subscription"
              ]
            )



-- ====== Main Exports ======


{-| Returns the call of the platform's `export` with the nested object of
`mains`, as the module docstring describes.
-}
toMainExports : Mode.Mode -> CodeGen.Mains -> String
toMainExports mode mains =
    let
        export : JsName.Name
        export =
            JsName.fromKernel Name.platform "export"

        exports : String
        exports =
            generateExports mode (DataMap.foldr addToTrie emptyTrie mains)
    in
    export ++ "(" ++ exports ++ ");"


{-| Returns the JavaScript object for a trie: an `init` field for the `main` at
this level, if any, and one field for each next module-name segment.
-}
generateExports : Mode.Mode -> Trie -> String
generateExports mode (Trie maybeMain subs) =
    let
        starter : String -> String
        starter end =
            case maybeMain of
                Nothing ->
                    "{"

                Just ( home, main ) ->
                    let
                        (JS.Builder builderData) =
                            JS.exprToBuilder (Expr.generateMain mode home main) (JS.emptyBuilder 0)
                    in
                    "{'init':"
                        ++ builderData.revBuilders
                        ++ end
    in
    case Dict.toList subs of
        [] ->
            starter "" ++ "}"

        ( name, subTrie ) :: otherSubTries ->
            starter ","
                ++ "'"
                ++ name
                ++ "':"
                ++ generateExports mode subTrie
                ++ List.foldl (flip (addSubTrie mode)) "}" otherSubTries


{-| Returns the field for one sub-trie, preceded by a comma, followed by `end`.
-}
addSubTrie : Mode.Mode -> String -> ( Name.Name, Trie ) -> String
addSubTrie mode end ( name, trie ) =
    ",'" ++ name ++ "':" ++ generateExports mode trie ++ end



-- ====== Module Trie Structure ======


{-| The `main`s of a program arranged by the segments of their module names.
The `main` at a level belongs to the module whose name ends there; the
dictionary leads on to longer names.
-}
type Trie
    = Trie (Maybe ( ModuleName.Canonical, Opt.Main )) (Dict Name.Name Trie)


{-| The trie with no `main`.
-}
emptyTrie : Trie
emptyTrie =
    Trie Nothing Dict.empty


{-| Adds the `main` of `home` to the trie.
-}
addToTrie : ModuleName.Canonical -> Opt.Main -> Trie -> Trie
addToTrie ((ModuleName.Canonical _ moduleName) as home) main trie =
    segmentsToTrie home (Name.splitDots moduleName) main |> merge trie


{-| Creates a trie holding only `main`, reached through `segments`.
-}
segmentsToTrie : ModuleName.Canonical -> List Name.Name -> Opt.Main -> Trie
segmentsToTrie home segments main =
    case segments of
        [] ->
            Trie (Just ( home, main )) Dict.empty

        segment :: otherSegments ->
            Trie Nothing (Dict.singleton segment (segmentsToTrie home otherSegments main))


{-| Returns a trie holding the `main`s of both tries.
-}
merge : Trie -> Trie -> Trie
merge (Trie main1 subs1) (Trie main2 subs2) =
    Trie
        (checkedMerge main1 main2)
        (Dict.merge Dict.insert (\k v1 v2 acc -> Dict.insert k (merge v1 v2) acc) Dict.insert subs1 subs2 Dict.empty)


{-| Returns whichever of `a` and `b` is present. Both present means two `main`s
for one module name, and crashes.
-}
checkedMerge : Maybe a -> Maybe a -> Maybe a
checkedMerge a b =
    case ( a, b ) of
        ( Nothing, main ) ->
            main

        ( main, Nothing ) ->
            main

        ( Just _, Just _ ) ->
            crash "cannot have two modules with the same name"
