#!/usr/bin/env bash
# setup-cluster.sh — EIP Controller cluster setup
# Checks each prerequisite, shows current state, and asks before making changes.
# bash 3.2 compatible (macOS default shell).
set -euo pipefail

# ─── colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn()  { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail()  { echo -e "${RED}  ✘  $*${RESET}"; }
info()  { echo -e "${CYAN}  ℹ  $*${RESET}"; }
header(){ echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

confirm() {
  # confirm <prompt> — returns 0 for yes, 1 for no
  local msg="$1"
  while true; do
    printf "${YELLOW}  → %s [y/n]: ${RESET}" "$msg"
    read -r ans
    case "$(echo "$ans" | tr '[:upper:]' '[:lower:]')" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "    Please enter y or n." ;;
    esac
  done
}

pause() {
  printf "\n${CYAN}  Press Enter to continue to the next step, or q to quit: ${RESET}"
  read -r key
  case "$(echo "$key" | tr '[:upper:]' '[:lower:]')" in
    q) echo "Exiting."; exit 0 ;;
  esac
}

# ─── detect defaults ──────────────────────────────────────────────────────────
DETECTED_REGION=$(aws configure get region 2>/dev/null || echo "eu-central-1")
DETECTED_CLUSTER=$(kubectl config current-context 2>/dev/null | sed 's/.*@//' | cut -d. -f1 || echo "")
DETECTED_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║        EIP Controller — Cluster Setup Script        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo "This script checks and sets up all prerequisites for the EIP Controller."
echo "It will show the current state of each step and ask before making changes."
echo ""

# ─── collect inputs ───────────────────────────────────────────────────────────
header "Configuration"

printf "  Cluster name [%s]: " "$DETECTED_CLUSTER"
read -r INPUT_CLUSTER
CLUSTER_NAME="${INPUT_CLUSTER:-$DETECTED_CLUSTER}"

printf "  AWS region   [%s]: " "$DETECTED_REGION"
read -r INPUT_REGION
REGION="${INPUT_REGION:-$DETECTED_REGION}"

printf "  AWS account  [%s]: " "$DETECTED_ACCOUNT"
read -r INPUT_ACCOUNT
ACCOUNT_ID="${INPUT_ACCOUNT:-$DETECTED_ACCOUNT}"

printf "  Scraper node group name [scraper-ng]: "
read -r INPUT_SCRAPER_NG
SCRAPER_NG="${INPUT_SCRAPER_NG:-scraper-ng}"

printf "  System node group name  [system-ng]: "
read -r INPUT_SYSTEM_NG
SYSTEM_NG="${INPUT_SYSTEM_NG:-system-ng}"

printf "  IAM role name [EIPControllerRole]: "
read -r INPUT_ROLE
IAM_ROLE="${INPUT_ROLE:-EIPControllerRole}"

printf "  IAM policy name [EIPControllerPolicy]: "
read -r INPUT_POLICY
IAM_POLICY="${INPUT_POLICY:-EIPControllerPolicy}"

echo ""
echo -e "${BOLD}  Settings:${RESET}"
echo "    Cluster  : $CLUSTER_NAME"
echo "    Region   : $REGION"
echo "    Account  : $ACCOUNT_ID"
echo "    Scraper NG: $SCRAPER_NG"
echo "    System NG : $SYSTEM_NG"
echo "    IAM Role  : $IAM_ROLE"
echo ""
confirm "Proceed with these settings?" || { echo "Exiting."; exit 0; }

# ─── Step 1: VPC subnets ──────────────────────────────────────────────────────
header "Step 1 — VPC: public + private subnets"

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")

if [ -z "$VPC_ID" ]; then
  fail "Could not find VPC for cluster $CLUSTER_NAME. Check your kubectl context and cluster name."
  exit 1
fi
info "VPC: $VPC_ID"

PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --region "$REGION" \
  --query 'Subnets[*].SubnetId' --output text 2>/dev/null)

PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
  --region "$REGION" \
  --query 'Subnets[*].SubnetId' --output text 2>/dev/null)

if [ -n "$PUBLIC_SUBNETS" ]; then
  pass "Public subnets found: $PUBLIC_SUBNETS"
else
  fail "No public subnets found in VPC $VPC_ID. Scraper nodes require public subnets with an IGW route."
fi

