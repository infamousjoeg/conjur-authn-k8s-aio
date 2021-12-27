# conjur-authn-k8s-aio <!-- omit in toc -->

Conjur Kubernetes All-in-One Dockerfile

- [Supported Authenticators](#supported-authenticators)
- [Usage](#usage)
  - [Build Secretless Broker](#build-secretless-broker)
  - [Build Conjur Authn-K8s Client](#build-conjur-authn-k8s-client)
  - [Build Secrets Provider for K8s](#build-secrets-provider-for-k8s)

## Supported Authenticators

* [Secretless Broker](https://github.com/cyberark/secretless-broker)
* [Conjur Authn-K8s Client](https://github.com/cyberark/conjur-authn-k8s-client)
* [Secrets Provider for K8s](https://github.com/cyberark/secrets-provider-for-k8s)

## Usage

### Build Secretless Broker

```shell
docker build --target secretless-broker -t cyberark/secretless-broker:v1.7.8 .
```

### Build Conjur Authn-K8s Client

```shell
docker build --target authenticator-client -t cyberark/conjur-authn-k8s-client:v0.22.0 .
```

### Build Secrets Provider for K8s

```shell
docker build --target secrets-provider -t cyberark/secrets-provider-for-k8s:v1.2.0 .
