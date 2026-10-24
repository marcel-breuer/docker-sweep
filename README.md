# DockerSweep

DockerSweep is a native, local-first macOS menu bar app for monitoring Docker and Mac storage, and safely cleaning resources that Docker reports as unused.

It uses Swift, SwiftUI, Swift Concurrency, and the official Docker CLI. DockerSweep reads filesystem allocation metadata for Docker Desktop's disk image when it is at the documented default path; it never reads the image or volume contents, modifies the disk image, stops running containers, runs `docker compose down`, or sends telemetry anywhere.

## Features

- Menu bar dashboard for Docker availability, storage use, reclaimable space, scan times, and cleanup results.
- Host free-space monitoring, configurable low-storage notifications, and a separate opt-in low-space cleanup policy.
- Separate reporting for Docker engine usage, Docker Desktop disk-image allocation, and disk-image capacity when available.
- Automatic Docker CLI discovery at common Homebrew, Docker Desktop, and `PATH` locations.
- `docker system df --format json` parsing with a table-output fallback.
- Separate, sequential prune commands for stopped containers, networks, images, build cache, and volumes.
- Safe defaults: automatic cleanup is off and volumes are excluded.
- Configurable scan interval, storage threshold, cooldown, resource age, image mode, and resource categories.
- Manual cleanup preview with individual unused-resource candidates, stale-state revalidation, and a clear warning for volume operations.
- Local cleanup history, sanitized technical logs, atomic JSON persistence, and five-file log rotation.
- Optional login-item registration through `SMAppService`.
- Testable Docker and process abstractions with no shell command interpolation.

## Requirements

- macOS 13 Ventura or newer
- Apple Silicon or Intel Mac (universal app)
- Docker Desktop or a compatible local Docker Engine

DockerSweep does not require administrator privileges. The app talks to Docker only through the Docker CLI in the user's environment.

## Install with Homebrew

Install from the public tap:

```sh
brew install --cask marcel-breuer/tap/dockersweep
```

Or tap once and install by cask name:

```sh
brew tap marcel-breuer/tap
brew install --cask dockersweep
```

The cask is also kept in [`Casks/dockersweep.rb`](Casks/dockersweep.rb) for review and tap maintenance.

## Signed releases

Releases produced by the notarized release workflow are signed with Developer ID and notarized by Apple. Older releases published before that workflow may still be unsigned; prefer a release produced by the new workflow. Verify the published SHA-256 checksum before installation. Locally built development copies are not notarized and may trigger a Gatekeeper warning.

The release workflow requires the repository secrets `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`. It fails closed if signing or notarization is unavailable.

## Usage and safety

DockerSweep's automatic cleanup is disabled during onboarding. Docker-storage cleanup runs only after the configured threshold is exceeded and the cooldown has elapsed. Low-host-space notifications and low-host-space cleanup are configured separately; cleanup remains off by default.

The default cleanup policy is:

- Build cache: enabled, seven-day minimum age
- Dangling images: enabled
- Stopped containers: enabled, seven-day minimum age
- Networks: enabled, seven-day minimum age
- Anonymous and named volumes: disabled
- Automatic cleanup: disabled
- Low-storage alerts: disabled until enabled
- Low-storage cleanup: disabled until separately enabled
- Login item: disabled until enabled in Settings
- Automatic scans: enabled

Volumes can contain databases, uploads, and other persistent project data. DockerSweep asks for explicit confirmation before volume cleanup and excludes resources carrying `docker-sweep.keep=true` or `keep` labels. No cleanup can be undone through DockerSweep.

## Privacy

All Docker metadata, settings, history, and logs remain on the Mac. DockerSweep does not upload Docker metadata, read container environment variables, inspect project contents, access credentials, or use analytics SDKs. See [PRIVACY.md](PRIVACY.md).

## Development

This is a native macOS project, so the Apple Swift/Xcode toolchain is required. Docker containers cannot provide the macOS SDK needed for the app target.

```sh
swift build
swift test
./scripts/package-release.sh 0.1.2
```

The release script creates:

- `dist/DockerSweep.app`
- `dist/DockerSweep-<version>-universal.zip` (arm64 and x86_64)
- `dist/DockerSweep-<version>-universal.zip.sha256`

Local packaging creates an ad-hoc signed app. Set `REQUIRE_NOTARIZATION=true` and provide the release workflow's signing and Apple credentials to create a signed and notarized release.

## Contributing

DockerSweep is open source under the MIT License. Contributions, bug reports, tests, documentation improvements, and safer Docker integrations are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

MIT. See [LICENSE](LICENSE).
