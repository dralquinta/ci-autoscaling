#!/bin/bash

# deploy.sh - Deploy autoscaling-demo Container Instance to OCI
# Usage: ./deploy.sh

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
    echo -e "${BLUE}[CMD]${NC} $1"
}

# Check if deploy.env is sourced
if [ -z "$OCI_COMPARTMENT_OCID" ] || [ -z "$SUBNET_OCID" ]; then
    error "Required environment variables are not set. Please source deploy.env first:
    
    source deploy.env
    
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

# Load Balancer Configuration
LB_OCID="${LB_OCID:-}"
BACKEND_SET_NAME="${BACKEND_SET_NAME}"
LISTENER_NAME="${LISTENER_NAME}"

# Show help menu
show_help() {
    cat << EOF
Usage: ./deploy.sh [OPTIONS]

Deploy autoscaling-demo Spring Boot application to OCI Container Instances.

OPTIONS:
    --help                   Display this help message and exit

ENVIRONMENT VARIABLES:
    Required:
        OCI_COMPARTMENT_OCID    OCI Compartment OCID
        SUBNET_OCID             OCI Subnet OCID for container and load balancer
        AD_NAME                 Availability Domain (auto-detected if not set)
    
    Docker Registry:
        DOCKER_USERNAME         Docker Hub username (default: dralquinta)
        DOCKER_PASSWORD         Docker Hub password (required for push)
        DOCKER_REGISTRY         Docker registry URL (default: docker.io)
    
    Container Configuration:
        MEMORY_GB               Container memory in GB (default: 8)
        OCPUS                   Container OCPUs (default: 1)
    
    Load Balancer (optional):
        LB_OCID                 Existing Load Balancer OCID to configure backend

EXAMPLES:
    # Basic deployment
    ./deploy.sh
    
    # Deploy with load balancer backend configuration
    export LB_OCID=ocid1.loadbalancer.oc1...
    ./deploy.sh
    
    # Deploy with custom resources
    export MEMORY_GB=16
    export OCPUS=2
    ./deploy.sh
    
    # Deploy with existing load balancer
    export LB_OCID=ocid1.loadbalancer.oc1...
    ./deploy.sh

WORKFLOW:
    1. Check prerequisites (OCI CLI, Docker)
    2. Build Docker image
    3. Push image to Docker registry
    4. Check for existing container instance
    5. Destroy existing instance if found
    6. Deploy new container instance
    7. Test deployment health
    8. Configure load balancer backend (if LB_OCID is set)

CONFIGURATION FILE:
    You can source deploy.env to set environment variables:
        source deploy.env
        ./deploy.sh

For more information, see README.md and AUTOSCALING_USE_CASES.md
EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

# Check for required environment variables
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v oci &> /dev/null; then
        error "OCI CLI not found. Please install the OCI CLI."
    fi
    
    if ! command -v docker &> /dev/null; then
        error "Docker not found. Please install Docker."
    fi
    
    # Check required environment variables
    if [ -z "$OCI_COMPARTMENT_OCID" ]; then
        error "OCI_COMPARTMENT_OCID environment variable is not set"
    fi
    
    if [ -z "$SUBNET_OCID" ]; then
        error "SUBNET_OCID environment variable is not set"
    fi
    
    if [ -z "$AD_NAME" ]; then
        warn "AD_NAME not set, will attempt to discover automatically"
        # Try to get first available AD
        cmd "oci iam availability-domain list --compartment-id $OCI_COMPARTMENT_OCID --query 'data[0].name' --raw-output"
        
        set +e
        local AD_OUTPUT
        AD_OUTPUT=$(oci iam availability-domain list --compartment-id "$OCI_COMPARTMENT_OCID" \
            --query 'data[0].name' --raw-output 2>&1)
        local AD_EXIT_CODE=$?
        set -e
        
        if [ $AD_EXIT_CODE -ne 0 ]; then
            echo ""
            error "Failed to auto-detect availability domain. Error: $AD_OUTPUT\n\nPlease set AD_NAME environment variable explicitly.\nExample: export AD_NAME='iAEE:US-SANJOSE-1-AD-1'"
        fi
        
        AD_NAME="$AD_OUTPUT"
        
        if [ -z "$AD_NAME" ] || [ "$AD_NAME" = "null" ]; then
            error "Could not determine availability domain. Please set AD_NAME environment variable.\nExample: export AD_NAME='iAEE:US-SANJOSE-1-AD-1'"
        fi
        log "Using availability domain: $AD_NAME"
    fi
    
    log "Prerequisites check passed"
}

