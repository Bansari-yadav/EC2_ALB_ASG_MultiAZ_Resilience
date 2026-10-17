
#!/bin/bash
set -e

cd "$(dirname "$0")"
set -a
source .env
set +a
export AWS_PAGER=""

echo "== Checking configuration =="

for VAR in AWS_REGION AMI_ID INSTANCE_TYPE KEY_NAME BUCKET_NAME APP_SECURITY_GROUP_ID UPLOADER_ROLE_NAME UPLOADER_PROFILE_NAME UPLOADER_LT_NAME VIEWER_ROLE_NAME VIEWER_PROFILE_NAME VIEWER_LT_NAME; do
  if [ -z "${!VAR}" ] || [[ "${!VAR}" == YOUR_* ]]; then
    echo "Missing configuration: $VAR"
    exit 1
  fi
done

echo "== Creating S3 bucket =="

if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
  echo "S3 bucket already exists."
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi

echo "== Configuring IAM roles =="

cat > trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

for ROLE in "$UPLOADER_ROLE_NAME" "$VIEWER_ROLE_NAME"; do
  if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam create-role \
      --role-name "$ROLE" \
      --assume-role-policy-document file://trust-policy.json >/dev/null
  fi
done

cat > uploader-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject"],
    "Resource": "arn:aws:s3:::${BUCKET_NAME}/shared.txt"
  }]
}
EOF

cat > viewer-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/shared.txt"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$UPLOADER_ROLE_NAME" \
  --policy-name "${UPLOADER_ROLE_NAME}-policy" \
  --policy-document file://uploader-policy.json

aws iam put-role-policy \
  --role-name "$VIEWER_ROLE_NAME" \
  --policy-name "${VIEWER_ROLE_NAME}-policy" \
  --policy-document file://viewer-policy.json

for APP in uploader viewer; do

  if [ "$APP" = uploader ]; then
    ROLE="$UPLOADER_ROLE_NAME"
    PROFILE="$UPLOADER_PROFILE_NAME"
  else
    ROLE="$VIEWER_ROLE_NAME"
    PROFILE="$VIEWER_PROFILE_NAME"
  fi

  if ! aws iam get-instance-profile \
    --instance-profile-name "$PROFILE" >/dev/null 2>&1; then

    aws iam create-instance-profile \
      --instance-profile-name "$PROFILE" >/dev/null
  fi

  EXISTING_ROLE=$(aws iam get-instance-profile \
    --instance-profile-name "$PROFILE" \
    --query "InstanceProfile.Roles[].RoleName" \
    --output text)

  if [ "$EXISTING_ROLE" != "$ROLE" ]; then
    aws iam add-role-to-instance-profile \
      --instance-profile-name "$PROFILE" \
      --role-name "$ROLE"
  fi
done

echo "Waiting for IAM propagation..."
sleep 20

echo "== Building user-data and launch templates =="

for APP in uploader viewer; do

  APP_JS_B64=$(base64 -w0 "lab03/${APP}-app/app.js")
  PKG_JSON_B64=$(base64 -w0 "lab03/${APP}-app/package.json")

  if [ "$APP" = uploader ]; then
    PROFILE="$UPLOADER_PROFILE_NAME"
    LT="$UPLOADER_LT_NAME"
  else
    PROFILE="$VIEWER_PROFILE_NAME"
    LT="$VIEWER_LT_NAME"
  fi

  cat > "user-data-${APP}.sh" <<EOF
#!/bin/bash
set -e
dnf install -y nodejs

mkdir -p /opt/app
echo "$APP_JS_B64" | base64 -d > /opt/app/app.js
echo "$PKG_JSON_B64" | base64 -d > /opt/app/package.json

cd /opt/app
npm install --omit=dev

cat > /etc/systemd/system/${APP}.service <<SERVICE
[Unit]
Description=${APP} Application
After=network-online.target
Wants=network-online.target

[Service]
Environment=BUCKET_NAME=$BUCKET_NAME
Environment=AWS_REGION=$AWS_REGION
Environment=PORT=3000
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
SERVICE

