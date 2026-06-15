#!/bin/bash
set -euo pipefail

# Check if global-values.yaml exists
if [[ ! -f "global-values.yaml" ]]; then
  echo "Error: global-values.yaml file does not exist!"
  exit 1
fi

# Check required tools
if ! command -v yq &> /dev/null; then
  echo "Error: yq is not installed. Install it with: sudo wget -qO /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/bin/yq"
  exit 1
fi

if ! command -v aws &> /dev/null; then
  echo "Error: AWS CLI is not installed. Install it from: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
  echo "Error: AWS credentials not configured or invalid"
  echo "Run: aws configure"
  exit 1
fi

# Read values from global-values.yaml
building_block=$(yq 'explode(.) | .global.building_block' global-values.yaml)
environment_name=$(yq 'explode(.) | .global.environment' global-values.yaml)
aws_region=$(yq 'explode(.) | .global.cloud_storage_region' global-values.yaml)

# Validate required values
if [[ -z "$building_block" || -z "$environment_name" || -z "$aws_region" ]]; then
  echo "Error: Unable to extract required values from global-values.yaml"
  echo "Ensure building_block, environment, and cloud_storage_region are set"
  exit 1
fi

# Validate environment name (1-9 lowercase alphanumeric characters)
if ! [[ "$environment_name" =~ ^[a-z0-9]{1,9}$ ]]; then
  echo "Error: environment must be 1-9 lowercase alphanumeric characters"
  exit 1
fi

# Get AWS Account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Construct resource names with account ID for global uniqueness
BUCKET_NAME="${building_block}-${environment_name}-${AWS_ACCOUNT_ID}-tfstate"

echo "======================================"
echo "AWS OpenTofu Backend Setup"
echo "======================================"
echo "Building block: $building_block"
echo "Environment: $environment_name"
echo "Region: $aws_region"
echo "AWS Account: $AWS_ACCOUNT_ID"
echo "S3 Bucket: $BUCKET_NAME"
echo "======================================"

# Check whether the bucket exists and is accessible
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$aws_region" >/dev/null 2>&1; then
  echo ""
  echo "✓ S3 bucket $BUCKET_NAME already exists and is accessible"
else
  # If head-bucket failed, inspect the error to give a clearer message
  set +e
  ERR_OUT=$(aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$aws_region" 2>&1)
  ERR_CODE=$?
  set -e

  if echo "$ERR_OUT" | grep -qi 'Not Found\|NoSuchBucket'; then
    echo ""
    echo "Creating S3 bucket for OpenTofu state..."
    # Handle us-east-1 special case (doesn't need LocationConstraint)
    if [ "$aws_region" = "us-east-1" ]; then
      aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$aws_region"
    else
      aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$aws_region" \
        --create-bucket-configuration LocationConstraint="$aws_region"
    fi

    # Enable versioning
    echo "Enabling versioning on S3 bucket..."
    aws s3api put-bucket-versioning \
      --bucket "$BUCKET_NAME" \
      --versioning-configuration Status=Enabled

    # Enable server-side encryption
    echo "Enabling encryption on S3 bucket..."
    aws s3api put-bucket-encryption \
      --bucket "$BUCKET_NAME" \
      --server-side-encryption-configuration '{
        "Rules": [{
          "ApplyServerSideEncryptionByDefault": {
            "SSEAlgorithm": "AES256"
          },
          "BucketKeyEnabled": true
        }]
      }'

    # Block public access
    echo "Blocking public access to S3 bucket..."
    aws s3api put-public-access-block \
      --bucket "$BUCKET_NAME" \
      --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    # Add bucket tagging
    aws s3api put-bucket-tagging \
      --bucket "$BUCKET_NAME" \
      --tagging "TagSet=[{Key=Environment,Value=$environment_name},{Key=BuildingBlock,Value=$building_block},{Key=ManagedBy,Value=OpenTofu},{Key=Purpose,Value=OpenTofuState}]"

    echo "✓ S3 bucket $BUCKET_NAME created successfully"
  else
    # Common alternative errors: bucket exists in another account, access denied, or region mismatch
    echo ""
    echo "ERROR: Unable to access bucket $BUCKET_NAME: $ERR_OUT"
    echo "Possible causes:"
    echo "- The bucket exists but in another AWS account"
    echo "- You don't have permissions to access the bucket"
    echo "- The bucket exists in a different region"
    echo ""
    echo "If the bucket exists in another account, either choose a different bucket name or ensure the account has shared access."
    exit 1
  fi
fi

# Export environment variables to tf.sh
cat > tf.sh <<EOF
export AWS_REGION=$aws_region
export TERRAFORM_BACKEND_BUCKET=$BUCKET_NAME
EOF

echo ""
echo "======================================"
echo "✓ OpenTofu backend setup complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "1. Run: source tf.sh"
echo "2. Run: terragrunt init"
echo "3. Run: terragrunt run-all apply"
echo ""