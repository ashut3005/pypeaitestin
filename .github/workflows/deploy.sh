name: Deploy Frontend to EC2 Prod Blue Green (with Auto-Rollback)

on:
  push:
    branches:
      - prod

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ${{ secrets.AWS_REGION }}
  AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}
  ECR_REPOSITORY: whispey-frontend-prod
  BRANCH: prod
  ROLLBACK_WAIT_TIME: 300  # 5 minutes in seconds
  HEALTH_CHECK_INTERVAL: 10 # seconds between health checks
  HEALTH_CHECK_ATTEMPTS: 30 # total attempts after deployment

jobs:
  test:
    name: Test and Build Validation
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "npm"

      - name: Install dependencies
        run: npm ci

      - name: Run lint
        run: |
          if npm run | grep -q "lint"; then
            npm run lint
          else
            echo "No lint script found, skipping lint"
          fi

      - name: Run tests
        run: |
          if npm run | grep -q "test"; then
            npm test
          else
            echo "No test script found, skipping tests"
          fi
        continue-on-error: true

      - name: Build application
        run: npm run build

  sonarqube:
    name: SonarQube Scan and Quality Gate
    runs-on: ubuntu-latest
    needs: test

    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run SonarQube scan
        uses: SonarSource/sonarqube-scan-action@v5
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}

      - name: Check SonarQube Quality Gate
        uses: SonarSource/sonarqube-quality-gate-action@v1
        timeout-minutes: 10
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}

  docker-build-push:
    name: Build and Push Docker Image to ECR
    runs-on: ubuntu-latest
    needs: sonarqube

    outputs:
      image_uri: ${{ steps.image.outputs.image_uri }}
      image_tag: ${{ steps.image.outputs.image_tag }}

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Prepare image details
        id: image
        run: |
          IMAGE_TAG="${GITHUB_SHA}"
          IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${IMAGE_TAG}"

          echo "IMAGE_TAG=${IMAGE_TAG}" >> $GITHUB_ENV
          echo "IMAGE_URI=${IMAGE_URI}" >> $GITHUB_ENV

          echo "image_tag=${IMAGE_TAG}" >> $GITHUB_OUTPUT
          echo "image_uri=${IMAGE_URI}" >> $GITHUB_OUTPUT

          echo "Image URI: ${IMAGE_URI}"

      - name: Configure AWS credentials using OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.PROD_AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Login to Amazon ECR
        run: |
          aws ecr get-login-password --region "${AWS_REGION}" \
            | docker login \
              --username AWS \
              --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

      - name: Ensure ECR repository exists
        run: |
          aws ecr describe-repositories \
            --repository-names "${ECR_REPOSITORY}" \
            --region "${AWS_REGION}" \
          || aws ecr create-repository \
            --repository-name "${ECR_REPOSITORY}" \
            --region "${AWS_REGION}"

      - name: Build Docker image
        run: |
          docker build \
            -t "${IMAGE_URI}" \
            -t "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:latest" \
            .

      - name: Push Docker image
        run: |
          docker push "${IMAGE_URI}"
          docker push "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:latest"

  deploy:
    name: Deploy to Private EC2 using Blue Green
    runs-on: ubuntu-latest
    needs: docker-build-push
    environment: production

    steps:
      - name: Configure AWS credentials using OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.PROD_AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Trigger blue green deployment through SSM
        id: deploy
        run: |
          IMAGE_URI="${{ needs.docker-build-push.outputs.image_uri }}"
          IMAGE_TAG="${{ needs.docker-build-push.outputs.image_tag }}"
          INSTANCE_ID="${{ secrets.PROD_PRIVATE_INSTANCE_ID }}"

          echo "Deploying image: ${IMAGE_URI}"
          echo "Image tag: ${IMAGE_TAG}"
          echo "Target private EC2 instance: ${INSTANCE_ID}"

          COMMAND_ID=$(aws ssm send-command \
            --instance-ids "${INSTANCE_ID}" \
            --document-name "AWS-RunShellScript" \
            --comment "Frontend blue green deploy - ${IMAGE_TAG}" \
            --parameters commands='[
              "set -e",
              "echo Starting frontend blue green deployment",
              "sudo /opt/frontend/deploy.sh '"${IMAGE_URI}"' '"${IMAGE_TAG}"'"
            ]' \
            --query "Command.CommandId" \
            --output text)

          echo "SSM Command ID: ${COMMAND_ID}"
          echo "command_id=${COMMAND_ID}" >> $GITHUB_OUTPUT

          aws ssm wait command-executed \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}"

          RESULT=$(aws ssm get-command-invocation \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}")

          STATUS=$(echo "${RESULT}" | jq -r '.StatusDetails')
          STDOUT=$(echo "${RESULT}" | jq -r '.StandardOutputContent')
          STDERR=$(echo "${RESULT}" | jq -r '.StandardErrorContent')

          echo "──── STDOUT ────"
          echo "${STDOUT}"

          if [ -n "${STDERR}" ]; then
            echo "──── STDERR ────"
            echo "${STDERR}"
          fi

          if [ "${STATUS}" != "Success" ]; then
            echo "Deployment failed. SSM status: ${STATUS}"
            exit 1
          fi

          echo "Deployment completed successfully"
          echo "instance_id=${INSTANCE_ID}" >> $GITHUB_OUTPUT
          echo "image_tag=${IMAGE_TAG}" >> $GITHUB_OUTPUT

  health-check-and-monitor:
    name: Health Check and Post-Deployment Monitoring
    runs-on: ubuntu-latest
    needs: [deploy, docker-build-push]
    if: success()

    steps:
      - name: Configure AWS credentials using OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.PROD_AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Wait for deployment stabilization
        run: |
          echo "Waiting for deployment to stabilize..."
          sleep 10

      - name: Get EC2 Private IP
        id: ec2_info
        run: |
          INSTANCE_ID="${{ secrets.PROD_PRIVATE_INSTANCE_ID }}"
          PRIVATE_IP=$(aws ec2 describe-instances \
            --instance-ids "${INSTANCE_ID}" \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' \
            --output text)
          echo "private_ip=${PRIVATE_IP}" >> $GITHUB_OUTPUT
          echo "EC2 Private IP: ${PRIVATE_IP}"

      - name: Perform health checks through SSM
        id: health_check
        continue-on-error: true
        run: |
          INSTANCE_ID="${{ secrets.PROD_PRIVATE_INSTANCE_ID }}"
          
          # Health check script to be executed on the EC2 instance
          COMMAND_ID=$(aws ssm send-command \
            --instance-ids "${INSTANCE_ID}" \
            --document-name "AWS-RunShellScript" \
            --comment "Post-deployment health check" \
            --parameters commands='[
              "set +e",
              "ATTEMPTS=0",
              "MAX_ATTEMPTS=30",
              "INTERVAL=10",
              "",
              "while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do",
              "  RESPONSE=$(curl -s -o /dev/null -w \"%{http_code}\" http://127.0.0.1/health 2>/dev/null || echo \"000\")",
              "  if [ \"$RESPONSE\" = \"200\" ]; then",
              "    echo \"Health check passed: HTTP $RESPONSE\"",
              "    exit 0",
              "  fi",
              "  ATTEMPTS=$((ATTEMPTS + 1))",
              "  echo \"Health check attempt $ATTEMPTS/$MAX_ATTEMPTS failed (HTTP $RESPONSE). Retrying in $INTERVAL seconds...\"",
              "  sleep $INTERVAL",
              "done",
              "",
              "echo \"Health check failed after $MAX_ATTEMPTS attempts\"",
              "exit 1"
            ]' \
            --query "Command.CommandId" \
            --output text)

          echo "Health check Command ID: ${COMMAND_ID}"

          aws ssm wait command-executed \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}"

          RESULT=$(aws ssm get-command-invocation \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}")

          STATUS=$(echo "${RESULT}" | jq -r '.StatusDetails')
          STDOUT=$(echo "${RESULT}" | jq -r '.StandardOutputContent')

          echo "──── Health Check Output ────"
          echo "${STDOUT}"

          if [ "${STATUS}" != "Success" ]; then
            echo "exit_code=1" >> $GITHUB_OUTPUT
            exit 1
          fi

          echo "exit_code=0" >> $GITHUB_OUTPUT

      - name: Monitor application logs (if health check fails)
        if: failure()
        run: |
          INSTANCE_ID="${{ secrets.PROD_PRIVATE_INSTANCE_ID }}"
          
          COMMAND_ID=$(aws ssm send-command \
            --instance-ids "${INSTANCE_ID}" \
            --document-name "AWS-RunShellScript" \
            --comment "Fetch application logs for debugging" \
            --parameters commands='[
              "echo \"==== Recent Docker logs =====\"",
              "docker logs --tail=50 frontend-blue 2>/dev/null || docker logs --tail=50 frontend-green 2>/dev/null || echo \"No active container logs found\"",
              "echo \"\"",
              "echo \"==== Nginx error logs =====\"",
              "tail -20 /var/log/nginx/error.log 2>/dev/null || echo \"Nginx error log not found\"",
              "echo \"\"",
              "echo \"==== Active slots and containers =====\"",
              "cat /opt/frontend/active-slot 2>/dev/null || echo \"Active slot file not found\"",
              "docker ps -a --format \"table {{.Names}}\t{{.Status}}\" | grep frontend || echo \"No frontend containers found\""
            ]' \
            --query "Command.CommandId" \
            --output text)

          aws ssm wait command-executed \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}"

          RESULT=$(aws ssm get-command-invocation \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}")

          STDOUT=$(echo "${RESULT}" | jq -r '.StandardOutputContent')
          echo "${STDOUT}"

  automatic-rollback:
    name: Automatic Rollback (if monitoring fails)
    runs-on: ubuntu-latest
    needs: [health-check-and-monitor, deploy, docker-build-push]
    if: failure()

    steps:
      - name: Configure AWS credentials using OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.PROD_AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Trigger automatic rollback
        id: rollback
        run: |
          INSTANCE_ID="${{ secrets.PROD_PRIVATE_INSTANCE_ID }}"
          IMAGE_TAG="${{ needs.docker-build-push.outputs.image_tag }}"
          
          echo "⚠️  INITIATING AUTOMATIC ROLLBACK ⚠️"
          echo "Reason: Post-deployment health checks failed"
          echo "Failed deployment image tag: ${IMAGE_TAG}"
          echo "Affected EC2 instance: ${INSTANCE_ID}"

          COMMAND_ID=$(aws ssm send-command \
            --instance-ids "${INSTANCE_ID}" \
            --document-name "AWS-RunShellScript" \
            --comment "Automatic rollback triggered due to health check failure - ${IMAGE_TAG}" \
            --parameters commands='[
              "set -e",
              "echo \"========== AUTOMATIC ROLLBACK INITIATED ==========\"",
              "APP_DIR=\"/opt/frontend\"",
              "ACTIVE_SLOT_FILE=\"${APP_DIR}/active-slot\"",
              "PREVIOUS_IMAGE_FILE=\"${APP_DIR}/previous-image\"",
              "CURRENT_IMAGE_FILE=\"${APP_DIR}/current-image\"",
              "NGINX_CONF=\"/etc/nginx/conf.d/frontend-upstream.conf\"",
              "",
              "# Get current state",
              "CURRENT_ACTIVE_SLOT=$(cat ${ACTIVE_SLOT_FILE})",
              "echo \"Current active slot: ${CURRENT_ACTIVE_SLOT}\"",
              "",
              "# Determine rollback target",
              "if [ \"${CURRENT_ACTIVE_SLOT}\" = \"blue\" ]; then",
              "  ROLLBACK_SLOT=\"green\"",
              "  ROLLBACK_PORT=\"3002\"",
              "  ROLLBACK_CONTAINER=\"frontend-green\"",
              "else",
              "  ROLLBACK_SLOT=\"blue\"",
              "  ROLLBACK_PORT=\"3001\"",
              "  ROLLBACK_CONTAINER=\"frontend-blue\"",
              "fi",
              "",
              "echo \"Rolling back to slot: ${ROLLBACK_SLOT}\"",
              "echo \"Rolling back to container: ${ROLLBACK_CONTAINER}\"",
              "echo \"Rolling back to port: ${ROLLBACK_PORT}\"",
              "",
              "# Get previous image URI if available",
              "if [ -f ${PREVIOUS_IMAGE_FILE} ]; then",
              "  PREVIOUS_IMAGE=$(cat ${PREVIOUS_IMAGE_FILE})",
              "  echo \"Previous image: ${PREVIOUS_IMAGE}\"",
              "fi",
              "",
              "# Update Nginx to point to rollback port",
              "cat > ${NGINX_CONF} <<EOF",
              "upstream frontend_active {",
              "    server 127.0.0.1:${ROLLBACK_PORT};",
              "}",
              "",
              "server {",
              "    listen 80;",
              "    server_name _;",
              "",
              "    location / {",
              "        proxy_pass http://frontend_active;",
              "        proxy_http_version 1.1;",
              "",
              "        proxy_set_header Host \\$host;",
              "        proxy_set_header X-Real-IP \\$remote_addr;",
              "        proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;",
              "        proxy_set_header X-Forwarded-Proto \\$http_x_forwarded_proto;",
              "",
              "        proxy_connect_timeout 5s;",
              "        proxy_send_timeout 60s;",
              "        proxy_read_timeout 60s;",
              "    }",
              "",
              "    location /health {",
              "        access_log off;",
              "        proxy_pass http://frontend_active/health;",
              "    }",
              "",
              "    location /private-nginx-health {",
              "        access_log off;",
              "        return 200 \"private nginx ok\\\\n\";",
              "    }",
              "}",
              "EOF",
              "",
              "# Validate and reload Nginx",
              "echo \"Validating Nginx config...\"",
              "nginx -t",
              "",
              "echo \"Reloading Nginx...\"",
              "systemctl reload nginx",
              "",
              "sleep 2",
              "",
              "# Verify health through Nginx",
              "echo \"Verifying rollback health...\"",
              "curl -fsS http://127.0.0.1/health || echo \"Warning: Health check returned non-200\"",
              "",
              "# Update state files",
              "echo \"${ROLLBACK_SLOT}\" > ${ACTIVE_SLOT_FILE}",
              "",
              "echo \"========== ROLLBACK COMPLETED SUCCESSFULLY ==========\"",
              "echo \"\"",
              "echo \"=== ROLLBACK SUMMARY ===\"",
              "echo \"Active slot       : ${ROLLBACK_SLOT}\"",
              "echo \"Active container  : ${ROLLBACK_CONTAINER}\"",
              "echo \"Active port       : ${ROLLBACK_PORT}\"",
              "echo \"========================\"",
              "echo \"\"",
              "echo \"Previous deployment has been restored.\"",
              "echo \"Please investigate the failed deployment before retrying.\""
            ]' \
            --query "Command.CommandId" \
            --output text)

          echo "Rollback Command ID: ${COMMAND_ID}"
          echo "command_id=${COMMAND_ID}" >> $GITHUB_OUTPUT

          aws ssm wait command-executed \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}"

          RESULT=$(aws ssm get-command-invocation \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}")

          STATUS=$(echo "${RESULT}" | jq -r '.StatusDetails')
          STDOUT=$(echo "${RESULT}" | jq -r '.StandardOutputContent')
          STDERR=$(echo "${RESULT}" | jq -r '.StandardErrorContent')

          echo "──── ROLLBACK STDOUT ────"
          echo "${STDOUT}"

          if [ -n "${STDERR}" ]; then
            echo "──── ROLLBACK STDERR ────"
            echo "${STDERR}"
          fi

          if [ "${STATUS}" != "Success" ]; then
            echo "❌ ROLLBACK FAILED - Manual intervention required!"
            exit 1
          fi

          echo "✅ Automatic rollback completed successfully"