chown -R ec2-user:ec2-user /opt/app
systemctl daemon-reload
systemctl enable ${APP}.service
systemctl start ${APP}.service
EOF

  USERDATA_B64=$(base64 -w0 "user-data-${APP}.sh")

  cat > "${APP}-lt-data.json" <<EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$KEY_NAME",
  "SecurityGroupIds": ["$APP_SECURITY_GROUP_ID"],
  "IamInstanceProfile": {
    "Name": "$PROFILE"
  },
  "UserData": "$USERDATA_B64",
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        {"Key": "Name", "Value": "${APP}-app"}
      ]
    }
  ]
}
EOF

  echo "Configuring launch template: $LT"

  if aws ec2 describe-launch-templates \
    --launch-template-names "$LT" \
    --region "$AWS_REGION" >/dev/null 2>&1; then

    aws ec2 create-launch-template-version \
      --launch-template-name "$LT" \
      --launch-template-data "file://${APP}-lt-data.json" \
      --region "$AWS_REGION" >/dev/null

  else

    aws ec2 create-launch-template \
      --launch-template-name "$LT" \
      --launch-template-data "file://${APP}-lt-data.json" \
      --region "$AWS_REGION" >/dev/null
  fi
done

# ===== MULTI-AZ ALB AND AUTO SCALING =====

echo "== Looking up the default VPC and subnets =="

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text --region "$AWS_REGION")

SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_A" \
  --query "Subnets[0].SubnetId" \
  --output text --region "$AWS_REGION")

SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_B" \
  --query "Subnets[0].SubnetId" \
  --output text --region "$AWS_REGION")

echo "Subnet A: $SUBNET_A"
echo "Subnet B: $SUBNET_B"

if [[ "$SUBNET_A" == "None" || "$SUBNET_B" == "None" || -z "$SUBNET_A" || -z "$SUBNET_B" ]]; then
  echo "ERROR: Could not find both subnets."
  exit 1
fi

echo "== Creating ALB security group =="

ALB_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text --region "$AWS_REGION")

if [[ "$ALB_SECURITY_GROUP_ID" == "None" || -z "$ALB_SECURITY_GROUP_ID" ]]; then
  ALB_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$ALB_SG_NAME" \
    --description "Allow inbound traffic to ALB" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text --region "$AWS_REGION")
fi

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SECURITY_GROUP_ID" \
  --protocol tcp --port "$UPLOADER_LISTENER_PORT" \
  --cidr 0.0.0.0/0 --region "$AWS_REGION" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SECURITY_GROUP_ID" \
  --protocol tcp --port "$VIEWER_LISTENER_PORT" \
  --cidr 0.0.0.0/0 --region "$AWS_REGION" 2>/dev/null || true

echo "== Restricting application security group to ALB =="

aws ec2 revoke-security-group-ingress \
  --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 \
  --cidr 0.0.0.0/0 --region "$AWS_REGION" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 \
  --source-group "$ALB_SECURITY_GROUP_ID" \
  --region "$AWS_REGION" 2>/dev/null || true

echo "== Security groups configured =="

# ===== TARGET GROUPS =====

echo "== Creating Uploader Target Group =="

UPLOADER_TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$UPLOADER_TG_NAME" \
  --region "$AWS_REGION" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text 2>/dev/null || true)

if [[ -z "$UPLOADER_TG_ARN" || "$UPLOADER_TG_ARN" == "None" ]]; then
  UPLOADER_TG_ARN=$(aws elbv2 create-target-group \
    --name "$UPLOADER_TG_NAME" \
    --protocol HTTP \
    --port 3000 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path / \
    --health-check-interval-seconds 10 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --region "$AWS_REGION" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text)
fi

echo "== Creating Viewer Target Group =="

VIEWER_TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$VIEWER_TG_NAME" \
  --region "$AWS_REGION" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text 2>/dev/null || true)

if [[ -z "$VIEWER_TG_ARN" || "$VIEWER_TG_ARN" == "None" ]]; then
  VIEWER_TG_ARN=$(aws elbv2 create-target-group \
    --name "$VIEWER_TG_NAME" \
    --protocol HTTP \
    --port 3000 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path / \
    --health-check-interval-seconds 10 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --region "$AWS_REGION" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text)
fi

echo "== Both Target Groups configured =="

# ===== APPLICATION LOAD BALANCER =====

echo "== Creating Application Load Balancer =="

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text 2>/dev/null || true)

