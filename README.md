# OIDC registry smoke test

A manual GitHub Actions workflow that requests a GitHub OIDC ID token, exchanges it using OAuth 2.0 Token Exchange, logs in to an OCI registry, and retrieves an image manifest without downloading image layers.

## Configure and run

1. Push these files to your GitHub repository's default branch.
2. Configure your token service to trust the workflow identity and authorize the requested registry operation.
3. Open **Actions → OIDC registry smoke test → Run workflow** and supply:
   - `org`: registry namespace owning the image.
   - `connection_id`: connection selector configured at your token service.
   - `connection_parameter`: service-specific form field name for that selector.
   - `oidc_audience`: audience requested in the GitHub ID token.
   - `exchange_audience`: target audience requested during token exchange.
   - `sts_url`: HTTPS token service base URL, without `/oauth/token`.
   - `registry`: registry hostname, without a URL scheme.
   - `image`, `tag`: image path within the namespace and tag; defaults are `alpine` and `3.17`.
   - `runner`: runner label; defaults to `ubuntu-latest`.

Keep environment-specific values outside the repository and enter them when dispatching the workflow. The runner must have Bash, curl, jq, and Docker CLI, and network access to all configured services.

The token service must accept a form-encoded POST to `/oauth/token` with the standard `grant_type`, `subject_token`, `subject_token_type`, and `audience` fields, plus your configured connection selector field. It must return an `access_token` string. The registry must accept the literal username `$oauthtoken` and that access token as its login password. Adapt these integration points if your service uses a different contract.

The workflow runs `docker manifest inspect <registry>/<org>/<image>:<tag>`, prints the JSON, and writes `manifest.json` in the job workspace. Docker handles the registry authentication challenge. Pushes do not automatically run the workflow.

No static registry credentials are included. Tokens are masked in Actions logs, and temporary token files and Docker credentials are removed on script exit.
