resource "aws_security_group" "kube-worker" {
  name        = "kube-worker"
  description = "security group that open ports to vpc, this needs to be attached to kube worker"
  vpc_id      = "${module.cdis_vpc.vpc_id}"

  ingress {
    from_port   = 30000
    to_port     = 30100
    protocol    = "TCP"
    cidr_blocks = ["172.${var.vpc_octet2}.${var.vpc_octet3}.0/20", "${var.csoc_cidr}"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "TCP"
    cidr_blocks = ["${var.csoc_cidr}"]
  }

  tags {
    Environment  = "${var.vpc_name}"
    Organization = "Basic Service"
  }
}

resource "aws_route_table_association" "public_kube" {
  subnet_id      = "${aws_subnet.public_kube.id}"
  route_table_id = "${module.cdis_vpc.public_route_table_id}"
}

resource "aws_subnet" "public_kube" {
  vpc_id                  = "${module.cdis_vpc.vpc_id}"
  cidr_block              = "172.${var.vpc_octet2}.${var.vpc_octet3 + 4}.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${data.aws_availability_zones.available.names[0]}"

  # Note: KubernetesCluster tag is required by kube-aws to identify the public subnet for ELBs
  tags = "${map("Name", "public_kube", "Organization", "Basic Service", "Environment", var.vpc_name, "kubernetes.io/cluster/${var.vpc_name}", "shared", "kubernetes.io/role/elb", "", "KubernetesCluster", "${local.cluster_name}")}"
}

#
# Only create db_fence if var.db_password_fence is set.
# Sort of a hack during userapi to fence switch over.
#
resource "aws_db_instance" "db_fence" {
  allocated_storage           = "${var.db_size}"
  identifier                  = "${var.vpc_name}-fencedb"
  storage_type                = "gp2"
  engine                      = "postgres"
  engine_version              = "9.6.6"
  parameter_group_name        = "${aws_db_parameter_group.rds-cdis-pg.name}"
  instance_class              = "${var.db_instance}"
  name                        = "fence"
  username                    = "fence_user"
  password                    = "${var.db_password_fence}"
  snapshot_identifier         = "${var.fence_snapshot}"
  db_subnet_group_name        = "${aws_db_subnet_group.private_group.id}"
  vpc_security_group_ids      = ["${module.cdis_vpc.security_group_local_id}"]
  allow_major_version_upgrade = true
  final_snapshot_identifier   = "${replace(var.vpc_name,"_", "-")}-fencedb"

  tags {
    Environment  = "${var.vpc_name}"
    Organization = "Basic Service"
  }

  lifecycle {
    ignore_changes  = ["identifier", "name", "engine_version", "username", "password", "allocated_storage", "parameter_group_name"]
    prevent_destroy = true
  }
}

resource "aws_db_instance" "db_gdcapi" {
  allocated_storage           = "${var.db_size}"
  identifier                  = "${var.vpc_name}-gdcapidb"
  storage_type                = "gp2"
  engine                      = "postgres"
  engine_version              = "9.6.6"
  parameter_group_name        = "${aws_db_parameter_group.rds-cdis-pg.name}"
  instance_class              = "${var.db_instance}"
  name                        = "gdcapi"
  username                    = "sheepdog"
  password                    = "${var.db_password_sheepdog}"
  snapshot_identifier         = "${var.gdcapi_snapshot}"
  db_subnet_group_name        = "${aws_db_subnet_group.private_group.id}"
  vpc_security_group_ids      = ["${module.cdis_vpc.security_group_local_id}"]
  allow_major_version_upgrade = true
  final_snapshot_identifier   = "${replace(var.vpc_name,"_", "-")}-gdcapidb"

  tags {
    Environment  = "${var.vpc_name}"
    Organization = "Basic Service"
  }

  lifecycle {
    ignore_changes  = ["*"]
    prevent_destroy = true
  }
}

resource "aws_db_instance" "db_indexd" {
  allocated_storage           = "${var.db_size}"
  identifier                  = "${var.vpc_name}-indexddb"
  storage_type                = "gp2"
  engine                      = "postgres"
  engine_version              = "9.6.6"
  parameter_group_name        = "${aws_db_parameter_group.rds-cdis-pg.name}"
  instance_class              = "${var.db_instance}"
  name                        = "indexd"
  username                    = "indexd_user"
  password                    = "${var.db_password_indexd}"
  snapshot_identifier         = "${var.indexd_snapshot}"
  db_subnet_group_name        = "${aws_db_subnet_group.private_group.id}"
  vpc_security_group_ids      = ["${module.cdis_vpc.security_group_local_id}"]
  allow_major_version_upgrade = true
  final_snapshot_identifier   = "${replace(var.vpc_name,"_", "-")}-indexddb"

  tags {
    Environment  = "${var.vpc_name}"
    Organization = "Basic Service"
  }

  lifecycle {
    ignore_changes  = ["identifier", "name", "engine_version", "username", "password", "allocated_storage", "parameter_group_name"]
    prevent_destroy = true
  }
}

# See https://www.postgresql.org/docs/9.6/static/runtime-config-logging.html
# and https://www.postgresql.org/docs/9.6/static/runtime-config-query.html#RUNTIME-CONFIG-QUERY-ENABLE
# for detail parameter descriptions

resource "aws_db_parameter_group" "rds-cdis-pg" {
  name   = "${var.vpc_name}-rds-cdis-pg"
  family = "postgres9.6"

  # make index searches cheaper per row
  parameter {
    name  = "cpu_index_tuple_cost"
    value = "0.000005"
  }

  # raise cost of search per row to be closer to read cost
  # suggested for SSD backed disks
  parameter {
    name  = "cpu_tuple_cost"
    value = "0.7"
  }

  # Log the duration of each SQL statement
  parameter {
    name  = "log_duration"
    value = "1"
  }

  # Log statements above this duration
  # 0 = everything
  parameter {
    name  = "log_min_duration_statement"
    value = "0"
  }

  # lower cost of random reads from disk because we use SSDs
  parameter {
    name  = "random_page_cost"
    value = "0.7"
  }
}

resource "aws_kms_key" "kube_key" {
  description         = "encryption/decryption key for kubernete"
  enable_key_rotation = true

  tags {
    Environment  = "${var.vpc_name}"
    Organization = "Basic Service"
  }
}

resource "aws_kms_alias" "kube_key" {
  name          = "alias/${var.vpc_name}-k8s"
  target_key_id = "${aws_kms_key.kube_key.key_id}"
}

resource "aws_key_pair" "automation_dev" {
  key_name   = "${var.vpc_name}_automation_dev"
  public_key = "${var.kube_ssh_key}"
}

resource "aws_s3_bucket" "kube_bucket" {
  # S3 buckets are in a global namespace, so dns style naming
  bucket = "kube-${replace(var.vpc_name,"_", "-")}-gen3"
  acl    = "private"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  tags {
    Name         = "kube-${replace(var.vpc_name,"_", "-")}-gen3"
    Environment  = "${var.vpc_name}"
    Organization = "Basic Service"
  }

  lifecycle {
    # allow same bucket between stacks
    ignore_changes = ["tags", "bucket"]
  }
}