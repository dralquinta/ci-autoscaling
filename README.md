# Autoscaling Demo Application

A simple Spring Boot application designed to test autoscaling features in Docker and OCI Container Instances. This application provides REST endpoints to generate CPU and memory load for testing horizontal pod autoscaling (HPA) and container orchestration systems.

## Features

- **CPU Load Testing**: Endpoint to generate CPU-intensive workload
- **Memory Load Testing**: Endpoint to allocate memory for memory-based autoscaling
- **Combined Load Testing**: Test both CPU and memory simultaneously
- **Health Checks**: Built-in health endpoints for container orchestration
- **Prometheus Metrics**: Integrated metrics for monitoring and autoscaling decisions
- **Docker Support**: Multi-stage Dockerfile for optimized container images

## Prerequisites

- Java 17 or higher
- Maven 3.6+
- Docker and Docker Compose
- Fn CLI
- OCI CLI
- IAM Policies for DynGroup on Functions
- OCIR Token

## Project Structure

```
ci-autoscaling/
├── src/
│   └── main/
│       ├── java/com/demo/sonda/
│       │   ├── AutoscalingDemoApplication.java
│       │   └── controller/
│       │       └── LoadTestController.java
│       └── resources/
│           └── application.properties
├── Dockerfile
├── docker-compose.yml
├── pom.xml
└── README.md
```

## API Endpoints

### Health & Info
- `GET /api/health` - Simple health check
- `GET /api/info` - Application and system information
- `GET /actuator/health` - Spring Boot Actuator health endpoint
- `GET /actuator/metrics` - Available metrics
- `GET /actuator/prometheus` - Prometheus-formatted metrics

### Load Testing Endpoints

#### CPU Load
```bash
GET /api/cpu?iterations=1000
```
Generates CPU load by performing mathematical calculations.
- **Parameters**: 
  - `iterations` (optional, default: 1000) - Number of calculation iterations (x1000)

#### Memory Load
```bash
GET /api/memory?sizeMB=10
```
Allocates memory to test memory-based autoscaling.
- **Parameters**: 
  - `sizeMB` (optional, default: 10) - Amount of memory to allocate in MB

#### Clear Memory
```bash
DELETE /api/memory
```
Clears all allocated memory and triggers garbage collection.

#### Combined Load
```bash
GET /api/combined?cpuIterations=500&memoryMB=5
```
Tests both CPU and memory simultaneously.
- **Parameters**: 
  - `cpuIterations` (optional, default: 500)
  - `memoryMB` (optional, default: 5)

## Quick Start

### Option 1: Deploy to OCI Container Instances (Recommended)

1. **Configure deployment**:
```bash
# Edit deploy.env with your OCI resource OCIDs
vi deploy.env

# Source the configuration
source deploy.env
```

2. **Deploy to OCI**:
```bash
./deploy.sh
```

The script will:
- Build the Docker image
- Push to Docker registry
- Create/update OCI Container Instance
- Configure health checks
- Optionally configure load balancer backend

3. **Test the deployment**:
```bash
# Use the private IP from deployment output
export APP_IP="<container-private-ip>"

# Run autoscaling tests
./test-autoscaling.sh http://${APP_IP}:8080
```

### Option 2: Using Docker Compose (Local Development)

1. **Build and run the application**:
```bash
docker-compose up --build
```

2. **Access the application**:
```bash
# Health check
curl http://localhost:8080/api/health

# System info
curl http://localhost:8080/api/info

# Test CPU load
curl http://localhost:8080/api/cpu?iterations=2000

# Test memory load
curl http://localhost:8080/api/memory?sizeMB=50
```

3. **Stop the application**:
```bash
docker-compose down
```

### Option 3: Using Docker directly

1. **Build the Docker image**:
```bash
docker build -t autoscaling-demo:latest .
```

2. **Run the container**:
```bash
docker run -d -p 8080:8080 --name autoscaling-demo autoscaling-demo:latest
```

3. **View logs**:
```bash
docker logs -f autoscaling-demo
```

4. **Stop and remove**:
```bash
docker stop autoscaling-demo
docker rm autoscaling-demo
```

### Option 4: Local Development

1. **Build the application**:
```bash
mvn clean package
```

2. **Run the application**:
```bash
java -jar target/autoscaling-demo-1.0.0.jar
```

## Autoscaling Use Cases

This application provides **three specific use cases** to test autoscaling:

### Use Case 1: CPU-Based Autoscaling (>60%)
Trigger autoscaling when CPU utilization exceeds 60%.

```bash
# Start sustained CPU load at 75%
curl -X POST "http://localhost:8080/api/scenario/cpu/start?targetCpuPercent=75&durationSeconds=300"

# Monitor status
curl http://localhost:8080/api/scenario/status

# Stop CPU load
curl -X POST "http://localhost:8080/api/scenario/cpu/stop"
```

### Use Case 2: Memory-Based Autoscaling (>60%)
Trigger autoscaling when memory utilization exceeds 60%.

