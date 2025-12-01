# OCI Container Instances Autoscaling Architecture

## Component Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                         OCI Tenancy                                │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │              OCI Monitoring & Alarms                          │ │
│  │                                                               │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐ │ │
│  │  │ CPU High Alarm │  │ CPU Low Alarm  │  │ Memory High    │ │ │
│  │  │ Threshold:70%  │  │ Threshold:30%  │  │ Alarm 70%      │ │ │
│  │  │ Period: 5min   │  │ Period: 5min   │  │ Period: 5min   │ │ │
│  │  └────────┬───────┘  └────────┬───────┘  └────────┬───────┘ │ │
│  │           │                    │                    │         │ │
│  │           └────────────┬───────┴────────────────────┘         │ │
│  │                        │                                      │ │
│  └────────────────────────┼──────────────────────────────────────┘ │
│                           │                                        │
│  ┌────────────────────────▼──────────────────────────────────────┐ │
│  │         OCI Notifications Service                             │ │
│  │  ┌──────────────────────────────────────────────────────────┐ │ │
│  │  │  Topic: ci-autoscaling-notifications                     │ │ │
│  │  │  Subscriptions:                                          │ │ │
│  │  │    - Scale-Up Function (on alarm FIRING)                 │ │ │
│  │  │    - Scale-Down Function (on alarm OK)                   │ │ │
│  │  │    - Email (optional)                                    │ │ │
│  │  └──────────────────────────────────────────────────────────┘ │ │
│  └────────────────┬──────────────────────┬──────────────────────┘ │
│                   │                      │                        │
│  ┌────────────────▼─────────┐  ┌────────▼─────────────────────┐  │
│  │   OCI Functions          │  │   OCI Functions              │  │
│  │   App: ci-autoscaling    │  │   App: ci-autoscaling        │  │
│  │                          │  │                              │  │
│  │  ┌─────────────────────┐ │  │  ┌─────────────────────────┐│  │
│  │  │  scale-up-function  │ │  │  │ scale-down-function     ││  │
│  │  │                     │ │  │  │                         ││  │
│  │  │  1. Check max limit │ │  │  │  1. Check min limit     ││  │
│  │  │  2. Create CI       │ │  │  │  2. Select oldest CI    ││  │
│  │  │  3. Wait ACTIVE     │ │  │  │  3. Remove from LB      ││  │
│  │  │  4. Get private IP  │ │  │  │  4. Delete CI           ││  │
│  │  │  5. Create backend  │ │  │  │                         ││  │
│  │  │  6. Add to LB       │ │  │  │                         ││  │
│  │  └─────────┬───────────┘ │  │  └─────────┬───────────────┘│  │
│  └────────────┼─────────────┘  └────────────┼────────────────┘  │
│               │                              │                   │
│  ┌────────────▼──────────────────────────────▼──────────────┐   │
│  │           Container Instances (CI)                        │   │
│  │                                                            │   │
│  │  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌─────┐   │   │
│  │  │ Instance-1│  │Instance-2 │  │Instance-3 │  │ ... │   │   │
│  │  │ ACTIVE    │  │ ACTIVE    │  │ ACTIVE    │  │     │   │   │
│  │  │ 10.0.10.10│  │10.0.10.11 │  │10.0.10.12 │  │     │   │   │
│  │  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘  └──┬──┘   │   │
│  │        │               │               │           │      │   │
│  └────────┼───────────────┼───────────────┼───────────┼──────┘   │
│           │               │               │           │          │
│  ┌────────▼───────────────▼───────────────▼───────────▼───────┐  │
│  │              Load Balancer (Public)                         │  │
│  │              IP: 165.1.66.58                                │  │
│  │                                                             │  │
│  │  Backend Set: autoscaling-demo-backend-set                 │  │
│  │    Policy: ROUND_ROBIN                                     │  │
│  │    Health Check: HTTP /actuator/health:8080                │  │
│  │                                                             │  │
│  │  Backends:                                                  │  │
│  │    - 10.0.10.10:8080 (weight: 1, healthy)                  │  │
│  │    - 10.0.10.11:8080 (weight: 1, healthy)                  │  │
│  │    - 10.0.10.12:8080 (weight: 1, healthy)                  │  │
│  └─────────────────────────┬───────────────────────────────────┘  │
│                            │                                      │
└────────────────────────────┼──────────────────────────────────────┘
                             │
                    ┌────────▼─────────┐
                    │  Internet Users  │
                    │                  │
                    │  http://LB-IP/   │
                    └──────────────────┘
```

## Scale-Up Flow

```
1. User Traffic → Container Instances → CPU/Memory Usage Increases
                                              │
2. OCI Monitoring detects: CPU > 70% for 5 minutes
                                              │
3. Alarm State: OK → FIRING
                                              │
4. Notification sent to Topic
                                              │
5. Scale-Up Function triggered
                                              │
