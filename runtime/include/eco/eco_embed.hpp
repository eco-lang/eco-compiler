// A C++20 layer over `eco/eco_embed.h`, the interface through which a host application runs a program compiled
// by Eco as a library. It adds nothing the C functions cannot do; it makes the safe way to use them the easy way.
//
// Each port is a typed handle (`BytesOutPort`, `BytesInPort`, `JsonOutPort`, `JsonInPort`), resolved from its
// name once, when it is made, and checked against the port's kind if the program has registered it already. A
// handle is a pointer: cheap to copy, valid for the life of the process, and usable on any thread.
//
// An outgoing port's `subscribe` takes any callable and returns a `Subscription`, which unsubscribes when it is
// destroyed. The runtime, not the `Subscription`, deletes the callable, once no delivery can reach it, so ending
// a subscription never frees a callback that is still running. An exception must not leave a callback: one that
// does is printed and the process aborts, rather than unwinding through the runtime and the program.
//
// A bytes subscriber gets a `BorrowedBytes`, whose bytes are those of the Elm value and are valid only during the
// call; `retain` makes an `OwnedBytes` copy that may be kept anywhere and released on any thread. A
// `BytesInPort` takes bytes in two ways: `emit`, whose callable fills the payload (straight into the program's
// heap when it is called inside an outgoing callback), and `send`, which hands over a `Buffer` filled earlier.
//
// Callbacks run on the eco thread while the program waits for them. No garbage collection runs during one, so
// borrowed bytes stay put for the whole call, emits included.

#ifndef ECO_EMBED_HPP
#define ECO_EMBED_HPP

#include "eco_embed.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <memory>
#include <new>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>

namespace eco {

// What `BytesInPort::emit` and `BytesInPort::send` did, the `ECO_EMIT_*` results.
enum class EmitResult {
    Queued = ECO_EMIT_QUEUED,
    NotAPort = ECO_EMIT_NOT_A_PORT,
    Cancelled = ECO_EMIT_CANCELLED,
    Overrun = ECO_EMIT_OVERRUN,
    Nested = ECO_EMIT_NESTED,
    NoMemory = ECO_EMIT_NO_MEMORY,
};

// What `JsonInPort::send` did. On `Rejected`, `eco_last_error()` says why.
enum class SendResult { Queued = 0, NotAPort = 1, Rejected = 2 };

class BorrowedBytes;

/**
 * An immutable copy of a payload's bytes, shared by reference count. Copying one adds a reference; the last one
 * destroyed frees the bytes. May be used and destroyed on any thread. A default-constructed one holds nothing.
 */
class OwnedBytes {
public:
    OwnedBytes() noexcept = default;
    OwnedBytes(const OwnedBytes& other) noexcept : p_(other.p_) {
        if (p_) eco_owned_ref(p_);
    }
    OwnedBytes(OwnedBytes&& other) noexcept : p_(std::exchange(other.p_, nullptr)) {}
    OwnedBytes& operator=(OwnedBytes other) noexcept {
        std::swap(p_, other.p_);
        return *this;
    }
    ~OwnedBytes() {
        if (p_) eco_owned_unref(p_);
    }

    // The bytes; empty when this holds nothing.
    std::span<const std::byte> view() const noexcept {
        if (!p_) return {};
        return {reinterpret_cast<const std::byte*>(eco_owned_data(p_)), eco_owned_size(p_)};
    }
    std::size_t size() const noexcept { return p_ ? eco_owned_size(p_) : 0; }
    // Whether this holds a copy, possibly of no bytes.
    explicit operator bool() const noexcept { return p_ != nullptr; }

private:
    friend class BorrowedBytes;
    explicit OwnedBytes(eco_owned_bytes* p) noexcept : p_(p) {}
    eco_owned_bytes* p_ = nullptr;
};

/**
 * The bytes of one outgoing payload, lent to a subscriber for the duration of its call. It cannot be copied or
 * moved, so that it is not kept by accident; `retain` makes a copy that can be.
 */
class BorrowedBytes {
public:
    BorrowedBytes(const BorrowedBytes&) = delete;
    BorrowedBytes& operator=(const BorrowedBytes&) = delete;
    BorrowedBytes(BorrowedBytes&&) = delete;
    BorrowedBytes& operator=(BorrowedBytes&&) = delete;

