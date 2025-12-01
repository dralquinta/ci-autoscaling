#!/bin/bash

# loadbalancer.sh - Manage OCI Load Balancer for autoscaling-demo
# Usage: ./loadbalancer.sh [--create|--destroy]

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
if [ -z "$OCI_COMPARTMENT_OCID" ] || [ -z "$LB_SUBNET_OCID" ]; then
    error "Required environment variables are not set. Please source deploy.env first:
    
    source deploy.env
    
Then run this script again."
fi

# Configuration from environment variables
SUBNET_OCID="${LB_SUBNET_OCID}"
OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID}"

# Load Balancer Configuration
LB_DISPLAY_NAME="${LB_DISPLAY_NAME}"
LB_SHAPE="${LB_SHAPE}"
LB_MIN_BANDWIDTH_MBPS="${LB_MIN_BANDWIDTH_MBPS}"
LB_MAX_BANDWIDTH_MBPS="${LB_MAX_BANDWIDTH_MBPS}"
BACKEND_SET_NAME="${BACKEND_SET_NAME}"
LISTENER_NAME="${LISTENER_NAME}"
APP_PORT="${APP_PORT}"
HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH}"

# Show help menu
show_help() {
    cat << EOF
Usage: ./loadbalancer.sh [OPTIONS]

Manage OCI Load Balancer for autoscaling-demo application.

OPTIONS:
    --create     Create a new OCI Load Balancer with backend set and listener
    --destroy    Destroy the existing Load Balancer
    --help       Display this help message and exit

ENVIRONMENT VARIABLES:
    Required:
        OCI_COMPARTMENT_OCID       OCI Compartment OCID
        SUBNET_OCID                OCI Subnet OCID for load balancer
    
    Optional:
        LB_MIN_BANDWIDTH_MBPS      Minimum bandwidth in Mbps (default: 10)
        LB_MAX_BANDWIDTH_MBPS      Maximum bandwidth in Mbps (default: 100)

EXAMPLES:
    # Create load balancer
    ./loadbalancer.sh --create
    
    # Destroy load balancer
    export LB_OCID=ocid1.loadbalancer.oc1...
    ./loadbalancer.sh --destroy
    
    # Create with custom bandwidth
    export LB_MIN_BANDWIDTH_MBPS=50
    export LB_MAX_BANDWIDTH_MBPS=200
    ./loadbalancer.sh --create

WORKFLOW:
    1. Run ./loadbalancer.sh --create to create the load balancer
    2. Save the LB_OCID from the output
    3. Set LB_OCID in deploy.env for container deployments
    4. Run ./loadbalancer.sh --destroy when no longer needed

NOTES:
    - The load balancer is created with a backend set and HTTP listener
    - Backend set uses ROUND_ROBIN policy with health checks
    - Health checks target ${HEALTH_CHECK_PATH} on port ${APP_PORT}
    - Load balancer is created with public IP (not private)

EOF
    exit 0
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v oci &> /dev/null; then
        error "OCI CLI not found. Please install the OCI CLI."
    fi
    
    if [ -z "$OCI_COMPARTMENT_OCID" ]; then
        error "OCI_COMPARTMENT_OCID environment variable is not set"
    fi
    
    if [ -z "$SUBNET_OCID" ]; then
        error "SUBNET_OCID environment variable is not set"
    fi
    
    log "Prerequisites check passed"
}

