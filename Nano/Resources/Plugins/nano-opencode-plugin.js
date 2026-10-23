/**
 * Nano plugin for OpenCode.
 *
 * OpenCode installs no shell hooks, so Nano was discovering its sessions by
 * polling a SQLite database every 25 seconds - late, and only while Nano
 * happened to look. OpenCode does expose an official plugin API, so this
 * connects to the same Unix socket the shell bridge uses and pushes the same
 * event shape. From Nano's side an OpenCode session becomes indistinguishable
 * from a hook-driven one.
 */
import { connect } from "node:net";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const TRANSPORT = join(
  homedir(),
  "Library/Application Support/Nano/run/hook-transport.json",
);

function transport() {
  try {
    return JSON.parse(readFileSync(TRANSPORT, "utf8"));
  } catch {
    // Nano not installed, or not yet launched. Never a reason to disturb
    // OpenCode: the plugin simply does nothing.
    return null;
  }
}

function send(event) {
  const config = transport();
  if (!config?.socketPath || !config?.authToken) return;

  try {
    const socket = connect(config.socketPath);
    socket.setTimeout(1000);
    const done = () => socket.destroy();

    socket.on("connect", () => {
      socket.write(
        JSON.stringify({
          token: config.authToken,
          source: "opencode",
          event,
        }) + "\n",
      );
    });
    // Fire and forget: OpenCode must never wait on Nano, and Nano's reply
    // matters only for the blocking permission path below.
    socket.on("data", done);
    socket.on("timeout", done);
    socket.on("error", done);
  } catch {
    // Swallowed on purpose - a monitoring tool must not break the agent.
  }
}

/** Blocking variant: waits for Nano's answer so a permission can be decided. */
function ask(event, timeoutMs = 86400000) {
  return new Promise((resolve) => {
    const config = transport();
    if (!config?.socketPath || !config?.authToken) return resolve(null);

    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };

    try {
      const socket = connect(config.socketPath);
      socket.setTimeout(timeoutMs);
      let buffer = "";

      socket.on("connect", () => {
        socket.write(
          JSON.stringify({ token: config.authToken, source: "opencode", event }) + "\n",
        );
      });
      socket.on("data", (chunk) => {
        buffer += chunk.toString();
        if (!buffer.includes("\n")) return;
        try {
          finish(JSON.parse(buffer.trim()));
        } catch {
          finish(null);
        }
        socket.destroy();
      });
      socket.on("timeout", () => { socket.destroy(); finish(null); });
      socket.on("error", () => finish(null));
      socket.on("close", () => finish(null));
    } catch {
      finish(null);
    }
  });
}

export const NanoPlugin = async ({ project, directory, client, serverUrl }) => {
  const cwd = directory ?? project?.worktree ?? process.cwd();

  // The client plugins receive predates the question routes, so the reply
  // goes through its underlying HTTP client, or straight to the server.
  async function replyToQuestion(requestID, answers) {
    const http = client?._client;
    if (http?.post) {
      await http.post({
        url: "/question/{requestID}/reply",
        path: { requestID },
        query: { directory: cwd },
        body: { answers },
        headers: { "Content-Type": "application/json" },
      });
      return;
    }
    if (!serverUrl) return;
    const url = new URL(`/question/${encodeURIComponent(requestID)}/reply`, serverUrl);
    url.searchParams.set("directory", cwd);
    await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ answers }),
    });
  }

  // Nano answers only a single question with a handful of options; for
  // anything else it shows a card and OpenCode's own prompt takes the answer.
  async function forwardQuestion(request) {
    const reply = await ask({
      hook_event_name: "PreToolUse",
      session_id: request?.sessionID,
      cwd,
      tool_name: "question",
      tool_input: { questions: request?.questions ?? [] },
    });
    if (typeof reply?.answer !== "string" || !request?.id) return;
    await replyToQuestion(request.id, [[reply.answer]]);
  }

  return {
    "chat.message": async (input, output) => {
      send({
        hook_event_name: "UserPromptSubmit",
        session_id: input.sessionID,
        cwd,
        model: input.model?.modelID,
        provider_id: input.model?.providerID,
        // OpenCode has used both shapes across releases. Forward whichever is
        // present; Nano extracts text parts and never needs the attachments.
        parts: output?.message?.parts ?? output?.parts,
        message: output?.message?.content ?? output?.content,
      });
    },

    "tool.execute.after": async (input, output) => {
      send({
        hook_event_name: "PostToolUse",
        session_id: input.sessionID,
        cwd,
        tool_name: input.tool,
        tool_input: input?.args ?? {},
      });
    },

    "permission.ask": async (input, output) => {
      const reply = await ask({
        hook_event_name: "PermissionRequest",
        session_id: input.sessionID ?? input.id,
        cwd,
        tool_name: input.type ?? "permission",
        tool_input: input.metadata ?? {},
      });

      // Only speak when the user actually decided. Anything else leaves
      // OpenCode's own prompt to handle it, so a closed island never blocks.
      if (reply?.permissionDecision === "allow") output.status = "allow";
      if (reply?.permissionDecision === "deny") output.status = "deny";
    },

    event: async ({ event }) => {
      if (event?.type === "session.idle") {
        send({
          hook_event_name: "Stop",
          session_id: event.properties?.sessionID,
          cwd,
        });
      }
      // Not awaited: the answer can take as long as the user does, and the
      // event bus must keep moving meanwhile.
      if (event?.type === "question.asked") {
        forwardQuestion(event.properties).catch(() => {});
      }
      // Answered or dismissed, here or in OpenCode: Nano retracts its card.
      if (event?.type === "question.replied" || event?.type === "question.rejected") {
        send({
          hook_event_name: "PostToolUse",
          session_id: event.properties?.sessionID,
          cwd,
          tool_name: "question",
        });
      }
    },
  };
};

export default NanoPlugin;
