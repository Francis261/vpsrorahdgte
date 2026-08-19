FROM node:22-bookworm

# base tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server sudo curl jq ca-certificates docker.io \
    && rm -rf /var/lib/apt/lists/*

# cloudflared (named tunnel connector)
RUN curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /usr/local/bin/cloudflared \
    && chmod +x /usr/local/bin/cloudflared

# pm2
RUN npm install -g pm2

# opencode CLI (official installer)
RUN curl -fsSL https://opencode.ai/install | bash \
    && ln -sf /root/.opencode/bin/opencode /usr/local/bin/opencode

# sshd: allow root login with password (password set at boot in entrypoint)
RUN mkdir -p /run/sshd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

WORKDIR /app
COPY services/ /app/services/
COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
RUN chmod +x /app/scripts/entrypoint.sh \
    && mkdir -p /root/.config/opencode /root/.ssh \
    && { [ -f /app/services/seed/bashrc ] && cp /app/services/seed/bashrc /root/.bashrc || true; } \
    && { [ -f /app/services/seed/opencode.json ] && cp /app/services/seed/opencode.json /root/.config/opencode/opencode.json || true; } \
    && { [ -f /app/services/seed/authorized_keys ] \
         && cp /app/services/seed/authorized_keys /root/.ssh/authorized_keys \
         && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys || true; }

CMD ["/app/scripts/entrypoint.sh"]