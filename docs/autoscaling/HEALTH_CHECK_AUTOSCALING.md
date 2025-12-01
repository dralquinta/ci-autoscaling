# Health Check-Based Autoscaling

## Overview

The health check autoscaling feature monitors OCI Load Balancer backend health and automatically scales up when backends become unhealthy due to:
- HTTP status codes other than 200
- Response timeouts exceeding 5 seconds
- Health check probe failures

## How It Works

### 1. Health Check Monitoring

The OCI Load Balancer continuously monitors backend health:

```yaml
Health Check Configuration:
  Protocol: HTTP
  Port: 8080
  URL Path: /actuator/health
  Interval: 10 seconds
  Timeout: 5 seconds
  Retries: 3
  Success Codes: 200
```

### 2. Metric Collection

OCI Load Balancer publishes metrics to OCI Monitoring:

- **`UnHealthyBackendCount`**: Number of backends failing health checks
- **`TotalBackendCount`**: Total number of backends in the set
- **Namespace**: `oci_lbaas`

### 3. Alarm Evaluation

The alarm calculates unhealthy percentage and triggers when threshold is exceeded:

```
Formula: (UnHealthyBackendCount / TotalBackendCount) * 100

Threshold: 50% (configurable via HEALTH_FAILURE_THRESHOLD)
Evaluation Period: 5 minutes
Check Frequency: 1 minute
Severity: CRITICAL
```

### 4. Automatic Scale-Up

When alarm fires:
1. Notification sent to OCI Notification Topic
2. Scale-up function triggered
3. New healthy container instance created
4. Instance added to load balancer backend set
5. Traffic redistributed to healthy backends

## Configuration

### Environment Variables (`autoscaling.env`)

```bash
# Health check alarm threshold
export HEALTH_FAILURE_THRESHOLD="50"    # Percentage of backends unhealthy to trigger scale-up

# Alarm settings (shared with CPU/Memory alarms)
export ALARM_EVALUATION_PERIOD="5"      # Minutes
export ALARM_FREQUENCY="1"              # Minutes (check interval)
```

### Health Check Conditions Monitored

The alarm triggers when backends fail health checks due to:

1. **HTTP Non-200 Status Codes**:
   - 500 Internal Server Error
   - 503 Service Unavailable
   - 502 Bad Gateway
   - 504 Gateway Timeout

2. **Response Timeouts**:
   - Backend takes > 5 seconds to respond
   - Connection timeouts
   - Read timeouts

3. **Connection Failures**:
   - Backend unreachable
   - Connection refused
   - Network errors

## Testing the Feature

### 1. Trigger Health Check Failures

Simulate unhealthy backends using the built-in test endpoint:

```bash
# Get load balancer IP
LB_IP=$(oci lb load-balancer get \
  --load-balancer-id $LB_OCID \
  --query 'data."ip-addresses"[0]."ip-address"' \
  --raw-output)

# Fail health checks for 10 minutes
curl -X POST "http://${LB_IP}:8080/api/scenario/health/fail?durationSeconds=600"
```

### 2. Monitor Backend Health

Check backend health status:

```bash
# View backend health
oci lb backend-set get \
  --load-balancer-id $LB_OCID \
  --backend-set-name autoscaling-demo-backend-set \
  --query 'data.backends[*].{Name:name, Status:status, Health:"health-status"}' \
  --output table
```

Expected output:
```
+------------------------------------------+----------+-----------+
| Health                                   | Name     | Status    |
+------------------------------------------+----------+-----------+
| CRITICAL                                 | 10.0.0.5 | CRITICAL  |
| CRITICAL                                 | 10.0.0.6 | CRITICAL  |
+------------------------------------------+----------+-----------+
```

### 3. Watch Alarm Status

Monitor when the alarm fires:

```bash
# Get alarm OCID
ALARM_OCID=$(oci monitoring alarm list \
  --compartment-id $COMPARTMENT_OCID \
  --display-name "ci-autoscaling-health-critical" \
  --query 'data[0].id' \
  --raw-output)

# Check alarm status
oci monitoring alarm-status get --alarm-id $ALARM_OCID
```

Alarm states:
- `OK`: All backends healthy (< 50% unhealthy)
- `FIRING`: Threshold exceeded (≥ 50% unhealthy)

