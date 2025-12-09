"""
OCI Container Instances Scale-Up Function for ANY-APP

This function is triggered by an OCI Alarm when metrics exceed thresholds.
It creates a new container instance and adds it as a backend to the load balancer.
"""

import io
import json
import logging
import os
import time
from datetime import datetime, timedelta

import oci

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def handler(ctx, data: io.BytesIO = None):
    """
    OCI Functions entry point for scale-up operations.
    
    Args:
        ctx: Function context containing config
        data: Event data from OCI Alarm/Notification
    
    Returns:
        dict: Operation result with status and details
    """
    try:
        logger.info("=== Scale-Up Function Triggered ===")
        
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
        current_count = count_active_instances(container_client, config)
        creating_count = count_creating_instances(container_client, config)
        total_count = current_count + creating_count
        
        logger.info(f"Current instances - Active: {current_count}, Creating: {creating_count}, Total: {total_count}")
        
        # Check if we're already at or above max
        if total_count >= config['max_instances']:
            logger.warning(f"Already at maximum instances ({config['max_instances']}). No scale-up needed.")
            return {
                "status": "skipped",
                "message": f"Already at maximum instances ({config['max_instances']})",
                "active_count": current_count,
                "creating_count": creating_count,
                "total_count": total_count
            }
        
        # Check if there's already a scale-up in progress
        if creating_count > 0:
            logger.warning(f"Scale-up already in progress ({creating_count} instances being created). Skipping.")
            return {
                "status": "skipped",
                "message": f"Scale-up already in progress ({creating_count} instances being created)",
                "active_count": current_count,
                "creating_count": creating_count
            }
        
        # Check cooldown period
        if not check_cooldown(container_client, config):
            logger.warning("Cooldown period active. Skipping scale-up.")
            return {
                "status": "skipped",
                "message": "Cooldown period active (2 minutes since last scale operation)",
                "current_count": current_count
            }
        
        # Create new container instance
        logger.info("Creating new container instance...")
        instance_ocid = create_container_instance(container_client, config)
        logger.info(f"Container instance created: {instance_ocid}")
        
        # Wait for instance to become ACTIVE
        logger.info("Waiting for instance to reach ACTIVE state...")
        wait_for_instance_state(container_client, instance_ocid, "ACTIVE", max_wait=300)
        
        # Get private IP
        instance_details = container_client.get_container_instance(instance_ocid).data
        private_ip = instance_details.vnics[0].private_ip
        logger.info(f"Instance private IP: {private_ip}")
        
        # Add to load balancer
        logger.info("Adding backend to load balancer...")
        add_backend_to_lb(lb_client, config, private_ip)
        
        logger.info("✅ Scale-up completed successfully")
        return {
            "status": "success",
            "message": "New instance created and added to load balancer",
            "instance_ocid": instance_ocid,
            "private_ip": private_ip,
            "new_count": total_count + 1
        }
        
    except Exception as e:
        logger.error(f"Scale-up failed: {str(e)}", exc_info=True)
        return {
            "status": "error",
            "message": str(e)
        }


def get_config():
    """Load configuration from environment variables."""
    return {
        'compartment_id': os.environ['COMPARTMENT_OCID'],
        'subnet_id': os.environ['SUBNET_OCID'],
        'ad_name': os.environ['AD_NAME'],
        'image_uri': os.environ['IMAGE_URI'],
        'container_name': os.environ['CONTAINER_NAME'],
        'display_name_prefix': os.environ['DISPLAY_NAME_PREFIX'],
        'memory_gb': float(os.environ.get('MEMORY_GB', '8')),
        'ocpus': float(os.environ.get('OCPUS', '1')),
        'app_port': int(os.environ.get('APP_PORT', '8080')),
        'health_check_path': os.environ.get('HEALTH_CHECK_PATH', '/health'),
        'lb_ocid': os.environ['LB_OCID'],
        'backend_set_name': os.environ['BACKEND_SET_NAME'],
        'max_instances': int(os.environ.get('MAX_INSTANCES', '5')),
    }


def count_active_instances(client, config):
    """Count active container instances."""
    try:
        instances = client.list_container_instances(
            compartment_id=config['compartment_id'],
            lifecycle_state="ACTIVE"
        ).data
        
        # Filter by display name prefix
        matching = [i for i in instances if i.display_name.startswith(config['display_name_prefix'])]
        return len(matching)
    except Exception as e:
        logger.error(f"Error counting active instances: {e}")
        return 0


