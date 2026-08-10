FROM node:22.18.0-alpine AS base
ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN corepack enable
WORKDIR /app

FROM base AS dependencies
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

FROM dependencies AS build
COPY tsconfig.base.json nx.json prisma.config.ts ./
COPY apps/api ./apps/api
COPY libs/shared ./libs/shared
RUN pnpm exec nx run api:build

FROM build AS migrate
CMD ["pnpm", "exec", "prisma", "migrate", "deploy", "--config", "prisma.config.ts"]

FROM build AS production-dependencies
RUN pnpm prune --prod

FROM node:22.18.0-alpine AS runtime
ENV NODE_ENV=production
ENV PAGEPASS_PORT=8787
WORKDIR /app
COPY package.json ./
COPY --from=production-dependencies /app/node_modules ./node_modules
COPY --from=build /app/dist/apps/api ./dist/apps/api
USER node
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8787/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/apps/api/apps/api/src/main.js"]
