# JuiceFS flush race community submission checklist

## A. Review set

Review these files in order:

1. `candidate/community-candidate.patch`
2. `tests/writer_flush_test.go`
3. `drafts/commit-message.md`
4. either `drafts/pr.md`, or `drafts/issue.md` followed by the PR draft
5. `reports/U01-execution-20260818-130955.md`, especially the Codex review

Expected candidate scope:

- production: only `pkg/vfs/writer.go`, 7 inserted lines;
- test: new `pkg/vfs/writer_flush_test.go`, 243 lines;
- no go.mod/go.sum, block-size, retry, timer, buffer, or unrelated production change;
- `writer_flush_c02_test.go` is internal evidence and is not part of the default PR.

## B. Submission-time dynamic gates

- [ ] Fetch official `juicedata/juicefs` main and record its exact HEAD.
- [ ] If HEAD differs from `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a`, rerun the minimal
      stock/apply/community-test replay and regenerate the canonical diff.
- [ ] Search current open/closed issues, PRs and commits for an equivalent fix.
- [ ] Confirm the three test names and helper names do not conflict with current main.
- [ ] Recheck `CONTRIBUTING.md`, license header, formatting and commit-signing requirements.
- [ ] Secret-scan only the files that will be posted.
- [ ] Obtain explicit authorization before creating a fork, branch, commit, issue, PR or comment.

## C. Allowed local-test wording

On frozen official main commit `53835e24...`:

- stock deterministically missed the catch-up dispatch in U1/U3 while U2 passed;
- the candidate applied without a context port and corrected the target behavior;
- targeted count/race commands, internal C02 semantics, full `pkg/vfs`, gofmt,
  `git diff --check`, `go vet`, Linux build and a fresh replay completed successfully;
- GitHub Actions was not run locally;
- v1.3 real Ceph S/A/B performance is a separate validation line.

Do not claim that the U01 tar is a complete independent audit package. Its included files are
checksum-valid, but the Codex review documents missing/stale control and packaging records.

## D. What to post

For a direct PR, normally post only the git commit (writer change plus regression test) and the
updated PR body. Do not attach `evidence/`, full archives, C02 internal tests, v1.3 references or
historical project documents unless a maintainer asks for a specific item.

For an issue-first flow, post the issue draft and the minimal reproduction description. Avoid
internal hostnames, absolute paths, Ceph details and production performance claims.

## E. After opening the PR

- [ ] Record the public issue/PR URL and submitted commit SHA in a new local submission record.
- [ ] Watch official CI; do not rewrite a failing result as passed.
- [ ] Answer maintainer questions with the smallest relevant raw evidence.
- [ ] Any code/test change requested by maintainers gets a new local replay and reviewed diff.
