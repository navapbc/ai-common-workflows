import logging
log = logging.getLogger(__name__)

def enroll(beneficiary):
    log.info(
        "enrollment request for ssn=%s dob=%s diagnosis=%s",
        beneficiary["ssn"], beneficiary["dob"], beneficiary["diagnosis"],
    )
    return {"status": "accepted"}
