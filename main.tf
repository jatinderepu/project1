terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
provider "aws" {
  profile = "default"
  region  = "us-west-1"
}
module "vpc" {
  source             = "terraform-aws-modules/vpc/aws"
  name               = "test"
  cidr               = "10.0.0.0/16"
  azs                = ["us-west-1c", "us-west-1b"]
  private_subnets    = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets     = ["10.0.101.0/24", "10.0.102.0/24"]
  enable_nat_gateway = true
}
module "web_server_sg" {
  source              = "terraform-aws-modules/security-group/aws//modules/http-80"
  name                = "web-server"
  description         = "Security group for web-server with HTTP ports open within VPC"
  vpc_id              = module.vpc.vpc_id
  ingress_cidr_blocks = ["10.10.0.0/16"]
}
resource "aws_lb" "default" {
  name    = "graphene-lb"
  subnets = module.vpc.private_subnets
}
resource "aws_lb_target_group" "hello_world" {
  name        = "example-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"
}
resource "aws_lb_listener" "hello_world" {
  load_balancer_arn = aws_lb.default.id
  port              = "80"
  protocol          = "HTTP"
  default_action {
    target_group_arn = aws_lb_target_group.hello_world.id
    type             = "forward"
  }
}
resource "aws_ecs_cluster" "demo-ecs-cluster" {
  name = "ecs-cluster-for-demo"
}
resource "aws_ecs_service" "demo-ecs-service-two" {
  name            = "demo-app"
  cluster         = aws_ecs_cluster.demo-ecs-cluster.id
  task_definition = aws_ecs_task_definition.demo-ecs-task-definition.arn
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = module.vpc.private_subnets
    assign_public_ip = true
  }
   load_balancer {
    target_group_arn = aws_lb_target_group.hello_world.id
    container_name   = "demo-container"
    container_port   = 80
  }
  desired_count = 2
}
resource "aws_ecs_task_definition" "demo-ecs-task-definition" {
  family                   = "ecs-task-definition-demo"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  memory                   = "1024"
  cpu                      = "512"
  execution_role_arn       = "arn:aws:iam::225842243320:role/ecsTaskExecutionRole"
  container_definitions    = <<EOF
[
  {
    "name": "demo-container",
    "image": "225842243320.dkr.ecr.us-west-1.amazonaws.com/test1:latest",
    "memory": 1024,
    "cpu": 512,
    "essential": true,
    "entryPoint": ["/"],
    "portMappings": [
      {
        "containerPort": 80,
        "hostPort": 80
      }
    ] 
  }
]
EOF
}
resource "aws_appmesh_mesh" "main" {
  name = "main-app-mesh"
  spec {
    egress_filter {
      type = "DROP_ALL"
    }
  }
}
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "test.local"
  description = "all services will be registered under this common namespace"
  vpc         = module.vpc.vpc_id
}
resource "aws_service_discovery_service" "app" {
  name = "app.test.local"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}
resource "aws_appmesh_virtual_gateway" "vgtest" {
  name      = "app-virtual-gateway"
  mesh_name = aws_appmesh_mesh.main.name

  spec {
    listener {
      port_mapping {
        port     = 8080
        protocol = "http"
      }
    }
  }

  tags = {
    Environment = "test"
  }
}
resource "aws_appmesh_virtual_node" "app" {
  name      = "app"
  mesh_name = aws_appmesh_mesh.main.name
  spec {
    listener {
      port_mapping {
        port     = "80"
        protocol = "http"
      }
      health_check {
        protocol            = "http"
        path                = "/"
        healthy_threshold   = 2
        unhealthy_threshold = 2
        timeout_millis      = 2000
        interval_millis     = 5000
      }
    }
    service_discovery {
      aws_cloud_map {
        service_name   = aws_service_discovery_service.app.name
        namespace_name = aws_service_discovery_private_dns_namespace.main.name
      }
    }
  }
}
resource "aws_appmesh_virtual_router" "app" {
  name      = "app-router"
  mesh_name = aws_appmesh_mesh.main.name
  spec {
    listener {
      port_mapping {
        port     = "80"
        protocol = "http"
      }
    }
  }
}
resource "aws_appmesh_route" "app" {
  name                = "app-route"
  mesh_name           = aws_appmesh_mesh.main.name
  virtual_router_name = aws_appmesh_virtual_router.app.name
  spec {
    http_route {
      match {
        prefix = "/"
      }
      retry_policy {
        http_retry_events = [
          "server-error",
        ]
        max_retries = 1
        per_retry_timeout {
          unit  = "s"
          value = 15
        }
      }
      action {
        weighted_target {
          virtual_node = aws_appmesh_virtual_node.app.name
          weight       = 1
        }
      }
    }
  }
}
resource "aws_appmesh_virtual_service" "app" {
  name      = "app.test.local"
  mesh_name = aws_appmesh_mesh.main.name
  spec {
    provider {
      virtual_router {
        virtual_router_name = aws_appmesh_virtual_router.app.name
      }
    }
  }
}
