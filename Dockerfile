# syntax=docker/dockerfile:1

# ===============================================================
# Base — shared toolchain for the dependency + build stages
# ===============================================================
FROM node:22-alpine AS base
# Some Next.js native dependencies expect glibc compatibility
# shims on musl-based Alpine.
RUN apk add --no-cache libc6-compat
WORKDIR /app

# ===============================================================
# Stage 1 — install dependencies
# Cached until package.json / package-lock.json change.
# ===============================================================
FROM base AS deps
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# ===============================================================
# Stage 2 — build
#
# NEXT_PUBLIC_* values are inlined into the client bundle at build
# time, so they must be present while `next build` runs. Easypanel
# forwards the App service's environment variables to the Docker
# build as build args, so declaring them here is enough: set them
# in Easypanel → Environment before deploying.
#
# Server-only secrets (SUPABASE_SERVICE_ROLE_KEY, ENCRYPTION_KEY,
# META_APP_SECRET, ...) are read at runtime and are deliberately
# NOT declared here — they never end up in the image.
# ===============================================================
FROM base AS builder
COPY --from=deps /app/node_modules ./node_modules
COPY . .

ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL
ARG NEXT_PUBLIC_APP_LOCALE=en

ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_PUBLIC_APP_LOCALE=$NEXT_PUBLIC_APP_LOCALE \
    NEXT_TELEMETRY_DISABLED=1

# Fail with an actionable message instead of silently shipping an
# image whose browser bundle points at "undefined".
RUN if [ -z "$NEXT_PUBLIC_SUPABASE_URL" ] || [ -z "$NEXT_PUBLIC_SUPABASE_ANON_KEY" ]; then \
      echo "ERROR: NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY are required at build time." >&2; \
      echo "Set them in Easypanel -> Environment (they are forwarded as build args) and redeploy." >&2; \
      exit 1; \
    fi

# No persistent .next cache here on purpose: NEXT_PUBLIC_* values are
# baked into the output, and a cache reused across builds could serve
# chunks compiled with the previous values after an env change.
RUN npm run build

# ===============================================================
# Stage 3 — minimal runtime (Next.js standalone output)
# ===============================================================
FROM node:22-alpine AS runner
WORKDIR /app

# PORT/HOSTNAME are read by Next's standalone server. They are
# defaults: Easypanel can override PORT at runtime, and 0.0.0.0
# makes the app reachable through the platform proxy.
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# Run as an unprivileged user.
RUN addgroup -S nextjs && adduser -S nextjs -G nextjs

# Only the traced server bundle, hashed static assets, and public
# files ship in the final image — no node_modules, no source.
COPY --from=builder --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nextjs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nextjs /app/public ./public

USER nextjs
EXPOSE 3000
STOPSIGNAL SIGTERM

# Lets Docker/Easypanel mark the container unhealthy when Next stops
# answering. /login is static and does not require a session.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 3000) + '/login').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "server.js"]
