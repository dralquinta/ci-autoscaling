# ANY-APP Quick Start Guide

Get your application running on OCI Container Instances with autoscaling in 15 minutes.

## Prerequisites Checklist

- [ ] OCI CLI installed and configured
- [ ] Docker installed
- [ ] Fn CLI installed (for autoscaling)
- [ ] Your application containerized or ready to containerize
- [ ] OCI Compartment and VCN/Subnet ready

## Step-by-Step Guide

### Step 1: Prepare Your Application (5 minutes)

#### Add Your Source Code
```bash
cd ANY-APP/application-source-code

# Copy your application files
cp -r /path/to/your/app/* .

# OR use provided examples
mv package.json.example package.json  # Node.js
mv server.js.example server.js
# OR
mv requirements.txt.example requirements.txt  # Python
mv app.py.example app.py

cd ..
```

#### Setup Dockerfile
```bash
# Copy the template
cp Dockerfile.template Dockerfile

# Edit and uncomment the section for your runtime
# For Node.js: uncomment OPTION 1
# For Python: uncomment OPTION 2
# For Java: uncomment OPTION 3
# etc.
vi Dockerfile
```

**Note**: The Dockerfile automatically copies from `application-source-code/` directory.

### Step 2: Configure Deployment (3 minutes)

```bash
# Copy configuration template
cp app.env.template app.env

# Edit with your values
vi app.env
```

**Minimum required values:**
```bash
export OCI_COMPARTMENT_OCID="ocid1.compartment.oc1..aaaaaa..."
export SUBNET_OCID="ocid1.subnet.oc1.region.aaaaaa..."
export AD_NAME="US-ASHBURN-AD-1"
export DOCKER_USERNAME="your-docker-username"
export IMAGE_NAME="my-app"
export CONTAINER_NAME="my-app"
export DISPLAY_NAME="my-app-instance"
export APP_PORT="8080"
export HEALTH_CHECK_PATH="/health"
```

### Step 3: Build and Push Image (3 minutes)

```bash
# Source configuration
source app.env

# Login to Docker Hub (or your registry)
docker login

# Build and push in one command
./deploy.sh --build-and-push
```

### Step 4: Deploy to OCI (2 minutes)

```bash
# Deploy container instance
./deploy.sh --deploy

# Check status
./deploy.sh --status
```

### Step 5: Setup Load Balancer (Optional, 2 minutes)

```bash
# Create load balancer
./scripts/load-balancer.sh --create

# Copy the LB_OCID from output and add to app.env
echo 'export LB_OCID="ocid1.loadbalancer.oc1.region.xxx"' >> app.env

# Redeploy to register with LB
source app.env
./deploy.sh --undeploy
./deploy.sh --deploy
```

### Step 6: Setup Autoscaling (Optional, 5 minutes)

```bash
cd autoscaling/

# Copy autoscaling config
cp autoscaling.env.template autoscaling.env

# Source parent configuration
source ../app.env

# Edit autoscaling config (thresholds, limits, etc.)
vi autoscaling.env
source autoscaling.env

# Deploy autoscaling infrastructure
./setup-autoscaling.sh --deploy
```

## Verification

### Test Your Deployment

```bash
# Get the container IP (if no LB)
./deploy.sh --status

# Or get LB IP
./scripts/load-balancer.sh --status

# Test health endpoint
curl http://<ip-address>/health
```

### Test Autoscaling

```bash
# Generate load to trigger scale-up
./scripts/test-autoscaling.sh <load-balancer-ip>

# Watch instances scale up
watch -n 10 './deploy.sh --status'

# Check autoscaling status
cd autoscaling/
./setup-autoscaling.sh --status
```

## Common Customizations

### Change Resource Allocation

```bash
# In app.env
export MEMORY_GB="16"  # Increase memory
export OCPUS="2"       # Increase CPU
```

### Adjust Autoscaling Thresholds

```bash
# In autoscaling/autoscaling.env
export CPU_SCALE_UP_THRESHOLD="80"    # Scale up at 80% CPU
export CPU_SCALE_DOWN_THRESHOLD="20"  # Scale down at 20% CPU
export MIN_INSTANCES="2"              # Keep minimum 2 instances
export MAX_INSTANCES="10"             # Allow up to 10 instances
```

### Add Custom Environment Variables

Edit `deploy.sh` and add to the container creation section:

```bash
"environmentVariables": [
  {"name": "DATABASE_URL", "value": "your-db-url"},
  {"name": "API_KEY", "value": "your-api-key"}
]
```

## Cleanup

### Remove Everything

```bash
# Remove autoscaling (if configured)
cd autoscaling/
./setup-autoscaling.sh --undeploy

# Remove load balancer (if created)
cd ..
./scripts/load-balancer.sh --delete

# Remove container instance
./deploy.sh --undeploy
```

## Troubleshooting

### Container Won't Start
```bash
# Check logs
oci logging-search search-logs \
  --search-query "search \"<compartment-ocid>/Container_Instances\" | source='<instance-ocid>'"
```

### Health Check Failing
```bash
# Test locally first
docker run -p 8080:8080 your-image
curl http://localhost:8080/health
```

### Can't Access Application
```bash
# Check security list allows traffic
# Check container is running
./deploy.sh --status

# Check LB backend health
./scripts/load-balancer.sh --status
```

## Next Steps

- Configure monitoring and alerts
- Set up CI/CD pipeline
- Add SSL/TLS with certificates
- Implement custom metrics for autoscaling
- Configure logging aggregation

## Getting Help

- Check README.md for detailed documentation
- Review Dockerfile.template for more runtime options
- See example configurations in the parent directory
- Consult OCI documentation for service-specific issues

---

**Pro Tip**: Keep your `app.env` and `autoscaling/autoscaling.env` files in a secure location. Never commit them to version control!
