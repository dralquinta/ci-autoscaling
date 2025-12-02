#!/bin/bash

# app.sh - Deploy/Undeploy autoscaling-demo Container Instance to OCI
# Usage: ./app.sh --deploy | --undeploy

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
# Load Balancer Configuration (backend set and backend management only - LB creation handled by loadbalancer.sh)
LB_OCID="${LB_OCID:-}"
BACKEND_SET_NAME="${BACKEND_SET_NAME}"
LISTENER_NAME="${LISTENER_NAME}"

# Show help menu
show_help() {
    cat << EOF
Usage: ./app.sh [OPTIONS]

Deploy or undeploy autoscaling-demo Spring Boot application to OCI Container Instances.

OPTIONS:
    --deploy                 Deploy the container instance
    --undeploy               Undeploy (destroy) the container instance
    --status                 Show current container instance status
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
        LB_OCID                 Existing Load Balancer OCID (required to add backends)
                                Note: Use loadbalancer.sh to create the load balancer first

EXAMPLES:
    # Deploy the application
    ./app.sh --deploy
    
    # Undeploy the application
    ./app.sh --undeploy
    
    # Deploy with load balancer backend configuration
    export LB_OCID=ocid1.loadbalancer.oc1...
    ./app.sh --deploy
    
    # Deploy with custom resources
    export MEMORY_GB=16
    export OCPUS=2
    ./app.sh --deploy

DEPLOY WORKFLOW:
    1. Check prerequisites (OCI CLI, Docker)
    2. Build Docker image
    3. Push image to Docker registry
    4. Check for existing container instance
    5. Destroy existing instance if found
    6. Deploy new container instance
    7. Test deployment health
    8. Create backend set and add container as backend (if LB_OCID is set)

UNDEPLOY WORKFLOW:
    1. Check prerequisites (OCI CLI)
    2. Find existing container instance
    3. Remove backend from load balancer (if LB_OCID is set)
    4. Destroy container instance

CONFIGURATION FILE:
    You can source app.env to set environment variables:
        source app.env
        ./app.sh --deploy

For more information, see README.md and AUTOSCALING_USE_CASES.md
EOF
    exit 0
}

# Parse command line arguments
DEPLOY_MODE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            ;;
        --deploy)
            DEPLOY_MODE="deploy"
            shift
            ;;
        --undeploy)
            DEPLOY_MODE="undeploy"
            shift
            ;;
        --status)
            DEPLOY_MODE="status"
            shift
            ;;
        --skip-docker)
            export SKIP_DOCKER=1
            shift
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

# Validate that either --deploy or --undeploy is provided
if [ -z "$DEPLOY_MODE" ]; then
    error "Please specify either --deploy or --undeploy. Use --help for usage information."
fi

# Check for required environment variables
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v oci &> /dev/null; then
        error "OCI CLI not found. Please install the OCI CLI."
    fi
    
    if [ "$DEPLOY_MODE" == "deploy" ]; then
        if ! command -v docker &> /dev/null; then
            if [ "$SKIP_DOCKER" == "1" ]; then
                warn "Docker not found - continuing because SKIP_DOCKER=1"
            else
                error "Docker not found. Please install Docker."
            fi
        fi
    fi
    
    # Check required environment variables
    if [ -z "$OCI_COMPARTMENT_OCID" ]; then
        error "OCI_COMPARTMENT_OCID environment variable is not set"
    fi
    
    if [ -z "$SUBNET_OCID" ]; then
        error "SUBNET_OCID environment variable is not set"
    fi
    
    if [ "$DEPLOY_MODE" == "deploy" ]; then
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
        fi
        log "Using availability domain: $AD_NAME"
    fi
    
    log "Prerequisites check passed"
}

