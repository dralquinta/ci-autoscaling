"""
OCI Container Instances Scale-Up Function

This function is triggered by an OCI Alarm when CPU/Memory exceeds thresholds.
It creates a new container instance and adds it as a backend to the load balancer.
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
        network_client = oci.core.VirtualNetworkClient(config={}, signer=signer)
        
        # Check current number of active instances (including CREATING state)
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
        
        # Check cooldown period (prevent scaling within 2 minutes of last scale operation)
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
        logger.info("Retrieving private IP address...")
        private_ip = get_instance_private_ip(container_client, network_client, instance_ocid)
        logger.info(f"Instance private IP: {private_ip}")
        
        # Check if backend set exists, create if needed
        ensure_backend_set_exists(lb_client, config)
        
        # Add to load balancer backend set
        logger.info("Adding instance to load balancer backend set...")
        add_backend_to_lb(lb_client, config, private_ip)
        logger.info("Backend added successfully")
        
        result = {
            "status": "success",
            "message": "Container instance scaled up successfully",
            "instance_ocid": instance_ocid,
            "private_ip": private_ip,
            "total_instances": current_count + 1,
            "timestamp": datetime.utcnow().isoformat()
        }
        
        logger.info(f"Scale-up completed: {json.dumps(result, indent=2)}")
        return result
        
    except Exception as e:
        logger.error(f"Scale-up failed: {str(e)}", exc_info=True)
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
        "availability_domain": os.environ.get("AD_NAME"),
        "image_uri": os.environ.get("CONTAINER_IMAGE_URI") or os.environ.get("IMAGE_URI", "docker.io/dralquinta/ci-autoscaling:latest"),
        "container_name": os.environ.get("CONTAINER_NAME", "autoscaling-demo"),
        "display_name_prefix": os.environ.get("DISPLAY_NAME_PREFIX", "autoscaling-demo-instance"),
        "memory_gb": int(os.environ.get("MEMORY_GB", "8")),
        "ocpus": int(os.environ.get("OCPUS", "1")),
        "lb_ocid": os.environ.get("LB_OCID"),
        "backend_set_name": os.environ.get("BACKEND_SET_NAME", "autoscaling-demo-backend-set"),
        "app_port": int(os.environ.get("APP_PORT", "8080")),
        "health_check_path": os.environ.get("HEALTH_CHECK_PATH", "/actuator/health"),
        "max_instances": int(os.environ.get("MAX_INSTANCES", "5")),
        "min_instances": int(os.environ.get("MIN_INSTANCES", "1")),
        "cooldown_seconds": int(os.environ.get("COOLDOWN_SECONDS", "120")),  # Default 2 minutes
        "ocir_username": os.environ.get("OCIR_USERNAME"),
        "ocir_auth_token": os.environ.get("OCIR_AUTH_TOKEN"),
        "ocir_registry": os.environ.get("OCIR_REGISTRY", "sa-santiago-1.ocir.io")
    }


def count_active_instances(container_client, config):
    """Count currently active container instances with our display name prefix."""
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
        
        return len(matching_instances)
    except Exception as e:
        logger.error(f"Failed to count instances: {e}")
        return 0


def count_creating_instances(container_client, config):
    """Count container instances currently being created."""
    try:
        response = container_client.list_container_instances(
            compartment_id=config["compartment_id"],
            lifecycle_state="CREATING"
        )
        
        # Filter by display name prefix
        prefix = config["display_name_prefix"]
        matching_instances = [
            inst for inst in response.data.items 
            if inst.display_name.startswith(prefix)
        ]
        
        return len(matching_instances)
    except Exception as e:
        logger.error(f"Failed to count creating instances: {e}")
        return 0


def check_cooldown(container_client, config):
    """
    Check if cooldown period has elapsed since last scale operation.
    Returns True if scaling is allowed, False if in cooldown.
    """
    try:
        import datetime
        
        cooldown_seconds = int(config.get("cooldown_seconds", 120))  # Default 2 minutes
        
        # List all instances (any state)
        response = container_client.list_container_instances(
            compartment_id=config["compartment_id"]
        )
        
        # Filter by display name prefix
        prefix = config["display_name_prefix"]
        matching_instances = [
            inst for inst in response.data.items 
            if inst.display_name.startswith(prefix)
        ]
        
        if not matching_instances:
            logger.info("No existing instances found. Cooldown check passed.")
            return True
        
        # Find most recent instance creation time
        most_recent = max(matching_instances, key=lambda x: x.time_created)
        time_since_creation = datetime.datetime.now(datetime.timezone.utc) - most_recent.time_created
        seconds_elapsed = time_since_creation.total_seconds()
        
        logger.info(f"Most recent instance created {seconds_elapsed:.0f} seconds ago")
        
        if seconds_elapsed < cooldown_seconds:
            remaining = cooldown_seconds - seconds_elapsed
            logger.warning(f"Cooldown active: {remaining:.0f} seconds remaining")
            return False
        
        logger.info("Cooldown period elapsed. Ready to scale.")
        return True
        
    except Exception as e:
        logger.error(f"Error checking cooldown: {e}")
        # On error, allow scaling (fail open)
        return True


def create_container_instance(container_client, config):
    """Create a new container instance."""
    timestamp = int(time.time())
    display_name = f"{config['display_name_prefix']}-{timestamp}"
    
    # Prepare image pull secrets if OCIR credentials are provided
    image_pull_secrets = None
    if config.get("ocir_username") and config.get("ocir_auth_token"):
        secret_name = f"ocir-secret-{timestamp}"
        image_pull_secrets = [
            oci.container_instances.models.BasicImagePullSecret(
                secret_type="BASIC",
                registry_endpoint=config["ocir_registry"],
                username=config["ocir_username"],
                password=config["ocir_auth_token"]
            )
        ]
        logger.info(f"Configured OCIR image pull secret for registry {config['ocir_registry']}")
    
    # Build container instance details
    create_details = oci.container_instances.models.CreateContainerInstanceDetails(
        compartment_id=config["compartment_id"],
        availability_domain=config["availability_domain"],
        shape="CI.Standard.E4.Flex",
        shape_config=oci.container_instances.models.CreateContainerInstanceShapeConfigDetails(
            memory_in_gbs=float(config["memory_gb"]),
            ocpus=float(config["ocpus"])
        ),
        display_name=display_name,
        image_pull_secrets=image_pull_secrets,
        vnics=[
            oci.container_instances.models.CreateContainerVnicDetails(
                subnet_id=config["subnet_id"],
                is_public_ip_assigned=True,
                display_name=f"{display_name}-vnic",
                hostname_label=f"ci-{timestamp}"
            )
        ],
        containers=[
            oci.container_instances.models.CreateContainerDetails(
                display_name=config["container_name"],
                image_url=config["image_uri"],
                environment_variables={
                    "JAVA_OPTS": f"-Xmx{int(config['memory_gb'] * 0.75)}g -Xms{int(config['memory_gb'] * 0.25)}g",
                    "SPRING_PROFILES_ACTIVE": "production"
                }
            )
        ]
    )
    
    # Create the instance
    response = container_client.create_container_instance(create_details)
    
    # Get work request and extract instance OCID
    work_request_id = response.headers.get("opc-work-request-id")
    if work_request_id:
        # Wait for work request to complete
        time.sleep(10)
        work_request = container_client.get_work_request(work_request_id).data
        for resource in work_request.resources:
            if resource.entity_type == "containerInstance":
                return resource.identifier
    
    # Fallback: query by display name
    time.sleep(15)
    response = container_client.list_container_instances(
        compartment_id=config["compartment_id"],
        display_name=display_name
    )
    if response.data.items:
        return response.data.items[0].id
    
    raise Exception("Failed to retrieve container instance OCID")


def wait_for_instance_state(container_client, instance_ocid, target_state, max_wait=300):
    """Wait for container instance to reach target lifecycle state."""
    elapsed = 0
    interval = 5
    
    while elapsed < max_wait:
        try:
            instance = container_client.get_container_instance(instance_ocid).data
            if instance.lifecycle_state == target_state:
                logger.info(f"Instance reached {target_state} state")
                return True
            logger.info(f"Current state: {instance.lifecycle_state}, waiting...")
        except Exception as e:
            logger.warning(f"Error checking instance state: {e}")
        
        time.sleep(interval)
        elapsed += interval
    
    raise Exception(f"Timeout waiting for instance to reach {target_state} state")


def get_instance_private_ip(container_client, network_client, instance_ocid):
    """Get private IP address of container instance."""
    max_wait = 120
    elapsed = 0
    interval = 5
    
    while elapsed < max_wait:
        try:
            instance = container_client.get_container_instance(instance_ocid).data
            if instance.vnics and len(instance.vnics) > 0:
                vnic_id = instance.vnics[0].vnic_id
                if vnic_id:
                    vnic = network_client.get_vnic(vnic_id).data
                    if vnic.private_ip:
                        return vnic.private_ip
        except Exception as e:
            logger.warning(f"Error getting private IP: {e}")
        
        time.sleep(interval)
        elapsed += interval
    
    raise Exception("Failed to retrieve private IP address")


def ensure_backend_set_exists(lb_client, config):
    """Check if backend set exists, create if it doesn't."""
    try:
        lb = lb_client.get_load_balancer(config["lb_ocid"]).data
        
        if config["backend_set_name"] in lb.backend_sets:
            logger.info(f"Backend set '{config['backend_set_name']}' already exists")
            return
        
        logger.info(f"Creating backend set '{config['backend_set_name']}'...")
        
        backend_set_details = oci.load_balancer.models.CreateBackendSetDetails(
            name=config["backend_set_name"],
            policy="ROUND_ROBIN",
            health_checker=oci.load_balancer.models.HealthCheckerDetails(
                protocol="HTTP",
                port=config["app_port"],
                url_path=config["health_check_path"],
                interval_in_millis=10000,
                timeout_in_millis=3000,
                retries=3,
                return_code=200
            )
        )
        
        lb_client.create_backend_set(
            create_backend_set_details=backend_set_details,
            load_balancer_id=config["lb_ocid"]
        )
        
        # Wait for backend set creation
        time.sleep(30)
        logger.info("Backend set created successfully")
        
    except Exception as e:
        logger.error(f"Error managing backend set: {e}")
        raise


def add_backend_to_lb(lb_client, config, private_ip):
    """Add container instance as backend to load balancer."""
    backend_details = oci.load_balancer.models.CreateBackendDetails(
        ip_address=private_ip,
        port=config["app_port"],
        weight=1,
        backup=False,
        drain=False,
        offline=False
    )
    
    lb_client.create_backend(
        create_backend_details=backend_details,
        load_balancer_id=config["lb_ocid"],
        backend_set_name=config["backend_set_name"]
    )
    
    # Wait for backend to be added
    time.sleep(20)
