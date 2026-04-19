###############################################################################
# Stage 1 – Export Godot project to Web/WASM
# Force amd64 since Godot headless export only needs to run once at build time
###############################################################################
FROM --platform=linux/amd64 ubuntu:22.04 AS builder

ARG GODOT_VERSION=4.3
ARG GODOT_RELEASE=stable

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download Godot editor (headless) and export templates
RUN wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-${GODOT_RELEASE}/Godot_v${GODOT_VERSION}-${GODOT_RELEASE}_linux.x86_64.zip" -O /tmp/godot.zip \
    && unzip /tmp/godot.zip -d /tmp \
    && mv "/tmp/Godot_v${GODOT_VERSION}-${GODOT_RELEASE}_linux.x86_64" /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm /tmp/godot.zip

RUN wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-${GODOT_RELEASE}/Godot_v${GODOT_VERSION}-${GODOT_RELEASE}_export_templates.tpz" -O /tmp/templates.tpz \
    && mkdir -p "/root/.local/share/godot/export_templates/${GODOT_VERSION}.${GODOT_RELEASE}" \
    && unzip /tmp/templates.tpz -d /tmp \
    && mv /tmp/templates/* "/root/.local/share/godot/export_templates/${GODOT_VERSION}.${GODOT_RELEASE}/" \
    && rm -rf /tmp/templates.tpz /tmp/templates

# Copy game source
WORKDIR /game
COPY . .

# First pass: let Godot import all resources (generates .godot/imported/)
RUN godot --headless --import 2>&1 || true

# Export to Web
RUN mkdir -p /build \
    && godot --headless --export-release "Web" /build/index.html

###############################################################################
# Stage 2 – Serve with nginx (runs native on any arch)
###############################################################################
FROM nginx:1.29.8-alpine

# Remove default nginx config
RUN rm /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY wasm-dev-login.json /usr/share/nginx/html/wasm-dev-login.json
COPY --from=builder /build /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
