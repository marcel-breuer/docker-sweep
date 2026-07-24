# DockerSweep

DockerSweep is a native, local-first macOS menu bar app for monitoring Docker storage and safely cleaning resources that Docker reports as unused.

It uses Swift, SwiftUI, Swift Concurrency, and the official Docker CLI. DockerSweep does not inspect Docker Desktop's internal virtual disk, read volume contents, stop running containers, run `docker compose down`, or send telemetry anywhere.

## Features

- Menu bar dashboard for Docker availability, storage use, reclaimable space, scan times, and cleanup results.
- Automatic Docker CLI discovery at common Homebrew, Docker Desktop, and `PATH` locations.
- `docker system df --format json` parsing with a table-output fallback.
- Separate, sequential prune commands for stopped containers, networks, images, build cache, and volumes.
- Safe defaults: automatic cleanup is off and volumes are excluded.
- Configurable scan interval, storage threshold, cooldown, resource age, image mode, and resource categories.
- Manual cleanup preview with a clear warning for volume operations.
- Local cleanup history, sanitized technical logs, atomic JSON persistence, and five-file log rotation.
- Optional login-item registration through `SMAppService`.
- Testable Docker and process abstractions with no shell command interpolation.

## Requirements

- macOS 13 Ventura or newer
- Apple Silicon for the first release
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

## Unsigned release notice

DockerSweep is currently distributed without an Apple Developer ID signature or notarization. macOS may show a warning that the developer cannot be verified or that the app may contain malware. This is a Gatekeeper warning caused by the unsigned, unnotarized distribution and is documented here for transparency.

After attempting to open the app once, approve DockerSweep under **System Settings > Privacy & Security**. If needed, remove quarantine for this app only:

```sh
xattr -dr com.apple.quarantine /Applications/DockerSweep.app
```

Do not disable Gatekeeper globally. Download releases only from this repository and verify the published SHA-256 checksum.

## Usage and safety

DockerSweep's automatic cleanup is disabled during onboarding. When enabled, it runs only after the configured total Docker storage threshold is exceeded and the cleanup cooldown has elapsed.

The default cleanup policy is:

- Build cache: enabled, seven-day minimum age
- Dangling images: enabled
- Stopped containers: enabled, seven-day minimum age
- Networks: enabled, seven-day minimum age
- Anonymous and named volumes: disabled
- Automatic cleanup: disabled
- Login item and automatic scans: enabled

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
- `dist/DockerSweep-<version>-arm64.zip`
- `dist/DockerSweep-<version>-arm64.zip.sha256`

Set `DEVELOPER_ID_APPLICATION` when a future signed release is built. Without it, the script creates an ad-hoc signed app for local distribution.

## Contributing

DockerSweep is open source under the MIT License. Contributions, bug reports, tests, documentation improvements, and safer Docker integrations are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

MIT. See [LICENSE](LICENSE).
