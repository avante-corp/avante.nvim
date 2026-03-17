#!/usr/bin/env node

// ACP wrapper shim for avante.nvim
//
// Patches @zed-industries/claude-code-acp to merge user-collected answers
// into AskUserQuestion tool input (works with v0.12.6; in v0.16.2+ the tool
// is blocked at SDK level via disallowedTools — pending official ACP support).
//
// The avante client collects answers via its inline UI and includes them in
// the permission response's `answers` field. This shim intercepts
// requestPermission to capture those answers and merges them into
// updatedInput so the tool receives them.

import { loadManagedSettings, applyEnvironmentSettings } from "@zed-industries/claude-code-acp/dist/utils.js";

const managedSettings = loadManagedSettings();
if (managedSettings) {
  applyEnvironmentSettings(managedSettings);
}

// stdout is used for ACP protocol messages — redirect console to stderr
console.log = console.error;
console.info = console.error;
console.warn = console.error;
console.debug = console.error;

process.on("unhandledRejection", (reason, promise) => {
  console.error("Unhandled Rejection at:", promise, "reason:", reason);
});

import { ClaudeAcpAgent } from "@zed-industries/claude-code-acp/dist/acp-agent.js";
import {
  nodeToWebReadable,
  nodeToWebWritable,
} from "@zed-industries/claude-code-acp/dist/utils.js";
import { AgentSideConnection, ndJsonStream } from "@agentclientprotocol/sdk";

// Patch canUseTool to capture answers from permission responses and merge into updatedInput.
//
// NOTE: In v0.16.2+, AskUserQuestion is in disallowedTools which blocks it at
// the SDK level before canUseTool is even called. This patch works for v0.12.6.
// When ACP officially supports AskUserQuestion, this shim can be removed.
const origCanUseTool = ClaudeAcpAgent.prototype.canUseTool;
ClaudeAcpAgent.prototype.canUseTool = function (sessionId) {
  const self = this;
  const origFactory = origCanUseTool.call(this, sessionId);

  return async (toolName, toolInput, opts) => {
    // Temporarily wrap requestPermission to capture answers from the response
    const origRP = self.client.requestPermission.bind(self.client);
    let capturedAnswers = null;

    self.client.requestPermission = async function (params) {
      const response = await origRP(params);
      if (response && response.answers) {
        capturedAnswers = response.answers;
      }
      return response;
    };

    const result = await origFactory(toolName, toolInput, opts);

    // Restore original
    self.client.requestPermission = origRP;

    // Merge captured answers into updatedInput for AskUserQuestion
    if (result.behavior === "allow" && capturedAnswers && result.updatedInput) {
      result.updatedInput = {
        ...result.updatedInput,
        answers: capturedAnswers,
      };
    }

    return result;
  };
};

// Run the patched ACP agent
const input = nodeToWebWritable(process.stdout);
const output = nodeToWebReadable(process.stdin);
const stream = ndJsonStream(input, output);
new AgentSideConnection((client) => new ClaudeAcpAgent(client), stream);

process.stdin.resume();
