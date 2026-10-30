# syntax=docker/dockerfile:1

# Multi-stage image for the Go API, built by infra/docker-compose.yml
# (build context: backend/). The runtime is alpine rather than distroless so
# busybox wget can serve the compose healthcheck and ca-certificates can back
# HTTPS JWKS fetches in deployed shapes.

FROM golang:1.23-alpine AS build
WORKDIR /src

# Module downloads cache independently of source changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

FROM alpine:3.20
# ca-certificates: the verifier fetches discovery/JWKS over HTTPS in
# production shapes; wget (busybox) serves the healthcheck.
RUN apk add --no-cache ca-certificates

COPY --from=build /out/api /usr/local/bin/api
EXPOSE 8080
USER nobody:nogroup
ENTRYPOINT ["/usr/local/bin/api"]