6. Function executes:
   ├─ Check: current_count < MAX_INSTANCES? ✓
   ├─ Create new Container Instance
   ├─ Wait for ACTIVE state (30-60s)
   ├─ Get private IP address
   ├─ Check backend set exists (create if needed)
   └─ Add backend: 10.0.10.13:8080
                                              │
7. Load Balancer health check passes (30s)
                                              │
8. New backend receives traffic
   └─> Total instances: 3 → 4
```

## Scale-Down Flow

```
1. Load decreases → CPU/Memory Usage Decreases
                                              │
2. OCI Monitoring detects: CPU < 30% for 5 minutes
                                              │
3. Alarm State: FIRING → OK
                                              │
4. Notification sent to Topic
                                              │
5. Scale-Down Function triggered
                                              │
6. Function executes:
   ├─ Check: current_count > MIN_INSTANCES? ✓
   ├─ List all ACTIVE instances
   ├─ Select oldest instance (FIFO)
   ├─ Get private IP: 10.0.10.10
   ├─ Remove backend from LB
   └─ Delete Container Instance
                                              │
7. Backend removed from rotation
                                              │
8. Container Instance deleted
   └─> Total instances: 4 → 3
```

## Metric Collection

```
┌─────────────────────────────────────────────────────────────┐
│  Each Container Instance reports metrics every 1 minute:    │
│                                                             │
│  Namespace: oci_computecontainerinstance                   │
│                                                             │
│  Metrics:                                                   │
│  ├─ CpuUtilization (%)                                     │
│  ├─ MemoryUtilization (%)                                  │
│  ├─ NetworkBytesIn                                         │
│  └─ NetworkBytesOut                                        │
│                                                             │
│  Dimensions:                                                │
│  ├─ resourceId: ocid1.computecontainerinstance...         │
│  ├─ resourceDisplayName: autoscaling-demo-instance-123... │
│  └─ compartmentId: ocid1.compartment...                   │
└─────────────────────────────────────────────────────────────┘
```

## Alarm Evaluation Logic

```
Alarm Query Example (CPU High):
  CpuUtilization[5m]{resourceDisplayName =~ "autoscaling-demo-instance*"}.mean()

Evaluation:
  ┌─────────────────────────────────────────────┐
  │ Every 1 minute (ALARM_FREQUENCY):          │
  │                                             │
  │ 1. Collect metrics from all instances      │
  │    matching display name pattern           │
  │                                             │
  │ 2. Calculate mean over 5 minute window     │
  │    (ALARM_EVALUATION_PERIOD)               │
  │                                             │
  │ 3. Compare to threshold:                   │
  │    mean_cpu > 70%?                         │
  │                                             │
  │ 4. If true → State = FIRING                │
  │    If false → State = OK                   │
  │                                             │
  │ 5. On state change → Send notification     │
  └─────────────────────────────────────────────┘
```

## Concurrency Handling

```
Multiple alarms can trigger simultaneously:

Scenario: High CPU + High Memory at same time
├─ Both alarms fire
├─ Both send notifications
├─ Scale-up function receives 2 calls
│
├─ First call:
│  ├─ current_count = 1
│  ├─ Check: 1 < MAX_INSTANCES (5)? ✓
│  └─ Create instance → current_count = 2
│
└─ Second call (runs concurrently):
   ├─ current_count = 2 (may still be 1 during race)
   ├─ Check: 2 < MAX_INSTANCES (5)? ✓
   └─ Create instance → current_count = 3

Result: Both calls succeed, 2 instances created

Protection: MAX_INSTANCES limit enforced in function
```

## IAM Policy Requirements

```
Dynamic Group:
  ALL {resource.type = 'fnfunc', 
       resource.compartment.id = '<compartment-ocid>'}

Required Policies:
  Allow dynamic-group <dg-name> to manage container-instances
  Allow dynamic-group <dg-name> to manage load-balancers
  Allow dynamic-group <dg-name> to use virtual-network-family
  Allow dynamic-group <dg-name> to read metrics
```

## Configuration Hierarchy

```
autoscaling.env (source of truth)
        │
        ├─> setup-autoscaling.sh (deployment)
        │   ├─> Creates Functions App
        │   ├─> Deploys Functions
        │   ├─> Sets Function env vars
        │   ├─> Creates Notification Topic
        │   └─> Creates Alarms
        │
        └─> Functions (runtime)
            ├─> scale-up-function/func.py
            │   └─> Uses env vars from Function config
            │
            └─> scale-down-function/func.py
                └─> Uses env vars from Function config
```

---

This architecture provides:
- ✅ **Automatic scaling** based on actual load
- ✅ **No manual intervention** required
- ✅ **Cost optimization** (scale down when idle)
- ✅ **High availability** (multiple instances)
- ✅ **Load distribution** (via Load Balancer)
- ✅ **Observability** (metrics, alarms, notifications)