# Build Docker image
build_docker_image() {
    log "Building Docker image..."
    
    if [ ! -f "./Dockerfile" ]; then
        error "Dockerfile not found in current directory"
    fi
    
    cmd "docker build -t ${IMAGE_NAME}:${IMAGE_TAG} ."
    docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" . || error "Failed to build Docker image"
    
    log "Docker image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
}

# Push Docker image to registry
push_docker_image() {
    log "Pushing Docker image to registry..."
    
    # Tag image for registry
    cmd "docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${IMAGE_URI}"
    docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${IMAGE_URI}" || error "Failed to tag Docker image"
    
    # Login to Docker registry if credentials provided
    if [ -n "$DOCKER_PASSWORD" ]; then
        cmd "echo '***' | docker login $DOCKER_REGISTRY -u $DOCKER_USERNAME --password-stdin"
        echo "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME" --password-stdin || error "Failed to login to Docker registry"
    else
        warn "DOCKER_PASSWORD not set, assuming already logged in to Docker registry"
    fi
    
    # Push image
    cmd "docker push ${IMAGE_URI}"
    docker push "${IMAGE_URI}" || error "Failed to push Docker image"
    
    log "Docker image pushed successfully: ${IMAGE_URI}"
}

# Check if container instance already exists
check_existing_instance() {
    log "Checking for existing container instances..."
    
    cmd "oci container-instances container-instance list --compartment-id $OCI_COMPARTMENT_OCID --display-name $DISPLAY_NAME --lifecycle-state ACTIVE"
    local EXISTING_OCID=$(oci container-instances container-instance list \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --display-name "$DISPLAY_NAME" \
        --lifecycle-state "ACTIVE" \
        --query 'data.items[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_OCID" ] && [ "$EXISTING_OCID" != "null" ]; then
        log "Found existing container instance: $EXISTING_OCID"
        CONTAINER_INSTANCE_OCID="$EXISTING_OCID"
        return 0
    else
        log "No existing container instance found"
        return 1
    fi
}

# Destroy existing container instance
destroy_existing_instance() {
    if [ -z "$CONTAINER_INSTANCE_OCID" ]; then
        warn "No container instance OCID provided, skipping destroy"
        return 0
    fi
    
    log "Destroying existing container instance: $CONTAINER_INSTANCE_OCID"
    
    cmd "oci container-instances container-instance delete --container-instance-id $CONTAINER_INSTANCE_OCID --force"
    oci container-instances container-instance delete \
        --container-instance-id "$CONTAINER_INSTANCE_OCID" \
        --force || error "Failed to delete container instance"
    
    # Wait for deletion to complete
    log "Waiting for container instance to be deleted..."
    local MAX_WAIT=120  # 2 minutes
    local ELAPSED=0
    local SLEEP_INTERVAL=5
    
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        set +e
        local STATE=$(oci container-instances container-instance get \
            --container-instance-id "$CONTAINER_INSTANCE_OCID" \
            --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
        local GET_EXIT=$?
        set -e
        
        # If get command fails, instance is likely deleted
        if [ $GET_EXIT -ne 0 ]; then
            log "Container instance has been deleted"
            break
        fi
        
        if [ "$STATE" == "DELETED" ]; then
            log "Container instance is now DELETED"
            break
        fi
        
        echo -ne "\r${BLUE}[INFO]${NC} Current state: $STATE (waited ${ELAPSED}s)..."
        sleep $SLEEP_INTERVAL
        ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
    done
    echo  # New line after progress updates
    
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        warn "Timeout waiting for container instance deletion"
    fi
    
    log "Container instance destroyed successfully"
    CONTAINER_INSTANCE_OCID=""
}

# Deploy the container instance
deploy_container() {
    log "Deploying Container Instance for autoscaling-demo..."
    info "Configuration: ${OCPUS} OCPUs, ${MEMORY_GB} GB RAM"
    
    cmd "oci container-instances container-instance create --compartment-id $OCI_COMPARTMENT_OCID --availability-domain $AD_NAME --shape CI.Standard.E4.Flex --shape-config '{\"memoryInGBs\":$MEMORY_GB,\"ocpus\":$OCPUS}' --display-name $DISPLAY_NAME --vnics '[{\"subnetId\":\"$SUBNET_OCID\",\"assignPublicIp\":false}]' --containers '[{\"displayName\":\"$CONTAINER_NAME\",\"imageUrl\":\"$IMAGE_URI\"}]' --wait-for-state SUCCEEDED"
    
    # Create container instance - capture full output first
    set +e
    local CREATE_OUTPUT=$(oci container-instances container-instance create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --availability-domain "$AD_NAME" \
        --shape "CI.Standard.E4.Flex" \
        --shape-config '{"memoryInGBs":'$MEMORY_GB',"ocpus":'$OCPUS'}' \
        --display-name "$DISPLAY_NAME" \
        --vnics '[{"subnetId":"'$SUBNET_OCID'","assignPublicIp":false,"displayName":"autoscaling-demo-vnic","hostnameLabel":"autoscaling-demo"}]' \
        --containers '[{
            "displayName": "'$CONTAINER_NAME'",
            "imageUrl": "'$IMAGE_URI'",
            "environmentVariables": {
                "JAVA_OPTS": "-Xmx'$(($MEMORY_GB * 3 / 4))'g -Xms'$(($MEMORY_GB / 4))'g",
                "SPRING_PROFILES_ACTIVE": "production"
            }
        }]' \
        --wait-for-state SUCCEEDED 2>&1)
    
    local EXIT_CODE=$?
    set -e
    
    if [ $EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Container creation failed with error:${NC}"
        echo "$CREATE_OUTPUT"
        error "Failed to create container instance"
    fi
    
    # Extract the container instance OCID from the output
    CONTAINER_INSTANCE_OCID=$(echo "$CREATE_OUTPUT" | grep -o 'ocid1\.computecontainerinstance[^"]*' | head -1)
    
    if [ -z "$CONTAINER_INSTANCE_OCID" ]; then
        error "Failed to extract container instance OCID from output"
    fi
    
    log "Created Container Instance: $CONTAINER_INSTANCE_OCID"
}

# Get container instance details
get_instance_details() {
    log "Retrieving container instance details..."
    
    # Get VNIC ID first
    cmd "oci container-instances container-instance get --container-instance-id $CONTAINER_INSTANCE_OCID"
    local VNIC_ID=$(oci container-instances container-instance get \
        --container-instance-id "$CONTAINER_INSTANCE_OCID" \
        --query 'data.vnics[0]."vnic-id"' --raw-output 2>/dev/null || echo "")
    
    if [ -z "$VNIC_ID" ] || [ "$VNIC_ID" == "null" ]; then
        warn "Could not retrieve VNIC ID"
        return 0
    fi
    
    # Get private IP from VNIC
    cmd "oci network vnic get --vnic-id $VNIC_ID"
    CONTAINER_PRIVATE_IP=$(oci network vnic get \
        --vnic-id "$VNIC_ID" \
        --query 'data."private-ip"' --raw-output 2>/dev/null || echo "")
    
    if [ -n "$CONTAINER_PRIVATE_IP" ] && [ "$CONTAINER_PRIVATE_IP" != "null" ]; then
        echo ""
        log "✅ Container Instance deployed successfully!"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "OCID:           $CONTAINER_INSTANCE_OCID"
        log "Private IP:     $CONTAINER_PRIVATE_IP"
        log "Health Check:   http://${CONTAINER_PRIVATE_IP}:${APP_PORT}${HEALTH_CHECK_PATH}"
        log "Application:    http://${CONTAINER_PRIVATE_IP}:${APP_PORT}"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log ""
        log "API Endpoints:"
        log "  - CPU Scenario:    POST http://${CONTAINER_PRIVATE_IP}:${APP_PORT}/api/scenario/cpu/start"
        log "  - Memory Scenario: POST http://${CONTAINER_PRIVATE_IP}:${APP_PORT}/api/scenario/memory/start"
        log "  - Health Scenario: POST http://${CONTAINER_PRIVATE_IP}:${APP_PORT}/api/scenario/health/fail"
        log "  - Status:          GET  http://${CONTAINER_PRIVATE_IP}:${APP_PORT}/api/scenario/status"
        log "  - Prometheus:      GET  http://${CONTAINER_PRIVATE_IP}:${APP_PORT}/actuator/prometheus"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        warn "Could not retrieve private IP address"
        log "OCID: $CONTAINER_INSTANCE_OCID"
    fi
}

# Check if backend set exists
check_backend_set_exists() {
    if [ -z "$LB_OCID" ]; then
        return 1
    fi
    
    log "Checking if backend set '$BACKEND_SET_NAME' exists..."
    
    cmd "oci lb load-balancer get --load-balancer-id $LB_OCID"
    local BACKEND_SET=$(oci lb load-balancer get \
        --load-balancer-id "$LB_OCID" \
        --query "data.\"backend-sets\".\"$BACKEND_SET_NAME\"" 2>/dev/null || echo "")
    
    if [ -n "$BACKEND_SET" ] && [ "$BACKEND_SET" != "null" ]; then
        log "Backend set '$BACKEND_SET_NAME' already exists"
        return 0
    else
        log "Backend set '$BACKEND_SET_NAME' does not exist"
        return 1
    fi
}

# Create backend set
create_backend_set() {
    log "Creating backend set '$BACKEND_SET_NAME'..."
    
    cmd "oci lb backend-set create --load-balancer-id $LB_OCID --name $BACKEND_SET_NAME --policy ROUND_ROBIN --health-checker-protocol HTTP --health-checker-port $APP_PORT --health-checker-url-path $HEALTH_CHECK_PATH --wait-for-state SUCCEEDED"
    oci lb backend-set create \
        --load-balancer-id "$LB_OCID" \
        --name "$BACKEND_SET_NAME" \
        --policy "ROUND_ROBIN" \
        --health-checker-protocol "HTTP" \
        --health-checker-port "$APP_PORT" \
        --health-checker-url-path "$HEALTH_CHECK_PATH" \
        --health-checker-interval-in-ms 10000 \
        --health-checker-timeout-in-ms 3000 \
        --health-checker-retries 3 \
        --wait-for-state SUCCEEDED || error "Failed to create backend set"
    
    log "Backend set created successfully"
}

# Remove old backend from backend set
remove_old_backend() {
    if [ -z "$1" ] || [ -z "$LB_OCID" ]; then
        return 0
    fi
    
    local OLD_IP="$1"
    log "Removing old backend with IP: $OLD_IP"
    
    cmd "oci lb backend delete --load-balancer-id $LB_OCID --backend-set-name $BACKEND_SET_NAME --backend-name ${OLD_IP}:${APP_PORT} --force --wait-for-state SUCCEEDED"
    oci lb backend delete \
        --load-balancer-id "$LB_OCID" \
        --backend-set-name "$BACKEND_SET_NAME" \
        --backend-name "${OLD_IP}:${APP_PORT}" \
        --force \
        --wait-for-state SUCCEEDED 2>/dev/null || warn "Could not remove old backend (may not exist)"
}

# Add container to backend set
add_backend_to_lb() {
    if [ -z "$CONTAINER_PRIVATE_IP" ] || [ -z "$LB_OCID" ]; then
        return 0
    fi
    
    log "Adding container instance to Load Balancer backend set..."
    log "Backend: ${CONTAINER_PRIVATE_IP}:${APP_PORT}"
    
    cmd "oci lb backend create --load-balancer-id $LB_OCID --backend-set-name $BACKEND_SET_NAME --ip-address $CONTAINER_PRIVATE_IP --port $APP_PORT --weight 1 --wait-for-state SUCCEEDED"
    oci lb backend create \
        --load-balancer-id "$LB_OCID" \
        --backend-set-name "$BACKEND_SET_NAME" \
        --ip-address "$CONTAINER_PRIVATE_IP" \
        --port "$APP_PORT" \
        --weight 1 \
        --backup false \
        --drain false \
        --offline false \
        --wait-for-state SUCCEEDED || error "Failed to add backend to load balancer"
    
    log "Backend added successfully"
}

# Create Load Balancer


# Get Load Balancer public IP
get_lb_public_ip() {
    if [ -z "$LB_OCID" ]; then
        return 0
    fi
    
    log "Retrieving Load Balancer details..."
    
    cmd "oci lb load-balancer get --load-balancer-id $LB_OCID"
    local LB_PUBLIC_IP=$(oci lb load-balancer get \
        --load-balancer-id "$LB_OCID" \
        --query 'data."ip-addresses"[0]."ip-address"' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$LB_PUBLIC_IP" ] && [ "$LB_PUBLIC_IP" != "null" ]; then
        echo ""
        log "✅ Load Balancer Configuration"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "OCID:          $LB_OCID"
        log "Public IP:     $LB_PUBLIC_IP"
        log "HTTP URL:      http://${LB_PUBLIC_IP}"
        log "Listener:      $LISTENER_NAME"
        log "Backend Set:   $BACKEND_SET_NAME"
        log "Backend:       ${CONTAINER_PRIVATE_IP}:${APP_PORT}"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log ""
        log "Test the Load Balancer:"
        log "  curl http://${LB_PUBLIC_IP}/api/health"
        log "  curl http://${LB_PUBLIC_IP}/api/info"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# Test the deployment
test_deployment() {
    if [ -z "$CONTAINER_PRIVATE_IP" ]; then
        warn "Cannot test deployment - no private IP available"
        return 0
    fi
    
    log "Testing deployment..."
    
    local MAX_RETRIES=10
    local RETRY_DELAY=10
    
    for i in $(seq 1 $MAX_RETRIES); do
        info "Health check attempt $i/$MAX_RETRIES..."
        
        cmd "curl -sf http://${CONTAINER_PRIVATE_IP}:${APP_PORT}${HEALTH_CHECK_PATH}"
        if curl -sf "http://${CONTAINER_PRIVATE_IP}:${APP_PORT}${HEALTH_CHECK_PATH}" > /dev/null 2>&1; then
            log "✅ Application is healthy and responding!"
            
            # Test info endpoint
            info "Testing application info endpoint..."
            cmd "curl -s http://${CONTAINER_PRIVATE_IP}:${APP_PORT}/api/info | head -5"
            curl -s "http://${CONTAINER_PRIVATE_IP}:${APP_PORT}/api/info" | head -5
            
            return 0
        fi
        
        if [ $i -lt $MAX_RETRIES ]; then
            info "Waiting ${RETRY_DELAY}s before retry..."
            sleep $RETRY_DELAY
        fi
    done
    
    warn "Application health check did not succeed after $MAX_RETRIES attempts"
    warn "The application may still be starting up. Please check manually."
}

# Main execution
main() {
    log "Starting autoscaling-demo deployment to OCI Container Instances..."
    echo ""
    
    check_prerequisites
    echo ""
    
    # Build and push Docker image
    build_docker_image
    echo ""
    push_docker_image
    echo ""
    
    # Store old container IP if exists (for backend removal)
    OLD_CONTAINER_IP=""
    if check_existing_instance; then
        log "Existing instance found - will destroy and redeploy with latest image"
        
        # Get old container IP before destroying
        cmd "oci container-instances container-instance get --container-instance-id $CONTAINER_INSTANCE_OCID"
        local OLD_VNIC_ID=$(oci container-instances container-instance get \
            --container-instance-id "$CONTAINER_INSTANCE_OCID" \
            --query 'data.vnics[0]."vnic-id"' --raw-output 2>/dev/null || echo "")
        
        if [ -n "$OLD_VNIC_ID" ] && [ "$OLD_VNIC_ID" != "null" ]; then
            cmd "oci network vnic get --vnic-id $OLD_VNIC_ID"
            OLD_CONTAINER_IP=$(oci network vnic get \
                --vnic-id "$OLD_VNIC_ID" \
                --query 'data."private-ip"' --raw-output 2>/dev/null || echo "")
            log "Old container IP: $OLD_CONTAINER_IP"
        fi
        
        destroy_existing_instance
        echo ""
    fi
    
    # Deploy new container instance with latest image
    deploy_container
    
    # Wait for networking to be ready
    log "Waiting for networking to be ready..."
    sleep 30
    
    # Get new container details (sets CONTAINER_PRIVATE_IP)
    get_instance_details
    echo ""
    
    # Test deployment
    test_deployment
    
    # Configure Load Balancer backend (if LB_OCID is set)
    if [ -n "$LB_OCID" ] && [ -n "$CONTAINER_PRIVATE_IP" ]; then
        echo ""
        log "Configuring Load Balancer..."
        
        # Create backend set if it doesn't exist
        if ! check_backend_set_exists; then
            create_backend_set
        fi
        
        # Remove old backend if it existed
        if [ -n "$OLD_CONTAINER_IP" ]; then
            remove_old_backend "$OLD_CONTAINER_IP"
        fi
        
        # Add new backend
        add_backend_to_lb
        
        # Display Load Balancer info
        get_lb_public_ip
    fi
    
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "✅ Deployment complete!"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log "Next steps:"
    log "  1. Test autoscaling scenarios:"
    if [ -n "$LB_OCID" ]; then
        local LB_IP=$(oci lb load-balancer get \
            --load-balancer-id "$LB_OCID" \
            --query 'data."ip-addresses"[0]."ip-address"' \
            --raw-output 2>/dev/null || echo "")
        if [ -n "$LB_IP" ]; then
            log "     ./test-autoscaling.sh http://${LB_IP}"
        else
            log "     ./test-autoscaling.sh http://${CONTAINER_PRIVATE_IP}:${APP_PORT}"
        fi
    else
        log "     ./test-autoscaling.sh http://${CONTAINER_PRIVATE_IP}:${APP_PORT}"
    fi
    echo ""
    log "  2. Monitor container:"
    log "     oci container-instances container-instance get --container-instance-id $CONTAINER_INSTANCE_OCID"
    echo ""
    log "  3. View logs:"
    log "     oci logging-search search-logs --search-query \"search \\\"$OCI_COMPARTMENT_OCID\\\" | source='$CONTAINER_INSTANCE_OCID'\""
    echo ""
}

# Run main function
main