if [ -n "$PRIVATE_SUBNETS" ]; then
  pass "Private subnets found: $PRIVATE_SUBNETS"
else
  fail "No private subnets found in VPC $VPC_ID. The controller requires private subnets with a NAT Gateway route."
  warn "Cannot continue without private subnets. Add private subnets + NAT Gateway to your VPC first."
fi

# verify IGW on public subnets and NAT on private subnets
for sn in $PUBLIC_SUBNETS; do
  ROUTE=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$sn" \
    --region "$REGION" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' \
    --output text 2>/dev/null)
  if echo "$ROUTE" | grep -q "igw-"; then
    pass "Subnet $sn → IGW ✔"
  else
    warn "Subnet $sn has no IGW route — scraper pods won't have EIP egress"
  fi
  break  # check just one as a sample
done

for sn in $PRIVATE_SUBNETS; do
  ROUTE=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$sn" \
    --region "$REGION" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId' \
    --output text 2>/dev/null)
  if echo "$ROUTE" | grep -q "nat-"; then
    pass "Subnet $sn → NAT Gateway ✔"
  else
    warn "Subnet $sn has no NAT Gateway route — controller won't have internet access"
  fi
  break  # check just one as a sample
done

pause

# ─── Step 2: Node groups ──────────────────────────────────────────────────────
header "Step 2 — Node groups"

EXISTING_NGS=$(eksctl get nodegroup --cluster "$CLUSTER_NAME" --region "$REGION" \
  --output json 2>/dev/null | python3 -c "import sys,json; ngs=json.load(sys.stdin); print(' '.join([n['Name'] for n in ngs]))" 2>/dev/null || echo "")

info "Existing node groups: ${EXISTING_NGS:-none}"

