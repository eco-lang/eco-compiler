module Common.Format.Cheapskate.Inlines exposing (pHtmlTag, pLinkLabel, pReference, parseInlines)

{-| The formatter re-prints the Markdown in doc comments, and this module reads
the text of a Markdown block, such as a paragraph or a heading, into the inline
elements of `Common.Format.Cheapskate.Types`: text, spaces and line breaks,
emphasis, code spans, links, images, entities and raw HTML. It also exposes three of its
parsers on their own: for a link label, a link reference definition and an HTML
tag.

`parseInlines` never fails. At each point in the text it tries a fixed list of
alternatives, and the first that succeeds wins, so the order of the list is the
precedence between constructs:

1.  a run of ASCII letters and digits, which starts a bare URI instead when it
    is a known scheme name followed by `:`;
2.  a run of whitespace;
3.  emphasis with `*`, then emphasis with `_`, the latter only when the
    character before it is not an ASCII letter or digit;
4.  a code span;
5.  a link, then an image;
6.  an HTML tag or comment, then an autolink in angle brackets;
7.  an entity;
8.  any one character, as text.

A failed alternative is undone, as `Common.Format.Cheapskate.ParserCombinators`
describes for `oneOf`, so a code span, link label or HTML tag left unclosed
falls through to the next alternative. Emphasis is different: once its run of
markers is read it does not fail, and emphasis left unclosed comes back as its
markers as text, followed by the inlines read after them.

A link written with a label, `[text][label]` or `[text]`, keeps the label as
its `Ref` target and is not looked up: the `ReferenceMap` given to
`parseInlines` is passed along but never read. Every bracketed label that
`pLinkLabel` can read becomes a link, whether or not a definition exists for
it.

Outside code spans, bare URIs, autolinks and raw HTML, a backslash before an
escapable character, as `Common.Format.Cheapskate.Util.isEscapable` defines
them, is dropped and the character kept. The text of a link is the exception:
`pLinkLabel` drops such backslashes and the result is then read again as
inlines, so in `[a\*b*](u)` the escaped `*` opens emphasis, and in
`[a\\*b](u)` both backslashes are lost. In text, a backslash before a line
feed is a hard line break.

Some input is read differently from common Markdown. An HTML tag is recognised
only when no space comes between its `<` and its `>` outside a quoted value,
so `<a href="x">` and `<br />` are text. A bare URI that ends in `.`, `;`, `?`,
`!`, `:` or `,` keeps that character in the link and also has it again as text
after the link. An inline link fails when a space comes between its URL or
title and its closing `)`, and a link title ends at its first closing quote
even when a letter follows, so `'don't'` cannot be a title.

@docs pHtmlTag, pLinkLabel, pReference, parseInlines

-}

import Common.Format.Cheapskate.ParserCombinators
    exposing
        ( Parser
        , andThen
        , anyChar
        , char
        , endOfInput
        , fail
        , guard
        , lazy
        , leftSequence
        , many
        , manyTill
        , map
        , mzero
        , notAfter
        , notInClass
        , oneOf
        , option
        , parse
        , peekChar
        , return
        , satisfy
        , scan
        , showParseError
        , skip
        , string
        , takeTill
        , takeWhile
        , takeWhile1
        )
import Common.Format.Cheapskate.Types exposing (HtmlTagType(..), Inline(..), Inlines, LinkTarget(..), ReferenceMap)
import Common.Format.Cheapskate.Util exposing (isEscapable, isWhitespace, nfb, nfbChar, scanSpaces, scanSpnl)
import Set exposing (Set)
import Utils.Crash exposing (crash)


