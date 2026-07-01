import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { evaluate } from './gate.mjs';

function loadEvent() {
  const path = process.env.GITHUB_EVENT_PATH;
  if (!path) throw new Error('GITHUB_EVENT_PATH not set');
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

function changedFiles(repo, prNumber) {
  // Escape hatch for local/dry-run testing.
  if (process.env.PR_FILES !== undefined) {
    return process.env.PR_FILES.split('\n').map((s) => s.trim()).filter(Boolean);
  }
  const out = execFileSync(
    'gh',
    ['api', `repos/${repo}/pulls/${prNumber}/files`, '--paginate', '-q', '.[].path'],
    { encoding: 'utf8' },
  );
  return out.split('\n').map((s) => s.trim()).filter(Boolean);
}

function main() {
  const event = loadEvent();
  const pr = event.pull_request;
  if (!pr) {
    console.error('No pull_request in event payload; nothing to check.');
    process.exit(0);
  }
  const body = pr.body || '';
  const labels = (pr.labels || []).map((l) => l.name);
  const repo = process.env.GITHUB_REPOSITORY;
  const files = changedFiles(repo, pr.number);

  const result = evaluate({ body, labels, files });
  if (result.pass) {
    console.log('✅ PR gate passed: release notes present and docs updated (or waived).');
    process.exit(0);
  }
  console.error('❌ PR gate failed:');
  for (const f of result.failures) console.error(`  - ${f}`);
  process.exit(1);
}

main();