# scraper node group
if echo "$EXISTING_NGS" | grep -qw "$SCRAPER_NG"; then
  SCRAPER_LABEL=$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=$SCRAPER_NG" \
    --show-labels 2>/dev/null | grep "node.kubernetes.io/scraper=true" | wc -l | tr -d ' ')
  if [ "$SCRAPER_LABEL" -gt 0 ]; then
    pass "Scraper node group '$SCRAPER_NG' exists and nodes are labeled"
  else
    warn "Scraper node group '$SCRAPER_NG' exists but nodes are NOT labeled node.kubernetes.io/scraper=true"
    if confirm "Add label and taint to nodes in $SCRAPER_NG now?"; then
      for node in $(kubectl get nodes -l "eks.amazonaws.com/nodegroup=$SCRAPER_NG" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        kubectl label node "$node" node.kubernetes.io/scraper=true --overwrite
        kubectl taint node "$node" node.kubernetes.io/scraper=true:NoSchedule --overwrite 2>/dev/null || true
        pass "Labeled + tainted $node"
      done
    fi
  fi
else
  warn "Scraper node group '$SCRAPER_NG' does not exist"
  echo ""
  echo "  To create it, you need to pick public subnets from the list above."
  printf "  Enter public subnet IDs (comma-separated): "
  read -r SCRAPER_SUBNETS
  if [ -n "$SCRAPER_SUBNETS" ] && confirm "Create scraper node group '$SCRAPER_NG' in subnets $SCRAPER_SUBNETS?"; then
    eksctl create nodegroup \
      --cluster "$CLUSTER_NAME" \
      --region "$REGION" \
      --name "$SCRAPER_NG" \
      --node-type m5.large \
      --nodes 2 \
      --nodes-min 1 \
      --nodes-max 10 \
      --node-labels "node.kubernetes.io/scraper=true" \
      --node-taints "node.kubernetes.io/scraper=true:NoSchedule" \
      --subnet-ids "$SCRAPER_SUBNETS"
    pass "Scraper node group '$SCRAPER_NG' created"
  else
    warn "Skipping scraper node group creation — create it manually before deploying scraper pods"
  fi
fi

# system node group
if echo "$EXISTING_NGS" | grep -qw "$SYSTEM_NG"; then
  SYSTEM_NODE=$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=$SYSTEM_NG" \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
  if [ -z "$SYSTEM_NODE" ]; then
    pass "System node group '$SYSTEM_NG' exists — nodes have no public IP (private subnet) ✔"
  else
    warn "System node group '$SYSTEM_NG' exists but nodes have public IPs — may be in a public subnet"
  fi
else
  warn "System node group '$SYSTEM_NG' does not exist"
  echo ""
  echo "  To create it, you need to pick private subnets from the list above."
  printf "  Enter private subnet IDs (comma-separated): "
  read -r SYSTEM_SUBNETS
  if [ -n "$SYSTEM_SUBNETS" ] && confirm "Create system node group '$SYSTEM_NG' in subnets $SYSTEM_SUBNETS?"; then
    eksctl create nodegroup \
      --cluster "$CLUSTER_NAME" \
      --region "$REGION" \
      --name "$SYSTEM_NG" \
      --node-type m5.large \
      --nodes 1 \
      --nodes-min 1 \
      --nodes-max 3 \
      --node-private-networking \
      --subnet-ids "$SYSTEM_SUBNETS"
    pass "System node group '$SYSTEM_NG' created"
  else
    warn "Skipping system node group creation — create it manually before installing the controller"
  fi
fi

pause

# ─── Step 3: IMDSv2 hop limit ─────────────────────────────────────────────────
header "Step 3 — IMDSv2 hop limit = 2"

INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running" \
  --region "$REGION" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text 2>/dev/null)

ALL_OK=true
for iid in $INSTANCE_IDS; do
  HOPLIMIT=$(aws ec2 describe-instances \
    --instance-ids "$iid" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpPutResponseHopLimit' \
    --output text 2>/dev/null)
  NG=$(aws ec2 describe-instances \
    --instance-ids "$iid" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].Tags[?Key==`eks:nodegroup-name`].Value' \
    --output text 2>/dev/null)
  if [ "$HOPLIMIT" = "2" ]; then
    pass "$iid ($NG) — hop limit $HOPLIMIT ✔"
  else
    fail "$iid ($NG) — hop limit $HOPLIMIT (needs 2)"
    ALL_OK=false
    if confirm "Set hop limit to 2 on instance $iid now?"; then
      aws ec2 modify-instance-metadata-options \
        --instance-id "$iid" \
        --http-put-response-hop-limit 2 \
        --http-endpoint enabled \
        --region "$REGION" > /dev/null
      pass "Hop limit set to 2 on $iid"
    fi
  fi
done

$ALL_OK && pass "All nodes have hop limit = 2" || warn "Some nodes still have hop limit != 2 — fix before deploying"

pause

# ─── Step 4: EXTERNALSNAT ─────────────────────────────────────────────────────
header "Step 4 — EXTERNALSNAT=true on aws-node DaemonSet"

EXTERNALSNAT=$(kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_VPC_K8S_CNI_EXTERNALSNAT")].value}' \
  2>/dev/null || echo "false")

if [ "$EXTERNALSNAT" = "true" ]; then
  pass "EXTERNALSNAT is already true ✔"
else
  warn "EXTERNALSNAT is currently '${EXTERNALSNAT:-not set}' — scraper pod egress will not use the assigned EIP"
  if confirm "Set EXTERNALSNAT=true on aws-node DaemonSet now?"; then
    kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_EXTERNALSNAT=true
    pass "EXTERNALSNAT set to true — aws-node pods will restart rolling"
  else
    warn "Skipping — EIP egress will NOT work without this"
  fi
fi

pause

# ─── Step 5: OIDC provider ────────────────────────────────────────────────────
header "Step 5 — OIDC provider"

OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null | sed 's|https://||')
OIDC_ID=$(echo "$OIDC_ISSUER" | awk -F'/' '{print $NF}')

info "Cluster OIDC issuer: $OIDC_ISSUER"

OIDC_EXISTS=$(aws iam list-open-id-connect-providers \
  --query "OIDCProviderList[?contains(Arn, '$OIDC_ID')].Arn" \
  --output text 2>/dev/null)

if [ -n "$OIDC_EXISTS" ]; then
  pass "OIDC provider registered: $OIDC_EXISTS"
else
  warn "OIDC provider not registered for this cluster"
  if confirm "Register OIDC provider now?"; then
    eksctl utils associate-iam-oidc-provider \
      --region "$REGION" \
      --cluster "$CLUSTER_NAME" \
      --approve
    pass "OIDC provider registered"
  else
    warn "Skipping — IRSA will not work without this"
  fi
fi

pause

# ─── Step 6: IAM role ─────────────────────────────────────────────────────────
header "Step 6 — IAM role"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY}"

REQUIRED_ACTIONS="ec2:AllocateAddress ec2:AssociateAddress ec2:DisassociateAddress ec2:ReleaseAddress ec2:DescribeAddresses ec2:DescribeNetworkInterfaces ec2:DescribeInstances ec2:CreateTags"

DESIRED_POLICY_DOC=$(cat <<PDOC
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:AllocateAddress",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:ReleaseAddress",
      "ec2:DescribeAddresses",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeInstances",
      "ec2:CreateTags"
    ],
    "Resource": "*"
  }]
}
PDOC
)

