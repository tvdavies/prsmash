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
  return execFileSync("git", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 120_000,
    maxBuffer: 16 * 1024 * 1024,
  }).trim();
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
// A steer sent since pi last went idle. pi queues a steer that reaches an idle
// session without starting a run, so after every settle these are reclaimed
// (clear_queue) and re-sent as a prompt.
let steerUnconfirmed = false;
let finishing = false;
const startedAt = Date.now();
let deadline = startedAt + baseTimeoutMs;
const hardDeadline = startedAt + maxTimeoutMs;
const pending = new Map<string, (record: Record<string, unknown>) => void>();

// Every RPC request is bounded: a pi that stops answering must not hold the
// session past its deadline. A timeout resolves as a failed response.
function send(command: Record<string, unknown>, timeoutMs = 120_000): Promise<Record<string, unknown>> {
  const id = `prsmash-${++requestId}`;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      resolve({ type: "response", id, success: false, error: `no response to ${String(command.type)} after ${timeoutMs / 1000}s` });
    }, timeoutMs);
    pending.set(id, (record) => {
      clearTimeout(timer);
      resolve(record);
    });
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

const controlRetryMs = seconds(env.PRSMASH_CONTROL_RETRY_SECONDS, 10) * 1000;
const controlGiveUpMs = seconds(env.PRSMASH_CONTROL_GIVE_UP_SECONDS, 300) * 1000;
const controlFailures = new Map<string, { first: number; last: number }>();

// Control files stay on disk until handled, so a transient failure (a fetch
// that times out) is retried on the next poll rather than lost.
function controlMessages(): Array<{ path: string; message: ControlMessage | undefined }> {
  if (!controlDir || !existsSync(controlDir)) return [];
  const now = Date.now();
  return readdirSync(controlDir)
    .filter((n) => n.endsWith(".json"))
    .sort()
    .filter((name) => {
      const failed = controlFailures.get(join(controlDir, name));
      return !failed || now - failed.last >= controlRetryMs;
    })
    .map((name) => {
      const path = join(controlDir, name);
      try {
        return { path, message: JSON.parse(readFileSync(path, "utf8")) as ControlMessage };
      } catch (error) {
        note(`ignoring unreadable control message ${name}: ${(error as Error).message}`);
        return { path, message: undefined };
      }
    });
}

type Delta = { from: string; to: string; files: string[]; lines: number; commits: string; diffPath: string };
type Move = Delta | { superseded: string } | "nothing" | "retry";

// Fetch the PR's current head and describe what changed since the head under
// review. The size limit is checked before the patch is written, so an
// enormous delta supersedes the review instead of overflowing a buffer.
function describeMove(requested: string): Move {
  const from = readExpectedHead() || git("rev-parse", "HEAD");
  if (requested === from) return "nothing";
  try {
    git("fetch", "-q", "origin", `+pull/${prNumber}/head`);
  } catch (error) {
    note(`could not fetch PR head: ${(error as Error).message}`);
    return "retry";
  }
  const to = git("rev-parse", "FETCH_HEAD");
  if (to === from) return "nothing";
  if (to !== requested) note(`asked to move to ${requested}, GitHub now has ${to}; using ${to}`);
  try {
    // A head we already cover (an older notification arriving late).
    git("merge-base", "--is-ancestor", to, from);
    return "nothing";
  } catch {
    // not an ancestor: genuinely new
  }
  try {
    git("merge-base", "--is-ancestor", from, to);
  } catch {
    return { superseded: `${to} does not contain ${from} (force-push or rebase)` };
  }
  const numstat = git("diff", "--numstat", from, to);
  const files: string[] = [];
  let lines = 0;
  for (const row of numstat.split("\n").filter(Boolean)) {
    const [added, deleted, ...path] = row.split("\t");
    files.push(path.join("\t"));
    lines += (Number(added) || 0) + (Number(deleted) || 0);
  }
  if (lines > steerMaxLines) return { superseded: `delta of ${lines} lines exceeds ${steerMaxLines}` };
  const diffPath = join(tmpDir, `delta-${from.slice(0, 12)}-${to.slice(0, 12)}.diff`);
  mkdirSync(tmpDir, { recursive: true });
  git("diff", `--output=${diffPath}`, from, to);
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
  await send({ type: "abort" }, 60_000);
}

