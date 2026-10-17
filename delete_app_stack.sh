
#!/bin/bash
set -e

cd "$(dirname "$0")"

# ===== LOAD CONFIGURATION =====

set -a
source .env
set +a

export AWS_PAGER=""

if [ ! -f stack_outputs.env ]; then
  echo "ERROR: stack_outputs.env is missing."
  echo "Cannot safely identify ALB and Target Groups."
  exit 1
fi

set -a
source stack_outputs.env
set +a

# ===== DELETE AUTO SCALING GROUPS =====

echo "== Deleting Auto Scaling Groups =="

for ASG_NAME in "$UPLOADER_ASG_NAME" "$VIEWER_ASG_NAME"; do

  aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --force-delete \
    --region "$AWS_REGION" 2>/dev/null || true

  echo "Waiting for $ASG_NAME to disappear..."

  DELETED=false

  for i in $(seq 1 40); do

    EXISTING=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --region "$AWS_REGION" \
      --query "AutoScalingGroups[0].AutoScalingGroupName" \
      --output text)

    if [ "$EXISTING" = "None" ] || [ -z "$EXISTING" ]; then
      DELETED=true
      echo "$ASG_NAME deleted."
      break
    fi

    sleep 15
  done

  if [ "$DELETED" != true ]; then
    echo "ERROR: $ASG_NAME has not finished deleting."
    exit 1
  fi

done

# ===== DELETE APPLICATION LOAD BALANCER =====

echo "== Deleting Application Load Balancer =="

aws elbv2 delete-load-balancer \
  --load-balancer-arn "$ALB_ARN" \
  --region "$AWS_REGION"

aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"

echo "Application Load Balancer deleted."

# ===== DELETE TARGET GROUPS =====

echo "== Deleting Target Groups =="

aws elbv2 delete-target-group \
  --target-group-arn "$UPLOADER_TG_ARN" \
  --region "$AWS_REGION"

aws elbv2 delete-target-group \
  --target-group-arn "$VIEWER_TG_ARN" \
  --region "$AWS_REGION"

echo "Both Target Groups deleted."

# ===== REMOVE ALB ACCESS FROM APP SECURITY GROUP =====

echo "== Removing ALB access from application security group =="

aws ec2 revoke-security-group-ingress \
  --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp \
  --port 3000 \
  --source-group "$ALB_SECURITY_GROUP_ID" \
  --region "$AWS_REGION" 2>/dev/null || true

# ===== DELETE ALB SECURITY GROUP =====

echo "== Deleting ALB Security Group =="

for i in $(seq 1 12); do

  if aws ec2 delete-security-group \
    --group-id "$ALB_SECURITY_GROUP_ID" \
    --region "$AWS_REGION" >/dev/null 2>&1; then

    echo "ALB Security Group deleted."
    break
  fi

  if [ "$i" -eq 12 ]; then
    echo "ERROR: Could not delete ALB Security Group."
    exit 1
  fi

  sleep 10

done

# Keep the application security group for reuse.
# Do not reopen port 3000 to the public internet.

echo "== Multi-AZ infrastructure cleanup complete =="

# ===== DELETE LAUNCH TEMPLATES =====

echo "== Deleting launch templates =="

aws ec2 delete-launch-template \
  --launch-template-name "$UPLOADER_LT_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

aws ec2 delete-launch-template \
  --launch-template-name "$VIEWER_LT_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

# ===== REMOVE IAM ROLES AND INSTANCE PROFILES =====

echo "== Removing IAM roles and profiles =="

for APP in uploader viewer; do

  if [ "$APP" = uploader ]; then
    ROLE="$UPLOADER_ROLE_NAME"
    PROFILE="$UPLOADER_PROFILE_NAME"
  else
    ROLE="$VIEWER_ROLE_NAME"
    PROFILE="$VIEWER_PROFILE_NAME"
  fi

  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$PROFILE" \
    --role-name "$ROLE" 2>/dev/null || true

  aws iam delete-instance-profile \
    --instance-profile-name "$PROFILE" 2>/dev/null || true

  aws iam delete-role-policy \
    --role-name "$ROLE" \
    --policy-name "${ROLE}-policy" 2>/dev/null || true

  # Delete the uploader-specific policy before deleting its role.
  if [ "$APP" = uploader ]; then
    aws iam delete-role-policy \
      --role-name "$ROLE" \
      --policy-name uploader-put-only \
      2>/dev/null || true
  fi

  aws iam delete-role \
    --role-name "$ROLE" 2>/dev/null || true

done

# ===== DELETE S3 BUCKET =====

echo "== Deleting S3 bucket =="

aws s3 rm "s3://$BUCKET_NAME" \
  --recursive \
  --region "$AWS_REGION" 2>/dev/null || true

aws s3api delete-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"

# ===== REMOVE GENERATED LOCAL FILES =====

echo "== Removing generated local files =="

rm -f stack_outputs.env
rm -f uploader-lt-data.json viewer-lt-data.json
rm -f user-data-uploader.sh user-data-viewer.sh
rm -f uploader-policy.json viewer-policy.json trust-policy.json
rm -f uploader_instance_ids.txt viewer_instance_ids.txt

echo "======================================"
echo "Cleanup complete."
echo "======================================"
