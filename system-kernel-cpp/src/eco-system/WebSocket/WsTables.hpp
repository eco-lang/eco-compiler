//===- WsTables.hpp - Eco-thread WebSocket tables -------------------------===//
//
// The WebSocket kernels hand Elm plain integer ids, and something on the eco thread has to map each id back to the
// C++ objects behind it. These tables are that map, and they are also where every WebSocket event posted by the
// reactor is turned into the resumption of the Elm task that waits for it.
//
// There are three tables, all touched only on the eco thread (the thread that runs the Elm scheduler), so none is
// locked:
//
//   * Handshakes, keyed by a handshake id. A handshake is a connection whose opening HTTP exchange has been read
//     but not yet answered: one made by `dial`, one read by `readUpgrade`, or one registered by
//     `wsTablesAddServerHandshake` or `wsTablesAddServerH2Handshake`. All of them share one id space, and the entry
//     stays until the kernel that answers or drops the handshake erases it, or the tables are reset.
//   * WebSockets, keyed by a WebSocket id. An entry holds the codec (`WsCore`), the ids of its readable and
//     writable stream (its two faces), and, once the WebSocket has ended, its `WsCloseInfo`. The entry outlives the
//     end of the WebSocket so that `closed` can still answer; it is erased when it has ended, both faces have been
//     destroyed, no `closed` task is parked on it and no subscription names it. Its `WsCloseInfo` is then kept, with
//     whether it was delivered to `OnClose` subscriptions, in a first-in first-out list of the most recently erased
//     WebSockets, bounded at 4096 entries; an undelivered one is delivered from there to a later subscriber.
//   * Pending dials, keyed by the dialling task's resume token, so that killing that task can cancel the dial.
//
// The tables hold no Elm heap pointers, only shared pointers, numbers, strings and Scheduler tokens, so they need no
// root scanner. They belong to one heap generation (`currentHeapGeneration`, which changes when the Elm heap is
// reset). The first access in a new generation resets them: the connections of handshakes are aborted, h2
// handshakes abandoned, WebSockets that have not ended aborted, and pending dials cancelled. The holds the tables own
// (handshake peer holds, close-handshake holds, parked `closed` tasks, cancelled dials) need no release: the scheduler
// voided every hold of the old heap when it saw the new generation (D21 of plans/kernel-lib-bug-fixes.md).
//
// `ensureWsTables` registers a dispatch function for every `WsEvent::Kind`. A hold (`HoldToken`) is a Scheduler
// liveness count that keeps the program running while it is held. For an event that answers a waiting task
// (`Dialed`, `UpgradeRead`, `Opened`, `OpDone`, `PingDone`), the dispatch function resumes the task with the result
// built from the event and releases the hold of the event's token. When the task was killed it releases the hold
// all the same, and aborts what nobody will now receive: the connection of a `Dialed` or `UpgradeRead`, and the
// WebSocket of an `Opened` that succeeded and still has an entry. An `Opened` that failed, or whose task was killed,
// also discards the WebSocket's two stream pairs, which Elm never received, so that the pairs and the entry are
// erased. `Closed` records the `WsCloseInfo`, releases the
// close-handshake hold, resumes and releases every parked `closed` task, and reports the end to `wsManagerOnClosed`.
// `HandshakeGone` releases a handshake's peer hold and leaves the entry in place.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_TABLES_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_TABLES_HPP

