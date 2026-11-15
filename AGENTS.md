# Agent instructions

## User interface work

- Use the project-scoped `$unslop` skill in `.agents/skills/unslop/` for new UI views, UI redesigns, and focused UI reviews.
- Before changing a screen, inspect the rendered UI when practical and audit it using the skill. Keep the existing DockerSweep branding, SwiftUI conventions, design tokens, and reusable components. Do not do a broad redesign without evidence from the audit.
- If the audit finds no concrete problems, report that and suggest at most a few specific refinements; do not change the screen just to make it different.
- Preserve existing behavior and content. For UI changes, check window resizing and layout at supported sizes, accessibility, contrast, visual consistency, and relevant automated tests. Include before-and-after evidence in the PR when the rendered UI changes.

The skill is maintained in `.agents/skills/unslop/`; see its `UPSTREAM.md` for installation, source, revision, and license details.

## CI/CD pipeline

Stand: 2026-11-15

Kept workflows:

- `ci.yml` (CI): runs `swift build` and `swift test` on macOS 15 for pull requests.
- `release.yml` (Release): packaging, GitHub release with zip and SHA-256, tag creation and optional Homebrew tap cask update.

Removed workflows:

- `dependabot-auto-merge.yml`: removed to cut pipeline runs. Dependabot PRs are now reviewed and merged manually. `.github/dependabot.yml` (configuration) stays.

Rule: run all pipeline steps locally before every PR. For this repo that means `swift build` and `swift test` (the same commands as `ci.yml`); for changes to `release.yml`, also validate the YAML syntax without triggering a real release.
