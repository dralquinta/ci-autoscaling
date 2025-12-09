# ANY-APP: Generic Container Instance Autoscaling Solution

## 🎯 What is ANY-APP?

ANY-APP is a **production-ready, generic template** for deploying any containerized application to **OCI Container Instances** with **automated horizontal autoscaling**. It eliminates the need to build deployment infrastructure from scratch for each new application.

## ✨ Key Features

- 🚀 **Deploy Any Application**: Support for Node.js, Python, Java, Go, .NET, and more
- 📈 **Auto-Scaling**: CPU and memory-based horizontal scaling with OCI Functions
- ⚖️ **Load Balancing**: Automatic backend registration/deregistration
- 🏥 **Health Checks**: Built-in health monitoring and recovery
- 🔒 **Production-Ready**: Security best practices and proper resource limits
- 📦 **One-Command Deploy**: Single command to build, push, and deploy
- 🛠️ **Fully Customizable**: Easy to adapt for specific requirements

## 📦 What's Included

```
ANY-APP/
├── 📄 Documentation
│   ├── README.md          - Comprehensive guide (12KB)
│   ├── QUICKSTART.md      - 15-minute quick start (5KB)
│   └── INDEX.md           - Directory overview (6KB)
│
├── 🔧 Configuration Templates
│   ├── app.env.template             - Application config
│   ├── Dockerfile.template          - Multi-runtime Dockerfile
│   └── docker-compose.yml.template  - Local testing
│
├── 🚀 Deployment Scripts
│   ├── deploy.sh                    - Main deployment (13KB, executable)
│   └── scripts/
│       ├── load-balancer.sh         - LB management (6KB)
│       └── test-autoscaling.sh      - Load testing (2KB)
│
├── 📊 Autoscaling Infrastructure
│   ├── autoscaling.env.template     - Autoscaling config
│   ├── setup-autoscaling.sh         - Deploy autoscaling (12KB)
│   └── scale-up-function/           - Scale-up OCI Function
│   └── scale-down-function/         - Scale-down OCI Function
│
└── 📁 Application Source Code (YOUR CODE GOES HERE)
    └── application-source-code/
        ├── README.md                - Instructions
        ├── EXAMPLES.md              - Example applications
        ├── *.example                - Example files
        └── (your app files)         - Your application code
```

**Total: 19 files, 5 directories, fully documented and ready to use**

## 🎬 Quick Start (15 Minutes)

### 1. Add Your Application Code
```bash
cd ANY-APP/application-source-code
# Copy your application files here
cp -r /path/to/your/app/* .
cd ..
```

### 2. Setup Configuration
```bash
cp app.env.template app.env
vi app.env  # Fill in your OCI details
```

### 3. Prepare Your Dockerfile
```bash
# Copy template and customize
cp Dockerfile.template Dockerfile
# Edit for your runtime (Node.js, Python, Java, etc.)
vi Dockerfile  # Uncomment the appropriate section
```

### 4. Deploy
```bash
source app.env
./deploy.sh --build-and-push
./deploy.sh --deploy
```

### 4. Add Autoscaling (Optional)
```bash
cd autoscaling/
cp autoscaling.env.template autoscaling.env
source autoscaling.env
./setup-autoscaling.sh --deploy
```

**That's it!** Your application is now running with autoscaling on OCI.

## 📋 Supported Application Types

### Runtime Environments
- ✅ **Node.js** - Express, Koa, NestJS, etc.
- ✅ **Python** - Flask, FastAPI, Django, etc.
- ✅ **Java** - Spring Boot, Quarkus, Micronaut, etc.
- ✅ **Go** - Gin, Echo, standard net/http
- ✅ **.NET** - ASP.NET Core
- ✅ **Static Content** - Nginx, Apache

### Application Types
- REST APIs and GraphQL servers
- Web applications (React, Angular, Vue.js)
- Microservices
- Backend services
- API gateways
- WebSocket servers

## 🎛️ Configuration Options

### Basic Configuration
```bash
export OCI_COMPARTMENT_OCID="..."
export SUBNET_OCID="..."
export IMAGE_NAME="my-app"
export APP_PORT="8080"
export HEALTH_CHECK_PATH="/health"
```

### Resource Allocation
```bash
export MEMORY_GB="8"    # 1-64 GB
export OCPUS="1"        # 1-64 CPUs
```

### Autoscaling Thresholds
```bash
export MIN_INSTANCES="1"
export MAX_INSTANCES="10"
export CPU_SCALE_UP_THRESHOLD="70"
export CPU_SCALE_DOWN_THRESHOLD="30"
```

## 🎯 Use Cases

1. **Rapid Prototyping**: Get from code to production in 15 minutes
2. **Microservices Deployment**: Consistent deployment across all services
3. **Production Workloads**: Battle-tested autoscaling for production
4. **Multi-Environment**: Easy dev/staging/prod configurations
5. **CI/CD Integration**: Scriptable deployment for automation

## 📊 Architecture

