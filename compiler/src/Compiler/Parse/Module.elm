module Compiler.Parse.Module exposing
    ( Effects(..)
    , Header
    , Module
    , ProjectType(..)
    , chompImport
    , chompImports
    , chompModule
    , defaultHeader
    , fromByteString
    , isKernel
    )

{-| Parse Elm module declarations including headers, imports, and declarations.

This module provides the entry point for parsing entire Elm modules. It handles:

  - Module headers (normal, port, and effect modules)
  - Import declarations
  - Module documentation comments
  - Top-level declarations


# Parsing Entry Point

@docs fromByteString


# Module Structure

@docs Module, Header, ProjectType, Effects, defaultHeader


# Parsers

@docs chompModule, chompImports, chompImport


# Utilities

@docs isKernel

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name as Name
import Compiler.Elm.Compiler.Imports as Imports
import Compiler.Elm.Package as Pkg
import Compiler.Parse.Declaration as Decl
import Compiler.Parse.Keyword as Keyword
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Compiler.Parse.Space as Space
import Compiler.Parse.Symbol as Symbol
import Compiler.Parse.SyntaxVersion exposing (SyntaxVersion)
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E



-- ====== Parsing Entry Point ======


{-| Parse a complete Elm module from source text.

Takes a syntax version, project type, and source string. Returns either
a parsed module or a syntax error. This is the main entry point for module parsing.

-}
fromByteString : SyntaxVersion -> ProjectType -> String -> Result E.Error Src.Module
fromByteString syntaxVersion projectType source =
    case P.fromByteString (chompModule syntaxVersion projectType) E.ModuleBadEnd source of
        Ok modul ->
            checkModule syntaxVersion projectType modul

        Err err ->
            Err (E.ParseError err)



-- ====== Project Type ======


{-| Whether we're compiling a package or application.

This affects whether ports and effect modules are allowed, and which
default imports are included.

-}
type ProjectType
    = Package Pkg.Name
    | Application


-- Checks if this is the elm/core package.
isCore : ProjectType -> Bool
isCore projectType =
    case projectType of
        Package pkg ->
            pkg == Pkg.core

        Application ->
            False


{-| Check if the project type represents a kernel package.

Only kernel packages (like elm/core internals) are allowed to define
effect modules and use kernel JavaScript code.

-}
isKernel : ProjectType -> Bool
isKernel projectType =
    case projectType of
        Package pkg ->
            Pkg.isKernel pkg

        Application ->
            False



-- ====== Module Parsing ======


{-| Intermediate representation of a parsed module before validation.

This structure preserves all comments and formatting information during
parsing. It's later converted to `Src.Module` after validation in `checkModule`.

-}
type alias Module =
    { initialComments : Src.FComments
    , header : Maybe Header
    , imports : Src.C1 (List (Src.C1 Src.Import))
    , infixes : List (Src.C1 (A.Located Src.Infix))
    , decls : List (Src.C2 Decl.Decl)
    }


{-| Parse the structure of an Elm module.

Parses header (if present), imports, infixes (for kernel code), and
declarations. Handles different project types by conditionally including
default imports and allowing/disallowing certain features.

-}
chompModule : SyntaxVersion -> ProjectType -> P.Parser E.Module Module
chompModule syntaxVersion projectType =
    chompHeader
        |> P.andThen
            (\( ( initialComments, headerComments ), header ) ->
                chompImports
                    (if isCore projectType then
                        []

                     else
                        Imports.defaults
                    )
                    |> P.andThen
                        (\imports ->
                            (if isKernel projectType then
                                chompInfixes []

                             else
                                P.pure []
                            )
                                |> P.andThen
                                    (\infixes ->
                                        P.specialize E.Declarations (chompDecls syntaxVersion)
                                            |> P.map
                                                (\decls ->
                                                    Module
                                                        initialComments
                                                        header
                                                        ( headerComments, imports )
                                                        infixes
                                                        decls
                                                )
                                    )
                        )
            )



-- CHECK MODULE


checkModule : SyntaxVersion -> ProjectType -> Module -> Result E.Error Src.Module
checkModule syntaxVersion projectType module_ =
    let
        ( ( values, unions ), ( aliases, ports ) ) =
            categorizeDecls [] [] [] [] (List.map Src.c2Value module_.decls)

        ( _, imports ) =
            module_.imports
    in
    case module_.header of
        Just ({ effects, docs } as header) ->
            let
                ( _, name ) =
                    header.name

                ( _, exports ) =
                    header.exports
            in
            checkEffects projectType ports effects
                |> Result.map
                    (\checkedEffects ->
                        Src.Module
                            { syntaxVersion = syntaxVersion
                            , name = Just name
                            , exports = exports
                            , docs = toDocs docs (List.map Src.c2Value module_.decls)
                            , imports = List.map Src.c1Value imports
                            , values = values
                            , unions = unions
                            , aliases = aliases
                            , infixes = List.map Src.c1Value module_.infixes
                            , effects = checkedEffects
                            }
                    )

        Nothing ->
            Ok
                (Src.Module
                    { syntaxVersion = syntaxVersion
                    , name = Nothing
                    , exports = A.At A.one (Src.Open [] [])
                    , docs = toDocs (Err A.one) (List.map Src.c2Value module_.decls)
                    , imports = List.map Src.c1Value imports
                    , values = values
                    , unions = unions
                    , aliases = aliases
                    , infixes = List.map Src.c1Value module_.infixes
                    , effects =
                        case ports of
                            [] ->
                                Src.NoEffects

                            _ ->
                                Src.Ports ports
                    }
                )


checkEffects : ProjectType -> List Src.Port -> Effects -> Result E.Error Src.Effects
checkEffects projectType ports effects =
    case effects of
        NoEffects region ->
            case ports of
                [] ->
                    Ok Src.NoEffects

                (Src.Port _ ( _, name ) _) :: _ ->
                    case projectType of
                        Package _ ->
                            Err (E.NoPortsInPackage name)

                        Application ->
                            Err (E.UnexpectedPort region)

        Ports region _ ->
            case projectType of
                Package _ ->
                    Err (E.NoPortModulesInPackage region)

                Application ->
                    case ports of
                        [] ->
                            Err (E.NoPorts region)

                        _ :: _ ->
                            Ok (Src.Ports ports)

        Manager region _ ( _, manager ) ->
            if isKernel projectType then
                case ports of
                    [] ->
                        Ok (Src.Manager region manager)

                    _ :: _ ->
                        Err (E.UnexpectedPort region)

            else
                Err (E.NoEffectsOutsideKernel region)


categorizeDecls :
    List (A.Located Src.Value)
    -> List (A.Located Src.Union)
    -> List (A.Located Src.Alias)
    -> List Src.Port
    -> List Decl.Decl
    -> ( ( List (A.Located Src.Value), List (A.Located Src.Union) ), ( List (A.Located Src.Alias), List Src.Port ) )
categorizeDecls values unions aliases ports decls =
    case decls of
        [] ->
            ( ( values, unions ), ( aliases, ports ) )

        decl :: otherDecls ->
            case decl of
                Decl.Value _ value ->
                    categorizeDecls (value :: values) unions aliases ports otherDecls

                Decl.Union _ union ->
                    categorizeDecls values (union :: unions) aliases ports otherDecls

                Decl.Alias _ alias_ ->
                    categorizeDecls values unions (alias_ :: aliases) ports otherDecls

                Decl.Port _ port_ ->
                    categorizeDecls values unions aliases (port_ :: ports) otherDecls



-- TO DOCS


toDocs : Result A.Region Src.Comment -> List Decl.Decl -> Src.Docs
toDocs comment decls =
    case comment of
        Ok overview ->
            Src.YesDocs overview (getComments decls [])

        Err region ->
            Src.NoDocs region (getComments decls [])


getComments : List Decl.Decl -> List ( Name.Name, Src.Comment ) -> List ( Name.Name, Src.Comment )
getComments decls comments =
    case decls of
        [] ->
            comments

        decl :: otherDecls ->
            case decl of
                Decl.Value c (A.At _ (Src.Value v)) ->
                    getComments otherDecls (addComment c (Tuple.second v.name) comments)

                Decl.Union c (A.At _ (Src.Union ( _, n ) _ _)) ->
                    getComments otherDecls (addComment c n comments)

                Decl.Alias c (A.At _ (Src.Alias data)) ->
                    getComments otherDecls (addComment c (Tuple.second data.name) comments)

                Decl.Port c (Src.Port _ ( _, n ) _) ->
                    getComments otherDecls (addComment c n comments)


addComment : Maybe Src.Comment -> A.Located Name.Name -> List ( Name.Name, Src.Comment ) -> List ( Name.Name, Src.Comment )
addComment maybeComment (A.At _ name) comments =
    case maybeComment of
        Just comment ->
            ( name, comment ) :: comments

        Nothing ->
            comments



-- FRESH LINES


freshLine : (Row -> Col -> E.Module) -> P.Parser E.Module Src.FComments
freshLine toFreshLineError =
    Space.chomp E.ModuleSpace
        |> P.andThen
            (\comments ->
                Space.checkFreshLine toFreshLineError
                    |> P.map (\_ -> comments)
            )



-- CHOMP DECLARATIONS


chompDecls : SyntaxVersion -> P.Parser E.Decl (List (Src.C2 Decl.Decl))
chompDecls syntaxVersion =
    Decl.declaration syntaxVersion
        |> P.andThen (\( decl, _ ) -> P.loop (chompDeclsHelp syntaxVersion) [ decl ])


chompDeclsHelp : SyntaxVersion -> List (Src.C2 Decl.Decl) -> P.Parser E.Decl (P.Step (List (Src.C2 Decl.Decl)) (List (Src.C2 Decl.Decl)))
chompDeclsHelp syntaxVersion decls =
    P.oneOfWithFallback
        [ Space.checkFreshLine E.DeclStart
            |> P.andThen
                (\_ ->
                    Decl.declaration syntaxVersion
                        |> P.map (\( decl, _ ) -> P.Loop (decl :: decls))
                )
        ]
        (P.Done (List.reverse decls))


chompInfixes : List (Src.C1 (A.Located Src.Infix)) -> P.Parser E.Module (List (Src.C1 (A.Located Src.Infix)))
chompInfixes infixes =
    P.oneOfWithFallback
        [ Decl.infix_
            |> P.andThen (\binop -> chompInfixes (binop :: infixes))
        ]
        infixes



-- MODULE DOC COMMENT


chompModuleDocCommentSpace : P.Parser E.Module (Src.C1 (Result A.Region Src.Comment))
chompModuleDocCommentSpace =
    P.addLocation (freshLine E.FreshLine)
        |> P.andThen
            (\(A.At region beforeComments) ->
                P.oneOfWithFallback
                    [ Space.docComment E.ImportStart E.ModuleSpace
                        |> P.andThen
                            (\docComment ->
                                Space.chomp E.ModuleSpace
                                    |> P.andThen
                                        (\afterComments ->
                                            Space.checkFreshLine E.FreshLine
                                                |> P.map
                                                    (\_ ->
                                                        ( beforeComments ++ afterComments
                                                        , Ok docComment
                                                        )
                                                    )
                                        )
                            )
                    ]
                    ( beforeComments, Err region )
            )



-- ====== Header ======


{-| Module header information including name, exports, and effect type.

Contains all the information from the module declaration line,
including surrounding comments and the module documentation comment.

-}
type alias Header =
    { name : Src.C2 (A.Located Name.Name)
    , effects : Effects
    , exports : Src.C2 (A.Located Src.Exposing)
    , docs : Result A.Region Src.Comment
    }


{-| Default header used when a module has no explicit module declaration.

Creates a header for an implicit module named "Main" with open exports.
Used for simple scripts and REPL evaluation contexts.

-}
defaultHeader : Header
defaultHeader =
    { name = ( ( [], [] ), A.At A.zero Name.mainModule )
    , effects = NoEffects A.zero
    , exports = ( ( [], [] ), A.At A.zero (Src.Open [] []) )
    , docs = Err A.zero
    }


{-| The kind of effects a module can have.

  - `NoEffects` - A normal module with no special effects
  - `Ports` - A port module that can define ports for JavaScript interop
  - `Manager` - An effect manager (kernel code only) that defines commands/subscriptions

-}
type Effects
    = NoEffects A.Region
    | Ports A.Region Src.FComments
    | Manager A.Region Src.FComments (Src.C1 Src.Manager)



-- HEADER PARSING HELPERS


type alias ModuleErrContext =
    { spaceErr : Row -> Col -> E.Module
    , nameErr : Row -> Col -> E.Module
    , exposingErr : E.Exposing -> Row -> Col -> E.Module
    }


chompModuleHeaderCommon :
    ModuleErrContext
    -> (A.Position -> A.Position -> Effects)
    -> Src.FComments
    -> A.Position
    -> P.Parser E.Module (Src.C2 (Maybe Header))
chompModuleHeaderCommon errCtx makeEffects initialComments start =
    P.getPosition
        |> P.andThen
            (\effectEnd ->
                Space.chompAndCheckIndent E.ModuleSpace errCtx.spaceErr
                    |> P.andThen
                        (\beforeNameComments ->
                            P.addLocation (Var.moduleName errCtx.nameErr)
                                |> P.andThen
                                    (\name ->
                                        Space.chompAndCheckIndent E.ModuleSpace errCtx.spaceErr
                                            |> P.andThen
                                                (\afterNameComments ->
                                                    Keyword.exposing_ errCtx.spaceErr
                                                        |> P.andThen (\_ -> Space.chompAndCheckIndent E.ModuleSpace errCtx.spaceErr)
                                                        |> P.andThen
                                                            (\afterExportsComments ->
                                                                P.addLocation (P.specialize errCtx.exposingErr exposing_)
                                                                    |> P.andThen
                                                                        (\exports ->
                                                                            chompModuleDocCommentSpace
                                                                                |> P.map
                                                                                    (\docCommentResult ->
                                                                                        buildHeader initialComments
                                                                                            start
                                                                                            effectEnd
                                                                                            beforeNameComments
                                                                                            name
                                                                                            afterNameComments
                                                                                            afterExportsComments
                                                                                            exports
                                                                                            (makeEffects start effectEnd)
                                                                                            docCommentResult
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


buildHeader :
    Src.FComments
    -> A.Position
    -> A.Position
    -> Src.FComments
    -> A.Located Name.Name
    -> Src.FComments
    -> Src.FComments
    -> A.Located Src.Exposing
    -> Effects
    -> Src.C1 (Result A.Region Src.Comment)
    -> Src.C2 (Maybe Header)
buildHeader initialComments _ _ beforeNameComments name afterNameComments afterExportsComments exports effects ( headerComments, docComment ) =
    ( ( initialComments, headerComments )
    , Just <|
        Header
            ( ( beforeNameComments, afterNameComments ), name )
            effects
            ( ( [], afterExportsComments ), exports )
            docComment
    )


chompHeader : P.Parser E.Module (Src.C2 (Maybe Header))
chompHeader =
    freshLine E.FreshLine
        |> P.andThen
            (\initialComments ->
                P.getPosition
                    |> P.andThen
                        (\start ->
                            P.oneOfWithFallback
                                [ chompNormalModule initialComments start
                                , chompPortModule initialComments start
                                , chompEffectModule initialComments start
                                ]
                                ( ( initialComments, [] ), Nothing )
                        )
            )


chompNormalModule : Src.FComments -> A.Position -> P.Parser E.Module (Src.C2 (Maybe Header))
chompNormalModule initialComments start =
    let
        errCtx : ModuleErrContext
        errCtx =
            { spaceErr = E.ModuleProblem
            , nameErr = E.ModuleName
            , exposingErr = E.ModuleExposing
            }
    in
    Keyword.module_ E.ModuleProblem
        |> P.andThen (\_ -> chompModuleHeaderCommon errCtx (\s e -> NoEffects (A.Region s e)) initialComments start)


chompPortModule : Src.FComments -> A.Position -> P.Parser E.Module (Src.C2 (Maybe Header))
chompPortModule initialComments start =
    let
        errCtx : ModuleErrContext
        errCtx =
            { spaceErr = E.PortModuleProblem
            , nameErr = E.PortModuleName
            , exposingErr = E.PortModuleExposing
            }
    in
    Keyword.port_ E.PortModuleProblem
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.ModuleSpace E.PortModuleProblem)
        |> P.andThen
            (\postPortComments ->
                Keyword.module_ E.PortModuleProblem
                    |> P.andThen (\_ -> chompModuleHeaderCommon errCtx (\s e -> Ports (A.Region s e) postPortComments) initialComments start)
            )


chompEffectModule : Src.FComments -> A.Position -> P.Parser E.Module (Src.C2 (Maybe Header))
chompEffectModule initialComments start =
    Keyword.effect_ E.Effect
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.ModuleSpace E.Effect)
        |> P.andThen
            (\postEffectComments ->
                Keyword.module_ E.Effect
                    |> P.andThen (\_ -> chompEffectModuleBody initialComments start postEffectComments)
            )


chompEffectModuleBody : Src.FComments -> A.Position -> Src.FComments -> P.Parser E.Module (Src.C2 (Maybe Header))
chompEffectModuleBody initialComments start postEffectComments =
    P.getPosition
        |> P.andThen
            (\effectEnd ->
                Space.chompAndCheckIndent E.ModuleSpace E.Effect
                    |> P.andThen
                        (\beforeNameComments ->
                            P.addLocation (Var.moduleName E.ModuleName)
                                |> P.andThen
                                    (\name ->
                                        Space.chompAndCheckIndent E.ModuleSpace E.Effect
                                            |> P.andThen
                                                (\afterNameComments ->
                                                    chompEffectModuleWhere initialComments start effectEnd postEffectComments beforeNameComments name afterNameComments
                                                )
                                    )
                        )
            )


chompEffectModuleWhere :
    Src.FComments
    -> A.Position
    -> A.Position
    -> Src.FComments
    -> Src.FComments
    -> A.Located Name.Name
    -> Src.FComments
    -> P.Parser E.Module (Src.C2 (Maybe Header))
chompEffectModuleWhere initialComments start effectEnd postEffectComments beforeNameComments name afterNameComments =
    Keyword.where_ E.Effect
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.ModuleSpace E.Effect)
        |> P.andThen
            (\postWhereComments ->
                chompManager
                    |> P.andThen
                        (\( beforeExportsComments, manager ) ->
                            chompEffectModuleExposing initialComments start effectEnd postEffectComments beforeNameComments name afterNameComments postWhereComments beforeExportsComments manager
                        )
            )


chompEffectModuleExposing :
    Src.FComments
    -> A.Position
    -> A.Position
    -> Src.FComments
    -> Src.FComments
    -> A.Located Name.Name
    -> Src.FComments
    -> Src.FComments
    -> Src.FComments
    -> Src.Manager
    -> P.Parser E.Module (Src.C2 (Maybe Header))
chompEffectModuleExposing initialComments start effectEnd postEffectComments beforeNameComments name afterNameComments postWhereComments beforeExportsComments manager =
    Space.chompAndCheckIndent E.ModuleSpace E.Effect
        |> P.andThen
            (\_ ->
                Keyword.exposing_ E.Effect
                    |> P.andThen (\_ -> Space.chompAndCheckIndent E.ModuleSpace E.Effect)
                    |> P.andThen
                        (\afterExportsComments ->
                            P.addLocation (P.specialize (\_ -> E.Effect) exposing_)
                                |> P.andThen
                                    (\exports ->
                                        chompModuleDocCommentSpace
                                            |> P.map
                                                (\( headerComments, docComment ) ->
                                                    let
                                                        nameWithComments : Src.C2 (A.Located Name.Name)
                                                        nameWithComments =
                                                            ( ( beforeNameComments, afterNameComments ), name )

                                                        managerType : Effects
                                                        managerType =
                                                            Manager (A.Region start effectEnd) postEffectComments ( postWhereComments, manager )

                                                        exportsWithComments : Src.C2 (A.Located Src.Exposing)
                                                        exportsWithComments =
                                                            ( ( beforeExportsComments, afterExportsComments ), exports )
                                                    in
                                                    ( ( initialComments, headerComments )
                                                    , Header nameWithComments managerType exportsWithComments docComment |> Just
                                                    )
                                                )
                                    )
                        )
            )


chompManager : P.Parser E.Module (Src.C1 Src.Manager)
chompManager =
    P.word1 '{' E.Effect
        |> P.andThen (\_ -> spaces_em)
        |> P.andThen
            (\postOpeningBracketComments ->
                P.oneOf E.Effect
                    [ chompCommand
                        |> P.andThen
                            (\cmd ->
                                spaces_em
                                    |> P.andThen
                                        (\trailingComments ->
                                            P.oneOf E.Effect
                                                [ P.word1 '}' E.Effect
                                                    |> P.andThen (\_ -> spaces_em)
                                                    |> P.map
                                                        (\postClosingBracketComments ->
                                                            ( postClosingBracketComments
                                                            , Src.Cmd ( ( postOpeningBracketComments, trailingComments ), cmd )
                                                            )
                                                        )
                                                , P.word1 ',' E.Effect
                                                    |> P.andThen (\_ -> spaces_em)
                                                    |> P.andThen
                                                        (\postCommaComments ->
                                                            chompSubscription
                                                                |> P.andThen
                                                                    (\sub ->
                                                                        spaces_em
                                                                            |> P.andThen
                                                                                (\preClosingBracketComments ->
                                                                                    P.word1 '}' E.Effect
                                                                                        |> P.andThen (\_ -> spaces_em)
                                                                                        |> P.map
                                                                                            (\postClosingBracketComments ->
                                                                                                ( postClosingBracketComments
                                                                                                , Src.Fx
                                                                                                    ( ( postOpeningBracketComments, trailingComments ), cmd )
                                                                                                    ( ( postCommaComments, preClosingBracketComments ), sub )
                                                                                                )
                                                                                            )
                                                                                )
                                                                    )
                                                        )
                                                ]
                                        )
                            )
                    , chompSubscription
                        |> P.andThen
                            (\sub ->
                                spaces_em
                                    |> P.andThen
                                        (\trailingComments ->
                                            P.oneOf E.Effect
                                                [ P.word1 '}' E.Effect
                                                    |> P.andThen (\_ -> spaces_em)
                                                    |> P.map
                                                        (\postClosingBracketComments ->
                                                            ( postClosingBracketComments
                                                            , Src.Sub ( ( postOpeningBracketComments, trailingComments ), sub )
                                                            )
                                                        )
                                                , P.word1 ',' E.Effect
                                                    |> P.andThen (\_ -> spaces_em)
                                                    |> P.andThen
                                                        (\postCommaComments ->
                                                            chompCommand
                                                                |> P.andThen
                                                                    (\cmd ->
                                                                        spaces_em
                                                                            |> P.andThen
                                                                                (\preClosingBracketComments ->
                                                                                    P.word1 '}' E.Effect
                                                                                        |> P.andThen (\_ -> spaces_em)
                                                                                        |> P.map
                                                                                            (\postClosingBracketComments ->
                                                                                                ( postClosingBracketComments
                                                                                                , Src.Fx
                                                                                                    ( ( postCommaComments, preClosingBracketComments ), cmd )
                                                                                                    ( ( postOpeningBracketComments, trailingComments ), sub )
                                                                                                )
                                                                                            )
                                                                                )
                                                                    )
                                                        )
                                                ]
                                        )
                            )
                    ]
            )


chompCommand : P.Parser E.Module (Src.C2 (A.Located Name.Name))
chompCommand =
    Keyword.command_ E.Effect
        |> P.andThen (\_ -> spaces_em)
        |> P.andThen
            (\beforeEqualComments ->
                P.word1 '=' E.Effect
                    |> P.andThen (\_ -> spaces_em)
                    |> P.andThen
                        (\afterEqualComments ->
                            P.addLocation (Var.upper E.Effect)
                                |> P.map (\command -> ( ( beforeEqualComments, afterEqualComments ), command ))
                        )
            )


chompSubscription : P.Parser E.Module (Src.C2 (A.Located Name.Name))
chompSubscription =
    Keyword.subscription_ E.Effect
        |> P.andThen (\_ -> spaces_em)
        |> P.andThen
            (\beforeEqualComments ->
                P.word1 '=' E.Effect
                    |> P.andThen (\_ -> spaces_em)
                    |> P.andThen
                        (\afterEqualComments ->
                            P.addLocation (Var.upper E.Effect)
                                |> P.map (\subscription -> ( ( beforeEqualComments, afterEqualComments ), subscription ))
                        )
            )


spaces_em : P.Parser E.Module Src.FComments
spaces_em =
    Space.chompAndCheckIndent E.ModuleSpace E.Effect



-- ====== Imports ======


{-| Parse a sequence of import declarations.

Repeatedly parses import statements until none remain. Takes a list of
default imports to prepend (empty for core, standard defaults otherwise).

-}
chompImports : List (Src.C1 Src.Import) -> P.Parser E.Module (List (Src.C1 Src.Import))
chompImports is =
    P.oneOfWithFallback
        [ chompImport
            |> P.andThen (\i -> chompImports (i :: is))
        ]
        (List.reverse is)


{-| Parse a single import declaration.

Parses the import keyword, module name, optional alias, and optional
exposing list. Handles all comment preservation around each component.

-}
chompImport : P.Parser E.Module (Src.C1 Src.Import)
chompImport =
    Keyword.import_ E.ImportStart
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.ModuleSpace E.ImportIndentName)
        |> P.andThen
            (\preNameComments ->
                P.addLocation (Var.moduleName E.ImportName)
                    |> P.andThen
                        (\((A.At (A.Region _ end) _) as name) ->
                            Space.chomp E.ModuleSpace
                                |> P.andThen
                                    (\trailingComments ->
                                        P.oneOf E.ImportEnd
                                            [ Space.checkFreshLine E.ImportEnd
                                                |> P.map (\_ -> ( trailingComments, Src.Import ( preNameComments, name ) Nothing ( ( [], [] ), Src.Explicit (A.At A.zero []) ) ))
                                            , Space.checkIndent end E.ImportEnd
                                                |> P.andThen
                                                    (\_ ->
                                                        P.oneOf E.ImportAs
                                                            [ chompAs ( preNameComments, name ) trailingComments
                                                            , chompExposing ( preNameComments, name ) Nothing [] trailingComments
                                                            ]
                                                    )
                                            ]
                                    )
                        )
            )


chompAs : Src.C1 (A.Located Name.Name) -> Src.FComments -> P.Parser E.Module (Src.C1 Src.Import)
chompAs name trailingComments =
    Keyword.as_ E.ImportAs
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.ModuleSpace E.ImportIndentAlias)
        |> P.andThen
            (\postAliasComments ->
                Var.upper E.ImportAlias
                    |> P.andThen
                        (\alias_ ->
                            P.getPosition
                                |> P.andThen
                                    (\end ->
                                        Space.chomp E.ModuleSpace
                                            |> P.andThen
                                                (\preExposedComments ->
                                                    let
                                                        aliasWithComments : Maybe (Src.C2 Name.Name)
                                                        aliasWithComments =
                                                            Just ( ( trailingComments, postAliasComments ), alias_ )

                                                        emptyExposing : Src.C2 Src.Exposing
                                                        emptyExposing =
                                                            ( ( [], [] ), Src.Explicit (A.At A.zero []) )
                                                    in
                                                    P.oneOf E.ImportEnd
                                                        [ Space.checkFreshLine E.ImportEnd
                                                            |> P.map (\_ -> ( preExposedComments, Src.Import name aliasWithComments emptyExposing ))
                                                        , Space.checkIndent end E.ImportEnd
                                                            |> P.andThen (\_ -> chompExposing name (Just ( postAliasComments, alias_ )) trailingComments preExposedComments)
                                                        ]
                                                )
                                    )
                        )
            )


chompExposing :
    Src.C1 (A.Located Name.Name)
    -> Maybe (Src.C1 Name.Name)
    -> Src.FComments
    -> Src.FComments
    -> P.Parser E.Module (Src.C1 Src.Import)
chompExposing name maybeAlias trailingComments preExposedComments =
    Keyword.exposing_ E.ImportExposing
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.ModuleSpace E.ImportIndentExposingList)
        |> P.andThen
            (\postExposedComments ->
                P.specialize E.ImportExposingList exposing_
                    |> P.andThen
                        (\exposed ->
                            freshLine E.ImportEnd
                                |> P.map
                                    (\comments ->
                                        let
                                            aliasWithComments : Maybe (Src.C2 Name.Name)
                                            aliasWithComments =
                                                Maybe.map
                                                    (\( postAliasComments, alias_ ) ->
                                                        ( ( trailingComments, postAliasComments ), alias_ )
                                                    )
                                                    maybeAlias

                                            exposedWithComments : Src.C2 Src.Exposing
                                            exposedWithComments =
                                                ( ( preExposedComments, postExposedComments ), exposed )
                                        in
                                        ( comments, Src.Import name aliasWithComments exposedWithComments )
                                    )
                        )
            )



-- LISTING


exposing_ : P.Parser E.Exposing Src.Exposing
exposing_ =
    P.word1 '(' E.ExposingStart
        |> P.andThen (\_ -> P.getPosition)
        |> P.andThen
            (\start ->
                Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentValue
                    |> P.andThen
                        (\preExposedComments ->
                            P.oneOf E.ExposingValue
                                [ P.word2 '.' '.' E.ExposingValue
                                    |> P.andThen (\_ -> Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentEnd)
                                    |> P.andThen
                                        (\postComments ->
                                            P.word1 ')' E.ExposingEnd
                                                |> P.map (\_ -> Src.Open preExposedComments postComments)
                                        )
                                , chompExposed
                                    |> P.andThen
                                        (\exposed ->
                                            Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentEnd
                                                |> P.andThen
                                                    (\postExposedComments ->
                                                        P.loop (exposingHelp start) [ ( ( preExposedComments, postExposedComments ), exposed ) ]
                                                    )
                                        )
                                ]
                        )
            )


exposingHelp : A.Position -> List (Src.C2 Src.Exposed) -> P.Parser E.Exposing (P.Step (List (Src.C2 Src.Exposed)) Src.Exposing)
exposingHelp start revExposed =
    P.oneOf E.ExposingEnd
        [ P.word1 ',' E.ExposingEnd
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentValue)
            |> P.andThen
                (\preExposedComments ->
                    chompExposed
                        |> P.andThen
                            (\exposed ->
                                Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentEnd
                                    |> P.map
                                        (\postExposedComments ->
                                            P.Loop (( ( preExposedComments, postExposedComments ), exposed ) :: revExposed)
                                        )
                            )
                )
        , P.word1 ')' E.ExposingEnd
            |> P.andThen (\_ -> P.getPosition)
            |> P.map (\end -> P.Done (Src.Explicit (A.At (A.Region start end) (List.reverse revExposed))))
        ]


chompExposed : P.Parser E.Exposing Src.Exposed
chompExposed =
    P.getPosition
        |> P.andThen
            (\start ->
                P.oneOf E.ExposingValue
                    [ Var.lower E.ExposingValue
                        |> P.andThen
                            (\name ->
                                P.getPosition
                                    |> P.map (\end -> A.at start end name |> Src.Lower)
                            )
                    , P.word1 '(' E.ExposingValue
                        |> P.andThen (\_ -> Symbol.operator E.ExposingOperator E.ExposingOperatorReserved)
                        |> P.andThen
                            (\op ->
                                P.word1 ')' E.ExposingOperatorRightParen
                                    |> P.andThen (\_ -> P.getPosition)
                                    |> P.map (\end -> Src.Operator (A.Region start end) op)
                            )
                    , Var.upper E.ExposingValue
                        |> P.andThen
                            (\name ->
                                P.getPosition
                                    |> P.andThen
                                        (\end ->
                                            Space.chompAndCheckIndent E.ExposingSpace E.ExposingIndentEnd
                                                |> P.andThen
                                                    (\privacyComments ->
                                                        privacy
                                                            |> P.map (Src.Upper (A.at start end name) << Tuple.pair privacyComments)
                                                    )
                                        )
                            )
                    ]
            )


privacy : P.Parser E.Exposing Src.Privacy
privacy =
    P.oneOfWithFallback
        [ P.word1 '(' E.ExposingTypePrivacy
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.ExposingSpace E.ExposingTypePrivacy)
            |> P.andThen (\_ -> P.getPosition)
            |> P.andThen
                (\start ->
                    P.word2 '.' '.' E.ExposingTypePrivacy
                        |> P.andThen (\_ -> P.getPosition)
                        |> P.andThen
                            (\end ->
                                Space.chompAndCheckIndent E.ExposingSpace E.ExposingTypePrivacy
                                    |> P.andThen (\_ -> P.word1 ')' E.ExposingTypePrivacy)
                                    |> P.map (\_ -> Src.Public (A.Region start end))
                            )
                )
        ]
        Src.Private
