// pybind11/mayhem/oracle.cpp — a self-contained functional oracle over the SAME pybind11
// embedded-interpreter + type-caster path the fuzzer drives. It does NOT touch the network or the
// Python test suite; it embeds CPython (py::scoped_interpreter, exactly like the harness) and
// asserts that pybind11's wrappers convert correctly in both directions. A no-op / "return success"
// patch to the casters or to embed.h cannot pass: every check reads a real value back through
// pybind11 and compares it to a golden expectation.
//
// Built + run by mayhem/test.sh with NORMAL (non-sanitiser) flags so it is an honest correctness
// oracle. One pass/fail per CHECK; the program exits non-zero on the first failure (caught by
// test.sh, which also tolerates a clean nonzero and reports it as a failed CTRF count).

#include <cstdio>
#include <string>
#include "pybind11/embed.h"
#include "pybind11/pybind11.h"

namespace py = pybind11;

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, name)                                                                          \
    do {                                                                                           \
        if (cond) {                                                                                \
            ++g_pass;                                                                              \
            std::printf("[ PASS ] %s\n", name);                                                    \
        } else {                                                                                   \
            ++g_fail;                                                                              \
            std::printf("[ FAIL ] %s\n", name);                                                    \
        }                                                                                          \
    } while (0)

int main() {
    py::scoped_interpreter guard{};

    // 1) py::exec defines a value in a local dict and we read it back through the caster
    //    (this is the harness's first and highest-coverage operation).
    try {
        auto locals = py::dict();
        py::exec("x = 6 * 7\ny = 'pybind' + '11'\n", py::globals(), locals);
        int x = locals["x"].cast<int>();
        std::string y = locals["y"].cast<std::string>();
        CHECK(x == 42, "py::exec assigns int, int caster reads 42");
        CHECK(y == "pybind11", "py::exec assigns str, string caster reads 'pybind11'");
    } catch (const std::exception &e) {
        std::printf("exception in exec check: %s\n", e.what());
        CHECK(false, "py::exec / casters threw");
    }

    // 2) module import + attribute lookup (the harness's os.attr(...) path), then call it.
    try {
        py::object os = py::module_::import("os");
        py::object getcwd = os.attr("getcwd");
        std::string cwd = getcwd().cast<std::string>();
        CHECK(!cwd.empty(), "import os, attr('getcwd') call returns a non-empty path");
        bool has_sep = py::module_::import("os").attr("sep").cast<std::string>() == "/";
        CHECK(has_sep, "os.sep is '/' via attribute caster");
    } catch (const std::exception &e) {
        std::printf("exception in os check: %s\n", e.what());
        CHECK(false, "os import/attr threw");
    }

    // 3) decimal.Decimal construct from string + method call (the harness's Decimal path).
    try {
        py::object Decimal = py::module_::import("decimal").attr("Decimal");
        py::object d = Decimal("2.25");
        py::object root = d.attr("sqrt")();
        std::string s = py::str(root);
        CHECK(s == "1.5", "Decimal('2.25').sqrt() == 1.5 through pybind11 wrappers");
        py::object sum = Decimal("0.1") + Decimal("0.2");
        CHECK(py::str(sum).cast<std::string>() == "0.3", "Decimal('0.1')+Decimal('0.2') == 0.3");
    } catch (const std::exception &e) {
        std::printf("exception in Decimal check: %s\n", e.what());
        CHECK(false, "Decimal construct/method threw");
    }

    // 4) py::str type-caster round-trip on a UTF-8 string (the harness's final py::str path).
    try {
        py::str s = py::str("h\xc3\xa9llo");  // "héllo" UTF-8
        std::string back = s.cast<std::string>();
        CHECK(back == "h\xc3\xa9llo", "py::str round-trips a UTF-8 string");
        py::object up = s.attr("upper")();
        CHECK(up.cast<std::string>() == "H\xc3\x89LLO", "str.upper() through pybind11 == 'HÉLLO'");
    } catch (const std::exception &e) {
        std::printf("exception in str check: %s\n", e.what());
        CHECK(false, "py::str caster threw");
    }

    std::printf("[ PASSED ] %d checks.\n", g_pass);
    if (g_fail) std::printf("[ FAILED ] %d checks.\n", g_fail);
    return g_fail == 0 ? 0 : 1;
}
