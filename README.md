# my-dr-project

Cross-cluster DR lab: Kind + MongoDB + Kasten K10 + AWS S3.

## Prerequisites
- kind, kubectl, terraform, make, helm

## Quick start
    cp .env.example .env   # fill in AWS creds
    make e2e

## Layout
    terraform/   S3 bucket for Kasten backups
    manifests/   Kind config, MongoDB, Kasten values
    scripts/     bootstrap, deploy-kasten, validate-backup