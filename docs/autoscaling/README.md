# OCI Container Instances Autoscaling

Automated scaling solution for OCI Container Instances using Functions, Alarms, Events, and Notifications.

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Components](#components)
- [Setup](#setup)
- [Configuration](#configuration)
- [Usage](#usage)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)

## 🎯 Overview

This autoscaling solution automatically scales OCI Container Instances up or down based on CPU and Memory metrics. It uses:

- **OCI Functions**: Serverless functions that create/destroy container instances
- **OCI Alarms**: Monitor metrics and trigger scaling actions
- **OCI Notifications**: Route alarm events to functions
- **OCI Load Balancer**: Distribute traffic across container instances

### Key Features

✅ **Automatic scaling** based on CPU and Memory thresholds  
✅ **No Terraform or Resource Manager** required  
✅ **Configurable min/max instances**  
✅ **Automatic backend set management**  
✅ **Email notifications** (optional)  
✅ **Reuses deploy.sh logic** for backend operations  

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     OCI Monitoring                          │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐           │
│  │ CPU High   │  │ CPU Low    │  │ Memory High│           │
│  │  Alarm     │  │  Alarm     │  │  Alarm     │  ...      │
│  └──────┬─────┘  └──────┬─────┘  └──────┬─────┘           │
└─────────┼────────────────┼────────────────┼────────────────┘
          │                │                │
          └────────┬───────┴────────────────┘
                   │
           ┌───────▼────────┐
           │  Notification  │
           │     Topic      │
           └───────┬────────┘
                   │
       ┌───────────┴───────────┐
       │                       │
┌──────▼───────┐        ┌──────▼────────┐
│  Scale-Up    │        │  Scale-Down   │
│  Function    │        │  Function     │
└──────┬───────┘        └──────┬────────┘
       │                       │
       └───────────┬───────────┘
                   │
       ┌───────────▼────────────┐
       │  Container Instances   │
       │  ┌──┐ ┌──┐ ┌──┐ ┌──┐  │
       │  │CI│ │CI│ │CI│ │CI│  │
       │  └──┘ └──┘ └──┘ └──┘  │
       └───────────┬────────────┘
                   │
          ┌────────▼─────────┐
          │  Load Balancer   │
          │  (Backend Set)   │
          └──────────────────┘
```

### Workflow

1. **Monitoring**: OCI Alarms continuously monitor CPU/Memory metrics of all container instances
2. **Trigger**: When threshold is exceeded, alarm fires and sends notification
3. **Scale Up**: Notification triggers scale-up function which:
   - Creates new container instance
   - Waits for it to become ACTIVE
   - Creates backend set if needed
   - Adds instance to load balancer
4. **Scale Down**: When metrics return to normal, alarm clears and triggers scale-down function which:
   - Selects oldest instance (FIFO)
   - Removes from load balancer
   - Deletes container instance

## ⚙️ Prerequisites

### Required Tools

- **OCI CLI**: Configured with proper credentials
  ```bash
  oci setup config
  ```

- **Fn CLI**: For deploying functions
  ```bash
  curl -LSs https://raw.githubusercontent.com/fnproject/cli/master/install | sh
  ```

- **Docker**: For building function images
  ```bash
  # Verify Docker is installed and running
  docker version
  ```

### OCI Services Setup

1. **Functions Service**: Enable Functions in your tenancy
   - Navigate to Developer Services > Functions in OCI Console
   - Ensure service is enabled in your region

2. **Container Registry**: Configure Docker to push to OCIR
   ```bash
   # Login to OCIR
   docker login <region>.ocir.io
   ```

3. **Load Balancer**: Must be created before autoscaling
   ```bash
   cd ..
   source deploy.env
   ./loadbalancer.sh --create
   ```

### IAM Policies

Functions need permissions to manage container instances and load balancers. Create a dynamic group and policy:

#### Dynamic Group
Create dynamic group for all functions in your compartment:
```
ALL {resource.type = 'fnfunc', resource.compartment.id = 'ocid1.compartment.oc1...'}
```

#### IAM Policy
```
Allow dynamic-group <your-dynamic-group> to manage container-instances in compartment <your-compartment>
Allow dynamic-group <your-dynamic-group> to manage load-balancers in compartment <your-compartment>
Allow dynamic-group <your-dynamic-group> to use virtual-network-family in compartment <your-compartment>
Allow dynamic-group <your-dynamic-group> to read metrics in compartment <your-compartment>
```

## 📦 Components

### Scale-Up Function (`scale-up-function/`)

- **Language**: Python 3.11
- **Trigger**: CPU/Memory high alarms
- **Actions**:
  - Check current instance count vs MAX_INSTANCES
  - Create new container instance
  - Wait for ACTIVE state
  - Create backend set (if needed)
  - Add instance to load balancer

### Scale-Down Function (`scale-down-function/`)

- **Language**: Python 3.11
- **Trigger**: CPU/Memory low alarms
- **Actions**:
  - Check current instance count vs MIN_INSTANCES
  - Select oldest instance for removal
  - Remove from load balancer backend set
  - Delete container instance

### Configuration (`autoscaling.env`)

Environment variables for autoscaling:
- Instance limits (MIN/MAX)
- Scaling thresholds
- Container configuration
- Load balancer settings

### Deployment Script (`setup-autoscaling.sh`)

Bash script to:
- Create Functions application
- Deploy both functions
- Configure environment variables
- Create notification topic
- Create alarms for CPU and Memory
- Link everything together

## 🚀 Setup

### 1. Configure Environment

Edit `autoscaling.env` with your settings:

```bash
cd autoscaling
vi autoscaling.env
```

Key settings to update:
- `COMPARTMENT_OCID`: Your compartment OCID
- `LB_OCID`: Your load balancer OCID (from loadbalancer.sh)
- `MIN_INSTANCES`: Minimum number of instances (default: 1)
- `MAX_INSTANCES`: Maximum number of instances (default: 5)
- `CPU_SCALE_UP_THRESHOLD`: CPU percentage to trigger scale-up (default: 70)
- `CPU_SCALE_DOWN_THRESHOLD`: CPU percentage to trigger scale-down (default: 30)

### 2. Source Configuration

```bash
source autoscaling.env
```

### 3. Deploy Autoscaling Infrastructure

```bash
./setup-autoscaling.sh --deploy
```

This will:
- ✅ Create Functions application
- ✅ Build and deploy scale-up function
- ✅ Build and deploy scale-down function
- ✅ Configure function environment variables
- ✅ Create notification topic
- ✅ Create 4 alarms (CPU high/low, Memory high/low)
- ✅ Link alarms to functions

### 4. Verify Deployment

```bash
./setup-autoscaling.sh --status
```

## 🎛️ Configuration

### Scaling Thresholds

Adjust in `autoscaling.env`:

```bash
# Scale up when CPU > 70% for 5 minutes
export CPU_SCALE_UP_THRESHOLD="70"

# Scale down when CPU < 30% for 5 minutes
export CPU_SCALE_DOWN_THRESHOLD="30"

# Similar for memory
export MEMORY_SCALE_UP_THRESHOLD="70"
export MEMORY_SCALE_DOWN_THRESHOLD="30"
```

### Instance Limits

```bash
# Minimum number of instances (never scale below this)
export MIN_INSTANCES="1"

# Maximum number of instances (never scale above this)
export MAX_INSTANCES="5"
```

### Alarm Timing

```bash
# How long metric must exceed threshold before triggering
export ALARM_EVALUATION_PERIOD="5"  # Minutes

# How often to check metrics
export ALARM_FREQUENCY="1"  # Minutes
```

## 🎯 Usage

### Manual Testing

#### Test Scale-Up
Generate CPU load to trigger scale-up:
```bash
# Get load balancer IP
LB_IP=$(oci lb load-balancer get --load-balancer-id $LB_OCID --query 'data."ip-addresses"[0]."ip-address"' --raw-output)

# Start CPU load scenario
curl -X POST "http://${LB_IP}/api/scenario/cpu/start?targetCpuPercent=80&durationSeconds=600"

# Watch instances scale up
watch 'oci container-instances container-instance list --compartment-id $COMPARTMENT_OCID --lifecycle-state ACTIVE --query "data.items[?starts_with(\"display-name\", \"autoscaling-demo-instance\")]" --output table'
```

#### Test Scale-Down
Stop the load and wait for scale-down:
```bash
# Stop CPU load
curl -X POST "http://${LB_IP}/api/scenario/cpu/stop"

# Watch instances scale down (takes 5-10 minutes)
watch './setup-autoscaling.sh --status'
```

### Check Function Logs

View scale-up function logs:
```bash
fn logs get app ci-autoscaling-app fn scale-up
```

View scale-down function logs:
```bash
fn logs get app ci-autoscaling-app fn scale-down
```

### Monitor Alarms

Check alarm status:
```bash
oci monitoring alarm-status list \
  --compartment-id $COMPARTMENT_OCID \
  --display-name-starts-with "ci-autoscaling"
```

## 📊 Monitoring

### Dashboard Metrics

Monitor these metrics in OCI Console:
- **CpuUtilization**: CPU usage percentage
- **MemoryUtilization**: Memory usage percentage
- **Container Instance Count**: Number of ACTIVE instances
- **Load Balancer Backend Health**: Health status of backends

### CloudEvents

View Events service rules:
```bash
oci events rule list --compartment-id $COMPARTMENT_OCID
```

### Function Invocations

Check function metrics:
```bash
# Get function OCIDs
SCALE_UP_OCID=$(oci fn function list --application-id $FUNCTIONS_APP_OCID --display-name scale-up --query 'data[0].id' --raw-output)

# View invocation metrics
oci monitoring metric-data summarize-metrics-data \
  --compartment-id $COMPARTMENT_OCID \
  --namespace oci_faas \
  --query-text "FunctionInvocationCount[$SCALE_UP_OCID].sum()"
```

## 🔧 Troubleshooting

### Functions Not Triggering

1. **Check IAM policies**: Ensure dynamic group and policies are correct
   ```bash
   oci iam dynamic-group list --compartment-id $COMPARTMENT_OCID
   ```

2. **Verify alarm configuration**: Check alarms are enabled and firing
   ```bash
   oci monitoring alarm list --compartment-id $COMPARTMENT_OCID --output table
   ```

3. **Check notification subscriptions**:
   ```bash
   oci ons subscription list --compartment-id $COMPARTMENT_OCID --topic-id $NOTIFICATION_TOPIC_OCID
   ```

### Scale-Up Failing

Check function logs for errors:
```bash
fn logs get app ci-autoscaling-app fn scale-up
```

Common issues:
- **Quota exceeded**: Check service limits
- **Subnet full**: No available IPs in subnet
- **Image pull failure**: Verify image URI and access
- **LB backend set missing**: Function creates it automatically, but check LB state

### Scale-Down Not Working

1. **Check MIN_INSTANCES**: Might already be at minimum
2. **Check alarm thresholds**: CPU/Memory might not be low enough
3. **Review function logs**: Look for errors in scale-down function

### Container Creation Slow

Normal behavior:
- Container creation: 30-60 seconds
- VNIC attachment: 30-60 seconds
- LB backend health check: 30-60 seconds

Total time from alarm to working backend: **2-3 minutes**

## 🗑️ Cleanup

Remove all autoscaling components:

```bash
cd autoscaling
source autoscaling.env
./setup-autoscaling.sh --destroy
```

This removes:
- All alarms
- Functions application (including both functions)
- Notification topic and subscriptions

**Note**: This does NOT remove:
- Container instances (use `deploy.sh` to manage those)
- Load balancer (use `loadbalancer.sh --destroy`)
- VCN/Subnets

## 📚 Additional Resources

- [OCI Functions Documentation](https://docs.oracle.com/en-us/iaas/Content/Functions/home.htm)
- [OCI Monitoring Alarms](https://docs.oracle.com/en-us/iaas/Content/Monitoring/home.htm)
- [OCI Container Instances](https://docs.oracle.com/en-us/iaas/Content/container-instances/home.htm)
- [OCI Load Balancer](https://docs.oracle.com/en-us/iaas/Content/Balance/home.htm)

## 🤝 Support

For issues or questions:
1. Check function logs: `fn logs get app ci-autoscaling-app`
2. Review alarm history in OCI Console
3. Verify IAM policies and dynamic groups
4. Check OCI service limits

---

**Created**: December 2025  
**Version**: 1.0.0
