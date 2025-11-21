#pragma once

#include <string>
#include <vector>
#include <functional>
#include <algorithm>

namespace Testing {

// Represents a single property-based test
class Test {
public:
    Test(std::string name, std::function<void()> func)
        : name_(std::move(name)), testFunc_(std::move(func)) {}

    // Execute the test
    void run() const {
        testFunc_();
    }

    // Get the test name/description
    const std::string& getName() const {
        return name_;
    }

private:
    std::string name_;
    std::function<void()> testFunc_;
};

// Represents a collection of tests
class TestSuite {
public:
    // Add a test to the suite
    void add(Test test) {
        tests_.push_back(std::move(test));
    }

    // Get all test names
    std::vector<std::string> listTests() const {
        std::vector<std::string> names;
        names.reserve(tests_.size());
        for (const auto& test : tests_) {
            names.push_back(test.getName());
        }
        return names;
    }

    // Filter tests by name pattern (substring match)
    std::vector<Test> filter(const std::string& pattern) const {
        if (pattern.empty()) {
            return tests_;  // No filter, return all
        }

        std::vector<Test> filtered;
        for (const auto& test : tests_) {
            if (test.getName().find(pattern) != std::string::npos) {
                filtered.push_back(test);
            }
        }
        return filtered;
    }

    // Run all tests or filtered tests
    void run(const std::string& filter = "") const {
        std::vector<Test> testsToRun = this->filter(filter);
        for (const auto& test : testsToRun) {
            test.run();
        }
    }

    // Get the number of tests
    size_t size() const {
        return tests_.size();
    }

private:
    std::vector<Test> tests_;
};

}  // namespace Testing
