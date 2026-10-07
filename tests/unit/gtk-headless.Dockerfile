FROM debian:trixie-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 xvfb xauth fonts-hack fonts-dejavu-core adwaita-icon-theme && rm -rf /var/lib/apt/lists/*
