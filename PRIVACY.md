# Privacy

DockerSweep is a local-only macOS application.

It invokes the Docker CLI in the user's environment to read aggregate Docker disk usage and run explicit prune commands selected by the user. It does not upload data, use analytics, access credentials, inspect container environment variables, read volume contents, or analyze project files.

Local settings and cleanup history are stored under `~/Library/Application Support/DockerSweep/`. Technical logs are stored under `~/Library/Logs/DockerSweep/` and are sanitized and rotated locally.

DockerSweep is not affiliated with Docker, Inc. Docker and Docker Desktop are trademarks of Docker, Inc.
