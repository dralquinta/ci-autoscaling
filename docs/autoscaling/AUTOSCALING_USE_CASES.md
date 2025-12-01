# Autoscaling Use Cases

This document describes four autoscaling scenarios designed to test different autoscaling triggers.

## Use Case 1: CPU-Based Autoscaling (>60% CPU Utilization)

### Scenario Description
This scenario generates sustained CPU load across all available cores to trigger CPU-based autoscaling when utilization exceeds 60%.

### API Endpoints

#### Start CPU Load Scenario
```bash
POST /api/scenario/cpu/start?targetCpuPercent=70&durationSeconds=300
```

**Parameters:**
- `targetCpuPercent` (default: 60) - Target CPU utilization percentage
- `durationSeconds` (default: 300) - How long to maintain the load

**Example:**
```bash
curl -X POST "http://localhost:8080/api/scenario/cpu/start?targetCpuPercent=70&durationSeconds=600"
```

#### Stop CPU Load Scenario
```bash
POST /api/scenario/cpu/stop
```

**Example:**
```bash
curl -X POST "http://localhost:8080/api/scenario/cpu/stop"
```

### Testing Steps

1. **Deploy the application with resource limits:**
```bash
docker run -d --name autoscaling-demo \
  --cpus="1.0" \
  -p 8080:8080 \
  autoscaling-demo:latest
```

2. **Start CPU load scenario:**
```bash
curl -X POST "http://localhost:8080/api/scenario/cpu/start?targetCpuPercent=75&durationSeconds=300"
```

3. **Monitor CPU usage:**
```bash
# In another terminal
docker stats autoscaling-demo
```

4. **Expected behavior:**
   - CPU usage should climb to ~70-75%
   - In Kubernetes, HPA should trigger scale-out when CPU exceeds threshold
   - Additional pods should be created
   - Load should distribute across pods

5. **Stop the scenario:**
```bash
curl -X POST "http://localhost:8080/api/scenario/cpu/stop"
```

---

## Use Case 2: Memory-Based Autoscaling (>60% Memory Utilization)

### Scenario Description
This scenario gradually allocates memory until reaching target percentage (e.g., 70%) to trigger memory-based autoscaling.

### API Endpoints

#### Start Memory Load Scenario
```bash
POST /api/scenario/memory/start?targetMemoryPercent=70&durationSeconds=300
```

**Parameters:**
- `targetMemoryPercent` (default: 70) - Target memory utilization percentage
- `durationSeconds` (default: 300) - How long to maintain the load

**Example:**
```bash
curl -X POST "http://localhost:8080/api/scenario/memory/start?targetMemoryPercent=75&durationSeconds=600"
```

#### Stop Memory Load Scenario
```bash
POST /api/scenario/memory/stop
```

**Example:**
```bash
curl -X POST "http://localhost:8080/api/scenario/memory/stop"
```

### Testing Steps

1. **Deploy with memory limits:**
```bash
docker run -d --name autoscaling-demo \
  --memory="512m" \
  -e JAVA_OPTS="-Xmx400m -Xms256m" \
  -p 8080:8080 \
  autoscaling-demo:latest
```

2. **Start memory load scenario:**
```bash
curl -X POST "http://localhost:8080/api/scenario/memory/start?targetMemoryPercent=75&durationSeconds=300"
```

3. **Monitor memory usage:**
```bash
# Watch container stats
docker stats autoscaling-demo

# Check application memory
curl http://localhost:8080/api/scenario/status
```

4. **Expected behavior:**
   - Memory usage should climb to ~70-75%
   - In Kubernetes, HPA should trigger scale-out when memory exceeds threshold
   - New pods should be provisioned
   - Memory pressure should be distributed

5. **Stop and clear memory:**
```bash
curl -X POST "http://localhost:8080/api/scenario/memory/stop"
```

---

## Use Case 3: Health Check Failure-Based Autoscaling

### Scenario Description
This scenario simulates unhealthy pods by:
- Returning HTTP 503 (Service Unavailable) status
- Returning HTTP 500 (Internal Server Error) status
- Simulating timeouts (>10 seconds response time)