# Create Load Balancer
create_load_balancer() {
    log "Creating Load Balancer..."
    
    # Check if load balancer already exists
    cmd "oci lb load-balancer list --compartment-id $OCI_COMPARTMENT_OCID --display-name $LB_DISPLAY_NAME --lifecycle-state ACTIVE"
    local EXISTING_LB=$(oci lb load-balancer list \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --display-name "$LB_DISPLAY_NAME" \
        --lifecycle-state "ACTIVE" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_LB" ] && [ "$EXISTING_LB" != "null" ]; then
        warn "Load Balancer already exists: $EXISTING_LB"
        LB_OCID="$EXISTING_LB"
        display_lb_info
        return 0
    fi
    
    info "Creating new Load Balancer with shape: $LB_SHAPE"
    info "Bandwidth: ${LB_MIN_BANDWIDTH_MBPS}-${LB_MAX_BANDWIDTH_MBPS} Mbps"
    info "Type: Public"
    
    cmd "oci lb load-balancer create --compartment-id $OCI_COMPARTMENT_OCID --display-name $LB_DISPLAY_NAME --shape-name $LB_SHAPE --shape-details '{\"minimumBandwidthInMbps\":$LB_MIN_BANDWIDTH_MBPS,\"maximumBandwidthInMbps\":$LB_MAX_BANDWIDTH_MBPS}' --subnet-ids '[\"$SUBNET_OCID\"]' --is-private false --wait-for-state SUCCEEDED"
    
    # Create Load Balancer
    set +e
    local CREATE_LB_OUTPUT=$(oci lb load-balancer create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --display-name "$LB_DISPLAY_NAME" \
        --shape-name "$LB_SHAPE" \
        --shape-details "{\"minimumBandwidthInMbps\":$LB_MIN_BANDWIDTH_MBPS,\"maximumBandwidthInMbps\":$LB_MAX_BANDWIDTH_MBPS}" \
        --subnet-ids "[\"$SUBNET_OCID\"]" \
        --is-private false \
        --wait-for-state SUCCEEDED 2>&1)
    
    local EXIT_CODE=$?
    set -e
    
    if [ $EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Load Balancer creation failed with error:${NC}"
        echo "$CREATE_LB_OUTPUT"
        error "Failed to create Load Balancer"
    fi
    
    # Extract Load Balancer OCID
    LB_OCID=$(echo "$CREATE_LB_OUTPUT" | grep -o 'ocid1\.loadbalancer[^"]*' | head -1)
    
    if [ -z "$LB_OCID" ]; then
        error "Failed to extract Load Balancer OCID from output"
    fi
    
    log "Created Load Balancer: $LB_OCID"
    
    # Wait for Load Balancer to be fully active
    log "Waiting for Load Balancer to be fully active..."
    sleep 30
    
    # Create backend set
    create_backend_set
    
    # Create HTTP listener
    create_listener
    
    # Display information
    display_lb_info
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
    
    log "Backend set '$BACKEND_SET_NAME' created successfully"
}

# Create HTTP listener
create_listener() {
    log "Creating HTTP listener '$LISTENER_NAME'..."
    
    cmd "oci lb listener create --load-balancer-id $LB_OCID --name $LISTENER_NAME --default-backend-set-name $BACKEND_SET_NAME --port 80 --protocol HTTP --wait-for-state SUCCEEDED"
    
    oci lb listener create \
        --load-balancer-id "$LB_OCID" \
        --name "$LISTENER_NAME" \
        --default-backend-set-name "$BACKEND_SET_NAME" \
        --port 80 \
        --protocol "HTTP" \
        --wait-for-state SUCCEEDED || error "Failed to create listener"
    
    log "HTTP listener '$LISTENER_NAME' created successfully"
}

# Display Load Balancer information
display_lb_info() {
    if [ -z "$LB_OCID" ]; then
        return 0
    fi
    
    log "Retrieving Load Balancer details..."
    
    cmd "oci lb load-balancer get --load-balancer-id $LB_OCID"
    local LB_PUBLIC_IP=$(oci lb load-balancer get \
        --load-balancer-id "$LB_OCID" \
        --query 'data."ip-addresses"[0]."ip-address"' \
        --raw-output 2>/dev/null || echo "")
    
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "✅ Load Balancer Created Successfully"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Display Name:  $LB_DISPLAY_NAME"
    log "OCID:          $LB_OCID"
    if [ -n "$LB_PUBLIC_IP" ] && [ "$LB_PUBLIC_IP" != "null" ]; then
        log "Public IP:     $LB_PUBLIC_IP"
        log "HTTP URL:      http://${LB_PUBLIC_IP}"
    fi
    log "Shape:         $LB_SHAPE"
    log "Bandwidth:     ${LB_MIN_BANDWIDTH_MBPS}-${LB_MAX_BANDWIDTH_MBPS} Mbps"
    log "Backend Set:   $BACKEND_SET_NAME"
    log "Listener:      $LISTENER_NAME (port 80)"
    log "Health Check:  HTTP ${HEALTH_CHECK_PATH}:${APP_PORT}"
    log "Type:          Public Load Balancer"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log "IMPORTANT: Save this Load Balancer OCID for container deployments:"
    echo ""
    echo -e "    ${GREEN}export LB_OCID=$LB_OCID${NC}"
    echo -e "    ${GREEN}echo 'export LB_OCID=$LB_OCID' >> deploy.env${NC}"
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ -n "$LB_PUBLIC_IP" ] && [ "$LB_PUBLIC_IP" != "null" ]; then
        echo ""
        log "Test the Load Balancer (after deploying containers):"
        echo ""
        echo -e "    ${BLUE}curl http://${LB_PUBLIC_IP}/api/health${NC}"
        echo -e "    ${BLUE}curl http://${LB_PUBLIC_IP}/api/info${NC}"
        echo ""
    fi
}

# Destroy Load Balancer
destroy_load_balancer() {
    if [ -z "$LB_OCID" ]; then
        # Try to find it by name
        log "LB_OCID not set, searching for Load Balancer by name..."
        cmd "oci lb load-balancer list --compartment-id $OCI_COMPARTMENT_OCID --display-name $LB_DISPLAY_NAME --all"
        LB_OCID=$(oci lb load-balancer list \
            --compartment-id "$OCI_COMPARTMENT_OCID" \
            --display-name "$LB_DISPLAY_NAME" \
            --all \
            --query 'data[0].id' \
            --raw-output 2>/dev/null || echo "")
        
        if [ -z "$LB_OCID" ] || [ "$LB_OCID" == "null" ]; then
            error "Could not find Load Balancer with name '$LB_DISPLAY_NAME'. Please set LB_OCID environment variable."
        fi
        
        log "Found Load Balancer: $LB_OCID"
    fi
    
    log "Destroying Load Balancer: $LB_OCID"
    warn "This will permanently delete the Load Balancer and all its configuration"
    
    cmd "oci lb load-balancer delete --load-balancer-id $LB_OCID --force --wait-for-state SUCCEEDED"
    
    oci lb load-balancer delete \
        --load-balancer-id "$LB_OCID" \
        --force \
        --wait-for-state SUCCEEDED || error "Failed to delete Load Balancer"
    
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "✅ Load Balancer Destroyed Successfully"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "OCID: $LB_OCID"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log "Remember to remove LB_OCID from deploy.env if you added it"
}

# Parse command line arguments
ACTION=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --create)
            ACTION="create"
            shift
            ;;
        --destroy)
            ACTION="destroy"
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

# Main execution
main() {
    if [ -z "$ACTION" ]; then
        error "No action specified. Use --create or --destroy. Run with --help for more information."
    fi
    
    log "Starting Load Balancer management for autoscaling-demo..."
    echo ""
    
    check_prerequisites
    echo ""
    
    case $ACTION in
        create)
            create_load_balancer
            ;;
        destroy)
            destroy_load_balancer
            ;;
        *)
            error "Invalid action: $ACTION"
            ;;
    esac
    
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "✅ Operation complete!"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Run main function
main
