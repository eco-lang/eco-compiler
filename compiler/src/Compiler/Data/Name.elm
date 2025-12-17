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



-- NAME


type alias Name =
    String



-- TO


toChars : Name -> List Char
toChars =
    String.toList


toElmString : Name -> String
toElmString =
    identity



-- FROM


fromPtr : String -> Int -> Int -> Name
fromPtr src start end =
    String.slice start end src



-- HAS DOT


hasDot : Name -> Bool
hasDot =
    String.contains "."


splitDots : Name -> List String
splitDots =
    String.split "."



-- GET KERNEL


getKernel : Name -> Name
getKernel name =
    if isKernel name then
        String.dropLeft (String.length prefixKernel) name

    else
        crash "AssertionFailed"



-- STARTS WITH


isKernel : Name -> Bool
isKernel =
    String.startsWith prefixKernel


isNumberType : Name -> Bool
isNumberType =
    String.startsWith prefixNumber


isComparableType : Name -> Bool
isComparableType =
    String.startsWith prefixComparable


isAppendableType : Name -> Bool
isAppendableType =
    String.startsWith prefixAppendable


isCompappendType : Name -> Bool
isCompappendType =
    String.startsWith prefixCompappend


prefixKernel : Name
prefixKernel =
    "Elm.Kernel."


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



-- FROM VAR INDEX


fromVarIndex : Int -> Name
fromVarIndex n =
    writeDigitsAtEnd "_v" n


writeDigitsAtEnd : String -> Int -> String
writeDigitsAtEnd prefix n =
    prefix ++ String.fromInt n



-- FROM TYPE VARIABLE


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



-- FROM TYPE VARIABLE SCHEME


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



-- FROM MANY NAMES
--
-- Creating a unique name by combining all the subnames can create names
-- longer than 256 bytes relatively easily. So instead, the first given name
-- (e.g. foo) is prefixed chars that are valid in JS but not Elm (e.g. _M$foo)
--
-- This should be a unique name since 0.19 disallows shadowing. It would not
-- be possible for multiple top-level cycles to include values with the same
-- name, so the important thing is to make the cycle name distinct from the
-- normal name. Same logic for destructuring patterns like (x,y)


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



-- FROM WORDS


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
-- SEP BY


sepBy : Char -> Name -> Name -> Name
sepBy sep ba1 ba2 =
    String.join (String.fromChar sep) [ ba1, ba2 ]



-- COMMON NAMES


int : Name
int =
    "Int"


float : Name
float =
    "Float"


bool : Name
bool =
    "Bool"


char : Name
char =
    "Char"


string : Name
string =
    "String"


maybe : Name
maybe =
    "Maybe"


result : Name
result =
    "Result"


list : Name
list =
    "List"


array : Name
array =
    "Array"


dict : Name
dict =
    "Dict"


bytes : Name
bytes =
    "Bytes"


tuple : Name
tuple =
    "Tuple"


jsArray : Name
jsArray =
    "JsArray"


json : Name
json =
    "Json"


task : Name
task =
    "Task"


router : Name
router =
    "Router"


cmd : Name
cmd =
    "Cmd"


sub : Name
sub =
    "Sub"


platform : Name
platform =
    "Platform"


virtualDom : Name
virtualDom =
    "VirtualDom"


shader : Name
shader =
    "Shader"


debug : Name
debug =
    "Debug"


debugger : Name
debugger =
    "Debugger"


bitwise : Name
bitwise =
    "Bitwise"


basics : Name
basics =
    "Basics"


utils : Name
utils =
    "Utils"


negate : Name
negate =
    "negate"


true : Name
true =
    "True"


false : Name
false =
    "False"


value : Name
value =
    "Value"


node : Name
node =
    "Node"


program : Name
program =
    "Program"


main_ : Name
main_ =
    "main"


mainModule : Name
mainModule =
    "Main"


dollar : Name
dollar =
    "$"


identity_ : Name
identity_ =
    "identity"


replModule : Name
replModule =
    "Elm_Repl"


replValueToPrint : Name
replValueToPrint =
    "repl_input_value_"
