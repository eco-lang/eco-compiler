module Compiler.AST.SourceBuilder exposing
    ( AliasDef
    , PortDef
    , TypedDef
    , UnionCtor
    , UnionDef
    , accessExpr
    , accessorExpr
    , binopsExpr
    , boolExpr
    , callExpr
    , caseExpr
    , chrExpr
    , ctorExpr
    , define
    , destruct
    , floatExpr
    , ifExpr
    , intExpr
    , lambdaExpr
    , letExpr
    , listExpr
    , makeKernelModule
    , makeModule
    , makeModuleWithDefs
    , makeModuleWithTypedDefs
    , makeModuleWithTypedDefsUnionsAliases
    , makeModuleWithTypedDefsUnionsAliasesExtended
    , makePortModule
    , negateExpr
    , opExpr
    , pAlias
    , pAnything
    , pChr
    , pCons
    , pCtor
    , pInt
    , pList
    , pRecord
    , pStr
    , pTuple
    , pTuple3
    , pUnit
    , pVar
    , parensExpr
    , qualVarExpr
    , recordExpr
    , strExpr
    , tCmd
    , tExtRecord
    , tLambda
    , tRecord
    , tSub
    , tTuple
    , tType
    , tUnit
    , tVar
    , tuple3Expr
    , tupleExpr
    , unitExpr
    , updateExpr
    , varExpr
    )

