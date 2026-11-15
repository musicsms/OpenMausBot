FROM node:24-alpine
WORKDIR /app
COPY package.json tsconfig.json ./
RUN npm install
COPY src ./src
EXPOSE 8318
CMD ["node", "--experimental-strip-types", "src/index.ts"]