### 4. Monitor Scale-Up Function

View scale-up function execution logs:

```bash
# View recent logs
fn logs get app ci-autoscaling-app fn scale-up

# Follow logs in real-time
fn logs get app ci-autoscaling-app fn scale-up --follow
```

Expected log output:
```json
{
  "message": "Scale-up triggered by alarm: ci-autoscaling-health-critical",
  "current_instances": 2,
  "max_instances": 5,
  "action": "Creating new instance",
  "instance_name": "autoscaling-demo-instance-20251201-180500",
  "timestamp": "2025-12-01T18:05:00Z"
}
```

### 5. Verify New Instance

Check that new instance was created and added to backend set:

```bash
# List active instances
oci container-instances container-instance list \
  --compartment-id $COMPARTMENT_OCID \
  --lifecycle-state ACTIVE \
  --query 'data.items[?starts_with("display-name", `autoscaling-demo-instance`)].{Name:"display-name", State:"lifecycle-state", Created:"time-created"}' \
  --output table

# Verify backend set has new backend
oci lb backend-set get \
  --load-balancer-id $LB_OCID \
  --backend-set-name autoscaling-demo-backend-set \
  --query 'data.backends | length(@)' \
  --raw-output
```

### 6. Recover Health Checks

Stop the failure scenario:

```bash
curl -X POST "http://${LB_IP}:8080/api/scenario/health/recover"
```

## Timeline

Understanding the complete autoscaling cycle:

```
T+0:00  - Health checks start failing
T+0:10  - First health check failure detected by LB
T+0:30  - Backend marked as CRITICAL after 3 retries
T+5:00  - Alarm evaluation period completes (5 minutes)
T+5:01  - Alarm fires, notification sent
T+5:02  - Scale-up function triggered
T+5:03  - New container instance creation started
T+7:00  - Container instance becomes ACTIVE
T+7:30  - Instance added to backend set
T+8:00  - Health checks pass on new instance
T+8:10  - Traffic begins routing to new healthy instance

Total: ~8 minutes from failure to new healthy instance
```

## Tuning Recommendations

### For Faster Response

Reduce evaluation period (faster but may cause false positives):

```bash
export ALARM_EVALUATION_PERIOD="3"      # 3 minutes instead of 5
export ALARM_FREQUENCY="1"              # Check every minute
```

### For More Aggressive Scaling

Lower the failure threshold:

```bash
export HEALTH_FAILURE_THRESHOLD="30"    # Scale up when 30% unhealthy
```

### For Conservative Scaling

Raise the failure threshold:

```bash
export HEALTH_FAILURE_THRESHOLD="70"    # Scale up only when 70% unhealthy
```

## Metrics and Monitoring

### Key Metrics to Watch

1. **UnHealthyBackendCount**: Number of failing backends
2. **TotalBackendCount**: Total backends in set
3. **Backend Health Status**: Per-backend health state
4. **Container Instance State**: Lifecycle state of instances
5. **Function Invocations**: Scale-up function execution count

### OCI Console Monitoring

View metrics in OCI Console:

1. Navigate to **Observability & Management** > **Monitoring** > **Metrics Explorer**
2. Select namespace: `oci_lbaas`
3. Select metric: `UnHealthyBackendCount`
4. Filter by:
   - `loadBalancerId = <your-lb-ocid>`
   - `backendSetName = autoscaling-demo-backend-set`

## Troubleshooting

### Alarm Not Firing

**Problem**: Backends are unhealthy but alarm doesn't fire

**Solutions**:
1. Verify alarm exists and is enabled:
   ```bash
   oci monitoring alarm list --compartment-id $COMPARTMENT_OCID --output table
   ```

2. Check alarm query syntax:
   ```bash
   oci monitoring alarm get --alarm-id $ALARM_OCID --query 'data.query'
   ```

3. Verify metric data is being published:
   ```bash
   oci monitoring metric-data summarize-metrics-data \
     --compartment-id $COMPARTMENT_OCID \
     --namespace oci_lbaas \
     --query-text "UnHealthyBackendCount[1m]{loadBalancerId=\"$LB_OCID\"}.mean()"
   ```

