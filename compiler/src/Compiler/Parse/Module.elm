module Compiler.Parse.Module exposing
    ( fromByteString
    , Module, Header, ProjectType(..), Effects(..)
    , chompModule, chompImports
    , isKernel
    )

{-| Turns the text of one `.elm` file into a `Src.Module`, and decides
whether the file may use ports or be an effect module.

Parsing comes first and keeps every comment. `chompModule` reads the file into
a `Module`: the module header if there is one, then the imports, then (for a
kernel project only) `infix` declarations, then one or more top-level
declarations, each starting in column 1. A header is one of `module`,
`port module` or `effect module ... where { command = X, subscription = Y }`,
each with a name and an `exposing` list, and may be followed by the module doc
comment. A file with no header is accepted too.

Checking comes second. `fromByteString` runs the parser and then sorts the
declarations into values, custom types, type aliases and ports, collects the
doc comments, and applies the rules about effects, which depend on the
`ProjectType`:

  - A module with a plain `module` header may not declare ports.
  - A `port module` is refused in a package, and elsewhere must declare at
    least one port.
  - An `effect module` is allowed only in a kernel project, and may not
    declare ports.
  - A file with no header is not checked: its ports, if any, become its
    effects.

A _kernel project_ is a package, or a kernel application, whose name
`Pkg.isKernel` accepts. A _kernel application_ is an application compiled as
though it were that package.

The checked `Src.Module` keeps no comments outside the declarations, imports
and expressions themselves, so a client that needs those (a formatter) uses the
`Module` record from `chompModule` instead.

Every list in the checked module that is built here comes out in reverse source
order: the values, custom types, type aliases, ports, infixes and doc comments.
The imports are the default imports, unless the package is `elm/core`, in
reverse order, followed by the file's own imports in source order.


# Parsing Entry Point

@docs fromByteString


# Module Structure

@docs Module, Header, ProjectType, Effects


# Parsers

@docs chompModule, chompImports


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
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E



-- ====== Parsing Entry Point ======


{-| Parses and checks the whole of `source` as a module of a project of
`projectType`.

The error is `E.ParseError` when the text does not parse, including when text
is left over after the last declaration it could read. Otherwise it is the
error for the effect rule the module breaks.

-}
fromByteString : ProjectType -> String -> Result E.Error Src.Module
fromByteString projectType source =
    case P.fromByteString (chompModule projectType) E.ModuleBadEnd source of
        Ok modul ->
            checkModule projectType modul

        Err err ->
            Err (E.ParseError err)



-- ====== Project Type ======


{-| The kind of project a module belongs to, which decides which module-level
features it may use.

`Package` names the package being compiled. A package may not declare ports
or be a port module. When the package is `elm/core`, its modules get no
default imports.

`Application` is an ordinary application.

`KernelApplication` is an application compiled as though it were the named
package. When `Pkg.isKernel` accepts that name it may, like a kernel package,
declare `infix` operators and be an effect module, while ports follow the
application rules.

Every other project type gets the default imports, and a project that
`isKernel` rejects may not declare infixes or effect modules.

-}
type ProjectType
    = Package Pkg.Name
    | Application
    | KernelApplication Pkg.Name


{-| Tells whether the project is the `elm/core` package, whose modules get no
default imports.
-}
isCore : ProjectType -> Bool
isCore projectType =
    case projectType of
        Package pkg ->
            pkg == Pkg.core

        Application ->
            False

        KernelApplication _ ->
            False


{-| Tells whether the project is a kernel project: a package or a kernel
application whose name `Pkg.isKernel` accepts.

Only a kernel project may declare `infix` operators or be an effect module.

-}
isKernel : ProjectType -> Bool
isKernel projectType =
    case projectType of
        Package pkg ->
            Pkg.isKernel pkg

        Application ->
            False

        KernelApplication pkg ->
            Pkg.isKernel pkg



-- ====== Module Parsing ======


{-| A parsed module before its effects are checked, with every comment
outside the declarations still in place.

`initialComments` are the comments before the header. The comment group in
`imports` is the comments after the header and its doc comment. `imports`
holds the default imports ahead of the file's own, as the module docstring
describes; `infixes` are in reverse source order and `decls` in source order.

-}
type alias Module =
    { initialComments : Src.FComments
    , header : Maybe Header
    , imports : Src.C1 (List (Src.C1 Src.Import))
    , infixes : List (Src.C1 (A.Located Src.Infix))
    , decls : List (Src.C2 Decl.Decl)
    }


{-| Produces a parser for a whole module of a project of `projectType`: an
optional header, the imports, `infix` declarations when the project is a kernel
project, and then at least one declaration.

The imports start from `Imports.defaults` unless the project is `elm/core`. No
effect rule is checked here.

-}
chompModule : ProjectType -> P.Parser E.Module Module
chompModule projectType =
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
                                        P.specialize E.Declarations chompDecls
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



-- ====== CHECK MODULE ======


{-| Builds the `Src.Module` for a parsed module, failing when its effects
break the rules for `projectType`.

Comments outside declarations are dropped, including those attached to each
import and infix. A module without a header gets no name, an `exposing (..)`
placed at `A.one`, docs that are missing at `A.one`, and `Src.Ports` effects
exactly when it declares a port; it cannot fail.

-}
checkModule : ProjectType -> Module -> Result E.Error Src.Module
checkModule projectType module_ =
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
                            { name = Just name
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
                    { name = Nothing
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


{-| Returns the effects of a module with a header, given its declared `ports`,
or the error that the combination of header and `projectType` earns.

A plain module with ports fails with `E.NoPortsInPackage`, naming the first
port in `ports`, in a package, and `E.UnexpectedPort` otherwise. A port module
fails with `E.NoPortModulesInPackage` in a package and with `E.NoPorts` when
it declares none. An effect module fails with `E.NoEffectsOutsideKernel`
outside a kernel project and with `E.UnexpectedPort` when it declares a port.

-}
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

                        KernelApplication _ ->
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

                KernelApplication _ ->
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


{-| Sorts `decls` into values, custom types, type aliases and ports, each
pushed onto the front of its accumulator, so that each list comes out in
reverse order of `decls`.
-}
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



-- ====== TO DOCS ======


{-| Builds the module's docs from the module doc comment, or the region where
it was missing, and the doc comments of `decls`.
-}
toDocs : Result A.Region Src.Comment -> List Decl.Decl -> Src.Docs
toDocs comment decls =
    case comment of
        Ok overview ->
            Src.YesDocs overview (getComments decls [])

        Err region ->
            Src.NoDocs region (getComments decls [])


{-| Pushes the name and doc comment of each of `decls` that has one onto the
front of `comments`, so the declarations' pairs come out in reverse order.
-}
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


{-| Pushes `name` paired with the comment onto `comments` when there is a
comment, and returns `comments` unchanged when there is none.
-}
addComment : Maybe Src.Comment -> A.Located Name.Name -> List ( Name.Name, Src.Comment ) -> List ( Name.Name, Src.Comment )
addComment maybeComment (A.At _ name) comments =
    case maybeComment of
        Just comment ->
            ( name, comment ) :: comments

        Nothing ->
            comments



-- ====== FRESH LINES ======


{-| Produces a parser that reads whitespace and comments and then requires the
next token to start in column 1, failing with `toFreshLineError` otherwise. It
returns the comments read.
-}
freshLine : (Row -> Col -> E.Module) -> P.Parser E.Module Src.FComments
freshLine toFreshLineError =
    Space.chomp E.ModuleSpace
        |> P.andThen
            (\comments ->
                Space.checkFreshLine toFreshLineError
                    |> P.map (\_ -> comments)
            )



-- ====== CHOMP DECLARATIONS ======


{-| A parser for one or more top-level declarations, in source order. Every
declaration after the first must start in column 1; the first needs no check,
because the parser before it has already required one.
-}
chompDecls : P.Parser E.Decl (List (Src.C2 Decl.Decl))
chompDecls =
    Decl.declaration
        |> P.andThen (\( decl, _ ) -> P.loop chompDeclsHelp [ decl ])


{-| One step of `chompDecls`: reads another declaration onto the front of
`decls` when the next line starts in column 1, and otherwise finishes with
`decls` reversed.
-}
chompDeclsHelp : List (Src.C2 Decl.Decl) -> P.Parser E.Decl (P.Step (List (Src.C2 Decl.Decl)) (List (Src.C2 Decl.Decl)))
chompDeclsHelp decls =
    P.oneOfWithFallback
        [ Space.checkFreshLine E.DeclStart
            |> P.andThen
                (\_ ->
                    Decl.declaration
                        |> P.map (\( decl, _ ) -> P.Loop (decl :: decls))
                )
        ]
        (P.Done (List.reverse decls))


{-| Produces a parser that reads `infix` declarations for as long as there are
any, pushing each onto the front of `infixes`, and returns the accumulated list
without reversing it.
-}
chompInfixes : List (Src.C1 (A.Located Src.Infix)) -> P.Parser E.Module (List (Src.C1 (A.Located Src.Infix)))
chompInfixes infixes =
    P.oneOfWithFallback
        [ Decl.infix_
            |> P.andThen (\binop -> chompInfixes (binop :: infixes))
        ]
        infixes



-- ====== MODULE DOC COMMENT ======


{-| A parser for what follows a module header: the comments up to the next line
starting in column 1, and a module doc comment there if there is one.

The result's comments are all those read, before and after the doc comment.
Without a doc comment the result is `Err` of the region of the whitespace that
was read, which is where the doc comment was expected.

-}
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


{-| A module's header: its name, its kind of effects, its `exposing` list and
its module doc comment, with the comments around them.

`docs` is `Err` of the place the doc comment was expected when the header has
none.

-}
type alias Header =
    { name : Src.C2 (A.Located Name.Name)
    , effects : Effects
    , exports : Src.C2 (A.Located Src.Exposing)
    , docs : Result A.Region Src.Comment
    }


{-| Which of the three kinds of header a module has, as written, before the
rules about effects are checked.

Each region runs from the first keyword of the header to the end of its
`module` keyword.

`NoEffects` is a plain `module` header.

`Ports` is a `port module` header, and carries the comments between `port`
and `module`.

`Manager` is an `effect module` header. It carries the comments between
`effect` and `module`, and the `where { ... }` record naming the module's
command type, subscription type, or both, with the comments after `where`.

-}
type Effects
    = NoEffects A.Region
    | Ports A.Region Src.FComments
    | Manager A.Region Src.FComments (Src.C1 Src.Manager)



-- ====== HEADER PARSING HELPERS ======


{-| The error constructors a header parser reports with, which differ between a
plain module header and a port module header.
-}
type alias ModuleErrContext =
    { spaceErr : Row -> Col -> E.Module
    , nameErr : Row -> Col -> E.Module
    , exposingErr : E.Exposing -> Row -> Col -> E.Module
    }


{-| Produces a parser for the part of a plain or port module header after its
`module` keyword: the name, `exposing` and the exposing list, then the comments
and optional doc comment that follow.

`makeEffects` receives `start` and the position after `module`.

-}
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


{-| Assembles a parsed header and the comment groups around its parts into the
result of a header parser.
-}
buildHeader :
    Src.FComments
    -> Src.FComments
    -> A.Located Name.Name
    -> Src.FComments
    -> Src.FComments
    -> A.Located Src.Exposing
    -> Effects
    -> Src.C1 (Result A.Region Src.Comment)
    -> Src.C2 (Maybe Header)
buildHeader initialComments beforeNameComments name afterNameComments afterExportsComments exports effects ( headerComments, docComment ) =
    ( ( initialComments, headerComments )
    , Just <|
        Header
            ( ( beforeNameComments, afterNameComments ), name )
            effects
            ( ( [], afterExportsComments ), exports )
            docComment
    )


{-| A parser for the comments at the top of a file and the module header after
them, if there is one.

The first comment group of the result is the comments before the header, and
the second those after it. With no header the second group is empty and the
header is `Nothing`.

-}
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


{-| Produces a parser for a `module` header starting at `start`.
-}
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


{-| Produces a parser for a `port module` header starting at `start`.
-}
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


{-| Produces a parser for an `effect module` header starting at `start`.
-}
chompEffectModule : Src.FComments -> A.Position -> P.Parser E.Module (Src.C2 (Maybe Header))
chompEffectModule initialComments start =
    Keyword.effect_ E.Effect
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.ModuleSpace E.Effect)
        |> P.andThen
            (\postEffectComments ->
                Keyword.module_ E.Effect
                    |> P.andThen (\_ -> chompEffectModuleBody initialComments start postEffectComments)
            )


{-| Produces a parser for the module name of an effect module header and
everything after it.
-}
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


{-| Produces a parser for the `where { ... }` part of an effect module header
and everything after it.
-}
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


{-| Produces a parser for the `exposing` list of an effect module header and
the comments and optional doc comment that follow it, and builds the header.

Every failure in the list is reported as `E.Effect`.

-}
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


{-| A parser for the `{ ... }` record of an effect module header, which names a
command type, a subscription type, or both in either order. Its comment group
is the comments after the closing brace.
-}
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


{-| A parser for `command = Name` in an effect module header.
-}
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


{-| A parser for `subscription = Name` in an effect module header.
-}
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


{-| A parser for whitespace and comments inside an effect module header, which
fails with `E.Effect` when the next token is in column 1.
-}
spaces_em : P.Parser E.Module Src.FComments
spaces_em =
    Space.chompAndCheckIndent E.ModuleSpace E.Effect



-- ====== Imports ======


{-| Produces a parser that reads import declarations for as long as there are
any, and returns `is` reversed followed by the imports read, in source order.
-}
chompImports : List (Src.C1 Src.Import) -> P.Parser E.Module (List (Src.C1 Src.Import))
chompImports is =
    P.oneOfWithFallback
        [ chompImport
            |> P.andThen (\i -> chompImports (i :: is))
        ]
        (List.reverse is)


{-| A parser for one import declaration: `import`, the module name, an
optional `as` alias and an optional `exposing` list, ending with the next token
in column 1.

The comment group is the comments after the import. An import without an
`exposing` list gets an empty explicit list placed at `A.zero`.

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


{-| Produces a parser for the `as Alias` part of an import of `name` and
whatever follows it.
-}
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


{-| Produces a parser for the `exposing` list of an import of `name` and the
comments after it, up to the next token in column 1.
-}
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



-- ====== LISTING ======


{-| A parser for an exposing list in parentheses: `(..)`, or a comma-separated
list of names.

The region of an explicit list starts just after the `(` and ends just after
the `)`.

-}
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


{-| One step of `exposing_`: reads a comma and another entry onto the front of
`revExposed`, or a `)` that ends the list, which is then put back in source
order and placed from `start`.
-}
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


{-| A parser for one entry of an exposing list: a value, an operator in
parentheses, or a type with its privacy.
-}
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


{-| A parser for what follows a type in an exposing list: `(..)` makes its
constructors public, with the region of the `..`. When the next character is
not `(`, the type is private and nothing is read; a `(` not followed by `..)`
is an error.
-}
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
