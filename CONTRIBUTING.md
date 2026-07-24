# Contributing to DockerSweep

Thanks for helping improve DockerSweep. The project is intentionally local-first and safety-focused.

## Before changing code

1. Open an issue for a larger feature or behavior change.
2. Keep the user interface and repository documentation in English.
3. Never add real Docker logs, container metadata, credentials, volume contents, or private project data to fixtures.
4. Keep Docker operations behind `DockerClient` and keep process execution argument-based rather than shell-based.

## Validation

Run the following on an Apple-Silicon Mac with Xcode installed:

```sh
swift build
swift test
```

If packaging changes, also run:

```sh
./scripts/package-release.sh 0.1.0
```

Integration testing with Docker should use disposable test resources and must verify that running containers and referenced volumes remain untouched.

## Pull requests

Use a focused branch and a Conventional Commit message. Describe the user impact, safety implications, tests, and any macOS or Docker version limitations.
