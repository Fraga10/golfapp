Deploy / Auto-update instructions
===============================

Recommended flow (minimal maintenance):

- Use GitHub Actions to build and push a Docker image to GitHub Container Registry (GHCR).
- Run the backend as a Docker container on your host and install Watchtower there. Watchtower will automatically pull new images and restart containers.

Required GitHub secret(s):

- `GHCR_TOKEN` — a Personal Access Token (recommended) with `read:packages` and `write:packages` (alternatively configure repo/package permissions to allow `GITHUB_TOKEN`).

Watchtower installation (Linux host example):

1. Login to GHCR on the host (if registry is private):

```bash
echo $GHCR_TOKEN | docker login ghcr.io -u YOUR_GH_USERNAME --password-stdin
```

2. Start your backend container (example):

```bash
docker run -d \
  --name golfe-backend \
  --label=com.centurylinklabs.watchtower.enable=true \
  -p 8080:8080 \
  ghcr.io/Fraga10/golfe:latest
```

3. Start Watchtower (checks every 5 minutes and cleans up old images):

```bash
docker run -d \
  --name watchtower \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower \
  --cleanup \
  --label-enable \
  --interval 300
```

Notes:
- If you prefer Docker Hub, adjust the GitHub Action and `docker login` step accordingly.
- If your host is Windows, you can run the same containers using Docker Desktop or Docker Engine on Windows; use PowerShell to set the `docker login` credentials.
- If you cannot run Docker on the host, see the `git pull` cron alternative described below.

Alternative: git pull + systemd (non-container)

If you run the backend directly (Dart process), you can set a cron job (or systemd timer) to `git pull` and restart the service. Example cron every 5 minutes:

```bash
*/5 * * * * cd /opt/golfe && git fetch origin && git reset --hard origin/main && dart pub get && systemctl restart golfe
```

Security
- Keep `GHCR_TOKEN` secret in GitHub Secrets.
- Restrict who can push to the `main` branch or require PRs to protect production.
- Use labels with Watchtower to control which containers are updated automatically.
