# ANY-APP: Generic OCI Container Instance Autoscaling Template

Deploy any containerized application to OCI Container Instances with automatic horizontal autoscaling based on CPU and memory metrics.

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Deployment](#deployment)
- [Autoscaling Setup](#autoscaling-setup)
- [Supported Applications](#supported-applications)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

## Overview

This template provides a generic, reusable framework for deploying any containerized application to OCI Container Instances with built-in autoscaling capabilities. It includes:

- Generic Dockerfile templates for multiple runtime environments
- Automated deployment scripts
- OCI Functions for scale-up and scale-down operations
- Alarm-based autoscaling triggers
- Load balancer integration
- Health check configuration

## Features

✅ **Multi-Runtime Support**: Templates for Node.js, Python, Java, Go, .NET, and static content  
✅ **Automated Deployment**: Single-command deployment and teardown  
✅ **Auto-Scaling**: CPU and memory-based horizontal pod autoscaling  
✅ **Load Balancing**: Automatic backend registration/deregistration  
✅ **Health Checks**: Built-in health monitoring  
✅ **Production-Ready**: Security best practices and resource limits  
✅ **Customizable**: Easy to adapt for any application type  

## Prerequisites

### Required Tools

- **OCI CLI** (configured with valid credentials)
  ```bash
  oci --version
  ```

- **Docker** (for building container images)
  ```bash
  docker --version
  ```

- **Fn CLI** (for deploying autoscaling functions)
  ```bash
  fn --version
  ```

### OCI Resources

- OCI Compartment with appropriate permissions
- VCN with public/private subnets
- Container Instances service enabled
- Functions service enabled
- Load Balancer (optional, but recommended for autoscaling)

### IAM Policies

Ensure the following policies are in place:

```
Allow dynamic-group <your-dynamic-group> to manage container-instances in compartment <compartment-name>
Allow dynamic-group <your-dynamic-group> to manage load-balancers in compartment <compartment-name>
Allow dynamic-group <your-dynamic-group> to use virtual-network-family in compartment <compartment-name>
```

## Quick Start

### 1. Add Your Application Source Code

Place your application source code in the `application-source-code/` directory:

```bash
cd ANY-APP/application-source-code

# Copy your application files here
cp -r /path/to/your/app/* .

# Or use provided examples as starting point
mv package.json.example package.json  # For Node.js
mv server.js.example server.js
# OR
mv requirements.txt.example requirements.txt  # For Python
mv app.py.example app.py
```

**Important**: Your application MUST have a health check endpoint (e.g., `/health`) that returns HTTP 200.

### 2. Choose Your Application Type

Copy and customize the Dockerfile template for your application:

```bash
cd ANY-APP

# For Node.js applications
cp Dockerfile.template Dockerfile
# Edit Dockerfile and uncomment the Node.js section (OPTION 1)

# For Python applications
cp Dockerfile.template Dockerfile
# Edit Dockerfile and uncomment the Python section (OPTION 2)

# For Java/Spring Boot applications
cp Dockerfile.template Dockerfile
# Edit Dockerfile and uncomment the Java section (OPTION 3)
```

The Dockerfile will automatically copy from `application-source-code/` directory.

### 3. Configure Environment

```bash
# Copy configuration template
cp app.env.template app.env

# Edit app.env with your values
vi app.env
```

Minimum required configuration:
```bash
export OCI_COMPARTMENT_OCID="ocid1.compartment.oc1..xxxx"
export SUBNET_OCID="ocid1.subnet.oc1.region.xxxx"
export AD_NAME="US-ASHBURN-AD-1"
export DOCKER_USERNAME="your-docker-username"
export IMAGE_NAME="your-app-name"
export CONTAINER_NAME="your-app"
export DISPLAY_NAME="your-app-instance"
export APP_PORT="8080"
export HEALTH_CHECK_PATH="/health"
```

### 4. Build and Deploy

```bash
# Source configuration
source app.env

# Build Docker image
./deploy.sh --build

# Push to registry (Docker Hub, OCIR, etc.)
./deploy.sh --push

# Deploy to OCI Container Instances
./deploy.sh --deploy
```

### 5. Setup Autoscaling (Optional)

```bash
cd autoscaling/

# Copy autoscaling configuration
cp autoscaling.env.template autoscaling.env

# Edit with your values
vi autoscaling.env

# Source configuration
source autoscaling.env

# Deploy autoscaling infrastructure
./setup-autoscaling.sh --deploy
```

## Configuration

### Application Configuration (`app.env`)

| Variable | Description | Example |
|----------|-------------|---------|
| `OCI_COMPARTMENT_OCID` | Compartment OCID | `ocid1.compartment.oc1..xxxx` |
| `SUBNET_OCID` | Subnet OCID | `ocid1.subnet.oc1.region.xxxx` |
| `AD_NAME` | Availability Domain | `US-ASHBURN-AD-1` |
| `DOCKER_USERNAME` | Docker registry username | `myusername` |
| `DOCKER_REGISTRY` | Registry URL | `docker.io` or OCIR URL |
| `IMAGE_NAME` | Container image name | `my-app` |
| `IMAGE_TAG` | Image tag | `latest` or `v1.0.0` |
| `CONTAINER_NAME` | Container name | `my-app-container` |
| `DISPLAY_NAME` | Instance display name | `my-app-instance` |
| `APP_PORT` | Application port | `8080` |
| `HEALTH_CHECK_PATH` | Health check endpoint | `/health` or `/actuator/health` |
| `MEMORY_GB` | Memory allocation (GB) | `8` |
| `OCPUS` | CPU allocation | `1` |

### Autoscaling Configuration (`autoscaling/autoscaling.env`)

| Variable | Description | Default |
|----------|-------------|---------|
| `MIN_INSTANCES` | Minimum instances | `1` |
| `MAX_INSTANCES` | Maximum instances | `5` |
| `CPU_SCALE_UP_THRESHOLD` | CPU threshold for scale-up (%) | `70` |
| `CPU_SCALE_DOWN_THRESHOLD` | CPU threshold for scale-down (%) | `30` |
| `MEMORY_SCALE_UP_THRESHOLD` | Memory threshold for scale-up (%) | `70` |
| `MEMORY_SCALE_DOWN_THRESHOLD` | Memory threshold for scale-down (%) | `30` |
| `ALARM_EVALUATION_PERIOD` | Alarm evaluation period (minutes) | `5` |

## Deployment

### Build Docker Image

```bash
# Build image locally
./deploy.sh --build

# Build with custom tag
IMAGE_TAG="v1.0.0" ./deploy.sh --build
```

### Push to Registry

```bash
# Push to Docker Hub
./deploy.sh --push

# Login first if needed
docker login

# Or use environment variable
export DOCKER_PASSWORD="your-password"
./deploy.sh --push
```

### Deploy Container Instance

```bash
# Deploy single instance
./deploy.sh --deploy

# Check deployment status
./deploy.sh --status
```

### Undeploy

```bash
# Remove container instance
./deploy.sh --undeploy
```

## Autoscaling Setup

### Deploy Autoscaling Infrastructure

```bash
cd autoscaling/
source autoscaling.env
./setup-autoscaling.sh --deploy
```

This will create:
- OCI Functions Application
- Scale-up Function
- Scale-down Function  
- Notification Topic
- CPU High/Low Alarms
- Memory High/Low Alarms

### Check Autoscaling Status

```bash
./setup-autoscaling.sh --status
```

### Remove Autoscaling

```bash
./setup-autoscaling.sh --undeploy
```

## Supported Applications

### Node.js Applications

Requirements:
- `package.json` with dependencies
- Main file (e.g., `server.js`, `index.js`)
- Health check endpoint

Example Dockerfile section:
```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
EXPOSE 3000
CMD ["node", "server.js"]
```

### Python Applications

Requirements:
- `requirements.txt` with dependencies
- Main file (e.g., `app.py`)
- Health check endpoint

Example Dockerfile section:
```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["python", "app.py"]
```

### Java/Spring Boot Applications

Requirements:
- `pom.xml` or `build.gradle`
- Spring Boot application with embedded server
- Actuator health endpoint (recommended)

Example Dockerfile section:
```dockerfile
FROM maven:3.9.5-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn clean package -DskipTests

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### Go Applications

Requirements:
- `go.mod` and `go.sum`
- Main package with HTTP server
- Health check endpoint

Example Dockerfile section:
```dockerfile
FROM golang:1.21-alpine AS build
WORKDIR /app
COPY go.* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o main .

FROM alpine:latest
WORKDIR /app
COPY --from=build /app/main .
EXPOSE 8080
CMD ["./main"]
```

## Architecture

```
                               +--------------------+
                               |  OCI Monitoring    |
                               |  (Alarms / MQL)    |
                               +---------+----------+
                                         |
                                         v
    Internet --> [Load Balancer] --> [Container Instances Pool]
                             ^           ^    ^
                             |           |    |
                             |           |    +-- scale-down fn (terminates instance)
                             |           +------- scale-up fn (creates instance)
                             |
                        Backend Set
                    (auto register/deregister)
```

### Components

1. **Container Instances**: Your application running in OCI Container Instances
2. **Load Balancer**: Distributes traffic across instances
3. **OCI Monitoring**: Collects CPU/Memory metrics
4. **Alarms**: Trigger when thresholds are exceeded
5. **OCI Functions**: Execute scale-up/scale-down operations
6. **Notifications**: Alert topic for function invocations

## Troubleshooting

### Container Instance Won't Start

Check the logs:
```bash
# Get instance OCID
oci container-instances container-instance list \
  --compartment-id $OCI_COMPARTMENT_OCID \
  --display-name $DISPLAY_NAME

# View logs
oci container-instances container-instance get-logs \
  --container-instance-id <instance-ocid>
```

### Health Check Failing

1. Verify your application is listening on the correct port
2. Check the health check path is accessible
3. Ensure health endpoint returns 200 OK
4. Test locally:
   ```bash
   docker run -p 8080:8080 your-image
   curl http://localhost:8080/health
   ```

### Autoscaling Not Triggering

1. Check alarm status:
   ```bash
   oci monitoring alarm list --compartment-id $COMPARTMENT_OCID
   ```

2. Verify function logs:
   ```bash
   fn invoke <app-name> <function-name>
   ```

3. Check metrics are being collected:
   ```bash
   oci monitoring metric list --compartment-id $COMPARTMENT_OCID
   ```

### Load Balancer Backend Unhealthy

1. Check backend health:
   ```bash
   oci lb backend-health get \
     --load-balancer-id $LB_OCID \
     --backend-set-name $BACKEND_SET_NAME \
     --backend-name <backend-name>
   ```

2. Verify security list allows traffic from LB to container
3. Check container health check is passing

## Advanced Usage

### Custom Environment Variables

Add custom variables to your container:

```bash
# In deploy.sh, modify the container creation JSON:
"environmentVariables": [{
  "name": "DATABASE_URL",
  "value": "your-database-url"
}, {
  "name": "API_KEY",
  "value": "your-api-key"
}]
```

### Multiple Containers per Instance

Edit the `create_container_instance` function in `deploy.sh` to add more containers:

```bash
"containers": [{
  "imageUrl": "${IMAGE_URI}",
  "displayName": "main-app"
}, {
  "imageUrl": "redis:alpine",
  "displayName": "redis-cache"
}]
```

### Custom Health Checks

Modify health check parameters in `deploy.sh`:

```bash
"healthChecks": [{
  "healthCheckType": "HTTP",
  "path": "${HEALTH_CHECK_PATH}",
  "port": ${APP_PORT},
  "intervalInSeconds": 30,
  "timeoutInSeconds": 3,
  "failureThreshold": 3,
  "successThreshold": 1
}]
```

## Support and Contribution

For issues, questions, or contributions, please refer to the main repository.

## License

See the main repository for license information.

---

**Note**: This is a generic template. Customize it according to your specific application requirements and organizational policies.
