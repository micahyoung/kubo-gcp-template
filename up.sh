#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if ! [ -d state/ ]; then
  exit "No State, exiting"
  exit 1
fi

source ./state/env.sh
: "${GCP_PROJECT_ID:?!}"
: "${GCP_PROJECT_DOMAIN:?!}"
: "${GCP_SERVICE_ACCOUNT_NAME:?!}"
: "${GCP_REGION:?!}"
: "${GCP_ZONE:?!}"
: "${GCP_NETWORK_NAME:?!}"


mkdir -p bin
PATH=$PATH:$(pwd)/bin

if ! [ -f bin/bosh ]; then
  curl -L "https://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-2.0.1-darwin-amd64" > bin/bosh
  chmod +x bin/bosh
fi

if ! [ -f bin/terraform ]; then
  curl -L "https://releases.hashicorp.com/terraform/0.10.2/terraform_0.10.2_darwin_amd64.zip" | funzip > bin/terraform
  chmod +x bin/terraform
fi

if ! gcloud --version; then
  brew cask install google-cloud-sdk
fi

if ! gcloud auth list | grep ACTIVE >/dev/null; then
  gcloud auth login
fi

if ! gcloud config get-value project | grep $GCP_PROJECT_ID >/dev/null; then
  gcloud config set project $GCP_PROJECT_ID
fi

if ! gcloud iam service-accounts list | grep $GCP_SERVICE_ACCOUNT_NAME >/dev/null; then
  gcloud iam service-accounts create $GCP_SERVICE_ACCOUNT_NAME
fi

if ! gcloud iam service-accounts list | grep $GCP_SERVICE_ACCOUNT_NAME >/dev/null; then
  gcloud iam service-accounts create kubo
fi

if ! [ -f state/$GCP_SERVICE_ACCOUNT_NAME.key.json ]; then
  gcloud iam service-accounts keys create \
    --iam-account=$GCP_SERVICE_ACCOUNT_NAME@$GCP_PROJECT_DOMAIN \
    state/$GCP_SERVICE_ACCOUNT_NAME.key.json \
  ;
fi

if ! gcloud projects get-iam-policy $GCP_PROJECT_ID | grep $GCP_SERVICE_ACCOUNT_NAME >/dev/null; then
  gcloud projects add-iam-policy-binding $GCP_PROJECT_ID \
    --member serviceAccount:$GCP_SERVICE_ACCOUNT_NAME@$GCP_PROJECT_DOMAIN \
    --role 'roles/owner' \
  ;
fi

if ! gcloud compute networks describe $GCP_NETWORK_NAME >/dev/null; then
  gcloud compute networks create $GCP_NETWORK_NAME \
    --mode=custom \
  ;
fi

if ! [ -d kubo-deployment ]; then
  git clone https://github.com/cloudfoundry-incubator/kubo-deployment.git
fi

module_directory=$(pwd)/kubo-deployment/docs/user-guide/platforms/gcp
if ! [ -f state/terraform.tfstate ]; then
  docker run -i -t \
    -v $module_directory:/terraform \
    -v $(pwd)/state:/state \
    hashicorp/terraform:light init \
      -from-module /terraform/ \
      /state \
  ;
fi

SERVICE_ACCOUNT_EMAIL=$GCP_SERVICE_ACCOUNT_NAME@$GCP_PROJECT_DOMAIN
GOOGLE_CREDENTIALS=$(cat state/$GCP_SERVICE_ACCOUNT_NAME.key.json)
docker run -i -t \
  -v $module_directory:/terraform \
  -v $(pwd)/state:/state \
  -w /state/ \
  -e CHECKPOINT_DISABLE=1 \
  -e "GOOGLE_CREDENTIALS=${GOOGLE_CREDENTIALS}" \
  hashicorp/terraform:light apply \
    -var service_account_email=$SERVICE_ACCOUNT_EMAIL \
    -var projectid=$GCP_PROJECT_ID \
    -var network=$GCP_NETWORK_NAME \
    -var region=$GCP_REGION \
    -var prefix="kubo-deployment-" \
    -var zone=$GCP_ZONE \
    -var subnet_ip_prefix=10.0.1 \
    /terraform/ \
;

if ! [ -f state/bastion_id_rsa ]; then
  ssh-keygen -t rsa -f state/bastion_id_rsa -N ''
fi

gcloud compute copy-files \
  state/$GCP_SERVICE_ACCOUNT_NAME.key.json \
  "kubo-deployment-bosh-bastion":./ \
  --ssh-key-file state/bastion_id_rsa \
  --zone $GCP_ZONE \
;
