import test from 'node:test';
import assert from 'node:assert/strict';
import { TARGETS, releaseBranchFromRef, syncDecision, prTitle, prBody } from './sync.mjs';

test('TARGETS carries a release branch back to develop, then feature', () => {
  assert.deepEqual(TARGETS, ['develop', 'feature']);
});

test('releaseBranchFromRef accepts only release/<YYYYMM-sN> branch refs', () => {
  assert.equal(releaseBranchFromRef('refs/heads/release/202611-s1'), 'release/202611-s1');
  assert.equal(releaseBranchFromRef('refs/heads/release/202611-s12'), 'release/202611-s12');
  for (const ref of [
    'release/202611-s1', // not a full ref
    'refs/tags/release/202611-s1',
    'refs/heads/release/202611-s1-rc1',
    'refs/heads/release/202611-s1.1',
    'refs/heads/release/foo',
    'refs/heads/release/202611-s1/x',
    'refs/heads/develop',
    '',
    undefined,
  ]) {
    assert.equal(releaseBranchFromRef(ref), null, String(ref));
  }
});

test('syncDecision: missing target is skipped', () => {
  assert.equal(syncDecision({ targetExists: false, aheadBy: 3, openPrUrl: null }), 'missing');
});
test('syncDecision: nothing to carry back is skipped, even with an open PR', () => {
  assert.equal(syncDecision({ targetExists: true, aheadBy: 0, openPrUrl: null }), 'in-sync');
  assert.equal(syncDecision({ targetExists: true, aheadBy: 0, openPrUrl: 'https://x/pull/1' }), 'in-sync');
});
test('syncDecision: an open PR is left to track the branch head', () => {
  assert.equal(syncDecision({ targetExists: true, aheadBy: 2, openPrUrl: 'https://x/pull/1' }), 'keep');
});
test('syncDecision: commits missing and no PR opens one', () => {
  assert.equal(syncDecision({ targetExists: true, aheadBy: 1, openPrUrl: null }), 'open');
});
test('syncDecision rejects a non-numeric ahead_by', () => {
  assert.throws(() => syncDecision({ targetExists: true, aheadBy: undefined, openPrUrl: null }));
});

test('prTitle', () => {
  assert.equal(prTitle('release/202611-s1', 'develop'), 'sync: release/202611-s1 → develop');
});
test('prBody names the branches and asks for a merge commit', () => {
  const body = prBody('release/202611-s1', 'feature');
  assert.ok(body.includes('`release/202611-s1`'));
  assert.ok(body.includes('`feature`'));
  assert.ok(body.includes('Merge with a merge commit, not squash, so the fix keeps its history and the next promotion does not conflict.'));
  assert.match(body, /close and reopen/i);
});
