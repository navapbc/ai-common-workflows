import logging
log = logging.getLogger(__name__)

def enroll(beneficiary):
    log.info("enrollment request received")
    return {"status": "accepted"}
