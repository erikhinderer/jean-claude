// Jean Claude custom tool: install the project's dependencies into its sandbox
// volume. This is the only sandbox step with network access, so it asks first.
import { tool } from "@opencode-ai/plugin"

const RUNNER = "__JC_SANDBOX__"

export default tool({
  description:
    "Install this project's dependencies into its sandbox (pip/npm/pnpm/yarn/go/cargo, " +
    "detected automatically) so run_tests_sandboxed can work offline. This step has network " +
    "access and needs the user's approval. Run it once per project, and again after " +
    "dependency files change.",
  args: {
    backend: tool.schema
      .enum(["auto", "wasm", "container"])
      .optional()
      .describe("Must match the backend used for run_tests_sandboxed (default auto)."),
  },
  async execute(args, context) {
    const dir = context.worktree || context.directory
    const r = await Bun.$`${RUNNER} setup --dir ${dir} --backend ${args.backend ?? "auto"} --timeout 1800`.nothrow().quiet()
    return (r.stdout.toString() + r.stderr.toString()).trim() || `jc-sandbox exited with code ${r.exitCode}`
  },
})