    // The bytes, valid until the callback returns.
    std::span<const std::byte> view() const noexcept {
        return {reinterpret_cast<const std::byte*>(eco_borrowed_data(b_)), eco_borrowed_size(b_)};
    }
    std::size_t size() const noexcept { return eco_borrowed_size(b_); }
    // Returns a copy of the bytes that outlives the call. Throws `std::bad_alloc` if it cannot be allocated.
    OwnedBytes retain() const {
        eco_owned_bytes* owned = eco_borrowed_retain(b_);
        if (!owned) throw std::bad_alloc();
        return OwnedBytes(owned);
    }

private:
    friend struct detail_access;
    explicit BorrowedBytes(const eco_borrowed_bytes* b) noexcept : b_(b) {}
    const eco_borrowed_bytes* b_;
};

// Makes `BorrowedBytes` for the subscriber trampolines; not for hosts.
struct detail_access {
    // A prvalue, which guaranteed copy elision lets a non-movable type be returned as.
    static BorrowedBytes make(const eco_borrowed_bytes* b) noexcept { return BorrowedBytes(b); }
};

/**
 * Bytes a host fills before handing them to an incoming bytes port with `BytesInPort::send`: a buffer of a fixed
 * capacity, of which the first `size()` bytes are the payload. Move-only.
 */
class Buffer {
public:
    explicit Buffer(std::size_t capacity) : data_(new std::byte[capacity > 0 ? capacity : 1]), cap_(capacity) {}

    // The whole buffer, to write into.
    std::span<std::byte> writable() noexcept { return {data_.get(), cap_}; }
    // Sets how many of the bytes are the payload. Throws `std::length_error` past the capacity.
    void setSize(std::size_t n) {
        if (n > cap_) throw std::length_error("eco::Buffer::setSize past the capacity");
        size_ = n;
    }
    std::size_t size() const noexcept { return size_; }
    std::size_t capacity() const noexcept { return cap_; }

private:
    friend class BytesInPort;
    std::unique_ptr<std::byte[]> data_;
    std::size_t cap_;
    std::size_t size_ = 0;
};

/**
 * A subscription to an outgoing port, ended when it is destroyed or `reset`. Move-only. The callable it was made
 * with is deleted by the runtime once no delivery can reach it.
 */
class Subscription {
public:
    Subscription() noexcept = default;
    Subscription(Subscription&& other) noexcept { *this = std::move(other); }
    Subscription& operator=(Subscription&& other) noexcept {
        if (this != &other) {
            reset();
            port_ = std::exchange(other.port_, nullptr);
            json_ = std::exchange(other.json_, nullptr);
            borrowed_ = std::exchange(other.borrowed_, nullptr);
            user_ = std::exchange(other.user_, nullptr);
        }
        return *this;
    }
    Subscription(const Subscription&) = delete;
    Subscription& operator=(const Subscription&) = delete;
    ~Subscription() { reset(); }

