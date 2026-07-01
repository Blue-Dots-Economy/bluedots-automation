import { test } from 'node:test';
import assert from 'node:assert/strict';
import { hasReleaseNotes } from './gate.mjs';

test('release notes present with content', () => {
  const body = '## Summary\nstuff\n\n## Release Notes\n- Added export button\n';
  assert.equal(hasReleaseNotes(body), true);
});

test('missing release notes heading', () => {
  assert.equal(hasReleaseNotes('## Summary\njust a summary'), false);
});

test('empty body', () => {
  assert.equal(hasReleaseNotes(''), false);
  assert.equal(hasReleaseNotes(null), false);
});

test('heading present but section empty', () => {
  assert.equal(hasReleaseNotes('## Release Notes\n\n## Checklist\n- [ ] x'), false);
});

test('heading present but only an HTML comment (untouched template)', () => {
  const body = '## Release Notes\n<!-- list user-facing changes -->\n';
  assert.equal(hasReleaseNotes(body), false);
});

test('alternate casing and underscore spelling', () => {
  assert.equal(hasReleaseNotes('### release_notes\n- change'), true);
  assert.equal(hasReleaseNotes('# RELEASE NOTES\n- change'), true);
});

test('content stops at next heading', () => {
  const body = '## Release Notes\n- real change\n## Notes\nignored';
  assert.equal(hasReleaseNotes(body), true);
});

import { hasDocUpdate } from './gate.mjs';

test('README.md at repo root counts', () => {
  assert.equal(hasDocUpdate(['README.md', 'src/x.ts']), true);
});

test('lowercase readme.md counts', () => {
  assert.equal(hasDocUpdate(['readme.md']), true);
});

test('CLAUDE.md counts', () => {
  assert.equal(hasDocUpdate(['CLAUDE.md']), true);
});

test('nested README counts', () => {
  assert.equal(hasDocUpdate(['packages/schemas/README.md']), true);
});

test('no docs touched', () => {
  assert.equal(hasDocUpdate(['src/a.ts', 'src/b.ts']), false);
});

test('lowercase claude.md does NOT count (must be exact)', () => {
  assert.equal(hasDocUpdate(['claude.md']), false);
});
