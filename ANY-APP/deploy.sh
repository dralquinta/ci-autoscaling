#!/bin/bash

# deploy.sh - Generic Deploy/Undeploy Container Instance to OCI
# Usage: ./deploy.sh --deploy | --undeploy | --status

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

cmd() {
    echo -e "${YELLOW}[CMD]${NC} ${YELLOW}$1${NC}"
}

# Check if app.env is sourced
if [ -z "$OCI_COMPARTMENT_OCID" ] || [ -z "$SUBNET_OCID" ]; then
    error "Required environment variables are not set. Please source app.env first:
    
    source app.env
    
Then run this script again."
fi

# Configuration from environment variables
IMAGE_NAME="${IMAGE_NAME}"
IMAGE_TAG="${IMAGE_TAG}"
DOCKER_REGISTRY="${DOCKER_REGISTRY}"
DOCKER_USERNAME="${DOCKER_USERNAME}"
IMAGE_URI="${DOCKER_REGISTRY}/${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"

# OCI Configuration
SUBNET_OCID="${SUBNET_OCID}"
CONTAINER_NAME="${CONTAINER_NAME}"
DISPLAY_NAME="${DISPLAY_NAME}"
OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID}"

# Container Configuration
APP_PORT="${APP_PORT}"
HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH}"
MEMORY_GB="${MEMORY_GB}"
OCPUS="${OCPUS}"
INSTANCE_WAIT_TIMEOUT="${INSTANCE_WAIT_TIMEOUT:-300}"

# Load Balancer Configuration
LB_OCID="${LB_OCID:-}"
BACKEND_SET_NAME="${BACKEND_SET_NAME}"
LISTENER_NAME="${LISTENER_NAME}"

# Show help menu
show_help() {
    cat << EOF
Usage: ./deploy.sh [OPTIONS]

Deploy or undeploy your application to OCI Container Instances.

OPTIONS:
    --deploy                 Deploy the container instance
    --undeploy               Undeploy (destroy) the container instance
    --status                 Show current container instance status
    --build                  Build Docker image locally
    --push                   Push Docker image to registry
    --build-and-push         Build and push Docker image
    --help                   Display this help message and exit

ENVIRONMENT VARIABLES:
    Required:
        OCI_COMPARTMENT_OCID    OCI Compartment OCID
        SUBNET_OCID             OCI Subnet OCID for container and load balancer
        AD_NAME                 Availability Domain
    
    Docker Registry:
        DOCKER_USERNAME         Docker username
        DOCKER_PASSWORD         Docker password (required for push)
        DOCKER_REGISTRY         Docker registry URL (default: docker.io)
        IMAGE_NAME              Image name
        IMAGE_TAG               Image tag (default: latest)
    
    Container Configuration:
        CONTAINER_NAME          Container name
        DISPLAY_NAME            Display name for the instance
        APP_PORT                Application port
        HEALTH_CHECK_PATH       Health check endpoint path
        MEMORY_GB               Container memory in GB (default: 8)
        OCPUS                   Container OCPUs (default: 1)
    
    Load Balancer (optional):
        LB_OCID                 Load Balancer OCID (leave empty to skip LB)
        BACKEND_SET_NAME        Backend set name
        LISTENER_NAME           Listener name

EXAMPLES:
    # Build and push image
    source app.env
    ./deploy.sh --build-and-push
    
    # Deploy container instance
    ./deploy.sh --deploy
    
    # Check status
    ./deploy.sh --status
    
    # Undeploy everything
    ./deploy.sh --undeploy

For more information, see README.md
EOF
    exit 0
}

# Function to build Docker image
build_image() {
    log "Building Docker image..."
    
    if [ ! -f "Dockerfile" ]; then
        error "Dockerfile not found. Please create one from Dockerfile.template"
    fi
    
    if [ ! -d "application-source-code" ]; then
        warn "application-source-code directory not found. Creating it..."
        mkdir -p application-source-code
        warn "Please add your application source code to the application-source-code/ directory"
    fi
    
    cmd "docker build -t ${IMAGE_URI} ."
    docker build -t "${IMAGE_URI}" .
    
    log "✅ Docker image built successfully: ${IMAGE_URI}"
}

