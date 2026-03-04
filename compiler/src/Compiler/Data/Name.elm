module Compiler.Data.Name exposing
    ( Name
    , toChars, toElmString
    , fromPtr, fromVarIndex, fromTypeVariable, fromTypeVariableScheme, fromManyNames, fromWords
    , hasDot, splitDots, sepBy
    , isKernel, getKernel
    , isNumberType, isComparableType, isAppendableType, isCompappendType
    , int, float, bool, char, string, maybe, result, list, array, dict, bytes, tuple, jsArray, json, task, router, cmd, sub
    , platform, virtualDom, shader, debug, debugger, bitwise, basics, utils
    , negate, true, false, value, node, program, main_, mainModule, dollar, identity_, replModule, replValueToPrint
    )

{-| String-based names used throughout the compiler for identifiers, module names, and type names.

This module provides utilities for working with names including creating them from various sources,
checking for special prefixes like kernel modules, and providing constants for common Elm types and modules.


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


# Common Type Names

@docs int, float, bool, char, string, maybe, result, list, array, dict, bytes, tuple, jsArray, json, task, router, cmd, sub


# Module Names

@docs platform, virtualDom, shader, debug, debugger, bitwise, basics, utils


# Special Names

@docs negate, true, false, value, node, program, main_, mainModule, dollar, identity_, replModule, replValueToPrint

-}

import Utils.Crash exposing (crash)



-- ====== NAME ======


{-| A string-based name used throughout the compiler for identifiers, module names, and type names.
This is a simple type alias to String for clarity and type safety.
-}
type alias Name =
    String



-- ====== TO ======


{-| Convert a Name to a list of characters.
-}
toChars : Name -> List Char
toChars =
    String.toList


{-| Convert a Name to an Elm String (identity function since Name is a String alias).
-}
toElmString : Name -> String
toElmString =
    identity



-- ====== FROM ======


{-| Extract a Name from a source string using start and end indices (substring extraction).
-}
fromPtr : String -> Int -> Int -> Name
fromPtr src start end =
    String.slice start end src



-- ====== HAS DOT ======


{-| Check if a Name contains a dot character (used for qualified names like "List.map").
-}
hasDot : Name -> Bool
hasDot =
    String.contains "."


{-| Split a Name by dot characters into a list of segments.
-}
splitDots : Name -> List String
splitDots =
    String.split "."



-- ====== GET KERNEL ======


{-| Strip the "Elm.Kernel." or "Eco.Kernel." prefix from a kernel module name. Crashes if the name is not a kernel module.
Both prefixes are exactly 11 characters, so the same dropLeft works for either.
-}
getKernel : Name -> Name
getKernel name =
    if isKernel name then
        String.dropLeft (String.length prefixKernel) name

    else
        crash "AssertionFailed"



-- ====== STARTS WITH ======


{-| Check if a Name starts with "Elm.Kernel." or "Eco.Kernel." prefix (identifies kernel modules).
-}
isKernel : Name -> Bool
isKernel name =
    String.startsWith prefixKernel name || String.startsWith prefixEcoKernel name


{-| Check if a Name starts with "number" prefix (identifies number type constraint variables).
-}
isNumberType : Name -> Bool
isNumberType =
    String.startsWith prefixNumber


{-| Check if a Name starts with "comparable" prefix (identifies comparable type constraint variables).
-}
isComparableType : Name -> Bool
isComparableType =
    String.startsWith prefixComparable


{-| Check if a Name starts with "appendable" prefix (identifies appendable type constraint variables).
-}
isAppendableType : Name -> Bool
isAppendableType =
    String.startsWith prefixAppendable


{-| Check if a Name starts with "compappend" prefix (identifies compappend type constraint variables).
-}
isCompappendType : Name -> Bool
isCompappendType =
    String.startsWith prefixCompappend


prefixKernel : Name
prefixKernel =
    "Elm.Kernel."


prefixEcoKernel : Name
prefixEcoKernel =
    "Eco.Kernel."


prefixNumber : Name
prefixNumber =
    "number"


prefixComparable : Name
prefixComparable =
    "comparable"


prefixAppendable : Name
prefixAppendable =
    "appendable"


prefixCompappend : Name
prefixCompappend =
    "compappend"



-- ====== FROM VAR INDEX ======


{-| Generate a variable name from an index (e.g., 0 -> "_v0", 1 -> "_v1").
-}
fromVarIndex : Int -> Name
fromVarIndex n =
    writeDigitsAtEnd "_v" n


writeDigitsAtEnd : String -> Int -> String
writeDigitsAtEnd prefix n =
    prefix ++ String.fromInt n



-- ====== FROM TYPE VARIABLE ======