# Build Docker image
build_docker_image() {
    log "Building Docker image..."
    
    # Optionally skip Docker build/push (useful for debug)
    if [ "$SKIP_DOCKER" == "1" ]; then
        warn "SKIP_DOCKER is set - skipping Docker build"
        return 0
    fi

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
    if [ "$SKIP_DOCKER" == "1" ]; then
        warn "SKIP_DOCKER is set - skipping Docker push"
        return 0
    fi
    
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

# Deploy container instance
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
    # When --wait-for-state is used, we need to extract from work-request or query by name
    CONTAINER_INSTANCE_OCID=$(echo "$CREATE_OUTPUT" | grep -o 'ocid1\.computecontainerinstance[^"[:space:]]*' | head -1)
    
    if [ -z "$CONTAINER_INSTANCE_OCID" ]; then
        # If extraction failed, query by display name (wait a bit for state to propagate)
        log "Extracting OCID from output failed, waiting for instance to be active..."
        sleep 10
        
        cmd "oci container-instances container-instance list --compartment-id $OCI_COMPARTMENT_OCID --display-name $DISPLAY_NAME"
        CONTAINER_INSTANCE_OCID=$(oci container-instances container-instance list \
            --compartment-id "$OCI_COMPARTMENT_OCID" \
            --display-name "$DISPLAY_NAME" \
            --query 'data.items[0].id' \
            --raw-output 2>/dev/null || echo "")
        
        if [ -z "$CONTAINER_INSTANCE_OCID" ] || [ "$CONTAINER_INSTANCE_OCID" == "null" ]; then
            # If still not found, try to extract from work-request-id in CREATE_OUTPUT
            WORK_REQUEST_OCID=$(echo "$CREATE_OUTPUT" | grep -o 'ocid1\.workrequest[^"[:space:]]*' | head -1)
            if [ -n "$WORK_REQUEST_OCID" ]; then
                log "Found work request: $WORK_REQUEST_OCID, querying resources for container instance OCID..."
                set +e
                CONTAINER_INSTANCE_OCID=$(oci work-requests work-request get --work-request-id "$WORK_REQUEST_OCID" --query "data.resources[?contains(entity-type, 'containerInstance')].identifier | [0]" --raw-output 2>/dev/null || echo "")
                set -e
            fi

            if [ -z "$CONTAINER_INSTANCE_OCID" ] || [ "$CONTAINER_INSTANCE_OCID" == "null" ]; then
                error "Failed to extract or query container instance OCID"
            fi
        fi
    fi
    
    log "Created Container Instance: $CONTAINER_INSTANCE_OCID"
    # Wait until the container instance lifecycle state becomes ACTIVE
    wait_for_instance_state "$CONTAINER_INSTANCE_OCID" "ACTIVE" "$INSTANCE_WAIT_TIMEOUT"
    if [ $? -ne 0 ]; then
        set +e
        local STATE=$(oci container-instances container-instance get --container-instance-id "$CONTAINER_INSTANCE_OCID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "UNKNOWN")
        set -e
        if [ "$STATE" != "ACTIVE" ]; then
            error "Container instance did not reach ACTIVE state (state: $STATE). Check the OCI Console or run: oci container-instances container-instance get --container-instance-id $CONTAINER_INSTANCE_OCID"
        fi
    fi
}


# Wait for a container instance to reach a specific lifecycle state
wait_for_instance_state() {
    local instance_ocid="$1"
    local target_state="$2"
    local max_wait=${3:-120}
    local elapsed=0
    local interval=5

    log "Waiting for instance $instance_ocid to reach state $target_state..."
    while [ $elapsed -lt $max_wait ]; do
        set +e
        local state=$(oci container-instances container-instance get --container-instance-id "$instance_ocid" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "")
        local get_exit=$?
        set -e
        if [ $get_exit -ne 0 ]; then
            warn "Failed to query instance state for $instance_ocid"
        fi
        if [ "$state" = "$target_state" ]; then
            log "Instance $instance_ocid reached state $target_state"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    warn "Timeout waiting for instance $instance_ocid to reach $target_state (waited ${max_wait}s)"
    return 1
}

# Get container instance details
get_instance_details() {
    log "Retrieving container instance details..."
    
    # Get VNIC ID first - wait until VNIC is attached
    local MAX_WAIT=120
    local ELAPSED=0
    local SLEEP_INTERVAL=5
    local VNIC_ID=""

    cmd "oci container-instances container-instance get --container-instance-id $CONTAINER_INSTANCE_OCID"
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        VNIC_ID=$(oci container-instances container-instance get \
            --container-instance-id "$CONTAINER_INSTANCE_OCID" \
            --query 'data.vnics[0]."vnic-id"' --raw-output 2>/dev/null || echo "")
        
        if [ -n "$VNIC_ID" ] && [ "$VNIC_ID" != "null" ]; then
            log "VNIC attached: $VNIC_ID"
            break
        fi
        
        sleep $SLEEP_INTERVAL
        ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
        info "Waiting for VNIC attachment... (${ELAPSED}s / ${MAX_WAIT}s)"
    done
    
    if [ -z "$VNIC_ID" ] || [ "$VNIC_ID" == "null" ]; then
        error "Failed to get VNIC ID within timeout period"
    fi
    
    # Get private IP from VNIC
    cmd "oci network vnic get --vnic-id $VNIC_ID"
    CONTAINER_PRIVATE_IP=$(oci network vnic get \
        --vnic-id "$VNIC_ID" \
        --query 'data."private-ip"' --raw-output 2>/dev/null || echo "")
    
    if [ -z "$CONTAINER_PRIVATE_IP" ] || [ "$CONTAINER_PRIVATE_IP" == "null" ]; then
        error "Failed to get container private IP"
    fi
    
    log "Container Private IP: $CONTAINER_PRIVATE_IP"
    
    # Display container details
    echo ""
    log "✅ Container Instance Details"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "OCID:        $CONTAINER_INSTANCE_OCID"
    log "Private IP:  $CONTAINER_PRIVATE_IP"
    log "Port:        $APP_PORT"
    log "Health:      http://${CONTAINER_PRIVATE_IP}:${APP_PORT}${HEALTH_CHECK_PATH}"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Test deployment
test_deployment() {
    log "Testing deployment health..."
    
    if [ -z "$CONTAINER_PRIVATE_IP" ]; then
        warn "Container private IP not available, skipping health check"
        return 0
    fi
    
    local HEALTH_URL="http://${CONTAINER_PRIVATE_IP}:${APP_PORT}${HEALTH_CHECK_PATH}"
    local MAX_RETRIES=30
    local RETRY_DELAY=5
    local RETRY_COUNT=0
    
    log "Health check URL: $HEALTH_URL"
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        set +e
        local HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "$HEALTH_URL" 2>/dev/null)
        set -e
        
        if [ "$HTTP_STATUS" == "200" ]; then
            log "✅ Health check passed! Application is running."
            return 0
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        info "Health check attempt $RETRY_COUNT/$MAX_RETRIES (HTTP $HTTP_STATUS) - waiting ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
    done
    
    warn "Health check did not pass after $MAX_RETRIES attempts. Application may still be starting up."
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
        log "Backend Set:   $BACKEND_SET_NAME"
        log "Backend:       ${CONTAINER_PRIVATE_IP}:${APP_PORT}"
        log "Health Check:  HTTP ${HEALTH_CHECK_PATH}"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log ""
        log "Access application: http://${LB_PUBLIC_IP}"
    fi
}

# Main deployment function
deploy() {
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
    
    # Get new container details (sets CONTAINER_PRIVATE_IP)
    log "Gathering instance details and waiting for VNIC attachment..."
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
    
    # Determine the base URL
    local BASE_URL=""
    if [ -n "$LB_OCID" ]; then
        local LB_IP=$(oci lb load-balancer get \
            --load-balancer-id "$LB_OCID" \
            --query 'data."ip-addresses"[0]."ip-address"' \
            --raw-output 2>/dev/null || echo "")
        if [ -n "$LB_IP" ]; then
            BASE_URL="http://${LB_IP}"
            log "🌐 Application Endpoints (via Load Balancer):"
            log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log "Public IP: ${LB_IP}"
        else
            BASE_URL="http://${CONTAINER_PRIVATE_IP}:${APP_PORT}"
            log "🌐 Application Endpoints (Direct Container Access):"
            log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log "Container IP: ${CONTAINER_PRIVATE_IP}:${APP_PORT}"
        fi
    else
        BASE_URL="http://${CONTAINER_PRIVATE_IP}:${APP_PORT}"
        log "🌐 Application Endpoints (Direct Container Access):"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "Container IP: ${CONTAINER_PRIVATE_IP}:${APP_PORT}"
    fi
    echo ""
    
    # Health & Info Endpoints
    log "📋 Health & Info:"
    log "  ${BASE_URL}/actuator/health"
    log "  ${BASE_URL}/api/health"
    log "  ${BASE_URL}/api/info"
    echo ""
    
    # Load Test Endpoints
    log "⚡ Load Test Endpoints:"
    log "  ${BASE_URL}/api/cpu?iterations=1000"
    log "  ${BASE_URL}/api/memory?sizeMB=10"
    log "  ${BASE_URL}/api/combined?cpuIterations=500&memoryMB=5"
    log "  DELETE ${BASE_URL}/api/memory"
    echo ""
    
    # Autoscaling Scenarios
    log "🔄 Autoscaling Scenario Controls:"
    log "  CPU Load:"
    log "    POST ${BASE_URL}/api/scenario/cpu/start?targetCpuPercent=60&durationSeconds=300"
    log "    POST ${BASE_URL}/api/scenario/cpu/stop"
    echo ""
    log "  Memory Load:"
    log "    POST ${BASE_URL}/api/scenario/memory/start?targetMemoryPercent=70&durationSeconds=300"
    log "    POST ${BASE_URL}/api/scenario/memory/stop"
    echo ""
    log "  Health Check Failure:"
    log "    POST ${BASE_URL}/api/scenario/health/fail?durationSeconds=300"
    log "    POST ${BASE_URL}/api/scenario/health/recover"
    log "    GET  ${BASE_URL}/api/scenario/health/status"
    echo ""
    log "  Scenario Status:"
    log "    GET ${BASE_URL}/api/scenario/status"
    echo ""
    
    # Actuator Endpoints
    log "📊 Actuator Endpoints:"
    log "  ${BASE_URL}/actuator/metrics"
    log "  ${BASE_URL}/actuator/prometheus"
    echo ""
    
    # Quick Test Commands
    log "🧪 Quick Test Commands:"
    log "  # Check health:"
    log "    curl ${BASE_URL}/api/health"
    echo ""
    log "  # Get application info:"
    log "    curl ${BASE_URL}/api/info"
    echo ""
    log "  # Start CPU autoscaling scenario:"
    log "    curl -X POST '${BASE_URL}/api/scenario/cpu/start?targetCpuPercent=70&durationSeconds=300'"
    echo ""
    log "  # Check scenario status:"
    log "    curl ${BASE_URL}/api/scenario/status"
    echo ""
    log "  # Run full autoscaling test suite:"
    if [ -n "$LB_IP" ]; then
        log "    ./test-autoscaling.sh http://${LB_IP}"
    else
        log "    ./test-autoscaling.sh http://${CONTAINER_PRIVATE_IP}:${APP_PORT}"
    fi
    echo ""
    
    log "📦 Container Management:"
    log "  Monitor: oci container-instances container-instance get --container-instance-id ${CONTAINER_INSTANCE_OCID}"
    log "  Logs:    oci logging-search search-logs --search-query \"search \\\"${OCI_COMPARTMENT_OCID}\\\" | source='${CONTAINER_INSTANCE_OCID}'\""
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Main undeployment function
undeploy() {
    log "Starting autoscaling-demo undeployment from OCI Container Instances..."
    echo ""
    
    check_prerequisites
    echo ""
    
    # Check for existing container instance
    if ! check_existing_instance; then
        log "No container instance found to undeploy"
        return 0
    fi
    
    # Get container IP before destroying (for backend removal)
    log "Getting container details for cleanup..."
    cmd "oci container-instances container-instance get --container-instance-id $CONTAINER_INSTANCE_OCID"
    local VNIC_ID=$(oci container-instances container-instance get \
        --container-instance-id "$CONTAINER_INSTANCE_OCID" \
        --query 'data.vnics[0]."vnic-id"' --raw-output 2>/dev/null || echo "")
    
    local CONTAINER_IP=""
    if [ -n "$VNIC_ID" ] && [ "$VNIC_ID" != "null" ]; then
        cmd "oci network vnic get --vnic-id $VNIC_ID"
        CONTAINER_IP=$(oci network vnic get \
            --vnic-id "$VNIC_ID" \
            --query 'data."private-ip"' --raw-output 2>/dev/null || echo "")
        log "Container IP: $CONTAINER_IP"
    fi
    
    # Remove backend from load balancer if LB_OCID is set
    if [ -n "$LB_OCID" ] && [ -n "$CONTAINER_IP" ]; then
        echo ""
        log "Removing backend from Load Balancer..."
        remove_old_backend "$CONTAINER_IP"
    fi
    
    # Destroy container instance
    echo ""
    destroy_existing_instance
    
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "✅ Undeployment complete!"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Main execution
if [ "$DEPLOY_MODE" == "deploy" ]; then
    deploy
elif [ "$DEPLOY_MODE" == "undeploy" ]; then
    undeploy
elif [ "$DEPLOY_MODE" == "status" ]; then
    log "Container Instance Status:"
    oci container-instances container-instance list --compartment-id "$OCI_COMPARTMENT_OCID" --display-name "$DISPLAY_NAME" --lifecycle-state ACTIVE --query 'data[*].{"Display Name":"display-name","State":"lifecycle-state","Created":"time-created"}' --output table
fi
