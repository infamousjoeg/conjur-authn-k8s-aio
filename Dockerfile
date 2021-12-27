# =================== SECRETLESS - BUILDER CONTAINER ===================
FROM golang:1.17-buster as secretless-builder
LABEL builder="secretless-builder"

# On CyberArk dev laptops, golang module dependencies are downloaded with a
# corporate proxy in the middle. For these connections to succeed we need to
# configure the proxy CA certificate in build containers.
#
# To allow this script to also work on non-CyberArk laptops where the CA
# certificate is not available, we copy the (potentially empty) directory
# and update container certificates based on that, rather than rely on the
# CA file itself.
#
# ADD ./secretless-broker/build_ca_certificate /usr/local/share/ca-certificates/
# RUN update-ca-certificates

WORKDIR /secretless

# TODO: Expand this with build args when we support other arches
ENV GOOS=linux \
    GOARCH=amd64 \
    CGO_ENABLED=1

COPY ./secretless-broker/go.mod secretless-broker/go.sum /secretless/
COPY ./secretless-broker/third_party/ /secretless/third_party

RUN go mod download

# secretless source files
COPY ./secretless-broker/cmd /secretless/cmd
COPY ./secretless-broker/internal /secretless/internal
COPY ./secretless-broker/pkg /secretless/pkg
COPY ./secretless-broker/resource-definitions /secretless/resource-definitions

ARG TAG="dev"

# The `Tag` override is there to provide the git commit information in the
# final binary. See `Static long version tags` in the `Building` section
# of `CONTRIBUTING.md` for more information.
RUN go build -ldflags="-X github.com/cyberark/secretless-broker/pkg/secretless.Tag=$TAG" \
             -o dist/$GOOS/$GOARCH/secretless-broker ./cmd/secretless-broker && \
    go build -o dist/$GOOS/$GOARCH/summon2 ./cmd/summon2


# =================== SECRETLESS - MAIN CONTAINER ===================
FROM alpine:3.14 as secretless-broker

RUN apk add -u shadow libc6-compat openssl && \
    # Add Limited user
    groupadd -r secretless \
             -g 777 && \
    useradd -c "secretless runner account" \
            -g secretless \
            -u 777 \
            -m \
            -r \
            secretless && \
    # Ensure plugin dir is owned by secretless user
    mkdir -p /usr/local/lib/secretless && \
    # Make and setup a directory for sockets at /sock
    mkdir /sock && \
    # Make and setup a directory for the Conjur client certificate/access token
    mkdir -p /etc/conjur/ssl && \
    mkdir -p /run/conjur && \
    # Use GID of 0 since that is what OpenShift will want to be able to read things
    chown secretless:0 /usr/local/lib/secretless \
                       /sock \
                       /etc/conjur/ssl \
                       /run/conjur && \
    # We need open group permissions in these directories since OpenShift won't
    # match our UID when we try to write files to them
    chmod 770 /sock \
              /etc/conjur/ssl \
              /run/conjur

USER secretless

ENTRYPOINT [ "/usr/local/bin/secretless-broker" ]

COPY --from=secretless-builder /secretless/dist/linux/amd64/secretless-broker \
                               /secretless/dist/linux/amd64/summon2 /usr/local/bin/

# =================== SECRETLESS - MAIN CONTAINER (REDHAT) ===================
FROM registry.access.redhat.com/ubi8/ubi as secretless-broker-redhat

ARG VERSION

LABEL name="Secretless-broker"
LABEL vendor="CyberArk"
LABEL version="$VERSION"
LABEL release="$VERSION"
LABEL summary="Secure your apps by making them Secretless"
LABEL description="Secretless Broker is a connection broker which relieves client \
applications of the need to directly handle secrets to target services"

    # Add Limited user