{-| Create a type variable name with an index suffix. If index is 0, returns the name unchanged.
If the name ends with a digit, adds an underscore before the index (e.g., "a2" + 3 -> "a2\_3").
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


{-| Generate a type variable name from a scheme index (0 -> "a", 1 -> "b", ..., 26 -> "a26", etc.).
Uses lowercase letters with numeric suffixes for indices beyond 25.
-}
fromTypeVariableScheme : Int -> Name
fromTypeVariableScheme scheme =
    if scheme < 26 then
        (0x61 + scheme)
            |> Char.fromCode
            |> String.fromChar

    else
        -- do
        --     let (extra, letter) = List.quotRem scheme 26
        --     let size = 1 + getIndexSize extra
        --     mba <- newByteArray size
        --     writeWord8 mba 0 (0x61 + Word.fromInt letter)
        --     writeDigitsAtEnd mba size extra
        --     freeze mba
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
--
-- Creating a unique name by combining all the subnames can create names
-- longer than 256 bytes relatively easily. So instead, the first given name
-- (e.g. foo) is prefixed chars that are valid in JS but not Elm (e.g. _M$foo)
--
-- This should be a unique name since 0.19 disallows shadowing. It would not
-- be possible for multiple top-level cycles to include values with the same
-- name, so the important thing is to make the cycle name distinct from the
-- normal name. Same logic for destructuring patterns like (x,y)


{-| Create a unique name from multiple names by prefixing the first name with "\_M$".
This creates names valid in JavaScript but not in Elm, avoiding conflicts.
-}
fromManyNames : List Name -> Name
fromManyNames names =
    case names of
        [] ->
            blank

        -- NOTE: this case is needed for (let _ = Debug.log "x" x in ...)
        -- but maybe unused patterns should be stripped out instead
        firstName :: _ ->
            blank ++ firstName


blank : Name
blank =
    "_M$"



-- ====== FROM WORDS ======


{-| Construct a Name from a list of characters.
-}
fromWords : List Char -> Name
fromWords words =
    String.fromList words



-- writeWords : MBA s -> Int -> List Word.Word8 -> ST s ()
-- writeWords !mba !i words =
--     case words of
--         [] ->
--             ()
--         w :: ws ->
--             do
--                 writeWord8 mba i w
--                 writeWords mba (i + 1) ws
-- ====== SEP BY ======


{-| Join two Names with a separator character between them.
-}
sepBy : Char -> Name -> Name -> Name
sepBy sep ba1 ba2 =
    String.join (String.fromChar sep) [ ba1, ba2 ]



-- ====== COMMON NAMES ======


{-| The "Int" type name.
-}
int : Name
int =
    "Int"


{-| The "Float" type name.
-}
float : Name
float =
    "Float"


{-| The "Bool" type name.
-}
bool : Name
bool =
    "Bool"


{-| The "Char" type name.
-}
char : Name
char =
    "Char"


{-| The "String" type name.
-}
string : Name
string =
    "String"


{-| The "Maybe" type name.
-}
maybe : Name
maybe =
    "Maybe"


{-| The "Result" type name.
-}
result : Name
result =
    "Result"


{-| The "List" type name.
-}
list : Name
list =
    "List"


{-| The "Array" type name.
-}
array : Name
array =
    "Array"


{-| The "Dict" type name.
-}
dict : Name
dict =
    "Dict"


{-| The "Bytes" type name.
-}
bytes : Name
bytes =
    "Bytes"


{-| The "Tuple" type name.
-}
tuple : Name
tuple =
    "Tuple"


{-| The "JsArray" type name for JavaScript arrays.
-}
jsArray : Name
jsArray =
    "JsArray"


{-| The "Json" type name.
-}
json : Name
json =
    "Json"


{-| The "Task" type name.
-}
task : Name
task =
    "Task"


{-| The "Router" type name for platform routing.
-}
router : Name
router =
    "Router"


{-| The "Cmd" type name for commands.
-}
cmd : Name
cmd =
    "Cmd"


{-| The "Sub" type name for subscriptions.
-}
sub : Name
sub =
    "Sub"


{-| The "Platform" module name.
-}
platform : Name
platform =
    "Platform"


{-| The "VirtualDom" module name.
-}
virtualDom : Name
virtualDom =
    "VirtualDom"


{-| The "Shader" type name for WebGL shaders.
-}
shader : Name
shader =
    "Shader"


{-| The "Debug" module name.
-}
debug : Name
debug =
    "Debug"


{-| The "Debugger" module name.
-}
debugger : Name
debugger =
    "Debugger"


{-| The "Bitwise" module name.
-}
bitwise : Name
bitwise =
    "Bitwise"


{-| The "Basics" module name.
-}
basics : Name
basics =
    "Basics"


{-| The "Utils" module name.
-}
utils : Name
utils =
    "Utils"


{-| The "negate" function name.
-}
negate : Name
negate =
    "negate"


{-| The "True" boolean constructor name.
-}
true : Name
true =
    "True"


{-| The "False" boolean constructor name.
-}
false : Name
false =
    "False"


{-| The "Value" type name (used in Json.Decode).
-}
value : Name
value =
    "Value"


{-| The "Node" type name (used in Html).
-}
node : Name
node =
    "Node"


{-| The "Program" type name for Elm applications.
-}
program : Name
program =
    "Program"


{-| The "main" function name for program entry points.
-}
main_ : Name
main_ =
    "main"


{-| The "Main" module name for program entry modules.
-}
mainModule : Name
mainModule =
    "Main"


{-| The "$" operator name for function application.
-}
dollar : Name
dollar =
    "$"


{-| The "identity" function name.
-}
identity_ : Name
identity_ =
    "identity"


{-| The "Elm\_Repl" module name for REPL sessions.
-}
replModule : Name
replModule =
    "Elm_Repl"


{-| The "repl\_input\_value\_" variable name for REPL value printing.
-}
replValueToPrint : Name
replValueToPrint =
    "repl_input_value_"