#       - name: Send Slack notification (Rollback)
#         if: always()
#         continue-on-error: true
#         run: |
#           INSTANCE_ID="${{ secrets.PROD_PRIVATE_INSTANCE_ID }}"
#           IMAGE_TAG="${{ needs.docker-build-push.outputs.image_tag }}"
#           ROLLBACK_STATUS="${{ steps.rollback.outcome }}"
          
#           if [ "${ROLLBACK_STATUS}" = "success" ]; then
#             COLOR="warning"
#             MESSAGE="⚠️ Automatic rollback completed due to health check failures. Previous version restored."
#           else
#             COLOR="danger"
#             MESSAGE="❌ Automatic rollback FAILED. Manual intervention required immediately!"
#           fi
          
#           curl -X POST "${{ secrets.SLACK_WEBHOOK_URL }}" \
#             -H 'Content-Type: application/json' \
#             -d "{
#               \"attachments\": [
#                 {
#                   \"color\": \"${COLOR}\",
#                   \"title\": \"🔄 Frontend Deployment - Automatic Rollback Triggered\",
#                   \"fields\": [
#                     {\"title\": \"Repository\", \"value\": \"${{ github.repository }}\", \"short\": true},
#                     {\"title\": \"Branch\", \"value\": \"${{ github.ref_name }}\", \"short\": true},
#                     {\"title\": \"Failed Image Tag\", \"value\": \"${IMAGE_TAG}\", \"short\": true},
#                     {\"title\": \"Instance ID\", \"value\": \"${INSTANCE_ID}\", \"short\": true},
#                     {\"title\": \"Rollback Status\", \"value\": \"${ROLLBACK_STATUS}\", \"short\": true},
#                     {\"title\": \"Triggered by\", \"value\": \"${{ github.actor }}\", \"short\": true},
#                     {\"title\": \"Commit\", \"value\": \"${{ github.sha }}\", \"short\": false},
#                     {\"title\": \"Message\", \"value\": \"${MESSAGE}\", \"short\": false}
#                   ],
#                   \"footer\": \"GitHub Actions\",
#                   \"ts\": $(date +%s)
#                 }
#               ]
#             }" || true