RUN groupadd -r secretless \
             -g 777 && \
    useradd -c "secretless runner account" \
            -g secretless \
            -u 777 \
            -m \
            -r \
            secretless && \
    # Ensure plugin dir is owned by secretless user
    mkdir -p /usr/local/lib/secretless && \
    # Make and setup a directory for sockets at /sock
    mkdir /sock && \
    # Make and setup a directory for the Conjur client certificate/access token
    mkdir -p /etc/conjur/ssl && \
    mkdir -p /run/conjur && \
    mkdir -p /licenses && \
    # Use GID of 0 since that is what OpenShift will want to be able to read things
    chown secretless:0 /usr/local/lib/secretless \
                       /sock \
                       /etc/conjur/ssl \
                       /run/conjur && \
    # We need open group permissions in these directories since OpenShift won't
    # match our UID when we try to write files to them
    chmod 770 /sock \
              /etc/conjur/ssl \
              /run/conjur

COPY ./secretless-broker/LICENSE /licenses

USER secretless

ENTRYPOINT [ "/usr/local/bin/secretless-broker" ]

COPY --from=secretless-builder /secretless/dist/linux/amd64/secretless-broker \
                               /secretless/dist/linux/amd64/summon2 /usr/local/bin/

# =================== AUTHN-K8S - BUILDER CONTAINER ===================

FROM goboring/golang:1.16.7b7 as authenticator-client-builder

ENV GOOS=linux \
    GOARCH=amd64 \
    CGO_ENABLED=1

# this value changes in ./bin/build
ARG TAG_SUFFIX="-dev"

WORKDIR /opt/conjur-authn-k8s-client
COPY ./conjur-authn-k8s-client /opt/conjur-authn-k8s-client

EXPOSE 8080

RUN apt-get update && apt-get install -y jq

RUN go mod download

RUN go get -u github.com/jstemmer/go-junit-report

RUN go build -a -installsuffix cgo \
    -ldflags="-X 'github.com/cyberark/conjur-authn-k8s-client/pkg/authenticator.TagSuffix=$TAG_SUFFIX'" \
    -o authenticator ./cmd/authenticator

# Verify the binary is using BoringCrypto.
# Outputting to /dev/null so the output doesn't include all the files
RUN sh -c "go tool nm authenticator | grep '_Cfunc__goboringcrypto_' 1> /dev/null"

# =================== AUTHN-K8S - BUSYBOX LAYER ===================
# this layer is used to get binaries into the main container
FROM busybox

# =================== AUTHN-K8S - MAIN CONTAINER ===================
FROM alpine:3.14 as authenticator-client

# copy a few commands from busybox
COPY --from=busybox /bin/tar /bin/tar
COPY --from=busybox /bin/sleep /bin/sleep
COPY --from=busybox /bin/sh /bin/sh
COPY --from=busybox /bin/ls /bin/ls
COPY --from=busybox /bin/id /bin/id
COPY --from=busybox /bin/whoami /bin/whoami
COPY --from=busybox /bin/mkdir /bin/mkdir
COPY --from=busybox /bin/chmod /bin/chmod
COPY --from=busybox /bin/cat /bin/cat

RUN apk add -u shadow libc6-compat && \
    # Add Limited user
    groupadd -r authenticator \
             -g 777 && \
    useradd -c "authenticator runner account" \
            -g authenticator \
            -u 777 \
            -m \
            -r \
            authenticator && \
    # Ensure authenticator dir is owned by authenticator user and setup a
    # directory for the Conjur client certificate/access token
    mkdir -p /usr/local/lib/authenticator /etc/conjur/ssl /run/conjur && \
    # Use GID of 0 since that is what OpenShift will want to be able to read things
    chown authenticator:0 /usr/local/lib/authenticator \
                       /etc/conjur/ssl \
                       /run/conjur && \
    # We need open group permissions in these directories since OpenShift won't
    # match our UID when we try to write files to them
    chmod 770 /etc/conjur/ssl \
              /run/conjur

# Ensure openssl development libraries are always up to date
RUN apk add --no-cache openssl-dev

USER authenticator

VOLUME /run/conjur

COPY --from=authenticator-client-builder /opt/conjur-authn-k8s-client/authenticator /usr/local/bin/

ENTRYPOINT [ "/usr/local/bin/authenticator" ]