DESIRED_TRUST=$(cat <<TRUST
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ISSUER}:sub": "system:serviceaccount:eip-controller:eip-controller",
        "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
TRUST
)

ROLE_ARN=$(aws iam get-role --role-name "$IAM_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "")

if [ -n "$ROLE_ARN" ]; then
  pass "IAM role exists: $ROLE_ARN"

  # ── check trust policy has correct OIDC ID ──────────────────────────────────
  CURRENT_TRUST=$(aws iam get-role --role-name "$IAM_ROLE" \
    --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo "{}")

  if echo "$CURRENT_TRUST" | grep -q "$OIDC_ID"; then
    pass "Trust policy references correct OIDC ID ($OIDC_ID) ✔"
  else
    warn "Trust policy does NOT reference this cluster's OIDC ID ($OIDC_ID)"
    info "Current trust policy:"
    echo "$CURRENT_TRUST" | python3 -m json.tool 2>/dev/null || echo "$CURRENT_TRUST"
    if confirm "Update trust policy to use OIDC ID $OIDC_ID?"; then
      aws iam update-assume-role-policy \
        --role-name "$IAM_ROLE" \
        --policy-document "$DESIRED_TRUST"
      pass "Trust policy updated with OIDC ID $OIDC_ID"
    else
      warn "Skipping — IRSA will fail if trust policy points to a different cluster"
    fi
  fi

  # ── check service account condition ─────────────────────────────────────────
  if echo "$CURRENT_TRUST" | grep -q "system:serviceaccount:eip-controller:eip-controller"; then
    pass "Trust policy scoped to correct service account ✔"
  else
    warn "Trust policy does not scope to system:serviceaccount:eip-controller:eip-controller"
    if confirm "Update trust policy with correct service account condition?"; then
      aws iam update-assume-role-policy \
        --role-name "$IAM_ROLE" \
        --policy-document "$DESIRED_TRUST"
      pass "Trust policy updated"
    fi
  fi

  # ── check policy exists and has all required permissions ────────────────────
  POLICY_EXISTS=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
    --query 'Policy.Arn' --output text 2>/dev/null || echo "")

  if [ -z "$POLICY_EXISTS" ]; then
    warn "Policy $IAM_POLICY does not exist — creating it"
    aws iam create-policy \
      --policy-name "$IAM_POLICY" \
      --policy-document "$DESIRED_POLICY_DOC" > /dev/null
    pass "Policy $IAM_POLICY created"
  else
    # get current policy version and check permissions
    DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
      --query 'Policy.DefaultVersionId' --output text 2>/dev/null)
    CURRENT_ACTIONS=$(aws iam get-policy-version \
      --policy-arn "$POLICY_ARN" \
      --version-id "$DEFAULT_VERSION" \
      --query 'PolicyVersion.Document.Statement[0].Action' \
      --output text 2>/dev/null || echo "")

    MISSING=""
    for action in $REQUIRED_ACTIONS; do
      if ! echo "$CURRENT_ACTIONS" | grep -q "$action"; then
        MISSING="$MISSING $action"
      fi
    done

    if [ -z "$MISSING" ]; then
      pass "Policy $IAM_POLICY has all required permissions ✔"
    else
      warn "Policy $IAM_POLICY is missing:$MISSING"
      if confirm "Update policy to add missing permissions?"; then
        # delete old versions if at limit (max 5)
        VERSION_COUNT=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
          --query 'length(Versions)' --output text 2>/dev/null || echo "0")
        if [ "$VERSION_COUNT" -ge 5 ]; then
          OLDEST=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
            --query 'Versions[-1].VersionId' --output text 2>/dev/null)
          aws iam delete-policy-version \
            --policy-arn "$POLICY_ARN" \
            --version-id "$OLDEST" 2>/dev/null || true
          info "Deleted oldest policy version $OLDEST to make room"
        fi
        aws iam create-policy-version \
          --policy-arn "$POLICY_ARN" \
          --policy-document "$DESIRED_POLICY_DOC" \
          --set-as-default > /dev/null
        pass "Policy $IAM_POLICY updated with all required permissions"
      else
        warn "Skipping — controller may fail with missing permissions"
      fi
    fi
  fi

  # ── check policy is attached to role ────────────────────────────────────────
  ATTACHED=$(aws iam list-attached-role-policies --role-name "$IAM_ROLE" \
    --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyArn" \
    --output text 2>/dev/null)
  if [ -n "$ATTACHED" ]; then
    pass "Policy $IAM_POLICY is attached to role ✔"
  else
    warn "Policy $IAM_POLICY is NOT attached to $IAM_ROLE"
    if confirm "Attach policy to role now?"; then
      aws iam attach-role-policy \
        --role-name "$IAM_ROLE" \
        --policy-arn "$POLICY_ARN"
      pass "Policy attached"
    fi
  fi

else
  # ── role does not exist — create everything ──────────────────────────────────
  warn "IAM role '$IAM_ROLE' does not exist"
  if confirm "Create IAM policy and role now?"; then
    # create or reuse policy
    POLICY_EXISTS=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
      --query 'Policy.Arn' --output text 2>/dev/null || echo "")
    if [ -z "$POLICY_EXISTS" ]; then
      aws iam create-policy \
        --policy-name "$IAM_POLICY" \
        --policy-document "$DESIRED_POLICY_DOC" > /dev/null
      pass "Policy $IAM_POLICY created"
    else
      pass "Policy $IAM_POLICY already exists — reusing"
    fi

    ROLE_ARN=$(aws iam create-role \
      --role-name "$IAM_ROLE" \
      --assume-role-policy-document "$DESIRED_TRUST" \
      --query 'Role.Arn' --output text)
    pass "Role created: $ROLE_ARN"

    aws iam attach-role-policy \
      --role-name "$IAM_ROLE" \
      --policy-arn "$POLICY_ARN"
    pass "Policy attached to role"
  else
    warn "Skipping — IRSA will not work without the role"
  fi
