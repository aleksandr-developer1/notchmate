# Project instructions

## Change log

- Update `CHANGELOG.md` for every user-visible feature, behavior change, fix, or removal in the same task as the code change.
- Keep pending changes under `Unreleased`, grouped into `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`; omit empty groups.
- Describe the effect on users concisely. Consolidate related changes instead of copying commit history. Do not claim measured performance gains without measurements.
- Preserve existing entries and release history. Do not invent past releases or assign a date or version to unreleased work.

## Releases

- Create a release only when the user explicitly asks to make a release on GitHub. Requests to implement, fix, test, build, commit, or push changes do not authorize a release.
- Until that request, keep changes in `Unreleased`. Do not bump the app version or build number, create or push release tags, create draft or published GitHub releases, or upload release assets.
- Local builds using the `release` compiler configuration are allowed for validation; they are not published product releases and must not be presented as such.
- When a GitHub release is explicitly requested, use the accumulated `Unreleased` entries for release notes. Move those entries to a versioned section dated with the actual GitHub publication date only after publication succeeds, and leave a new `Unreleased` section for future work.
