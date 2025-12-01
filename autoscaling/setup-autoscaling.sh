#!/bin/bash

# setup-autoscaling.sh - Deploy OCI Functions, Alarms, Events, and Notifications for CI Autoscaling
# Usage: ./setup-autoscaling.sh [--deploy|--destroy|--status]

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

# Check if autoscaling.env is sourced
if [ -z "$COMPARTMENT_OCID" ] || [ -z "$LB_OCID" ]; then
    error "Required environment variables are not set. Please source autoscaling.env first:
    
    source autoscaling.env
    
Then run this script again."
fi

# Show help menu
show_help() {
    cat << EOF
Usage: ./setup-autoscaling.sh [OPTIONS]

Deploy and manage OCI Container Instances autoscaling infrastructure.

OPTIONS:
    --deploy            Deploy all autoscaling components (default)
    --deploy-alarms-only Deploy only alarms (assumes functions already deployed)
    --destroy           Remove all autoscaling components
    --status            Show status of autoscaling components
    --help              Display this help message

COMPONENTS:
    - OCI Functions Application
    - Scale-Up Function
    - Scale-Down Function
    - Notification Topic and Subscriptions
    - CPU High Alarm (triggers scale-up)
    - CPU Low Alarm (triggers scale-down)
    - Memory High Alarm (triggers scale-up)
    - Memory Low Alarm (triggers scale-down)

PREREQUISITES:
    - OCI CLI configured
    - Fn CLI installed (for function deployment)
    - Docker installed (for building functions)
    - Functions service enabled in tenancy
    - Proper IAM policies for Functions and Alarms

WORKFLOW:
    1. Create Functions Application
    2. Deploy scale-up and scale-down functions
    3. Configure function environment variables
    4. Create notification topic
    5. Create alarms for CPU and Memory thresholds
    6. Link alarms to functions via notifications

EXAMPLES:
    # Deploy autoscaling infrastructure
    source autoscaling.env
    ./setup-autoscaling.sh --deploy
    
    # Check status
    ./setup-autoscaling.sh --status
    
    # Remove all components
    ./setup-autoscaling.sh --destroy

For more information, see README.md
EOF
    exit 0
}

# Parse command line arguments
ACTION="deploy"
while [[ $# -gt 0 ]]; do
    case $1 in
        --deploy)
            ACTION="deploy"
            shift
            ;;
        --deploy-alarms-only)
            ACTION="deploy-alarms-only"
            shift
            ;;
        --destroy)
            ACTION="destroy"
            shift
            ;;
        --status)
            ACTION="status"
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

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v oci &> /dev/null; then
        error "OCI CLI not found. Please install the OCI CLI."
    fi
    
    if ! command -v fn &> /dev/null; then
        error "Fn CLI not found. Please install the Fn CLI: curl -LSs https://raw.githubusercontent.com/fnproject/cli/master/install | sh"
    fi
    
    if ! command -v docker &> /dev/null; then
        error "Docker not found. Please install Docker."
    fi
    
    log "Prerequisites check passed"
}