fi

pause

# ─── Step 7: EIP quota ────────────────────────────────────────────────────────
header "Step 7 — EIP quota"

CURRENT_QUOTA=$(aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-0263D0A3 \
  --region "$REGION" \
  --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")

CURRENT_USED=$(aws ec2 describe-addresses \
  --region "$REGION" \
  --query 'length(Addresses)' --output text 2>/dev/null || echo "unknown")

info "Current quota : $CURRENT_QUOTA EIPs in $REGION"
info "Currently used: $CURRENT_USED EIPs"

if [ "$CURRENT_QUOTA" != "unknown" ] && [ "$(echo "$CURRENT_QUOTA <= 5" | bc 2>/dev/null)" = "1" ]; then
  warn "Quota is only $CURRENT_QUOTA — not enough for production use"
  echo ""
  echo "  Request an increase via:"
  echo "  aws service-quotas request-service-quota-increase \\"
  echo "    --service-code ec2 --quota-code L-0263D0A3 \\"
  echo "    --desired-value 50 --region $REGION"
  echo ""
  echo "  Or use the AWS Console: Service Quotas → EC2 → EC2-VPC Elastic IPs"
  warn "Quota increases can take 24–48 hours — request now if going to production"
elif [ "$CURRENT_QUOTA" != "unknown" ]; then
  pass "EIP quota is $CURRENT_QUOTA — sufficient for testing"
fi

pause

# ─── Step 8: Helm install ─────────────────────────────────────────────────────
header "Step 8 — Helm install"

HELM_STATUS=$(helm status eip-controller -n eip-controller 2>/dev/null | grep "STATUS:" | awk '{print $2}' || echo "")

if [ "$HELM_STATUS" = "deployed" ]; then
  pass "eip-controller is already deployed"
  CURRENT_VERSION=$(helm list -n eip-controller -o json 2>/dev/null | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0]['chart'] if r else '')" 2>/dev/null || echo "")
  info "Installed chart: $CURRENT_VERSION"

  LATEST=$(helm search repo eip-controller/eip-controller --output json 2>/dev/null | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0]['version'] if r else '')" 2>/dev/null || echo "")
  info "Latest chart   : $LATEST"

  if [ -n "$LATEST" ] && [ -n "$CURRENT_VERSION" ] && ! echo "$CURRENT_VERSION" | grep -q "$LATEST"; then
    warn "Newer version available"
    if confirm "Upgrade to $LATEST now?"; then
      helm repo update eip-controller
      helm upgrade eip-controller eip-controller/eip-controller \
        --namespace eip-controller --reuse-values
      pass "Upgraded to $LATEST"
    fi
  else
    pass "Already on latest version ✔"
  fi