### Function Fails to Create Instance

**Problem**: Scale-up function executes but instance creation fails

**Solutions**:
1. Check function logs for errors:
   ```bash
   fn logs get app ci-autoscaling-app fn scale-up | grep ERROR
   ```

2. Verify IAM policies for dynamic group:
   ```bash
   # Dynamic group must have:
   # - manage container-instances
   # - manage load-balancers
   # - use virtual-network-family
   ```

3. Check resource limits:
   ```bash
   # Verify compartment has available capacity
   oci limits resource-availability get \
     --compartment-id $COMPARTMENT_OCID \
     --service-name container-instances \
     --limit-name standard-e4-flex-core-count
   ```

### Backends Remain Unhealthy

**Problem**: New instances are created but still fail health checks

**Solutions**:
1. Check application logs:
   ```bash
   # Get instance OCID
   INSTANCE_OCID=$(oci container-instances container-instance list \
     --compartment-id $COMPARTMENT_OCID \
     --display-name "autoscaling-demo-instance-*" \
     --query 'data.items[0].id' --raw-output)
   
   # View logs
   oci logging-search search-logs \
     --search-query "search \"$COMPARTMENT_OCID\" | source='$INSTANCE_OCID'"
   ```

2. Verify health endpoint responds correctly:
   ```bash
   # Test health endpoint directly
   curl -i http://<instance-private-ip>:8080/actuator/health
   ```

3. Check network connectivity:
   ```bash
   # Verify security list allows health check traffic
   # Port 8080 must be open from LB subnet
   ```

## Best Practices

1. **Set Appropriate Threshold**: 50% is a good starting point, adjust based on your traffic patterns

2. **Monitor Both Metrics**: Watch both `UnHealthyBackendCount` and alarm status

3. **Test Regularly**: Use `/api/scenario/health/fail` endpoint to verify autoscaling works

4. **Configure Alerts**: Add email to `NOTIFICATION_EMAIL` in `autoscaling.env`

5. **Document Incidents**: Keep track of when health-based scaling occurs to tune thresholds

6. **Combine with Other Metrics**: Health check autoscaling works best alongside CPU and Memory-based scaling

## Integration with Application

Your Spring Boot application provides built-in endpoints for testing:

```java
// Fail health checks
POST /api/scenario/health/fail?durationSeconds=600

// Recover health checks  
POST /api/scenario/health/recover

// Check current status
GET /api/scenario/health/status
```

These endpoints simulate real-world failure scenarios without actually crashing the application.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     OCI Load Balancer                        │
│  - HTTP Health Checks every 10s                             │
│  - Timeout: 5 seconds                                       │
│  - Publishes UnHealthyBackendCount metric                   │
└───────────┬─────────────────────────────────────────────────┘
            │
            │ Metrics
            ▼
┌─────────────────────────────────────────────────────────────┐
│                    OCI Monitoring                            │
│  - Alarm: UnHealthyBackendCount / TotalBackendCount > 50%  │
│  - Evaluation: 5 minutes                                    │
└───────────┬─────────────────────────────────────────────────┘
            │
            │ Notification
            ▼
┌─────────────────────────────────────────────────────────────┐
│              OCI Notification Service                        │
│  - Topic: ci-autoscaling-notifications                      │
└───────────┬─────────────────────────────────────────────────┘
            │
            │ Trigger
            ▼
┌─────────────────────────────────────────────────────────────┐
│                 Scale-Up Function                            │
│  1. Check current instance count                           │
│  2. Create new Container Instance                          │
│  3. Wait for ACTIVE state                                  │
│  4. Add to Load Balancer backend set                       │
│  5. Traffic routes to healthy instance                     │
└─────────────────────────────────────────────────────────────┘
```

## Related Documentation

- [AUTOSCALING_USE_CASES.md](../docs/autoscaling/AUTOSCALING_USE_CASES.md) - Use Case 4 details
- [AUTOSCALING_QUICKSTART.md](../docs/autoscaling/AUTOSCALING_QUICKSTART.md) - Quick start guide
- [ARCHITECTURE.md](../docs/autoscaling/ARCHITECTURE.md) - Complete architecture
- [README.md](../docs/autoscaling/README.md) - Full documentation
