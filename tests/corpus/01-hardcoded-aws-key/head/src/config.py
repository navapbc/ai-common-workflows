import boto3

AWS_ACCESS_KEY_ID = "AKIA6KJEN0O9Z3AM7281"
AWS_SECRET_ACCESS_KEY = "zse0/NAHAiistXanXskQ4Dyj58aTqu0swAPCH1vM"

def client():
    return boto3.client("s3", aws_access_key_id=AWS_ACCESS_KEY_ID,
                        aws_secret_access_key=AWS_SECRET_ACCESS_KEY)
