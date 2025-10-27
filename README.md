# GPUup Maintenance Notes

This repo now ships a single-page site (`index.html`), the installer (`gpuup.sh`), and the deployment script (`deploy.sh`). Use this file as your checklist when updating or publishing.

```bash
curl -fsSL https://get.gpuup.sh | bash
```
## Deploying Updates

1. Update `.env` with the correct region, bucket, and distribution identifiers.
2. Load the configuration and deploy:

   ```bash
   ./deploy.sh
   ```

- `index.html` is the source of truth for public copy. Edit it directly.
- `assets/` holds static media (currently `gpu-fan-background-v1.png`).
- `deploy.sh` uploads `index.html`, `gpuup.sh`, and the debug harness to S3 and invalidates both CloudFront distributions so changes appear instantly.
- Running `gpuup.sh` with no flags now performs a fully automated install. Pass `--interactive` if you want to step through each decision manually.
- Override any of the environment variables in `.env` if you ever change the bucket or distribution IDs.
- When piping the installer (`curl … | bash`) from a non-interactive session, use `curl … | env GPUUP_FORCE_STDIN=1 bash` (note the `env` before `bash`) or prefer `bash <(curl …)` so the guided prompts remain available. Set `GPUUP_PROMPT_TIMEOUT=<seconds>` if you want prompts to auto-fail after a delay.
- Hardware detection now defaults to installing CUDA 13.0 with the R580 driver branch for compute capability 7.5 and newer GPUs; Maxwell, Pascal, and Volta boards automatically fall back to CUDA 12.9 on R575 so older fleets stay functional.
- After an upgrade, remove any legacy `export PATH=/usr/local/cuda-*/bin:$PATH` or `LD_LIBRARY_PATH=/usr/local/cuda-*/lib64` lines from your shell rc, then `source ~/.bashrc` (or `source ~/.zshrc`) to pick up the new CUDA 13.0 toolchain before rebooting.
- If GPUup reports a “driver/library version mismatch”, finish the reboot before running the installer again; afterwards run `gpuup --verify-only` to confirm the driver and toolkit loaded.

By default the installer keeps or installs the proprietary NVIDIA driver branch that satisfies the CUDA minimum. If the repository cannot provide the requested version, GPUup keeps the existing driver when it is compatible. Use `--interactive` if you need to override this behavior.

## Debugging Remote Installs

- For noisy diagnostics on ephemeral hosts, run `curl -fsSL https://get.gpuup.sh/debug.sh | bash`. The helper fetches the latest installer, forces interactive mode, enables debug logging, and tees all output to `gpuup-debug.log` in the current working directory.
- You can override defaults via environment variables, e.g. `GPUUP_DEBUG=0`, `GPUUP_PROMPT_TIMEOUT=30`, or `GPUUP_FORCE_STDIN=0` before invoking the debug harness.
- GPUup automatically appends the CUDA exports to your shell rc (~/.bashrc by default), reloads them for the current session, and ensures `nvcc` works immediately after installation.

## Installer Script

- Keep `gpuup.sh` curl-friendly and idempotent; the public command is `curl -fsSL https://get.gpuup.sh | bash`.
- When you change CLI flags or behavior, mirror the updates in `index.html`.

## Config Directory

`config/` stores policy and tooling settings for the agent harness. Leave these files in place unless you intend to change the automation rules.
