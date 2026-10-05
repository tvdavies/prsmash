// prsmashd — event-driven prsmash.
//
// Watches open PRs and starts a review as soon as one becomes eligible, instead
// of waiting for the next timer tick. A PR whose head moves while its review is
// running gets a control message; prsmash-session steers the reviewer onto the
// new commits rather than throwing its context away.
//
// Events come from conditional polling of the open-PR list (If-None-Match, so
// an unchanged list costs nothing against the REST quota) plus a periodic full
// sweep for signals the list does not carry, such as resolved threads. The
// source is behind a small interface so a webhook relay can feed it later.
//
// What counts as eligible is unchanged: lib/review-queue.sh decides, and the
// per-PR prsmash run still re-checks dispositions and mergeability under the
// PR lock. A PR is "in review" exactly while that lock is held, which also
// covers reviews left running across a daemon restart.

import { spawn, spawnSync, execFileSync, type ChildProcess } from "node:child_process";
import { closeSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const { values: flags } = parseArgs({ options: { "dry-run": { type: "boolean", default: false } } });
const env = process.env;

const config = {
  dryRun: flags["dry-run"] === true,
  repo: env.PRSMASH_REPO || "lleverage-ai/lleverage",
  sourceRepo: env.PRSMASH_SOURCE_REPO || join(env.HOME ?? "", "dev/lleverage-ai/lleverage"),
  logRoot: env.PRSMASH_LOG_DIR || join(env.HOME ?? "", ".prsmash"),
  prsmash: env.PRSMASH_BIN || resolve(here, "../bin/prsmash"),
  queueScript: env.PRSMASH_DAEMON_QUEUE_SCRIPT || resolve(here, "../lib/review-queue.sh"),
  libDir: env.PRSMASH_LIB_DIR || resolve(here, "../lib"),
  apiUrl: env.PRSMASH_GITHUB_API || "https://api.github.com",
  maxConcurrent: positive(env.PRSMASH_MAX_CONCURRENT_REVIEWS, 4),
  pollSeconds: positive(env.PRSMASH_POLL_SECONDS, 20),
  sweepSeconds: positive(env.PRSMASH_SWEEP_SECONDS, 600),
  recheckMinSeconds: positive(env.PRSMASH_RECHECK_MIN_SECONDS, 20),
  approvalsSeconds: positive(env.PRSMASH_APPROVALS_SECONDS, 60),
  // "systemd-run": each review is a transient prsmash-run-* user unit, so it
  // gets that unit family's limits and slice and outlives a daemon restart.
  // Anything else: a detached child process (tests, manual runs).
  launcher: env.PRSMASH_REVIEW_LAUNCHER || "spawn",
  runtimeMaxSeconds: positive(env.PRSMASH_REVIEW_RUNTIME_MAX_SECONDS, 7800),
};

// Environment a transient unit needs; systemd-run starts it from a clean one.
const FORWARDED_ENV = /^(PATH|HOME|USER|LANG|PRSMASH_\w+|PI_\w+|PR_REVIEW_\w+|SLACK_MCP_\w+|GH_\w+|GITHUB_TOKEN)$/;

function positive(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function log(message: string): void {
  process.stdout.write(`${new Date().toISOString()} ${message}\n`);
}

const safeRepo = config.repo.replace(/[/:]/g, "_");
const lockPath = (pr: number) => join(config.logRoot, "locks", `pr-${safeRepo}-${pr}.lock`);
const controlDir = (pr: number) => join(config.logRoot, "control", `${safeRepo}-${pr}`);

// --- open-PR snapshot ---------------------------------------------------------

type PrState = { number: number; head: string; updatedAt: string; draft: boolean; requested: string };

export type EventSink = {
  // The PR is new or something about it changed.
  changed(prs: PrState[]): void;
};

class ConditionalPoller {
  private etags = new Map<string, string>();
  private bodies = new Map<string, unknown[]>();
  private token = "";

  private refreshToken(): void {
    this.token = execFileSync("gh", ["auth", "token"], { encoding: "utf8" }).trim();
  }

  private async page(n: number): Promise<unknown[]> {
    const url = `${config.apiUrl}/repos/${config.repo}/pulls?state=open&per_page=100&page=${n}`;
    if (!this.token) this.refreshToken();
    const headers: Record<string, string> = {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${this.token}`,
      "X-GitHub-Api-Version": "2022-11-28",
    };
    const etag = this.etags.get(url);
    if (etag && this.bodies.has(url)) headers["If-None-Match"] = etag;
    const response = await fetch(url, { headers, signal: AbortSignal.timeout(30_000) });
    if (response.status === 304) return this.bodies.get(url)!;
    if (response.status === 401) {
      this.token = "";
      throw new Error("GitHub rejected the token; will refresh it");
    }
    if (!response.ok) throw new Error(`GET ${url} -> ${response.status}`);
    const body = (await response.json()) as unknown[];
    const newEtag = response.headers.get("etag");
    if (newEtag) this.etags.set(url, newEtag);
    this.bodies.set(url, body);
    return body;
  }

  async poll(): Promise<PrState[]> {
    const prs: PrState[] = [];
    for (let n = 1; n <= 20; n++) {
      const page = (await this.page(n)) as Array<Record<string, any>>;
      for (const pr of page) {
        prs.push({
          number: pr.number,
          head: pr.head?.sha ?? "",
          updatedAt: pr.updated_at ?? "",
          draft: pr.draft === true,
          requested: (pr.requested_reviewers ?? []).map((r: { login: string }) => r.login).sort().join(","),
        });
      }
      if (page.length < 100) break;
    }
    return prs;
  }
}

// --- daemon state -------------------------------------------------------------

type QueueEntry = { number: number; headRefOid?: string; queueSource?: string; title?: string; author?: { login?: string } };
type QueueResult = { repo: string; user: string; prs: QueueEntry[] };

const known = new Map<number, PrState>();
const waiting = new Map<number, QueueEntry>(); // eligible, not yet started; insertion order = FIFO
const children = new Map<number, { child: ChildProcess; queueFile: string }>();
// Reviews still running from before this daemon started, found by their locks.
const orphans = new Set<number>();
const recheck = new Set<number>();
let queueUser = "";
let lastRecheckAt = 0;
let checking = false;
let fullSweepDue = true;
let stopping = false;

function lockHeld(pr: number): boolean {
  mkdirSync(dirname(lockPath(pr)), { recursive: true });
  return spawnSync("flock", ["-n", "-E", "99", lockPath(pr), "true"]).status === 99;
}

function findOrphans(): void {
  for (const pr of known.keys()) if (!children.has(pr) && lockHeld(pr)) orphans.add(pr);
}

// Reviews running now, whether this daemon started them or a previous one did.
function inReview(): Set<number> {
  for (const pr of orphans) {
    if (!lockHeld(pr)) {
      // Finished without us seeing it exit; let the queue decide what is next.
      orphans.delete(pr);
      clearControl(pr);
      recheck.add(pr);
    }
  }
  return new Set([...children.keys(), ...orphans]);
}

function writeControl(pr: number, message: Record<string, unknown>): void {
  const dir = controlDir(pr);
  mkdirSync(dir, { recursive: true });
  const name = `${Date.now()}-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  writeFileSync(join(dir, `${name}.tmp`), JSON.stringify(message));
  renameSync(join(dir, `${name}.tmp`), join(dir, `${name}.json`));
}

function clearControl(pr: number): void {
  rmSync(controlDir(pr), { recursive: true, force: true });
}

const sink: EventSink = {
  changed(prs) {
    for (const pr of prs) {
      const before = known.get(pr.number);
      known.set(pr.number, pr);
      const headMoved = before !== undefined && before.head !== pr.head;
      if (headMoved && (children.has(pr.number) || orphans.has(pr.number) || lockHeld(pr.number))) {
        if (config.dryRun) {
          log(`#${pr.number} would steer the running review onto ${pr.head.slice(0, 12)}`);
        } else {
          log(`#${pr.number} moved to ${pr.head.slice(0, 12)} mid-review; steering`);
          writeControl(pr.number, { type: "head-moved", head: pr.head });
        }
        continue;
      }
      if (pr.draft) {
        waiting.delete(pr.number);
        continue;
      }
      recheck.add(pr.number);
    }
  },
};

function diffSnapshot(prs: PrState[]): void {
  const open = new Set(prs.map((pr) => pr.number));
  for (const number of [...known.keys()]) {
    if (!open.has(number)) {
      known.delete(number);
      waiting.delete(number);
      recheck.delete(number);
    }
  }
  const changed = prs.filter((pr) => {
    const before = known.get(pr.number);
    return !before || before.head !== pr.head || before.updatedAt !== pr.updatedAt || before.requested !== pr.requested || before.draft !== pr.draft;
  });
  if (changed.length > 0) sink.changed(changed);
}

// --- eligibility ----------------------------------------------------------------

// Drop exact heads prsmash already handled (and nobody has answered since),
// using the same rule prsmash applies under the PR lock. Starting those would
// only take a slot to report HANDLED. Fails open: prsmash re-checks anyway.
function filterHandled(result: QueueResult): QueueResult {
  const script = `source "$1/review-disposition-state.sh"; review_disposition_state_init "$2"; filter_review_dispositions "$(cat)"`;
  const filtered = spawnSync("bash", ["-c", script, "filter", config.libDir, config.logRoot], {
    input: JSON.stringify(result),
    encoding: "utf8",
  });
  if (filtered.status !== 0) {
    log(`disposition filter failed: ${filtered.stderr.trim().slice(0, 200)}`);
    return result;
  }
  try {
    return JSON.parse(filtered.stdout) as QueueResult;
  } catch {
    return result;
  }
}

function runQueue(only: number[] | undefined): Promise<QueueResult | undefined> {
  const args = only ? ["--only", only.join(",")] : [];
  return new Promise((resolvePromise) => {
    const child = spawn(config.queueScript, args, { cwd: config.sourceRepo, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.stdout.on("data", (chunk) => (out += chunk));
    child.stderr.on("data", (chunk) => (err += chunk));
    child.on("exit", (code) => {
      if (code !== 0) {
        log(`queue check failed (${code}): ${err.trim().slice(0, 300)}`);
        return resolvePromise(undefined);
      }
      try {
        const parsed = JSON.parse(out) as QueueResult;
        if (!Array.isArray(parsed.prs)) throw new Error("no prs array");
        resolvePromise(filterHandled(parsed));
      } catch {
        // "No PRs are currently waiting…" is the script's empty answer.
        resolvePromise({ repo: config.repo, user: queueUser, prs: [] });
      }
    });
  });
}

async function checkEligibility(): Promise<void> {
  if (checking || stopping) return;
  const sweep = fullSweepDue;
  if (!sweep && (recheck.size === 0 || Date.now() - lastRecheckAt < config.recheckMinSeconds * 1000)) return;
  checking = true;
  const only = sweep ? undefined : [...recheck];
  recheck.clear();
  fullSweepDue = false;
  lastRecheckAt = Date.now();
  try {
    const result = await runQueue(only);
    if (!result) {
      if (only) only.forEach((n) => recheck.add(n));
      else fullSweepDue = true;
      return;
    }
    if (result.user) queueUser = result.user;
    const eligible = new Set<number>();
    for (const entry of result.prs) {
      if ((entry as { implicitRereview?: boolean }).implicitRereview) continue;
      eligible.add(entry.number);
      if (children.has(entry.number)) continue;
      if (!waiting.has(entry.number)) log(`#${entry.number} eligible (${entry.queueSource ?? "review-request"}): ${entry.title ?? ""}`);
      waiting.set(entry.number, entry);
    }
    // A checked PR that is no longer eligible (approved elsewhere, review
    // request withdrawn) leaves the waiting list.
    for (const number of only ?? [...waiting.keys()]) if (!eligible.has(number)) waiting.delete(number);
  } finally {
    checking = false;
  }
  schedule();
}

// --- running reviews ---------------------------------------------------------

function schedule(): void {
  if (stopping) return;
  const active = inReview();
  for (const [number, entry] of waiting) {
    if (active.size >= config.maxConcurrent) break;
    if (active.has(number)) continue;
    waiting.delete(number);
    start(entry);
    active.add(number);
  }
}

function start(entry: QueueEntry): void {
  const pr = entry.number;
  if (config.dryRun) {
    log(`#${pr} would start a review at ${(entry.headRefOid ?? "").slice(0, 12)}`);
    return;
  }
  const queueDir = join(config.logRoot, "daemon", "queue");
  mkdirSync(queueDir, { recursive: true });
  const queueFile = join(queueDir, `${safeRepo}-${pr}-${Date.now()}.json`);
  writeFileSync(queueFile, JSON.stringify({ in_repo: true, repo: config.repo, user: queueUser, prs: [entry] }));
  // Messages left for an earlier review are moot: this one starts at the current head.
  clearControl(pr);
  mkdirSync(controlDir(pr), { recursive: true });

  // Output goes to a file, and the review gets its own process group, so it
  // survives this daemon restarting (a pipe would SIGPIPE it).
  const outDir = join(config.logRoot, "daemon", "out");
  mkdirSync(outDir, { recursive: true });
  const outFile = join(outDir, `${safeRepo}-${pr}.log`);
  const reviewEnv: Record<string, string | undefined> = { ...env, PRSMASH_ALLOW_CONCURRENT: "1", PRSMASH_CONTROL_DIR: controlDir(pr) };
  const prsmashArgs = ["--all", "--queue-file", queueFile];
  let child: ChildProcess;
  let envFile = "";
  if (config.launcher === "systemd-run") {
    writeFileSync(outFile, "");
    const unit = `prsmash-run-pr${pr}-${new Date().toISOString().replace(/\D/g, "").slice(0, 14)}`;
    // Tokens must not sit in this command line for the hours a review runs
    // (any local user can read argv). They go in a private file that the
    // unit sources and deletes before starting prsmash.
    const envDir = join(config.logRoot, "daemon", "env");
    mkdirSync(envDir, { recursive: true, mode: 0o700 });
    envFile = join(envDir, `${unit}.env`);
    const quote = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;
    const lines = Object.entries(reviewEnv)
      .filter(([key, value]) => value !== undefined && FORWARDED_ENV.test(key))
      .map(([key, value]) => `${key}=${quote(value!)}`);
    writeFileSync(envFile, `${lines.join("\n")}\n`, { mode: 0o600 });
    child = spawn(
      "systemd-run",
      [
        "--user", "--wait", "--collect", "--quiet",
        `--unit=${unit}`,
        "--description=prsmash review",
        `--working-directory=${config.sourceRepo}`,
        `--property=RuntimeMaxSec=${config.runtimeMaxSeconds}`,
        `--property=StandardOutput=append:${outFile}`,
        `--property=StandardError=append:${outFile}`,
        "/bin/bash", "-c", 'set -a; . "$0"; set +a; rm -f -- "$0"; exec "$@"', envFile,
        config.prsmash, ...prsmashArgs,
      ],
      { stdio: "ignore", detached: true },
    );
  } else {
    const out = openSync(outFile, "w");
    child = spawn(config.prsmash, prsmashArgs, { cwd: config.sourceRepo, stdio: ["ignore", out, out], detached: true, env: reviewEnv });
    closeSync(out);
  }
  const head = entry.headRefOid ?? known.get(pr)?.head ?? "";
  children.set(pr, { child, queueFile });
  log(`#${pr} review started at ${head.slice(0, 12)} (${children.size} running)`);

  child.on("exit", (code) => {
    // prsmash's run log has the detail; the journal gets the outcome line.
    try {
      for (const line of readFileSync(outFile, "utf8").split("\n")) {
        const plain = line.replace(/\x1b\[[0-9;]*m/g, "").trim();
        if (/^\[\d+\/\d+\]|^Run logs:/.test(plain)) log(`#${pr} ${plain}`);
      }
    } catch {
      // no output
    }
    children.delete(pr);
    rmSync(queueFile, { force: true });
    if (envFile) rmSync(envFile, { force: true });
    clearControl(pr);
    log(`#${pr} review process exited (${code})`);
    // Always look again: the head may have moved after the reviewer stopped
    // listening, the review may have been superseded, or a control message
    // may have gone unread. The queue and dispositions decide what happens.
    if (known.has(pr)) recheck.add(pr);
    schedule();
  });
}

let approvalsRunning = false;
function processApprovals(): void {
  if (config.dryRun || approvalsRunning || stopping) return;
  approvalsRunning = true;
  const child = spawn(config.prsmash, ["--approvals-only"], {
    cwd: config.sourceRepo,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...env, PRSMASH_ALLOW_CONCURRENT: "1" },
  });
  let out = "";
  child.stdout.on("data", (c) => (out += c));
  child.stderr.on("data", (c) => (out += c));
  child.on("exit", () => {
    approvalsRunning = false;
    const plain = out.replace(/\x1b\[[0-9;]*m/g, "").trim();
    if (plain) log(`approvals: ${plain.split("\n").slice(-5).join(" | ")}`);
  });
}

// --- main loop ------------------------------------------------------------------

async function pollLoop(poller: ConditionalPoller): Promise<void> {
  let first = true;
  while (!stopping) {
    try {
      diffSnapshot(await poller.poll());
      if (first) {
        findOrphans();
        if (orphans.size > 0) log(`found ${orphans.size} review(s) already running: ${[...orphans].map((n) => `#${n}`).join(" ")}`);
        first = false;
      }
      await checkEligibility();
      schedule();
    } catch (error) {
      log(`poll failed: ${(error as Error).message}`);
    }
    await new Promise((r) => setTimeout(r, config.pollSeconds * 1000));
  }
}

function shutdown(): void {
  if (stopping) return;
  stopping = true;
  log(`stopping; ${children.size} review(s) keep running and stay locked`);
  // Reviews are detached on purpose: a restart (deploy, crash) must not throw
  // away work in flight. The next daemon finds them through their PR locks.
  process.exit(0);
}

function main(): void {
  log(`prsmashd ${config.dryRun ? "(dry run) " : ""}watching ${config.repo}; max ${config.maxConcurrent} concurrent, poll ${config.pollSeconds}s, sweep ${config.sweepSeconds}s`);
  // Clear stale control messages for reviews that are not running.
  try {
    for (const name of readdirSync(join(config.logRoot, "control"))) {
      const pr = Number(name.split("-").pop());
      if (Number.isInteger(pr) && !lockHeld(pr)) rmSync(join(config.logRoot, "control", name), { recursive: true, force: true });
    }
  } catch {
    // no control directory yet
  }
  setInterval(() => {
    fullSweepDue = true;
    findOrphans();
  }, config.sweepSeconds * 1000).unref();
  setInterval(processApprovals, config.approvalsSeconds * 1000).unref();
  // Free slots held by reviews a previous daemon started.
  setInterval(schedule, 15_000).unref();
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  processApprovals();
  void pollLoop(new ConditionalPoller());
}

main();
