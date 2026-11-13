/// Pi extension that gives local Pi sessions a `web_read` tool. Written into
/// `<agent dir>/extensions/web_read.ts` (auto-discovered by Pi). It runs
/// `webread`, which AI App puts first on the agent's PATH. API from Pi
/// 1.5 docs/extensions.md (docs/local-wire-notes.md).
const kPiWebReadExtension = r'''
// Written by AI App: web_read and web_search tools for local models.
// Edits are overwritten.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { existsSync } from "node:fs";
import { delimiter, join } from "node:path";

/** Windows: a Python script of AI App's on PATH (next to its .cmd). */
function findScript(name: string): string | undefined {
  const path = process.env.PATH ?? process.env.Path ?? "";
  for (const dir of path.split(delimiter)) {
    const f = join(dir, name);
    if (dir && existsSync(f)) return f;
  }
  return undefined;
}

/** Runs webread or websearch with [args] as separate arguments. */
async function run(pi: ExtensionAPI, name: string, args: string[], signal?: AbortSignal) {
  const opts = { signal, timeout: 30000 };
  let r;
  if (process.platform === "win32") {
    // Not through cmd.exe, which would cut an argument at "&": run the
    // script with Python directly.
    const script = findScript(name);
    if (!script) return `${name} is not on PATH`;
    r = await pi.exec("py", ["-3", script, ...args], opts);
    // Only when py itself is missing (pi.exec does not use a shell, so
    // that is exactly "spawn py ENOENT"); never when the script failed.
    if (r.code !== 0 && /^spawn py ENOENT/.test(r.stderr ?? "")) {
      r = await pi.exec("python", [script, ...args], opts);
    }
  } else {
    r = await pi.exec(name, args, opts);
  }
  return r.code === 0 ? r.stdout : (r.stderr || `${name} exited with code ${r.code}`);
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "web_read",
    label: "Read web page",
    description:
      "Fetch a web page (http or https) and return its text, capped at about 12,000 characters.",
    parameters: Type.Object({
      url: Type.String({ description: "The page URL, starting with http:// or https://" }),
    }),
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const text = await run(pi, "webread", [params.url], signal);
      return { content: [{ type: "text", text }], details: {} };
    },
  });
  pi.registerTool({
    name: "web_search",
    label: "Search the web",
    description:
      "Search the web (SearXNG). Returns numbered results with title, URL and a snippet; read one with web_read.",
    parameters: Type.Object({
      query: Type.String({ description: "What to search for" }),
    }),
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const text = await run(pi, "websearch", [params.query], signal);
      return { content: [{ type: "text", text }], details: {} };
    },
  });
}
''';
