## need to test

terraform {
    required_version = ">= 1.0"
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 5.0"
        }
    }
}

provider "aws" {
    region = var.aws_region
}

# Variables
variable "aws_region" {
    description = "AWS region"
    type        = string
    default     = "us-west-2"
}

variable "cluster_name" {
    description = "EKS cluster name"
    type        = string
    default     = "my-eks-cluster"
}

variable "cluster_version" {
    description = "EKS cluster version"
    type        = string
    default     = "1.28"
}

# Data sources
data "aws_availability_zones" "available" {
    state = "available"
}

# VPC
resource "aws_vpc" "main" {
    cidr_block           = "10.0.0.0/16"
    enable_dns_hostnames = true
    enable_dns_support   = true

    tags = {
        Name = "${var.cluster_name}-vpc"
    }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
    vpc_id = aws_vpc.main.id

    tags = {
        Name = "${var.cluster_name}-igw"
    }
}

# Subnets
resource "aws_subnet" "private" {
    count             = 2
    vpc_id            = aws_vpc.main.id
    cidr_block        = "10.0.${count.index + 1}.0/24"
    availability_zone = data.aws_availability_zones.available.names[count.index]

    tags = {
        Name                              = "${var.cluster_name}-private-${count.index + 1}"
        "kubernetes.io/role/internal-elb" = "1"
        "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
}

resource "aws_subnet" "public" {
    count                   = 2
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.${count.index + 101}.0/24"
    availability_zone       = data.aws_availability_zones.available.names[count.index]
    map_public_ip_on_launch = true

    tags = {
        Name                            = "${var.cluster_name}-public-${count.index + 1}"
        "kubernetes.io/role/elb"        = "1"
        "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
}

# NAT Gateway
resource "aws_eip" "nat" {
    count  = 2
    domain = "vpc"

    tags = {
        Name = "${var.cluster_name}-nat-${count.index + 1}"
    }
}

resource "aws_nat_gateway" "main" {
    count         = 2
    allocation_id = aws_eip.nat[count.index].id
    subnet_id     = aws_subnet.public[count.index].id

    tags = {
        Name = "${var.cluster_name}-nat-${count.index + 1}"
    }

    depends_on = [aws_internet_gateway.main]
}

# Route Tables
resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.main.id
    }

    tags = {
        Name = "${var.cluster_name}-public"
    }
}

resource "aws_route_table" "private" {
    count  = 2
    vpc_id = aws_vpc.main.id

    route {
        cidr_block     = "0.0.0.0/0"
        nat_gateway_id = aws_nat_gateway.main[count.index].id
    }

    tags = {
        Name = "${var.cluster_name}-private-${count.index + 1}"
    }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
    count          = 2
    subnet_id      = aws_subnet.public[count.index].id
    route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
    count          = 2
    subnet_id      = aws_subnet.private[count.index].id
    route_table_id = aws_route_table.private[count.index].id
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
    name = "${var.cluster_name}-cluster-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    Service = "eks.amazonaws.com"
                }
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
    role       = aws_iam_role.eks_cluster.name
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
    name     = var.cluster_name
    role_arn = aws_iam_role.eks_cluster.arn
    version  = var.cluster_version

    vpc_config {
        subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
        endpoint_private_access = true
        endpoint_public_access  = true
    }

    depends_on = [
        aws_iam_role_policy_attachment.eks_cluster_policy
    ]

    tags = {
        Name = var.cluster_name
    }
}

# EKS Node Group IAM Role
resource "aws_iam_role" "eks_node_group" {
    name = "${var.cluster_name}-node-group-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    Service = "ec2.amazonaws.com"
                }
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    role       = aws_iam_role.eks_node_group.name
}

# EKS Node Group
resource "aws_eks_node_group" "main" {
    cluster_name    = aws_eks_cluster.main.name
    node_group_name = "${var.cluster_name}-node-group"
    node_role_arn   = aws_iam_role.eks_node_group.arn
    subnet_ids      = aws_subnet.private[*].id

    capacity_type  = "ON_DEMAND"
    instance_types = ["t3.medium"]

    scaling_config {
        desired_size = 2
        max_size     = 3
        min_size     = 1
    }

    update_config {
        max_unavailable = 1
    }

    depends_on = [
        aws_iam_role_policy_attachment.eks_worker_node_policy,
        aws_iam_role_policy_attachment.eks_cni_policy,
        aws_iam_role_policy_attachment.eks_container_registry_policy,
    ]

    tags = {
        Name = "${var.cluster_name}-node-group"
    }
}

# Outputs
output "cluster_endpoint" {
    description = "EKS cluster endpoint"
    value       = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
    description = "Security group ID attached to the EKS cluster"
    value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "cluster_name" {
    description = "EKS cluster name"
    value       = aws_eks_cluster.main.name
}