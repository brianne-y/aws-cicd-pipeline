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
### Step 1 — Flask Application and Dockerfile

All work in this step runs locally on my Mac. Docker Desktop needs to be open and running before any docker commands will work. The whale icon in the menu bar confirms the engine is active.

I verified Docker was installed and working by running two commands in my terminal. The first confirmed the version. The second pulled the hello-world image from Docker Hub and ran it as a container, printing a confirmation message that the installation was successful.

![Docker Installed and Hello World](screenshots/docker-installed-hello-world.png)

With Docker confirmed, I opened my terminal and created the project directory:

```bash
mkdir project-3-ecs-pipeline && cd project-3-ecs-pipeline
```

I then opened the entire project folder in VS Code:

```bash
code .
```

Inside VS Code I created four files directly from the sidebar: app.py, requirements.txt, .dockerignore, and Dockerfile.

![VS Code Project Structure](screenshots/vscode-project-structure.png)

**app.py** is a minimal Flask application with two endpoints. The root endpoint returns a JSON status response. The /health endpoint is what the ALB uses to verify the container is healthy before routing traffic to it. The application listens on 0.0.0.0 so it accepts connections from any network interface inside the container.

**requirements.txt** contains a single dependency. Flask is pinned to version 3.0.3 so every build installs the exact same package rather than pulling whatever the latest version happens to be at build time.

**.dockerignore** tells Docker what to exclude when building the container image. The .git folder, Terraform files, and the README have no business being inside a running container. Excluding them keeps the image smaller and avoids accidentally copying sensitive values into it.

**Dockerfile** builds the container image with security decisions built in from the start. It uses python:3.12-slim as the base image with a pinned version rather than :latest. It creates a non-root user called appuser and runs the application as that user rather than root. Dependencies are installed before the application code is copied so Docker can cache that layer. If only app.py changes on a future build, pip does not reinstall everything from scratch. A built-in health check runs every 30 seconds so ECS knows whether the container is actually healthy, not just running.

I verified the application ran correctly by starting it locally and hitting both endpoints:

![Flask App Local Test](screenshots/flask-app-local-test.png)

### Step 2 — Remote State S3 Bucket

Before running Terraform, I created the S3 bucket that stores the Terraform state file remotely. This has to be done manually because Terraform cannot create the bucket it needs to store its own state. It is a dependency that has to exist first.

I created the bucket and enabled versioning in a single command:

```bash
aws s3 mb s3://brianne-terraform-state-2026 --region us-east-1 && aws s3api put-bucket-versioning --bucket brianne-terraform-state-2026 --versioning-configuration Status=Enabled
```

Versioning means previous state file versions can be recovered if anything gets corrupted. Public access is blocked by default on all new S3 buckets in AWS so no additional configuration was needed there.

I confirmed the bucket was created and versioning was enabled directly from the terminal rather than clicking through the console.

![S3 Remote State Created](screenshots/s3-remote-state-created.png)

### Step 3 — Terraform Project Structure

With the S3 backend in place, I created the Terraform project files inside the same project directory. All five files were created directly in VS Code from the sidebar.

Here is what each file does and why it exists:

**providers.tf** tells Terraform which cloud provider to use, what version is required, and where to store the state file. This is written first because everything else depends on it.

**variables.tf** defines placeholders for values that change between environments or contain sensitive information. The GitHub repository name, alert email address, and application name are all defined here as variables rather than hardcoded into the infrastructure.

**terraform.tfvars** is where those placeholders get filled in with real values. This file never gets committed to GitHub. It is blocked by .gitignore from the very first commit so sensitive values never accidentally get pushed.

**main.tf** is the core of the project. It defines every piece of infrastructure Terraform will build across six sections: VPC and networking, security groups, ECR repository, IAM roles, ALB and ECS cluster and service, and CloudWatch monitoring. This is the file that turns code into real cloud infrastructure.

**outputs.tf** prints useful values to the terminal after terraform apply finishes: the ALB DNS name to test the application, the ECR URL to push images, the ECS cluster and service names for the GitHub Actions workflow, and the GitHub Actions role ARN to configure the OIDC secret.

![Project Structure VS Code](screenshots/project-structure-vscode.png)

### Step 4 — Infrastructure Deployment with Terraform

With all five files written and the S3 backend in place, I ran terraform init to initialize Terraform, download the AWS provider plugin, and connect to the remote backend.

![Terraform Init](screenshots/terraform-init.png)

terraform plan validated 37 resources to be created across the full stack. I reviewed the plan before applying to confirm every resource matched what was designed.

![Terraform Plan](screenshots/terraform-plan.png)

Running terraform apply provisioned everything in a single command: VPC, public and private subnets across two availability zones, internet gateway, NAT gateway, route tables, security groups, ECR repository with vulnerability scanning, IAM roles, ALB, ECS cluster, ECS task definition and service, CloudWatch log group, SNS topic, and two CloudWatch alarms.

![Terraform Apply Complete](screenshots/terraform-apply-complete.png)

**VPC and Networking** — I built a VPC with four subnets across two availability zones. Two public subnets host the ALB. Two private subnets host the ECS Fargate tasks. A NAT Gateway in the public subnet gives the private subnets outbound internet access for pulling container images and sending logs to CloudWatch, without exposing the tasks to inbound traffic from the internet.

