# syntax=docker/dockerfile:1.3-labs

ARG GO_VERSION=1.17
ARG GORELEASER_XX_VERSION=1.1.0
ARG XX_VERSION=1.1.0

FROM --platform=$BUILDPLATFORM crazymax/goreleaser-xx:${GORELEASER_XX_VERSION} AS goreleaser-xx
FROM --platform=$BUILDPLATFORM tonistiigi/xx:${XX_VERSION} AS xx

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS base
COPY --from=goreleaser-xx / /
COPY --from=xx / /
RUN apk add --no-cache \
    bash \
    ca-certificates \
    clang \
    curl \
    git \
    file \
    lld \
    pkgconfig \
    tar
WORKDIR /src

FROM base AS vendored
RUN --mount=type=bind,target=.,rw \
  --mount=type=cache,target=/go/pkg/mod \
  go mod tidy && go mod download

FROM base AS lint
RUN apk add --no-cache gcc jq-dev libc-dev musl-dev oniguruma-dev
RUN go install golang.org/x/lint/golint@latest
RUN --mount=type=bind,target=. \
  --mount=type=cache,target=/root/.cache \
  golint ./...

FROM vendored AS build
ARG CGO_ENABLED=1
ARG TARGETPLATFORM
ARG GO_LINKMODE=static
ARG GIT_REF
RUN xx-apk add --no-cache \
    gcc \
    jq-dev \
    libc-dev \
    linux-headers \
    musl-dev \
    oniguruma-dev
RUN --mount=type=bind,target=/src,rw \
  --mount=type=cache,target=/root/.cache/go-build \
  --mount=target=/go/pkg/mod,type=cache <<EOT
[ "$(xx-info arch)" = "ppc64le" ] && XX_CC_PREFER_LINKER=ld xx-clang --setup-target-triple
[ "$(xx-info arch)" = "386" ] && XX_CC_PREFER_LINKER=ld xx-clang --setup-target-triple
LDFLAGS="-v -s -w"
if [ "$CGO_ENABLED" = "1" ] && [ "$GO_LINKMODE" = "static" ] && [ "$(go env GOOS)" = "linux" ]; then
  LDFLAGS="$LDFLAGS -extldflags -static"
fi
if [ "$CGO_ENABLED" = "1" ] && [ "$(go env GOOS)" != "windows" ]; then
  GO_BUILDTAGS="netgo"
fi
xx-go --wrap
set -a
source <(xx-go env)
goreleaser-xx --debug \
  --name "faq" \
  --dist "/out" \
  --main="./cmd/faq" \
  --flags="-tags=$GO_BUILDTAGS" \
  --ldflags="$LDFLAGS -X 'github.com/jzelinskie/faq/pkg/version.Version={{.Version}}'" \
  --envs="CGO_ENABLED=$CGO_ENABLED" \
  --files="LICENSE" \
  --files="README.md"
xx-verify $([ "$GO_LINKMODE" = "static" ] && echo "--static") /usr/local/bin/faq
EOT

FROM scratch AS artifacts
COPY --from=build /out/*.tar.gz /
COPY --from=build /out/*.zip /

FROM scratch
COPY --from=build /usr/local/bin/faq /faq
ENTRYPOINT ["/faq"]