### API Endpoints

#### Fail Health Checks
```bash
POST /api/scenario/health/fail?durationSeconds=300
```

**Parameters:**
- `durationSeconds` (default: 300) - How long health checks should fail

**Example:**
```bash
curl -X POST "http://localhost:8080/api/scenario/health/fail?durationSeconds=600"
```

#### Recover Health Checks
```bash
POST /api/scenario/health/recover
```

**Example:**
```bash
curl -X POST "http://localhost:8080/api/scenario/health/recover"
```

#### Check Health Status
```bash
GET /api/scenario/health/status
```

**Example:**
```bash
curl http://localhost:8080/api/scenario/health/status
```

### Testing Steps

1. **Deploy application:**
```bash
docker-compose up -d
```

2. **Verify healthy state:**
```bash
curl http://localhost:8080/api/scenario/health/status
# Should return: {"status":"UP","timestamp":...}
```

3. **Trigger health check failures:**
```bash
curl -X POST "http://localhost:8080/api/scenario/health/fail?durationSeconds=300"
```

4. **Verify failing health checks:**
```bash
curl -i http://localhost:8080/api/scenario/health/status
# Should return HTTP 503 or 500
```

5. **Expected behavior:**
   - Health endpoint returns non-200 status codes
   - In Kubernetes, pod marked as unhealthy
   - Kubernetes stops sending traffic to unhealthy pod
   - New pods may be created to replace unhealthy ones
   - Failed pods may be restarted

6. **Recover health checks:**
```bash
curl -X POST "http://localhost:8080/api/scenario/health/recover"
```

---

## Use Case 4: Load Balancer Health Check Failure-Based Autoscaling

### Scenario Description
This scenario monitors the OCI Load Balancer backend health and triggers autoscaling when:
- Backends return HTTP status codes other than 200
- Backend response times exceed 5 seconds (timeout)
- Health check probe failures occur

### How It Works

1. **OCI Load Balancer monitors backend health:**
   - Sends periodic health checks to each backend
   - Tracks `UnHealthyBackendCount` metric
   - Monitors response codes and timeouts

2. **Alarm triggers when unhealthy percentage exceeds threshold:**
   - Formula: `(UnHealthyBackendCount / TotalBackendCount) * 100 > 50%`
   - Evaluates over 5-minute period
   - Fires when ≥50% of backends are unhealthy

3. **Scale-up function creates new healthy instance:**
   - New container instance provisioned
   - Added to load balancer backend set
   - Distributes traffic away from unhealthy backends

### Testing Steps

1. **Trigger health check failures on existing instances:**
```bash
# Get the LB public IP
LB_IP=$(oci lb load-balancer get --load-balancer-id $LB_OCID --query 'data."ip-addresses"[0]."ip-address"' --raw-output)

# Fail health checks on all running instances
curl -X POST "http://${LB_IP}:8080/api/scenario/health/fail?durationSeconds=600"
```

2. **Monitor backend health:**
```bash
# Check backend set status
oci lb backend-set get \
  --load-balancer-id $LB_OCID \
  --backend-set-name autoscaling-demo-backend-set \
  --query 'data.backends[*].{Name:name, Status:status, Health:"health-status"}'
```

3. **Expected behavior:**
   - Backends marked as `CRITICAL` or `WARNING`
   - `UnHealthyBackendCount` metric increases
   - After 5 minutes, alarm fires
   - Scale-up function creates new healthy instance
   - New instance added to backend set
   - Traffic shifts to healthy backends

4. **Monitor alarm state:**
```bash
oci monitoring alarm-status get \
  --alarm-id $(oci monitoring alarm list \
    --compartment-id $COMPARTMENT_OCID \
    --display-name "ci-autoscaling-health-critical" \
    --query 'data[0].id' --raw-output)
```

5. **Check scale-up function logs:**
```bash
fn logs get app ci-autoscaling-app fn scale-up
```

6. **Recover health checks:**
```bash
curl -X POST "http://${LB_IP}:8080/api/scenario/health/recover"
```

