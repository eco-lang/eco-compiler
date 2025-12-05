#ifndef ELM_KERNEL_VALUE_HPP
#define ELM_KERNEL_VALUE_HPP

#include <cstdint>
#include <string>
#include <variant>
#include <memory>
#include <vector>
#include <functional>
#include <optional>
#include <map>

namespace Elm {

// Forward declarations
struct Value;
struct List;
struct Tuple2;
struct Tuple3;
struct Record;
struct Custom;
struct Closure;
struct Task;
struct Process;

// ============================================================================
// Core Value Type
// ============================================================================

// Tag for discriminating value types (matches JS $ field)
enum class ValueTag : uint16_t {
    // Primitives
    Int = 0,
    Float = 1,
    Char = 2,
    String = 3,
    Bool = 4,
    Unit = 5,

    // Containers
    List = 10,
    Tuple2 = 11,
    Tuple3 = 12,
    Array = 13,

    // Records and Custom Types
    Record = 20,
    Custom = 21,

    // Functions
    Closure = 30,

    // Effects
    Task = 40,
    Process = 41,

    // Special
    Nothing = 50,
    Just = 51,
    Ok = 52,
    Err = 53,
};

// ============================================================================
// List (Cons cells)
// ============================================================================

// Elm List is a linked list of cons cells
// Nil is represented by nullptr
struct List {
    std::shared_ptr<Value> head;  // 'a' field in JS
    std::shared_ptr<List> tail;   // 'b' field in JS

    List(std::shared_ptr<Value> h, std::shared_ptr<List> t)
        : head(std::move(h)), tail(std::move(t)) {}

    // Check if this is the end of the list
    bool isEmpty() const { return head == nullptr; }

    static std::shared_ptr<List> nil() { return nullptr; }

    static std::shared_ptr<List> cons(std::shared_ptr<Value> head, std::shared_ptr<List> tail) {
        return std::make_shared<List>(std::move(head), std::move(tail));
    }
};

// ============================================================================
// Tuples
// ============================================================================

struct Tuple2 {
    std::shared_ptr<Value> a;
    std::shared_ptr<Value> b;

    Tuple2(std::shared_ptr<Value> a_, std::shared_ptr<Value> b_)
        : a(std::move(a_)), b(std::move(b_)) {}
};

struct Tuple3 {
    std::shared_ptr<Value> a;
    std::shared_ptr<Value> b;
    std::shared_ptr<Value> c;

    Tuple3(std::shared_ptr<Value> a_, std::shared_ptr<Value> b_, std::shared_ptr<Value> c_)
        : a(std::move(a_)), b(std::move(b_)), c(std::move(c_)) {}
};

// ============================================================================
// Record
// ============================================================================

struct Record {
    std::map<std::u16string, std::shared_ptr<Value>> fields;

    Record() = default;
    Record(std::map<std::u16string, std::shared_ptr<Value>> f)
        : fields(std::move(f)) {}

    std::shared_ptr<Value> get(const std::u16string& key) const {
        auto it = fields.find(key);
        return (it != fields.end()) ? it->second : nullptr;
    }

    void set(const std::u16string& key, std::shared_ptr<Value> val) {
        fields[key] = std::move(val);
    }
};

// ============================================================================
// Custom Type (algebraic data types)
// ============================================================================

struct Custom {
    uint16_t tag;  // $ field - constructor tag
    std::vector<std::shared_ptr<Value>> args;  // a, b, c, ... fields

    Custom(uint16_t t) : tag(t) {}
    Custom(uint16_t t, std::vector<std::shared_ptr<Value>> a)
        : tag(t), args(std::move(a)) {}
};

// ============================================================================
// Closure (functions)
// ============================================================================

// Function types for different arities
using Fn1 = std::function<std::shared_ptr<Value>(std::shared_ptr<Value>)>;
using Fn2 = std::function<std::shared_ptr<Value>(std::shared_ptr<Value>, std::shared_ptr<Value>)>;
using Fn3 = std::function<std::shared_ptr<Value>(std::shared_ptr<Value>, std::shared_ptr<Value>, std::shared_ptr<Value>)>;

struct Closure {
    uint8_t arity;  // Number of arguments expected
    std::variant<Fn1, Fn2, Fn3> func;
    std::vector<std::shared_ptr<Value>> partialArgs;  // Partially applied arguments

