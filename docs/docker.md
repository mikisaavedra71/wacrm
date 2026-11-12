# Running with Docker

The repo ships a multi-stage `Dockerfile` (Next.js standalone output,
runs as a non-root user) and a `docker-compose.yml` with a single
`app` service. Supabase is external — point the app at your hosted
(or self-hosted) Supabase project via env vars; no database container
is included.

## Quick start

1. Copy the env template and fill it in:

   ```bash
   cp .env.local.example .env.local
   ```

2. Build and start (the `--env-file` flag is required — Compose only
   reads `.env` by default for `${VAR}` substitution, and this project
   keeps its config in `.env.local`):

   ```bash
   docker compose --env-file .env.local up --build -d
   ```

3. The app is served on [http://localhost:3000](http://localhost:3000)
   (publish it elsewhere with `HOST_PORT=8080` in `.env.local`).

> Use `HOST_PORT`, not `PORT`, to move the published port. `PORT` is
> what the server listens on _inside_ the container, and `env_file`
> would inject it there — leaving the app on a port the mapping and
> the healthcheck don't target. Compose pins it to 3000 for that
> reason.

## Deploying on Easypanel

1. Create an **App** service and point its **Source** at this repository.
   Keep the build path at `/` — Easypanel auto-detects the `Dockerfile`
   in the repo root.
2. Open **Environment** and paste every variable you need from
   `.env.local.example` (at minimum the five required ones, plus
   `NEXT_PUBLIC_SITE_URL` and `NEXT_PUBLIC_APP_LOCALE`).
3. Set the service's **target port** to `3000` (the port the image
   exposes). Do not override `PORT` unless you also change the target
   port; the built-in health check follows `PORT`.
4. Add your domain under **Domains** and enable HTTPS. Set
   `NEXT_PUBLIC_SITE_URL` to that public URL.
5. Deploy. The first build fails fast if `NEXT_PUBLIC_SUPABASE_URL` or
   `NEXT_PUBLIC_SUPABASE_ANON_KEY` is missing, with a message telling
   you to set it in the Environment tab.

Easypanel forwards project/service environment variables to the Docker
build as build args, so the `NEXT_PUBLIC_*` values are baked into the
client bundle automatically. Keep them in the Environment tab rather
than only in a local `.env.local`. Changing any `NEXT_PUBLIC_*` value
requires a **redeploy/rebuild**, not just a restart — the old value is
compiled into the bundle.

The image includes a `HEALTHCHECK` that probes `/login` every 30s, so
Easypanel can report the container as healthy without an extra endpoint.
If the build is OOM-killed, raise the service's build memory: the
Turbopack production build is the memory-heavy step, not the runtime.

Apply the `supabase/` migrations before the first deploy, and point an
external scheduler at the cron endpoints described below if you use
automations or flows.

## Build-time vs runtime variables

- `NEXT_PUBLIC_*` variables are **inlined into the client bundle at
  build time**. They are passed as Docker build args by
  `docker-compose.yml`. If you change any of them, rebuild:
  `docker compose --env-file .env.local up --build -d`. This includes
  `NEXT_PUBLIC_APP_LOCALE` (`en | ko | pt | es`), so the UI language is
  fixed per image.
- Everything else (`SUPABASE_SERVICE_ROLE_KEY`, `ENCRYPTION_KEY`,
  `META_APP_SECRET`, …) is read at **runtime** from `.env.local` via
  `env_file` and is never baked into the image — safe to change with
  just a container restart.

## Plain Docker (no Compose)

```bash
docker build \
  --build-arg NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co \
  --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key \
  -t wacrm .

docker run -d --env-file .env.local -e PORT=3000 -p 3000:3000 wacrm
```

## Notes

- Database migrations under `supabase/` are **not** run by the
  container — apply them with the Supabase CLI as described in the
  README.
- Received attachments are copied into the `chat-media` Supabase
  Storage bucket, because Meta deletes media roughly 30 days after it
  arrives and the copy is the only thing that outlives that. It grows
  with inbound volume, so it's worth watching your project's storage
  quota. Turn it off per account under Settings → WhatsApp →
  Attachment Storage; attachments received while it's off become
  unviewable once Meta drops them. Files over 16 MB (the bucket's
  limit) are never copied.
- Nothing inside the container is scheduled. If you use automation
  Wait steps or flows, point an external scheduler at
  `GET /api/automations/cron` and `GET /api/flows/cron` on this
  deployment, sending the shared secret in the `x-cron-secret` header
  (`AUTOMATION_CRON_SECRET`, see `.env.local.example`). Both return
  503 until that variable is set.
