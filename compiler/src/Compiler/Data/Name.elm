module Compiler.Data.Name exposing
    ( Name
    , toChars, toElmString
    , fromPtr, fromVarIndex, fromTypeVariable, fromTypeVariableScheme, fromManyNames, fromWords
    , hasDot, splitDots, sepBy
    , isKernel, getKernel
    , isNumberType, isComparableType, isAppendableType, isCompappendType
    , int, float, bool, char, string, maybe, result, list, array, dict, bytes, tuple, jsArray, json, task, router, cmd, sub
    , platform, virtualDom, shader, debug, debugger, bitwise, basics, utils
    , negate, true, false, value, node, program, main_, mainModule, dollar, identity_, replValueToPrint
    )

{-| Every identifier the compiler handles is a `Name`, and this module holds the
rules that are carried in how a name is spelled.

A `Name` is the text of an identifier: a value, type, constructor, record
field, type variable or module, spelled as in source or as the compiler makes
it up. A module name keeps its dots, as in `Elm.Kernel.List`.

Three spelling rules matter outside this module.

A _kernel module_ is one whose name starts with `Elm.Kernel.` or `Eco.Kernel.`
and whose implementation is not written in Elm. The part before `.Kernel.`,
`Elm` or `Eco`, is its _kernel prefix_. `isKernel` recognises these names and
`getKernel` splits one into its prefix and the rest.

A type variable's constraint is written in its name. A variable whose name
starts with `number`, `comparable`, `appendable` or `compappend` is
_super-constrained_: it can stand only for a type of that class. The test is a
prefix match, so `number2` and `comparableKey` are constrained too.

A name the compiler makes up must not clash with one from source. The parser
never starts an identifier or an operator with `_`, so `fromVarIndex` and
`fromManyNames` start their names with it. `fromTypeVariable` and
`fromTypeVariableScheme` make ordinary-looking names, and nothing here checks
them against names already in use.

Besides a few conversion and splitting helpers, the rest of the module is
constants for names the compiler has to recognise or produce. Each is only
text, so one constant can name several things: `maybe` is both the module
`Maybe` and its type.


# Core Type

@docs Name


# Conversion

@docs toChars, toElmString


# Construction

@docs fromPtr, fromVarIndex, fromTypeVariable, fromTypeVariableScheme, fromManyNames, fromWords


# Name Analysis

@docs hasDot, splitDots, sepBy


# Kernel Module Utilities

@docs isKernel, getKernel


# Type Constraint Prefixes

@docs isNumberType, isComparableType, isAppendableType, isCompappendType


# Names of Common Types and Modules

@docs int, float, bool, char, string, maybe, result, list, array, dict, bytes, tuple, jsArray, json, task, router, cmd, sub


# Names of Other Modules, Kernel Modules and Types

@docs platform, virtualDom, shader, debug, debugger, bitwise, basics, utils


# Special Names

@docs negate, true, false, value, node, program, main_, mainModule, dollar, identity_, replValueToPrint

-}

import Utils.Crash exposing (crash)



-- ====== NAME ======


{-| The text of an identifier, spelled as in source or as the compiler makes it
up.

This is a name for `String`, not a new type. Any `String` is accepted where a
`Name` is expected, so the compiler cannot tell a value name from a module
name, or a qualified name from a bare one.

-}
type alias Name =
    String



-- ====== TO ======


{-| Returns the characters of a name, first to last.
-}
toChars : Name -> List Char
toChars =
    String.toList


{-| Returns the name unchanged, since a `Name` already is a `String`.
-}
toElmString : Name -> String
toElmString =
    identity



-- ====== FROM ======


{-| Returns the part of `src` from index `start` up to, but not including, index
`end`, counted as `String.slice` counts them.
-}
fromPtr : String -> Int -> Int -> Name
fromPtr src start end =
    String.slice start end src



-- ====== HAS DOT ======


{-| Tells whether the name contains a `.`, as a qualified name or a dotted module
name does.
-}
hasDot : Name -> Bool
hasDot =
    String.contains "."


{-| Splits a name at every `.`, so `Elm.Kernel.List` gives
`[ "Elm", "Kernel", "List" ]`. A name with no dot gives a list of itself alone.
-}
splitDots : Name -> List String
splitDots =
    String.split "."



-- ====== GET KERNEL ======


{-| Splits the name of a kernel module into its kernel prefix, `Elm` or `Eco`, and
the rest of the name, so `Elm.Kernel.List` gives `( "Elm", "List" )`.

It crashes, with the message `AssertionFailed`, on a name that starts with
neither `Elm.Kernel.` nor `Eco.Kernel.`; `isKernel` accepts exactly the names it
can split.

-}
getKernel : Name -> ( Name, Name )
getKernel name =
    if String.startsWith prefixEcoKernel name then
        ( "Eco", String.dropLeft (String.length prefixEcoKernel) name )

    else if String.startsWith prefixKernel name then
        ( "Elm", String.dropLeft (String.length prefixKernel) name )

    else
        crash "AssertionFailed"



