#!/bin/bash

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!
# AWS DELETE EVERYTHING SCRIPT
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!

# Set the AWS profile and region if needed
# export AWS_PROFILE=your-profile
# export AWS_REGION=your-region

# colors
GREEN='\033[0;32m'
NC='\033[0m' # No Color
ORANGE='\033[0;33m'

# Stop EC2 instances
stop_ec2_instances() {
    echo -e "Terminating all EC2 instances..."

    # Get IDs of all instances that are in the 'running' state
    running_instance_ids=$(aws ec2 describe-instances \
                            --filters "Name=instance-state-name,Values=running" \
                            --query 'Reservations[*].Instances[*].InstanceId' \
                            --output text)

    # Stop running instances first
    if [ -n "$running_instance_ids" ]; then
        echo "Stopping running instances..."
        aws ec2 stop-instances --instance-ids $running_instance_ids --output text > /dev/null
        echo "Waiting for running instances to stop..."
        aws ec2 wait instance-stopped --instance-ids $running_instance_ids
    fi

    # Get IDs of all instances except those in the 'terminated' state
    non_terminated_instance_ids=$(aws ec2 describe-instances \
                                    --filters "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
                                    --query 'Reservations[*].Instances[*].InstanceId' \
                                    --output text)

    # Terminate all non-terminated instances
    if [ -n "$non_terminated_instance_ids" ]; then
        echo "Terminating instances..."
        aws ec2 terminate-instances --instance-ids $non_terminated_instance_ids --output text > /dev/null
        echo "Waiting for instances to terminate..."
        aws ec2 wait instance-terminated --instance-ids $non_terminated_instance_ids
    fi

    # List all terminated instances
    terminated_instance_ids=$(aws ec2 describe-instances \
                                --filters "Name=instance-state-name,Values=terminated" \
                                --query 'Reservations[*].Instances[*].InstanceId' \
                                --output text)
    
    if [ -n "$terminated_instance_ids" ]; then
        echo -e "${GREEN}Terminated EC2 Instances:${NC}"
        echo "$terminated_instance_ids"
    else
        echo -e "${GREEN}No terminated EC2 instances found.${NC}"
    fi
}


# Delete S3 buckets
delete_s3_buckets() {
    echo -e "Deleting all S3 buckets..."
    aws s3 ls | awk '{print $3}' | \
        xargs -I {} sh -c 'aws s3 rb s3://{} --force && echo -e "${GREEN}[+]${NC} Deleted S3 bucket: {}"'
    echo -e "${GREEN}S3 buckets deleted.${NC}"
}

# Terminate RDS instances
terminate_rds_instances() {
    echo -e "Terminating all RDS instances..."
    aws rds describe-db-instances \
        --query 'DBInstances[*].DBInstanceIdentifier' \
        --output text | \
        xargs -I {} sh -c 'aws rds delete-db-instance --db-instance-identifier {} --skip-final-snapshot && echo -e "${GREEN}[+]${NC} Terminated RDS instance: {}"'
    echo -e "${GREEN}RDS instances terminated.${NC}"
}

# Delete Lambda functions
delete_lambda_functions() {
    echo -e "Deleting all Lambda functions..."
    aws lambda list-functions --query 'Functions[*].FunctionName' --output text | \
        tr '\t' '\n' | \
        xargs -I {} sh -c 'aws lambda delete-function --function-name {} && echo -e "${GREEN}[+]${NC} Deleted Lambda function: {}"'
    echo -e "${GREEN}Lambda functions deleted.${NC}"
}

