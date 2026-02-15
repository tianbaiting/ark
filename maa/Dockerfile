FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    p7zip-full \
    adb \
    python3 \
    libatomic1 \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/MaaAssistantArknights/maa-cli/main/install.sh | bash

ENV PATH="/root/.local/bin:${PATH}"

COPY entrypoint.sh /usr/local/bin/maa-entrypoint.sh
RUN chmod +x /usr/local/bin/maa-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/maa-entrypoint.sh"]
CMD ["maa", "--help"]
