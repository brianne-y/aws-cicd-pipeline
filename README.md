# Containerized Microservice with Automated CI/CD Pipeline

## Scenario — What Problem Are We Solving?

This project simulates a problem that every engineering team eventually hits: deployments become a liability.

When updates are deployed manually, every release carries human risk. Someone has to SSH into a server, pull the latest code, restart a process, and confirm nothing broke. That works once. It does not work when a team is shipping updates daily, when multiple engineers are involved, or when a deployment happens at the wrong moment and takes a service down. There is no audit trail, no automatic rollback, and no consistent process from one deployment to the next.

The goal of this project was to eliminate manual deployments entirely. I containerized a Flask application using Docker, stored container images in Amazon ECR, and built a GitHub Actions pipeline that automatically builds, pushes, and deploys a new version to ECS Fargate every time code is pushed to the main branch. A deployment now takes the same steps, in the same order, every single time, with no human involvement after the push. If a deployment fails a health check, ECS rolls it back automatically.

This is my third AWS project and the most complex build I have done so far. Project 2 taught me Terraform and three-tier infrastructure. This one adds containers, a private networking layer, automated deployments, and zero stored credentials. I will be honest: there was a meaningful jump in complexity between the two. This documentation reflects the actual build, including where I got stuck and what I learned.

---

## Architecture

The application runs on Amazon ECS Fargate inside private subnets with no public IP addresses assigned. All inbound traffic enters through an Application Load Balancer sitting in public subnets. The ALB is the only entry point from the internet. Container images are stored in Amazon ECR and pulled by ECS during each deployment.

For outbound access from the private subnets (pulling images, sending logs to CloudWatch), a NAT Gateway handles the routing without exposing the containers to the internet directly.

The deployment pipeline works like this: a push to the main branch on GitHub triggers GitHub Actions. The workflow authenticates to AWS using OIDC with no stored credentials, builds a new Docker image tagged with the commit SHA, pushes it to ECR, and tells ECS to deploy it using a rolling update strategy. If the new containers fail their health checks, ECS rolls back to the previous version automatically.

Traffic flow:      User → ALB (public subnets) → ECS Fargate tasks (private subnets, no public IP)

Deployment flow:   GitHub push → OIDC auth → Docker build → ECR push → ECS rolling deploy

Outbound access:   ECS tasks → NAT Gateway → internet (image pulls, log delivery)


*Full architecture diagram will be added once the build is complete.*

---

## AWS Services Used

- **Docker** — packages the Flask application and all its dependencies into a container image that runs identically in every environment
- **Amazon ECR** — private container registry that stores every image version with vulnerability scanning on every push and a lifecycle policy keeping the last 10 images
- **Amazon ECS Fargate** — runs the containers without requiring server management; AWS handles the underlying compute and I define what runs on it
- **Application Load Balancer** — the single controlled entry point for all internet traffic; routes requests to healthy containers and performs health checks before sending traffic to a new deployment
- **Amazon VPC** — isolated network with public subnets for the ALB and private subnets for the ECS tasks, with a NAT Gateway providing outbound access from the private layer
- **AWS IAM** — two separate roles: one for the ECS control plane (pulling images, writing logs) and one for the application runtime; plus a GitHub Actions OIDC role scoped to this specific repository and the main branch only
- **GitHub Actions** — the CI/CD pipeline that automates the entire build and deployment process on every push with no manual steps
- **Amazon CloudWatch** — collects container logs with a 30-day retention policy and monitors ALB error rates and ECS task counts with SNS alerting
- **Amazon SNS** — sends email alerts when CloudWatch thresholds are exceeded
- **Amazon S3** — remote Terraform state storage with a new key for this project's state file
- **Terraform** — all 36 resources defined and deployed as Infrastructure as Code

---

## Obstacles — Constraints and Security Requirements

**ECS tasks must never have a public IP address.**
Assigning a public IP to a compute resource means it is reachable from the internet, even if nothing is intentionally listening on it. In this architecture, ECS tasks live in private subnets and the option to assign a public IP is disabled at the resource level. The only way to reach the application is through the ALB. Someone who discovers a container's IP address gets nowhere because there is no network path to it from the internet.

**No AWS credentials are stored anywhere in GitHub.**
The most common CI/CD security mistake is storing an AWS access key as a GitHub secret. If that key is ever exposed, anyone who has it can act as that IAM user until the key is manually rotated. This pipeline uses IAM OIDC instead. When GitHub Actions runs, it proves its identity to AWS using a short-lived cryptographic token and receives temporary credentials scoped to exactly what the pipeline needs. There is no long-lived secret to rotate, leak, or forget about.

**The OIDC trust policy is scoped to this repository and the main branch only.**
It is not enough to trust GitHub as an identity provider broadly. The trust policy in this project specifies the exact repository and the exact branch allowed to authenticate. A workflow running from a forked repository or a different branch cannot assume this role. The scope of any potential compromise is limited before anything can go wrong.

**Two separate IAM roles handle two separate jobs.**
The ECS execution role is what the ECS control plane uses to pull container images from ECR and send logs to CloudWatch. The ECS task role is what the Flask application itself uses at runtime. Combining them into one role would mean a vulnerability in the application could potentially be used to access infrastructure-level permissions. Keeping them separate enforces least privilege at both levels independently.

**Container images are scanned for vulnerabilities on every push.**
Every image pushed to ECR is automatically scanned against a database of known vulnerabilities. This does not replace a full security program, but it does mean issues in the base image or installed packages are flagged immediately rather than discovered later in production.

**The Dockerfile runs the application as a non-root user.**
By default, processes inside a Docker container run as root. If an attacker exploits a vulnerability in the application, root access inside the container makes further damage significantly easier. Running as a dedicated non-root user limits what a compromised container can actually do.

**Deployment failures roll back automatically.**
ECS is configured with a circuit breaker that monitors the health of newly deployed containers. If a deployment fails its health checks, ECS stops the rollout and reverts to the previous working version without any manual intervention needed. A bad deployment does not stay bad.

---

## Actions — What Was Built and Why
*This project is still currently being built. Please return within the next 1-2 days to see it come to life! :)*


## Let's Connect!

Brianne Young | Cloud Engineer | [LinkedIn](https://www.linkedin.com/in/brianne-young0/) | [GitHub](https://github.com/brianne-y)