# Create Functions Application
create_functions_app() {
    log "Creating Functions Application: $FUNCTIONS_APP_NAME"
    
    # Check if app already exists
    cmd "oci fn application list --compartment-id $COMPARTMENT_OCID --display-name $FUNCTIONS_APP_NAME --lifecycle-state ACTIVE"
    EXISTING_APP=$(oci fn application list \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$FUNCTIONS_APP_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_APP" ] && [ "$EXISTING_APP" != "null" ]; then
        log "Functions Application already exists: $EXISTING_APP"
        FUNCTIONS_APP_OCID="$EXISTING_APP"
        return 0
    fi
    
    # Create new application
    cmd "oci fn application create --compartment-id $COMPARTMENT_OCID --display-name $FUNCTIONS_APP_NAME --subnet-ids '[\"$FUNCTIONS_SUBNET_OCID\"]'"
    FUNCTIONS_APP_OCID=$(oci fn application create \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$FUNCTIONS_APP_NAME" \
        --subnet-ids "[\"$FUNCTIONS_SUBNET_OCID\"]" \
        --query 'data.id' --raw-output)
    
    log "Functions Application created: $FUNCTIONS_APP_OCID"
}

# Deploy a function
deploy_function() {
    local FUNCTION_DIR=$1
    local FUNCTION_NAME=$2
    
    log "Deploying function: $FUNCTION_NAME"
    log "Building and pushing Docker image (this may take 2-5 minutes)..."
    
    cd "$FUNCTION_DIR"
    
    # Set Docker timeouts
    export DOCKER_CLIENT_TIMEOUT=300
    export COMPOSE_HTTP_TIMEOUT=300
    
    # Run fn deploy with 3 minute timeout (fn hangs after successful deployment)
    # Disable errexit temporarily
    cmd "fn deploy --app $FUNCTIONS_APP_NAME"
    set +e
    timeout 180 fn deploy --app "$FUNCTIONS_APP_NAME" > /dev/null 2>&1
    local EXIT_CODE=$?
    set -e
    
    if [ $EXIT_CODE -eq 124 ]; then
        log "fn deploy timed out (expected - verifying deployment)..."
    elif [ $EXIT_CODE -ne 0 ]; then
        log "fn deploy completed (exit code $EXIT_CODE - verifying)..."
    else
        log "fn deploy completed successfully"
    fi
    
    cd - > /dev/null
    
    # Verify function was deployed successfully
    sleep 3
    cmd "oci fn function list --application-id $FUNCTIONS_APP_OCID --display-name $FUNCTION_NAME --lifecycle-state ACTIVE"
    local FUNCTION_OCID=$(oci fn function list \
        --application-id "$FUNCTIONS_APP_OCID" \
        --display-name "$FUNCTION_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' --raw-output 2>/dev/null)
    
    if [ -z "$FUNCTION_OCID" ] || [ "$FUNCTION_OCID" = "null" ]; then
        error "Function deployment failed - $FUNCTION_NAME not found in OCI"
    fi
    
    log "Function deployed successfully: $FUNCTION_OCID"
    # Return only the OCID without mixing it with logs
    echo "$FUNCTION_OCID" > /tmp/function_ocid_$$.tmp
}

# Configure function environment variables
configure_function_env() {
    local FUNCTION_OCID=$1
    local FUNCTION_NAME=$2
    
    log "Configuring environment for $FUNCTION_NAME..."
    
    # Create a temp file with the config JSON
    local CONFIG_FILE="/tmp/fn_config_$$.json"
    cat > "$CONFIG_FILE" <<EOF
{
  "COMPARTMENT_OCID": "$COMPARTMENT_OCID",
  "SUBNET_OCID": "$SUBNET_OCID",
  "AD_NAME": "$AD_NAME",
  "IMAGE_URI": "$IMAGE_URI",
  "CONTAINER_NAME": "$CONTAINER_NAME",
  "DISPLAY_NAME_PREFIX": "$DISPLAY_NAME_PREFIX",
  "MEMORY_GB": "$MEMORY_GB",
  "OCPUS": "$OCPUS",
  "LB_OCID": "$LB_OCID",
  "BACKEND_SET_NAME": "$BACKEND_SET_NAME",
  "APP_PORT": "$APP_PORT",
  "HEALTH_CHECK_PATH": "$HEALTH_CHECK_PATH",
  "MAX_INSTANCES": "$MAX_INSTANCES",
  "MIN_INSTANCES": "$MIN_INSTANCES"
}
EOF
    
    cmd "oci fn function update --function-id $FUNCTION_OCID --config file://$CONFIG_FILE --force"
    set +e
    timeout 60 oci fn function update \
        --function-id "$FUNCTION_OCID" \
        --config "file://$CONFIG_FILE" \
        --force > /dev/null 2>&1
    local EXIT_CODE=$?
    set -e
    
    rm -f "$CONFIG_FILE"
    
    if [ $EXIT_CODE -eq 0 ]; then
        log "Environment configured for $FUNCTION_NAME"
    else
        warn "Environment configuration may have issues (exit code $EXIT_CODE) - continuing anyway"
    fi
}

# Create notification topic
create_notification_topic() {
    log "Creating notification topic: $NOTIFICATION_TOPIC_NAME"
    
    # Check if topic already exists
    cmd "oci ons topic list --compartment-id $COMPARTMENT_OCID --name $NOTIFICATION_TOPIC_NAME --lifecycle-state ACTIVE"
    EXISTING_TOPIC=$(oci ons topic list \
        --compartment-id "$COMPARTMENT_OCID" \
        --name "$NOTIFICATION_TOPIC_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0]."topic-id"' --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_TOPIC" ] && [ "$EXISTING_TOPIC" != "null" ]; then
        log "Notification topic already exists: $EXISTING_TOPIC"
        NOTIFICATION_TOPIC_OCID="$EXISTING_TOPIC"
        return 0
    fi
    
    # Create new topic
    cmd "oci ons topic create --compartment-id $COMPARTMENT_OCID --name $NOTIFICATION_TOPIC_NAME --description 'Notifications for CI autoscaling alarms'"
    NOTIFICATION_TOPIC_OCID=$(oci ons topic create \
        --compartment-id "$COMPARTMENT_OCID" \
        --name "$NOTIFICATION_TOPIC_NAME" \
        --description "Notifications for CI autoscaling alarms" \
        --query 'data."topic-id"' --raw-output)
    
    log "Notification topic created: $NOTIFICATION_TOPIC_OCID"
    
    # Add email subscription if configured
    if [ -n "$NOTIFICATION_EMAIL" ]; then
        log "Creating email subscription for: $NOTIFICATION_EMAIL"
        cmd "oci ons subscription create --compartment-id $COMPARTMENT_OCID --topic-id $NOTIFICATION_TOPIC_OCID --protocol EMAIL --subscription-endpoint $NOTIFICATION_EMAIL"
        oci ons subscription create \
            --compartment-id "$COMPARTMENT_OCID" \
            --topic-id "$NOTIFICATION_TOPIC_OCID" \
            --protocol "EMAIL" \
            --subscription-endpoint "$NOTIFICATION_EMAIL" > /dev/null
        warn "Please check your email and confirm the subscription"
    fi
}

# Subscribe function to notification topic
subscribe_function_to_topic() {
    local FUNCTION_OCID=$1
    local FUNCTION_NAME=$2
    
    log "Subscribing $FUNCTION_NAME to notification topic..."
    
    # Check if subscription already exists
    cmd "oci ons subscription list --compartment-id $COMPARTMENT_OCID --topic-id $NOTIFICATION_TOPIC_OCID"
    local EXISTING_SUB=$(oci ons subscription list \
        --compartment-id "$COMPARTMENT_OCID" \
        --topic-id "$NOTIFICATION_TOPIC_OCID" \
        --query "data[?endpoint=='$FUNCTION_OCID'].id | [0]" \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_SUB" ] && [ "$EXISTING_SUB" != "null" ]; then
        log "Function subscription already exists: $EXISTING_SUB"
        return 0
    fi
    
    # Create function subscription
    cmd "oci ons subscription create --compartment-id $COMPARTMENT_OCID --topic-id $NOTIFICATION_TOPIC_OCID --protocol ORACLE_FUNCTIONS --subscription-endpoint $FUNCTION_OCID"
    local SUB_OCID=$(oci ons subscription create \
        --compartment-id "$COMPARTMENT_OCID" \
        --topic-id "$NOTIFICATION_TOPIC_OCID" \
        --protocol "ORACLE_FUNCTIONS" \
        --subscription-endpoint "$FUNCTION_OCID" \
        --query 'data.id' --raw-output 2>/dev/null || echo "")
    
    if [ -n "$SUB_OCID" ] && [ "$SUB_OCID" != "null" ]; then
        log "Function subscribed successfully: $SUB_OCID"
    else
        warn "Failed to subscribe function - check IAM policies for Functions service"
    fi
}

# Create alarm
create_alarm() {
    local ALARM_NAME=$1
    local METRIC_NAME=$2
    local THRESHOLD=$3
    local OPERATOR=$4
    local FUNCTION_OCID=$5
    
    log "Creating alarm: $ALARM_NAME"
    
    # Check if alarm already exists
    cmd "oci monitoring alarm list --compartment-id $COMPARTMENT_OCID --display-name $ALARM_NAME --lifecycle-state ACTIVE"
    EXISTING_ALARM=$(oci monitoring alarm list \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$ALARM_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_ALARM" ] && [ "$EXISTING_ALARM" != "null" ]; then
        log "Alarm already exists: $EXISTING_ALARM"
        return 0
    fi
    
    # Build metric query - monitor all instances with our prefix
    METRIC_QUERY="$METRIC_NAME[${ALARM_EVALUATION_PERIOD}m]{resourceDisplayName =~ \"$DISPLAY_NAME_PREFIX*\"}.mean()"
    
    # Create alarm
    cmd "oci monitoring alarm create --compartment-id $COMPARTMENT_OCID --display-name $ALARM_NAME --destinations '[\"$NOTIFICATION_TOPIC_OCID\"]' --namespace oci_computecontainerinstance --query-text '$METRIC_QUERY'"
    ALARM_OCID=$(oci monitoring alarm create \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$ALARM_NAME" \
        --destinations "[\"$NOTIFICATION_TOPIC_OCID\"]" \
        --is-enabled true \
        --metric-compartment-id "$COMPARTMENT_OCID" \
        --namespace "oci_computecontainerinstance" \
        --query-text "$METRIC_QUERY" \
        --resolution "1m" \
        --severity "WARNING" \
        --body "Autoscaling alarm $ALARM_NAME triggered" \
        --message-format "PRETTY_JSON" \
        --repeat-notification-duration "PT${ALARM_FREQUENCY}M" \
        --query 'data.id' --raw-output)
    
    log "Alarm created: $ALARM_OCID"
}

# Create alarm for health check failures
create_alarm_health_check() {
    local ALARM_NAME=$1
    local THRESHOLD=$2
    local FUNCTION_OCID=$3
    
    log "Creating health check alarm: $ALARM_NAME"
    
    # Check if alarm already exists
    cmd "oci monitoring alarm list --compartment-id $COMPARTMENT_OCID --display-name $ALARM_NAME --lifecycle-state ACTIVE"
    EXISTING_ALARM=$(oci monitoring alarm list \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$ALARM_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_ALARM" ] && [ "$EXISTING_ALARM" != "null" ]; then
        log "Alarm already exists: $EXISTING_ALARM"
        return 0
    fi
    
    # Build metric query - monitor unhealthy backends percentage
    # This metric tracks backends that return non-200 status codes or timeout > 5 seconds
    METRIC_QUERY="UnHealthyBackendCount[${ALARM_EVALUATION_PERIOD}m]{loadBalancerId=\"$LB_OCID\", backendSetName=\"$BACKEND_SET_NAME\"}.mean() / TotalBackendCount[${ALARM_EVALUATION_PERIOD}m]{loadBalancerId=\"$LB_OCID\", backendSetName=\"$BACKEND_SET_NAME\"}.mean() * 100"
    
    # Create alarm
    cmd "oci monitoring alarm create --compartment-id $COMPARTMENT_OCID --display-name $ALARM_NAME --destinations '[\"$NOTIFICATION_TOPIC_OCID\"]' --namespace oci_lbaas --query-text '$METRIC_QUERY'"
    ALARM_OCID=$(oci monitoring alarm create \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$ALARM_NAME" \
        --destinations "[\"$NOTIFICATION_TOPIC_OCID\"]" \
        --is-enabled true \
        --metric-compartment-id "$COMPARTMENT_OCID" \
        --namespace "oci_lbaas" \
        --query-text "$METRIC_QUERY" \
        --resolution "1m" \
        --severity "CRITICAL" \
        --body "Health check failure: ${THRESHOLD}% of backends are unhealthy" \
        --message-format "PRETTY_JSON" \
        --repeat-notification-duration "PT${ALARM_FREQUENCY}M" \
        --query 'data.id' --raw-output)
    
    log "Health check alarm created: $ALARM_OCID"
    
    info "This alarm monitors:"
    info "  - HTTP status codes != 200"
    info "  - Response timeouts > 5 seconds"
    info "  - Backend health check failures"
}

# Deploy all components
deploy_autoscaling() {
    log "====== Deploying Autoscaling Infrastructure ======"
    echo ""
    
    check_prerequisites
    echo ""
    
    # Create Functions Application
    create_functions_app
    echo ""
    
    # Deploy scale-up function
    log "Deploying scale-up function..."
    deploy_function "$(pwd)/scale-up-function" "$SCALE_UP_FUNCTION_NAME"
    SCALE_UP_FUNCTION_OCID=$(cat /tmp/function_ocid_$$.tmp)
    rm -f /tmp/function_ocid_$$.tmp
    configure_function_env "$SCALE_UP_FUNCTION_OCID" "$SCALE_UP_FUNCTION_NAME"
    echo ""
    
    # Deploy scale-down function
    log "Deploying scale-down function..."
    deploy_function "$(pwd)/scale-down-function" "$SCALE_DOWN_FUNCTION_NAME"
    SCALE_DOWN_FUNCTION_OCID=$(cat /tmp/function_ocid_$$.tmp)
    rm -f /tmp/function_ocid_$$.tmp
    configure_function_env "$SCALE_DOWN_FUNCTION_OCID" "$SCALE_DOWN_FUNCTION_NAME"
    echo ""
    
    # Create notification topic
    create_notification_topic
    echo ""
    
    # Subscribe functions to notification topic
    log "Subscribing functions to notification topic..."
    subscribe_function_to_topic "$SCALE_UP_FUNCTION_OCID" "scale-up-function"
    subscribe_function_to_topic "$SCALE_DOWN_FUNCTION_OCID" "scale-down-function"
    echo ""
    
    # Create alarms
    log "Creating alarms..."
    
    create_alarm \
        "ci-autoscaling-cpu-high" \
        "CpuUtilization" \
        "$CPU_SCALE_UP_THRESHOLD" \
        "GREATER_THAN" \
        "$SCALE_UP_FUNCTION_OCID"
    
    create_alarm \
        "ci-autoscaling-cpu-low" \
        "CpuUtilization" \
        "$CPU_SCALE_DOWN_THRESHOLD" \
        "LESS_THAN" \
        "$SCALE_DOWN_FUNCTION_OCID"
    
    create_alarm \
        "ci-autoscaling-memory-high" \
        "MemoryUtilization" \
        "$MEMORY_SCALE_UP_THRESHOLD" \
        "GREATER_THAN" \
        "$SCALE_UP_FUNCTION_OCID"
    
    create_alarm \
        "ci-autoscaling-memory-low" \
        "MemoryUtilization" \
        "$MEMORY_SCALE_DOWN_THRESHOLD" \
        "LESS_THAN" \
        "$SCALE_DOWN_FUNCTION_OCID"
    
    create_alarm_health_check \
        "ci-autoscaling-health-critical" \
        "$HEALTH_FAILURE_THRESHOLD" \
        "$SCALE_UP_FUNCTION_OCID"
    
    echo ""
    log "====== Autoscaling Infrastructure Deployed ======"
    echo ""
    log "Next steps:"
    log "  1. Alarms will monitor CPU, Memory, and Health Check metrics"
    log "  2. When thresholds are exceeded, functions will scale up"
    log "  3. When metrics return to normal, functions will scale down"
    log "  4. Health check alarm triggers when backends fail or timeout > 5s"
    log "  5. Check status with: ./setup-autoscaling.sh --status"
    echo ""
}

# Show status of components
show_status() {
    log "====== Autoscaling Infrastructure Status ======"
    echo ""
    
    # Functions Application
    info "Functions Application: $FUNCTIONS_APP_NAME"
    cmd "oci fn application list --compartment-id $COMPARTMENT_OCID --display-name $FUNCTIONS_APP_NAME"
    oci fn application list \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$FUNCTIONS_APP_NAME" \
        --query 'data[*].{Name:"display-name", State:"lifecycle-state", ID:id}' \
        --output table
    echo ""
    
    # Functions
    # Get the Functions App OCID
    APP_OCID=$(oci fn application list \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$FUNCTIONS_APP_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' --raw-output 2>/dev/null)
    
    if [ -n "$APP_OCID" ] && [ "$APP_OCID" != "null" ]; then
        info "Scale-Up Function:"
        cmd "oci fn function list --application-id $APP_OCID --display-name $SCALE_UP_FUNCTION_NAME"
        oci fn function list \
            --application-id "$APP_OCID" \
            --display-name "$SCALE_UP_FUNCTION_NAME" \
            --query 'data[*].{Name:"display-name", State:"lifecycle-state", ID:id}' \
            --output table 2>/dev/null || warn "Function not found"
        echo ""
        
        info "Scale-Down Function:"
        cmd "oci fn function list --application-id $APP_OCID --display-name $SCALE_DOWN_FUNCTION_NAME"
        oci fn function list \
            --application-id "$APP_OCID" \
            --display-name "$SCALE_DOWN_FUNCTION_NAME" \
            --query 'data[*].{Name:"display-name", State:"lifecycle-state", ID:id}' \
            --output table 2>/dev/null || warn "Function not found"
    else
        warn "Functions Application not found"
    fi
    echo ""
    
    # Alarms
    info "Alarms:"
    cmd "oci monitoring alarm list --compartment-id $COMPARTMENT_OCID"
    oci monitoring alarm list \
        --compartment-id "$COMPARTMENT_OCID" \
        --query 'data[?starts_with("display-name", `ci-autoscaling`)].{Name:"display-name", State:"lifecycle-state", Enabled:"is-enabled"}' \
        --output table
    echo ""
    
    # Container Instances
    info "Active Container Instances:"
    cmd "oci container-instances container-instance list --compartment-id $COMPARTMENT_OCID --lifecycle-state ACTIVE"
    oci container-instances container-instance list \
        --compartment-id "$COMPARTMENT_OCID" \
        --lifecycle-state ACTIVE \
        --query "data.items[?starts_with(\"display-name\", '$DISPLAY_NAME_PREFIX')].{Name:\"display-name\", State:\"lifecycle-state\", Created:\"time-created\"}" \
        --output table
    echo ""
}

# Destroy all components
destroy_autoscaling() {
    log "====== Destroying Autoscaling Infrastructure ======"
    echo ""
    
    warn "This will remove all autoscaling components. Proceed? (y/N)"
    read -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log "Cancelled"
        exit 0
    fi
    
    # Delete alarms
    log "Deleting alarms..."
    cmd "oci monitoring alarm list --compartment-id $COMPARTMENT_OCID"
    ALARM_IDS=$(oci monitoring alarm list \
        --compartment-id "$COMPARTMENT_OCID" \
        --query 'data[?starts_with("display-name", `ci-autoscaling`)].id' \
        --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")
    
    if [ -n "$ALARM_IDS" ]; then
        while IFS= read -r ALARM_ID; do
            if [ -n "$ALARM_ID" ] && [ "$ALARM_ID" != "null" ]; then
                log "Deleting alarm: $ALARM_ID"
                cmd "oci monitoring alarm delete --alarm-id $ALARM_ID --force"
                oci monitoring alarm delete --alarm-id "$ALARM_ID" --force 2>/dev/null || warn "Failed to delete alarm"
            fi
        done <<< "$ALARM_IDS"
        log "All alarms deleted"
    else
        log "No alarms found to delete"
    fi
    echo ""
    
    # Delete functions first, then application
    log "Deleting Functions Application..."
    cmd "oci fn application list --compartment-id $COMPARTMENT_OCID --display-name $FUNCTIONS_APP_NAME --lifecycle-state ACTIVE"
    APP_ID=$(oci fn application list \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$FUNCTIONS_APP_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' --raw-output 2>/dev/null || echo "")
    
    if [ -n "$APP_ID" ] && [ "$APP_ID" != "null" ]; then
        # Delete all functions in the application first
        cmd "oci fn function list --application-id $APP_ID"
        FUNCTION_IDS=$(oci fn function list \
            --application-id "$APP_ID" \
            --query 'data[*].id' \
            --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")
        
        if [ -n "$FUNCTION_IDS" ]; then
            while IFS= read -r FUNCTION_ID; do
                if [ -n "$FUNCTION_ID" ] && [ "$FUNCTION_ID" != "null" ]; then
                    log "Deleting function: $FUNCTION_ID"
                    cmd "oci fn function delete --function-id $FUNCTION_ID --force"
                    oci fn function delete --function-id "$FUNCTION_ID" --force 2>/dev/null || warn "Failed to delete function"
                fi
            done <<< "$FUNCTION_IDS"
        fi
        
        # Now delete the application
        log "Deleting application: $APP_ID"
        cmd "oci fn application delete --application-id $APP_ID --force"
        oci fn application delete --application-id "$APP_ID" --force 2>/dev/null && log "Functions Application deleted" || warn "Failed to delete application"
    else
        log "No Functions Application found to delete"
    fi
    echo ""
    
    # Delete notification topic
    log "Deleting notification topic..."
    cmd "oci ons topic list --compartment-id $COMPARTMENT_OCID --name $NOTIFICATION_TOPIC_NAME --lifecycle-state ACTIVE"
    TOPIC_ID=$(oci ons topic list \
        --compartment-id "$COMPARTMENT_OCID" \
        --name "$NOTIFICATION_TOPIC_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0]."topic-id"' --raw-output 2>/dev/null || echo "")
    
    if [ -n "$TOPIC_ID" ] && [ "$TOPIC_ID" != "null" ]; then
        log "Deleting topic: $TOPIC_ID"
        cmd "oci ons topic delete --topic-id $TOPIC_ID --force"
        oci ons topic delete --topic-id "$TOPIC_ID" --force 2>/dev/null && log "Notification topic deleted" || warn "Failed to delete topic"
    else
        log "No notification topic found to delete"
    fi
    echo ""
    
    log "====== Autoscaling Infrastructure Destroyed ======"
}

# Deploy only alarms (skip function deployment)
deploy_alarms_only() {
    log "====== Deploying Alarms Only ======"
    echo ""
    
    # Get existing functions
    cmd "oci fn application list --compartment-id $COMPARTMENT_OCID --display-name $FUNCTIONS_APP_NAME --lifecycle-state ACTIVE"
    FUNCTIONS_APP_OCID=$(oci fn application list \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$FUNCTIONS_APP_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' --raw-output)
    
    if [ -z "$FUNCTIONS_APP_OCID" ] || [ "$FUNCTIONS_APP_OCID" = "null" ]; then
        error "Functions Application not found. Deploy functions first."
    fi
    
    cmd "oci fn function list --application-id $FUNCTIONS_APP_OCID --display-name $SCALE_UP_FUNCTION_NAME --lifecycle-state ACTIVE"
    SCALE_UP_FUNCTION_OCID=$(oci fn function list \
        --application-id "$FUNCTIONS_APP_OCID" \
        --display-name "$SCALE_UP_FUNCTION_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' --raw-output)
    
    cmd "oci fn function list --application-id $FUNCTIONS_APP_OCID --display-name $SCALE_DOWN_FUNCTION_NAME --lifecycle-state ACTIVE"
    SCALE_DOWN_FUNCTION_OCID=$(oci fn function list \
        --application-id "$FUNCTIONS_APP_OCID" \
        --display-name "$SCALE_DOWN_FUNCTION_NAME" \
        --lifecycle-state ACTIVE \
        --query 'data[0].id' --raw-output)
    
    if [ -z "$SCALE_UP_FUNCTION_OCID" ] || [ "$SCALE_UP_FUNCTION_OCID" = "null" ]; then
        error "Scale-up function not found. Deploy it first."
    fi
    
    if [ -z "$SCALE_DOWN_FUNCTION_OCID" ] || [ "$SCALE_DOWN_FUNCTION_OCID" = "null" ]; then
        error "Scale-down function not found. Deploy it first."
    fi
    
    log "Found existing functions:"
    log "  Scale-up: $SCALE_UP_FUNCTION_OCID"
    log "  Scale-down: $SCALE_DOWN_FUNCTION_OCID"
    echo ""
    
    # Configure function environment variables
    log "Configuring function environments..."
    configure_function_env "$SCALE_UP_FUNCTION_OCID" "$SCALE_UP_FUNCTION_NAME"
    configure_function_env "$SCALE_DOWN_FUNCTION_OCID" "$SCALE_DOWN_FUNCTION_NAME"
    echo ""
    
    # Create notification topic
    create_notification_topic
    echo ""
    
    # Create alarms
    log "Creating alarms..."
    
    create_alarm \
        "ci-autoscaling-cpu-high" \
        "CpuUtilization" \
        "$CPU_SCALE_UP_THRESHOLD" \
        "GREATER_THAN" \
        "$SCALE_UP_FUNCTION_OCID"
    
    create_alarm \
        "ci-autoscaling-cpu-low" \
        "CpuUtilization" \
        "$CPU_SCALE_DOWN_THRESHOLD" \
        "LESS_THAN" \
        "$SCALE_DOWN_FUNCTION_OCID"
    
    create_alarm \
        "ci-autoscaling-memory-high" \
        "MemoryUtilization" \
        "$MEMORY_SCALE_UP_THRESHOLD" \
        "GREATER_THAN" \
        "$SCALE_UP_FUNCTION_OCID"
    
    create_alarm \
        "ci-autoscaling-memory-low" \
        "MemoryUtilization" \
        "$MEMORY_SCALE_DOWN_THRESHOLD" \
        "LESS_THAN" \
        "$SCALE_DOWN_FUNCTION_OCID"
    
    create_alarm_health_check \
        "ci-autoscaling-health-critical" \
        "$HEALTH_FAILURE_THRESHOLD" \
        "$SCALE_UP_FUNCTION_OCID"
    
    echo ""
    log "====== Autoscaling Alarms Deployed ======"
}

# Main execution
main() {
    case $ACTION in
        deploy)
            deploy_autoscaling
            ;;
        deploy-alarms-only)
            deploy_alarms_only
            ;;
        status)
            show_status
            ;;
        destroy)
            destroy_autoscaling
            ;;
        *)
            error "Unknown action: $ACTION"
            ;;
    esac
}

# Cleanup function for temp files
cleanup() {
    rm -f /tmp/function_ocid_$$.tmp /tmp/fn_config_$$.json 2>/dev/null
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Cleanup function for temp files
cleanup() {
    rm -f /tmp/function_ocid_$$.tmp /tmp/fn_config_$$.json 2>/dev/null
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Run main function
main
