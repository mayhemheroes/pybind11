/* Copyright 2023 Google LLC
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
      http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include <fuzzer/FuzzedDataProvider.h>
#include <iostream>
#include <string>
#include "pybind11/embed.h"
#include "pybind11/pybind11.h"

namespace py = pybind11;

// The embedded CPython interpreter performs one-time initialisation (interned
// strings, singleton type objects, module/import tables) whose allocations live
// for the whole process and are intentionally never freed. Under
// -fsanitize=address LeakSanitizer reports those as leaks at exit, and libFuzzer
// additionally runs a leak check after the initial corpus — halting EVERY run on
// any input that actually executes Python (e.g. `class C: ...`). Disable leak
// detection (only) by baking detect_leaks=0 into __asan_default_options.
//
// This is intentionally a STRONG definition, not weak: libFuzzer's runtime ships
// its own __asan_default_options, so a weak override here is shadowed by it and
// has no effect (verified: a weak symbol is never called; a strong one wins and
// libFuzzer's is weak, so there is no link conflict). It only sets the DEFAULT —
// keys named in a runtime ASAN_OPTIONS still override it, so Mayhem's
// abort_on_error=1/symbolize=0 set is untouched and detect_leaks stays 0 unless a
// run explicitly asks for detect_leaks=1. UAF / heap-overflow / UBSan detection
// are all fully intact; only leak reporting is suppressed.
extern "C" const char *__asan_default_options() { return "detect_leaks=0"; }

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  FuzzedDataProvider fdp(data, size);

  static py::scoped_interpreter guard{};
  try {
    auto locals = py::dict();
    py::exec(fdp.ConsumeRandomLengthString().c_str(), py::globals(), locals);
  } catch (pybind11::error_already_set &e) {
  }

  try {
    py::object os = py::module_::import("os");
    py::object makedirs = os.attr(fdp.ConsumeRandomLengthString().c_str());
  } catch (py::error_already_set &e) {
  }

  try {
    py::tuple args =
        py::make_tuple(fdp.ConsumeRandomLengthString().c_str(), py::none());
    py::object Decimal = py::module_::import("decimal").attr("Decimal");
    py::object pi = Decimal(fdp.ConsumeRandomLengthString().c_str());
    py::object exp_pi = pi.attr(fdp.ConsumeRandomLengthString().c_str())();
  } catch (py::error_already_set &e) {
  }

  try {
    py::object obj = py::str(fdp.ConsumeRandomLengthString().c_str());
  } catch (py::error_already_set &e) {
  }
  return 0;
}