### Configuration

The health check alarm is configured in `autoscaling.env`:

```bash
export HEALTH_FAILURE_THRESHOLD="50"    # Percentage of backends unhealthy to trigger scale-up
```

### Metrics Monitored

The alarm uses OCI Load Balancer metrics:
- **Namespace:** `oci_lbaas`
- **Metrics:**
  - `UnHealthyBackendCount` - Number of backends failing health checks
  - `TotalBackendCount` - Total number of backends in set
- **Evaluation:** `(UnHealthyBackendCount / TotalBackendCount) * 100`

### Health Check Configuration

The backend set health checker is configured in `deploy.sh`:
- **Protocol:** HTTP
- **Port:** 8080
- **URL Path:** `/actuator/health`
- **Interval:** 10 seconds
- **Timeout:** 5 seconds (responses > 5s considered failed)
- **Retries:** 3
- **Success Codes:** 200

---

## OCI Container Instances Deployment with All Four Autoscaling Scenarios

### Complete Deployment Manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoscaling-demo
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: autoscaling-demo
  template:
    metadata:
      labels:
        app: autoscaling-demo
    spec:
      containers:
      - name: autoscaling-demo
        image: autoscaling-demo:latest
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: JAVA_OPTS
          value: "-Xmx400m -Xms256m"
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        # Liveness probe - restarts pod if failing
        livenessProbe:
          httpGet:
            path: /api/scenario/health/status
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        # Readiness probe - removes from service if failing
        readinessProbe:
          httpGet:
            path: /api/scenario/health/status
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 2
---
apiVersion: v1
kind: Service
metadata:
  name: autoscaling-demo
  namespace: default
spec:
  selector:
    app: autoscaling-demo
  ports:
  - port: 8080
    targetPort: 8080
    protocol: TCP
    name: http
  type: LoadBalancer
---
# HPA for CPU-based autoscaling
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: autoscaling-demo-cpu
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: autoscaling-demo
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60  # Scale when CPU > 60%
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # Wait 5 min before scaling down
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0  # Scale up immediately
      policies:
      - type: Percent
        value: 100
        periodSeconds: 30
      - type: Pods
        value: 2
        periodSeconds: 30
      selectPolicy: Max
---
# HPA for Memory-based autoscaling
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: autoscaling-demo-memory
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: autoscaling-demo
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 60  # Scale when Memory > 60%
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 30
      - type: Pods
        value: 2
        periodSeconds: 30
      selectPolicy: Max
```

### Apply the Deployment

```bash
# Apply the deployment
kubectl apply -f k8s-autoscaling-deployment.yaml

# Check HPA status
kubectl get hpa

# Watch HPA in real-time
kubectl get hpa -w

# Check pod status
kubectl get pods -l app=autoscaling-demo

# Get service endpoint
kubectl get svc autoscaling-demo
```

---

## Combined Test Script

Create a file `test-autoscaling.sh`:

```bash
#!/bin/bash

# Configuration
APP_URL="http://localhost:8080"
if [ ! -z "$1" ]; then
    APP_URL="$1"
fi

echo "Testing Autoscaling Scenarios"
echo "Application URL: $APP_URL"
echo "================================"

# Test 1: CPU-based autoscaling
echo ""
echo "TEST 1: CPU-Based Autoscaling"
echo "Starting CPU load at 75% for 5 minutes..."
curl -X POST "$APP_URL/api/scenario/cpu/start?targetCpuPercent=75&durationSeconds=300"
echo ""
echo "Waiting 2 minutes to observe scaling..."
sleep 120

echo "Checking scenario status..."
curl "$APP_URL/api/scenario/status"
echo ""

echo "Stopping CPU load..."
curl -X POST "$APP_URL/api/scenario/cpu/stop"
echo ""
echo "Waiting 1 minute for scale-down..."
sleep 60

# Test 2: Memory-based autoscaling
echo ""
echo "TEST 2: Memory-Based Autoscaling"
echo "Starting memory load at 75% for 5 minutes..."
curl -X POST "$APP_URL/api/scenario/memory/start?targetMemoryPercent=75&durationSeconds=300"
echo ""
echo "Waiting 2 minutes to observe scaling..."
sleep 120

