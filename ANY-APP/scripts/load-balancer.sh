#!/bin/bash

# load-balancer.sh - Setup OCI Load Balancer for ANY-APP
# Usage: ./load-balancer.sh --create | --delete | --status

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

# Check if app.env is sourced
if [ -z "$OCI_COMPARTMENT_OCID" ] || [ -z "$SUBNET_OCID" ]; then
    error "Required environment variables are not set. Please source app.env first"
fi

show_help() {
    cat << EOF
Usage: ./load-balancer.sh [OPTIONS]

Setup and manage OCI Load Balancer for ANY-APP.

OPTIONS:
    --create            Create load balancer with backend set
    --delete            Delete load balancer
    --status            Show load balancer status
    --help              Display this help message

EXAMPLES:
    # Create load balancer
    source app.env
    ./load-balancer.sh --create
    
    # Check status
    ./load-balancer.sh --status
    
    # Delete load balancer
    ./load-balancer.sh --delete

EOF
    exit 0
}

# Function to check if LB exists
lb_exists() {
    if [ -n "$LB_OCID" ]; then
        local lb_state=$(oci lb load-balancer get \
            --load-balancer-id "${LB_OCID}" \
            --query 'data."lifecycle-state"' \
            --raw-output 2>/dev/null || echo "")
        
        if [ "$lb_state" = "ACTIVE" ]; then
            echo "$LB_OCID"
            return 0
        fi
    fi
    
    # Search by display name
    local found_ocid=$(oci lb load-balancer list \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --display-name "${LB_DISPLAY_NAME}" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$found_ocid" ] && [ "$found_ocid" != "null" ]; then
        echo "$found_ocid"
        return 0
    fi
    
    return 1
}

# Function to create load balancer
create_lb() {
    log "Creating OCI Load Balancer..."
    
    # Check if already exists
    if lb_ocid=$(lb_exists); then
        warn "Load balancer already exists: ${lb_ocid}"
        info "Add this to your app.env: export LB_OCID=\"${lb_ocid}\""
        return 0
    fi
    
    # Create load balancer
    info "Creating load balancer: ${LB_DISPLAY_NAME}"
    
    local lb_config=$(cat <<EOF
{
  "compartmentId": "${OCI_COMPARTMENT_OCID}",
  "displayName": "${LB_DISPLAY_NAME}",
  "shapeName": "${LB_SHAPE}",
  "subnetIds": ["${LB_SUBNET_OCID:-$SUBNET_OCID}"],
  "isPrivate": false,
  "backendSets": {
    "${BACKEND_SET_NAME}": {
      "policy": "ROUND_ROBIN",
      "healthChecker": {
        "protocol": "HTTP",
        "urlPath": "${HEALTH_CHECK_PATH}",
        "port": ${APP_PORT},
        "returnCode": 200,
        "intervalInMillis": 30000,
        "timeoutInMillis": 3000,
        "retries": 3
      }
    }
  },
  "listeners": {
    "${LISTENER_NAME}": {
      "defaultBackendSetName": "${BACKEND_SET_NAME}",
      "port": 80,
      "protocol": "HTTP"
    }
  }
}
EOF
)
    
    if [ "${LB_SHAPE}" = "flexible" ]; then
        lb_config=$(echo "$lb_config" | jq ". + {
            \"shapeDetails\": {
                \"minimumBandwidthInMbps\": ${LB_MIN_BANDWIDTH_MBPS},
                \"maximumBandwidthInMbps\": ${LB_MAX_BANDWIDTH_MBPS}
            }
        }")
    fi
    
    echo "$lb_config" | jq '.'
    
    local response=$(echo "$lb_config" | oci lb load-balancer create \
        --from-json file:///dev/stdin \
        --wait-for-state ACTIVE \
        --max-wait-seconds 900)
    
    local lb_ocid=$(echo "$response" | jq -r '.data.id')
    
    if [ -z "$lb_ocid" ] || [ "$lb_ocid" = "null" ]; then
        error "Failed to create load balancer"
    fi
    
    log "✅ Load balancer created successfully"
    info "Load Balancer OCID: ${lb_ocid}"
    
    # Get public IP
    local public_ip=$(echo "$response" | jq -r '.data."ip-addresses"[0]."ip-address"')
    info "Public IP: ${public_ip}"
    
    echo ""
    warn "IMPORTANT: Add this to your app.env file:"
    echo "export LB_OCID=\"${lb_ocid}\""
    echo ""
    info "You can now access your application at: http://${public_ip}"
}

# Function to delete load balancer
delete_lb() {
    log "Deleting load balancer..."
    
    local lb_ocid=$(lb_exists) || true
    
    if [ -z "$lb_ocid" ]; then
        warn "No load balancer found to delete"
        return 0
    fi
    
    info "Deleting load balancer: ${lb_ocid}"
    
    oci lb load-balancer delete \
        --load-balancer-id "${lb_ocid}" \
        --force \
        --wait-for-state DELETED \
        --max-wait-seconds 900
    
    log "✅ Load balancer deleted successfully"
}

# Function to show status
show_status() {
    log "Checking load balancer status..."
    
    local lb_ocid=$(lb_exists) || true
    
    if [ -z "$lb_ocid" ]; then
        info "No load balancer found"
        return 0
    fi
    
    info "Load Balancer OCID: ${lb_ocid}"
    
    # Get LB details
    oci lb load-balancer get \
        --load-balancer-id "${lb_ocid}" \
        --query 'data.{"Name":"display-name","State":"lifecycle-state","Shape":"shape-name","Public-IP":"ip-addresses[0].\"ip-address\""}' \
        --output table
    
    # Get backend set status
    info "\nBackend Set Status:"
    oci lb backend-set list \
        --load-balancer-id "${lb_ocid}" \
        --query 'data[].{Name:name,Policy:policy,BackendCount:backends | length(@)}' \
        --output table
    
    # Get backends
    info "\nBackends:"
    oci lb backend list \
        --load-balancer-id "${lb_ocid}" \
        --backend-set-name "${BACKEND_SET_NAME}" \
        --query 'data[].{"IP":"ip-address",Port:port,Status:"health-status"}' \
        --output table 2>/dev/null || warn "No backends found"
}

# Main execution
main() {
    case "${1:-}" in
        --create)
            create_lb
            ;;
        --delete)
            delete_lb
            ;;
        --status)
            show_status
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
