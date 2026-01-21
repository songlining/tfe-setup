FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install basic tools
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    make \
    git \
    unzip \
    gnupg \
    lsb-release \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# Install HashiCorp Terraform CLI (latest)
RUN wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update && apt-get install -y terraform \
    && rm -rf /var/lib/apt/lists/*

# Install kind (Kubernetes in Docker)
RUN ARCH=$(dpkg --print-architecture) \
    && curl -Lo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/v0.25.0/kind-linux-${ARCH}" \
    && chmod +x /usr/local/bin/kind

# Create workspace directory
WORKDIR /workspaces/tfe-setup

# Set up bash completion for terraform
RUN terraform -install-autocomplete 2>/dev/null || true
