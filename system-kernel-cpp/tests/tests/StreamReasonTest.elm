module StreamReasonTest exposing (suite)

{-| Tests how a stream kernel's cancellation reason is read (`Stream.Internal.decodeReason`) and
written for a resource failure (`Stream.Internal.encodeFailure`), the wire form the C++ and JS
kernels share (eco-system/Core/Core.hpp, failureReason; plans/eco-system-typed-api.md B7).

What the tests establish:

  - `"\u{0001}origin\u{001F}code\u{001F}message"` is a failure with those three parts, and a
    message may itself contain U+001F.
  - A reason starting with U+0002 means the stream had ended, whatever follows.
  - Any other reason, including the empty one and one that only contains the markers later, is a
    program's own reason, kept as it is.
  - `encodeFailure` writes what `decodeReason` reads back.

-}

import Expect
import Stream.Internal as Internal exposing (Reason(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Stream.Internal reasons"
        [ test "a marked failure has its origin, code and message" <|
            \_ ->
                Internal.decodeReason "\u{0001}socket\u{001F}ECONNRESET\u{001F}read ECONNRESET"
                    |> Expect.equal (FailureReason (Internal.failure "socket" "ECONNRESET" "read ECONNRESET"))
        , test "a failure's message may contain the separator" <|
            \_ ->
                Internal.decodeReason "\u{0001}codec\u{001F}\u{001F}a\u{001F}b"
                    |> Expect.equal (FailureReason (Internal.failure "codec" "" "a\u{001F}b"))
        , test "U+0002 means the stream had ended" <|
            \_ ->
                Internal.decodeReason "\u{0002}WritableStream is closed"
                    |> Expect.equal EndedReason
        , test "a program's reason is kept as it is" <|
            \_ ->
                Internal.decodeReason "stop now"
                    |> Expect.equal (ProgramReason "stop now")
        , test "the empty reason is a program's" <|
            \_ ->
                Internal.decodeReason ""
                    |> Expect.equal (ProgramReason "")
        , test "a marker later in the text does not count" <|
            \_ ->
                Internal.decodeReason "x\u{0001}socket"
                    |> Expect.equal (ProgramReason "x\u{0001}socket")
        , test "encodeFailure round-trips through decodeReason" <|
            \_ ->
                let
                    f =
                        Internal.failure "websocket" "ERR_WS_PROTOCOL" "ERR_WS_PROTOCOL: bad frame"
                in
                Internal.decodeReason (Internal.encodeFailure f)
                    |> Expect.equal (FailureReason f)
        ]
