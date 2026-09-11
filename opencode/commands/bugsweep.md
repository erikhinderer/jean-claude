---
description: Full pass — review the repo, fix the bugs you find, prove it with tests
agent: build
---

Do a bug sweep of this repository. Focus: $ARGUMENTS

1. Suggest a feature branch first if we're on main/master (git switch -c jean-claude/bugsweep).
2. Read the README and project structure; run the tests with run_tests_sandboxed for a baseline.
3. List the bugs you find, most serious first, before changing anything.
4. Fix them one at a time with small, focused edits; add or update a test for each fix where
   practical; re-run the tests after each fix.
5. Finish with: files changed, tests before/after, and anything that needs a human decision.
