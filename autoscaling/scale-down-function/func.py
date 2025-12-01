"""
OCI Container Instances Scale-Down Function

This function is triggered when OCI Alarm clears (metric returns to normal).
It removes a container instance and removes it from the load balancer backend set.
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
        network_client = oci.core.VirtualNetworkClient(config={}, signer=signer)
        
        # Get list of active instances
        instances = list_active_instances(container_client, config)
        logger.info(f"Current active instances: {len(instances)}")
        
        if len(instances) <= config['min_instances']:
            logger.warning(f"Already at minimum instances ({config['min_instances']}). No scale-down needed.")
            return {
                "status": "skipped",
                "message": f"Already at minimum instances ({config['min_instances']})",
                "current_count": len(instances)
            }
        
        # Select instance to remove (oldest first)
        instance_to_remove = select_instance_for_removal(instances)
        logger.info(f"Selected instance for removal: {instance_to_remove.id}")
        logger.info(f"Instance display name: {instance_to_remove.display_name}")
        
        # Get private IP before deletion
        try:
            private_ip = get_instance_private_ip(container_client, network_client, instance_to_remove.id)
            logger.info(f"Instance private IP: {private_ip}")
            
            # Remove from load balancer backend set
            logger.info("Removing instance from load balancer backend set...")
            remove_backend_from_lb(lb_client, config, private_ip)
            logger.info("Backend removed successfully")
        except Exception as e:
            logger.warning(f"Could not remove backend from LB: {e}")
            private_ip = "unknown"
        
        # Delete container instance
        logger.info("Deleting container instance...")
        delete_container_instance(container_client, instance_to_remove.id)
        logger.info("Container instance deleted successfully")
        
        result = {
            "status": "success",
            "message": "Container instance scaled down successfully",
            "instance_ocid": instance_to_remove.id,
            "instance_name": instance_to_remove.display_name,
            "private_ip": private_ip,
            "total_instances": len(instances) - 1,
            "timestamp": datetime.utcnow().isoformat()
        }
        
        logger.info(f"Scale-down completed: {json.dumps(result, indent=2)}")
        return result
        
    except Exception as e:
        logger.error(f"Scale-down failed: {str(e)}", exc_info=True)
        return {
            "status": "error",
            "message": str(e),
            "timestamp": datetime.utcnow().isoformat()
        }


def get_config():
    """Load configuration from environment variables."""
    return {
        "compartment_id": os.environ.get("COMPARTMENT_OCID"),
        "subnet_id": os.environ.get("SUBNET_OCID"),
        "display_name_prefix": os.environ.get("DISPLAY_NAME_PREFIX", "autoscaling-demo-instance"),
        "lb_ocid": os.environ.get("LB_OCID"),
        "backend_set_name": os.environ.get("BACKEND_SET_NAME", "autoscaling-demo-backend-set"),
        "app_port": int(os.environ.get("APP_PORT", "8080")),
        "max_instances": int(os.environ.get("MAX_INSTANCES", "5")),
        "min_instances": int(os.environ.get("MIN_INSTANCES", "1"))
    }


def list_active_instances(container_client, config):
    """List all active container instances with our display name prefix."""
    try:
        response = container_client.list_container_instances(
            compartment_id=config["compartment_id"],
            lifecycle_state="ACTIVE"
        )
        
        # Filter by display name prefix
        prefix = config["display_name_prefix"]
        matching_instances = [
            inst for inst in response.data.items 
            if inst.display_name.startswith(prefix)
        ]
        
        return matching_instances
    except Exception as e:
        logger.error(f"Failed to list instances: {e}")
        return []


def select_instance_for_removal(instances):
    """
    Select which instance to remove.
    Strategy: Remove the oldest instance (by creation time).
    """
    if not instances:
        raise Exception("No instances available for removal")
    
    # Sort by time_created (oldest first)
    sorted_instances = sorted(instances, key=lambda x: x.time_created)
    return sorted_instances[0]


def get_instance_private_ip(container_client, network_client, instance_ocid):
    """Get private IP address of container instance."""
    try:
        instance = container_client.get_container_instance(instance_ocid).data
        if instance.vnics and len(instance.vnics) > 0:
            vnic_id = instance.vnics[0].vnic_id
            if vnic_id:
                vnic = network_client.get_vnic(vnic_id).data
                if vnic.private_ip:
                    return vnic.private_ip
    except Exception as e:
        logger.error(f"Error getting private IP: {e}")
    
    raise Exception("Failed to retrieve private IP address")


def remove_backend_from_lb(lb_client, config, private_ip):
    """Remove container instance from load balancer backend set."""
    backend_name = f"{private_ip}:{config['app_port']}"
    
    try:
        lb_client.delete_backend(
            load_balancer_id=config["lb_ocid"],
            backend_set_name=config["backend_set_name"],
            backend_name=backend_name
        )
        
        # Wait for backend removal
        time.sleep(20)
        logger.info(f"Backend {backend_name} removed from load balancer")
        
    except oci.exceptions.ServiceError as e:
        if e.status == 404:
            logger.warning(f"Backend {backend_name} not found in load balancer (may have been removed already)")
        else:
            raise


def delete_container_instance(container_client, instance_ocid):
    """Delete a container instance."""
    try:
        container_client.delete_container_instance(instance_ocid)
        logger.info(f"Delete request sent for instance {instance_ocid}")
        
        # Wait a bit for deletion to start
        time.sleep(10)
        
        # Optionally wait for DELETED state (with timeout)
        max_wait = 120
        elapsed = 0
        interval = 10
        
        while elapsed < max_wait:
            try:
                instance = container_client.get_container_instance(instance_ocid).data
                if instance.lifecycle_state == "DELETED":
                    logger.info("Instance successfully deleted")
                    return
                logger.info(f"Instance state: {instance.lifecycle_state}, waiting for DELETED...")
            except oci.exceptions.ServiceError as e:
                if e.status == 404:
                    logger.info("Instance deleted (404 response)")
                    return
                logger.warning(f"Error checking instance state: {e}")
            
            time.sleep(interval)
            elapsed += interval
        
        logger.warning("Deletion may still be in progress (timeout reached)")
        
    except oci.exceptions.ServiceError as e:
        if e.status == 404:
            logger.info("Instance already deleted")
        else:
            raise
