resource "aws_db_instance" "claims" {
  identifier           = "claims-primary"
  engine               = "postgres"
  instance_class       = "db.t3.medium"
  allocated_storage    = 100
  db_name              = "claims"
  username             = "app"
  password             = var.db_password
  skip_final_snapshot  = true
  publicly_accessible  = false
}
