#!/bin/bash
set -e

# Configuration
CLUSTER_NAME="rag-voice-agent-cluster"
REGION="us-east-1"
BACKEND_SERVICE_NAME="rag-voice-agent-backend-service"
FRONTEND_SERVICE_NAME="rag-voice-agent-frontend-service"
BACKEND_TASK_FAMILY="rag-voice-agent-backend-td"
FRONTEND_TASK_FAMILY="rag-voice-agent-frontend-td"

# Fetch Infrastructure Details from CloudFormation
STACK_NAME="rag-voice-agent-stack"

echo "Fetching infrastructure details from CloudFormation stack: $STACK_NAME..."

get_output() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
        --output text
}

# Network Config
PRIVATE_SUBNET_1=$(get_output PrivateSubnet1)
PRIVATE_SUBNET_2=$(get_output PrivateSubnet2)
# Security Groups
BACKEND_SG=$(get_output BackendSecurityGroup)
FRONTEND_SG=$(get_output FrontendSecurityGroup)
# Target Groups
BACKEND_TG_ARN=$(get_output BackendTargetGroupArn)
FRONTEND_TG_ARN=$(get_output FrontendTargetGroupArn)

for v in PRIVATE_SUBNET_1 PRIVATE_SUBNET_2 BACKEND_SG FRONTEND_SG BACKEND_TG_ARN FRONTEND_TG_ARN; do
    if [ -z "${!v}" ] || [ "${!v}" = "None" ]; then
        echo "❌ Missing CloudFormation output for $v (stack: $STACK_NAME, region: $REGION)."
        exit 1
    fi
done

# ----------------------------------------------------------------
# Register Task Definitions
# ----------------------------------------------------------------
# The CI pipeline only registers task definitions inside its "Deploy" step,
# which also requires the services to exist. Register them here first so
# the services can be created (CI will register new revisions afterwards).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TD_DIR="$SCRIPT_DIR/../.github/workflows"

image_exists() {
    local repo=$1 tag=$2
    aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$tag" \
        --region "$REGION" >/dev/null 2>&1
}

register_td() {
    local file=$1 repo=$2
    local image tag
    image=$(grep -o '"image": *"[^"]*"' "$file" | sed -E 's/.*"image": *"([^"]*)"/\1/')
    tag="${image##*:}"

    if ! image_exists "$repo" "$tag"; then
        echo "❌ Image $repo:$tag not found in ECR ($REGION)."
        echo "   Push it first: ./scripts/build-and-push-ecr.sh"
        exit 1
    fi

    echo "Registering task definition from $(basename "$file") (image: $repo:$tag)"
    aws ecs register-task-definition \
        --cli-input-json "file://$file" \
        --region "$REGION" \
        --query "taskDefinition.taskDefinitionArn" \
        --output text
}

echo "----------------------------------------------------------------"
echo "Registering Task Definitions"
echo "----------------------------------------------------------------"
register_td "$TD_DIR/task-definition-backend.json" "rag-voice-agent-backend"
register_td "$TD_DIR/task-definition-frontend.json" "rag-voice-agent-frontend"

echo "----------------------------------------------------------------"
echo "Creating ECS Services"
echo "----------------------------------------------------------------"

# Function to check if service exists
service_exists() {
    local cluster=$1
    local service=$2
    aws ecs describe-services --cluster "$cluster" --services "$service" --region "$REGION" \
        --query "services[?status=='ACTIVE'].serviceName" --output text | grep -q "$service"
}

# Create Backend Service
echo "Creating Backend Service: $BACKEND_SERVICE_NAME"
if service_exists "$CLUSTER_NAME" "$BACKEND_SERVICE_NAME"; then
    echo "Service $BACKEND_SERVICE_NAME already exists. Skipping creation."
else
    aws ecs create-service \
        --cluster "$CLUSTER_NAME" \
        --service-name "$BACKEND_SERVICE_NAME" \
        --task-definition "$BACKEND_TASK_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2],securityGroups=[$BACKEND_SG],assignPublicIp=DISABLED}" \
        --load-balancers targetGroupArn=$BACKEND_TG_ARN,containerName=rag-voice-agent-backend-container,containerPort=8000 \
        --region "$REGION"
fi

# Create Frontend Service
echo "Creating Frontend Service: $FRONTEND_SERVICE_NAME"
if service_exists "$CLUSTER_NAME" "$FRONTEND_SERVICE_NAME"; then
    echo "Service $FRONTEND_SERVICE_NAME already exists. Skipping creation."
else
    aws ecs create-service \
        --cluster "$CLUSTER_NAME" \
        --service-name "$FRONTEND_SERVICE_NAME" \
        --task-definition "$FRONTEND_TASK_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2],securityGroups=[$FRONTEND_SG],assignPublicIp=DISABLED}" \
        --load-balancers targetGroupArn=$FRONTEND_TG_ARN,containerName=rag-voice-agent-frontend-container,containerPort=80 \
        --region "$REGION"
fi

echo "----------------------------------------------------------------"
echo "Services Created. CI/CD Pipeline can now update them."
echo "----------------------------------------------------------------"