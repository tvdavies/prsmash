// prsmash-session — run one pr-review in pi's RPC mode so prsmashd can steer it.
//
// Stands in for `pi -p` in run_pr_review. Behaves the same towards prsmash: the
// final assistant text goes to stdout, an errored or aborted final turn exits 1
// with the error on stderr. On top of that it watches PRSMASH_CONTROL_DIR for
// control messages from prsmashd. When the PR head moves, the new commits are
// fetched, the expected-head file the posting helper reads is moved forward,
// and the agent is steered onto the delta instead of being killed, so the
// context it has gathered survives. A force-push, an oversized delta or too
// many moves abort the review with exit 75 (superseded) so prsmash leaves the
// head unrecorded and prsmashd starts a fresh review.
//
// Exit codes: 0 settled, 1 error, 75 superseded, 124 timed out, 143 terminated.

import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { readJsonl } from "./jsonl.ts";

export const EXIT_SUPERSEDED = 75;
export const EXIT_TIMEOUT = 124;

const { values: opts } = parseArgs({
  options: {
    pi: { type: "string", default: process.env.PRSMASH_PI_BIN || "pi" },
    "session-dir": { type: "string" },
    skill: { type: "string" },
    model: { type: "string" },
    thinking: { type: "string" },
    prompt: { type: "string" },
    pr: { type: "string" },
    timeout: { type: "string" },
    "max-timeout": { type: "string" },
  },
});

const env = process.env;
const controlDir = env.PRSMASH_CONTROL_DIR || "";
const expectedHeadFile = env.PRSMASH_REVIEW_EXPECTED_HEAD_FILE || "";
const resultFile = env.PRSMASH_REVIEW_RESULT_FILE || "";
const tmpDir = env.PR_REVIEW_TMPDIR || env.TMPDIR || "/tmp";
const prNumber = opts.pr || "";
const graceMs = seconds(env.PRSMASH_SESSION_GRACE_SECONDS, 40) * 1000;
const pollMs = seconds(env.PRSMASH_SESSION_POLL_SECONDS, 2) * 1000;
const maxSteers = int(env.PRSMASH_MAX_STEERS, 3);
const steerMaxLines = int(env.PRSMASH_STEER_MAX_LINES, 600);
const baseTimeoutMs = seconds(opts.timeout, 2700) * 1000;
const maxTimeoutMs = Math.max(baseTimeoutMs, seconds(opts["max-timeout"], 7200) * 1000);

if (!opts.prompt) fail("--prompt is required");

