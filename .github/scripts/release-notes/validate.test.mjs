import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./validate.mjs', import.meta.url));

function validate(env) {
  return spawnSync(process.execPath, [script], {
    encoding: 'utf8',
    env: { PATH: process.env.PATH, ...env },
  });
}

test('sprint tag prints true and exits 0', () => {
  const r = validate({ TAG: '202610-s1-rc1' });
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), 'true');
  assert.equal(r.stderr, '');
});

test('version tag prints false and exits 0', () => {
  const r = validate({ TAG: 'v1.2.0' });
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), 'false');
});

test('extra pattern admits a prefixed tag as non-sprint', () => {
  const r = validate({ TAG: 'api-v1.2.0', EXTRA_TAG_PATTERN: '^(api|web|worker)-v[0-9]+\\.[0-9]+\\.[0-9]+$' });
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), 'false');
});

test('bad tag exits 1 with an ::error on stderr and nothing on stdout', () => {
  const r = validate({ TAG: '202610-s1-rc1-hotfix' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /::error title=Bad tag name::/);
  assert.equal(r.stdout, '');
});

test('error data escapes % and newlines', () => {
  const r = validate({ TAG: 'bad%\ntag' });
  assert.equal(r.status, 1);
  assert.equal(r.stderr.trim().split('\n').length, 1);
  assert.match(r.stderr, /bad%25%0Atag/);
});
