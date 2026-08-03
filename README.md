# GitHub Actions Self-Hosted Runner

Custom Docker image and AWS infrastructure for org-wide ephemeral GitHub Actions self-hosted runners on Fargate. Based on [myoung34/docker-github-actions-runner](https://github.com/myoung34/docker-github-actions-runner).

## Architecture

```
GitHub webhook (workflow_job)
    │
    ▼
API Gateway ──► WebhookReceiver Lambda (HMAC validation)
                    │
                    ▼
                SQS Queue (rate control)
                    │
                    ▼
            TaskLauncher Lambda (MaxConcurrency controlled)
                    │
                    ▼
            ECS Fargate Task (ephemeral runner)
                    │
                    ▼
            Registers with GitHub ──► Runs job ──► Self-terminates
```

## Project Structure

```
.
├── Dockerfile.base          # Base image: Ubuntu 24.04 + system deps
├── Dockerfile               # Final image: base + GitHub Actions runner binary
├── build/
│   ├── config.json          # Package manifest (add/remove tools here)
│   ├── config.sh            # Config reader functions
│   ├── install_base.sh      # Main install orchestrator
│   ├── sources.sh           # APT repository configuration
│   └── tools.sh             # Per-tool install functions
├── scripts/
│   ├── install_actions.sh   # Downloads GitHub Actions runner
│   ├── entrypoint.sh        # Container entrypoint
│   ├── token.sh             # Runner registration token
│   └── app_token.sh         # GitHub App authentication
├── infra/
│   └── template.yaml        # CloudFormation (full stack)
├── buildspec.yml            # CodeBuild spec
└── .dockerignore
```

## Infrastructure (AWS CloudFormation)

Single stack in `infra/template.yaml` deploys:

**CI/CD Pipeline:**
- ECR Repository (KMS encrypted, scan on push, lifecycle policies)
- CodePipeline (GitHub → CodeBuild → ECR)
- CodeBuild (privileged mode for Docker builds)
- S3 Artifact Bucket (KMS encrypted)

**Runner Infrastructure:**
- KMS Key (shared: ECR, Secrets Manager, CloudWatch Logs, SQS)
- Secrets Manager (GitHub PAT + webhook secret)
- SQS Queues (encrypted, with DLQ)
- ECS Task Definition (Fargate, ephemeral)
- Lambda: Webhook Receiver (HMAC validation, processes `queued` + `waiting` events)
- Lambda: Task Launcher (rate-controlled via SQS MaximumConcurrency)
- API Gateway HTTP (webhook endpoint)
- Security Group (egress-only)
- S3 VPC Endpoint (restricts S3 access to VPC)

### Prerequisites

1. [CodeStar Connection](https://docs.aws.amazon.com/codepipeline/latest/userguide/connections-github.html) to GitHub in `AVAILABLE` status
2. Existing ECS cluster
3. VPC with private subnets + NAT Gateway
4. AWS CLI configured

### Deploy

```bash
aws cloudformation deploy \
  --template-file infra/template.yaml \
  --stack-name github-runners \
  --parameter-overrides \
    EnvironmentName=prod \
    GitHubOwner=your-org \
    GitHubRepo=Github-Runners \
    GitHubBranch=main \
    CodeStarConnectionArn=arn:aws:codestar-connections:us-east-1:ACCOUNT:connection/ID \
    RepositoryName=github-actions-runner \
    GHRunnerVersion=2.336.0 \
    ECSClusterName=YOUR-CLUSTER \
    VpcId=vpc-xxx \
    SubnetIds=subnet-a,subnet-b \
    RouteTableIds=rtb-xxx \
    GitHubOrg=your-org \
    GitHubPAT=ghp_xxx \
    GitHubWebhookSecret=your-secret \
  --capabilities CAPABILITY_NAMED_IAM
```

### GitHub Webhook Setup

After deploying, configure an org-level webhook:

1. Go to **Organization Settings → Webhooks → Add webhook**
2. **Payload URL:** Use the `WebhookUrl` output from the stack
3. **Content type:** `application/json`
4. **Secret:** Same value as `GitHubWebhookSecret` parameter
5. **Events:** Select "Workflow jobs" only

## Customization

### Add/Remove Tools

Edit `build/config.json`:

- `source: "apt"` — installed via apt-get
- `source: "script"` — custom install function in `build/tools.sh`

### Change Runner Version

Update `GH_RUNNER_VERSION` in `Dockerfile` (or pass via CodeBuild parameter).

### Change Base OS

Update the `FROM` line + digest in `Dockerfile.base`.

## Local Build

```bash
docker build -f Dockerfile.base -t github-runner-base:latest .
docker build -t github-runner:latest .
```

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `REPO_URL` | Repository URL (repo-scoped runners) | Yes* |
| `ORG_NAME` | Organization name (org-scoped runners) | Yes* |
| `ACCESS_TOKEN` | PAT with admin:org scope | Yes** |
| `APP_ID` | GitHub App ID | Yes** |
| `APP_PRIVATE_KEY` | GitHub App private key (PEM) | Yes** |
| `APP_LOGIN` | GitHub App installation login | Yes** |
| `RUNNER_NAME` | Runner name | No |
| `LABELS` | Comma-separated labels | No |
| `RUNNER_SCOPE` | `repo`, `org`, or `enterprise` | No (default: repo) |
| `EPHEMERAL` | Ephemeral runner (terminates after one job) | No |
| `DISABLE_AUTO_UPDATE` | Disable runner auto-update | No |
| `START_DOCKER_SERVICE` | Start Docker-in-Docker | No |
| `RUN_AS_ROOT` | Run as root user | No (default: false) |

\*One required depending on scope.
\*\*Either `ACCESS_TOKEN` OR `APP_ID` + `APP_PRIVATE_KEY` + `APP_LOGIN`.

## Security Notes

- Runners are **ephemeral** — destroyed after each job
- Containers run as non-root user (`runner`, UID 1001) by default
- All data at rest encrypted with KMS (ECR, SQS, Secrets, Logs, S3)
- S3 access restricted to VPC endpoint
- Security group allows egress-only (no inbound)
- Webhook payloads validated via HMAC-SHA256
- Some ECR scan findings (Go stdlib, golang.org/x/crypto, openssl) are upstream dependencies in precompiled binaries (GitHub runner, Docker CE) that cannot be patched at the image level — see risk acceptance documentation