# Delete IAM users (EXCLUDE YOUR OWN USER)
delete_iam_users() {
    echo "Deleting all IAM users..."
    for user in $(aws iam list-users --query 'Users[*].UserName' --output text | tr '\t' '\n' | grep -v "YOUR_USER_NAME")
    do
        for key in $(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[*].AccessKeyId' --output text)
        do
            aws iam delete-access-key --user-name "$user" --access-key-id "$key"
        done
        # Detach managed policies
        for policy in $(aws iam list-attached-user-policies --user-name "$user" --query 'AttachedPolicies[*].PolicyArn' --output text)
        do
            aws iam detach-user-policy --user-name "$user" --policy-arn "$policy"
        done

        # Delete inline policies
        for policy in $(aws iam list-user-policies --user-name "$user" --query 'PolicyNames' --output text)
        do
            aws iam delete-user-policy --user-name "$user" --policy-name "$policy"
        done

        # Finally, delete the user
        aws iam delete-user --user-name "$user" && echo -e "${GREEN}[+]${NC} Deleted IAM user: $user"
    done
}



# Delete VPCs (EXCLUDE THE DEFAULT VPC)
delete_vpcs() {
    echo "Deleting all VPCs..."
    for vpc in $(aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`false`].VpcId' --output text)
    do
        # Delete subnets
        for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[*].SubnetId' --output text)
        do
            aws ec2 delete-subnet --subnet-id $subnet
        done

        # Detach and delete internet gateways
        for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[*].InternetGatewayId' --output text)
        do
            aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc
            aws ec2 delete-internet-gateway --internet-gateway-id $igw
        done

        # Disassociate and delete route tables (skip main route table)
        for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query 'RouteTables[?Associations[?Main!=`true`]].RouteTableId' --output text)
        do
            for rta in $(aws ec2 describe-route-tables --route-table-id $rt --query 'RouteTables[*].Associations[*].RouteTableAssociationId' --output text)
            do
                aws ec2 disassociate-route-table --association-id $rta
            done
            aws ec2 delete-route-table --route-table-id $rt
        done

        # Delete security groups (skip default security group)
        for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)
        do
            aws ec2 delete-security-group --group-id $sg
        done

        # Delete network ACLs (skip default ACL)
        for acl in $(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc" --query 'NetworkAcls[?IsDefault!=`true`].NetworkAclId' --output text)
        do
            aws ec2 delete-network-acl --network-acl-id $acl
        done

        # Delete VPC endpoints
        for vpce in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc" --query 'VpcEndpoints[*].VpcEndpointId' --output text)
        do
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $vpce
        done

        # Finally, delete the VPC
        if output=$(aws ec2 delete-vpc --vpc-id $vpc 2>&1); then
            echo -e "${GREEN}[+]${NC} Deleted VPC: $vpc"
        else
            echo -e "${ORANGE}[ERROR]${NC} Failed to delete VPC: $vpc$ORANGE$output${NC}"
        fi
    done
}

# Delete DynamoDB tables
delete_dynamodb_tables() {
    echo -e "Deleting all DynamoDB tables..."
    aws dynamodb list-tables --query 'TableNames[*]' --output text | \
        tr '\t' '\n' | \
        xargs -I {} sh -c 'aws dynamodb delete-table --table-name {} && echo -e "${GREEN}[+]${NC} Deleted DynamoDB table: {}"'
    echo -e "${GREEN}DynamoDB tables deleted.${NC}"
}

# Delete Elastic Load Balancers (both classic and application/network load balancers)
delete_elbs() {
    echo "Deleting all Elastic Load Balancers..."
    # Classic Load Balancers
    aws elb describe-load-balancers --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output text | \
        xargs -I {} aws elb delete-load-balancer --load-balancer-name {}
    # Application and Network Load Balancers
    aws elbv2 describe-load-balancers --query 'LoadBalancers[*].LoadBalancerArn' --output text | \
        xargs -I {} aws elbv2 delete-load-balancer --load-balancer-arn {}
    echo -e "${GREEN}Elastic Load Balancers deleted.${NC}"
}

# Delete Elastic Beanstalk environments
delete_elastic_beanstalk_environments() {
    echo -e "Deleting all Elastic Beanstalk environments..."
    for env in $(aws elasticbeanstalk describe-environments --query 'Environments[*].EnvironmentId' --output text)
    do
        aws elasticbeanstalk terminate-environment --environment-id $env
        echo -e "${GREEN}[+]${NC} Elastic Beanstalk environment ${env} deleted."
    done
}

# Delete ECS clusters
delete_ecs_clusters() {
    echo -e "Deleting all ECS clusters..."
    for cluster in $(aws ecs list-clusters --query 'clusterArns[*]' --output text)
    do
        aws ecs delete-cluster --cluster $cluster
        echo -e "${GREEN}[+]${NC} ECS cluster ${cluster} deleted."
    done
}

# Delete EKS clusters
delete_eks_clusters() {
    echo -e "Deleting all EKS clusters..."
    for cluster in $(aws eks list-clusters --query 'clusters[*]' --output text)
    do
        aws eks delete-cluster --name $cluster
        echo -e "${GREEN}[+]${NC} EKS cluster ${cluster} deleted."
    done
}

# Delete CloudFormation stacks
delete_cloudformation_stacks() {
    echo -e "Deleting all CloudFormation stacks..."
    for stack in $(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query 'StackSummaries[*].StackId' --output text)
    do
        aws cloudformation delete-stack --stack-name $stack
        echo -e "${GREEN}[+]${NC} CloudFormation stack ${stack} deleted."
    done
}

# calling functions
stop_ec2_instances
delete_s3_buckets
terminate_rds_instances
delete_lambda_functions
delete_iam_users
delete_vpcs
delete_dynamodb_tables
delete_elbs
delete_elastic_beanstalk_environments
delete_ecs_clusters
delete_eks_clusters
delete_cloudformation_stacks
