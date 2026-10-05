#!/usr/bin/env node
// Minimal stand-in for `pi --mode rpc`. Records every command it receives to
// $FAKE_PI_LOG and behaves according to $FAKE_PI_MODE:
//   quick     settle straight after the prompt
//   steer     keep running until a steer arrives, then settle
//   error     settle with an errored final message
//   abortable keep running until aborted
//   followup  settle at once; answer a later prompt and settle again
//   late-steer settle just as a steer arrives, leaving it queued (as real pi
//             does for an idle session); answer the reclaiming prompt
import { appendFileSync } from "node:fs";

const mode = process.env.FAKE_PI_MODE || "quick";
const logFile = process.env.FAKE_PI_LOG;
const emit = (record) => process.stdout.write(`${JSON.stringify(record)}\n`);
const say = (text, extra = {}) =>
  emit({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text }], stopReason: "stop", ...extra } });
const settle = () => {
  emit({ type: "agent_end", messages: [], willRetry: false });
  emit({ type: "agent_settled" });
};

let prompts = 0;
let queuedSteering = [];
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let i;
  while ((i = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, i);
    buffer = buffer.slice(i + 1);
    if (!line) continue;
    const command = JSON.parse(line);
    if (logFile) appendFileSync(logFile, `${line}\n`);
    handle(command);
  }
});
process.stdin.on("end", () => process.exit(0));

function handle(command) {
  switch (command.type) {
    case "prompt": {
      prompts += 1;
      emit({ type: "response", id: command.id, command: "prompt", success: true, data: { disposition: "started" } });
      emit({ type: "agent_start" });
      if (mode === "late-steer" && prompts > 1) {
        say(`reclaimed: ${command.message.split("\n")[0]}`);
        settle();
      } else if (mode === "quick" || (mode === "followup" && prompts === 1)) {
        say("quick review done");
        settle();
      } else if (mode === "followup") {
        say(`followed up: ${command.message.split("\n")[0]}`);
        settle();
      } else if (mode === "error") {
        emit({ type: "message_end", message: { role: "assistant", content: [], stopReason: "error", errorMessage: "API Error: 529 overloaded_error" } });
        settle();
      }
      break;
    }
    case "steer":
      if (mode === "late-steer") {
        say("finished on the old head");
        settle();
        queuedSteering.push(command.message);
      }
      emit({ type: "response", id: command.id, command: "steer", success: true, data: { disposition: "queued" } });
      if (mode === "steer") {
        setTimeout(() => {
          say("steered review done");
          settle();
        }, 200);
      }
      break;
    case "abort":
      say("", { stopReason: "aborted" });
      settle();
      emit({ type: "response", id: command.id, command: "abort", success: true });
      break;
    case "clear_queue":
      emit({ type: "response", id: command.id, command: "clear_queue", success: true, data: { steering: queuedSteering, followUp: [] } });
      queuedSteering = [];
      break;
    case "extension_ui_response":
      break;
    default:
      emit({ type: "response", id: command.id, command: command.type, success: true });
  }
}
