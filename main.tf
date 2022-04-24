provider "aws" {}

terraform {
  backend "s3" {
    bucket = "yifanfu"
    key    = "ephemeral-state-app"
  }
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "ephemeral_cluster_name" {
  name = "/yifanfu/ephemeral/cluster-name"
}

data "aws_ssm_parameter" "ephemeral_listener_arn" {
  name = "/yifanfu/ephemeral/listener-arn"
}

data "aws_ssm_parameter" "ephemeral_alb_dns_name" {
  name = "/yifanfu/ephemeral/alb-dns-name"
}

data "aws_ssm_parameter" "ephemeral_alb_zone_id" {
  name = "/yifanfu/ephemeral/alb-zone-id"
}

resource "aws_lb_listener_rule" "host_based_weighted_routing" {
  listener_arn = data.aws_ssm_parameter.ephemeral_listener_arn.value

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx.arn
  }

  condition {
    host_header {
      values = ["${terraform.workspace}.*"]
    }
  }
}

resource "aws_lb_target_group" "nginx" {
  name        = "ephemeral-tg-nginx-${terraform.workspace}"
  target_type = "ip"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = "vpc-fe62799b"
  health_check {
    path = "/"
    interval = 300
    timeout = 120
  }
}

data "aws_iam_policy_document" "ecs_tasks_execution_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_tasks_execution_role" {
  name               = "nginx-${terraform.workspace}-ecs-task-execution-role"
  assume_role_policy = "${data.aws_iam_policy_document.ecs_tasks_execution_role.json}"
}

resource "aws_iam_role_policy_attachment" "ecs_tasks_execution_role" {
  role       = "${aws_iam_role.ecs_tasks_execution_role.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "default" {
  name              = "/ecs/ephemeral/nginx-${terraform.workspace}"
  retention_in_days = 1
}

resource "aws_ecs_task_definition" "nginx" {
  family = "nginx"
  execution_role_arn = aws_iam_role.ecs_tasks_execution_role.arn
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu = 256
  memory = 512
  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = "nginx:alpine"
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = 80
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.default.name
          awslogs-region        = "ap-southeast-2"
          awslogs-stream-prefix = "app"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "nginx" {
  name          = "nginx-${terraform.workspace}"
  cluster       = "arn:aws:ecs:ap-southeast-2:${data.aws_caller_identity.current.account_id}:cluster/${data.aws_ssm_parameter.ephemeral_cluster_name.value}"
  desired_count = 1
  launch_type = "FARGATE"

  network_configuration {
    subnets = ["subnet-3c15b358"]
    security_groups = ["sg-e1a58b85"]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.nginx.arn
    container_name = "nginx"
    container_port = 80
  }

  # Track the latest ACTIVE revision
  task_definition = aws_ecs_task_definition.nginx.arn
}

resource "aws_route53_record" "nginx" {
  zone_id = "Z29XRKVIN533HV"
  name = "${terraform.workspace}.yifanfu.com"
  type = "A"

  alias {
    name = data.aws_ssm_parameter.ephemeral_alb_dns_name.value
    zone_id = data.aws_ssm_parameter.ephemeral_alb_zone_id.value
    evaluate_target_health = true
  }
}

# something now important at all