async function handleControl(): Promise<void> {
  for (const { path, message } of controlMessages()) {
    if (superseded) return;
    const valid = message?.type === "head-moved" && /^[0-9a-f]{40}$/.test(message.head ?? "");
    const move = valid ? describeMove(message!.head) : "nothing";
    if (move === "retry") {
      const now = Date.now();
      const failed = controlFailures.get(path) ?? { first: now, last: now };
      controlFailures.set(path, { first: failed.first, last: now });
      if (now - failed.first < controlGiveUpMs) continue;
      note(`giving up on ${path} after ${Math.round((now - failed.first) / 1000)}s of failures`);
    }
    rmSync(path, { force: true });
    controlFailures.delete(path);
    if (move === "nothing" || move === "retry") continue;
    if ("superseded" in move) return supersede(move.superseded);
    if (steers >= maxSteers) return supersede(`head moved more than ${maxSteers} times`);
    const delta = move;

    // The helper only accepts this head when the reviewer names it with
    // --expected-head, so moving the file early cannot let a reviewer still
    // finishing the old head publish against the new one.
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
    else steerUnconfirmed = true;
    const response = await send(command);
    if (response.success !== true) {
      // The expected head has moved but the reviewer may never hear about it.
      // Finishing normally would record a head nobody reviewed, so give the
      // review up and let the new head be reviewed from scratch.
      if (followUp) running = false;
      return supersede(`could not deliver the move to ${delta.to}: ${String(response.error)}`);
    }
  }
}

// After pi goes idle, a steer that arrived as it settled sits in its queue
// and would never run. Take it back and send it as a prompt.
async function reclaimQueuedSteers(): Promise<void> {
  if (!steerUnconfirmed) return;
  steerUnconfirmed = false;
  const cleared = await send({ type: "clear_queue" });
  if (cleared.success !== true) {
    return supersede(`could not confirm the steer was delivered: ${String(cleared.error)}`);
  }
  const queued = ((cleared.data as { steering?: string[] } | undefined)?.steering ?? []).filter(Boolean);
  if (queued.length === 0) return;
  note(`a steer reached pi as it settled; sending it as a follow-up`);
  running = true;
  const response = await send({ type: "prompt", message: queued.join("\n\n") });
  if (response.success !== true) {
    running = false;
    return supersede(`could not resend the steer: ${String(response.error)}`);
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

// The one way out. The first caller fixes the exit code synchronously, so a
// timeout that fires while the main loop is awaiting cannot be overtaken by a
// later "settled normally" exit; later callers wait on the same ending.
let terminal: Promise<never> | undefined;
function shutdown(code: number, options: { abortFirst?: boolean } = {}): Promise<never> {
  if (terminal) return terminal;
  finishing = true;
  terminal = (async (): Promise<never> => {
    if (options.abortFirst) {
      await send({ type: "abort" }, 30_000);
      killPi("SIGTERM");
    }
    pi.stdin!.end();
    const exited = await Promise.race([piExited, sleep(30_000).then(() => undefined)]);
    if (exited === undefined) {
      killPi("SIGTERM");
      await Promise.race([piExited, sleep(10_000)]);
      killPi("SIGKILL");
    }
    process.exit(code);
  })();
  return terminal;
}

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) {
  process.on(signal, () => {
    if (finishing) return;
    finishing = true;
    terminal = new Promise<never>(() => {});
    killPi("SIGTERM");
    setTimeout(() => {
      killPi("SIGKILL");
      process.exit(143);
    }, 5_000).unref();
    void piExited.then(() => process.exit(143));
  });
}

// The deadline is enforced on its own timer, so an awaited RPC call or a
// blocked control step cannot hold the session past it.
let timingOut = false;
const watchdog = setInterval(() => {
  if (timingOut || finishing || Date.now() <= Math.min(deadline, hardDeadline)) return;
  timingOut = true;
  process.stdout.write(`PRSMASH_REVIEW_TIMEOUT: no result after ${Math.round((Date.now() - startedAt) / 1000)}s\n`);
  void shutdown(EXIT_TIMEOUT, { abortFirst: true });
}, 1_000);
watchdog.unref();

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
    if (finishing) return;
    if (piGone) break;
    if (!superseded) await handleControl();
    if (finishing) return;
    if (superseded && !running) break;
    if (running || superseded) continue;
    await reclaimQueuedSteers();
    if (finishing) return;
    if (superseded) break;
    if (running) continue;
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
    await shutdown(1);
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

main().catch(async (error: unknown) => {
  note(`session failed: ${(error as Error).stack ?? String(error)}`);
  killPi("SIGTERM");
  await shutdown(1);
});
