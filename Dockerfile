FROM ubuntu:22.04

LABEL maintainer="Orion-X Project"
LABEL version="2.0.0-dev"
LABEL description="Orion-X Phoenix Edition - Incident Response & Digital Forensics Toolkit"

# Prevent interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install core packages
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-dev \
    bash-completion vim nano \
    curl wget git sudo \
    net-tools iproute2 iputils-ping \
    tcpdump wireshark tshark \
    binwalk bulk-extractor \
    volatility3 sleuthkit \
    zeek \
    cryptsetup \
    wireguard-tools \
    jq \
    unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip3 install --no-cache-dir \
    volatility3 \
    scapy \
    pytz \
    python-dateutil \
    termcolor \
    requests

# Create directory structure
RUN mkdir -p /opt/orionx/scripts \
    /opt/orionx/data/samples/pcaps \
    /opt/orionx/data/samples/memory \
    /opt/orionx/data/samples/firmware \
    /opt/orionx/data/samples/logs/cowrie \
    /opt/orionx/data/samples/logs/web-attacks \
    /opt/orionx/theme/wallpapers \
    /usr/share/doc/orionx \
    /var/log/orionx \
    /etc/wireguard \
    /etc/element-desktop \
    /home/orionx

# Add orionx user
RUN useradd -m -s /bin/bash -G sudo orionx && \
    echo "orionx:orionx" | chpasswd && \
    echo "orionx ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/orionx

# Set up permissions
RUN chown -R orionx:orionx /opt/orionx /home/orionx /var/log/orionx

# Copy scripts and documentation
COPY scripts/ /opt/orionx/scripts/
COPY docs/ /usr/share/doc/orionx/
COPY data/ /opt/orionx/data/
COPY theme/ /opt/orionx/theme/

# Make scripts executable (including mesh subdirectory) and link to PATH
# NOTE: setup-vpn.sh was renamed to setup-wireguard.sh in v2.0.0
RUN chmod +x /opt/orionx/scripts/*.sh /opt/orionx/scripts/*.py /opt/orionx/scripts/mesh/* && \
    ln -sf /opt/orionx/scripts/setup-wireguard.sh /usr/bin/ && \
    ln -sf /opt/orionx/scripts/mesh/orionx-mesh /usr/local/bin/orionx-mesh && \
    ln -sf /opt/orionx/scripts/setup-matrix.sh /usr/bin/ && \
    ln -sf /opt/orionx/scripts/artifact-analyzer.py /usr/bin/ && \
    ln -sf /opt/orionx/scripts/storyboard-gen.py /usr/bin/ && \
    ln -sf /opt/orionx/scripts/toggle-theme.sh /usr/bin/ && \
    ln -sf /opt/orionx/scripts/run-lynis.sh /usr/bin/ && \
    ln -sf /opt/orionx/scripts/download-samples.sh /usr/bin/

# Create welcome message
RUN echo '#!/bin/bash\necho ""\necho "Welcome to Orion-X Phoenix Edition v2.0.0-dev Docker Environment"\necho "Type \"orionx-help\" for a list of available commands"\necho ""' > /etc/update-motd.d/10-orionx && \
    chmod +x /etc/update-motd.d/10-orionx

# Add bash aliases and help function for user
RUN echo '\n# Orion-X Phoenix Edition\nexport PATH=$PATH:/opt/orionx/scripts\nalias ll="ls -la"\nalias cls="clear"\n\norionx-help() {\n  echo "Orion-X Phoenix Edition v2.0.0-dev Help"\n  echo "-----------------------------------"\n  echo "setup-wireguard.sh : Standalone WireGuard tunnel setup"\n  echo "orionx-mesh        : P2P mesh networking (join, leave, status)"\n  echo "setup-matrix.sh  : Setup secure communication"\n  echo "toggle-theme.sh  : Switch between dark and green themes"\n  echo "run-lynis.sh     : Run security audit"\n  echo "download-samples.sh : Download sample data for analysis"\n  echo ""\n  echo "Forensic Tools:"\n  echo "artifact-analyzer.py : Automate artifact analysis"\n  echo "storyboard-gen.py    : Create incident timeline"\n  echo ""\n  echo "Documentation available in /usr/share/doc/orionx/"\n}\n' >> /home/orionx/.bashrc

# Set working directory
WORKDIR /home/orionx

# Set default command
CMD ["/bin/bash", "-l"]

# Switch to non-root user
USER orionx