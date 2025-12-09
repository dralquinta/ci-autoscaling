#!/bin/bash

# setup-autoscaling.sh - Setup autoscaling for ANY-APP
# This script sets up OCI Functions, Alarms, and Notifications for autoscaling

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

# Check if autoscaling.env is sourced
if [ -z "$COMPARTMENT_OCID" ] || [ -z "$LB_OCID" ]; then
    error "Required environment variables are not set. Please source autoscaling.env first:
    
    cd autoscaling/
    source autoscaling.env
    
Then run this script again."
fi

show_help() {
    cat << EOF
Usage: ./setup-autoscaling.sh [OPTIONS]

Setup autoscaling infrastructure for ANY-APP on OCI Container Instances.

OPTIONS:
    --deploy            Deploy all autoscaling components (default)
    --undeploy          Remove all autoscaling components
    --status            Show status of autoscaling components
    --help              Display this help message

COMPONENTS:
    - OCI Functions Application
    - Scale-Up Function
    - Scale-Down Function
    - Notification Topic and Subscriptions
    - CPU High/Low Alarms
    - Memory High/Low Alarms

PREREQUISITES:
    - OCI CLI configured
    - Fn CLI installed
    - Docker installed
    - Functions service enabled
    - IAM policies configured

WORKFLOW:
    1. Source autoscaling.env with your configuration
    2. Run: ./setup-autoscaling.sh --deploy
    3. Wait for functions and alarms to be created
    4. Test autoscaling with load testing tools

EXAMPLES:
    # Deploy autoscaling
    source autoscaling.env
    ./setup-autoscaling.sh --deploy
    
    # Check status
    ./setup-autoscaling.sh --status
    
    # Remove autoscaling
    ./setup-autoscaling.sh --undeploy

For detailed documentation, see README.md
EOF
    exit 0
}

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check OCI CLI
    if ! command -v oci &> /dev/null; then
        error "OCI CLI is not installed. Please install it first."
    fi
    
    # Check Fn CLI
    if ! command -v fn &> /dev/null; then
        error "Fn CLI is not installed. Please install it first."
    fi
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed. Please install it first."
    fi
    
    log "✅ All prerequisites met"
}