    // Ends the subscription, if there is one. A call in progress on another thread may still finish.
    void reset() noexcept {
        if (port_) {
            if (json_) eco_port_unsubscribe_json(port_, json_, user_);
            if (borrowed_) eco_port_unsubscribe_borrowed(port_, borrowed_, user_);
        }
        port_ = nullptr;
        json_ = nullptr;
        borrowed_ = nullptr;
        user_ = nullptr;
    }
    // Whether this holds a subscription.
    explicit operator bool() const noexcept { return port_ != nullptr; }

private:
    friend class BytesOutPort;
    friend class JsonOutPort;
    Subscription(eco_port* port, eco_port_callback json, eco_port_borrowed_callback borrowed, void* user) noexcept
        : port_(port), json_(json), borrowed_(borrowed), user_(user) {}
    eco_port* port_ = nullptr;
    eco_port_callback json_ = nullptr;
    eco_port_borrowed_callback borrowed_ = nullptr;
    void* user_ = nullptr;
};

namespace detail {

inline const char* kindName(int kind) {
    switch (kind) {
        case ECO_PORT_IN_JSON: return "an incoming JSON port";
        case ECO_PORT_IN_BYTES: return "an incoming bytes port";
        case ECO_PORT_OUT_JSON: return "an outgoing JSON port";
        case ECO_PORT_OUT_BYTES: return "an outgoing bytes port";
        default: return "a registered port";
    }
}

// Returns the handle of `name`, throwing `std::invalid_argument` if the program has registered the port as a kind
// other than `want`. A port not registered yet is accepted; its operations fail until it is registered as `want`.
inline eco_port* resolve(const char* name, int want) {
    eco_port* port = eco_port_get(name);
    if (!port) throw std::invalid_argument("eco: a port name must not be null");
    const int kind = eco_port_kind(port);
    if (kind != ECO_PORT_UNREGISTERED && kind != want) {
        throw std::invalid_argument(std::string("eco: port '") + name + "' is " + kindName(kind) + ", not " +
                                    kindName(want));
    }
    return port;
}

[[noreturn]] inline void abortOnException(const char* what) {
    std::fprintf(stderr, "eco: an exception escaped a port callback%s%s\n", what ? ": " : "", what ? what : "");
    std::fflush(stderr);
    std::abort();
}

// The C callbacks of a subscription whose callable has type `Fn`, one set per type, so that a subscription's
// (callback, user) pair is its own.
template <class Fn>
struct SubscriberThunks {
    static void borrowed(const eco_borrowed_bytes* bytes, void* user) {
        try {
            const BorrowedBytes& view = detail_access::make(bytes);
            (*static_cast<Fn*>(user))(view);
        } catch (const std::exception& e) {
            abortOnException(e.what());
        } catch (...) {
            abortOnException(nullptr);
        }
    }
    static void json(const char* text, void* user) {
        try {
            (*static_cast<Fn*>(user))(std::string_view(text));
        } catch (const std::exception& e) {
            abortOnException(e.what());
        } catch (...) {
            abortOnException(nullptr);
        }
    }
    static void destroy(void* user) { delete static_cast<Fn*>(user); }
};

}  // namespace detail

/**
 * An outgoing port whose payload is `Bytes`. Its subscribers get each payload as `BorrowedBytes`.
 */
class BytesOutPort {
public:
    // Resolves the port `name`. Throws `std::invalid_argument` if the program registered it as another kind.
    explicit BytesOutPort(const char* name) : port_(detail::resolve(name, ECO_PORT_OUT_BYTES)) {}

    // Subscribes `f`, a callable taking `const BorrowedBytes&`, and returns the subscription. Throws
    // `std::invalid_argument` if the port is a JSON port. If the port has never had a subscriber, `f` is first
    // called with the payloads sent before, on this thread.
    template <class F>
    Subscription subscribe(F&& f) const {
        using Fn = std::decay_t<F>;
        static_assert(std::is_invocable_v<Fn&, const BorrowedBytes&>,
                      "a bytes subscriber is called with const eco::BorrowedBytes&");
        Fn* fn = new Fn(std::forward<F>(f));
        if (eco_port_subscribe_borrowed(port_, &detail::SubscriberThunks<Fn>::borrowed, fn,
                                        &detail::SubscriberThunks<Fn>::destroy) != 0) {
            delete fn;
            throw std::invalid_argument(std::string("eco: cannot subscribe to '") + name() + "'");
        }
        return Subscription(port_, nullptr, &detail::SubscriberThunks<Fn>::borrowed, fn);
    }

    eco_port* handle() const noexcept { return port_; }
    const char* name() const noexcept { return eco_port_get_name(port_); }

private:
    eco_port* port_;
};

/**
 * An outgoing port whose payload is anything but `Bytes`. Its subscribers get each payload as JSON text.
 */
class JsonOutPort {
public:
    explicit JsonOutPort(const char* name) : port_(detail::resolve(name, ECO_PORT_OUT_JSON)) {}