    Closure(Fn1 f) : arity(1), func(std::move(f)) {}
    Closure(Fn2 f) : arity(2), func(std::move(f)) {}
    Closure(Fn3 f) : arity(3), func(std::move(f)) {}
};

// ============================================================================
// Task (async operations)
// ============================================================================

// Task types matching JS implementation
enum class TaskTag : uint16_t {
    Succeed = 0,   // __Task_succeed
    Fail = 1,      // __Task_fail
    Binding = 2,   // __Task_binding
    AndThen = 3,   // __Task_andThen
    OnError = 4,   // __Task_onError
    Receive = 5,   // __Task_receive
};

struct Task {
    TaskTag tag;
    std::shared_ptr<Value> value;  // For Succeed/Fail
    std::shared_ptr<Closure> callback;  // For AndThen/OnError
    std::function<void(std::function<void(std::shared_ptr<Value>)>)> binding;  // For Binding
    std::function<void()> kill;  // Kill function for Binding

    Task(TaskTag t) : tag(t) {}

    static std::shared_ptr<Task> succeed(std::shared_ptr<Value> v) {
        auto t = std::make_shared<Task>(TaskTag::Succeed);
        t->value = std::move(v);
        return t;
    }

    static std::shared_ptr<Task> fail(std::shared_ptr<Value> v) {
        auto t = std::make_shared<Task>(TaskTag::Fail);
        t->value = std::move(v);
        return t;
    }
};

// ============================================================================
// Process (green thread)
// ============================================================================

struct Process {
    uint64_t id;
    std::shared_ptr<Task> root;
    std::vector<std::shared_ptr<Task>> stack;
    std::function<void()> kill;

    Process(uint64_t i) : id(i) {}
};

// ============================================================================
// Main Value type (tagged union)
// ============================================================================

struct Value {
    ValueTag tag;

    // Use variant to hold different value types
    std::variant<
        int64_t,                      // Int
        double,                       // Float
        char32_t,                     // Char
        std::u16string,               // String
        bool,                         // Bool
        std::monostate,               // Unit, Nothing
        std::shared_ptr<List>,        // List
        std::shared_ptr<Tuple2>,      // Tuple2
        std::shared_ptr<Tuple3>,      // Tuple3
        std::shared_ptr<Record>,      // Record
        std::shared_ptr<Custom>,      // Custom
        std::shared_ptr<Closure>,     // Closure
        std::shared_ptr<Task>,        // Task
        std::shared_ptr<Process>,     // Process
        std::vector<std::shared_ptr<Value>>  // Array
    > data;

    // Constructors for primitives
    static std::shared_ptr<Value> integer(int64_t n) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Int;
        v->data = n;
        return v;
    }