```
Internet → Load Balancer → Container Instances (1-N)
                ↑                  ↑
                |                  |
            Backend Set     OCI Monitoring
                |                  |
                |            Alarms (CPU/Memory)
                |                  ↓
                |           OCI Functions
                |          (Scale Up/Down)
                |                  |
                └──────────────────┘
           Auto Register/Deregister
```

## 🛠️ Command Reference

### Deployment Commands
```bash
./deploy.sh --build           # Build image
./deploy.sh --push            # Push to registry
./deploy.sh --deploy          # Deploy to OCI
./deploy.sh --undeploy        # Remove deployment
./deploy.sh --status          # Check status
```

### Load Balancer Commands
```bash
./scripts/load-balancer.sh --create   # Create LB
./scripts/load-balancer.sh --status   # Check LB
./scripts/load-balancer.sh --delete   # Remove LB
```

### Autoscaling Commands
```bash
cd autoscaling/
./setup-autoscaling.sh --deploy    # Setup autoscaling
./setup-autoscaling.sh --status    # Check status
./setup-autoscaling.sh --undeploy  # Remove autoscaling
```

## 📚 Documentation

- **[README.md](README.md)** - Complete documentation with all features
- **[QUICKSTART.md](QUICKSTART.md)** - Step-by-step 15-minute guide
- **[INDEX.md](INDEX.md)** - Directory structure and file descriptions

## 🔐 Security Best Practices

- ✅ Non-root container users
- ✅ Multi-stage Docker builds
- ✅ Minimal base images (Alpine Linux)
- ✅ No secrets in environment files
- ✅ Network isolation with private subnets
- ✅ Health check monitoring
- ✅ Resource limits enforced

## 📋 Prerequisites

- **OCI CLI** - Configured with valid credentials
- **Docker** - For building images
- **Fn CLI** - For autoscaling functions (optional)
- **OCI Resources** - Compartment, VCN, Subnet
- **IAM Policies** - Container Instances, Functions, Load Balancer

## 🚀 What Makes This Different?

Unlike other deployment templates:
- ✅ **Truly Generic** - Works with any containerized app
- ✅ **Production-Grade** - Real autoscaling with OCI Functions
- ✅ **Complete Solution** - Deployment + Autoscaling + LB
- ✅ **Well Documented** - 3 levels of docs (README, QUICKSTART, INDEX)
- ✅ **Copy & Customize** - Not a framework, just templates
- ✅ **No Vendor Lock-in** - Standard Docker containers

## 🎓 Learning Resources

1. Start with **QUICKSTART.md** for hands-on deployment
2. Read **README.md** for comprehensive understanding
3. Check **INDEX.md** for file-by-file breakdown
4. Review example configurations in parent directory
5. Customize scripts for your specific needs

## 🤝 How to Use This Template

1. **Copy the entire ANY-APP directory** for each new application
2. **Rename it** to your application name (e.g., `my-api/`)
3. **Customize** Dockerfile, configs, and scripts
4. **Deploy** using the provided scripts
5. **Repeat** for additional applications

Each application gets its own isolated deployment!

## 📈 Scaling Capabilities

- **Horizontal Scaling**: 1 to 64+ instances
- **Vertical Scaling**: 1-64 GB RAM, 1-64 CPUs per instance
- **Auto-Scaling**: CPU and memory threshold-based
- **Load Distribution**: Round-robin with health checks
- **Zero-Downtime**: Rolling deployments

## 🎉 Success Metrics

After deployment, you'll have:
- ✅ Containerized application running on OCI
- ✅ Health monitoring and automatic recovery
- ✅ Optional load balancer for high availability
- ✅ Optional autoscaling for dynamic workloads
- ✅ Infrastructure as code for repeatability
- ✅ Production-ready configuration

## 💡 Pro Tips

1. **Test Locally First**: Always test with `docker run` before deploying
2. **Health Checks**: Implement proper health endpoints
3. **Environment Files**: Keep `app.env` secure, never commit
4. **Start Small**: Begin with minimal resources, scale as needed
5. **Monitor**: Use OCI Monitoring to watch metrics
6. **Document**: Add application-specific notes to README

## 🔄 Next Steps

1. Deploy your first application using QUICKSTART.md
2. Configure autoscaling for production workloads
3. Set up CI/CD pipeline integration
4. Add custom monitoring and alerts
5. Implement SSL/TLS with certificates
6. Scale to multiple availability domains

## 📞 Getting Help

- Review comprehensive **README.md** for detailed docs
- Check **QUICKSTART.md** for step-by-step guide
- See example configs in parent directory
- Consult OCI documentation for service details

---

## 🎯 Bottom Line

**ANY-APP gives you everything needed to deploy any containerized application to OCI Container Instances with production-grade autoscaling in under 15 minutes.**

No more writing deployment scripts from scratch for every project. Just copy, configure, and deploy!

---

*Created for the ci-autoscaling repository*  
*Version: 1.0.0*  
*Date: December 2025*