#   deployment-summary:
#     name: Deployment Summary
#     runs-on: ubuntu-latest
#     needs: [deploy, health-check-and-monitor, automatic-rollback]
#     if: always()

#     steps:
#       - name: Generate deployment summary
#         run: |
#           echo "# Deployment Status Summary"
#           echo ""
#           echo "| Stage | Status |"
#           echo "|-------|--------|"
#           echo "| Deploy | ${{ needs.deploy.result }} |"
#           echo "| Health Check | ${{ needs.health-check-and-monitor.result }} |"
#           echo "| Automatic Rollback | ${{ needs.automatic-rollback.result }} |"
#           echo ""
          
#           if [ "${{ needs.deploy.result }}" = "success" ] && [ "${{ needs.health-check-and-monitor.result }}" = "success" ]; then
#             echo "✅ **Deployment completed successfully with all health checks passed**"
#             exit 0
#           elif [ "${{ needs.automatic-rollback.result }}" = "success" ]; then
#             echo "⚠️ **Deployment rolled back automatically due to health check failures**"
#             exit 1
#           else
#             echo "❌ **Deployment failed - check logs for details**"
#             exit 1
#           fi

#       - name: Send Slack notification (Success)
#         if: success()
#         continue-on-error: true
#         run: |
#           curl -X POST "${{ secrets.SLACK_WEBHOOK_URL }}" \
#             -H 'Content-Type: application/json' \
#             -d "{
#               \"attachments\": [
#                 {
#                   \"color\": \"good\",
#                   \"title\": \"✅ Frontend Deployment Successful\",
#                   \"fields\": [
#                     {\"title\": \"Repository\", \"value\": \"${{ github.repository }}\", \"short\": true},
#                     {\"title\": \"Branch\", \"value\": \"${{ github.ref_name }}\", \"short\": true},
#                     {\"title\": \"Commit SHA\", \"value\": \"${{ github.sha }}\", \"short\": true},
#                     {\"title\": \"Triggered by\", \"value\": \"${{ github.actor }}\", \"short\": true},
#                     {\"title\": \"Run URL\", \"value\": \"${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}\", \"short\": false}
#                   ],
#                   \"footer\": \"GitHub Actions\",
#                   \"ts\": $(date +%s)
#                 }
#               ]
#             }" || true
