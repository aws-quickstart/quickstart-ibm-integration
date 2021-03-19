#!/bin/bash
#******************************************************************************
# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2020. All Rights Reserved.
#
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.
#******************************************************************************
# PREREQUISITES:
#   - Bash terminal
#   - Existing OpenShift Cluster with version > 4.4.13
#   - Logged into cluster on the OC CLI (https://docs.openshift.com/container-platform/4.4/cli_reference/openshift_cli/getting-started-cli.html)
#
# MADATORY PARAMETERS:
#   -n : <namespace> (string), Defaults to "cp4i"
#   -k : <entitlement key> (string)
#
# USAGE:
#   For usage and optional parameters see README.md
#

# initial variables
namespace='integration'
maxWaitTime=1800
maxTrials=2
currentTrial=1
entitlementKey=''
platformNavigatorReplicas="3"
asperaKey=''
capabilityAPIConnect="false";
capabilityAPPConnectDashboard="false";
capabilityAPPConenctDesigner="false";
capabilityAssetRepository="false";
capabilityOperationsDashboard="false";
deploymentScriptsPath="$(pwd)/cp4i-deployment/capabilities-runtimes-scripts";

storageClass="ocs-storagecluster-cephfs"
runtimeMQ="false";
runtimeKafka="false";
runtimeAspera="false";
runtimeDataPower="false";
platformPassword="";

# get cli input flags
while getopts 'w:t:n:k:c:a:1:2:3:4:5:6:7:8:9:p:' flag; do
  case "${flag}" in
  
    n) namespace="${OPTARG}" ;;
    w) maxWaitTime="${OPTARG}" ;;
    t) maxTrials="${OPTARG}" ;;
    k) entitlementKey="${OPTARG}" ;;
    c) currentTrial="${OPTARG}" ;;
    a) asperaKey="${OPTARG}" ;;
    1) capabilityAPIConnect=$(echo "${OPTARG}" | awk '{print tolower($0)}');;
    2) capabilityAPPConnectDashboard=$(echo "${OPTARG}" | awk '{print tolower($0)}');;
    3) capabilityAPPConenctDesigner=$(echo "${OPTARG}" | awk '{print tolower($0)}');;
    4) capabilityOperationsDashboard=$(echo "${OPTARG}" | awk '{print tolower($0)}');;
    5) capabilityAssetRepository=$(echo "${OPTARG}" | awk '{print tolower($0)}');;
    6) runtimeMQ=$(echo "${OPTARG}" | awk '{print tolower($0)}');;
    7) runtimeKafka=$(echo "${OPTARG}" | awk '{print tolower($0)}');;
    8) runtimeAspera=$(echo "${OPTARG}" | awk '{print tolower($0)}');;
    9) runtimeDataPower=$(echo "${OPTARG}" | awk '{print tolower($0)}');;
    p) platformPassword="${OPTARG}" ;;



  esac
done
echo "DEBUG: capabilityAPIConnect: ${capabilityAPIConnect}"
echo "DEBUG: capabilityAPPConnectDashboard: ${capabilityAPPConnectDashboard}"
echo "DEBUG: capabilityAPPConenctDesigner: ${capabilityAPPConenctDesigner}"
echo "DEBUG: capabilityOperationsDashboard: ${capabilityOperationsDashboard}"
echo "DEBUG: capabilityAssetRepository: ${capabilityAssetRepository}"
echo "DEBUG: runtimeMQ: ${runtimeMQ}"
echo "DEBUG: runtimeKafka: ${runtimeKafka}"
echo "DEBUG: runtimeAspera: ${runtimeAspera}"
echo "DEBUG: runtimeDataPower: ${runtimeDataPower}"



# check for missing mandatory namespace
if [ -z "$namespace" ]
then
      echo "ERROR: missing namespace argument, make sure to pass namespace, ex: '-n mynamespace'"
      exit 1;
fi

# check for missing mandatory entitlement key
if [ -z "$entitlementKey" ]
then
      echo "ERROR: missing ibm entitlement key argument, make sure to pass a key, ex: '-k mykey'"
      exit 1;