{-| A parser for one HTML tag, returning its kind and its text exactly as
written.

A tag is `<`, an optional `/`, a name made of ASCII letters, digits, `?` and
`!`, any attributes, then any tabs, carriage returns, line feeds and `/`s, and
`>`. Each attribute may be preceded by tabs, carriage returns or line feeds,
but not by spaces, and is a name starting with an ASCII letter, then `=`, then
a value: a quoted string, a run of ASCII letters and digits, or nothing. So a
tag with a space before an attribute or before `/>`, such as `<a href="x">` or
`<br />`, is not read as a tag. A `>` inside a quoted value does not end the
tag.

The kind is `Closing` when the tag starts with `</`. Otherwise it is
`SelfClosing` when the characters just before `>` end with `/`, and `Opening`
when they do not. The kind carries the name in lower case.

-}
pHtmlTag : Parser ( HtmlTagType, String )
pHtmlTag =
    char '<'
        |> andThen
            (\_ ->
                oneOf (char '/' |> map (\_ -> True)) (return False)
                    |> andThen
                        (\closing ->
                            takeWhile1 (\c -> isAsciiAlphaNum c || c == '?' || c == '!')
                                |> andThen
                                    (\tagname ->
                                        let
                                            tagname_ : String
                                            tagname_ =
                                                String.toLower tagname

                                            attr : Parser String
                                            attr =
                                                takeWhile isSpace
                                                    |> andThen
                                                        (\ss ->
                                                            satisfy Char.isAlpha
                                                                |> andThen
                                                                    (\x ->
                                                                        takeWhile (\c -> isAsciiAlphaNum c || c == ':')
                                                                            |> andThen
                                                                                (\xs ->
                                                                                    skip ((==) '=')
                                                                                        |> andThen (\_ -> oneOf (pQuoted '"') (oneOf (pQuoted '\'') (oneOf (takeWhile1 Char.isAlphaNum) (return ""))))
                                                                                        |> map
                                                                                            (\v ->
                                                                                                ss ++ String.fromChar x ++ xs ++ "=" ++ v
                                                                                            )
                                                                                )
                                                                    )
                                                        )
                                        in
                                        many attr
                                            |> map String.concat
                                            |> andThen
                                                (\attrs ->
                                                    takeWhile (\c -> isSpace c || c == '/')
                                                        |> andThen
                                                            (\final ->
                                                                char '>'
                                                                    |> andThen
                                                                        (\_ ->
                                                                            let
                                                                                tagtype : HtmlTagType
                                                                                tagtype =
                                                                                    if closing then
                                                                                        Closing tagname_

                                                                                    else
                                                                                        case stringStripSuffix "/" final of
                                                                                            Just _ ->
                                                                                                SelfClosing tagname_

                                                                                            Nothing ->
                                                                                                Opening tagname_
                                                                            in
                                                                            return
                                                                                ( tagtype
                                                                                , String.fromList
                                                                                    ('<'
                                                                                        :: (if closing then
                                                                                                [ '/' ]

                                                                                            else
                                                                                                []
                                                                                           )
                                                                                    )
                                                                                    ++ tagname
                                                                                    ++ attrs
                                                                                    ++ final
                                                                                    ++ ">"
                                                                                )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


{-| Tests whether `c` is a tab, a line feed or a carriage return. The space
character is not included, which is why `pHtmlTag` accepts no space between
attributes.
-}
isSpace : Char -> Bool
isSpace c =
    c == '\t' || c == '\n' || c == '\u{000D}'


{-| Returns `t` without the suffix `p` when `t` ends with `p`, and `Nothing`
when it does not.
-}
stringStripSuffix : String -> String -> Maybe String
stringStripSuffix p t =
    if String.endsWith p t then
        Just (String.dropRight (String.length p) t)

    else
        Nothing


{-| Produces a parser for a value enclosed in the quote character `c`,
returning the value with its quotes. Everything up to the next `c`, line
breaks included, is part of the value; there is no escaping.
-}
pQuoted : Char -> Parser String
pQuoted c =
    skip ((==) c)
        |> andThen (\_ -> takeTill ((==) c))
        |> andThen
            (\contents ->
                skip ((==) c)
                    |> map (\_ -> String.fromChar c ++ contents ++ String.fromChar c)
            )


{-| A parser for an HTML comment, from `<!--` to the first `-->`, returning its
text exactly as written. Anything may come between the two, `--` and line
breaks included. Without a `-->` it fails.
-}
pHtmlComment : Parser String
pHtmlComment =
    string "<!--"
        |> andThen (\_ -> manyTill anyChar (string "-->"))
        |> andThen (\rest -> return ("<!--" ++ String.fromList rest ++ "-->"))


{-| A parser for a link label in square brackets, returning the text between
the brackets.

A code span inside the label is read whole, backticks included, so a `]`
within it does not end the label. A bracketed part is read as a nested label
and kept with its brackets. Emphasis markers are ordinary characters here, so
in `[a *b](/url) c*` the label is `a *b`.

A backslash before an escapable character is dropped and the character kept;
before any other character it makes the parse fail. The parse also fails when
the label, a bracketed part of it or a code span in it is not closed.

-}
pLinkLabel : Parser String
pLinkLabel =
    let
        regChunk : Parser String
        regChunk =
            takeWhile1 (\c -> c /= '`' && c /= '[' && c /= ']' && c /= '\\')

        codeChunk : Parser String
        codeChunk =
            map Tuple.second pCode_

        bracketed : Parser String
        bracketed =
            lazy (\() -> pLinkLabel)
                |> map inBrackets

        inBrackets : String -> String
        inBrackets t =
            "[" ++ t ++ "]"
    in
    char '['
        |> andThen
            (\_ ->
                map String.concat
                    (manyTill (oneOf regChunk (oneOf pEscaped (oneOf bracketed codeChunk))) (char ']'))
            )


{-| A parser for the URL of an inline link or a reference definition, returning
it without any angle brackets.

A URL that starts with `<` runs to the next unescaped `>` and may contain
spaces but no line break. Without the `>` the parse fails, as it does at a
backslash before a character that cannot be escaped.

Any other URL is the longest run that contains no space or line feed and in
which unescaped parentheses are balanced, so it stops before a `)` with no `(`
to close and before a `(` that is never closed. It may be empty, and a
backslash before a character that cannot be escaped ends it.

In both forms a backslash before an escapable character is dropped.

-}
pLinkUrl : Parser String
pLinkUrl =
    oneOf (char '<' |> andThen (\_ -> return True)) (return False)
        |> andThen
            (\inPointy ->
                if inPointy then
                    manyTill (pSatisfy (\c -> c /= '\u{000D}' && c /= '\n')) (char '>')
                        |> map String.fromList

                else
                    let
                        regChunk : Parser String
                        regChunk =
                            oneOf (takeWhile1 (notInClass " \n()\\")) pEscaped

                        parenChunk : () -> Parser String
                        parenChunk () =
                            char '('
                                |> andThen (\_ -> manyTill (oneOf regChunk (lazy parenChunk)) (char ')'))
                                |> map (parenthesize << String.concat)

                        parenthesize : String -> String
                        parenthesize x =
                            "(" ++ x ++ ")"
                    in
                    map String.concat (many (oneOf regChunk (parenChunk ())))
            )


{-| A parser for a link title in double quotes, single quotes or parentheses,
returning the text between the delimiters.

The character after the opening delimiter must be present and must not be
whitespace or `)`. The title ends at the first closing delimiter, whatever
follows it, so it can contain its own closing delimiter only escaped. A
backslash before an escapable character is dropped, and before any other
character it makes the parse fail.

`pEnder` tests that the delimiter itself, not the character after it, is not a
letter or digit, so the test always passes, and `nestedChunk` never succeeds.

-}
pLinkTitle : Parser String
pLinkTitle =
    satisfy (\c -> c == '"' || c == '\'' || c == '(')
        |> andThen
            (\c ->
                peekChar
                    |> andThen
                        (\next ->
                            case next of
                                Nothing ->
                                    mzero

                                Just x ->
                                    if isWhitespace x then
                                        mzero

                                    else if x == ')' then
                                        mzero

                                    else
                                        return ()
                        )
                    |> andThen
                        (\_ ->
                            let
                                ender : Char
                                ender =
                                    if c == '(' then
                                        ')'

                                    else
                                        c

                                pEnder : Parser Char
                                pEnder =
                                    skip Char.isAlphaNum |> nfb |> andThen (\_ -> char ender)

                                regChunk : Parser String
                                regChunk =
                                    oneOf (takeWhile1 (\x -> x /= ender && x /= '\\')) pEscaped

                                nestedChunk : Parser String
                                nestedChunk =
                                    lazy (\() -> pLinkTitle)
                                        |> map (\x -> String.fromChar c ++ x ++ String.fromChar ender)
                            in
                            map String.concat (manyTill (oneOf regChunk nestedChunk) pEnder)
                        )
            )


{-| A parser for a link reference definition, `[label]: url "title"`, returning
the label, the URL and the title, which is `""` when there is none.

The whole input must be the definition: it must start with `[`, and nothing may
follow the definition, not even a space. Spaces and at most one line break may
come between the `:` and the URL, and between the URL and the title. The URL
may be empty, and may be written in angle brackets, which are not kept. A
backslash before an escapable character is dropped from all three parts, as in
`pLinkLabel`.

-}
pReference : Parser ( String, String, String )
pReference =
    pLinkLabel
        |> andThen
            (\lab ->
                char ':'
                    |> andThen (\_ -> scanSpnl)
                    |> andThen (\_ -> pLinkUrl)
                    |> andThen
                        (\url ->
                            option "" (scanSpnl |> andThen (\_ -> pLinkTitle))
                                |> andThen
                                    (\tit ->
                                        endOfInput
                                            |> map (\_ -> ( lab, url, tit ))
                                    )
                        )
            )


{-| A parser for a backslash followed by an escapable character, returning the
character without the backslash. It fails when the character after the
backslash cannot be escaped.
-}
pEscaped : Parser String
pEscaped =
    map String.fromChar (skip ((==) '\\') |> andThen (\_ -> satisfy isEscapable))


{-| Produces a parser for one character that satisfies `p`, written either as
itself or after a backslash, and returns the character. A backslash is
accepted only before an escapable character that satisfies `p`, and is not
kept.
-}
pSatisfy : (Char -> Bool) -> Parser Char
pSatisfy p =
    oneOf (satisfy (\c -> c /= '\\' && p c))
        (char '\\' |> andThen (\_ -> satisfy (\c -> isEscapable c && p c)))


{-| Returns the inline elements of the text `t`.

Any text can be read, so this never fails. `remap` is not consulted: a
reference link keeps its label as its target.

-}
parseInlines : ReferenceMap -> String -> Inlines
parseInlines remap t =
    case parse (map List.concat (leftSequence (many (pInline remap)) endOfInput)) t of
        Err e ->
            -- Unreachable: pInline fails only at the end of the input.
            crash ("parseInlines: " ++ showParseError e)

        Ok r ->
            r


{-| Produces a parser for the inline elements at the current point: one
construct, or a piece of text. It tries the alternatives in the order the module
docstring lists, and takes the first that succeeds.

The last alternative accepts any character, so this fails only at the end of
the input, and when it succeeds it has consumed something.

-}
pInline : ReferenceMap -> Parser Inlines
pInline remap =
    oneOf pAsciiStr
        (oneOf pSpace
            (oneOf (pEnclosure '*' remap)
                (oneOf (notAfter Char.isAlphaNum |> andThen (\_ -> pEnclosure '_' remap))
                    (oneOf pCode
                        (oneOf (pLink remap)
                            (oneOf (pImage remap)
                                (oneOf pRawHtml
                                    (oneOf pAutolink
                                        (oneOf pEntity pSym)
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )


{-| A parser for a run of whitespace, returning one inline for the whole run:
`Space` when the run holds no line feed, `LineBreak` when it holds one and
starts with two spaces, and `SoftBreak` otherwise.
-}
pSpace : Parser Inlines
pSpace =
    takeWhile1 isWhitespace
        |> andThen
            (\ss ->
                return
                    (List.singleton
                        (if String.any ((==) '\n') ss then
                            if String.startsWith "  " ss then
                                LineBreak

                            else
                                SoftBreak

                         else
                            Space
                        )
                    )
            )


{-| Tests whether `c` is an ASCII letter or digit.
-}
isAsciiAlphaNum : Char -> Bool
isAsciiAlphaNum c =
    (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')


{-| A parser for a run of ASCII letters and digits, returned as text, unless
the run is a name in `schemeSet` followed by `:`, in which case it reads the
rest of a bare URI as `pUri` does.

Only scheme names made of letters and digits can match, since the run stops
at any other character. When the `:` is not followed by anything a URI may
contain, the whole parse fails and the run is left to the other alternatives,
which read it as text.

-}
pAsciiStr : Parser Inlines
pAsciiStr =
    takeWhile1 isAsciiAlphaNum
        |> andThen
            (\t ->
                peekChar
                    |> andThen
                        (\mbc ->
                            case mbc of
                                Just ':' ->
                                    if Set.member t schemeSet then
                                        pUri t

                                    else
                                        return (List.singleton (Str t))

                                _ ->
                                    return (List.singleton (Str t))
                        )
            )


{-| A parser for any one character as text, the alternative of last resort.

A backslash before an escapable character gives that character without the
backslash, and a backslash before a line feed gives `LineBreak`, consuming
both. Any other backslash is text. It fails only at the end of the input.

-}
pSym : Parser Inlines
pSym =
    anyChar
        |> andThen
            (\c ->
                let
                    ch : Char -> List Inline
                    ch =
                        String.fromChar >> Str >> List.singleton
                in
                if c == '\\' then
                    oneOf (map ch (satisfy isEscapable))
                        (oneOf (map (\_ -> List.singleton LineBreak) (satisfy ((==) '\n')))
                            (return (ch '\\'))
                        )

                else
                    return (ch c)
            )


{-| The URI scheme names this module recognises at the start of an autolink
and, when made only of letters and digits, at the start of a bare URI, all in
lower case.
-}
schemes : List String
schemes =
    [ -- unofficial
      "coap"
    , "doi"
    , "javascript"

    -- official
    , "aaa"
    , "aaas"
    , "about"
    , "acap"
    , "cap"
    , "cid"
    , "crid"
    , "data"
    , "dav"
    , "dict"
    , "dns"
    , "file"
    , "ftp"
    , "geo"
    , "go"
    , "gopher"
    , "h323"
    , "http"
    , "https"
    , "iax"
    , "icap"
    , "im"
    , "imap"
    , "info"
    , "ipp"
    , "iris"
    , "iris.beep"
    , "iris.xpc"
    , "iris.xpcs"
    , "iris.lwz"
    , "ldap"
    , "mailto"
    , "mid"
    , "msrp"
    , "msrps"
    , "mtqp"
    , "mupdate"
    , "news"
    , "nfs"
    , "ni"
    , "nih"
    , "nntp"
    , "opaquelocktoken"
    , "pop"
    , "pres"
    , "rtsp"
    , "service"
    , "session"
    , "shttp"
    , "sieve"
    , "sip"
    , "sips"
    , "sms"
    , "snmp"
    , "soap.beep"
    , "soap.beeps"
    , "tag"
    , "tel"
    , "telnet"
    , "tftp"
    , "thismessage"
    , "tn3270"
    , "tip"
    , "tv"
    , "urn"
    , "vemmi"
    , "ws"
    , "wss"
    , "xcon"
    , "xcon-userid"
    , "xmlrpc.beep"
    , "xmlrpc.beeps"
    , "xmpp"
    , "z39.50r"
    , "z39.50s"

    -- provisional
    , "adiumxtra"
    , "afp"
    , "afs"
    , "aim"
    , "apt"
    , "attachment"
    , "aw"
    , "beshare"
    , "bitcoin"
    , "bolo"
    , "callto"
    , "chrome"
    , "chrome-extension"
    , "com-eventbrite-attendee"
    , "content"
    , "cvs"
    , "dlna-playsingle"
    , "dlna-playcontainer"
    , "dtn"
    , "dvb"
    , "ed2k"
    , "facetime"
    , "feed"
    , "finger"
    , "fish"
    , "gg"
    , "git"
    , "gizmoproject"
    , "gtalk"
    , "hcp"
    , "icon"
    , "ipn"
    , "irc"
    , "irc6"
    , "ircs"
    , "itms"
    , "jar"
    , "jms"
    , "keyparc"
    , "lastfm"
    , "ldaps"
    , "magnet"
    , "maps"
    , "market"
    , "message"
    , "mms"
    , "ms-help"
    , "msnim"
    , "mumble"
    , "mvn"
    , "notes"
    , "oid"
    , "palm"
    , "paparazzi"
    , "platform"
    , "proxy"
    , "psyc"
    , "query"
    , "res"
    , "resource"
    , "rmi"
    , "rsync"
    , "rtmp"
    , "secondlife"
    , "sftp"
    , "sgn"
    , "skype"
    , "smb"
    , "soldat"
    , "spotify"
    , "ssh"
    , "steam"
    , "svn"
    , "teamspeak"
    , "things"
    , "udp"
    , "unreal"
    , "ut2004"
    , "ventrilo"
    , "view-source"
    , "webcal"
    , "wtai"
    , "wyciwyg"
    , "xfire"
    , "xri"
    , "ymsgr"
    ]


{-| The names in `schemes`, each both as listed and wholly in upper case. A
name in mixed case, such as `Http`, is not in the set.
-}
schemeSet : Set String
schemeSet =
    Set.fromList (schemes ++ List.map String.toUpper schemes)


{-| Produces a parser for the rest of a bare URI whose scheme name `scheme` has
already been read, starting at its `:`. It returns a link to the whole URI with
the URI as its text, as `autoLink` builds it.

The URI runs until whitespace or a `)` that closes no `(` opened within it, and
must have at least one character after the `:`. When its last character is one
of `.`, `;`, `?`, `!`, `:` and `,`, that character stays in the link and is also
returned as text after it.

-}
pUri : String -> Parser Inlines
pUri scheme =
    char ':'
        |> andThen (\_ -> scan (OpenParens 0) uriScanner)
        |> andThen
            (\x ->
                guard (not (String.isEmpty x))
                    |> andThen
                        (\_ ->
                            let
                                ( rawuri, endingpunct ) =
                                    case String.uncons (String.reverse x) of
                                        Just ( c, _ ) ->
                                            if String.contains (String.fromChar c) ".;?!:," then
                                                ( scheme ++ ":" ++ x, [ Str (String.fromChar c) ] )

                                            else
                                                ( scheme ++ ":" ++ x, [] )

                                        _ ->
                                            ( scheme ++ ":" ++ x, [] )
                            in
                            return (autoLink rawuri ++ endingpunct)
                        )
            )


{-| The state of the scan over a bare URI: how many `(` the URI has opened and
not yet closed.

It lets a URI include balanced parentheses, as in
`http://example.com/Foo_(bar)`, while a `)` with no `(` to close, as in
`(see http://example.com)`, ends the URI.

-}
type OpenParens
    = OpenParens Int


{-| Returns the scan state after accepting `c` into a bare URI, or `Nothing`
when `c` ends the URI: a space, tab, carriage return or line feed, or a `)`
with no open `(` to close.
-}
uriScanner : OpenParens -> Char -> Maybe OpenParens
uriScanner st c =
    case ( st, c ) of
        ( _, ' ' ) ->
            Nothing

        ( _, '\n' ) ->
            Nothing

        ( OpenParens n, '(' ) ->
            Just (OpenParens (n + 1))

        ( OpenParens n, ')' ) ->
            if n > 0 then
                Just (OpenParens (n - 1))

            else
                Nothing

        ( _, '+' ) ->
            Just st

        ( _, '/' ) ->
            Just st

        _ ->
            if isSpace c then
                Nothing

            else
                Just st


{-| Produces a parser for text that starts with a run of the emphasis character
`c`, returning emphasis or text.

A run followed by whitespace is returned as text, followed by the whitespace.
Otherwise a run of one opens emphasis, two open strong emphasis and three open
both, as `pOne`, `pTwo` and `pThree` describe, and a run of four or more is
text. Once the run is read this never fails: emphasis that is not closed comes
back as its markers as text, followed by the inlines read after them.

-}
pEnclosure : Char -> ReferenceMap -> Parser Inlines
pEnclosure c remap =
    takeWhile1 ((==) c)
        |> andThen
            (\cs ->
                oneOf
                    (pSpace |> map ((::) (Str cs)))
                    (case String.length cs of
                        3 ->
                            pThree c remap

                        2 ->
                            pTwo c remap []

                        1 ->
                            pOne c remap []

                        _ ->
                            return (List.singleton (Str cs))
                    )
            )


{-| Returns `constructor ils` as a one-element list, or `[]` when `ils` is
empty.
-}
single : (Inlines -> Inline) -> Inlines -> Inlines
single constructor ils =
    if List.isEmpty ils then
        []

    else
        List.singleton (constructor ils)


{-| Produces a parser for the rest of an emphasis opened by one `c`, where
`prefix` holds inlines already read inside it.

It reads inlines until it reaches a `c`, except that `cc` not followed by a
third `c` starts strong emphasis nested inside, read as `pTwo` reads it. At a
closing `c` the result is `Emph` holding `prefix` and what was read. With no
closing `c` it is `c` as text, followed by `prefix` and what was read.

-}
pOne : Char -> ReferenceMap -> Inlines -> Parser Inlines
pOne c remap prefix =
    map List.concat
        (many
            (oneOf (nfbChar c |> andThen (\_ -> pInline remap))
                (string (String.fromList [ c, c ])
                    |> andThen (\_ -> nfbChar c)
                    |> andThen (\_ -> pTwo c remap [])
                )
            )
        )
        |> andThen
            (\contents ->
                oneOf (char c |> andThen (\_ -> return (single Emph (prefix ++ contents))))
                    (return (Str (String.fromChar c) :: (prefix ++ contents)))
            )


{-| Produces a parser for the rest of a strong emphasis opened by `cc`, where
`prefix` holds inlines already read inside it.

It reads inlines until it reaches `cc`; a single `c` before that can open
emphasis nested inside. At `cc` the result is `Strong` holding `prefix` and
what was read. With no `cc` it is `cc` as text, followed by `prefix` and what
was read.

-}
pTwo : Char -> ReferenceMap -> Inlines -> Parser Inlines
pTwo c remap prefix =
    let
        ender : Parser String
        ender =
            string (String.fromList [ c, c ])
    in
    map List.concat (many (nfb ender |> andThen (\_ -> pInline remap)))
        |> andThen
            (\contents ->
                oneOf (ender |> map (\_ -> single Strong (prefix ++ contents)))
                    (return (Str (String.fromList [ c, c ]) :: (prefix ++ contents)))
            )


{-| Produces a parser for the rest of text opened by `ccc`, which closes as
emphasis inside strong emphasis or the other way round.

It reads inlines until it reaches a `c`. At `cc`, what was read becomes
`Strong` and reading goes on as `pOne`, which puts `Emph` around it; at a
single `c`, what was read becomes `Emph` and reading goes on as `pTwo`. With
no `c` the result is `ccc` as text, followed by what was read.

-}
pThree : Char -> ReferenceMap -> Parser Inlines
pThree c remap =
    map List.concat (many (nfbChar c |> andThen (\_ -> pInline remap)))
        |> andThen
            (\contents ->
                oneOf (string (String.fromList [ c, c ]) |> andThen (\_ -> pOne c remap (single Strong contents)))
                    (oneOf (char c |> andThen (\_ -> pTwo c remap (single Emph contents)))
                        (return (Str (String.fromList [ c, c, c ]) :: contents))
                    )
            )


{-| A parser for a code span, returning its `Code` inline.
-}
pCode : Parser Inlines
pCode =
    map Tuple.first pCode_


{-| A parser for a code span, returning both its `Code` inline and its text
exactly as written, backticks included, which is what `pLinkLabel` keeps.

A span opens with a run of backticks and closes at the next run of exactly the
same length. The `Code` holds what lies between, with whitespace trimmed from
both ends. With no closing run the parse fails. In inline text the first
backtick of the run is then read as text, and the rest of the run can open a
shorter span, so ``` ``a` ``` gives a backtick as text and then `Code "a"`.

-}
pCode_ : Parser ( Inlines, String )
pCode_ =
    takeWhile1 ((==) '`')
        |> andThen
            (\ticks ->
                let
                    end : Parser ()
                    end =
                        string ticks |> andThen (\_ -> nfb (char '`'))

                    nonBacktickSpan : Parser String
                    nonBacktickSpan =
                        takeWhile1 ((/=) '`')

                    backtickSpan : Parser String
                    backtickSpan =
                        takeWhile1 ((==) '`')
                in
                manyTill (oneOf nonBacktickSpan backtickSpan) end
                    |> map String.concat
                    |> map
                        (\contents ->
                            ( List.singleton (Code (String.trim contents)), ticks ++ contents ++ ticks )
                        )
            )


{-| Produces a parser for a link, starting at its bracketed label, returning
one `Link`.

The label's text, parsed into inlines, is the link's text. When an inline
target `(url "title")` follows, the link points to that URL; otherwise it is a
reference link, as `pReferenceLink` builds it. Since `pReferenceLink` never
fails, every label that `pLinkLabel` reads becomes a link here, and the
fallback to plain text is never used.

-}
pLink : ReferenceMap -> Parser Inlines
pLink remap =
    pLinkLabel
        |> andThen
            (\lab ->
                let
                    lab_ : Inlines
                    lab_ =
                        parseInlines remap lab
                in
                oneOf (oneOf (pInlineLink lab_) (pReferenceLink lab lab_))
                    (return (Str "[" :: lab_ ++ [ Str "]" ]))
            )


{-| Produces a parser for the target of an inline link, `(url "title")`,
returning the link with `lab` as its text.

Spaces may follow the `(`, and spaces with at most one line break may come
before the title, which is optional and `""` when absent. Nothing may come
between the URL or the title and the `)`: a space there makes the parse fail.

-}
pInlineLink : Inlines -> Parser Inlines
pInlineLink lab =
    char '('
        |> andThen
            (\_ ->
                scanSpaces
                    |> andThen (\_ -> pLinkUrl)
                    |> andThen
                        (\url ->
                            option "" (scanSpnl |> andThen (\_ -> andThen (\_ -> pLinkTitle) scanSpaces))
                                |> andThen
                                    (\tit ->
                                        char ')'
                                            |> map (\_ -> [ Link lab (Url url) tit ])
                                    )
                        )
            )


{-| Produces a parser for the rest of a reference link whose label `rawlab` has
been read, returning the link with `lab` as its text and a `Ref` target.

When a second label follows, after spaces and at most one line break, as in
`[text][label]` or `[text] [label]`, the target is that label, and it is `""`
for `[text][]`. Otherwise the target is `rawlab`. It never fails, and the
reference map is ignored.

-}
pReferenceLink : String -> Inlines -> Parser Inlines
pReferenceLink rawlab lab =
    option rawlab (scanSpnl |> andThen (\_ -> pLinkLabel))
        |> map (\ref -> [ Link lab (Ref ref) "" ])


{-| Produces a parser for text starting with `!`. Followed by a link with an
inline target, the `!` makes it an `Image`. Otherwise the `!` is text, followed
by any link that comes after it, so `![text][label]` is text and a reference
link, not an image.
-}
pImage : ReferenceMap -> Parser Inlines
pImage remap =
    char '!'
        |> andThen
            (\_ ->
                oneOf (map linkToImage (pLink remap)) (return [ Str "!" ])
            )


{-| Returns the image made from `ils` when it is a single link with a URL
target, and otherwise `ils` with `!` as text in front of it.
-}
linkToImage : Inlines -> Inlines
linkToImage ils =
    case ils of
        (Link lab (Url url) tit) :: [] ->
            [ Image lab url tit ]

        _ ->
            Str "!" :: ils


{-| A parser for an HTML entity, `&name;`, `&#digits;` or `&#xhex;`, returning
it as an `Entity` holding its text as written.

A name is not checked against any list of entities, so `&foo;` is accepted,
but it must be made of ASCII letters only, so `&frac12;` is not. A `&` that
begins none of these forms makes the parse fail.

-}
pEntity : Parser Inlines
pEntity =
    char '&'
        |> andThen (\_ -> oneOf pCharEntity (oneOf pDecEntity pHexEntity))
        |> andThen
            (\res ->
                char ';'
                    |> andThen (\_ -> return (List.singleton (Entity ("&" ++ res ++ ";"))))
            )


{-| A parser for the name of a named entity: one or more ASCII letters.
-}
pCharEntity : Parser String
pCharEntity =
    takeWhile1 (\c -> Char.isAlpha c)


{-| A parser for the `#` and the decimal digits of a numeric character
reference, returned as written.
-}
pDecEntity : Parser String
pDecEntity =
    char '#'
        |> andThen (\_ -> takeWhile1 Char.isDigit)
        |> andThen (\res -> return ("#" ++ res))


{-| A parser for the `#`, the `x` or `X` and the hexadecimal digits of a
hexadecimal character reference, returned as written.
-}
pHexEntity : Parser String
pHexEntity =
    char '#'
        |> andThen (\_ -> oneOf (char 'X') (char 'x'))
        |> andThen
            (\x ->
                takeWhile1 Char.isHexDigit
                    |> andThen
                        (\res ->
                            return ("#" ++ String.fromChar x ++ res)
                        )
            )


{-| A parser for an HTML tag, as `pHtmlTag` reads one, or an HTML comment,
returned as `RawHtml` holding its text as written.
-}
pRawHtml : Parser Inlines
pRawHtml =
    map (List.singleton << RawHtml) (oneOf (map Tuple.second pHtmlTag) pHtmlComment)


{-| A parser for an autolink in angle brackets, returning a link whose text is
what lies between the brackets.

The text after the `<` is split at its first `:` or `@`, which must not be its
first character. The part before it may contain spaces and even a `>`, so
`<x y> a@b>` is one e-mail link. At an `@` it is an e-mail address, whatever
comes before, and the link points to `mailto:` followed by the address. At a
`:` the part before must be a name in `schemeSet`, and the link points to the
whole text. The part
from the `:` or `@` to the closing `>` may not contain a space. Anything else
in angle brackets makes the parse fail.

-}
pAutolink : Parser Inlines
pAutolink =
    skip ((==) '<')
        |> andThen (\_ -> takeWhile1 (\c -> c /= ':' && c /= '@'))
        |> andThen
            (\s ->
                takeWhile1 (\c -> c /= '>' && c /= ' ')
                    |> andThen
                        (\rest ->
                            skip ((==) '>')
                                |> andThen
                                    (\_ ->
                                        if String.startsWith "@" rest then
                                            return (emailLink (s ++ rest))

                                        else if Set.member s schemeSet then
                                            return (autoLink (s ++ rest))

                                        else
                                            fail "Unknown contents of <>"
                                    )
                        )
            )


{-| Returns a link to the URL `t` whose text is `t`, with each entity in `t`,
such as `&amp;`, kept as an `Entity` and the rest as text.
-}
autoLink : String -> Inlines
autoLink t =
    let
        toInlines : String -> Inlines
        toInlines t_ =
            case parse pToInlines t_ of
                Ok r ->
                    r

                Err e ->
                    ("autolink: " ++ showParseError e) |> crash

        pToInlines : Parser Inlines
        pToInlines =
            map List.concat (many strOrEntity)

        strOrEntity : Parser Inlines
        strOrEntity =
            oneOf (map (List.singleton << Str) (takeWhile1 ((/=) '&')))
                (oneOf pEntity (map (List.singleton << Str) (string "&")))
    in
    Link (toInlines t) (Url t) "" |> List.singleton


{-| Returns a link to `mailto:` followed by the address `t`, with `t` as its
text.
-}
emailLink : String -> Inlines
emailLink t =
    [ Link [ Str t ] (Url ("mailto:" ++ t)) "" ]
