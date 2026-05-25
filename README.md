# eip-controller Helm Chart

Helm chart for deploying the EIP Controller — a Kubernetes operator that assigns a dedicated AWS Elastic IP to each annotated scraper pod on EKS.

## Install

```bash
helm repo add eip-controller https://ronakforcast.github.io/eip-controller-helm
helm repo update
helm install eip-controller eip-controller/eip-controller \
  --namespace eip-controller --create-namespace \
  --set aws.region=us-east-1 \
  --set aws.clusterName=my-cluster \
  --set bam.registerURL=http://bam-service.internal/api/v1/register \
  --set bam.removeURL=http://bam-service.internal/api/v1/remove \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/EIPController
```

## How it works

1. Label a pod with `eip-controller.io/eip-managed: "true"`
2. The controller detects the pod, allocates an EIP from the AWS pool, and associates it to the pod's private IP on its ENI
3. The EIP is written back as a pod annotation (`eip-controller.io/eip-public-ip`)
4. On pod deletion the EIP is disassociated and released — no orphaned IPs

## Prerequisites

| Requirement | Details |
|-------------|---------|
| EKS cluster | VPC CNI with `EXTERNALSNAT=true` on scraper node groups |
| Public subnets | Scraper nodes must have an IGW route (not NAT Gateway) |
| IRSA role | IAM role with EC2 EIP permissions attached to the controller service account |
| EIP quota | Default AWS quota is 5 per region — request an increase before deploying at scale |

## Key values

| Value | Default | Description |
|-------|---------|-------------|
| `aws.region` | `us-east-1` | AWS region |
| `aws.clusterName` | `""` | EKS cluster name — used to scope EIP tags (required) |
| `bam.registerURL` | `""` | BAM register endpoint (required) |
| `bam.removeURL` | `""` | BAM remove endpoint (required) |
| `bam.existingSecret` | `""` | Kubernetes secret name containing `api-key` for BAM auth |
| `controller.replicas` | `2` | Number of controller replicas (leader election enabled by default) |
| `controller.ec2RatePerSec` | `5` | EC2 API calls per second |
| `leaderElection.enabled` | `true` | Enable leader election for HA |
| `prometheusRule.enabled` | `false` | Deploy PrometheusRule CRD (requires Prometheus Operator) |

Full values reference: [values.yaml](charts/eip-controller/values.yaml)

## Annotating pods

```yaml
metadata:
  annotations:
    eip-controller.io/eip-managed: "true"
    eip-controller.io/aggregation-group: "scraper-group-1"  # optional grouping label
```

## End-to-end test results

All 12 tests passed against a live EKS cluster (`eu-central-1`, VPC CNI, IRSA) on 2026-05-25.

| # | Scenario | Result |
|---|----------|--------|
| 1 | EIP allocated and annotation written to pod within 90 s | PASS |
| 2 | Pod egress traffic exits via its assigned EIP (`checkip.amazonaws.com`) | PASS |
| 3 | IP registry (BAM) `/register` called with correct IP, pod name, and namespace | PASS |
| 4 | Kubernetes `EIPAssigned` event emitted on successful allocation | PASS |
| 5 | EIP disassociated and released on pod deletion; IP registry notified | PASS |
| 6 | EIP assignment succeeds even when the IP registry is completely unavailable | PASS |
| 7 | Each pod in a 3-replica Deployment receives a unique EIP | PASS |
| 8 | Scale-to-zero releases all EIPs; scale-up allocates fresh IPs | PASS |
| 9 | Pod held in `Terminating` by finalizer while controller is down; EIP released on controller restart | PASS |
| 10 | Controller restart does not re-allocate EIPs — existing assignments are reused | PASS |
| 11 | Orphan reconciler detects and releases a manually leaked EIP within one 5-minute cycle | PASS |
| 12 | Zero orphaned EIPs remain in AWS after full test teardown | PASS |

**20 assertions, 0 failures.**

The test suite is included in the controller source repository and can be run against any EKS cluster:

```bash
CLUSTER_CTX=<kubectl-context> \
CLUSTER_NAME=<eks-cluster-name> \
AWS_REGION=<region> \
./test/run_tests.sh
```

Prerequisites before running: `EXTERNALSNAT=true` on the target node group, scraper node label (`node.kubernetes.io/scraper=true`) set, and AWS credentials with EC2 EIP permissions available in the environment.

## Upgrading

```bash
helm repo update
helm upgrade eip-controller eip-controller/eip-controller --namespace eip-controller
```

## Uninstalling

```bash
helm uninstall eip-controller --namespace eip-controller
```

> EIPs held by running pods are released automatically via Kubernetes finalizers before the controller is removed.
