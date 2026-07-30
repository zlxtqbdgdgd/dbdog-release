# dbdog-release agent instructions

- For any release, publish, version-bump, artifact-build, or artifact-prune request, read
  `.claude/skills/publish/SKILL.md` completely and follow it.
- Treat `manifest.tsv` and the GitHub `artifacts` release as an atomic publication. Use
  `scripts/publish/publish.sh`; do not hand-edit the manifest/README or manually replace assets.
- Use the local `dbdog-build` SSH alias for builds. `dbdog-build-old` is rollback/reference only
  and must not be used for a new publication.
- Validate and upload artifacts directly from `dbdog-build`; do not relay release binaries through
  the developer workstation. GitHub credentials must be ephemeral and must not persist on the builder.
- Keep formal module publications serial because they update the same manifest and branch.
- Preserve user-owned untracked `.codex/` and `bugs/` directories.