#include "eco-system/Core/Core.hpp"
#include "eco-system/Socket/Conn.hpp"
#include "eco-system/WebSocket/H2StreamPort.hpp"
#include "eco-system/WebSocket/WsEvents.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"
#include "eco-system/WebSocket/WsProtocol.hpp"

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace Eco::System {

/// One handshake that has been read but not yet answered, with what answering it needs.
struct WsHandshakeEntry {
    std::shared_ptr<Conn> conn;   ///< The connection; null for a handshake on an HTTP/2 stream.
    bool server = false;          ///< True for a server-side handshake, false for one made by `dial`.
    /// The HTTP/2 extended CONNECT stream of a server handshake on HTTP/2; null otherwise.
    std::shared_ptr<H2PendingUpgrade> h2;
    /// For a handshake registered with `wsTablesAddServerHandshake` or `wsTablesAddServerH2Handshake`: the hold that
    /// keeps the program running while the peer is owed an answer. `kNoHold` for `dial` and `readUpgrade`
    /// handshakes, and once the hold has been released.
    HoldToken peerHold = kNoHold;
};

/// How a WebSocket ended: the close code, the reason, and whether the closing handshake completed cleanly.
///
/// A default `WsCloseInfo` is an abnormal end: code 1006, no reason, not clean.
struct WsCloseInfo {
    int code = 1006;
    std::string reason;
    bool clean = false;
};

/// One WebSocket, from the moment it is opened until its entry is erased, as the file comment describes.
struct WsEntry {
    std::shared_ptr<WsCore> core;
    int64_t readableId = 0, writableId = 0;
    bool closed = false;                  ///< True once the WebSocket has ended; `info` is meaningful only then.
    WsCloseInfo info;
    bool closeDelivered = false;          ///< True once the end has been delivered to the close subscriptions.
    /// The resume tokens of the parked `closed` tasks. Each token carries its own hold.
    std::vector<uint64_t> closedWaiters;
    /// The hold taken when a local close starts and released when the WebSocket ends; `kNoHold` when none is held.
    HoldToken closeHold = kNoHold;
    int facesAlive = 2;                   ///< How many of the two stream faces have not yet been destroyed.
    uint64_t outSeq = 0;                  ///< The sequence number of the last outgoing message stream opened.
};

/// The record of an erased WebSocket in the list of recently closed ones.
struct WsRecentClose {
    int64_t wsId = 0;
    WsCloseInfo info;
    bool delivered = false;   ///< Its end has been delivered to `OnClose` subscriptions (`WsEntry::closeDelivered`).
};

/// The three tables of the current heap generation, as the file comment describes, and the next ids to hand out.
struct WsTables {
    std::unordered_map<int64_t, WsHandshakeEntry> handshakes;
    std::unordered_map<int64_t, WsEntry> sockets;
    std::unordered_map<uint64_t, std::shared_ptr<DialJob>> pendingDials;   ///< Keyed by the dialling task's token.
    /// The records of erased WebSockets, oldest first, at most 4096.
    std::deque<WsRecentClose> recentlyClosed;
    int64_t nextHsId = 1;   ///< The next handshake id, shared by every kind of handshake.
    int64_t nextWsId = 1;
    uint64_t gen = 0;       ///< The heap generation the tables belong to; meaningful once `init` is true.
    bool init = false;
};

/// Returns the tables, first resetting them as the file comment describes if the heap generation has changed since
/// the last call. Eco thread only.
///
/// The tables are created on first use and never destroyed.
WsTables& wsTables();
/// Returns the entry of WebSocket `wsId`, or null if there is none. Eco thread only.
///
/// The pointer is valid until the entry is erased (by `wsTablesFaceGone`, `wsTablesRetire` or the end of the
/// WebSocket) or the tables are reset for a new heap generation. Anything that runs Elm code may do either, so look
/// the entry up again after it.
WsEntry* findWs(int64_t wsId);

/// Makes the tables ready for use: sets up the WebSocket event queue and the socket tables, and, on the first call,
/// registers the dispatch function of every `WsEvent::Kind`. Eco thread only.
void ensureWsTables();

/// Registers `conn`, a server connection whose HTTP/1.1 upgrade request has been read, as a server handshake, and
/// returns its handshake id. Eco thread only.
///
/// The entry owns `peerHold`. It is released when the handshake is answered or dropped, when a `HandshakeGone`
/// event reports its connection gone, or when the tables are reset.
int64_t wsTablesAddServerHandshake(std::shared_ptr<Conn> conn, HoldToken peerHold);
/// Registers `h2`, an HTTP/2 extended CONNECT stream awaiting its answer, as a server handshake with no connection,
/// and returns its handshake id. `peerHold` is owned as for `wsTablesAddServerHandshake`. Eco thread only.
int64_t wsTablesAddServerH2Handshake(std::shared_ptr<H2PendingUpgrade> h2, HoldToken peerHold);

/// Returns the `WsCloseInfo` of WebSocket `wsId` if it is in the list of recently erased WebSockets, and a default
/// (abnormal) `WsCloseInfo` otherwise. Searches the list linearly. Eco thread only.
WsCloseInfo wsRecentCloseInfo(int64_t wsId);
/// Returns the record of WebSocket `wsId` in the list of recently erased WebSockets, or null if it is not there.
/// Searches the list linearly. The pointer is valid until the next entry is erased or the tables are reset. Eco
/// thread only.
WsRecentClose* wsRecentClose(int64_t wsId);

/// Records that a local close of WebSocket `wsId` has started, by taking the close-handshake hold, which is
/// released when the WebSocket ends. Does nothing if there is no such entry, it has already ended, or the hold is
/// already taken. Eco thread only.
void wsTablesCloseStarted(int64_t wsId);
/// Records that one stream face of WebSocket `wsId` has been destroyed, and erases the entry if that leaves it
/// ready to be erased, as the file comment describes. Eco thread only.
void wsTablesFaceGone(int64_t wsId);
/// Erases the entry of WebSocket `wsId` if it is ready to be erased, as the file comment describes. Eco thread only.
void wsTablesRetire(int64_t wsId);

/// Cancels the dial whose task has resume token `token`, and returns whether it had not yet resolved. A
/// `CancelFn` for `makeKillHandle`. Eco thread only.
bool cancelPendingDial(uint64_t token);
/// Removes the parked `closed` task with resume token `token`, and returns whether one was found. A `CancelFn` for
/// `makeKillHandle`. Searches every WebSocket entry. Eco thread only.
bool cancelClosedWaiter(uint64_t token);

/// Builds the Elm value of `headers`, a `List ( String, List String )` with one element per header line, in order,
/// each pairing the name with a one-element list holding the value. Allocates; the result is not rooted.
HPointer buildHeaderList(const HeaderList& headers);

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_TABLES_HPP
