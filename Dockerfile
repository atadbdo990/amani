here# AMANI-MORA — Xray (VLESS/VMESS/TROJAN) container image
FROM golang:1.20-bullseye AS builder
WORKDIR /src

# Copy only the template and the generator source to build a static binary
COPY config.json.tpl /src/config.json.tpl
COPY main.go /src/main.go
COPY go.mod /src/go.mod
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags='-s -w' -o /configgen .

FROM ghcr.io/xtls/xray-core:latest
LABEL project="AMANI-MORA"

# Copy the generated static binary and the template into the final image
COPY --from=builder /configgen /configgen
COPY config.json.tpl /config.json.tpl

# Ensure xray config dir exists and expose the Cloud Run port
EXPOSE 8080

# Run the config generator which will write /etc/xray/config.json and exec xray
ENTRYPOINT ["/configgen"]
