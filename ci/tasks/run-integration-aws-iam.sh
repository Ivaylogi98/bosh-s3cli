#!/usr/bin/env bash
set -euo pipefail

my_dir="$( cd "$(dirname "${0}")" && pwd )"
release_dir="$( cd "${my_dir}" && cd ../.. && pwd )"
workspace_dir="$( cd "${release_dir}" && cd .. && pwd )"

source "${release_dir}/ci/tasks/utils.sh"
export GOPATH=${workspace_dir}
export PATH=${GOPATH}/bin:${PATH}

: "${access_key_id:?}"
: "${secret_access_key:?}"
: "${region_name:?}"
: "${stack_name:?}"

# Just need these to get the stack info and to create/invoke the Lambda function
export AWS_ACCESS_KEY_ID=${access_key_id}
export AWS_SECRET_ACCESS_KEY=${secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

stack_info=$(get_stack_info "${stack_name}")
bucket_name=$(get_stack_info_of "${stack_info}" "BucketName")
iam_role_arn=$(get_stack_info_of "${stack_info}" "IamRoleArn")
lambda_payload="{\"region\": \"${region_name}\", \"bucket_name\": \"${bucket_name}\", \"s3_host\": \"s3.amazonaws.com\"}"

lambda_log=$(mktemp -t "XXXXXX-lambda.log")
trap "cat ${lambda_log}" EXIT

pushd "${release_dir}" > /dev/null
  echo -e "\n building artifact with $(go version)..."

  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o out/s3cli \
    github.com/cloudfoundry/bosh-s3cli
  CGO_ENABLED=0 scripts/ginkgo build integration

  zip -j payload.zip integration/integration.test out/s3cli ci/assets/lambda_function.py

  lambda_function_name=s3cli-integration-$(date +%s)

  echo "Creating Lambda function: ${lambda_function_name}"
  creation_output=$(aws lambda create-function \
  --region "${region_name}" \
  --function-name "${lambda_function_name}" \
  --zip-file fileb://payload.zip \
  --role "${iam_role_arn}" \
  --timeout 300 \
  --handler lambda_function.test_runner_handler \
  --runtime python3.9 2>&1)

  create_exit_code=$?
  echo "${creation_output}"

  if [ ${create_exit_code} -ne 0 ]; then
    echo "ERROR: Failed to create Lambda function"
    exit 1
  fi

  echo "Waiting for Lambda function to become active..."
  tries=0
  max_tries=30
  get_function_status_command="aws lambda get-function --region ${region_name} --function-name ${lambda_function_name}"

  while [ $tries -lt $max_tries ]; do
    sleep 2
    tries=$((tries + 1))
    echo "Checking for function readiness; attempt: $tries"

    set +e
    function_status=$(${get_function_status_command} 2>&1)
    get_exit_code=$?
    set -e

    if [ ${get_exit_code} -eq 0 ]; then
      state=$(echo "${function_status}" | jq -r ".Configuration.State")
      state_reason=$(echo "${function_status}" | jq -r ".Configuration.StateReason // empty")

      echo "Function state: ${state}"
      if [ -n "${state_reason}" ]; then
        echo "State reason: ${state_reason}"
      fi

      if [ "${state}" = "Active" ]; then
        echo "Lambda function is active and ready"
        break
      elif [ "${state}" = "Failed" ]; then
        echo "ERROR: Lambda function creation failed"
        echo "${function_status}" | jq .
        exit 1
      fi
    else
      echo "Function not found yet, retrying..."
      if [ $tries -eq $max_tries ]; then
        echo "ERROR: Function not found after ${max_tries} attempts"
        echo "Last error: ${function_status}"
        exit 1
      fi
    fi
  done

  echo "Invoking Lambda function with payload: ${lambda_payload}"
  set +e
  invoke_output=$(aws lambda invoke \
  --invocation-type RequestResponse \
  --function-name "${lambda_function_name}" \
  --region "${region_name}" \
  --log-type Tail \
  --payload "${lambda_payload}" \
  "${lambda_log}" 2>&1)
  invoke_exit_code=$?
  set -e

  echo "${invoke_output}" | tee lambda_output.json

  if [ ${invoke_exit_code} -ne 0 ]; then
    echo "ERROR: Failed to invoke Lambda function"
    echo "Exit code: ${invoke_exit_code}"
    echo "Output: ${invoke_output}"

    # Try to get function details for debugging
    echo "Attempting to retrieve function details..."
    aws lambda get-function --region "${region_name}" --function-name "${lambda_function_name}" 2>&1 || true
    exit 1
  fi

  set +e
    log_group_name="/aws/lambda/${lambda_function_name}"

    logs_command="aws logs describe-log-streams --log-group-name=${log_group_name}"
    tries=0

    log_streams_json=$(${logs_command})
    while [[ ( $? -ne 0 ) && ( $tries -ne 5 ) ]] ; do
      sleep 2
      echo "Retrieving CloudWatch logs; attempt: $tries"
      tries=$((tries + 1))
      log_streams_json=$(${logs_command})
    done
  set -e

  log_stream_name=$(echo "${log_streams_json}" | jq -r ".logStreams[0].logStreamName")

  echo "Lambda execution log output for ${log_stream_name}"

  tries=0
  > lambda_output.log
  while [[ ( "$(du lambda_output.log | cut -f 1)" -eq "0" ) && ( $tries -ne 20 ) ]] ; do
    sleep 2
    tries=$((tries + 1))
    echo "Retrieving CloudWatch events; attempt: $tries"

    aws logs get-log-events \
      --log-group-name="${log_group_name}" \
      --log-stream-name="${log_stream_name}" \
    | jq -r ".events | map(.message) | .[]" | tee lambda_output.log
  done

  set +e
    aws lambda delete-function \
    --function-name "${lambda_function_name}" 2>/dev/null

    aws logs delete-log-group --log-group-name="${log_group_name}" 2>/dev/null
  set -e

  jq -r ".FunctionError" < lambda_output.json | grep -v -e "Handled" -e "Unhandled"
popd > /dev/null