```bash
# Start sustained memory load at 75%
curl -X POST "http://localhost:8080/api/scenario/memory/start?targetMemoryPercent=75&durationSeconds=300"

# Monitor status
curl http://localhost:8080/api/scenario/status

# Stop memory load
curl -X POST "http://localhost:8080/api/scenario/memory/stop"
```

### Use Case 3: Health Check Failure
Trigger pod replacement/restart when health checks fail (non-200 HTTP responses or timeouts).

```bash
# Trigger health check failures
curl -X POST "http://localhost:8080/api/scenario/health/fail?durationSeconds=300"

# Check health status (will return 503/500)
curl -i http://localhost:8080/api/scenario/health/status

# Recover health checks
curl -X POST "http://localhost:8080/api/scenario/health/recover"
```

### Automated Testing
Run all three scenarios automatically:

```bash
./test-autoscaling.sh http://localhost:8080
```

For detailed documentation on each use case, see [AUTOSCALING_USE_CASES.md](AUTOSCALING_USE_CASES.md).

## Testing Autoscaling

### Simulate Load with Apache Bench (ab)

```bash
# Install Apache Bench
sudo apt-get install apache2-utils  # Ubuntu/Debian
# or
brew install apache2  # macOS

# Generate sustained CPU load
ab -n 10000 -c 100 http://localhost:8080/api/cpu?iterations=1000

# Generate memory load
ab -n 1000 -c 50 http://localhost:8080/api/memory?sizeMB=10

# Combined load test
ab -n 5000 -c 100 http://localhost:8080/api/combined?cpuIterations=800&memoryMB=8
```

### Simulate Load with curl loop

```bash
# CPU load test
for i in {1..100}; do
  curl "http://localhost:8080/api/cpu?iterations=1500" &
done
wait

# Memory load test
for i in {1..50}; do
  curl "http://localhost:8080/api/memory?sizeMB=20" &
done
wait
```

## OCI Container Instances Deployment

### Prerequisites
- OCI CLI installed and configured
- Docker installed
- Access to OCI Compartment and VCN/Subnet
- Docker Hub account (or other registry)

### Deployment Steps

1. **Configure environment variables** in `deploy.env`:
```bash
export OCI_COMPARTMENT_OCID="ocid1.compartment.oc1..aaaaaaaxxxxxx"
export SUBNET_OCID="ocid1.subnet.oc1.region.aaaaaaaxxxxxx"
export AD_NAME="your-availability-domain"
export DOCKER_USERNAME="your-docker-username"
export DOCKER_PASSWORD="your-docker-password"
```

2. **Deploy**:
```bash
source deploy.env
./deploy.sh
```

The script handles:
- Building the Spring Boot application image
- Pushing to Docker registry
- Creating/updating OCI Container Instance
- Configuring health checks and resource limits
- Optional load balancer backend registration

### Monitoring OCI Container Instance

```bash
# Get instance details
oci container-instances container-instance get \
  --container-instance-id <instance-ocid>

# List all container instances
oci container-instances container-instance list \
  --compartment-id $OCI_COMPARTMENT_OCID

# View container logs (requires OCI Logging configured)
oci logging-search search-logs \
  --search-query "search \"$OCI_COMPARTMENT_OCID\" | source='<instance-ocid>'"
```

## Kubernetes Deployment

Deploy with Horizontal Pod Autoscaler (HPA) configured for all three use cases:

```bash
# Apply the complete deployment with HPAs
kubectl apply -f k8s-autoscaling-deployment.yaml

# Check HPA status
kubectl get hpa

# Watch HPA in real-time
kubectl get hpa -w

# Check pods
kubectl get pods -l app=autoscaling-demo

# Get service endpoint
kubectl get svc autoscaling-demo
```

The deployment includes:
- **Deployment** with resource requests/limits
- **Service** (LoadBalancer type)
- **HPA for CPU** (triggers at >60% CPU)
- **HPA for Memory** (triggers at >60% memory)
- **Liveness/Readiness probes** for health check-based autoscaling

Complete manifest available in `k8s-autoscaling-deployment.yaml`

## Monitoring

### Prometheus Metrics
Access Prometheus-formatted metrics at:
```
http://localhost:8080/actuator/prometheus
```

### Key Metrics to Monitor
- `jvm_memory_used_bytes` - JVM memory usage
- `jvm_memory_max_bytes` - Maximum JVM memory
- `process_cpu_usage` - Process CPU usage
- `system_cpu_usage` - System CPU usage
- `http_server_requests_seconds` - HTTP request metrics

## Configuration

Edit `src/main/resources/application.properties` to customize:
- Server port
- Logging levels
- Actuator endpoints
- Metrics export configuration

## Troubleshooting

1. **Container won't start**:
   - Check logs: `docker logs autoscaling-demo`
   - Verify port 8080 is not in use: `lsof -i :8080`

2. **Out of memory errors**:
   - Increase container memory limit in `docker-compose.yml`
   - Adjust JVM heap size: `JAVA_OPTS=-Xmx1024m -Xms512m`

3. **Memory not clearing**:
   - Call `DELETE /api/memory` to clear allocated memory
   - Garbage collection is triggered automatically

## License

MIT License
