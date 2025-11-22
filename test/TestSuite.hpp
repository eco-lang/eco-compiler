#pragma once

#include <string>
#include <vector>
#include <functional>
#include <algorithm>

namespace Testing {

/**
 * Represents a single property-based test with a name and test function.
 */
class Test {
public:
    Test(std::string name, std::function<void()> func)
        : name_(std::move(name)), testFunc_(std::move(func)) {}

    // Executes the test function.
    void run() const {
        testFunc_();
    }

    // Returns the test name/description.
    const std::string& getName() const {
        return name_;
    }

private:
    std::string name_;              // Test name/description.
    std::function<void()> testFunc_; // Test function to execute.
};

/**
 * A collection of tests that can be filtered and run together.
 */
class TestSuite {
public:
    // Adds a test to the suite.
    void add(Test test) {
        tests_.push_back(std::move(test));
    }

    // Returns a list of all test names.
    std::vector<std::string> listTests() const {
        std::vector<std::string> names;
        names.reserve(tests_.size());
        for (const auto& test : tests_) {
            names.push_back(test.getName());
        }
        return names;
    }

    // Returns tests whose names contain the given pattern.
    std::vector<Test> filter(const std::string& pattern) const {
        if (pattern.empty()) {
            return tests_;
        }

        std::vector<Test> filtered;
        for (const auto& test : tests_) {
            if (test.getName().find(pattern) != std::string::npos) {
                filtered.push_back(test);
            }
        }
        return filtered;
    }

    // Runs all tests, or only those matching the filter pattern.
    void run(const std::string& filter = "") const {
        std::vector<Test> testsToRun = this->filter(filter);
        for (const auto& test : testsToRun) {
            test.run();
        }
    }

    // Returns the number of tests in the suite.
    size_t size() const {
        return tests_.size();
    }

private:
    std::vector<Test> tests_; // All registered tests.
};

}  // namespace Testing
