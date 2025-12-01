# Workaround for fn deploy hanging issue

## Problem
The `fn deploy` command successfully deploys functions but hangs at the end, blocking the setup-autoscaling.sh script from completing.

## Manual Workaround

Instead of using `./setup-autoscaling.sh --deploy`, deploy functions manually:

```bash
cd /home/opc/DevOps/DEMO_SONDA/ci-autoscaling/autoscaling
source autoscaling.env

# Deploy scale-up function (will hang at end, press Ctrl+C after "Updating function..." appears)
cd scale-up-function
fn deploy --app ci-autoscaling-app
# Press Ctrl+C when you see "Updating function scale-up using image..."

# Deploy scale-down function
cd ../scale-down-function
fn deploy --app ci-autoscaling-app  
# Press Ctrl+C when you see "Updating function scale-down using image..."

# Return and configure functions + create alarms
cd ..
./setup-autoscaling.sh --skip-functions
```

## Note
Both functions will deploy successfully even though fn deploy hangs. You can verify in OCI Console.
