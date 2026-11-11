/// Pi extension that gives local Pi sessions a `web_read` tool. Written into
/// `<agent dir>/extensions/web_read.ts` (auto-discovered by Pi). It runs
/// `webread`, which AI App puts first on the agent's PATH. API from Pi
/// 1.5 docs/extensions.md (docs/local-wire-notes.md).
const kPiWebReadExtension = r'''
// Written by AI App: a web_read tool for local models. Edits are overwritten.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { existsSync } from "node:fs";
import { delimiter, join } from "node:path";

/** Windows: the webread Python script on PATH (next to webread.cmd). */
function findScript(): string | undefined {
  const path = process.env.PATH ?? process.env.Path ?? "";
  for (const dir of path.split(delimiter)) {
    const f = join(dir, "webread");
    if (dir && existsSync(f)) return f;
  }
  return undefined;
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
      const opts = { signal, timeout: 30000 };
      let r;
      if (process.platform === "win32") {
        // Not through cmd.exe, which would cut the URL at "&": run the
        // script with Python directly, the URL as its own argument.
        const script = findScript();
        if (!script) {
          return { content: [{ type: "text", text: "webread is not on PATH" }], details: {} };
        }
        r = await pi.exec("py", ["-3", script, params.url], opts);
        // Only when py itself is missing (pi.exec does not use a shell, so
        // that is exactly "spawn py ENOENT"); never when webread failed.
        if (r.code !== 0 && /^spawn py ENOENT/.test(r.stderr ?? "")) {
          r = await pi.exec("python", [script, params.url], opts);
        }
      } else {
        r = await pi.exec("webread", [params.url], opts);
      }
      const text = r.code === 0 ? r.stdout : (r.stderr || `webread exited with code ${r.code}`);
      return { content: [{ type: "text", text }], details: {} };
    },
  });
}
''';
