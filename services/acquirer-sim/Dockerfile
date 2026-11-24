FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY . .
EXPOSE 8083
# Datadog tracing is preloaded with -r (dd-init.js).
CMD ["node", "-r", "./dd-init.js", "server.js"]
