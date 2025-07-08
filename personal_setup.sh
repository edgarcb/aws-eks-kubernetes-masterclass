# Personal setup script for AWS EKS Kubernetes Masterclass

## prerequisites

"admin role"

## UP

# Create Cluster
eksctl create cluster --name=eks-dev --zones=us-east-1a,us-east-1b --without-nodegroup

eksctl get cluster

eksctl utils associate-iam-oidc-provider --cluster eks-dev --approve

# aws key pair 'kube-dev'
eksctl create nodegroup --cluster=eks-dev `
                       --name=eks-dev-ng-public1 `
                       --node-type=t3.medium `
                       --nodes=2 `
                       --nodes-min=2 `
                       --nodes-max=4 `
                       --node-volume-size=20 `
                       --ssh-access `
                       --ssh-public-key=kube-dev `
                       --managed `
                       --asg-access `
                       --external-dns-access `
                       --full-ecr-access `
                       --appmesh-access `
                       --alb-ingress-access

eksctl get nodegroup --cluster=eks-dev

kubectl get nodes -o wide

# Our kubectl context should be automatically changed to new cluster
kubectl config view --minify

## DOWN

eksctl delete nodegroup --cluster=eks-dev --name=eks-dev-ng-public1

eksctl delete cluster --name=eks-dev