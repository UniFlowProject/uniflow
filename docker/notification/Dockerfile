# Same build as uniflow-notification-service/Dockerfile. It lives here because that repo has no .dockerignore:
# its build context would copy node_modules and the developer's real .env (MongoDB/AWS credentials) into the
# image. The sibling Dockerfile.dockerignore (honoured by BuildKit) keeps them out. DEV ONLY.
# It also copies pnpm-workspace.yaml and .npmrc before `pnpm install`: with the original Dockerfile a current
# pnpm fails with "Ignored build scripts" because the allowBuilds list is not in the image yet.
FROM node:22.20-alpine AS builder
WORKDIR /app
RUN npm install -g pnpm
COPY pnpm-lock.yaml package.json pnpm-workspace.yaml .npmrc ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm run build

FROM node:22.20-alpine
WORKDIR /app
RUN npm install -g pnpm
COPY pnpm-lock.yaml package.json pnpm-workspace.yaml .npmrc ./
RUN pnpm install --frozen-lockfile --prod
COPY --from=builder /app/dist ./dist
EXPOSE 3003
ENV PORT=3003
CMD ["node", "dist/main.js"]