echo "Checking scenario status..."
curl "$APP_URL/api/scenario/status"
echo ""

echo "Stopping memory load..."
curl -X POST "$APP_URL/api/scenario/memory/stop"
echo ""
echo "Waiting 1 minute for scale-down..."
sleep 60

# Test 3: Health check failure
echo ""
echo "TEST 3: Health Check Failure"
echo "Triggering health check failures for 5 minutes..."
curl -X POST "$APP_URL/api/scenario/health/fail?durationSeconds=300"
echo ""
echo "Waiting 1 minute..."
sleep 60

echo "Checking health status (should fail)..."
curl -i "$APP_URL/api/scenario/health/status"
echo ""

echo "Waiting another minute to observe pod restarts..."
sleep 60

echo "Recovering health checks..."
curl -X POST "$APP_URL/api/scenario/health/recover"
echo ""

echo "Verifying health recovered..."
curl "$APP_URL/api/scenario/health/status"
echo ""

echo ""
echo "================================"
echo "All tests completed!"
echo "Check your orchestrator (Kubernetes/OCI) for scaling events"
```

Make it executable:
```bash
chmod +x test-autoscaling.sh
```

Run the tests:
```bash
# For local Docker
./test-autoscaling.sh http://localhost:8080

# For Kubernetes service
./test-autoscaling.sh http://<load-balancer-ip>:8080
```

---

## Monitoring Autoscaling Events

### Kubernetes
```bash
# Watch HPA events
kubectl get hpa -w

# Describe HPA for detailed metrics
kubectl describe hpa autoscaling-demo-cpu
kubectl describe hpa autoscaling-demo-memory

# Watch pod scaling
kubectl get pods -l app=autoscaling-demo -w

# Check events
kubectl get events --sort-by='.lastTimestamp' | grep autoscaling-demo

# View pod resource usage
kubectl top pods -l app=autoscaling-demo
```

### Docker Stats
```bash
# Monitor single container
docker stats autoscaling-demo

# Monitor all containers
docker stats
```

### Application Metrics
```bash
# Check Prometheus metrics
curl http://localhost:8080/actuator/prometheus | grep -E '(cpu|memory|jvm)'

# Check scenario status
curl http://localhost:8080/api/scenario/status

# Check application info
curl http://localhost:8080/api/info
```

---

## Expected Results

### Use Case 1: CPU Autoscaling
- **Trigger:** CPU utilization > 60%
- **Expected:** HPA scales from 2 to N pods (max 10)
- **Time to scale:** 30-60 seconds
- **Scale down:** After 5 minutes of low CPU

### Use Case 2: Memory Autoscaling
- **Trigger:** Memory utilization > 60%
- **Expected:** HPA scales from 2 to N pods (max 10)
- **Time to scale:** 30-60 seconds
- **Scale down:** After 5 minutes of low memory

### Use Case 3: Health Check Failure
- **Trigger:** HTTP non-200 response or timeout
- **Expected:** 
  - Pod marked unhealthy
  - Traffic stops routing to pod
  - Pod may be restarted by kubelet
  - New pods may be created
- **Recovery:** After health checks pass again

---

## Troubleshooting

### HPA not scaling
```bash
# Check metrics-server is running
kubectl get deployment metrics-server -n kube-system

# Check if metrics are available
kubectl top pods

# Verify HPA can read metrics
kubectl describe hpa autoscaling-demo-cpu
```

### Pods not receiving traffic when unhealthy
```bash
# Check service endpoints
kubectl get endpoints autoscaling-demo

# Check pod readiness
kubectl get pods -l app=autoscaling-demo -o wide
```

### Container OOM (Out of Memory)
```bash
# Increase memory limits in deployment
# Or reduce target memory percentage in scenario
curl -X POST "http://localhost:8080/api/scenario/memory/start?targetMemoryPercent=50&durationSeconds=300"
```