    static std::shared_ptr<Value> floating(double n) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Float;
        v->data = n;
        return v;
    }

    static std::shared_ptr<Value> character(char32_t c) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Char;
        v->data = c;
        return v;
    }

    static std::shared_ptr<Value> string(std::u16string s) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::String;
        v->data = std::move(s);
        return v;
    }

    static std::shared_ptr<Value> boolean(bool b) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Bool;
        v->data = b;
        return v;
    }

    static std::shared_ptr<Value> unit() {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Unit;
        v->data = std::monostate{};
        return v;
    }

    // Maybe constructors
    static std::shared_ptr<Value> nothing() {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Nothing;
        v->data = std::monostate{};
        return v;
    }

    static std::shared_ptr<Value> just(std::shared_ptr<Value> inner) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Just;
        auto custom = std::make_shared<Custom>(0);
        custom->args.push_back(std::move(inner));
        v->data = std::move(custom);
        return v;
    }

    // Result constructors
    static std::shared_ptr<Value> ok(std::shared_ptr<Value> inner) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Ok;
        auto custom = std::make_shared<Custom>(0);
        custom->args.push_back(std::move(inner));
        v->data = std::move(custom);
        return v;
    }

    static std::shared_ptr<Value> err(std::shared_ptr<Value> inner) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Err;
        auto custom = std::make_shared<Custom>(1);
        custom->args.push_back(std::move(inner));
        v->data = std::move(custom);
        return v;
    }

    // List constructor
    static std::shared_ptr<Value> list(std::shared_ptr<List> lst) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::List;
        v->data = std::move(lst);
        return v;
    }

    // Tuple constructors
    static std::shared_ptr<Value> tuple2(std::shared_ptr<Value> a, std::shared_ptr<Value> b) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Tuple2;
        v->data = std::make_shared<Tuple2>(std::move(a), std::move(b));
        return v;
    }

    static std::shared_ptr<Value> tuple3(std::shared_ptr<Value> a, std::shared_ptr<Value> b, std::shared_ptr<Value> c) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Tuple3;
        v->data = std::make_shared<Tuple3>(std::move(a), std::move(b), std::move(c));
        return v;
    }

    // Array constructor
    static std::shared_ptr<Value> array(std::vector<std::shared_ptr<Value>> arr) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Array;
        v->data = std::move(arr);
        return v;
    }

    // Record constructor
    static std::shared_ptr<Value> record(std::shared_ptr<Record> r) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Record;
        v->data = std::move(r);
        return v;
    }

    // Custom type constructor
    static std::shared_ptr<Value> custom(std::shared_ptr<Custom> c) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Custom;
        v->data = std::move(c);
        return v;
    }

    // Closure constructor
    static std::shared_ptr<Value> closure(std::shared_ptr<Closure> c) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Closure;
        v->data = std::move(c);
        return v;
    }

    // Task constructor
    static std::shared_ptr<Value> task(std::shared_ptr<Task> t) {
        auto v = std::make_shared<Value>();
        v->tag = ValueTag::Task;
        v->data = std::move(t);
        return v;
    }

    // Accessors
    int64_t asInt() const { return std::get<int64_t>(data); }
    double asFloat() const { return std::get<double>(data); }
    char32_t asChar() const { return std::get<char32_t>(data); }
    const std::u16string& asString() const { return std::get<std::u16string>(data); }
    bool asBool() const { return std::get<bool>(data); }
    std::shared_ptr<List> asList() const { return std::get<std::shared_ptr<List>>(data); }
    std::shared_ptr<Tuple2> asTuple2() const { return std::get<std::shared_ptr<Tuple2>>(data); }
    std::shared_ptr<Tuple3> asTuple3() const { return std::get<std::shared_ptr<Tuple3>>(data); }
    std::shared_ptr<Record> asRecord() const { return std::get<std::shared_ptr<Record>>(data); }
    std::shared_ptr<Custom> asCustom() const { return std::get<std::shared_ptr<Custom>>(data); }
    std::shared_ptr<Closure> asClosure() const { return std::get<std::shared_ptr<Closure>>(data); }
    std::shared_ptr<Task> asTask() const { return std::get<std::shared_ptr<Task>>(data); }
    const std::vector<std::shared_ptr<Value>>& asArray() const {
        return std::get<std::vector<std::shared_ptr<Value>>>(data);
    }

    // Type checks
    bool isInt() const { return tag == ValueTag::Int; }
    bool isFloat() const { return tag == ValueTag::Float; }
    bool isChar() const { return tag == ValueTag::Char; }
    bool isString() const { return tag == ValueTag::String; }
    bool isBool() const { return tag == ValueTag::Bool; }
    bool isUnit() const { return tag == ValueTag::Unit; }
    bool isList() const { return tag == ValueTag::List; }
    bool isTuple2() const { return tag == ValueTag::Tuple2; }
    bool isTuple3() const { return tag == ValueTag::Tuple3; }
    bool isRecord() const { return tag == ValueTag::Record; }
    bool isCustom() const { return tag == ValueTag::Custom; }
    bool isClosure() const { return tag == ValueTag::Closure; }
    bool isTask() const { return tag == ValueTag::Task; }
    bool isArray() const { return tag == ValueTag::Array; }
    bool isNothing() const { return tag == ValueTag::Nothing; }
    bool isJust() const { return tag == ValueTag::Just; }
    bool isOk() const { return tag == ValueTag::Ok; }
    bool isErr() const { return tag == ValueTag::Err; }
};

// ============================================================================
// Helper functions matching JS Utils
// ============================================================================

namespace Utils {

// Create a character value (matches __Utils_chr)
inline std::shared_ptr<Value> chr(char32_t c) {
    return Value::character(c);
}

// Create a tuple2 (matches __Utils_Tuple2)
inline std::shared_ptr<Value> Tuple2(std::shared_ptr<Value> a, std::shared_ptr<Value> b) {
    return Value::tuple2(std::move(a), std::move(b));
}

// Create a tuple3 (matches __Utils_Tuple3)
inline std::shared_ptr<Value> Tuple3(std::shared_ptr<Value> a, std::shared_ptr<Value> b, std::shared_ptr<Value> c) {
    return Value::tuple3(std::move(a), std::move(b), std::move(c));
}

} // namespace Utils

// ============================================================================
// Maybe helpers
// ============================================================================

namespace Maybe {

inline std::shared_ptr<Value> Nothing() {
    return Value::nothing();
}

inline std::shared_ptr<Value> Just(std::shared_ptr<Value> v) {
    return Value::just(std::move(v));
}

inline bool isJust(const std::shared_ptr<Value>& v) {
    return v && v->isJust();
}

inline bool isNothing(const std::shared_ptr<Value>& v) {
    return !v || v->isNothing();
}

} // namespace Maybe

// ============================================================================
// Result helpers
// ============================================================================

namespace Result {

inline std::shared_ptr<Value> Ok(std::shared_ptr<Value> v) {
    return Value::ok(std::move(v));
}

inline std::shared_ptr<Value> Err(std::shared_ptr<Value> v) {
    return Value::err(std::move(v));
}

} // namespace Result

} // namespace Elm

#endif // ELM_KERNEL_VALUE_HPP
