# OCI Container Instances Autoscaling - Quick Start

## 🚀 Quick Start (5 minutes)

### 1. Install Prerequisites

```bash
# Install Fn CLI
curl -LSs https://raw.githubusercontent.com/fnproject/cli/master/install | sh

# Verify installations
oci --version
fn --version
docker --version
```

### 2. Configure Fn CLI with OCI

```bash
# Create Fn context for OCI
fn create context oci-context --provider oracle

# Use the context
fn use context oci-context

# Configure for your tenancy
fn update context oracle.compartment-id <your-compartment-ocid>
fn update context api-url https://functions.<your-region>.oraclecloud.com
fn update context registry <region>.ocir.io/<namespace>/<repo-prefix>
```

### 3. Setup Docker for OCIR

```bash
# Login to OCIR
docker login <region>.ocir.io
# Username: <namespace>/<username>
# Password: <auth-token>
```

### 4. Create Load Balancer (if not exists)

```bash
cd /home/opc/DevOps/DEMO_SONDA/ci-autoscaling
source deploy.env
./loadbalancer.sh --create
```

### 5. Configure Autoscaling

```bash
cd autoscaling

# Edit configuration
vi autoscaling.env

# Update these required values:
# - COMPARTMENT_OCID
# - LB_OCID (from loadbalancer.sh output)
# - MIN_INSTANCES (default: 1)
# - MAX_INSTANCES (default: 5)

# Source configuration
source autoscaling.env
```

### 6. Deploy Autoscaling

```bash
# Deploy all components
./setup-autoscaling.sh --deploy
```

Expected output:
```
[2025-12-01 18:00:00] ====== Deploying Autoscaling Infrastructure ======
[2025-12-01 18:00:01] Checking prerequisites...
[2025-12-01 18:00:01] Prerequisites check passed
[2025-12-01 18:00:02] Creating Functions Application: ci-autoscaling-app
[2025-12-01 18:00:05] Functions Application created: ocid1.fnapp...
[2025-12-01 18:00:06] Deploying scale-up function...
...
[2025-12-01 18:05:00] ====== Autoscaling Infrastructure Deployed ======
```

### 7. Verify Setup

```bash
./setup-autoscaling.sh --status
```

### 8. Test Autoscaling

```bash
# Get load balancer IP
LB_IP=$(oci lb load-balancer get --load-balancer-id $LB_OCID --query 'data."ip-addresses"[0]."ip-address"' --raw-output)

# Test CPU-based autoscaling (80% for 10 minutes)
curl -X POST "http://${LB_IP}/api/scenario/cpu/start?targetCpuPercent=80&durationSeconds=600"

# Test Memory-based autoscaling (75% for 10 minutes)
curl -X POST "http://${LB_IP}/api/scenario/memory/start?targetMemoryPercent=75&durationSeconds=600"

# Test Health Check-based autoscaling (fail health checks for 10 minutes)
curl -X POST "http://${LB_IP}/api/scenario/health/fail?durationSeconds=600"

# Watch instances scale up (takes 5-10 minutes)
watch './setup-autoscaling.sh --status'

# After scenarios complete, scale-down begins automatically
```

## 📋 Verification Checklist

- [ ] Fn CLI installed and configured
- [ ] Docker logged into OCIR
- [ ] Load balancer created
- [ ] autoscaling.env configured
- [ ] Functions deployed successfully
- [ ] Alarms created and enabled
- [ ] Notification topic created
- [ ] IAM policies configured (see README.md)

## 🔍 Troubleshooting

### Functions deployment fails

```bash
# Check Fn context
fn list contexts

# Verify registry access
docker pull <region>.ocir.io/<namespace>/test

# Check compartment access
oci fn application list --compartment-id $COMPARTMENT_OCID
```

### Alarms not triggering

```bash
# Verify alarms exist
oci monitoring alarm list --compartment-id $COMPARTMENT_OCID --output table

# Check alarm status
oci monitoring alarm-status list --compartment-id $COMPARTMENT_OCID

# View notification subscriptions
oci ons subscription list --compartment-id $COMPARTMENT_OCID --topic-id $NOTIFICATION_TOPIC_OCID
```

### Scale operations failing

```bash
# Check function logs
fn logs get app ci-autoscaling-app fn scale-up
fn logs get app ci-autoscaling-app fn scale-down

# Verify IAM policies (must have dynamic group for functions)
oci iam dynamic-group list --compartment-id $COMPARTMENT_OCID
```

## 📚 Next Steps

1. **Monitor**: Watch metrics in OCI Console > Monitoring
2. **Tune**: Adjust thresholds in `autoscaling.env`
3. **Alert**: Add email to `NOTIFICATION_EMAIL` for notifications
4. **Scale**: Increase `MAX_INSTANCES` for higher load

## 🗑️ Cleanup

```bash
# Remove autoscaling infrastructure
./setup-autoscaling.sh --destroy

# Remove load balancer (if desired)
cd ..
./loadbalancer.sh --destroy

# Remove container instances
oci container-instances container-instance list \
  --compartment-id $COMPARTMENT_OCID \
  --lifecycle-state ACTIVE \
  --query 'data.items[?starts_with("display-name", "autoscaling-demo-instance")].id' \
  | jq -r '.[]' \
  | xargs -I {} oci container-instances container-instance delete --container-instance-id {} --force
```

---

For detailed documentation, see [README.md](README.md)
