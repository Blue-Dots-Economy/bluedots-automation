#!/bin/bash
set -euo pipefail

echo -e "\nPlease ensure you have updated all the mandatory variables as mentioned in the documentation."
echo "The installation will fail if any of the mandatory variables are missing."
echo "Press Enter to continue..."
read -r

environment=$(basename "$(pwd)")

function create_tf_backend() {
    echo -e "Creating terraform state backend"
    bash create_tf_backend.sh
}

function backup_configs() {
    timestamp=$(date +%d%m%y_%H%M%S)
    echo -e "\nBackup existing kubeconfig if it exists"
    mkdir -p ~/.kube
    mv ~/.kube/config ~/.kube/config.$timestamp || true
    export KUBECONFIG=~/.kube/config
}

function create_tf_resources() {
    source tf.sh
    echo -e "\nCreating resources on AWS"
    terragrunt run --all init -- -upgrade
    terragrunt run --all apply --non-interactive
    chmod 600 ~/.kube/config
}

function apply_gp3_default_sc() {
    echo -e "\nApplying gp3 StorageClass as cluster default"
    kubectl apply -f gp3-sc.yaml
    # Strip default annotation from gp2 if present, so only gp3 is default
    if kubectl get sc gp2 >/dev/null 2>&1; then
        kubectl patch storageclass gp2 \
            -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    fi
}

function destroy_tf_resources() {
    source tf.sh
    echo -e "Destroying resources on AWS cloud"
    terragrunt run --all destroy
}

function invoke_functions() {
    for func in "$@"; do
        $func
    done
}

if [ $# -eq 0 ]; then
    create_tf_backend
    backup_configs
    create_tf_resources
    apply_gp3_default_sc
else
    case "$1" in
    "create_tf_backend")
        create_tf_backend
        ;;
    "create_tf_resources")
        create_tf_resources
        ;;
    "apply_gp3_default_sc")
        apply_gp3_default_sc
        ;;
    "destroy_tf_resources")
        destroy_tf_resources
        ;;
    *)
        invoke_functions "$@"
        ;;
    esac
fi