def count_creating_instances(client, config):
    """Count instances in CREATING state."""
    try:
        instances = client.list_container_instances(
            compartment_id=config['compartment_id'],
            lifecycle_state="CREATING"
        ).data
        
        # Filter by display name prefix
        matching = [i for i in instances if i.display_name.startswith(config['display_name_prefix'])]
        return len(matching)
    except Exception as e:
        logger.error(f"Error counting creating instances: {e}")
        return 0


def check_cooldown(client, config):
    """Check if cooldown period has passed since last scale operation."""
    try:
        all_instances = client.list_container_instances(
            compartment_id=config['compartment_id']
        ).data
        
        matching = [i for i in all_instances if i.display_name.startswith(config['display_name_prefix'])]
        
        if not matching:
            return True
        
        # Get most recent creation time
        most_recent = max(matching, key=lambda x: x.time_created)
        time_since_creation = datetime.utcnow() - most_recent.time_created.replace(tzinfo=None)
        
        cooldown_seconds = 120  # 2 minutes
        return time_since_creation.total_seconds() > cooldown_seconds
        
    except Exception as e:
        logger.error(f"Error checking cooldown: {e}")
        return True  # Allow scale operation on error


def create_container_instance(client, config):
    """Create a new container instance."""
    # Generate unique name
    timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    display_name = f"{config['display_name_prefix']}-{timestamp}"
    
    # Create container instance
    create_details = oci.container_instances.models.CreateContainerInstanceDetails(
        compartment_id=config['compartment_id'],
        availability_domain=config['ad_name'],
        shape="CI.Standard.E4.Flex",
        shape_config=oci.container_instances.models.CreateContainerInstanceShapeConfigDetails(
            ocpus=config['ocpus'],
            memory_in_gbs=config['memory_gb']
        ),
        vnics=[oci.container_instances.models.CreateContainerVnicDetails(
            subnet_id=config['subnet_id'],
            is_public_ip_assigned=False
        )],
        containers=[oci.container_instances.models.CreateContainerDetails(
            image_url=config['image_uri'],
            display_name=config['container_name'],
            health_checks=[oci.container_instances.models.CreateContainerHealthCheckDetails(
                health_check_type="HTTP",
                path=config['health_check_path'],
                port=config['app_port'],
                interval_in_seconds=30,
                timeout_in_seconds=3,
                failure_threshold=3
            )]
        )],
        display_name=display_name
    )
    
    response = client.create_container_instance(create_details)
    return response.data.id


def wait_for_instance_state(client, instance_id, target_state, max_wait=300):
    """Wait for instance to reach target state."""
    start_time = time.time()
    
    while time.time() - start_time < max_wait:
        instance = client.get_container_instance(instance_id).data
        
        if instance.lifecycle_state == target_state:
            logger.info(f"Instance reached {target_state} state")
            return True
        
        if instance.lifecycle_state == "FAILED":
            raise Exception(f"Instance creation failed")
        
        time.sleep(10)
    
    raise Exception(f"Timeout waiting for instance to reach {target_state}")


def add_backend_to_lb(lb_client, config, private_ip):
    """Add backend to load balancer."""
    try:
        # Check if backend already exists
        backends = lb_client.list_backends(
            load_balancer_id=config['lb_ocid'],
            backend_set_name=config['backend_set_name']
        ).data
        
        for backend in backends:
            if backend.ip_address == private_ip:
                logger.info(f"Backend {private_ip} already exists in load balancer")
                return
        
        # Create backend
        create_backend_details = oci.load_balancer.models.CreateBackendDetails(
            ip_address=private_ip,
            port=config['app_port'],
            backup=False,
            drain=False,
            offline=False,
            weight=1
        )
        
        lb_client.create_backend(
            create_backend_details=create_backend_details,
            load_balancer_id=config['lb_ocid'],
            backend_set_name=config['backend_set_name']
        )
        
        logger.info(f"Backend {private_ip} added to load balancer")
        
    except Exception as e:
        logger.error(f"Error adding backend to load balancer: {e}")
        raise
