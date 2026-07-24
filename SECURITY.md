# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security vulnerability. Contact the maintainer through the private security contact available on the GitHub repository.

Include the affected version, macOS version, Docker version, reproduction steps, and the smallest possible proof of impact. Do not include credentials, private Docker logs, container environment variables, or volume contents.

DockerSweep is designed to avoid shell interpolation, administrator privileges, telemetry, and direct access to Docker Desktop's internal storage.