fi



# retry the installation - either with uninstalling or not
# increments the number of trials
# only retry if maximum number of trials isn't reached yet
function retry {
  # boolean flag indicates whether to uninstall or not
  uninstall=${1}

  if [[ $uninstall == true ]]
  then
    # uninstall
    sh ./cp4i-uninstall.sh -n ${namespace}
  fi
  
  # incermenent currentTrial
  currentTrial=$((currentTrial + 1))

  if [[ $currentTrial -gt $maxTrials ]]
    then 
    echo "ERROR: Max Install Trials Reached, exiting now";
    exit 1
  else
    # recall install inscript with current trial
    echo "INFO: Attempt Trial Number ${currentTrial} to install";

    install
  fi
}

# Delete existing subscriptions and install plans wich are stuck in "UpgradePending"
# Fixes a known issue in common services https://www.ibm.com/support/knowledgecenter/SSHKN6/installer/3.x.x/troubleshoot/op_hang.html
function cleanSubscriptions {
  # Get a list of subscriptions stuck in "UpgradePending"
  SUBSCRIPTIONS=$(oc get subscriptions -n ibm-common-services -o json |\
    jq -r '.items[] | select(.status.state=="UpgradePending") | .metadata.name' \
  )

  if [[ "$SUBSCRIPTIONS" == "" ]]; then
    echo "INFO: No subscriptions in UpgradePending"
  else
    echo "INFO: The following subscriptions are stuck in UpgradePending:"
    echo "$SUBSCRIPTIONS"

    # Get a unique list of install plans for subscriptions that are stuck in "UpgradePending"
    INSTALL_PLANS=$(oc get subscription -n ibm-common-services -o json |\
      jq -r '[ .items[] | select(.status.state=="UpgradePending") | .status.installplan.name] | unique | .[]' \
    )
    echo "INFO: Associated installplans:"
    echo "$INSTALL_PLANS"

    # Delete the InstallPlans
    oc delete installplans -n ibm-common-services $INSTALL_PLANS

    # Delete the Subscriptions
    oc delete subscriptions -n ibm-common-services $SUBSCRIPTIONS
  fi
}

# Delete a subscription with the given name in the given namespace
function delete_subscription {
  NAMESPACE=${1}
  name=${2}
  echo "INFO: Deleting subscription $name from $NAMESPACE"
  SUBSCRIPTIONS=$(oc get subscriptions -n ${NAMESPACE}  -o json |\
    jq -r ".items[] | select(.metadata.name==\"$name\") | .metadata.name "\
  )
  echo "DEBUG: Found subscriptions:"
  echo "$SUBSCRIPTIONS"

  # Get a unique list of install plans for subscriptions that are stuck in "UpgradePending"
  INSTALL_PLANS=$(oc get subscription -n ${NAMESPACE}  -o json |\
    jq -r "[ .items[] | select(.metadata.name==\"$name\")| .status.installplan.name] | unique | .[]" \
  )
  echo "DEBUG: Associated installplans:"
  echo "$INSTALL_PLANS"

  # Get the csv
  CSV=$(oc get subscription -n ${NAMESPACE} ${name} -o json | jq -r .status.currentCSV)
  echo "DEBUG: Associated ClusterServiceVersion:"
  echo "$CSV"

  # Delete CSV
  oc delete csv -n ${NAMESPACE} $CSV

  # Delete the InstallPlans
  oc delete installplans -n ${NAMESPACE} $INSTALL_PLANS

  # Delete the Subscriptions
  oc delete subscriptions -n ${NAMESPACE}  $SUBSCRIPTIONS
}

