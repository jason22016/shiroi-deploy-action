# Exact immutable image currently running in production; keep Node and musl aligned.
FROM innei/mx-server@sha256:fa34592f79c3fd604e5b8474d4e5293438366ae8195484d9608cf3fe92e3c4a9
WORKDIR /verify/source
COPY . .
ENV MONGOMS_DISABLE_POSTINSTALL=1 REDISMS_DISABLE_POSTINSTALL=1
RUN npm install --global pnpm@10.28.2
# The existing production assets are retained by the final image; do not fetch latest assets.
RUN mkdir -p assets && pnpm install --frozen-lockfile
RUN pnpm typecheck && pnpm -C apps/core exec vitest run --config vitest.update.config.mts
RUN pnpm bundle
