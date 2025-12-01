#!/bin/bash

###############################################################################
# Setup IAM Policies for Autoscaling Functions
#
# This script creates:
# 1. Dynamic Group for autoscaling functions
# 2. Policy statements allowing functions to manage container instances and load balancers
###############################################################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Display command before executing
cmd() {
    echo -e "${YELLOW}[CMD]${NC} ${YELLOW}$1${NC}"
    eval "$1"
}

# Load configuration
if [ -f "autoscaling.env" ]; then
    source autoscaling.env
else
    error "autoscaling.env file not found. Please run from autoscaling/ directory."
    exit 1
fi

# Get tenancy OCID and home region
TENANCY_OCID=$(oci iam compartment list --query "data[0].\"compartment-id\"" --raw-output)
HOME_REGION="us-ashburn-1"
log "Tenancy OCID: $TENANCY_OCID"
log "Home Region: $HOME_REGION"

# Dynamic Group Configuration
DYNAMIC_GROUP_NAME="ci-autoscaling-functions-dg"
DYNAMIC_GROUP_DESC="Dynamic group for CI Autoscaling Functions"

# Policy Configuration  
POLICY_NAME="ci-autoscaling-functions-policy"
POLICY_DESC="Policy allowing autoscaling functions to manage container instances and load balancers"

