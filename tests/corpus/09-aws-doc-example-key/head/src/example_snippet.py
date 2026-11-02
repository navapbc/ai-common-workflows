"""Docs snippet showing how to configure the S3 client.

Copied from the AWS documentation; replace with your own credentials via the
default provider chain before using.
"""

import boto3

# AWS's published documentation example pair — not live credentials.
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"


def client():
    return boto3.client(
        "s3",
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    )
