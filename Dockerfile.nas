# syntax=docker/dockerfile:1
#
# 自包含构建版 Dockerfile —— 在 NAS 上 clone 完直接 build,无需预先准备任何产物。
#
# 上游 Dockerfile 走的是 CI 预编译路线(COPY dist/${TARGETARCH}/artex),
# 而 dist/ 在 .gitignore 里,clone 下来是没有的;加上 Docker Hub 的
# autumn27/artex 镜像已下架,所以这里把前端静态导出和 Go 编译都搬进多阶段构建。
#
# 运行层(第 3 阶段)与上游 Dockerfile 保持一致:python slim + 常用 recon 工具
# + Node 20 + Playwright/Chromium。

# ---------- 阶段 1:前端 Next.js 静态导出 ----------
FROM node:22-bookworm AS webui
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
# husky 的 prepare 钩子在没有 .git 的构建上下文里会报错,装依赖前先摘掉。
RUN npm pkg delete scripts.prepare && npm ci
COPY web/ ./
# Next 构建是整条链里最吃内存的一步。NAS 内存 ≤4GB 时把它调小(如 2048),
# 否则 Node 堆涨到超过物理内存会被内核 OOM-kill。
ARG NODE_MAX_OLD_SPACE=4096
ENV NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE}
# build:static = NEXT_EXPORT=1 next build,next.config 据此切到 output:"export",产物落在 web/out
RUN npm run build:static

# ---------- 阶段 2:Go 编译,前端内嵌进二进制 ----------
FROM golang:1.26-bookworm AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# server/webui_embed.go 的 //go:embed all:webui/dist 要求这个目录在编译时存在
COPY --from=webui /src/web/out/ ./server/webui/dist/
ARG ARTEX_VERSION=0.3.15
RUN CGO_ENABLED=0 go build \
      -tags embedui \
      -trimpath \
      -ldflags "-s -w -buildid= -X main.version=${ARTEX_VERSION}" \
      -o /out/artex ./cmd/artex

# ---------- 阶段 3:运行镜像 ----------
FROM python:3.12-slim-bookworm
# 常用工具 + recon 常备件;Node 从 NodeSource 装 20.x(bookworm 自带的是 18,Playwright 要 >=20)
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates ripgrep curl wget vim git jq unzip \
      dnsutils iputils-ping netcat-openbsd inetutils-telnet whois nmap \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
# 预装 Playwright MCP/CLI 并预置 chromium,运行时不再联网下载
RUN npm install -g @playwright/mcp@latest @playwright/cli@latest playwright@latest \
    && playwright-cli --help \
    && playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /out/artex /app/artex
# 守护脚本:负责崩溃重拉、页面一键更新换装,并把 SIGTERM 转发给 artex 本体
COPY start.sh /app/start.sh
RUN chmod +x /app/artex /app/start.sh
COPY skills/ /app/skills/
# data/(SQLite + jwt.key)持久化点
VOLUME ["/app/data"]
EXPOSE 8787 8788
ENTRYPOINT ["/app/start.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]