function seconds(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function int(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function fail(message: string): never {
  process.stderr.write(`prsmash-session: ${message}\n`);
  process.exit(1);
}

function note(message: string): void {
  process.stderr.write(`[prsmash-session ${new Date().toISOString()}] ${message}\n`);
}

function git(...args: string[]): string {
  return execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function readExpectedHead(): string {
  if (!expectedHeadFile || !existsSync(expectedHeadFile)) return "";
  return readFileSync(expectedHeadFile, "utf8").trim();
}

function writeExpectedHead(head: string): void {
  const tmp = `${expectedHeadFile}.tmp.${process.pid}`;
  writeFileSync(tmp, `${head}\n`);
  renameSync(tmp, expectedHeadFile);
}

// --- pi process -------------------------------------------------------------

type AssistantMessage = {
  role: "assistant";
  content?: Array<{ type: string; text?: string }>;
  stopReason?: string;
  errorMessage?: string;
};

const piArgs = ["--mode", "rpc"];
if (opts.model) piArgs.push("--model", opts.model);
if (opts.thinking) piArgs.push("--thinking", opts.thinking);
if (opts["session-dir"]) piArgs.push("--session-dir", opts["session-dir"]);
if (opts.skill) piArgs.push("--skill", opts.skill);

const pi: ChildProcess = spawn(opts.pi!, piArgs, { stdio: ["pipe", "pipe", "inherit"], detached: true });

let requestId = 0;
let running = false;
let settledAt = 0;
let lastAssistant: AssistantMessage | undefined;
let steers = 0;
let finishing = false;
const startedAt = Date.now();
let deadline = startedAt + baseTimeoutMs;
const hardDeadline = startedAt + maxTimeoutMs;
const pending = new Map<string, (record: Record<string, unknown>) => void>();

function send(command: Record<string, unknown>): Promise<Record<string, unknown>> {
  const id = `prsmash-${++requestId}`;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    pi.stdin!.write(`${JSON.stringify({ ...command, id })}\n`);
  });
}

function killPi(signal: NodeJS.Signals): void {
  if (pi.pid === undefined || pi.exitCode !== null) return;
  try {
    process.kill(-pi.pid, signal);
  } catch {
    try {
      pi.kill(signal);
    } catch {
      // already gone
    }
  }
}

readJsonl(
  pi.stdout!,
  (raw) => {
    const record = raw as Record<string, unknown>;
    switch (record.type) {
      case "response": {
        const resolve = pending.get(String(record.id));
        if (resolve) {
          pending.delete(String(record.id));
          resolve(record);
        }
        break;
      }
      case "agent_start":
        running = true;
        break;
      case "agent_settled":
        running = false;
        settledAt = Date.now();
        break;
      case "message_end": {
        const message = record.message as AssistantMessage | undefined;
        if (message?.role === "assistant") {
          lastAssistant = message;
          if (message.stopReason === "error" && message.errorMessage) note(`assistant error: ${message.errorMessage}`);
        }
        break;
      }
      case "auto_retry_start":
        // Keeps the provider error in the log, where prsmash's is_retryable looks.
        note(`retrying after: ${String(record.errorMessage ?? "")}`);
        break;
      case "auto_retry_end":
        if (record.success === false) note(`retries exhausted: ${String(record.finalError ?? "")}`);
        break;
      case "extension_error":
        note(`extension error (${String(record.extensionPath)}): ${String(record.error)}`);
        break;
      case "extension_ui_request": {
        // Headless: nobody can answer a dialog. Cancel it rather than block.
        const method = String(record.method);
        if (["select", "confirm", "input", "editor"].includes(method)) {
          note(`cancelled extension dialog (${method}): ${String(record.title ?? "")}`);
          pi.stdin!.write(`${JSON.stringify({ type: "extension_ui_response", id: record.id, cancelled: true })}\n`);
        }
        break;
      }
    }
  },
  (line) => note(`unparsable RPC line: ${line.slice(0, 200)}`),
);

const piExited = new Promise<number>((resolve) => {
  pi.on("exit", (code, signal) => resolve(code ?? (signal ? 128 : 1)));
  pi.on("error", (error) => {
    note(`could not start pi: ${error.message}`);
    resolve(1);
  });
});

// --- control messages -------------------------------------------------------

type ControlMessage = { type: "head-moved"; head: string };

function takeControlMessages(): ControlMessage[] {
  if (!controlDir || !existsSync(controlDir)) return [];
  const messages: ControlMessage[] = [];
  for (const name of readdirSync(controlDir).filter((n) => n.endsWith(".json")).sort()) {
    const path = join(controlDir, name);
    try {
      messages.push(JSON.parse(readFileSync(path, "utf8")) as ControlMessage);
    } catch (error) {
      note(`ignoring unreadable control message ${name}: ${(error as Error).message}`);
    }
    rmSync(path, { force: true });
  }
  return messages;
}

type Delta = { from: string; to: string; files: string[]; lines: number; commits: string; diffPath: string };

// Fetch the PR's current head and describe what changed since the head under
// review. Returns undefined when there is nothing new to say.
function describeMove(requested: string): Delta | "superseded" | undefined {
  const from = readExpectedHead() || git("rev-parse", "HEAD");
  if (requested === from) return undefined;
  try {
    git("fetch", "-q", "origin", `+pull/${prNumber}/head`);
  } catch (error) {
    note(`could not fetch PR head: ${(error as Error).message}`);
    return undefined;
  }
  const to = git("rev-parse", "FETCH_HEAD");
  if (to === from) return undefined;
  if (to !== requested) note(`asked to move to ${requested}, GitHub now has ${to}; using ${to}`);
  try {
    // A head we already cover (an older notification arriving late).
    git("merge-base", "--is-ancestor", to, from);
    return undefined;
  } catch {
    // not an ancestor: genuinely new
  }
  try {
    git("merge-base", "--is-ancestor", from, to);
  } catch {
    note(`${to} does not contain ${from} (force-push or rebase)`);
    return "superseded";
  }
  const numstat = git("diff", "--numstat", from, to);
  const files: string[] = [];
  let lines = 0;
  for (const row of numstat.split("\n").filter(Boolean)) {
    const [added, deleted, ...path] = row.split("\t");
    files.push(path.join("\t"));
    lines += (Number(added) || 0) + (Number(deleted) || 0);
  }
  const diffPath = join(tmpDir, `delta-${from.slice(0, 12)}-${to.slice(0, 12)}.diff`);
  mkdirSync(tmpDir, { recursive: true });
  writeFileSync(diffPath, git("diff", from, to));
  const commits = git("log", "--format=- %h %s", `${from}..${to}`);
  return { from, to, files, lines, commits, diffPath };
}

function steerText(delta: Delta): string {
  const fileList = delta.files.map((f) => `- ${f}`).join("\n");
  return [
    `prsmash: PR #${prNumber} moved while you were reviewing it.`,
    `New head ${delta.to} (was ${delta.from}): ${delta.lines} changed lines in ${delta.files.length} file(s).`,
    "",
    "Commits:",
    delta.commits,
    "",
    "Files:",
    fileList,
    "",
    `The delta diff is at ${delta.diffPath}. The new head is fetched, but the worktree is still checked out at ${delta.from}.`,
    `Finish the step you are on, then run \`git checkout --detach ${delta.to}\` in the worktree and extend the review to cover ${delta.from}..${delta.to}:`,
    "review the delta, re-check every finding or conclusion that touches these files, and refresh CI/check status for the new head.",
    "Keep what you have already verified for unchanged files; do not restart the review.",
    `Publish only against ${delta.to} (\`--expected-head ${delta.to}\`); prsmash has already moved the expected head.`,
    "A publication refused because the head moved is superseded by this message: publish against the new head once the delta is reviewed.",
    "Do not stop or report head drift for this move.",
  ].join("\n");
}

let superseded = false;

async function supersede(reason: string): Promise<void> {
  if (superseded) return;
  superseded = true;
  process.stdout.write(`PRSMASH_SUPERSEDED: ${reason}\n`);
  await Promise.race([send({ type: "abort" }), sleep(60_000)]);
}

async function handleControl(): Promise<void> {
  for (const message of takeControlMessages()) {
    if (superseded || message.type !== "head-moved" || !/^[0-9a-f]{40}$/.test(message.head ?? "")) continue;
    const delta = describeMove(message.head);
    if (delta === undefined) continue;
    if (delta === "superseded") return supersede("head was force-pushed or rebased");
    if (steers >= maxSteers) return supersede(`head moved more than ${maxSteers} times`);
    if (delta.lines > steerMaxLines) return supersede(`delta of ${delta.lines} lines exceeds ${steerMaxLines}`);

    writeExpectedHead(delta.to);
    steers += 1;
    deadline = Math.min(hardDeadline, deadline + Math.max(600_000, baseTimeoutMs / 3));
    const text = steerText(delta);
    const followUp = !running;
    const command = followUp ? { type: "prompt", message: text } : { type: "steer", message: text };
    note(`${followUp ? "following up" : "steering"} onto ${delta.to} (${delta.lines} lines, ${delta.files.length} files)`);
    // Mark the follow-up as running before sending: its agent_settled can be
    // processed before this response resolves.
    if (followUp) running = true;
    const response = await send(command);
    if (response.success !== true) {
      note(`${command.type} rejected: ${String(response.error)}`);
      if (followUp) running = false;
    }
  }
}

function postedForExpectedHead(): boolean {
  if (!resultFile || !existsSync(resultFile)) return false;
  try {
    const result = JSON.parse(readFileSync(resultFile, "utf8")) as { head?: string; event?: string; posting?: string };
    return result.head === readExpectedHead() && Boolean(result.event || result.posting);
  } catch {
    return false;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function shutdown(code: number): Promise<never> {
  finishing = true;
  pi.stdin!.end();
  const exited = await Promise.race([piExited, sleep(30_000).then(() => undefined)]);
  if (exited === undefined) {
    killPi("SIGTERM");
    await Promise.race([piExited, sleep(10_000)]);
    killPi("SIGKILL");
  }
  process.exit(code);
}

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) {
  process.on(signal, () => {
    if (finishing) return;
    finishing = true;
    killPi("SIGTERM");
    setTimeout(() => {
      killPi("SIGKILL");
      process.exit(143);
    }, 5_000).unref();
    void piExited.then(() => process.exit(143));
  });
}

async function main(): Promise<void> {
  const accepted = await Promise.race([send({ type: "prompt", message: opts.prompt }), piExited.then(() => undefined)]);
  if (accepted === undefined) fail("pi exited before accepting the prompt");
  if (accepted.success !== true) fail(`prompt rejected: ${String(accepted.error)}`);
  // agent_settled can only precede this response for a run that already ended.
  if (settledAt === 0) running = (accepted.data as { disposition?: string } | undefined)?.disposition !== "handled";

  let piGone = false;
  void piExited.then(() => {
    piGone = true;
  });

  while (true) {
    await sleep(pollMs);
    if (piGone) break;
    if (Date.now() > Math.min(deadline, hardDeadline)) {
      process.stdout.write(`PRSMASH_REVIEW_TIMEOUT: no result after ${Math.round((Date.now() - startedAt) / 1000)}s\n`);
      await Promise.race([send({ type: "abort" }), sleep(30_000)]);
      killPi("SIGTERM");
      await shutdown(EXIT_TIMEOUT);
    }
    if (!superseded) await handleControl();
    if (superseded && !running) break;
    if (running || superseded) continue;
    // Settled. Unless the review is already published for the current head,
    // linger briefly: a push that lands as the reviewer finishes (often the
    // reason publication was refused) is cheaper to cover in this session
    // than in a cold one.
    if (!postedForExpectedHead() && Date.now() - settledAt < graceMs) continue;
    break;
  }

  if (superseded) await shutdown(EXIT_SUPERSEDED);

  if (piGone && running) {
    note("pi exited before the review settled");
    process.exit(1);
  }

  const text = (lastAssistant?.content ?? [])
    .filter((block) => block.type === "text" && block.text)
    .map((block) => block.text)
    .join("\n");
  if (text) process.stdout.write(`${text}\n`);
  if (lastAssistant?.stopReason === "error" || lastAssistant?.stopReason === "aborted") {
    process.stderr.write(`${lastAssistant.errorMessage || `Request ${lastAssistant.stopReason}`}\n`);
    await shutdown(1);
  }
  await shutdown(0);
}

void main();
