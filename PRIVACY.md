# Privacy

DockerSweep is a local-only macOS application.

It invokes the Docker CLI in the user's environment to read Docker storage metadata and list unused cleanup candidates. Candidate removal is explicit; cleanup never reads volume contents. On Docker Desktop, it reads filesystem allocation metadata for the documented disk image path when present, without opening or modifying the image. It reads available host disk space to support optional local alerts. macOS notifications are generated locally and contain only the available-space value. DockerSweep does not upload data, use analytics, access credentials, inspect container environment variables, or analyze project files.

Local settings and cleanup history are stored under `~/Library/Application Support/DockerSweep/`. Technical logs are stored under `~/Library/Logs/DockerSweep/` and are sanitized and rotated locally.

DockerSweep is not affiliated with Docker, Inc. Docker and Docker Desktop are trademarks of Docker, Inc.