-- ====== STARTS WITH ======


{-| Tells whether the name is that of a kernel module: one that starts with
`Elm.Kernel.` or `Eco.Kernel.`.
-}
isKernel : Name -> Bool
isKernel name =
    String.startsWith prefixKernel name || String.startsWith prefixEcoKernel name


{-| Tells whether a type variable with this name is constrained to numbers, which
it is whenever the name starts with `number`.
-}
isNumberType : Name -> Bool
isNumberType =
    String.startsWith prefixNumber


{-| Tells whether a type variable with this name is constrained to comparable
types, which it is whenever the name starts with `comparable`.
-}
isComparableType : Name -> Bool
isComparableType =
    String.startsWith prefixComparable


{-| Tells whether a type variable with this name is constrained to appendable
types, which it is whenever the name starts with `appendable`.
-}
isAppendableType : Name -> Bool
isAppendableType =
    String.startsWith prefixAppendable


{-| Tells whether a type variable with this name is constrained to types that are
both comparable and appendable, which it is whenever the name starts with
`compappend`.
-}
isCompappendType : Name -> Bool
isCompappendType =
    String.startsWith prefixCompappend


{-| The start of the name of every kernel module whose kernel prefix is `Elm`.
-}
prefixKernel : Name
prefixKernel =
    "Elm.Kernel."


{-| The start of the name of every kernel module whose kernel prefix is `Eco`.
-}
prefixEcoKernel : Name
prefixEcoKernel =
    "Eco.Kernel."


{-| The start of the name of every type variable constrained to numbers.
-}
prefixNumber : Name
prefixNumber =
    "number"


{-| The start of the name of every type variable constrained to comparable
types.
-}
prefixComparable : Name
prefixComparable =
    "comparable"


{-| The start of the name of every type variable constrained to appendable
types.
-}
prefixAppendable : Name
prefixAppendable =
    "appendable"


{-| The start of the name of every type variable constrained to types that are
both comparable and appendable.
-}
prefixCompappend : Name
prefixCompappend =
    "compappend"



-- ====== FROM VAR INDEX ======


{-| Returns the generated variable name for index `n`: `_v` followed by the
index, so 0 gives `_v0`. It cannot clash with a name from source, but it is
only as unique as the index.
-}
fromVarIndex : Int -> Name
fromVarIndex n =
    writeDigitsAtEnd "_v" n


{-| Returns `prefix` followed by the decimal digits of `n`.
-}
writeDigitsAtEnd : String -> Int -> String
writeDigitsAtEnd prefix n =
    prefix ++ String.fromInt n



-- ====== FROM TYPE VARIABLE ======


{-| Returns `name` numbered with `index`, for telling apart type variables that
share a name.

An `index` of zero or less leaves the name unchanged, and so does an empty
name. Otherwise the digits of `index` are appended, after an underscore when
the name already ends in a digit: `a` with 3 gives `a3`, and `a2` with 3 gives
`a2_3`, which keeps it apart from `a` with 23.

-}
fromTypeVariable : Name -> Int -> Name
fromTypeVariable name index =
    if index <= 0 then
        name

    else
        name
            |> String.toList
            |> List.reverse
            |> List.head
            |> Maybe.map
                (\lastChar ->
                    if Char.isDigit lastChar then
                        writeDigitsAtEnd (name ++ "_") index

                    else
                        writeDigitsAtEnd name index
                )
            |> Maybe.withDefault name



-- ====== FROM TYPE VARIABLE SCHEME ======


{-| Returns the name for the type variable numbered `scheme`, counting from 0.

The first 26 are the letters `a` to `z`. From 26 on, the letter is the one for
`scheme` modulo 26, and the number after it is `scheme` less that remainder: 26
gives `a26`, 27 gives `b26` and 52 gives `a52`. Different non-negative numbers
give different names.

-}
fromTypeVariableScheme : Int -> Name
fromTypeVariableScheme scheme =
    if scheme < 26 then
        (0x61 + scheme)
            |> Char.fromCode
            |> String.fromChar

    else
        let
            letter : Int
            letter =
                remainderBy 26 scheme

            extra : Int
            extra =
                max 0 (scheme - letter)
        in
        writeDigitsAtEnd
            ((0x61 + letter)
                |> Char.fromCode
                |> String.fromChar
            )
            extra



-- ====== FROM MANY NAMES ======


{-| Returns one name standing for a group of names: `_M$` followed by the first
of them, so `[ "x", "y" ]` gives `_M$x`.

Only the first name is used, so the result is as unique as that name: two
groups with the same first name get the same name. It never equals a name from
source, including the first name itself. An empty list gives `_M$` alone.

-}
fromManyNames : List Name -> Name
fromManyNames names =
    case names of
        [] ->
            blank

        firstName :: _ ->
            blank ++ firstName


{-| The start of every name `fromManyNames` makes. The parser never starts a name
with `_`, so no name from source begins this way.
-}
blank : Name
blank =
    "_M$"



-- ====== FROM WORDS ======


