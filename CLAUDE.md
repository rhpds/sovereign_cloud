# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the `rhpds.sovereign_cloud` Ansible Collection for managing Red Hat OpenShift Sovereign Cloud deployments. It integrates with Red Hat Advanced Cluster Management (RHACM), Hosted Control Planes (HCP), and Single Node OpenShift (SNO) clusters.

## Commands

### Running Static Checks

```bash
# Run all static checks (linting, syntax validation)
tox -c tests/static

# Run checks for specific PR diff (used in CI)
tox -c tests/static -- <base_branch> <commit_sha>
```

### Manual Linting

```bash
# YAML linting
yamllint -c tests/static/.yamllint .

# Python linting
flake8 --config tests/static/.flake8
pylint --rcfile tests/static/.pylintrc <files>
```

## Architecture

### Role Pattern

Both roles use a dispatch pattern in `tasks/main.yml` based on the `ACTION` variable:
- `ACTION == "provision"` → runs `workload.yml`
- `ACTION == "destroy"` → runs `remove_workload.yml`

### Roles

**`ocp4_workload_prepare_hcp`**: Prepares HCP cluster deployment by creating namespace and pull-secret in the HCP namespace from the existing `openshift-config` pull-secret.

**`ocp4_workload_register_sno`**: Registers an SNO cluster with RHACM by:
1. Creating a ManagedCluster resource on the RHACM hub
2. Waiting for the import manifest secret
3. Applying the Klusterlet CRD and import resources to the target SNO cluster

### External Dependencies

- `kubernetes.core` collection for K8s API operations
- `agnosticd.core.agnosticd_user_info` module for passing user information to the agnosticd framework

### Multi-Cluster Operations

The `register_sno` role operates across two clusters using separate API URLs and tokens:
- RHACM hub: `ocp4_workload_register_sno_rhacm_openshift_api_url/token`
- Target SNO: `ocp4_workload_register_sno_aws_openshift_api_url/token`

## Code Style

- YAML line length: 150 characters max
- Python line length: 120 characters max
- Indentation: 2 spaces for YAML
- Uses `yamllint`, `flake8`, `pylint`, and `ansible-lint` for validation