###############################################################################
# Create Dynamic Group
###############################################################################
create_dynamic_group() {
    log "Creating dynamic group: $DYNAMIC_GROUP_NAME"
    
    # Check if dynamic group already exists
    cmd "oci iam dynamic-group list --compartment-id $TENANCY_OCID --name $DYNAMIC_GROUP_NAME --region $HOME_REGION"
    EXISTING_DG=$(oci iam dynamic-group list \
        --compartment-id "$TENANCY_OCID" \
        --name "$DYNAMIC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_DG" ] && [ "$EXISTING_DG" != "null" ]; then
        log "Dynamic group already exists: $EXISTING_DG"
        DYNAMIC_GROUP_OCID="$EXISTING_DG"
        return 0
    fi
    
    # Get Functions Application OCID
    cmd "oci fn application list --compartment-id $COMPARTMENT_OCID --display-name $FUNCTIONS_APP_NAME"
    FUNCTIONS_APP_OCID=$(oci fn application list \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$FUNCTIONS_APP_NAME" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -z "$FUNCTIONS_APP_OCID" ] || [ "$FUNCTIONS_APP_OCID" == "null" ]; then
        error "Functions application not found. Please deploy functions first with: ./setup-autoscaling.sh --deploy"
        exit 1
    fi
    
    log "Functions Application OCID: $FUNCTIONS_APP_OCID"
    
    # Create matching rule for all functions in the application
    MATCHING_RULE="ALL {resource.type = 'fnfunc', resource.compartment.id = '$COMPARTMENT_OCID'}"
    
    # Create dynamic group
    cmd "oci iam dynamic-group create --compartment-id $TENANCY_OCID --name $DYNAMIC_GROUP_NAME --description \"$DYNAMIC_GROUP_DESC\" --matching-rule \"$MATCHING_RULE\" --region $HOME_REGION"
    DYNAMIC_GROUP_OCID=$(oci iam dynamic-group create \
        --compartment-id "$TENANCY_OCID" \
        --name "$DYNAMIC_GROUP_NAME" \
        --description "$DYNAMIC_GROUP_DESC" \
        --matching-rule "$MATCHING_RULE" \
        --region "$HOME_REGION" \
        --query 'data.id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$DYNAMIC_GROUP_OCID" ] && [ "$DYNAMIC_GROUP_OCID" != "null" ]; then
        log "Dynamic group created successfully: $DYNAMIC_GROUP_OCID"
    else
        error "Failed to create dynamic group"
        exit 1
    fi
}

###############################################################################
# Create Policy
###############################################################################
create_policy() {
    log "Creating policy: $POLICY_NAME"
    
    # Check if policy already exists
    cmd "oci iam policy list --compartment-id $TENANCY_OCID --name $POLICY_NAME --region $HOME_REGION"
    EXISTING_POLICY=$(oci iam policy list \
        --compartment-id "$TENANCY_OCID" \
        --name "$POLICY_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_POLICY" ] && [ "$EXISTING_POLICY" != "null" ]; then
        warn "Policy already exists: $EXISTING_POLICY"
        log "Updating policy statements..."
        
        # Update policy with new statements
        POLICY_STATEMENTS='[
            "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to manage container-instances in compartment id '${COMPARTMENT_OCID}'",
            "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to manage container-families in compartment id '${COMPARTMENT_OCID}'",
            "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to manage load-balancers in compartment id '${COMPARTMENT_OCID}'",
            "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to use virtual-network-family in compartment id '${COMPARTMENT_OCID}'",
            "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to read all-resources in compartment id '${COMPARTMENT_OCID}'"
        ]'
        
        cmd "oci iam policy update --policy-id $EXISTING_POLICY --statements '$POLICY_STATEMENTS' --force --region $HOME_REGION"
        oci iam policy update \
            --policy-id "$EXISTING_POLICY" \
            --statements "$POLICY_STATEMENTS" \
            --region "$HOME_REGION" \
            --force >/dev/null 2>&1
        
        log "Policy updated successfully"
        return 0
    fi
    
    # Create policy statements
    POLICY_STATEMENTS='[
        "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to manage container-instances in compartment id '${COMPARTMENT_OCID}'",
        "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to manage container-families in compartment id '${COMPARTMENT_OCID}'",
        "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to manage load-balancers in compartment id '${COMPARTMENT_OCID}'",
        "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to use virtual-network-family in compartment id '${COMPARTMENT_OCID}'",
        "Allow dynamic-group '${DYNAMIC_GROUP_NAME}' to read all-resources in compartment id '${COMPARTMENT_OCID}'"
    ]'
    
    # Create policy
    cmd "oci iam policy create --compartment-id $TENANCY_OCID --name $POLICY_NAME --description \"$POLICY_DESC\" --statements '$POLICY_STATEMENTS' --region $HOME_REGION"
    POLICY_OCID=$(oci iam policy create \
        --compartment-id "$TENANCY_OCID" \
        --name "$POLICY_NAME" \
        --description "$POLICY_DESC" \
        --statements "$POLICY_STATEMENTS" \
        --region "$HOME_REGION" \
        --query 'data.id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$POLICY_OCID" ] && [ "$POLICY_OCID" != "null" ]; then
        log "Policy created successfully: $POLICY_OCID"
    else
        error "Failed to create policy"
        exit 1
    fi
}

###############################################################################
# Show Status
###############################################################################
show_status() {
    log "====== IAM Resources Status ======"
    echo ""
    
    info "Dynamic Group: $DYNAMIC_GROUP_NAME"
    cmd "oci iam dynamic-group list --compartment-id $TENANCY_OCID --name $DYNAMIC_GROUP_NAME --region $HOME_REGION"
    oci iam dynamic-group list \
        --compartment-id "$TENANCY_OCID" \
        --name "$DYNAMIC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --query 'data[*].{Name:name, ID:id, MatchingRule:"matching-rule"}' \
        --output table
    echo ""
    
    info "Policy: $POLICY_NAME"
    cmd "oci iam policy list --compartment-id $TENANCY_OCID --name $POLICY_NAME --region $HOME_REGION"
    oci iam policy list \
        --compartment-id "$TENANCY_OCID" \
        --name "$POLICY_NAME" \
        --region "$HOME_REGION" \
        --query 'data[*].{Name:name, ID:id}' \
        --output table
    echo ""
    
    log "Policy Statements:"
    cmd "oci iam policy get --policy-id \$(oci iam policy list --compartment-id $TENANCY_OCID --name $POLICY_NAME --region $HOME_REGION --query 'data[0].id' --raw-output) --region $HOME_REGION"
    oci iam policy get \
        --policy-id "$(oci iam policy list --compartment-id "$TENANCY_OCID" --name "$POLICY_NAME" --region "$HOME_REGION" --query 'data[0].id' --raw-output)" \
        --region "$HOME_REGION" \
        --query 'data.statements[*]' \
        --output table
    echo ""
}

###############################################################################
# Cleanup
###############################################################################
cleanup() {
    log "====== Cleaning up IAM resources ======"
    
    # Delete policy
    POLICY_OCID=$(oci iam policy list \
        --compartment-id "$TENANCY_OCID" \
        --name "$POLICY_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$POLICY_OCID" ] && [ "$POLICY_OCID" != "null" ]; then
        log "Deleting policy: $POLICY_OCID"
        cmd "oci iam policy delete --policy-id $POLICY_OCID --force --region $HOME_REGION"
        oci iam policy delete --policy-id "$POLICY_OCID" --force --region "$HOME_REGION"
        log "Policy deleted"
    else
        warn "Policy not found"
    fi
    
    # Delete dynamic group
    DYNAMIC_GROUP_OCID=$(oci iam dynamic-group list \
        --compartment-id "$TENANCY_OCID" \
        --name "$DYNAMIC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$DYNAMIC_GROUP_OCID" ] && [ "$DYNAMIC_GROUP_OCID" != "null" ]; then
        log "Deleting dynamic group: $DYNAMIC_GROUP_OCID"
        cmd "oci iam dynamic-group delete --dynamic-group-id $DYNAMIC_GROUP_OCID --force --region $HOME_REGION"
        oci iam dynamic-group delete --dynamic-group-id "$DYNAMIC_GROUP_OCID" --force --region "$HOME_REGION"
        log "Dynamic group deleted"
    else
        warn "Dynamic group not found"
    fi
    
    log "Cleanup completed"
}

###############################################################################
# Main
###############################################################################

case "${1:-}" in
    --setup)
        log "====== Setting up IAM resources for autoscaling ======"
        create_dynamic_group
        echo ""
        create_policy
        echo ""
        log "====== IAM Setup Complete ======"
        echo ""
        log "Next steps:"
        log "  1. Wait 30-60 seconds for policy to propagate"
        log "  2. Test function: fn invoke ci-autoscaling-app scale-up"
        log "  3. Check status: ./setup-iam-policies.sh --status"
        ;;
    --status)
        show_status
        ;;
    --cleanup)
        cleanup
        ;;
    *)
        echo "Usage: $0 {--setup|--status|--cleanup}"
        echo ""
        echo "Commands:"
        echo "  --setup     Create dynamic group and policy for autoscaling functions"
        echo "  --status    Show current IAM resources status"
        echo "  --cleanup   Delete dynamic group and policy"
        exit 1
        ;;
esac
