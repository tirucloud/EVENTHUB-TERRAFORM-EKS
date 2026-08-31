# syntax=docker/dockerfile:1

# ---- build stage -------------------------------------------------------------
# The build context is the repository root, because all five services share one
# Go module. Only the packages this service needs are copied in, so a change to
# another service does not invalidate this image's layer cache.
# Pinned to the patch version, not the 1.26 floating tag.
#
# The Go standard library is compiled into the binary, so its CVEs are the
# image's CVEs. Trivy reports them against "stdlib", and a floating minor tag
# silently resolves to whatever patch is current — 1.26.4 at the time of
# writing, which still carries CVE-2026-39822. Bump this deliberately.
ARG GO_VERSION=1.26.5
FROM golang:${GO_VERSION}-alpine AS build

WORKDIR /src

# Dependencies first: this layer is reused until go.mod or go.sum changes.
COPY go.mod go.sum ./
RUN go mod download

COPY internal ./internal
COPY services/event-service ./services/event-service

# APP_VERSION is stamped by CI with the commit SHA and surfaces on /health.
ARG APP_VERSION=dev
ARG TARGETARCH

RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} \
    go build -trimpath -ldflags="-s -w" -o /out/event-service ./services/event-service

# ---- runtime stage -----------------------------------------------------------
# Distroless static: no shell, no package manager, no libc. The attack surface
# is the single Go binary, which keeps the Trivy report short and honest.
FROM gcr.io/distroless/static-debian12:nonroot

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PORT=8080

COPY --from=build /out/event-service /usr/local/bin/event-service

# 65532 is the "nonroot" user baked into the distroless image.
USER 65532:65532
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/event-service"]
