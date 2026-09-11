// Jean Claude custom tool: run the project's tests inside the sandbox (no network).
// Installed to ~/.config/opencode/tools/ by `make opencode`; __JC_SANDBOX__ is replaced
// with the path to jc-sandbox at install time.
import { tool } from "@opencode-ai/plugin"

const RUNNER = "__JC_SANDBOX__"

export default tool({
  description:
    "Run this project's tests in Jean Claude's sandbox and return the output. " +
    "Rust and Go tests run as WebAssembly inside Wasmtime; Python and Node tests run in a " +
    "throwaway locked-down container. The sandbox has NO network access and can only see " +
    "the project folder. Always use this tool to run tests (running test commands in the " +
    "shell is blocked). If the output says dependencies are missing, call sandbox_setup first.",
  args: {
    command: tool.schema
      .string()
      .optional()
      .describe("Optional custom test command, e.g. 'python -m pytest tests/test_api.py -k retry -x'. Omit to auto-detect."),
    backend: tool.schema
      .enum(["auto", "wasm", "container"])
      .optional()
      .describe("auto (default): wasm for Rust/Go, container for Python/Node. 'wasm' for pure-Python projects."),
    timeout: tool.schema.number().int().positive().optional().describe("Time limit in seconds (default 900)."),
  },
  async execute(args, context) {
    const dir = context.worktree || context.directory
    const argv = ["test", "--dir", dir, "--backend", args.backend ?? "auto", "--timeout", String(args.timeout ?? 900)]
    if (args.command) argv.push("--", args.command)
    const r = await Bun.$`${RUNNER} ${argv}`.nothrow().quiet()
    return (r.stdout.toString() + r.stderr.toString()).trim() || `jc-sandbox exited with code ${r.exitCode}`
  },
})
