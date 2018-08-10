#!/bin/bash

#####################################################################
# Example command in CloudShell
# curl -s https://raw.githubusercontent.com/valda-z/aks-netcore-playground/master/run.sh | bash -s -- --resource-group AKS --kubernetes-name valdaaks

#####################################################################
# user defined parameters
LOCATION="westeurope"
RESOURCEGROUP=""
KUBERNETESNAME=""

while [[ $# > 0 ]]
do
  key="$1"
  shift
  case $key in
    --location)
      LOCATION="$1"
      shift
      ;;
    --resource-group)
      RESOURCEGROUP="$1"
      shift
      ;;
    --kubernetes-name)
      KUBERNETESNAME="$1"
      shift
      ;;
    *)
      echo "ERROR: Unknown argument '$key' to script '$0'" 1>&2
      exit -1
  esac
done


function throw_if_empty() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "Parameter '$name' cannot be empty." 1>&2
    exit -1
  fi
}

#check parametrs
throw_if_empty --location $LOCATION
throw_if_empty --resource-group $RESOURCEGROUP
throw_if_empty --kubernetes-name  $KUBERNETESNAME

#####################################################################
# constants
MYUUID=$(cat /proc/sys/kernel/random/uuid | cut -d '-' -f 1)
APPDNSNAME="${KUBERNETESNAME}-${MYUUID}"
ACRNAME="${KUBERNETESNAME}${MYUUID}"
KUBERNETESADMINUSER=$(whoami)

#####################################################################
# internal variables
REGISTRY_SERVER=""
REGISTRY_USER_NAME=""
REGISTRY_PASSWORD=""
CREDENTIALS_ID=""
CREDENTIALS_DESC=""

#############################################################
# supporting functions
#############################################################
function retry_until_successful {
    counter=0
    echo "      .. EXEC:" "${@}"
    "${@}"
    while [ $? -ne 0 ]; do
        if [[ "$counter" -gt 50 ]]; then
            exit 1
        else
            let counter++
        fi
        echo "Retrying ..."
        sleep 5
        "${@}"
    done;
}

#############################################################
# create AKS
#############################################################

### login to Azure
# az login

### create resource group
echo "  .. create Resource group"
az group create --name ${RESOURCEGROUP} --location ${LOCATION} > /dev/null

### create kubernetes cluster
echo "  .. create AKS with kubernetes"
az aks create --resource-group ${RESOURCEGROUP} --name ${KUBERNETESNAME} --location ${LOCATION} --node-count 3 --kubernetes-version 1.9.6 --admin-username ${KUBERNETESADMINUSER} > /dev/null
sleep 10

#############################################################
# configure kubectl, helm
#############################################################

echo "  .. configuring kubectl and helm"

echo "      .. get kubectl credentials"
### initialize .kube/config
az aks get-credentials --resource-group=${RESOURCEGROUP} --name=${KUBERNETESNAME} > /dev/null
retry_until_successful kubectl get nodes
sleep 20
retry_until_successful kubectl get nodes
sleep 20
retry_until_successful kubectl get nodes
sleep 20
retry_until_successful kubectl get nodes
retry_until_successful kubectl patch storageclass default -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' > /dev/null

echo "      .. helm init"
### initialize helm
retry_until_successful helm init > /dev/null
retry_until_successful helm version
### patch tiller-deploy for version 2.9
echo "          .. patching tiller-deploy"
retry_until_successful kubectl -n kube-system patch deployment tiller-deploy -p '{"spec": {"template": {"spec": {"automountServiceAccountToken": true}}}}'
retry_until_successful helm version

#############################################################
# helm install services
#############################################################

echo "  .. helm - installing charts"

echo "      .. helming nginx-ingress"
### install nginx ingress to kubernetes cluster
retry_until_successful helm install --name default-ingress stable/nginx-ingress >/dev/null

### create ACR
echo "  .. create ACR"
az acr create -n ${ACRNAME} -g ${RESOURCEGROUP} --location ${LOCATION} --admin-enabled true --sku Basic > /dev/null
read REGISTRY_SERVER <<< $(az acr show -g ${RESOURCEGROUP} -n ${ACRNAME} --query [loginServer] -o tsv)
read REGISTRY_USER_NAME REGISTRY_PASSWORD <<< $(az acr credential show -g ${RESOURCEGROUP} -n ${ACRNAME} --query [username,passwords[0].value] -o tsv)
CREDENTIALS_ID=${REGISTRY_SERVER}
CREDENTIALS_DESC=${REGISTRY_SERVER}

#############################################################
# nginx-ingress installation / configuration
#############################################################

echo "  .. installing nginx-ingress"

echo "      .. waiting for service public IP"
echo -n "     ."
NGINX_IP=""
while [  -z "$NGINX_IP" ]; do
    echo -n "."
    sleep 3
    NGINX_IP=$(kubectl describe service default-ingress-nginx-ingress-controller | grep "LoadBalancer Ingress:" | awk '{print $3}')
done
echo ""

APPPUBIPRG=$(az network public-ip list -o  tsv | grep "${NGINX_IP}" | awk '{print $12}')
APPPUBIPNAME=$(az network public-ip list -o  tsv | grep "${NGINX_IP}" | awk '{print $8}')
APPFQDN=$(az network public-ip update --resource-group ${APPPUBIPRG} --name ${APPPUBIPNAME} --dns-name ${APPDNSNAME} --query [dnsSettings.fqdn] -o tsv)

#############################################################
# kubernetes ACR credentials
#############################################################

echo "  .. installing ACR credentials to kubernetes"
retry_until_successful kubectl create secret docker-registry ${REGISTRY_SERVER} --docker-server=${REGISTRY_SERVER} --docker-username=${REGISTRY_USER_NAME} --docker-password="${REGISTRY_PASSWORD}" --docker-email=test@test.it  > /dev/null

#############################################################
# end
#############################################################

echo "##########################################################################"
echo "### DONE!"
echo "### URL for your application is http://${APPFQDN} after deployment"
