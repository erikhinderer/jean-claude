---
description: Read-only code review — findings ranked by severity, no edits
agent: plan
---

Review this repository for bugs and risky code. Focus: $ARGUMENTS

1. Read the README and the project layout first (glob/grep, then open only the files that matter).
2. Run the existing tests with run_tests_sandboxed to get a baseline.
3. Report findings as a list, most serious first. For each: file and line, what goes wrong,
   how you know (test output, reasoning), and a concrete suggested fix.
Do not edit any files. End with the three fixes you'd make first.