else
  warn "eip-controller is not installed"

  # get role ARN if not already set
  if [ -z "$ROLE_ARN" ]; then
    ROLE_ARN=$(aws iam get-role --role-name "$IAM_ROLE" \
      --query 'Role.Arn' --output text 2>/dev/null || echo "")
  fi

  if [ -z "$ROLE_ARN" ]; then
    fail "IAM role ARN not found — complete Step 6 first"
  else
    printf "  BAM register URL [http://placeholder.local/register]: "
    read -r BAM_REGISTER
    BAM_REGISTER="${BAM_REGISTER:-http://placeholder.local/register}"

    printf "  BAM remove URL   [http://placeholder.local/remove]: "
    read -r BAM_REMOVE
    BAM_REMOVE="${BAM_REMOVE:-http://placeholder.local/remove}"

    echo ""
    echo "  Will run:"
    echo "    helm install eip-controller eip-controller/eip-controller \\"
    echo "      --namespace eip-controller --create-namespace \\"
    echo "      --set aws.region=$REGION \\"
    echo "      --set aws.clusterName=$CLUSTER_NAME \\"
    echo "      --set bam.registerURL=$BAM_REGISTER \\"
    echo "      --set bam.removeURL=$BAM_REMOVE \\"
    echo "      --set serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=$ROLE_ARN"
    echo ""
    if confirm "Install now?"; then
      helm repo update eip-controller 2>/dev/null || true
      helm install eip-controller eip-controller/eip-controller \
        --namespace eip-controller --create-namespace \
        --set aws.region="$REGION" \
        --set aws.clusterName="$CLUSTER_NAME" \
        --set bam.registerURL="$BAM_REGISTER" \
        --set bam.removeURL="$BAM_REMOVE" \
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ROLE_ARN"
      pass "eip-controller installed"
    fi
  fi
fi

pause

# ─── Final verification ───────────────────────────────────────────────────────
header "Final verification"

echo ""
info "Controller pods:"
kubectl get pods -n eip-controller -o wide 2>/dev/null || warn "Could not list controller pods"

echo ""
info "Checking controller pods are on system nodes (not scraper nodes)..."
CTRL_NODES=$(kubectl get pods -n eip-controller \
  -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null)
ALL_SYSTEM=true
for node in $CTRL_NODES; do
  IS_SCRAPER=$(kubectl get node "$node" \
    -o jsonpath='{.metadata.labels.node\.kubernetes\.io/scraper}' 2>/dev/null || echo "")
  if [ "$IS_SCRAPER" = "true" ]; then
    fail "Controller pod is on scraper node $node — this will cause IRSA credential failures"
    ALL_SYSTEM=false
  else
    pass "Controller pod on non-scraper node $node ✔"
  fi
done

echo ""
echo -e "${BOLD}━━━  Setup Summary  ━━━${RESET}"
echo ""
echo "  Cluster       : $CLUSTER_NAME"
echo "  Region        : $REGION"
echo "  IAM Role ARN  : ${ROLE_ARN:-not set}"
echo "  OIDC ID       : $OIDC_ID"
echo "  EXTERNALSNAT  : $(kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_VPC_K8S_CNI_EXTERNALSNAT")].value}' \
  2>/dev/null || echo 'unknown')"
echo ""
echo "  To annotate a scraper pod:"
echo "    eip-controller.io/eip-managed: \"true\""
echo "    eip-controller.io/aggregation-group: \"<group-id>\""
echo ""
echo "  To verify EIP assignment after pod starts:"
echo "    kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.annotations.eip-controller\.io/eip-public-ip}'"
echo ""
pass "Setup complete."
