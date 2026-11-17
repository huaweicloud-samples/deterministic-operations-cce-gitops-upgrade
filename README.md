# deterministic-operations-cce-gitops-upgrade

[![Status](https://img.shields.io/badge/Status-Incubating-blue)]()
[![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-Samples-red)]()
[![Scenario](https://img.shields.io/badge/Scenario-deterministic%20operations-success)](https://3ms.huawei.com/docs/docinfo/1300901382590492672?bookstackId=866760814559879168&gid=3591759&l=zh-cn&documentkind=&attachmentIdx=5)

This practice provides a mechanism to **drive cluster version upgrades declaratively with Git as the single source of truth**. The target version lives in `cluster-config.yaml`; Terraform performs the upgrade in the order control plane → add-ons → node pool; Argo CD continuously renders the declared state into the cluster and reconciles it; a 7-check pre-upgrade gate and an 11-assertion post-upgrade validation bracket the change.

## Overview

This repository is created from the huaweicloud-samples automated repository request workflow.

## Getting Started

Add setup, deployment, and verification steps here.

## Contributing

Please use pull requests and follow the repository review rules.

## License

This project is licensed under the MIT-0 license.

## Maintainers

CODEOWNERS: @Ferguson2211

## Feedback

Please use GitHub Issues: https://github.com/huaweicloud-samples/deterministic-operations-cce-gitops-upgrade/issues