# Function to setup Functions application
setup_functions_app() {
    log "Setting up Functions application..."
    
    # Check if app already exists
    local app_ocid=$(oci fn application list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --display-name "${FUNCTIONS_APP_NAME}" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$app_ocid" ] && [ "$app_ocid" != "null" ]; then
        info "Functions application already exists: ${app_ocid}"
        echo "$app_ocid"
        return 0
    fi
    
    info "Creating Functions application..."
    app_ocid=$(oci fn application create \
        --compartment-id "${COMPARTMENT_OCID}" \
        --display-name "${FUNCTIONS_APP_NAME}" \
        --subnet-ids "[\"${FUNCTIONS_SUBNET_OCID}\"]" \
        --query 'data.id' \
        --raw-output)
    
    log "✅ Functions application created: ${app_ocid}"
    echo "$app_ocid"
}

# Function to deploy scale-up function
deploy_scale_up_function() {
    local app_ocid=$1
    
    log "Deploying scale-up function..."
    
    cd "$(dirname "$0")"
    
    if [ ! -d "scale-up-function" ]; then
        error "scale-up-function directory not found"
    fi
    
    cd scale-up-function
    
    # Deploy function
    fn deploy --app "${FUNCTIONS_APP_NAME}" --verbose
    
    # Configure function environment variables
    fn config function "${FUNCTIONS_APP_NAME}" "${SCALE_UP_FUNCTION_NAME}" \
        COMPARTMENT_OCID "${COMPARTMENT_OCID}" \
        SUBNET_OCID "${SUBNET_OCID}" \
        AD_NAME "${AD_NAME}" \
        IMAGE_URI "${IMAGE_URI}" \
        CONTAINER_NAME "${CONTAINER_NAME}" \
        DISPLAY_NAME_PREFIX "${DISPLAY_NAME_PREFIX}" \
        MEMORY_GB "${MEMORY_GB}" \
        OCPUS "${OCPUS}" \
        APP_PORT "${APP_PORT}" \
        HEALTH_CHECK_PATH "${HEALTH_CHECK_PATH}" \
        LB_OCID "${LB_OCID}" \
        BACKEND_SET_NAME "${BACKEND_SET_NAME}" \
        MAX_INSTANCES "${MAX_INSTANCES}"
    
    cd ..
    log "✅ Scale-up function deployed"
}

# Function to deploy scale-down function
deploy_scale_down_function() {
    local app_ocid=$1
    
    log "Deploying scale-down function..."
    
    cd "$(dirname "$0")"
    
    if [ ! -d "scale-down-function" ]; then
        error "scale-down-function directory not found"
    fi
    
    cd scale-down-function
    
    # Deploy function
    fn deploy --app "${FUNCTIONS_APP_NAME}" --verbose
    
    # Configure function environment variables
    fn config function "${FUNCTIONS_APP_NAME}" "${SCALE_DOWN_FUNCTION_NAME}" \
        COMPARTMENT_OCID "${COMPARTMENT_OCID}" \
        DISPLAY_NAME_PREFIX "${DISPLAY_NAME_PREFIX}" \
        LB_OCID "${LB_OCID}" \
        BACKEND_SET_NAME "${BACKEND_SET_NAME}" \
        MIN_INSTANCES "${MIN_INSTANCES}"
    
    cd ..
    log "✅ Scale-down function deployed"
}

# Function to create notification topic
create_notification_topic() {
    log "Creating notification topic..."
    
    # Check if topic already exists
    local topic_ocid=$(oci ons topic list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --name "${NOTIFICATION_TOPIC_NAME}" \
        --lifecycle-state ACTIVE \
        --query 'data[0]."topic-id"' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$topic_ocid" ] && [ "$topic_ocid" != "null" ]; then
        info "Notification topic already exists: ${topic_ocid}"
        echo "$topic_ocid"
        return 0
    fi
    
    info "Creating notification topic..."
    topic_ocid=$(oci ons topic create \
        --compartment-id "${COMPARTMENT_OCID}" \
        --name "${NOTIFICATION_TOPIC_NAME}" \
        --query 'data."topic-id"' \
        --raw-output)
    
    log "✅ Notification topic created: ${topic_ocid}"
    
    # Subscribe email if provided
    if [ -n "$NOTIFICATION_EMAIL" ]; then
        info "Creating email subscription..."
        oci ons subscription create \
            --topic-id "${topic_ocid}" \
            --compartment-id "${COMPARTMENT_OCID}" \
            --protocol EMAIL \
            --subscription-endpoint "${NOTIFICATION_EMAIL}"
        info "Email subscription created. Check your email to confirm."
    fi
    
    echo "$topic_ocid"
}

# Function to create alarms
create_alarms() {
    local topic_ocid=$1
    
    log "Creating autoscaling alarms..."
    
    # Get load balancer metrics namespace
    local lb_namespace="oci_lbaas"
    
    # CPU Scale-Up Alarm
    info "Creating CPU scale-up alarm..."
    oci monitoring alarm create \
        --compartment-id "${COMPARTMENT_OCID}" \
        --display-name "CPU High - Scale Up" \
        --destinations "[\"${topic_ocid}\"]" \
        --is-enabled true \
        --metric-compartment-id "${COMPARTMENT_OCID}" \
        --namespace "${lb_namespace}" \
        --query-text "HttpRequests[${ALARM_EVALUATION_PERIOD}m].mean() > ${CPU_SCALE_UP_THRESHOLD}" \
        --severity "WARNING" \
        --repeat-notification-duration "PT2H" || warn "Failed to create CPU scale-up alarm"
    
    # CPU Scale-Down Alarm
    info "Creating CPU scale-down alarm..."
    oci monitoring alarm create \
        --compartment-id "${COMPARTMENT_OCID}" \
        --display-name "CPU Low - Scale Down" \
        --destinations "[\"${topic_ocid}\"]" \
        --is-enabled true \
        --metric-compartment-id "${COMPARTMENT_OCID}" \
        --namespace "${lb_namespace}" \
        --query-text "HttpRequests[${ALARM_EVALUATION_PERIOD}m].mean() < ${CPU_SCALE_DOWN_THRESHOLD}" \
        --severity "INFO" \
        --repeat-notification-duration "PT2H" || warn "Failed to create CPU scale-down alarm"
    
    log "✅ Alarms created successfully"
}

# Function to deploy all components
deploy_all() {
    log "Starting autoscaling deployment..."
    
    check_prerequisites
    
    local app_ocid=$(setup_functions_app)
    deploy_scale_up_function "$app_ocid"
    deploy_scale_down_function "$app_ocid"
    
    local topic_ocid=$(create_notification_topic)
    create_alarms "$topic_ocid"
    
    log "✅ Autoscaling deployment completed successfully"
    info "Your autoscaling infrastructure is now active"
}

# Function to undeploy all components
undeploy_all() {
    log "Removing autoscaling infrastructure..."
    
    # Delete alarms
    info "Deleting alarms..."
    local alarm_ids=$(oci monitoring alarm list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --query 'data[?contains("display-name", `Scale`)]|[].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$alarm_ids" ]; then
        for alarm_id in $alarm_ids; do
            oci monitoring alarm delete --alarm-id "$alarm_id" --force 2>/dev/null || true
        done
    fi
    
    # Delete notification topic
    info "Deleting notification topic..."
    local topic_ocid=$(oci ons topic list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --name "${NOTIFICATION_TOPIC_NAME}" \
        --query 'data[0]."topic-id"' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$topic_ocid" ] && [ "$topic_ocid" != "null" ]; then
        oci ons topic delete --topic-id "$topic_ocid" --force 2>/dev/null || true
    fi
    
    # Delete Functions application
    info "Deleting Functions application..."
    local app_ocid=$(oci fn application list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --display-name "${FUNCTIONS_APP_NAME}" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$app_ocid" ] && [ "$app_ocid" != "null" ]; then
        oci fn application delete --application-id "$app_ocid" --force 2>/dev/null || true
    fi
    
    log "✅ Autoscaling infrastructure removed"
}

# Function to show status
show_status() {
    log "Checking autoscaling status..."
    
    # Functions Application
    info "\n=== Functions Application ==="
    oci fn application list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --display-name "${FUNCTIONS_APP_NAME}" \
        --query 'data[].{"Name":"display-name","State":"lifecycle-state","OCID":id}' \
        --output table 2>/dev/null || warn "No Functions application found"
    
    # Notification Topic
    info "\n=== Notification Topic ==="
    oci ons topic list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --name "${NOTIFICATION_TOPIC_NAME}" \
        --query 'data[].{Name:name,State:"lifecycle-state",OCID:"topic-id"}' \
        --output table 2>/dev/null || warn "No notification topic found"
    
    # Alarms
    info "\n=== Alarms ==="
    oci monitoring alarm list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --query 'data[?contains("display-name", `Scale`)].{"Name":"display-name","Enabled":"is-enabled","Severity":severity}' \
        --output table 2>/dev/null || warn "No alarms found"
}

# Main execution
main() {
    case "${1:-}" in
        --deploy)
            deploy_all
            ;;
        --undeploy)
            undeploy_all
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