    // Subscribes `f`, a callable taking `std::string_view`, the payload's JSON, valid during the call.
    template <class F>
    Subscription subscribe(F&& f) const {
        using Fn = std::decay_t<F>;
        static_assert(std::is_invocable_v<Fn&, std::string_view>,
                      "a JSON subscriber is called with std::string_view");
        Fn* fn = new Fn(std::forward<F>(f));
        if (eco_port_subscribe_json(port_, &detail::SubscriberThunks<Fn>::json, fn,
                                    &detail::SubscriberThunks<Fn>::destroy) != 0) {
            delete fn;
            throw std::invalid_argument(std::string("eco: cannot subscribe to '") + name() + "'");
        }
        return Subscription(port_, &detail::SubscriberThunks<Fn>::json, nullptr, fn);
    }

    eco_port* handle() const noexcept { return port_; }
    const char* name() const noexcept { return eco_port_get_name(port_); }

private:
    eco_port* port_;
};

/**
 * An incoming port whose payload is `Bytes`.
 */
class BytesInPort {
public:
    explicit BytesInPort(const char* name) : port_(detail::resolve(name, ECO_PORT_IN_BYTES)) {}

    // Calls `fill` once with a writable span of `capacity` bytes and sends what it wrote. `fill` returns the
    // number of bytes written, as `std::size_t`, or as `std::optional<std::size_t>` with `std::nullopt` to send
    // nothing. Inside an outgoing callback the span is the new Bytes value itself, in the program's heap.
    //
    // An exception thrown by `fill` cancels the emit and is rethrown from here.
    template <class F>
    EmitResult emit(std::size_t capacity, F&& fill) const {
        using Fill = std::remove_reference_t<F>;
        using R = std::invoke_result_t<Fill&, std::span<std::byte>>;
        static_assert(std::is_convertible_v<R, std::size_t> || std::is_same_v<R, std::optional<std::size_t>>,
                      "a fill function returns std::size_t or std::optional<std::size_t>");
        struct Ctx {
            Fill* fill;
            std::exception_ptr error;
        } ctx{&fill, nullptr};
        eco_bytes_fill thunk = [](uint8_t* out, std::size_t cap, void* user) -> std::size_t {
            Ctx& c = *static_cast<Ctx*>(user);
            try {
                std::span<std::byte> span(reinterpret_cast<std::byte*>(out), cap);
                if constexpr (std::is_same_v<R, std::optional<std::size_t>>) {
                    std::optional<std::size_t> n = (*c.fill)(span);
                    return n ? *n : ECO_FILL_CANCEL;
                } else {
                    return static_cast<std::size_t>((*c.fill)(span));
                }
            } catch (...) {
                c.error = std::current_exception();
                return ECO_FILL_CANCEL;
            }
        };
        const int rc = eco_port_emit(port_, capacity, thunk, &ctx);
        if (ctx.error) std::rethrow_exception(ctx.error);
        return static_cast<EmitResult>(rc);
    }

    // Hands the first `buffer.size()` bytes of `buffer` to the port; the eco thread copies them into the
    // program's heap and frees the buffer. On `NotAPort` the buffer stays with the caller.
    EmitResult send(Buffer&& buffer) const {
        std::byte* raw = buffer.data_.get();
        const int rc = eco_port_send_buffer(port_, reinterpret_cast<const uint8_t*>(raw), buffer.size_,
                                            [](void* p) { delete[] static_cast<std::byte*>(p); }, raw);
        if (rc != 0) return EmitResult::NotAPort;
        (void)buffer.data_.release();
        buffer.cap_ = 0;
        buffer.size_ = 0;
        return EmitResult::Queued;
    }

    eco_port* handle() const noexcept { return port_; }
    const char* name() const noexcept { return eco_port_get_name(port_); }

private:
    eco_port* port_;
};

/**
 * An incoming port whose payload is anything but `Bytes`.
 */
class JsonInPort {
public:
    explicit JsonInPort(const char* name) : port_(detail::resolve(name, ECO_PORT_IN_JSON)) {}

    // Queues the JSON text `json` for the program, after checking it against the port's payload type.
    SendResult send(const std::string& json) const {
        return static_cast<SendResult>(eco_port_send_json(port_, json.c_str()));
    }

    eco_port* handle() const noexcept { return port_; }
    const char* name() const noexcept { return eco_port_get_name(port_); }

private:
    eco_port* port_;
};

}  // namespace eco

#endif  // ECO_EMBED_HPP