# Get auth port with internal url and apply the operand config in common services namespace
function IAM_Update_OperandConfig {

  # set EXTERNAL to external url - if not found retry
  EXTERNAL=$(oc get configmap console-config -n openshift-console -o jsonpath="{.data['console-config\.yaml']}" | grep -A2 'clusterInfo:' | tail -n1 | awk '{ print $2}' )
  if [ -z "$EXTERNAL" ] 
  then
  echo "ERROR: Failed getting EXTERNAL in IAM_Update_OperandConfig";
    retry true
  fi
  echo "INFO: External url: ${EXTERNAL}"

  # set INT_URL to internal url - if not found retry
  export INT_URL="${EXTERNAL}/.well-known/oauth-authorization-server"
  if [ -z "$INT_URL" ] 
  then
    echo "ERROR: Failed getting INT_URL in IAM_Update_OperandConfig";

    retry true
  fi
    echo "INFO: INT_URL: ${INT_URL}"

  # set IAM_URL to iam url - if not found retry
  export IAM_URL=$(curl -k $INT_URL | jq -r '.issuer')
  if [ -z "$IAM_URL" ] 
  then
      echo "ERROR: Failed getting IAM_URL in IAM_Update_OperandConfig";

    retry true
  fi
  echo "INFO: IAM URL : ${IAM_URL}"

  # update OperandConfig of common services to use IAM Url - if it fails retry
  echo "INFO: Updating the OperandConfig 'common-service' for IAM Authentication"
  oc get OperandConfig -n ibm-common-services $(oc get OperandConfig -n ibm-common-services | sed -n 2p | awk '{print $1}') -o json | jq '(.spec.services[] | select(.name == "ibm-iam-operator") | .spec.authentication)|={"config":{"roksEnabled":true,"roksURL":"'$IAM_URL'","roksUserPrefix":"IAM#"}}' | oc apply -f -
  if [[ $? != 0 ]]
  then 
    echo "ERROR: Failed Updating OperandConfig";
    retry true
  fi
}

# print a formatted time in minutes and seconds from the given input in seconds
function output_time {
  SECONDS=${1}
  if((SECONDS>59));then
    printf "%d minutes, %d seconds" $((SECONDS/60)) $((SECONDS%60))
  else
    printf "%d seconds" $SECONDS
  fi
}

# wait for a subscription to be successfully installed
# takes the name and the namespace as input
# waits for the specified maxWaitTime - if that is exceeded the subscriptions is deleted and it returns 1
function wait_for_subscription {
  NAMESPACE=${1}
  NAME=${2}

  phase=""
  # inital time
  time=0
  # wait interval - how often the status is checked in seconds
  wait_time=5

  until [[ "$phase" == "Succeeded" ]]; do
    csv=$(oc get subscription -n ${NAMESPACE} ${NAME} -o json | jq -r .status.currentCSV)
    wait=0
    if [[ "$csv" == "null" ]]; then
      echo "INFO: Waited for $(output_time $time), not got csv for subscription"
      wait=1
    else
      phase=$(oc get csv -n ${NAMESPACE} $csv -o json | jq -r .status.phase)
      if [[ "$phase" != "Succeeded" ]]; then
        echo "INFO: Waited for $(output_time $time), csv not in Succeeded phase, currently: $phase"
        wait=1
      fi
    fi

    # if subscriptions hasn't succeeded yet: wait
    if [[ "$wait" == "1" ]]; then
      ((time=time+$wait_time))
      if [ $time -gt $maxWaitTime ]; then
        echo "ERROR: Failed after waiting for $((maxWaitTime/60)) minutes"
        # delete subscription after maxWaitTime has exceeded
        delete_subscription ${NAMESPACE} ${NAME}
        return 1
      fi

      # wait
      sleep $wait_time
    fi
  done
  echo "INFO: $NAME has succeeded"
}

