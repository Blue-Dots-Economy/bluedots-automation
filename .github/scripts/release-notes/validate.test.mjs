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

test('candidate tag prints its kind and develop', () => {
  const r = validate({ TAG: '202610-s1-rc1' });
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), 'candidate develop');
  assert.equal(r.stderr, '');
});

test('release and hotfix tags derive main and the release branch', () => {
  assert.equal(validate({ TAG: '202610-s1' }).stdout.trim(), 'release main');
  assert.equal(validate({ TAG: '202610-s1.2' }).stdout.trim(), 'hotfix release/202610-s1');
});

test('a base set for a sprint tag is ignored with a notice on stderr', () => {
  const r = validate({ TAG: '202610-s1-rc1', BASE: 'main' });
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), 'candidate develop');
  assert.match(r.stderr, /^::notice title=Base ignored::.*develop/);
});

test('version tag uses BASE, default main', () => {
  assert.equal(validate({ TAG: 'v1.2.0' }).stdout.trim(), 'version main');
  assert.equal(validate({ TAG: 'v1.2.0', BASE: 'develop' }).stdout.trim(), 'version develop');
});

test('extra pattern admits a prefixed tag as a version tag', () => {
  const r = validate({ TAG: 'api-v1.2.0', EXTRA_TAG_PATTERN: '^(api|web|worker)-v[0-9]+\\.[0-9]+\\.[0-9]+$' });
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), 'version main');
});

test('a bad base exits 1', () => {
  const r = validate({ TAG: 'v1.2.0', BASE: 'a b' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /::error title=Bad base::/);
  assert.equal(r.stdout, '');
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