{-| Lets a test write an Elm program as a Source AST value, so that the program
can be given to the compiler stages that follow parsing without being written
out as source text and parsed.

The Source AST (`Compiler.AST.Source`) is what the parser produces. Besides the
syntax it holds every comment found around each node, which the formatter
needs, and the region of every node, which error reports need. A program built
here has neither: every comment slot is empty, and every region is `A.zero`,
the region from row 0 column 0 to row 0 column 0. The private helpers `c1`,
`c2`, `c0Eol` and `c2Eol`, and the constant `noComments`, fill the comment
slots.

There are builders for expressions, patterns, let definitions, types, and whole
modules. Each module builder exposes everything from the module. The builders
differ in what they accept and in the imports they add:

  - `makeModule` and `makeModuleWithDefs` import `Basics` and `List`.
  - `makeModuleWithTypedDefs` and `makeModuleWithTypedDefsUnionsAliases` import
    the standard set: `Basics`, `Maybe`, `List`, `Elm.JsArray as JsArray`,
    `String` and `Char`.
  - `makeModuleWithTypedDefsUnionsAliasesExtended` imports the standard set and
    `Bitwise`.
  - `makeKernelModule` imports the standard set and `Bitwise`, `Tuple`,
    `Bytes`, `Bytes.Encode` and `Bytes.Decode`.
  - `makePortModule` imports the standard set and `Array`, `Json.Encode`,
    `Json.Decode`, `Platform.Cmd` and `Platform.Sub`.

Every import exposes everything, as `exposing (..)` does. Each module imported
is one of the interfaces in `Compiler.Elm.Interface.Basic.testIfaces`.

A builder stores what it is given and checks nothing, so a built program need
not be one the parser could produce, nor one that compiles. Two differences
from the parser's output are easy to miss. A string or character literal holds
its text exactly as given, while the parser keeps a literal in escaped source
form (`Compiler.Parse.String`), so text that needs an escape must be passed
already escaped. And every list is stored in the order given, while the parser
stores a module's declarations and a record pattern's fields in reverse source
order (`Compiler.Parse.Module`, `Compiler.AST.Source`).

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A



-- ============================================================================
-- COMMENT WRAPPERS
-- ============================================================================


{-| The empty list of comments, for every comment slot a builder fills.
-}
noComments : Src.FComments
noComments =
    []


{-| Pairs a value with an empty list of comments before it.
-}
c1 : a -> Src.C1 a
c1 a =
    ( noComments, a )


{-| Pairs a value with empty lists of comments before and after it.
-}
c2 : a -> Src.C2 a
c2 a =
    ( ( noComments, noComments ), a )


{-| Pairs a value with no end-of-line comment.
-}
c0Eol : a -> Src.C0Eol a
c0Eol a =
    ( Nothing, a )


{-| Pairs a value with empty lists of comments before and after it and no
end-of-line comment.
-}
c2Eol : a -> Src.C2Eol a
c2Eol a =
    ( ( noComments, noComments, Nothing ), a )



-- ============================================================================
-- EXPRESSION BUILDERS
-- ============================================================================


{-| Builds an `Int` literal, spelled as `String.fromInt` writes `n`.
-}
intExpr : Int -> Src.Expr
intExpr n =
    A.At A.zero (Src.Int n (String.fromInt n))


{-| Builds a `Float` literal, spelled as `String.fromFloat` writes `f`, so a
whole number such as `1.0` is spelled `1`.
-}
floatExpr : Float -> Src.Expr
floatExpr f =
    A.At A.zero (Src.Float f (String.fromFloat f))


{-| Builds a single-line string literal whose text is `s` exactly as given,
with no escaping added.
-}
strExpr : String -> Src.Expr
strExpr s =
    A.At A.zero (Src.Str s False)


{-| Builds a character literal whose text is `c` exactly as given, with no
escaping added.
-}
chrExpr : String -> Src.Expr
chrExpr c =
    A.At A.zero (Src.Chr c)


{-| The unit expression, `()`.
-}
unitExpr : Src.Expr
unitExpr =
    A.At A.zero Src.Unit


{-| Builds `Basics.True` or `Basics.False`, a constructor qualified with its
module.
-}
boolExpr : Bool -> Src.Expr
boolExpr b =
    let
        name =
            if b then
                "True"

            else
                "False"
    in
    A.At A.zero (Src.VarQual Src.CapVar "Basics" name)


{-| Builds an unqualified reference to the lower-case name `name`.
-}
varExpr : Name -> Src.Expr
varExpr name =
    A.At A.zero (Src.Var Src.LowVar name)


{-| Builds an unqualified reference to the constructor `name`, such as `Just`.
-}
ctorExpr : Name -> Src.Expr
ctorExpr name =
    A.At A.zero (Src.Var Src.CapVar name)


{-| Builds a reference to the lower-case name `name` qualified with
`moduleName`, such as `List.map`.
-}
qualVarExpr : String -> Name -> Src.Expr
qualVarExpr moduleName name =
    A.At A.zero (Src.VarQual Src.LowVar moduleName name)


{-| Builds an operator used as a value, such as `(+)`. `name` is the operator
without parentheses.
-}
opExpr : Name -> Src.Expr
opExpr name =
    A.At A.zero (Src.Op name)


{-| Builds a list literal of `elements`.
-}
listExpr : List Src.Expr -> Src.Expr
listExpr elements =
    A.At A.zero (Src.List (List.map c2Eol elements) noComments)


{-| Builds a pair.
-}
tupleExpr : Src.Expr -> Src.Expr -> Src.Expr
tupleExpr a b =
    A.At A.zero (Src.Tuple (c2 a) (c2 b) [])


{-| Builds a triple.
-}
tuple3Expr : Src.Expr -> Src.Expr -> Src.Expr -> Src.Expr
tuple3Expr a b c =
    A.At A.zero (Src.Tuple (c2 a) (c2 b) [ c2 c ])


{-| Builds a record literal with the given field names and values.
-}
recordExpr : List ( Name, Src.Expr ) -> Src.Expr
recordExpr fields =
    let
        fieldList =
            List.map (\( name, expr ) -> c2Eol ( c1 (A.At A.zero name), c1 expr )) fields
    in
    A.At A.zero (Src.Record (c1 fieldList))


{-| Builds the negation of `inner`. The parser negates only a term, so an
`inner` built by `callExpr`, `binopsExpr` or `negateExpr` and not wrapped in
`parensExpr` gives a value it would not produce.
-}
negateExpr : Src.Expr -> Src.Expr
negateExpr inner =
    A.At A.zero (Src.Negate inner)


{-| Builds a chain of binary operators. Each pair in `ops` is an operand and the
operator after it, and `final` is the last operand, so
`binopsExpr [ ( a, "+" ), ( b, "*" ) ] c` is `a + b * c`. The chain is
stored flat; precedence is applied later, during canonicalization.
-}
binopsExpr : List ( Src.Expr, Name ) -> Src.Expr -> Src.Expr
binopsExpr ops final =
    A.At A.zero (Src.Binops (List.map (\( e, op ) -> ( e, c2 (A.At A.zero op) )) ops) final)


{-| Builds an anonymous function taking `args` and returning `body`.
-}
lambdaExpr : List Src.Pattern -> Src.Expr -> Src.Expr
lambdaExpr args body =
    A.At A.zero (Src.Lambda (c1 (List.map c1 args)) (c1 body))


{-| Builds the application of `func` to `args`. An empty `args` gives a call
with no arguments, which source text cannot express.
-}
callExpr : Src.Expr -> List Src.Expr -> Src.Expr
callExpr func args =
    A.At A.zero (Src.Call func (List.map c1 args))


{-| Builds an `if` with no `else if` branches.
-}
ifExpr : Src.Expr -> Src.Expr -> Src.Expr -> Src.Expr
ifExpr condition then_ else_ =
    A.At A.zero (Src.If (c1 ( c2 condition, c2 then_ )) [] (c1 else_))


{-| Builds a `let` of `defs`, in the order given, around `body`.
-}
letExpr : List Src.Def -> Src.Expr -> Src.Expr
letExpr defs body =
    A.At A.zero (Src.Let (List.map (\d -> c2 (A.At A.zero d)) defs) noComments body)


{-| Builds a `case` of `subject` with one branch per pattern and body pair.
-}
caseExpr : Src.Expr -> List ( Src.Pattern, Src.Expr ) -> Src.Expr
caseExpr subject branches =
    A.At A.zero (Src.Case (c2 subject) (List.map (\( p, e ) -> ( c2 p, c1 e )) branches))


{-| Builds the accessor function for `field`, as `.field` is written.
-}
accessorExpr : Name -> Src.Expr
accessorExpr field =
    A.At A.zero (Src.Accessor field)


{-| Builds `record.field`.
-}
accessExpr : Src.Expr -> Name -> Src.Expr
accessExpr record field =
    A.At A.zero (Src.Access record (A.At A.zero field))


{-| Builds an update of `record` that sets the given fields. `record` may be any
expression, though source text only allows a variable there.
-}
updateExpr : Src.Expr -> List ( Name, Src.Expr ) -> Src.Expr
updateExpr record fields =
    let
        fieldList =
            List.map (\( name, expr ) -> c2Eol ( c1 (A.At A.zero name), c1 expr )) fields
    in
    A.At A.zero (Src.Update (c2 record) (c1 fieldList))


{-| Builds `inner` in parentheses.
-}
parensExpr : Src.Expr -> Src.Expr
parensExpr inner =
    A.At A.zero (Src.Parens (c2 inner))



-- ============================================================================
-- PATTERN BUILDERS
-- ============================================================================


{-| The wildcard pattern, `_`.
-}
pAnything : Src.Pattern
pAnything =
    A.At A.zero (Src.PAnything "_")


{-| Builds a pattern that binds `name`.
-}
pVar : Name -> Src.Pattern
pVar name =
    A.At A.zero (Src.PVar name)


{-| Builds a pattern matching the `Int` `n`, spelled as `String.fromInt`
writes it.
-}
pInt : Int -> Src.Pattern
pInt n =
    A.At A.zero (Src.PInt n (String.fromInt n))


{-| Builds a pattern matching the single-line string literal whose text is
`s` exactly as given, with no escaping added.
-}
pStr : String -> Src.Pattern
pStr s =
    A.At A.zero (Src.PStr s False)


{-| Builds a pattern matching the character literal whose text is `c`
exactly as given, with no escaping added.
-}
pChr : String -> Src.Pattern
pChr c =
    A.At A.zero (Src.PChr c)


{-| The unit pattern, `()`.
-}
pUnit : Src.Pattern
pUnit =
    A.At A.zero (Src.PUnit noComments)


{-| Builds a pattern matching a pair.
-}
pTuple : Src.Pattern -> Src.Pattern -> Src.Pattern
pTuple a b =
    A.At A.zero (Src.PTuple (c2 a) (c2 b) [])


{-| Builds a pattern matching a triple.
-}
pTuple3 : Src.Pattern -> Src.Pattern -> Src.Pattern -> Src.Pattern
pTuple3 a b c =
    A.At A.zero (Src.PTuple (c2 a) (c2 b) [ c2 c ])


{-| Builds a pattern matching a list of exactly as many elements as
`elements` has.
-}
pList : List Src.Pattern -> Src.Pattern
pList elements =
    A.At A.zero (Src.PList (c1 (List.map c2 elements)))


{-| Builds the pattern `head :: tail`.
-}
pCons : Src.Pattern -> Src.Pattern -> Src.Pattern
pCons head tail =
    A.At A.zero (Src.PCons (c0Eol head) (c2Eol tail))


{-| Builds a record pattern that binds `fields`. They are stored in the order
given, which is the reverse of how the parser stores the same pattern.
-}
pRecord : List Name -> Src.Pattern
pRecord fields =
    A.At A.zero (Src.PRecord (c1 (List.map (\name -> c2 (A.At A.zero name)) fields)))


{-| Builds `pattern as name`.
-}
pAlias : Src.Pattern -> Name -> Src.Pattern
pAlias pattern name =
    A.At A.zero (Src.PAlias (c1 pattern) (c1 (A.At A.zero name)))


{-| Builds a pattern matching the unqualified constructor `name` applied to
`args`.
-}
pCtor : Name -> List Src.Pattern -> Src.Pattern
pCtor name args =
    A.At A.zero (Src.PCtor A.zero name (List.map c1 args))



-- ============================================================================
-- DEFINITION BUILDERS
-- ============================================================================


{-| Builds a let definition of `name` with arguments `args` and no type
annotation.
-}
define : Name -> List Src.Pattern -> Src.Expr -> Src.Def
define name args body =
    Src.Define (A.At A.zero name) (List.map c1 args) (c1 body) Nothing


{-| Builds a let definition that matches `expr` against `pattern`.
-}
destruct : Src.Pattern -> Src.Expr -> Src.Def
destruct pattern expr =
    Src.Destruct pattern (c1 expr)



-- ============================================================================
-- MODULE BUILDERS
-- ============================================================================


{-| The import `import Basics exposing (..)`.
-}
basicsImport : Src.Import
basicsImport =
    Src.Import
        (c1 (A.At A.zero "Basics"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Maybe exposing (..)`.
-}
maybeImport : Src.Import
maybeImport =
    Src.Import
        (c1 (A.At A.zero "Maybe"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import List exposing (..)`.
-}
listImport : Src.Import
listImport =
    Src.Import
        (c1 (A.At A.zero "List"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Elm.JsArray as JsArray exposing (..)`.
-}
jsArrayImport : Src.Import
jsArrayImport =
    Src.Import
        (c1 (A.At A.zero "Elm.JsArray"))
        (Just (c2 "JsArray"))
        (c2 (Src.Open noComments noComments))


{-| The import `import String exposing (..)`.
-}
stringImport : Src.Import
stringImport =
    Src.Import
        (c1 (A.At A.zero "String"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Char exposing (..)`.
-}
charImport : Src.Import
charImport =
    Src.Import
        (c1 (A.At A.zero "Char"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Bitwise exposing (..)`.
-}
bitwiseImport : Src.Import
bitwiseImport =
    Src.Import
        (c1 (A.At A.zero "Bitwise"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Tuple exposing (..)`.
-}
tupleImport : Src.Import
tupleImport =
    Src.Import
        (c1 (A.At A.zero "Tuple"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The standard import set: `Basics`, `Maybe`, `List`, `Elm.JsArray as JsArray`,
`String` and `Char`.
-}
standardImports : List Src.Import
standardImports =
    [ basicsImport, maybeImport, listImport, jsArrayImport, stringImport, charImport ]


{-| The standard import set and `Bitwise`.
-}
extendedImports : List Src.Import
extendedImports =
    [ basicsImport, maybeImport, listImport, jsArrayImport, stringImport, charImport, bitwiseImport ]


{-| The kernel import set: the standard set and `Bitwise`, `Tuple`, `Bytes`,
`Bytes.Encode` and `Bytes.Decode`.
-}
kernelImports : List Src.Import
kernelImports =
    [ basicsImport, maybeImport, listImport, jsArrayImport, stringImport, charImport, bitwiseImport, tupleImport, bytesImport, bytesEncodeImport, bytesDecodeImport ]


{-| The import `import Bytes exposing (..)`.
-}
bytesImport : Src.Import
bytesImport =
    Src.Import
        (c1 (A.At A.zero "Bytes"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Bytes.Encode exposing (..)`.
-}
bytesEncodeImport : Src.Import
bytesEncodeImport =
    Src.Import
        (c1 (A.At A.zero "Bytes.Encode"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Bytes.Decode exposing (..)`.
-}
bytesDecodeImport : Src.Import
bytesDecodeImport =
    Src.Import
        (c1 (A.At A.zero "Bytes.Decode"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| Builds a module named `Test` whose one top-level value is `name`, defined
as `expr` with no arguments and no annotation. It imports `Basics` and
`List`.
-}
makeModule : Name -> Src.Expr -> Src.Module
makeModule name expr =
    let
        value =
            Src.Value
                { comments = noComments
                , name = c1 (A.At A.zero name)
                , args = []
                , body = c1 expr
                , tipe = Nothing
                }
    in
    Src.Module
        { name = Just (A.At A.zero "Test")
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = [ basicsImport, listImport ]
        , values = [ A.At A.zero value ]
        , unions = []
        , aliases = []
        , infixes = []
        , effects = Src.NoEffects
        }


{-| Builds a module named `Test` whose one top-level value is `name`, defined
as `expr` with no arguments and no annotation. It imports the kernel set:
`Basics`, `Maybe`, `List`, `Elm.JsArray as JsArray`, `String`, `Char`,
`Bitwise`, `Tuple`, `Bytes`, `Bytes.Encode` and `Bytes.Decode`.
-}
makeKernelModule : Name -> Src.Expr -> Src.Module
makeKernelModule name expr =
    let
        value =
            Src.Value
                { comments = noComments
                , name = c1 (A.At A.zero name)
                , args = []
                , body = c1 expr
                , tipe = Nothing
                }
    in
    Src.Module
        { name = Just (A.At A.zero "Test")
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = kernelImports
        , values = [ A.At A.zero value ]
        , unions = []
        , aliases = []
        , infixes = []
        , effects = Src.NoEffects
        }


{-| Builds a module named `moduleName` with one top-level value for each name,
arguments and body in `defs`, none annotated. It imports `Basics` and
`List`.
-}
makeModuleWithDefs : Name -> List ( Name, List Src.Pattern, Src.Expr ) -> Src.Module
makeModuleWithDefs moduleName defs =
    let
        values =
            List.map
                (\( name, args, body ) ->
                    A.At A.zero
                        (Src.Value
                            { comments = noComments
                            , name = c1 (A.At A.zero name)
                            , args = List.map c1 args
                            , body = c1 body
                            , tipe = Nothing
                            }
                        )
                )
                defs
    in
    Src.Module
        { name = Just (A.At A.zero moduleName)
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = [ basicsImport, listImport ]
        , values = values
        , unions = []
        , aliases = []
        , infixes = []
        , effects = Src.NoEffects
        }


{-| A top-level value with a type annotation, for the module builders that take
annotated definitions. `tipe` is the annotation.
-}
type alias TypedDef =
    { name : Name
    , args : List Src.Pattern
    , tipe : Src.Type
    , body : Src.Expr
    }


{-| Builds a module named `moduleName` with one annotated top-level value for
each of `defs`. It imports the standard set: `Basics`, `Maybe`, `List`,
`Elm.JsArray as JsArray`, `String` and `Char`.
-}
makeModuleWithTypedDefs : Name -> List TypedDef -> Src.Module
makeModuleWithTypedDefs moduleName defs =
    let
        values =
            List.map
                (\{ name, args, tipe, body } ->
                    A.At A.zero
                        (Src.Value
                            { comments = noComments
                            , name = c1 (A.At A.zero name)
                            , args = List.map c1 args
                            , body = c1 body
                            , tipe = Just (c1 (c2 tipe))
                            }
                        )
                )
                defs
    in
    Src.Module
        { name = Just (A.At A.zero moduleName)
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = standardImports
        , values = values
        , unions = []
        , aliases = []
        , infixes = []
        , effects = Src.NoEffects
        }



-- ============================================================================
-- TYPE BUILDERS
-- ============================================================================


{-| Builds the type variable `name`.
-}
tVar : Name -> Src.Type
tVar name =
    A.At A.zero (Src.TVar name)


{-| Builds the function type `from -> to`.
-}
tLambda : Src.Type -> Src.Type -> Src.Type
tLambda from to =
    A.At A.zero (Src.TLambda (c0Eol from) (c2Eol to))


{-| Builds the unqualified type `name` applied to `args`, such as `Maybe a`.
-}
tType : Name -> List Src.Type -> Src.Type
tType name args =
    A.At A.zero (Src.TType A.zero name (List.map c1 args))


{-| Builds a pair type.
-}
tTuple : Src.Type -> Src.Type -> Src.Type
tTuple a b =
    A.At A.zero (Src.TTuple (c2Eol a) (c2Eol b) [])


{-| Builds a closed record type with the given field names and types.
-}
tRecord : List ( Name, Src.Type ) -> Src.Type
tRecord fields =
    let
        fieldList =
            List.map (\( name, t ) -> c2 ( c1 (A.At A.zero name), c1 t )) fields
    in
    A.At A.zero (Src.TRecord fieldList Nothing noComments)


{-| Builds the extensible record type `{ extVar | ... }` with the given field
names and types.
-}
tExtRecord : Name -> List ( Name, Src.Type ) -> Src.Type
tExtRecord extVar fields =
    let
        fieldList =
            List.map (\( name, t ) -> c2 ( c1 (A.At A.zero name), c1 t )) fields
    in
    A.At A.zero (Src.TRecord fieldList (Just (c2 (A.At A.zero extVar))) noComments)


{-| The unit type, `()`.
-}
tUnit : Src.Type
tUnit =
    A.At A.zero Src.TUnit



-- ============================================================================
-- UNION AND ALIAS BUILDERS
-- ============================================================================


{-| One constructor of a custom type declared by a `UnionDef`, with the types
of its arguments.
-}
type alias UnionCtor =
    { name : Name
    , args : List Src.Type
    }


{-| A custom type declaration to add to a built module. `args` are the names
of its type parameters.
-}
type alias UnionDef =
    { name : Name
    , args : List Name
    , ctors : List UnionCtor
    }


{-| Builds the custom type declaration that `def` describes.
-}
makeUnion : UnionDef -> A.Located Src.Union
makeUnion def =
    let
        ctors =
            List.map
                (\ctor ->
                    c2Eol ( A.At A.zero ctor.name, List.map c1 ctor.args )
                )
                def.ctors
    in
    A.At A.zero
        (Src.Union
            (c2 (A.At A.zero def.name))
            (List.map (\arg -> c1 (A.At A.zero arg)) def.args)
            ctors
        )


{-| A type alias declaration to add to a built module. `args` are the names of
its type parameters, and `tipe` is the type it names.
-}
type alias AliasDef =
    { name : Name
    , args : List Name
    , tipe : Src.Type
    }


{-| Builds the type alias declaration that `def` describes.
-}
makeAlias : AliasDef -> A.Located Src.Alias
makeAlias def =
    A.At A.zero
        (Src.Alias
            { comments = noComments
            , name = c2 (A.At A.zero def.name)
            , args = List.map (\arg -> c1 (A.At A.zero arg)) def.args
            , tipe = c1 def.tipe
            }
        )


{-| Builds a module named `moduleName` with one annotated top-level value for
each of `defs` and the custom types and aliases that `unions` and `aliases`
describe. It imports the standard set: `Basics`, `Maybe`, `List`,
`Elm.JsArray as JsArray`, `String` and `Char`.
-}
makeModuleWithTypedDefsUnionsAliases :
    Name
    -> List TypedDef
    -> List UnionDef
    -> List AliasDef
    -> Src.Module
makeModuleWithTypedDefsUnionsAliases moduleName defs unions aliases =
    let
        values =
            List.map
                (\{ name, args, tipe, body } ->
                    A.At A.zero
                        (Src.Value
                            { comments = noComments
                            , name = c1 (A.At A.zero name)
                            , args = List.map c1 args
                            , body = c1 body
                            , tipe = Just (c1 (c2 tipe))
                            }
                        )
                )
                defs
    in
    Src.Module
        { name = Just (A.At A.zero moduleName)
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = standardImports
        , values = values
        , unions = List.map makeUnion unions
        , aliases = List.map makeAlias aliases
        , infixes = []
        , effects = Src.NoEffects
        }


{-| Builds the same module as `makeModuleWithTypedDefsUnionsAliases`, with
`Bitwise` imported as well.
-}
makeModuleWithTypedDefsUnionsAliasesExtended : Name -> List TypedDef -> List UnionDef -> List AliasDef -> Src.Module
makeModuleWithTypedDefsUnionsAliasesExtended moduleName defs unions aliases =
    let
        values =
            List.map
                (\{ name, args, tipe, body } ->
                    A.At A.zero
                        (Src.Value
                            { comments = noComments
                            , name = c1 (A.At A.zero name)
                            , args = List.map c1 args
                            , body = c1 body
                            , tipe = Just (c1 (c2 tipe))
                            }
                        )
                )
                defs
    in
    Src.Module
        { name = Just (A.At A.zero moduleName)
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = extendedImports
        , values = values
        , unions = List.map makeUnion unions
        , aliases = List.map makeAlias aliases
        , infixes = []
        , effects = Src.NoEffects
        }



-- ============================================================================
-- PORT MODULE BUILDERS
-- ============================================================================


{-| A port declaration to add to a built module.

`tipe` is the whole type of the port, and nothing here checks it.
`Compiler.Canonicalize.Effects` accepts an outgoing port typed
`tLambda valueType (tCmd (tVar "msg"))` and an incoming one typed
`tLambda (tLambda valueType (tVar "msg")) (tSub (tVar "msg"))`, where
`valueType` is a type it allows to cross a port.

-}
type alias PortDef =
    { name : Name
    , tipe : Src.Type
    }


{-| Builds the type `Cmd msgType`.
-}
tCmd : Src.Type -> Src.Type
tCmd msgType =
    A.At A.zero (Src.TType A.zero "Cmd" [ c1 msgType ])


{-| Builds the type `Sub msgType`.
-}
tSub : Src.Type -> Src.Type
tSub msgType =
    A.At A.zero (Src.TType A.zero "Sub" [ c1 msgType ])


{-| Builds the port declaration that `def` describes.
-}
portDecl : PortDef -> Src.Port
portDecl def =
    Src.Port noComments (c2 (A.At A.zero def.name)) def.tipe


{-| Builds a port module named `Test` that declares `ports` and whose one
top-level value is `defName`, defined as `expr` with no arguments and no
annotation. It imports the standard set and `Array`, `Json.Encode`,
`Json.Decode`, `Platform.Cmd` and `Platform.Sub`.
-}
makePortModule : Name -> List PortDef -> Src.Expr -> Src.Module
makePortModule defName ports expr =
    let
        value =
            Src.Value
                { comments = noComments
                , name = c1 (A.At A.zero defName)
                , args = []
                , body = c1 expr
                , tipe = Nothing
                }
    in
    Src.Module
        { name = Just (A.At A.zero "Test")
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = portModuleImports
        , values = [ A.At A.zero value ]
        , unions = []
        , aliases = []
        , infixes = []
        , effects = Src.Ports (List.map portDecl ports)
        }


{-| The import set for a port module: the standard set and `Array`,
`Json.Encode`, `Json.Decode`, `Platform.Cmd` and `Platform.Sub`.
-}
portModuleImports : List Src.Import
portModuleImports =
    [ basicsImport
    , maybeImport
    , listImport
    , jsArrayImport
    , stringImport
    , charImport
    , arrayImport
    , jsonEncodeImport
    , jsonDecodeImport
    , platformCmdImport
    , platformSubImport
    ]


{-| The import `import Array exposing (..)`.
-}
arrayImport : Src.Import
arrayImport =
    Src.Import
        (c1 (A.At A.zero "Array"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Json.Encode exposing (..)`.
-}
jsonEncodeImport : Src.Import
jsonEncodeImport =
    Src.Import
        (c1 (A.At A.zero "Json.Encode"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Json.Decode exposing (..)`.
-}
jsonDecodeImport : Src.Import
jsonDecodeImport =
    Src.Import
        (c1 (A.At A.zero "Json.Decode"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Platform.Cmd exposing (..)`.
-}
platformCmdImport : Src.Import
platformCmdImport =
    Src.Import
        (c1 (A.At A.zero "Platform.Cmd"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| The import `import Platform.Sub exposing (..)`.
-}
platformSubImport : Src.Import
platformSubImport =
    Src.Import
        (c1 (A.At A.zero "Platform.Sub"))
        Nothing
        (c2 (Src.Open noComments noComments))
