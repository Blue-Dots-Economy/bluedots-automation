// IO shell for the sync-release-branch workflow. All logic lives in sync.mjs
// (unit-tested); this file only talks to gh and the filesystem. Every child process
// gets an argv array (execFileSync), never a shell string, so branch names are never
// interpreted by a shell.
//
//   REF REPOSITORY GH_TOKEN RUNNER_TEMP [GITHUB_STEP_SUMMARY]
//     For each target in TARGETS, opens a PR release/<sprint> -> target when the
//     target lacks commits from the release branch, and leaves an open one alone.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { TARGETS, releaseBranchFromRef, syncDecision, prTitle, prBody } from './sync.mjs';

function env(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

/** Run a command; returns trimmed stdout. Errors carry stderr, never the raw argv error. */
function run(cmd, args) {
  try {
    return execFileSync(cmd, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: 16 * 1024 * 1024,
    }).trim();
  } catch (err) {
    const e = new Error(`${cmd} ${args.join(' ')} failed: ${String(err.stderr || err.message).trim()}`);
    e.stderr = String(err.stderr ?? '');
    throw e;
  }
}

const gh = (args) => run('gh', args);
const ghJson = (args) => JSON.parse(gh(args) || 'null');

function appendSummary(text) {
  const f = process.env.GITHUB_STEP_SUMMARY;
  if (f) fs.appendFileSync(f, text.endsWith('\n') ? text : `${text}\n`);
}

function branchExists(repo, branch) {
  try {
    gh(['api', `repos/${repo}/git/ref/heads/${branch}`, '--jq', '.ref']);
    return true;
  } catch (err) {
    if (/HTTP 404|Not Found/i.test(err.stderr ?? '')) return false;
    throw err;
  }
}

const openPrUrl = (repo, branch, target) =>
  (ghJson(['pr', 'list', '--repo', repo, '--head', branch, '--base', target, '--state', 'open', '--json', 'url']) ?? [])[0]?.url ?? null;

function main() {
  const ref = env('REF');
  const repo = env('REPOSITORY');
  const temp = env('RUNNER_TEMP');
  const branch = releaseBranchFromRef(ref);
  if (!branch) {
    console.log(`::notice title=Not a release branch::${ref} is not release/<YYYYMM-sN>; nothing to sync.`);
    return;
  }

  for (const target of TARGETS) {
    const targetExists = branchExists(repo, target);
    const aheadBy = targetExists
      ? Number(gh(['api', `repos/${repo}/compare/${target}...${branch}`, '--jq', '.ahead_by']))
      : 0;
    const existing = targetExists && aheadBy > 0 ? openPrUrl(repo, branch, target) : null;
    const action = syncDecision({ targetExists, aheadBy, openPrUrl: existing });

    if (action === 'missing') {
      console.log(`::notice title=No ${target} branch::${repo} has no ${target} branch; skipped.`);
    } else if (action === 'in-sync') {
      console.log(`::notice title=${target} is up to date::${target} already has every commit on ${branch}; no PR needed.`);
    } else if (action === 'keep') {
      console.log(`::notice title=Sync PR already open::${existing} (${branch} -> ${target}) now includes the new commits.`);
      appendSummary(`- ${target}: already open, ${existing}`);
    } else {
      const bodyFile = path.join(temp, `sync-${target}.md`);
      fs.writeFileSync(bodyFile, prBody(branch, target));
      let url;
      try {
        url = gh(['pr', 'create', '--repo', repo, '--base', target, '--head', branch,
          '--title', prTitle(branch, target), '--body-file', bodyFile]);
      } catch (err) {
        // A concurrent run may have opened it between our list and create.
        url = openPrUrl(repo, branch, target);
        if (!url) throw err;
      }
      console.log(`::notice title=Sync PR opened::${url} (${branch} -> ${target}, ${aheadBy} commit(s)).`);
      appendSummary(`- ${target}: opened ${url}`);
    }
  }
}

try {
  main();
} catch (err) {
  // Workflow-command data must escape %, CR and LF or the message is cut at the first newline.
  const data = String(err.message).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
  console.error(`::error title=sync-release-branch::${data}`);
  process.exit(1);
}
