FROM node:24-alpine
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY tsconfig.json ./
COPY src ./src
ENV HOST=127.0.0.1
ENV PORT=8318
EXPOSE 8318
CMD ["node", "--experimental-strip-types", "src/index.ts"]
