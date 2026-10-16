FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git rsync openssh-client curl ca-certificates bash \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI only. The daemon is the host's, reached through the mounted socket.
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker

RUN npm install -g gitlab-ci-local

COPY drupal-ci.sh /usr/local/bin/drupal-ci
RUN chmod +x /usr/local/bin/drupal-ci

ENTRYPOINT ["drupal-ci"]
