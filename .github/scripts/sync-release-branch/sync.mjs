// Pure logic for the sync-release-branch workflow. No IO, no dependencies.
// A hotfix lands on release/<YYYYMM-sN>; this decides, per target branch, whether a PR
// carrying it back is needed.

/** Branches a release branch is carried back to, in order. */
export const TARGETS = ['develop', 'feature'];

const RELEASE_REF = /^refs\/heads\/(release\/20\d{4}-s\d+)$/;

/** `refs/heads/release/202611-s1` -> `release/202611-s1`; anything else -> null. */
export function releaseBranchFromRef(ref) {
  const m = typeof ref === 'string' ? RELEASE_REF.exec(ref) : null;
  return m ? m[1] : null;
}

/**
 * What to do for one target.
 *   missing  the target branch does not exist in this repo
 *   in-sync  the target already has every commit of the release branch
 *   keep     an open PR exists; PRs track their head, so it already shows the new commits
 *   open     open a new PR
 * @param {{ targetExists: boolean, aheadBy: number, openPrUrl: string|null }} state
 *   aheadBy: commits on the release branch that the target lacks (compare target...release)
 */
export function syncDecision({ targetExists, aheadBy, openPrUrl }) {
  if (!targetExists) return 'missing';
  if (!Number.isInteger(aheadBy)) throw new Error(`ahead_by must be an integer, got ${aheadBy}`);
  if (aheadBy === 0) return 'in-sync';
  return openPrUrl ? 'keep' : 'open';
}

export const prTitle = (branch, target) => `sync: ${branch} → ${target} (merge commit, do not squash)`;

export function prBody(branch, target) {
  return [
    `Carries the fixes on \`${branch}\` back to \`${target}\`. Opened by the \`sync-release-branch\` workflow after a push to \`${branch}\`; it tracks the branch, so later hotfixes show up here too.`,
    '',
    'Merge with a merge commit, not squash, so the fix keeps its history and the next promotion does not conflict.',
    '',
    'CI does not start on its own for a PR opened by a workflow. Close and reopen this PR (or push to it) to run it before merging.',
    '',
  ].join('\n');
}
