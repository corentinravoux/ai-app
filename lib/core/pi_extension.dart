/// Pi extension that gives local Pi sessions a `web_read` tool. Written into
/// `<agent dir>/extensions/web_read.ts` (auto-discovered by Pi). It runs
/// `webread`, which AI App puts first on the agent's PATH. API from Pi
/// 1.5 docs/extensions.md (docs/local-wire-notes.md).
const kPiWebReadExtension = r'''
// Written by AI App: a web_read tool for local models. Edits are overwritten.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

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
      const r = await pi.exec("webread", [params.url], { signal, timeout: 30000 });
      const text = r.code === 0 ? r.stdout : (r.stderr || `webread exited with code ${r.code}`);
      return { content: [{ type: "text", text }], details: {} };
    },
  });
}
''';
