"""
OCI Container Instances Scale-Down Function for ANY-APP

This function is triggered by an OCI Alarm when metrics fall below thresholds.
It terminates the most recently created container instance and removes it from the load balancer.
"""

import io
import json
import logging
import os
import time
from datetime import datetime

import oci

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def handler(ctx, data: io.BytesIO = None):
    """
    OCI Functions entry point for scale-down operations.
    
    Args:
        ctx: Function context containing config
        data: Event data from OCI Alarm/Notification
    
    Returns:
        dict: Operation result with status and details
    """
    try:
        logger.info("=== Scale-Down Function Triggered ===")
        
        # Parse the alarm event
        try:
            body = json.loads(data.getvalue())
            logger.info(f"Received event: {json.dumps(body, indent=2)}")
        except Exception as e:
            logger.error(f"Failed to parse event data: {e}")
            body = {}
        
        # Get configuration from environment variables
        config = get_config()
        logger.info(f"Configuration loaded: compartment={config['compartment_id'][:20]}...")
        
        # Initialize OCI clients
        signer = oci.auth.signers.get_resource_principals_signer()
        container_client = oci.container_instances.ContainerInstanceClient(config={}, signer=signer)
        lb_client = oci.load_balancer.LoadBalancerClient(config={}, signer=signer)
        
        # Check current number of active instances
        active_instances = get_active_instances(container_client, config)
        current_count = len(active_instances)
        
        logger.info(f"Current active instances: {current_count}")
        
        # Check if we're already at minimum
        if current_count <= config['min_instances']:
            logger.warning(f"Already at minimum instances ({config['min_instances']}). No scale-down needed.")
            return {
                "status": "skipped",
                "message": f"Already at minimum instances ({config['min_instances']})",
                "current_count": current_count
            }
        
        # Select instance to terminate (most recently created)
        instance_to_terminate = max(active_instances, key=lambda x: x.time_created)
        logger.info(f"Selected instance to terminate: {instance_to_terminate.display_name} ({instance_to_terminate.id})")
        
        # Get private IP before deletion
        private_ip = instance_to_terminate.vnics[0].private_ip
        logger.info(f"Instance private IP: {private_ip}")
        
        # Remove from load balancer first
        logger.info("Removing backend from load balancer...")
        remove_backend_from_lb(lb_client, config, private_ip)
        
        # Wait a bit for connections to drain
        logger.info("Waiting for connections to drain...")
        time.sleep(10)
        
        # Terminate instance
        logger.info("Terminating container instance...")
        container_client.delete_container_instance(instance_to_terminate.id)
        
        logger.info("✅ Scale-down completed successfully")
        return {
            "status": "success",
            "message": "Instance terminated and removed from load balancer",
            "terminated_instance": instance_to_terminate.display_name,
            "instance_ocid": instance_to_terminate.id,
            "private_ip": private_ip,
            "new_count": current_count - 1
        }
        
    except Exception as e:
        logger.error(f"Scale-down failed: {str(e)}", exc_info=True)
        return {
            "status": "error",
            "message": str(e)
        }


def get_config():
    """Load configuration from environment variables."""
    return {
        'compartment_id': os.environ['COMPARTMENT_OCID'],
        'display_name_prefix': os.environ['DISPLAY_NAME_PREFIX'],
        'lb_ocid': os.environ['LB_OCID'],
        'backend_set_name': os.environ['BACKEND_SET_NAME'],
        'min_instances': int(os.environ.get('MIN_INSTANCES', '1')),
        'app_port': int(os.environ.get('APP_PORT', '8080')),
    }


def get_active_instances(client, config):
    """Get all active container instances matching the display name prefix."""
    try:
        instances = client.list_container_instances(
            compartment_id=config['compartment_id'],
            lifecycle_state="ACTIVE"
        ).data
        
        # Filter by display name prefix
        matching = [i for i in instances if i.display_name.startswith(config['display_name_prefix'])]
        
        # Get full details for each instance (to get VNIC info)
        detailed_instances = []
        for instance in matching:
            full_instance = client.get_container_instance(instance.id).data
            detailed_instances.append(full_instance)
        
        return detailed_instances
        
    except Exception as e:
        logger.error(f"Error getting active instances: {e}")
        return []


def remove_backend_from_lb(lb_client, config, private_ip):
    """Remove backend from load balancer."""
    try:
        # Find backend by IP address
        backends = lb_client.list_backends(
            load_balancer_id=config['lb_ocid'],
            backend_set_name=config['backend_set_name']
        ).data
        
        backend_name = None
        for backend in backends:
            if backend.ip_address == private_ip:
                backend_name = backend.name
                break
        
        if not backend_name:
            logger.warning(f"Backend with IP {private_ip} not found in load balancer")
            return
        
        # Delete backend
        lb_client.delete_backend(
            load_balancer_id=config['lb_ocid'],
            backend_set_name=config['backend_set_name'],
            backend_name=backend_name
        )
        
        logger.info(f"Backend {private_ip} removed from load balancer")
        
    except Exception as e:
        logger.error(f"Error removing backend from load balancer: {e}")
        # Don't raise - we still want to terminate the instance even if LB removal fails