# Function to push Docker image
push_image() {
    log "Pushing Docker image to registry..."
    
    # Login to Docker registry if password is provided
    if [ -n "$DOCKER_PASSWORD" ]; then
        info "Logging in to Docker registry..."
        echo "$DOCKER_PASSWORD" | docker login "${DOCKER_REGISTRY}" -u "${DOCKER_USERNAME}" --password-stdin
    fi
    
    cmd "docker push ${IMAGE_URI}"
    docker push "${IMAGE_URI}"
    
    log "✅ Docker image pushed successfully: ${IMAGE_URI}"
}

# Function to check if instance exists
instance_exists() {
    local instance_ocid=$(oci container-instances container-instance list \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --display-name "${DISPLAY_NAME}" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$instance_ocid" ] && [ "$instance_ocid" != "null" ]; then
        echo "$instance_ocid"
        return 0
    else
        return 1
    fi
}

# Function to create container instance
create_container_instance() {
    log "Creating OCI Container Instance..."
    
    # Check if instance already exists
    if instance_ocid=$(instance_exists); then
        warn "Container instance '${DISPLAY_NAME}' already exists with OCID: ${instance_ocid}"
        info "Use --undeploy first or choose a different DISPLAY_NAME"
        return 0
    fi
    
    # Create container instance JSON
    local container_config=$(cat <<EOF
{
  "compartmentId": "${OCI_COMPARTMENT_OCID}",
  "availabilityDomain": "${AD_NAME}",
  "shape": "CI.Standard.E4.Flex",
  "shapeConfig": {
    "ocpus": ${OCPUS},
    "memoryInGBs": ${MEMORY_GB}
  },
  "vnics": [{
    "subnetId": "${SUBNET_OCID}",
    "isPublicIpAssigned": false
  }],
  "containers": [{
    "imageUrl": "${IMAGE_URI}",
    "displayName": "${CONTAINER_NAME}",
    "healthChecks": [{
      "healthCheckType": "HTTP",
      "path": "${HEALTH_CHECK_PATH}",
      "port": ${APP_PORT},
      "intervalInSeconds": 30,
      "timeoutInSeconds": 3,
      "failureThreshold": 3
    }]
  }],
  "displayName": "${DISPLAY_NAME}"
}
EOF
)
    
    info "Creating container instance with configuration:"
    echo "$container_config" | jq '.'
    
    cmd "oci container-instances container-instance create --from-json ..."
    local response=$(echo "$container_config" | oci container-instances container-instance create \
        --from-json file:///dev/stdin \
        --wait-for-state ACTIVE \
        --wait-interval-seconds 10 \
        --max-wait-seconds "${INSTANCE_WAIT_TIMEOUT}")
    
    local instance_ocid=$(echo "$response" | jq -r '.data.id')
    
    if [ -z "$instance_ocid" ] || [ "$instance_ocid" = "null" ]; then
        error "Failed to create container instance"
    fi
    
    log "✅ Container instance created successfully"
    info "Instance OCID: ${instance_ocid}"
    
    # Get private IP
    local private_ip=$(echo "$response" | jq -r '.data.vnics[0]."private-ip"')
    info "Private IP: ${private_ip}"
    
    # Add to load balancer if configured
    if [ -n "$LB_OCID" ]; then
        add_backend_to_lb "$instance_ocid" "$private_ip"
    else
        info "No load balancer configured, skipping backend registration"
    fi
    
    log "✅ Deployment completed successfully"
}

# Function to add backend to load balancer
add_backend_to_lb() {
    local instance_ocid=$1
    local private_ip=$2
    
    if [ -z "$LB_OCID" ]; then
        return 0
    fi
    
    log "Adding backend to load balancer..."
    
    # Check if backend already exists
    local existing_backend=$(oci lb backend list \
        --load-balancer-id "${LB_OCID}" \
        --backend-set-name "${BACKEND_SET_NAME}" \
        --query "data[?\"ip-address\"=='${private_ip}'].name | [0]" \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$existing_backend" ] && [ "$existing_backend" != "null" ]; then
        warn "Backend with IP ${private_ip} already exists in backend set"
        return 0
    fi
    
    cmd "oci lb backend create ..."
    oci lb backend create \
        --load-balancer-id "${LB_OCID}" \
        --backend-set-name "${BACKEND_SET_NAME}" \
        --ip-address "${private_ip}" \
        --port "${APP_PORT}" \
        --backup false \
        --drain false \
        --offline false \
        --weight 1 \
        --wait-for-state SUCCEEDED \
        --max-wait-seconds 300
    
    log "✅ Backend added to load balancer successfully"
}

# Function to undeploy (delete) container instance
undeploy_instance() {
    log "Undeploying container instance..."
    
    # Get instance OCID
    local instance_ocid=$(instance_exists) || true
    
    if [ -z "$instance_ocid" ]; then
        warn "No active container instance found with name '${DISPLAY_NAME}'"
        return 0
    fi
    
    info "Found instance: ${instance_ocid}"
    
    # Get private IP before deletion (for LB cleanup)
    local private_ip=$(oci container-instances container-instance get \
        --container-instance-id "${instance_ocid}" \
        --query 'data.vnics[0]."private-ip"' \
        --raw-output 2>/dev/null || echo "")
    
    # Remove from load balancer first
    if [ -n "$LB_OCID" ] && [ -n "$private_ip" ]; then
        remove_backend_from_lb "$private_ip"
    fi
    
    # Delete container instance
    log "Deleting container instance..."
    cmd "oci container-instances container-instance delete --container-instance-id ${instance_ocid}"
    oci container-instances container-instance delete \
        --container-instance-id "${instance_ocid}" \
        --force \
        --wait-for-state DELETED \
        --max-wait-seconds 300
    
    log "✅ Container instance deleted successfully"
}

# Function to remove backend from load balancer
remove_backend_from_lb() {
    local private_ip=$1
    
    if [ -z "$LB_OCID" ]; then
        return 0
    fi
    
    log "Removing backend from load balancer..."
    
    # Find backend name by IP
    local backend_name=$(oci lb backend list \
        --load-balancer-id "${LB_OCID}" \
        --backend-set-name "${BACKEND_SET_NAME}" \
        --query "data[?\"ip-address\"=='${private_ip}'].name | [0]" \
        --raw-output 2>/dev/null || echo "")
    
    if [ -z "$backend_name" ] || [ "$backend_name" = "null" ]; then
        warn "Backend with IP ${private_ip} not found in load balancer"
        return 0
    fi
    
    cmd "oci lb backend delete ..."
    oci lb backend delete \
        --load-balancer-id "${LB_OCID}" \
        --backend-set-name "${BACKEND_SET_NAME}" \
        --backend-name "${backend_name}" \
        --force \
        --wait-for-state SUCCEEDED \
        --max-wait-seconds 300
    
    log "✅ Backend removed from load balancer"
}

# Function to show status
show_status() {
    log "Checking container instance status..."
    
    local instance_ocid=$(instance_exists) || true
    
    if [ -z "$instance_ocid" ]; then
        info "No active container instance found with name '${DISPLAY_NAME}'"
        return 0
    fi
    
    info "Instance found: ${instance_ocid}"
    
    # Get full instance details
    oci container-instances container-instance get \
        --container-instance-id "${instance_ocid}" \
        --query 'data.{DisplayName:"display-name", State:"lifecycle-state", TimeCreated:"time-created", Shape:shape, OCPUs:"shape-config".ocpus, Memory:"shape-config"."memory-in-gbs", PrivateIP:vnics[0]."private-ip"}' \
        --output table
    
    # Check load balancer status
    if [ -n "$LB_OCID" ]; then
        local private_ip=$(oci container-instances container-instance get \
            --container-instance-id "${instance_ocid}" \
            --query 'data.vnics[0]."private-ip"' \
            --raw-output)
        
        info "\nLoad Balancer Backend Status:"
        oci lb backend-health get \
            --load-balancer-id "${LB_OCID}" \
            --backend-set-name "${BACKEND_SET_NAME}" \
            --backend-name "${private_ip}:${APP_PORT}" \
            --query 'data.{Status:status, HealthCheck:"health-check-results"}' \
            --output table 2>/dev/null || warn "Backend not found in load balancer"
    fi
}

# Main execution
main() {
    case "${1:-}" in
        --deploy)
            create_container_instance
            ;;
        --undeploy)
            undeploy_instance
            ;;
        --status)
            show_status
            ;;
        --build)
            build_image
            ;;
        --push)
            push_image
            ;;
        --build-and-push)
            build_image
            push_image
            ;;
        --help)
            show_help
            ;;
        *)
            error "Invalid option: ${1:-}
            
Use --help to see available options"
            ;;
    esac
}

# Run main function
main "$@"
