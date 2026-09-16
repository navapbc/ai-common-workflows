resource "aws_kms_key" "rds" {
  description             = "CMK for the claims database"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_db_instance" "claims" {
  identifier              = "claims-primary"
  engine                  = "postgres"
  instance_class          = "db.t3.medium"
  allocated_storage       = 100
  db_name                 = "claims"
  username                = "app"
  password                = var.db_password
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.rds.arn
  backup_retention_period = 30
  deletion_protection     = true
  publicly_accessible     = false
  skip_final_snapshot     = false
}