if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then

  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --subnets "$SUBNET_A" "$SUBNET_B" \
    --security-groups "$ALB_SECURITY_GROUP_ID" \
    --scheme internet-facing \
    --type application \
    --region "$AWS_REGION" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text)

fi

echo "== Waiting for ALB to become active =="

aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"

# ===== ALB LISTENERS =====

echo "== Configuring ALB listeners =="

EXISTING_PORTS=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --region "$AWS_REGION" \
  --query "Listeners[].Port" \
  --output text)

if ! echo "$EXISTING_PORTS" | tr '\t' '\n' | grep -qx "$UPLOADER_LISTENER_PORT"; then

  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port "$UPLOADER_LISTENER_PORT" \
    --default-actions "Type=forward,TargetGroupArn=$UPLOADER_TG_ARN" \
    --region "$AWS_REGION" >/dev/null

fi

if ! echo "$EXISTING_PORTS" | tr '\t' '\n' | grep -qx "$VIEWER_LISTENER_PORT"; then

  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port "$VIEWER_LISTENER_PORT" \
    --default-actions "Type=forward,TargetGroupArn=$VIEWER_TG_ARN" \
    --region "$AWS_REGION" >/dev/null

fi

ALB_DNS_NAME=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION" \
  --query "LoadBalancers[0].DNSName" \
  --output text)

echo "== ALB and listeners configured =="
echo "ALB DNS: $ALB_DNS_NAME"

# ===== AUTO SCALING GROUPS =====

echo "== Creating Uploader Auto Scaling Group =="

EXISTING_UPLOADER_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$UPLOADER_ASG_NAME" \
  --region "$AWS_REGION" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" \
  --output text)

if [[ -z "$EXISTING_UPLOADER_ASG" || "$EXISTING_UPLOADER_ASG" == "None" ]]; then

  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$UPLOADER_ASG_NAME" \
    --launch-template "LaunchTemplateName=$UPLOADER_LT_NAME,Version=\$Latest" \
    --min-size 1 \
    --max-size 1 \
    --desired-capacity 1 \
    --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
    --target-group-arns "$UPLOADER_TG_ARN" \
    --health-check-type ELB \
    --health-check-grace-period 120 \
    --tags "ResourceId=$UPLOADER_ASG_NAME,ResourceType=auto-scaling-group,Key=Name,Value=uploader-app,PropagateAtLaunch=true" \
    --region "$AWS_REGION"

fi

echo "== Creating Viewer Auto Scaling Group =="

EXISTING_VIEWER_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$VIEWER_ASG_NAME" \
  --region "$AWS_REGION" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" \
  --output text)

if [[ -z "$EXISTING_VIEWER_ASG" || "$EXISTING_VIEWER_ASG" == "None" ]]; then

  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$VIEWER_ASG_NAME" \
    --launch-template "LaunchTemplateName=$VIEWER_LT_NAME,Version=\$Latest" \
    --min-size 1 \
    --max-size 1 \
    --desired-capacity 1 \
    --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
    --target-group-arns "$VIEWER_TG_ARN" \
    --health-check-type ELB \
    --health-check-grace-period 120 \
    --tags "ResourceId=$VIEWER_ASG_NAME,ResourceType=auto-scaling-group,Key=Name,Value=viewer-app,PropagateAtLaunch=true" \
    --region "$AWS_REGION"

fi

echo "== Both Auto Scaling Groups configured =="

# ===== SAVE STACK OUTPUTS =====

cat > stack_outputs.env << EOF
VPC_ID=$VPC_ID
SUBNET_A=$SUBNET_A
SUBNET_B=$SUBNET_B
ALB_SECURITY_GROUP_ID=$ALB_SECURITY_GROUP_ID
ALB_ARN=$ALB_ARN
ALB_DNS_NAME=$ALB_DNS_NAME
UPLOADER_TG_ARN=$UPLOADER_TG_ARN
VIEWER_TG_ARN=$VIEWER_TG_ARN
EOF

echo "======================================"
echo "Deployment completed."
echo "Done. ALB DNS name: $ALB_DNS_NAME"
echo "Uploader: http://$ALB_DNS_NAME:$UPLOADER_LISTENER_PORT/"
echo "Viewer: http://$ALB_DNS_NAME:$VIEWER_LISTENER_PORT/"
echo "======================================"
echo "Allow 1-2 minutes for targets to become healthy."