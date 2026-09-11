---
description: Run the tests in the sandbox and fix failures until they pass
agent: build
---

Run this project's tests with run_tests_sandboxed. $ARGUMENTS

For each failure: find the root cause (don't just change the test to pass), make the smallest
correct fix, and re-run the affected tests. If dependencies are missing, call sandbox_setup.
If a test needs a live service that the offline sandbox can't reach, say so and skip it.
Stop when the suite passes or only service-dependent tests remain, then summarize every change.
