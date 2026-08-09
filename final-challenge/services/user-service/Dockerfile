# Stage 1: Install deps
FROM node:20-alpine AS builder
WORKDIR /app
COPY services/user-service/package*.json ./
RUN npm ci --only=production && npm cache clean --force

# Stage 2: Runtime (minimal image)
FROM node:20-alpine
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001
WORKDIR /app
COPY --from=builder --chown=nodejs:nodejs /app/node_modules ./node_modules
COPY --chown=nodejs:nodejs . .
COPY --chown=nodejs:nodejs services/shared ./shared
USER nodejs
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:${PORT:-3000}/health || exit 1
CMD ["node", "index.js"]
