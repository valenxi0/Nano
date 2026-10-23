import { connect } from "node:net";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, extname, join } from "node:path";

const transportPath = join(
  homedir(),
  "Library/Application Support/Nano/run/hook-transport.json",
);

function send(event: Record<string, unknown>) {
  try {
    const config = JSON.parse(readFileSync(transportPath, "utf8"));
    if (!config?.socketPath || !config?.authToken) return;
    const socket = connect(config.socketPath);
    const done = () => socket.destroy();
    socket.setTimeout(1000);
    socket.on("connect", () => {
      socket.write(JSON.stringify({
        token: config.authToken,
        source: "pi",
        event,
      }) + "\n");
    });
    socket.on("data", done);
    socket.on("timeout", done);
    socket.on("error", done);
  } catch {
    // Monitoring must never disturb Pi when Nano is closed or unavailable.
  }
}

export default function nanoPiExtension(pi: any) {
  const context = (ctx: any) => {
    const file = ctx?.sessionManager?.getSessionFile?.() ?? "";
    const name = basename(file);
    return {
      session_id: name.slice(0, Math.max(0, name.length - extname(name).length)),
      transcript_path: file || undefined,
      cwd: ctx?.cwd,
    };
  };

  pi.on("session_start", async (_event: any, ctx: any) => {
    send({ hook_event_name: "SessionStart", ...context(ctx) });
  });
  pi.on("input", async (event: any, ctx: any) => {
    send({ hook_event_name: "UserPromptSubmit", prompt: event?.text, ...context(ctx) });
  });
  pi.on("tool_call", async (event: any, ctx: any) => {
    send({
      hook_event_name: "PreToolUse",
      tool_name: event?.toolName,
      tool_input: event?.input ?? {},
      ...context(ctx),
    });
  });
  pi.on("tool_result", async (event: any, ctx: any) => {
    send({
      hook_event_name: "PostToolUse",
      tool_name: event?.toolName,
      tool_input: event?.input ?? {},
      ...context(ctx),
    });
  });
  pi.on("agent_settled", async (_event: any, ctx: any) => {
    send({ hook_event_name: "Stop", ...context(ctx) });
  });
}
