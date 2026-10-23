const fs = require("fs");
const os = require("os");
const path = require("path");
const vscode = require("vscode");

const receiptDirectory = path.join(os.homedir(), ".nano", "run", "ide-extension");
const receiptPath = path.join(
  receiptDirectory,
  `${String(vscode.env.uriScheme || "cursor").replace(/[^A-Za-z0-9._-]/g, "_")}-${process.pid}.json`
);

function normalizePath(value) {
  let text = String(value || "");
  try {
    text = decodeURIComponent(text);
  } catch (_) {}
  while (text.length > 1 && text.endsWith("/")) {
    text = text.slice(0, -1);
  }
  return text;
}

function samePath(left, right) {
  const a = normalizePath(left).toLowerCase();
  const b = normalizePath(right).toLowerCase();
  if (!a || !b) return false;
  return a === b || a.endsWith(b) || b.endsWith(a);
}

function workspaceRoots() {
  return (vscode.workspace.workspaceFolders || []).map((folder) =>
    normalizePath(folder.uri.fsPath)
  );
}

function matchesWorkspace(targetWorkspace) {
  if (!targetWorkspace) return true;
  return workspaceRoots().some((root) => samePath(root, targetWorkspace));
}

function isFocusPath(uriPath) {
  const value = String(uriPath || "").replace(/\/+$/, "");
  return (
    value === "/focus-cursor-agent" ||
    value === "focus-cursor-agent" ||
    value.endsWith("/focus-cursor-agent")
  );
}

async function writeReceipt(extra) {
  try {
    await fs.promises.mkdir(receiptDirectory, { recursive: true });
    const receipt = {
      scheme: vscode.env.uriScheme || "cursor",
      pid: process.pid,
      workspaces: workspaceRoots(),
      writtenAt: Date.now(),
      ...extra,
    };
    const temporaryPath = `${receiptPath}.${Date.now()}.tmp`;
    await fs.promises.writeFile(temporaryPath, JSON.stringify(receipt));
    await fs.promises.rename(temporaryPath, receiptPath);
  } catch (_) {}
}

async function openLocalConversation(conversation) {
  // Cursor 3.19's Agents window owns local chats across workspaces. This
  // command returns true only when that repository actually found the agent.
  try {
    const opened = await vscode.commands.executeCommand(
      "glass.openAgentById",
      conversation
    );
    if (opened === true) {
      return true;
    }
  } catch (_) {}

  // Classic project windows can only open a chat they have loaded. Never call
  // openComposer without a handle: Cursor resolves that call while falling
  // through to a blank/background Agents window.
  try {
    const handle = await vscode.commands.executeCommand(
      "composer.getComposerHandleById",
      conversation
    );
    if (!handle) return false;
    await vscode.commands.executeCommand("composer.openComposer", {
      type: "local",
      id: conversation,
    });
    return true;
  } catch (_) {}

  return false;
}

function activate(context) {
  const handler = vscode.window.registerUriHandler({
    async handleUri(uri) {
      if (!isFocusPath(uri.path)) return;
      const params = new URLSearchParams(uri.query);
      const conversation = params.get("conversation");
      if (!conversation) return;

      const workspace = params.get("workspace");
      if (workspace && !matchesWorkspace(workspace)) {
        await writeReceipt({
          conversation,
          opened: false,
          reason: "wrong-window",
        });
        return;
      }

      const opened = await openLocalConversation(conversation);
      await writeReceipt({
        conversation,
        opened,
        reason: opened ? "opened" : "not-in-window",
      });
    },
  });
  context.subscriptions.push(handler);
  void writeReceipt({ opened: false, reason: "ready" });
}

function deactivate() {}

module.exports = { activate, deactivate };