# =================== AUTHN-K8S - MAIN CONTAINER (REDHAT) ===================
FROM registry.access.redhat.com/ubi8/ubi as authenticator-client-redhat

    # Add Limited user
RUN groupadd -r authenticator \
             -g 777 && \
    useradd -c "authenticator runner account" \
            -g authenticator \
            -u 777 \
            -m \
            -r \
            authenticator && \
    # Ensure plugin dir is owned by authenticator user
    mkdir -p /usr/local/lib/authenticator && \
    # Make and setup a directory for the Conjur client certificate/access token
    mkdir -p /etc/conjur/ssl /run/conjur /licenses && \
    # Use GID of 0 since that is what OpenShift will want to be able to read things
    chown authenticator:0 /usr/local/lib/authenticator \
                       /etc/conjur/ssl \
                       /run/conjur && \
    # We need open group permissions in these directories since OpenShift won't
    # match our UID when we try to write files to them
    chmod 770 /etc/conjur/ssl \
              /run/conjur

VOLUME /run/conjur

COPY --from=authenticator-client-builder /opt/conjur-authn-k8s-client/authenticator /usr/local/bin/

ADD ./conjur-authn-k8s-client/LICENSE /licenses

USER authenticator

CMD [ "/usr/local/bin/authenticator" ]

ARG VERSION

LABEL name="conjur-authn-k8s-client"
LABEL vendor="CyberArk"
LABEL version="$VERSION"
LABEL release="$VERSION"
LABEL summary="Conjur OpenShift Authentication Client for use with Conjur"
LABEL description="The authentication client required to expose secrets from a Conjur server to applications running within OpenShift"

# =================== K8S SECRETS PROVIDER - BASE BUILD LAYER ===================
# this layer is used to prepare a common layer for both debug and release builds
FROM golang:1.17 as secrets-provider-builder-base

ENV GOOS=linux \
    GOARCH=amd64 \
    CGO_ENABLED=0

RUN go get -u github.com/jstemmer/go-junit-report && \
    go get github.com/smartystreets/goconvey

WORKDIR /opt/secrets-provider-for-k8s

EXPOSE 8080

COPY ./secrets-provider-for-k8s/go.mod ./secrets-provider-for-k8s/go.sum ./

# Add a layer of prefetched modules so the modules are already cached in case we rebuild
RUN go mod download

# =================== K8S SECRETS PROVIDER - RELEASE BUILD LAYER ===================
# this layer is used to build the release binaries
FROM secrets-provider-builder-base as secrets-provider-builder

COPY ./secrets-provider-for-k8s .

# this value is set in ./bin/build
ARG TAG

RUN go build \
    -a \
    -installsuffix cgo \
    -ldflags="-X github.com/cyberark/secrets-provider-for-k8s/pkg/secrets.Tag=$TAG" \
    -o secrets-provider \
    ./cmd/secrets-provider

# =================== K8S SECRETS PROVIDER - DEBUG BUILD LAYER ===================
# this layer is used to build the debug binaries
FROM secrets-provider-builder-base as secrets-provider-builder-debug

# Build Delve - debugging tool for Go
RUN go get github.com/go-delve/delve/cmd/dlv

# Expose port 40000 for debugging
EXPOSE 40000

COPY ./secrets-provider-for-k8s .

# Build debug flavor without compilation optimizations using "all=-N -l"
RUN go build -a -installsuffix cgo -gcflags="all=-N -l" -o secrets-provider ./cmd/secrets-provider

# =================== K8S SECRETS PROVIDER - BUSYBOX LAYER ===================
# this layer is used to get binaries into the main container
FROM busybox

# =================== K8S SECRETS PROVIDER - BASE MAIN CONTAINER ===================
# this layer is used to prepare a common layer for both debug and release containers
FROM alpine:3.14 as secrets-provider-base

# Ensure openssl development libraries are always up to date
RUN apk add --no-cache openssl-dev

