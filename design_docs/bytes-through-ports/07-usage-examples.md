# Usage Examples

After applying the compiler modifications, you can use `Bytes.Bytes` in ports.

## Elm Side

### Outgoing Port (Elm → JavaScript)

```elm
port module Ports exposing (..)

import Bytes exposing (Bytes)
import Bytes.Encode as BE


-- Declare an outgoing port that sends Bytes
port sendBytes : Bytes -> Cmd msg


-- Example: Send some bytes to JavaScript
sendSomeBytes : Cmd msg
sendSomeBytes =
    let
        bytes =
            BE.encode
                (BE.sequence
                    [ BE.unsignedInt8 72   -- 'H'
                    , BE.unsignedInt8 105  -- 'i'
                    ]
                )
    in
    sendBytes bytes
```

### Incoming Port (JavaScript → Elm)

```elm
port module Ports exposing (..)

import Bytes exposing (Bytes)
import Bytes.Decode as BD


-- Declare an incoming port that receives Bytes
port receiveBytes : (Bytes -> msg) -> Sub msg


-- Example: Subscription to receive bytes
subscriptions : Model -> Sub Msg
subscriptions model =
    receiveBytes GotBytes


-- In your update function
type Msg
    = GotBytes Bytes


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotBytes bytes ->
            let
                -- Decode the bytes however you need
                length = Bytes.width bytes
            in
            ( { model | bytesReceived = length }, Cmd.none )
```

### Composite Types with Bytes

```elm
port module Ports exposing (..)

import Bytes exposing (Bytes)


-- Bytes in a record
port sendPayload : { id : String, data : Bytes } -> Cmd msg


-- Bytes in a list
port receiveChunks : (List Bytes -> msg) -> Sub msg


-- Bytes in a tuple (via record, since tuples have limited port support)
port sendPair : { first : Bytes, second : Bytes } -> Cmd msg


-- Optional bytes
port sendOptional : Maybe Bytes -> Cmd msg
```

## JavaScript Side

### Receiving Bytes from Elm

```javascript
// Initialize your Elm app
const app = Elm.Main.init({
    node: document.getElementById('elm')
});

// Subscribe to outgoing port
app.ports.sendBytes.subscribe(function(dataView) {
    // dataView is a DataView object
    console.log('Received bytes, length:', dataView.byteLength);

    // Convert to Uint8Array if needed
    const uint8Array = new Uint8Array(
        dataView.buffer,
        dataView.byteOffset,
        dataView.byteLength
    );

    // Example: log the bytes
    console.log('Bytes:', uint8Array);

    // Example: send to WebSocket as binary
    websocket.send(uint8Array);
});
```

### Sending Bytes to Elm

```javascript
// Create bytes to send to Elm
function sendBytesToElm() {
    // Create from ArrayBuffer
    const buffer = new ArrayBuffer(4);
    const dataView = new DataView(buffer);
    dataView.setUint32(0, 12345678, false);  // big-endian

    // Send to Elm
    app.ports.receiveBytes.send(dataView);
}

// Alternative: Create from Uint8Array
function sendUint8ArrayToElm(uint8Array) {
    // Convert Uint8Array to DataView
    const dataView = new DataView(
        uint8Array.buffer,
        uint8Array.byteOffset,
        uint8Array.byteLength
    );

    app.ports.receiveBytes.send(dataView);
}

// Example: Receive binary data from WebSocket
websocket.onmessage = function(event) {
    if (event.data instanceof ArrayBuffer) {
        const dataView = new DataView(event.data);
        app.ports.receiveBytes.send(dataView);
    }
};

// Example: Receive from fetch
async function fetchAndSendToElm(url) {
    const response = await fetch(url);
    const arrayBuffer = await response.arrayBuffer();
    const dataView = new DataView(arrayBuffer);
    app.ports.receiveBytes.send(dataView);
}
```

### Working with Composite Types

```javascript
// Sending a record with bytes
app.ports.sendPayload.subscribe(function(payload) {
    console.log('ID:', payload.id);
    console.log('Data:', payload.data);  // DataView
});

// Receiving a list of bytes
const chunks = [
    new DataView(new ArrayBuffer(100)),
    new DataView(new ArrayBuffer(200)),
    new DataView(new ArrayBuffer(50))
];
app.ports.receiveChunks.send(chunks);

// Optional bytes (Maybe)
app.ports.sendOptional.subscribe(function(maybeBytes) {
    if (maybeBytes === null) {
        console.log('No bytes (Nothing)');
    } else {
        console.log('Got bytes (Just):', maybeBytes);
    }
});
```

## Common Conversions

### DataView ↔ Uint8Array

```javascript
// DataView to Uint8Array
function dataViewToUint8Array(dataView) {
    return new Uint8Array(
        dataView.buffer,
        dataView.byteOffset,
        dataView.byteLength
    );
}

// Uint8Array to DataView
function uint8ArrayToDataView(uint8Array) {
    return new DataView(
        uint8Array.buffer,
        uint8Array.byteOffset,
        uint8Array.byteLength
    );
}
```

### DataView ↔ Base64

```javascript
// DataView to Base64
function dataViewToBase64(dataView) {
    const uint8Array = new Uint8Array(
        dataView.buffer,
        dataView.byteOffset,
        dataView.byteLength
    );
    let binary = '';
    for (let i = 0; i < uint8Array.length; i++) {
        binary += String.fromCharCode(uint8Array[i]);
    }
    return btoa(binary);
}

// Base64 to DataView
function base64ToDataView(base64) {
    const binary = atob(base64);
    const uint8Array = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
        uint8Array[i] = binary.charCodeAt(i);
    }
    return new DataView(uint8Array.buffer);
}
```

### DataView ↔ Hex String

```javascript
// DataView to Hex string
function dataViewToHex(dataView) {
    const uint8Array = new Uint8Array(
        dataView.buffer,
        dataView.byteOffset,
        dataView.byteLength
    );
    return Array.from(uint8Array)
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');
}

// Hex string to DataView
function hexToDataView(hex) {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) {
        bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
    }
    return new DataView(bytes.buffer);
}
```

## Important Notes

1. **Always use DataView**: The Elm `Bytes` type expects a `DataView`, not `Uint8Array` or `ArrayBuffer` directly.

2. **No runtime validation**: The decoder uses `Json.Decode.value`, so if JavaScript sends something other than a `DataView`, errors will occur when Elm tries to use it.

3. **Zero-copy when possible**: The `DataView` is passed by reference, not copied. Be careful not to mutate the underlying `ArrayBuffer` after sending to Elm.

4. **Endianness**: Elm's `Bytes.Decode` functions let you specify endianness. JavaScript's `DataView` also supports both. Make sure they match when encoding/decoding multi-byte values.
