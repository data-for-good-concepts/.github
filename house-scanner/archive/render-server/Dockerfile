# House Renderer: Node + headless Chromium (from the Playwright image, which includes the browser and fonts).
FROM mcr.microsoft.com/playwright:v1.63.0-noble

WORKDIR /app
ENV NODE_ENV=production PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY server.js ./
COPY lib ./lib
COPY public ./public

ENV PORT=8080
EXPOSE 8080
CMD ["node", "server.js"]