# create a subscriptions and wait for it to be in succeeded state - if it fails: retry ones
# if it fails 2 times retry the whole installation
# param namespace: the namespace the subscription is created in
# param source: the catalog source of the operator
# param name: name of the subscription
# param channel: channel to be used for the subscription
# param retried: indicate whether this subscription has failed before and this is the retry
function create_subscription {
  NAMESPACE=${1}
  SOURCE=${2}
  NAME=${3}
  CHANNEL=${4}
  RETRIED=${5:-false};
  SOURCE_namespace="openshift-marketplace"
  SUBSCRIPTION_NAME="${NAME}-${CHANNEL}-${SOURCE}-${SOURCE_namespace}"

  # create subscription itself
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${NAME}
  source: ${SOURCE}
  sourceNamespace: ${SOURCE_namespace}
EOF

  # wait for it to succeed and retry if not
  wait_for_subscription ${NAMESPACE} ${SUBSCRIPTION_NAME}
  if [[ "$?" != "0"   ]]; then
    if [[ $RETRIED == true ]]
    then
      echo "ERROR: Failed to install subscription ${NAME} after retrial, reinstalling now";
      retry true
    fi
    echo "INFO: retrying subscription ${NAME}";
    create_subscription ${NAMESPACE} ${SOURCE} ${NAME} ${CHANNEL} true
  fi
}

# install an instance of the platform navigator operator
# wait until it is ready - if it fails retry
function install_platform_navigator {
  RETRIED=${1:-false};
  time=0
while ! cat <<EOF | oc apply -f -
apiVersion: integration.ibm.com/v1beta1
kind: PlatformNavigator
metadata:
  name: ${namespace}-navigator
  namespace: ${namespace}
spec:
  license:
    accept: true
  mqDashboard: true
  replicas: ${platformNavigatorReplicas}
  version: "2020.4.1-eus"
EOF

  do
    if [ $time -gt $maxWaitTime ]; then
      echo "ERROR: Exiting installation as timeout waiting for PlatformNavigator to be created"
      return 1
    fi
    echo "INFO: Waiting for PlatformNavigator to be created. Waited ${time} seconds(s)."
    time=$((time + 1))
    sleep 60
  done

  # Waiting for platform navigator object to be ready
  echo "INFO: Waiting for platform navigator object to be ready"

  time=0
  while [[ "$(oc get PlatformNavigator -n ${namespace} ${namespace}-navigator -o json | jq -r '.status.conditions[] | select(.type=="Ready").status')" != "True" ]]; do
    echo "INFO: The platform navigator object status:"
    echo "INFO: $(oc get PlatformNavigator -n ${namespace} ${namespace}-navigator)"
    if [ $time -gt $maxWaitTime ]; then
      echo "ERROR: Exiting installation Platform Navigator object is not ready"
      if [[ $RETRIED == false ]]
      then 
        echo "INFO: Retrying to install Platform Navigator"
        install_platform_navigator true
      else 
      retry true
      fi
    fi

    echo "INFO: Waiting for platform navigator object to be ready. Waited ${time} second(s)."

    time=$((time + 60))
    sleep 60
  done
}

function wait_for_product {
  type=${1}
  release_name=${2}
    time=0
    status=false;
  while [[ "$status" == false ]]; do
        currentStatus="$(oc get ${type} -n ${namespace} ${release_name} -o json | jq -r '.status.conditions[] | select(.type=="Ready").status')";
        if [ "$currentStatus" == "True" ]
        then
          status=true
        fi

    if [ "$status" == false ] 
    then
        currentStatus="$(oc get ${type} -n ${namespace} ${release_name} -o json | jq -r '.status.phase')"

       if [ "$currentStatus" == "Ready" ] || [ "$currentStatus" == "Running" ]
        then
          status=true
        fi
    fi


  
    echo "INFO: The ${type}   status:"
    echo "INFO: $(oc get ${type} -n ${namespace} ${release_name} )"
    if [ $time -gt $maxWaitTime ]; then
      echo "ERROR: Exiting installation ${type}  object is not ready"
      return 1
    fi

    echo "INFO: Waiting for ${type} object to be ready. Waited ${time} second(s)."

    time=$((time + 5))
    sleep 5
  done
}

