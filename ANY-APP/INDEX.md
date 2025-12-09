# ANY-APP: Generic Container Instance Autoscaling Template

## 📁 Directory Structure

```
ANY-APP/
├── README.md                      # Comprehensive documentation
├── QUICKSTART.md                  # 15-minute quick start guide
├── .gitignore                     # Git ignore rules
│
├── Dockerfile.template            # Multi-runtime Dockerfile template
├── docker-compose.yml.template    # Docker Compose template
├── app.env.template               # Application configuration template
├── deploy.sh                      # Main deployment script
│
├── application-source-code/       # YOUR APPLICATION CODE GOES HERE
│   ├── README.md                  # Instructions for adding your code
│   ├── EXAMPLES.md                # Example applications
│   ├── *.example                  # Example files for different runtimes
│   └── (your app files)           # Place your application here
│
├── scripts/
│   ├── load-balancer.sh          # Load balancer management
│   └── test-autoscaling.sh       # Autoscaling test script
│
└── autoscaling/
    ├── autoscaling.env.template   # Autoscaling configuration
    ├── setup-autoscaling.sh       # Autoscaling deployment script
    ├── scale-up-function/
    │   ├── func.py                # Scale-up function code
    │   ├── func.yaml              # Function configuration
    │   └── requirements.txt       # Python dependencies
    └── scale-down-function/
        ├── func.py                # Scale-down function code
        ├── func.yaml              # Function configuration
        └── requirements.txt       # Python dependencies
```

## 🚀 Quick Start

1. **Add your application code:**
   ```bash
   cd application-source-code/
   # Copy your app files here
   cp -r /path/to/your/app/* .
   cd ..
   ```

2. **Copy template files:**
   ```bash
   cp Dockerfile.template Dockerfile
   cp app.env.template app.env
   # Edit Dockerfile and uncomment your runtime section
   ```

3. **Configure:**
   ```bash
   vi app.env  # Edit with your OCI and app settings
   ```

4. **Deploy:**
   ```bash
   source app.env
   ./deploy.sh --build-and-push
   ./deploy.sh --deploy
   ```

See [QUICKSTART.md](QUICKSTART.md) for detailed step-by-step instructions.

## 📋 Key Files

### Configuration Files
- **app.env.template**: Main application configuration (OCI, Docker, resources)
- **autoscaling/autoscaling.env.template**: Autoscaling settings (thresholds, limits)

### Deployment Scripts
- **deploy.sh**: Build, push, deploy, and manage container instances
- **scripts/load-balancer.sh**: Create and manage OCI Load Balancer
- **autoscaling/setup-autoscaling.sh**: Deploy autoscaling infrastructure

### Templates
- **Dockerfile.template**: Multi-runtime container templates (Node.js, Python, Java, Go, .NET)
- **docker-compose.yml.template**: Local testing configuration

### Functions
- **autoscaling/scale-up-function/**: OCI Function to create new instances
- **autoscaling/scale-down-function/**: OCI Function to terminate instances

## 🎯 Use Cases

This template supports deploying any containerized application with autoscaling:

- ✅ REST APIs (Node.js, Python Flask/FastAPI, Spring Boot, Go)
- ✅ Web applications (React, Angular, Vue.js with nginx)
- ✅ Microservices architectures
- ✅ Backend services
- ✅ API gateways
- ✅ Static content servers

## 🛠️ Features

- **Multi-Runtime Support**: Templates for 6+ runtime environments
- **Automated Deployment**: Single-command deployment to OCI
- **Auto-Scaling**: CPU and memory-based horizontal scaling
- **Load Balancing**: Automatic backend registration/deregistration
- **Health Checks**: Built-in health monitoring
- **Production-Ready**: Security best practices included

## 📚 Documentation

- [README.md](README.md): Full documentation with all details
- [QUICKSTART.md](QUICKSTART.md): 15-minute quick start guide
- Examples in parent directory (`../docs/`)

## 🔧 Commands Reference

### Deployment
```bash
./deploy.sh --build           # Build Docker image
./deploy.sh --push            # Push to registry
./deploy.sh --build-and-push  # Build and push
./deploy.sh --deploy          # Deploy to OCI
./deploy.sh --undeploy        # Remove instance
./deploy.sh --status          # Check status
```

### Load Balancer
```bash
./scripts/load-balancer.sh --create   # Create LB
./scripts/load-balancer.sh --status   # Check status
./scripts/load-balancer.sh --delete   # Remove LB
```

### Autoscaling
```bash
cd autoscaling/
./setup-autoscaling.sh --deploy    # Setup autoscaling
./setup-autoscaling.sh --status    # Check status
./setup-autoscaling.sh --undeploy  # Remove autoscaling
```

### Testing
```bash
./scripts/test-autoscaling.sh <lb-ip>  # Generate load
```

## ⚙️ Configuration Examples

### Minimal Configuration
```bash
export OCI_COMPARTMENT_OCID="ocid1.compartment..."
export SUBNET_OCID="ocid1.subnet..."
export AD_NAME="US-ASHBURN-AD-1"
export DOCKER_USERNAME="myuser"
export IMAGE_NAME="my-app"
export APP_PORT="8080"
export HEALTH_CHECK_PATH="/health"
```

### Production Configuration
```bash
# Higher resources
export MEMORY_GB="16"
export OCPUS="4"

# Autoscaling
export MIN_INSTANCES="2"
export MAX_INSTANCES="20"
export CPU_SCALE_UP_THRESHOLD="75"
export CPU_SCALE_DOWN_THRESHOLD="25"
```

## 🔐 Security Notes

- Never commit `app.env` or `autoscaling.env` to version control
- Use OCI Vault for sensitive credentials
- Configure network security lists appropriately
- Use private subnets for container instances
- Enable HTTPS with SSL certificates on load balancer

## 📦 Prerequisites

- OCI CLI configured
- Docker installed
- Fn CLI installed (for autoscaling)
- Appropriate IAM policies configured

## 🤝 Contributing

This is a generic template. Customize it for your specific needs:

1. Modify Dockerfile for your application
2. Adjust resource allocations in app.env
3. Customize autoscaling thresholds
4. Add application-specific environment variables
5. Extend scripts with custom logic

## 📄 License

See main repository for license information.

---

**Need help?** See [README.md](README.md) for detailed documentation or [QUICKSTART.md](QUICKSTART.md) for a quick walkthrough.
