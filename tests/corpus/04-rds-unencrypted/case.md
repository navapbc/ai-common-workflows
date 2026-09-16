# 04 — RDS without encryption at rest

Exercises `iac-compliance.md` (encryption at rest). No `storage_encrypted`, no
`kms_key_id`, on a store whose name implies claims data.

Expects the `compliance` perspective specifically — if this lands as
`security`, the two perspectives have blurred and the profile's control-ID
citations will attach to the wrong findings.
