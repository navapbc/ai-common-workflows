from flask import Blueprint, jsonify
from auth import require_role

bp = Blueprint("claims", __name__)

@bp.get("/claims/<claim_id>")
@require_role("adjudicator")
def get_claim(claim_id):
    return jsonify(load_claim(claim_id))

@bp.get("/claims/<claim_id>/history")
def get_claim_history(claim_id):
    return jsonify(load_claim_history(claim_id))