# copy a few commands from busybox
COPY --from=busybox /bin/tar /bin/tar
COPY --from=busybox /bin/sleep /bin/sleep
COPY --from=busybox /bin/sh /bin/sh
COPY --from=busybox /bin/ls /bin/ls
COPY --from=busybox /bin/id /bin/id
COPY --from=busybox /bin/whoami /bin/whoami
COPY --from=busybox /bin/mkdir /bin/mkdir
COPY --from=busybox /bin/chmod /bin/chmod
COPY --from=busybox /bin/cat /bin/cat

RUN apk add -u shadow libc6-compat && \
    # Add limited user
    groupadd -r secrets-provider \
             -g 777 && \
    useradd -c "secrets-provider runner account" \
            -g secrets-provider \
            -u 777 \
            -m \
            -r \
            secrets-provider && \
    # Ensure plugin dir is owned by secrets-provider user
    mkdir -p /usr/local/lib/secrets-provider /etc/conjur/ssl /run/conjur && \
    # Use GID of 0 since that is what OpenShift will want to be able to read things
    chown secrets-provider:0 /usr/local/lib/secrets-provider \
                           /etc/conjur/ssl \
                           /run/conjur && \
    # We need open group permissions in these directories since OpenShift won't
    # match our UID when we try to write files to them
    chmod 770 /etc/conjur/ssl \
              /run/conjur

USER secrets-provider

# =================== K8S SECRETS PROVIDER - RELEASE MAIN CONTAINER ===================
FROM secrets-provider-base as secrets-provider

COPY --from=secrets-provider-builder /opt/secrets-provider-for-k8s/secrets-provider /usr/local/bin/

CMD [ "/usr/local/bin/secrets-provider"]

# =================== K8S SECRETS PROVIDER - DEBUG MAIN CONTAINER ===================
FROM secrets-provider-base as secrets-provider-debug

COPY --from=secrets-provider-builder-debug /go/bin/dlv /usr/local/bin/

COPY --from=secrets-provider-builder-debug /opt/secrets-provider-for-k8s/secrets-provider /usr/local/bin/

# Execute secrets provider wrapped with dlv debugger listening on port 40000 for remote debugger connection.
# Will wait indefinitely until a debugger is connected.
CMD ["/usr/local/bin/dlv",  \
     "--listen=:40000",     \
     "--headless=true",     \
     "--api-version=2",     \
     "--accept-multiclient",\
     "exec",                \
     "/usr/local/bin/secrets-provider"]

# =================== K8S SECRETS PROVIDER - MAIN CONTAINER (REDHAT) ===================
FROM registry.access.redhat.com/ubi8/ubi as secrets-provider-for-k8s-redhat

ARG VERSION

LABEL name="secrets-provider-for-k8s"
LABEL vendor="CyberArk"
LABEL version="$VERSION"
LABEL release="$VERSION"
LABEL summary="Store secrets in Conjur or DAP and consume them in your Kubernetes / Openshift application containers"
LABEL description="To retrieve the secrets from Conjur or DAP, the CyberArk Secrets Provider for Kubernetes runs as an \
 init container or separate application container and fetches the secrets that the pods require"

# Add limited user
RUN groupadd -r secrets-provider \
             -g 777 && \
    useradd -c "secrets-provider runner account" \
            -g secrets-provider \
            -u 777 \
            -m \
            -r \
            secrets-provider && \
    # Ensure plugin dir is owned by secrets-provider user
    mkdir -p /usr/local/lib/secrets-provider /etc/conjur/ssl /run/conjur /licenses && \
    # Use GID of 0 since that is what OpenShift will want to be able to read things
    chown secrets-provider:0 /usr/local/lib/secrets-provider \
                           /etc/conjur/ssl \
                           /run/conjur && \
    # We need open group permissions in these directories since OpenShift won't
    # match our UID when we try to write files to them
    chmod 770 /etc/conjur/ssl \
              /run/conjur

COPY --from=secrets-provider-builder /opt/secrets-provider-for-k8s/secrets-provider /usr/local/bin/

COPY ./secrets-provider-for-k8s/LICENSE.md /licenses

USER secrets-provider

ENTRYPOINT [ "/usr/local/bin/secrets-provider"]