{-| Returns the name spelled by the characters, in order.
-}
fromWords : List Char -> Name
fromWords words =
    String.fromList words



-- ====== SEP BY ======


{-| Returns `ba1` and `ba2` joined by `sep`, so `sepBy '.' "List" "map"` gives
`List.map`.
-}
sepBy : Char -> Name -> Name -> Name
sepBy sep ba1 ba2 =
    String.join (String.fromChar sep) [ ba1, ba2 ]



-- ====== COMMON NAMES ======


{-| The name of the type `Int`.
-}
int : Name
int =
    "Int"


{-| The name of the type `Float`.
-}
float : Name
float =
    "Float"


{-| The name of the type `Bool`.
-}
bool : Name
bool =
    "Bool"


{-| The name `Char`, of both the module and its type.
-}
char : Name
char =
    "Char"


{-| The name `String`, of both the module and its type.
-}
string : Name
string =
    "String"


{-| The name `Maybe`, of both the module and its type.
-}
maybe : Name
maybe =
    "Maybe"


{-| The name `Result`, of both the module and its type.
-}
result : Name
result =
    "Result"


{-| The name `List`: of the module and its type, and of the kernel module
`Elm.Kernel.List` without its `Elm.Kernel.` part.
-}
list : Name
list =
    "List"


{-| The name `Array`, of both the module and its type.
-}
array : Name
array =
    "Array"


{-| The name of the module `Dict`.
-}
dict : Name
dict =
    "Dict"


{-| The name of the type `Bytes`.
-}
bytes : Name
bytes =
    "Bytes"


{-| The name of the module `Tuple`.
-}
tuple : Name
tuple =
    "Tuple"


{-| The text `JsArray`: the name of the type `Elm.JsArray.JsArray`, and the
kernel module `Elm.Kernel.JsArray` without its `Elm.Kernel.` part. elm/core
has no module named `JsArray`.
-}
jsArray : Name
jsArray =
    "JsArray"


{-| The name of the kernel module `Elm.Kernel.Json`, without its `Elm.Kernel.`
part.
-}
json : Name
json =
    "Json"


{-| The name of the type `Task`.
-}
task : Name
task =
    "Task"


{-| The name of the type `Router`.
-}
router : Name
router =
    "Router"


{-| The name `Cmd`, of the type and of the alias `Platform.Cmd` is imported under
by default.
-}
cmd : Name
cmd =
    "Cmd"


{-| The name `Sub`, of the type and of the alias `Platform.Sub` is imported under
by default.
-}
sub : Name
sub =
    "Sub"


{-| The name `Platform`: of the module, and of the kernel module
`Elm.Kernel.Platform` without its `Elm.Kernel.` part.
-}
platform : Name
platform =
    "Platform"


{-| The name `VirtualDom`: of the module, and of the kernel module
`Elm.Kernel.VirtualDom` without its `Elm.Kernel.` part.
-}
virtualDom : Name
virtualDom =
    "VirtualDom"


{-| The name of the type `Shader`, the type of a GLSL shader literal.
-}
shader : Name
shader =
    "Shader"


{-| The name `Debug`: of the module, and of the kernel module `Elm.Kernel.Debug`
without its `Elm.Kernel.` part.
-}
debug : Name
debug =
    "Debug"


{-| The name of the kernel module `Elm.Kernel.Debugger`, without its
`Elm.Kernel.` part.
-}
debugger : Name
debugger =
    "Debugger"


{-| The name of the module `Bitwise`.
-}
bitwise : Name
bitwise =
    "Bitwise"


{-| The name of the module `Basics`.
-}
basics : Name
basics =
    "Basics"


{-| The name of the kernel module `Elm.Kernel.Utils`, without its `Elm.Kernel.`
part.
-}
utils : Name
utils =
    "Utils"


{-| The name of the function `negate`.
-}
negate : Name
negate =
    "negate"


{-| The name of the constructor `True`.
-}
true : Name
true =
    "True"


{-| The name of the constructor `False`.
-}
false : Name
false =
    "False"


{-| The name of the type `Value`, as in `Json.Encode.Value`.
-}
value : Name
value =
    "Value"


{-| The name of the type `Node`, as in `VirtualDom.Node`.
-}
node : Name
node =
    "Node"


{-| The name of the type `Program`.
-}
program : Name
program =
    "Program"


{-| The name `main`, of the value a program starts from.
-}
main_ : Name
main_ =
    "main"


{-| The name `Main`, given to a module whose source has no `module` line.
-}
mainModule : Name
mainModule =
    "Main"


{-| The name `$`, which the parser never reads as a name of its own. The compiler
gives it to values it makes up, among them the argument of a port encoder or
decoder it builds and the value name of a kernel module's global.
-}
dollar : Name
dollar =
    "$"


{-| The name of the function `identity`.
-}
identity_ : Name
identity_ =
    "identity"


{-| The name the REPL declares an entered expression under, so that its value
can be printed.
-}
replValueToPrint : Name
replValueToPrint =
    "repl_input_value_"
