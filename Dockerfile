FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:544.0.0-stable

ENV TERRAFORM_VERSION=1.13.4
ENV KUBECTL_VERSION=1.34.1
ENV KUSTOMIZE_VERSION=5.7.1
RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https=2.6.1 \
    gpg=2.2.40-1.1+deb12u1 \
    gnupg-utils=2.2.40-1.1+deb12u1 \
    ca-certificates=20230311+deb12u1 \
    curl=7.88.1-10+deb12u14 \
    lsb-release=12.0-1 \
    jq=1.6-2.1+deb12u1 \
    yq=3.1.0-3 \
    gh=2.23.0+dfsg1-1  \
    curl=7.88.1-10+deb12u14 \
    gettext-base=0.21-12 \
    python3.11-venv=3.11.2-6+deb12u6 \
    git=1:2.39.5-0+deb12u2 \
    bc=1.07.1-3+b1 \
    unzip=6.0-28 && \
    ##
    # add Gcloud GPG key
    # Install Gcloud SDK
    ##
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/google-cloud-sdk.gpg && \
    export CLOUD_SDK_REPO="cloud-sdk-$(lsb_release -c -s)" && \
    export CLOUD_SDK_VERSION=$(gcloud version | grep "Google Cloud SDK" | grep -oE '[^ ]+$') && \
    echo "deb [signed-by=/etc/apt/keyrings/google-cloud-sdk.gpg] https://packages.cloud.google.com/apt $CLOUD_SDK_REPO main" > /etc/apt/sources.list.d/google-cloud-sdk.list && \
    apt-get update && apt install -y --no-install-recommends \
        google-cloud-cli-gke-gcloud-auth-plugin=545.0.0-0 && \
    ##
    ## Install terraform
    ##
    curl -LO https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
        && unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
        && install -o root -g root -m 0755 terraform /usr/local/bin/terraform \
        && rm -rvf terraform_${TERRAFORM_VERSION}_linux_amd64.zip LICENSE.txt terraform && \
    ##
    #
    # Install Kubectl
    #
    ##
    curl -LO "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
        && rm -vf kubectl && \
    ##
    #
    # Install Kustomize
    #
    ##
    curl -LO "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
        && tar -zxvf kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz \
        && install -o root -g root -m 0755 kustomize /usr/local/bin/kustomize \
        && rm -vf kustomize \
    && rm -rf /var/lib/apt/lists/*