function install {
# -------------------- BEGIN INSTALLATION --------------------
echo "INFO: Starting installation of Cloud Pak for Integration in $namespace"


# create new project
oc new-project $namespace
# check if the project has been created - if not retry
oc get project $namespace
if [[ $? == 1 ]]
  then
    retry false
fi

# Create IBM Entitlement Key Secret
oc create secret docker-registry ibm-entitlement-key \
    --docker-username=cp \
    --docker-password=$entitlementKey \
    --docker-server=cp.icr.io \
    --namespace=${namespace}

# check if it has been created - if not retry
oc get secret ibm-entitlement-key -n $namespace
if [[ $? == 1 ]]
  then
    retry false
fi

# Create Open Cloud and IBM Cloud Operator CatalogSource
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: opencloud-operators
  namespace: openshift-marketplace
spec:
  displayName: IBMCS Operators
  publisher: IBM
  sourceType: grpc
  image: docker.io/ibmcom/ibm-common-service-catalog:latest
  updateStrategy:
    registryPoll:
      interval: 45m
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: ibm-operator-catalog
  publisher: IBM Content
  sourceType: grpc
  image: docker.io/ibmcom/ibm-operator-catalog
  updateStrategy:
    registryPoll:
      interval: 45m
---
EOF

# check if Operator catalog source has been created - if not retry
oc get CatalogSource opencloud-operators -n openshift-marketplace
if [[ $? == 1 ]]
  then
    retry false
fi

oc get CatalogSource ibm-operator-catalog -n openshift-marketplace
if [[ $? == 1 ]]
  then
    retry false
fi

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${namespace}-og
  namespace: ${namespace}
spec:
  targetNamespaces:
    - ${namespace}
EOF

# check if Operator Group has been created
oc get OperatorGroup ${namespace}-og -n ${namespace}
if [[ $? != 0 ]]
  then
    retry false
fi

# install common services
echo "INFO: Applying individual subscriptions for cp4i dependencies"
create_subscription ${namespace} "opencloud-operators" "ibm-common-service-operator" "stable-v1"

# wait for the Operand Deployment Lifecycle Manager to be installed
wait_for_subscription ibm-common-services operand-deployment-lifecycle-manager-app
if [[ $? != 0 ]]
  then
    retry true
fi

# install all the operators one by one
echo "INFO: Installing CP4I operators..."
create_subscription ${namespace} "certified-operators" "couchdb-operator-certified" "v1.4"
create_subscription ${namespace} "ibm-operator-catalog" "ibm-cloud-databases-redis-operator" "v1.1"
create_subscription ${namespace} "ibm-operator-catalog" "aspera-hsts-operator" "v1.2-eus"
create_subscription ${namespace} "ibm-operator-catalog" "datapower-operator" "v1.2-eus"
create_subscription ${namespace} "ibm-operator-catalog" "ibm-appconnect" "v1.1-eus"
create_subscription ${namespace} "ibm-operator-catalog" "ibm-eventstreams" "v2.2-eus"
create_subscription ${namespace} "ibm-operator-catalog" "ibm-mq" "v1.3-eus"
create_subscription ${namespace} "ibm-operator-catalog" "ibm-integration-asset-repository" "v1.1-eus"
# Apply the subscription for navigator. This needs to be before apic so apic knows it's running in cp4i
create_subscription ${namespace} "ibm-operator-catalog" "ibm-integration-platform-navigator" "v4.1-eus"
create_subscription ${namespace} "ibm-operator-catalog" "ibm-apiconnect" "v2.1-eus"
create_subscription ${namespace} "ibm-operator-catalog" "ibm-integration-operations-dashboard" "v2.1-eus"

# Wait for the OperandConfig to appear in the common services namespace
time=0
while [ "$(oc get OperandConfig -n ibm-common-services | sed -n 2p | awk '{print $1}')" != "common-service" ]; do
  if [ $time -gt $maxWaitTime ]; then
    echo "ERROR: Exiting installation as OperandConfig 'common-services is not found'"
    retry true
  fi
  echo "INFO: Waiting for OperandConfig 'common-services' to be available. Waited ${time} seconds(s)."
  time=$((time + 60))
  sleep 60
done
echo "INFO: Operand config common-services found: $(oc get OperandConfig -n ibm-common-services | sed -n 2p | awk '{print $1}')"
echo "INFO: Proceeding with updating the OperandConfig to enable Openshift Authentication..."
# Update the OperandConfig to use the correct IAM Url
IAM_Update_OperandConfig

# Instantiate Platform Navigator
echo "INFO: Instantiating Platform Navigator"
install_platform_navigator

# Printing the platform navigator object status
route=$(oc get route -n ${namespace} ${namespace}-navigator-pn -o json | jq -r .spec.host);
echo "INFO: The platform navigator object status:"
echo "INFO: $(oc get PlatformNavigator -n ${namespace} ${namespace}-navigator)"
echo "INFO: PLATFORM NAVIGATOR ROUTE IS: $route";

# Check if the platform navigator UI is reachable
response=$(curl -k -I "https://${route}")
if [[ $response != *"200 OK"* ]]; then
  # if navigator ui is not there
  retry true
fi

# clean up
cleanSubscriptions


if [[ ! -z "$platformPassword" ]]
then
      echo "INFO: Changing Platform Password"
  sh ${deploymentScriptsPath}/change-cs-credentials.sh -p ${platformPassword}
    
fi


echo "INFO: CP4I Installed Successfully on project ${namespace}"

if [[ "$capabilityOperationsDashboard" == "true" ]] 
then
echo "INFO: Installing Capability Operations Dashboard";
sh ${deploymentScriptsPath}/release-tracing.sh -n ${namespace} -r operations-dashboard -f ${storageClass} -p -b gp2
wait_for_product OperationsDashboard operations-dashboard
fi

if [[ "$capabilityAPIConnect" == "true" ]] 
then
echo "INFO: Installing Capability API Connect";
sh ${deploymentScriptsPath}/release-apic.sh -n ${namespace} -r api -p
wait_for_product APIConnectCluster api

fi
if [[ "$capabilityAPPConnectDashboard" == "true" ]] 
then
echo "INFO: Installing Capability App Connect Dashbaord";
sh ${deploymentScriptsPath}/release-ace-dashboard.sh -n ${namespace} -r app-connect-dashboard -s ${storageClass} -p
wait_for_product Dashboard app-connect-dashboard

fi
if [[ "$capabilityAPPConenctDesigner" == "true" ]] 
then
echo "INFO: Installing Capability App Connect Designer";
sh ${deploymentScriptsPath}/release-ace-designer.sh -n ${namespace} -r app-connect-designer -s ${storageClass}
wait_for_product Dashboard DesignerAuthoring Dashboard app-connect-designer
fi

if [[ "$capabilityAssetRepository" == "true" ]] 
then
echo "INFO: Installing Capability Asset Repository";
sh ${deploymentScriptsPath}/release-ar.sh -n ${namespace} -r assets-repo -a ${storageClass} -c ${storageClass}
wait_for_product AssetRepository assets-repo

fi


if [[ "$runtimeMQ" == "true" ]] 
then
echo "INFO: Installing Runtime MQ";
sh ${deploymentScriptsPath}/release-mq.sh -n ${namespace} -r mq  -z ${namespace}
wait_for_product QueueManager mq

fi

if [[ "$runtimeKafka" == "true" ]] 
then
echo "INFO: Installing Runtime Kafka";
sh ${deploymentScriptsPath}/release-es.sh -n ${namespace} -r kafka  -p -c ${storageClass}
wait_for_product EventStreams kafka

fi

if [[ "$runtimeAspera" == "true" ]] 
then
echo "INFO: Installing Runtime Aspera";
sh ${deploymentScriptsPath}/release-aspera.sh -n ${namespace} -r aspera -p -c ${storageClass} -k ${asperaKey}
wait_for_product IbmAsperaHsts aspera

fi

if [[ "$runtimeDataPower" == "true" ]] 
then
echo "INFO: Installing Runtime DataPower";
sh ${deploymentScriptsPath}/release-datapower.sh -n ${namespace} -r datapower -p -a admin
wait_for_product DataPowerService datapower

fi

}

install
exit 0