**Security Groups** — Two security groups enforce least privilege at the network layer. The ALB accepts port 80 from the internet. ECS tasks accept port 5000 from the ALB security group only. A security group rule rather than a CIDR block is used for the connection between them so the rule follows the resource automatically rather than breaking if an IP address changes. This also breaks the circular dependency that would occur if both security groups referenced each other directly.

**ECR Repository** — The container image registry is created with scan_on_push enabled so every image pushed is automatically scanned against a database of known vulnerabilities. A lifecycle policy retains the last 10 images and expires older ones automatically.

**IAM Roles** — Three IAM roles are created. The ECS execution role gives the ECS control plane permission to pull images from ECR and send logs to CloudWatch. The ECS task role is what the Flask application itself uses at runtime and is kept separate from the execution role intentionally. The GitHub Actions role uses OIDC instead of stored credentials and is scoped to this specific repository and the main branch only.

**ALB, ECS Cluster, Task Definition, and Service** — The Application Load Balancer is deployed across both public subnets and is the only entry point for internet traffic. The ECS service is initially set to desired_count of 0 to avoid a failed image pull state before the real Flask image exists in ECR. A lifecycle block tells Terraform to ignore future changes to the task definition and desired count so the GitHub Actions pipeline can manage deployments without Terraform overwriting them.

**CloudWatch and Alerting** — A log group is created with a 30 day retention policy. Two alarms are created: one monitors ALB 5xx error rates and one monitors ECS running task count. Both send email alerts via SNS when thresholds are exceeded.

![VPC Private Subnet NAT](screenshots/vpc-private-subnet-nat.png)

![VPC Public Subnet IGW](screenshots/vpc-public-subnet-igw.png)


### Step 5 — Bootstrap: First Image Push and Service Scale

With the infrastructure live, the ECS service existed but was running zero tasks. The task definition was pointing to a placeholder Python image with no Flask app in it. Before the GitHub Actions pipeline could take over, I needed to push the real Flask image to ECR and update the task definition to use it.

I set the ECR URL as a variable in my terminal to avoid retyping the full registry path on every command:

```bash
ECR_URL="YOUR-ACCOUNT-ID.dkr.ecr.us-east-1.amazonaws.com/project-3-flask"
```

I authenticated Docker to ECR using the AWS CLI:

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_URL
```

I built the Flask image locally and tagged it as bootstrap to distinguish it from images the pipeline would push later:

```bash
docker build -t $ECR_URL:bootstrap .
```

I pushed the image to ECR:

```bash
docker push $ECR_URL:bootstrap
```

I then registered a new task definition revision pointing to the bootstrap image and forced the ECS service to deploy it with a desired count of 2:

```bash
aws ecs update-service \
  --cluster project-3-flask-cluster \
  --service project-3-flask-service \
  --task-definition project-3-flask \
  --desired-count 2 \
  --force-new-deployment
```

Once both tasks passed their health checks and showed as running, I opened the ALB DNS URL in a browser and confirmed the Flask application was live and serving traffic.

![Flask App Live ALB](screenshots/flask-app-live-alb.png)

![ECS Service Healthy](screenshots/ecs-service-healthy.png)

![Target Group Healthy](screenshots/target-group-healthy.png)

### Step 6 — GitHub Actions Deployment Workflow

With the bootstrap complete and the application live, the next step was setting up the pipeline that would automate every future deployment. From this point forward, pushing code to the main branch is the only manual step required. Everything else happens automatically.

Before creating the workflow file I added one secret to the GitHub repository. Under Settings > Secrets and variables > Actions I added AWS_ROLE_ARN with the GitHub Actions role ARN from the Terraform outputs. This is the only credential the pipeline needs. There is no AWS access key and no secret key stored anywhere.

I created the workflow file directly on GitHub at .github/workflows/deploy.yml. The pipeline has seven steps:

1. Check out the repository code
2. Authenticate to AWS using OIDC with no stored credentials
3. Log Docker into ECR using the authenticated session
4. Build the Docker image tagged with the commit SHA and push it to ECR
5. Download the current ECS task definition from AWS
6. Inject the new image URI into the task definition
7. Deploy the updated task definition to ECS using a rolling update and wait for stability

The first pipeline run failed immediately because my local project code had not been pushed to GitHub yet. The workflow file existed but the Dockerfile, app.py, and every other file were still only on my Mac. GitHub Actions had nothing to build from.

![GitHub Actions Pipeline Error](screenshots/github-actions-pipeline-error.png)

I pushed the local code to GitHub:

```bash
git add .
git commit -m "Initial commit: Flask app, Dockerfile, and Terraform infrastructure"
git push -u origin main
```

That push triggered a second pipeline run automatically. This time all seven steps completed successfully in 3 minutes and 21 seconds.

![GitHub Actions Pipeline Success](screenshots/github-actions-pipeline-success.png)




## Let's Connect!

Brianne Young | Cloud Engineer | [LinkedIn](https://www.linkedin.com/in/brianne-young0/) | [GitHub](https://github.com/brianne-y)
