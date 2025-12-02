#!/bin/bash
# Cleanup script to delete all CREATING and FAILED container instances

set -e

# Source environment
source "$(dirname "$0")/autoscaling.env"

echo "Fetching instances to delete..."

# Get all CREATING and FAILED instances
INSTANCES=$(oci container-instances container-instance list \
    --compartment-id "$COMPARTMENT_OCID" \
    --query 'data.items[?("lifecycle-state"==`CREATING` || "lifecycle-state"==`FAILED`)].{id:id,name:"display-name",state:"lifecycle-state"}' \
    --output json)

COUNT=$(echo "$INSTANCES" | jq -r '. | length')

if [ "$COUNT" -eq 0 ]; then
    echo "No instances to delete."
    exit 0
fi

echo "Found $COUNT instances to delete"
echo ""

# Delete each instance
echo "$INSTANCES" | jq -r '.[] | @json' | while IFS= read -r instance; do
    ID=$(echo "$instance" | jq -r '.id')
    NAME=$(echo "$instance" | jq -r '.name')
    STATE=$(echo "$instance" | jq -r '.state')
    
    echo "Deleting $STATE instance: $NAME"
    echo "  OCID: $ID"
    
    RESULT=$(oci container-instances container-instance delete \
        --container-instance-id "$ID" \
        --force 2>&1 || true)
    
    if echo "$RESULT" | grep -q "opc-work-request-id"; then
        echo "  ✓ Delete initiated"
    elif echo "$RESULT" | grep -q "NotAuthorized\|already.*delet"; then
        echo "  ⚠ Already deleting or not authorized"
    else
        echo "  ✗ Error: $RESULT"
    fi
    echo ""
    
    # Small delay to avoid rate limiting
    sleep 0.5
done

echo "Cleanup complete!"
echo ""
echo "Note: Deletions are asynchronous. Run this to check remaining instances:"
echo "  oci container-instances container-instance list --compartment-id \"$COMPARTMENT_OCID\" --lifecycle-state FAILED --output table"
echo "  oci container-instances container-instance list --compartment-id \"$COMPARTMENT_OCID\" --lifecycle-state CREATING --output table"
